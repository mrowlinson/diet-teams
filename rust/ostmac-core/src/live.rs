//! Live media engine — the `run_call_test` media path joined to the Call UI.
//!
//! Signaling (`calls.rs`) places the call; this module owns everything after
//! the SDP answer: ICE, SRTP, RTP send/recv loops, and the two Swift joins:
//! - send: Swift AVCapture -> VideoToolbox encode -> `video_send_push` NAL
//!   queue -> packetizer -> SRTP -> UDP (black IDR fallback when idle).
//! - recv: UDP -> SRTP -> depacketize -> access-unit framing (MS PACSI /
//!   prefix NALs stripped) -> `video_incoming_poll` queue -> Swift
//!   VideoToolbox decode -> SwiftUI display.
//!
//! Audio rides the same engine via cpal (`ost::calling::audio`): mic capture
//! when a device exists, 1kHz tone fallback, speaker render, echo record.
//!
//! The engine runs on its own OS thread + tokio runtime (the per-call `rt()`
//! is dropped when place returns, so media cannot live on it). Loops poll a
//! shutdown flag on 500ms recv timeouts so `stop` joins within ~1s.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use base64::Engine;
use serde::Serialize;

use ost::calling::{ice, rtp, rtcp, sdp, srtp, test_tone, video};

use crate::{err_json, now_secs, string_to_c};

// ---------------------------------------------------------------------------
// Queues (FFI <-> engine)
// ---------------------------------------------------------------------------

/// One send-side access unit from Swift (raw NALs, no start codes).
#[derive(Debug, Clone)]
pub struct SendUnit {
    pub nals: Vec<Vec<u8>>,
}

/// One recv-side access unit for Swift (PACSI/prefix stripped).
#[derive(Debug, Clone)]
pub struct RecvUnit {
    pub nals: Vec<Vec<u8>>,
}

/// Max queued send units (drop-oldest past this; Swift paces at ~15fps).
pub const SEND_QUEUE_CAP: usize = 8;
/// Max queued recv units (drop-oldest; SwiftUI drains at display pace).
pub const RECV_QUEUE_CAP: usize = 4;
/// Max decoded NAL bytes accepted over FFI per push (4 MiB).
pub const MAX_SEND_BYTES: usize = 4 * 1024 * 1024;

fn send_queue() -> &'static Mutex<VecDeque<SendUnit>> {
    static S: OnceLock<Mutex<VecDeque<SendUnit>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn recv_queue() -> &'static Mutex<VecDeque<RecvUnit>> {
    static S: OnceLock<Mutex<VecDeque<RecvUnit>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(VecDeque::new()))
}

fn lock<T>(m: &'static Mutex<T>) -> std::sync::MutexGuard<'static, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// Tests run threaded but the queues are global: queue-touching tests hold
// this guard (plus the calls slot guard) so they never interleave.
#[cfg(test)]
fn test_lock() -> std::sync::MutexGuard<'static, ()> {
    static T: OnceLock<Mutex<()>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

static SEND_DROPPED: AtomicU64 = AtomicU64::new(0);
static RECV_DROPPED: AtomicU64 = AtomicU64::new(0);

fn push_send(unit: SendUnit) {
    let mut q = lock(send_queue());
    if q.len() >= SEND_QUEUE_CAP {
        q.pop_front();
        SEND_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    q.push_back(unit);
}

/// Take the newest send unit, dropping older ones (live pacing: never lag).
fn take_send_latest() -> Option<SendUnit> {
    let mut q = lock(send_queue());
    let unit = q.pop_back()?;
    let stale = q.len() as u64;
    if stale > 0 {
        q.clear();
        SEND_DROPPED.fetch_add(stale, Ordering::Relaxed);
    }
    Some(unit)
}

fn push_recv(unit: RecvUnit) {
    let mut q = lock(recv_queue());
    if q.len() >= RECV_QUEUE_CAP {
        q.pop_front();
        RECV_DROPPED.fetch_add(1, Ordering::Relaxed);
    }
    q.push_back(unit);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, Serialize)]
pub struct LiveStats {
    pub running: bool,
    pub audio_sent: u32,
    pub audio_recv: u32,
    pub video_sent: u32,
    pub video_recv: u32,
    pub send_queued: usize,
    pub send_dropped: u64,
    pub recv_pending: usize,
    pub recv_dropped: u64,
    pub ice_audio: String,
    pub ice_video: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub started_at: u64,
}

fn engine_stats() -> &'static Mutex<LiveStats> {
    static S: OnceLock<Mutex<LiveStats>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(LiveStats::default()))
}

// ---------------------------------------------------------------------------
// NAL helpers
// ---------------------------------------------------------------------------

fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map(|b| b & 0x1F).unwrap_or(0)
}

/// MS-H264PF wrappers the VT decoder must not see: PACSI (30), prefix (14).
fn is_wrapper_nal(nal: &[u8]) -> bool {
    matches!(nal_type(nal), 14 | 30)
}

fn b64_encode(v: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(v)
}

// ---------------------------------------------------------------------------
// JSON bodies: send queue / incoming queue / stats
// ---------------------------------------------------------------------------

/// Push one send-side access unit: JSON array of base64 NALs (no start
/// codes). Over-cap pushes drop the oldest unit (still `{ok:true}`).
pub fn video_send_push_json(nals_json: &str) -> String {
    let arr: Vec<String> = match serde_json::from_str(nals_json) {
        Ok(a) => a,
        Err(e) => return err_json("arg", format!("nals must be a JSON string array: {}", e)),
    };
    if arr.is_empty() || arr.len() > 32 {
        return err_json("arg", format!("need 1..=32 NALs, got {}", arr.len()));
    }
    let mut nals = Vec::with_capacity(arr.len());
    let mut total = 0usize;
    for (i, s) in arr.iter().enumerate() {
        let raw = match base64::engine::general_purpose::STANDARD.decode(s) {
            Ok(r) => r,
            Err(e) => return err_json("arg", format!("nal {} base64: {}", i, e)),
        };
        if raw.is_empty() || raw.len() > MAX_SEND_BYTES {
            return err_json("arg", format!("nal {} bad size {}", i, raw.len()));
        }
        total += raw.len();
        if total > MAX_SEND_BYTES {
            return err_json("arg", format!("unit too large: {} bytes", total));
        }
        nals.push(raw);
    }
    push_send(SendUnit { nals });
    serde_json::json!({"ok": true, "queued": lock(send_queue()).len()}).to_string()
}

/// Drain the newest recv-side access unit (older ones count as dropped).
/// `{ok:true, au:{nals:[b64..]}|null, dropped:n}`.
pub fn video_incoming_poll_json() -> String {
    let mut q = lock(recv_queue());
    let au = q.pop_back().map(|u| {
        u.nals
            .iter()
            .filter(|n| !is_wrapper_nal(n))
            .map(|n| b64_encode(n))
            .collect::<Vec<_>>()
    });
    let stale = q.len();
    if stale > 0 {
        q.clear();
        RECV_DROPPED.fetch_add(stale as u64, Ordering::Relaxed);
    }
    match au {
        Some(nals) if !nals.is_empty() => {
            serde_json::json!({"ok": true, "au": {"nals": nals}, "dropped": stale}).to_string()
        }
        _ => serde_json::json!({"ok": true, "au": null, "dropped": stale}).to_string(),
    }
}

/// Live engine stats (idle `{ok:true, running:false, ...}` when stopped).
pub fn call_media_json() -> String {
    let mut s = lock(engine_stats()).clone();
    s.send_queued = lock(send_queue()).len();
    s.recv_pending = lock(recv_queue()).len();
    s.send_dropped = SEND_DROPPED.load(Ordering::Relaxed);
    s.recv_dropped = RECV_DROPPED.load(Ordering::Relaxed);
    serde_json::json!({"ok": true, "media": s}).to_string()
}

// ---------------------------------------------------------------------------
// Offline loopback: the (c)->packetize->SRTP->depacketize->(b) join, no net.
// ---------------------------------------------------------------------------

fn loopback_material(tag: u32, fill: u8) -> Result<srtp::SrtpKeyingMaterial, String> {
    let raw = vec![fill; 30];
    let b64 = base64::engine::general_purpose::STANDARD.encode(&raw);
    let line = format!(
        "a=crypto:{} AES_CM_128_HMAC_SHA1_80 inline:{}|2^31",
        tag, b64
    );
    srtp::parse_crypto_line(&line).map_err(|e| format!("{:#}", e))
}

/// Run every queued send unit through the real engine data path —
/// packetize -> SRTP protect/unprotect -> RTP decode -> depacketize -> AU
/// framing — and push the resulting AUs to the incoming queue. Returns
/// `{ok, units, packets, aus, nals}`. No network, no auth, no hardware.
pub fn live_loopback_json() -> String {
    let units: Vec<SendUnit> = {
        let mut q = lock(send_queue());
        let mut v = Vec::with_capacity(q.len());
        while let Some(u) = q.pop_front() {
            v.push(u);
        }
        v
    };
    if units.is_empty() {
        return err_json("empty", "send queue is empty; push NALs first");
    }
    let mat_a = loopback_material(1, 0x11).unwrap();
    let mat_b = loopback_material(2, 0x22).unwrap();
    let mut ctx_send = srtp::create_context(&mat_a, &mat_b).unwrap();
    let mut ctx_recv = srtp::create_context(&mat_b, &mat_a).unwrap();
    let mut packetizer = video::VideoPacketizer::new(0x51ab_0001);
    let mut depacketizer = video::VideoDepacketizer::new();

    let mut packets = 0usize;
    let mut aus = 0usize;
    let mut nals_out = 0usize;
    for unit in &units {
        let rtp_packets = packetizer.packetize_frame(&unit.nals);
        let mut au: Vec<Vec<u8>> = Vec::new();
        for pkt in &rtp_packets {
            packets += 1;
            let wire = match srtp::protect(&mut ctx_send, pkt) {
                Ok(p) => p,
                Err(e) => return err_json("srtp", format!("protect: {:#}", e)),
            };
            let back = match srtp::unprotect(&mut ctx_recv, &wire) {
                Ok(p) => p,
                Err(e) => return err_json("srtp", format!("unprotect: {:#}", e)),
            };
            let decoded = match rtp::decode(&back) {
                Ok(p) => p,
                Err(e) => return err_json("rtp", format!("decode: {:#}", e)),
            };
            match depacketizer.depacketize(&decoded.payload, decoded.marker) {
                Ok(Some(nal)) => {
                    if !is_wrapper_nal(&nal) {
                        nals_out += 1;
                        au.push(nal);
                    }
                    if decoded.marker && !au.is_empty() {
                        push_recv(RecvUnit { nals: std::mem::take(&mut au) });
                        aus += 1;
                    }
                }
                Ok(None) => {}
                Err(e) => return err_json("depacketize", format!("{:#}", e)),
            }
        }
        if !au.is_empty() {
            // No marker seen (single-NAL units): still deliver the AU.
            push_recv(RecvUnit { nals: au });
            aus += 1;
        }
    }
    serde_json::json!({
        "ok": true, "units": units.len(), "packets": packets,
        "aus": aus, "nals": nals_out,
    })
    .to_string()
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Everything the engine needs after the SDP answer lands.
pub struct EngineParams {
    pub audio_sock: std::net::UdpSocket,
    pub video_sock: std::net::UdpSocket,
    pub local_audio_crypto: String,
    pub local_video_crypto: Option<String>,
    pub local_audio_ufrag: String,
    pub local_audio_pwd: String,
    pub local_video_ufrag: Option<String>,
    pub local_video_pwd: Option<String>,
    pub remote_sdp: String,
    pub controlling: bool,
    pub video_ssrc: u32,
    pub cname: String,
}

struct EngineHandle {
    shutdown: std::sync::Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn engine_slot() -> &'static Mutex<Option<EngineHandle>> {
    static S: OnceLock<Mutex<Option<EngineHandle>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(None))
}

pub fn engine_running() -> bool {
    lock(engine_slot()).is_some()
}

/// Start the live media engine on its own thread. Idempotent-busy: errors
/// when an engine is already running.
pub fn start_engine(p: EngineParams) -> Result<(), String> {
    {
        if lock(engine_slot()).is_some() {
            return Err("live media already running".to_string());
        }
    }
    // Fresh stats + drained queues for the new call.
    *lock(engine_stats()) = LiveStats {
        running: true,
        started_at: now_secs(),
        ..Default::default()
    };
    lock(send_queue()).clear();
    lock(recv_queue()).clear();

    let shutdown = std::sync::Arc::new(AtomicBool::new(false));
    let flag = shutdown.clone();
    let thread = std::thread::Builder::new()
        .name("ostmac-live-media".to_string())
        .spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(r) => r,
                Err(e) => {
                    lock(engine_stats()).error = Some(format!("runtime: {}", e));
                    return;
                }
            };
            rt.block_on(drive(p, flag));
        })
        .map_err(|e| format!("spawn media thread: {}", e))?;
    *lock(engine_slot()) = Some(EngineHandle {
        shutdown,
        thread: Some(thread),
    });
    Ok(())
}

/// Signal stop and join the engine thread (loops poll the flag on 500ms
/// recv timeouts, so this returns in ~1s).
pub fn stop_engine() -> LiveStats {
    let handle = lock(engine_slot()).take();
    if let Some(mut h) = handle {
        h.shutdown.store(true, Ordering::Relaxed);
        if let Some(t) = h.thread.take() {
            let _ = t.join();
        }
    }
    let mut s = lock(engine_stats());
    s.running = false;
    s.clone()
}

pub fn call_media_stop_json() -> String {
    let s = stop_engine();
    serde_json::json!({"ok": true, "media": s}).to_string()
}

fn stat_add(f: impl FnOnce(&mut LiveStats)) {
    f(&mut lock(engine_stats()));
}

fn stat_set_ice(audio: String, video: String) {
    let mut s = lock(engine_stats());
    s.ice_audio = audio;
    s.ice_video = video;
}

fn stat_error(e: String) {
    let mut s = lock(engine_stats());
    s.error = Some(e);
}

async fn drive(p: EngineParams, shutdown: std::sync::Arc<AtomicBool>) {
    if let Err(e) = drive_inner(p, shutdown).await {
        stat_error(e);
    }
    stat_add(|s| s.running = false);
}

async fn drive_inner(p: EngineParams, shutdown: std::sync::Arc<AtomicBool>) -> Result<(), String> {
    use tokio::sync::Mutex as AMutex;

    let audio_sock = std::sync::Arc::new(
        tokio::net::UdpSocket::from_std(p.audio_sock).map_err(|e| format!("audio sock: {}", e))?,
    );
    let video_sock = std::sync::Arc::new(
        tokio::net::UdpSocket::from_std(p.video_sock).map_err(|e| format!("video sock: {}", e))?,
    );

    let remote = sdp::parse_sdp_offer(&p.remote_sdp).map_err(|e| format!("remote SDP: {:#}", e))?;

    // SRTP contexts (local offer/answer crypto + remote crypto).
    let local_audio_mat =
        srtp::parse_crypto_line(&p.local_audio_crypto).map_err(|e| format!("audio crypto: {:#}", e))?;
    let remote_audio_mat = remote
        .crypto_lines
        .iter()
        .find_map(|l| srtp::parse_crypto_line(l).ok())
        .ok_or_else(|| "no audio crypto in remote SDP".to_string())?;
    let audio_ctx = std::sync::Arc::new(AMutex::new(
        srtp::create_context(&local_audio_mat, &remote_audio_mat)
            .map_err(|e| format!("audio srtp: {:#}", e))?,
    ));

    let video_pair: Option<(std::sync::Arc<AMutex<srtp::SrtpContext>>, String, String)> =
        match (&p.local_video_crypto, &remote.video) {
            (Some(local_line), Some(vid)) => {
                let local_mat = srtp::parse_crypto_line(local_line)
                    .map_err(|e| format!("video crypto: {:#}", e))?;
                let remote_mat = vid
                    .crypto_lines
                    .iter()
                    .find_map(|l| srtp::parse_crypto_line(l).ok())
                    .ok_or_else(|| "no video crypto in remote SDP".to_string())?;
                let ctx = srtp::create_context(&local_mat, &remote_mat)
                    .map_err(|e| format!("video srtp: {:#}", e))?;
                Some((
                    std::sync::Arc::new(AMutex::new(ctx)),
                    p.local_video_ufrag.clone().unwrap_or_default(),
                    p.local_video_pwd.clone().unwrap_or_default(),
                ))
            }
            _ => None,
        };

    // ICE (bounded: stop-aware).
    let audio_cands = ice::parse_candidates_from_sdp(&p.remote_sdp);
    let audio_agent = ice::IceAgent::new(
        ice::IceCredentials {
            ufrag: p.local_audio_ufrag.clone(),
            pwd: p.local_audio_pwd.clone(),
        },
        ice::IceCredentials {
            ufrag: remote.ice_ufrag.clone(),
            pwd: remote.ice_pwd.clone(),
        },
        p.controlling,
    );
    let ice_fut = audio_agent.check_connectivity(audio_sock.clone(), &audio_cands);
    let audio_remote = tokio::select! {
        r = ice_fut => r.map(|c| c.remote_addr).unwrap_or_else(|_| {
            ice::select_remote_candidate(&audio_cands)
                .unwrap_or_else(|| "127.0.0.1:9".parse().unwrap())
        }),
        _ = wait_shutdown(&shutdown) => return Ok(()),
    };
    stat_set_ice(audio_remote.to_string(), String::new());

    let video_remote: Option<std::net::SocketAddr> = if video_pair.is_some() {
        let vid_cands = ice::parse_candidates_from_sdp_section(&p.remote_sdp, "video");
        let vid = remote.video.as_ref().cloned().unwrap();
        let vid_agent = ice::IceAgent::new(
            ice::IceCredentials {
                ufrag: p.local_video_ufrag.clone().unwrap_or_default(),
                pwd: p.local_video_pwd.clone().unwrap_or_default(),
            },
            ice::IceCredentials {
                ufrag: vid.ice_ufrag,
                pwd: vid.ice_pwd,
            },
            p.controlling,
        );
        let ice_fut = vid_agent.check_connectivity(video_sock.clone(), &vid_cands);
        let addr = tokio::select! {
            r = ice_fut => r.map(|c| Some(c.remote_addr)).unwrap_or_else(|_| {
                ice::select_remote_candidate(&vid_cands)
            }),
            _ = wait_shutdown(&shutdown) => return Ok(()),
        };
        if let Some(a) = addr {
            let mut s = lock(engine_stats());
            s.ice_video = a.to_string();
        }
        addr
    } else {
        None
    };

    // Audio devices (cpal; tone fallback when no mic).
    let (_capture, mic_rx) = ost::calling::audio::AudioCapture::start()
        .map(|(c, rx)| (Some(c), Some(rx)))
        .unwrap_or((None, None));
    let (_playback, speaker_tx) = ost::calling::audio::AudioPlayback::start()
        .map(|(pb, tx)| (Some(pb), Some(tx)))
        .unwrap_or((None, None));
    // Keep device guards alive for the whole drive.
    let _devices = (_capture, _playback);

    let send_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpSendStats::default()));
    let recv_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpRecvStats::default()));
    let remote_ssrc = std::sync::Arc::new(AMutex::new(0u32));
    let vid_send_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpSendStats::default()));
    let vid_recv_stats = std::sync::Arc::new(AMutex::new(rtcp::RtpRecvStats::default()));
    let vid_remote_ssrc = std::sync::Arc::new(AMutex::new(0u32));
    let dyn_remote = std::sync::Arc::new(AMutex::new(audio_remote));
    let recorder = std::sync::Arc::new(AMutex::new(test_tone::AudioRecorder::new(8 * 8000)));

    let ssrc = (now_secs() as u32) ^ 0x51ab_0000;
    send_stats.lock().await.ssrc = ssrc;
    vid_send_stats.lock().await.ssrc = p.video_ssrc;

    let mut tasks = Vec::new();

    // -- audio send (mic > tone, 20ms) --
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let stats = send_stats.clone();
        let dyn_remote = dyn_remote.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut tone = test_tone::ToneGenerator::new();
            let mut seq: u16 = 0;
            let mut ts: u32 = 0;
            let mut interval = tokio::time::interval(Duration::from_millis(20));
            while !flag.load(Ordering::Relaxed) {
                interval.tick().await;
                let samples = match mic_rx.as_ref().and_then(|rx| rx.try_recv().ok()) {
                    Some(s) if s.len() == rtp::SAMPLES_PER_PACKET => s,
                    _ => tone.next_frame(),
                };
                let payload: Vec<u8> =
                    samples.iter().map(|&s| rtp::linear_to_ulaw(s)).collect();
                let rtp_pkt = rtp::encode(rtp::PT_PCMU, seq, ts, ssrc, &payload);
                let wire = {
                    let mut c = ctx.lock().await;
                    srtp::protect(&mut c, &rtp_pkt)
                };
                if let Ok(wire) = wire {
                    let addr = *dyn_remote.lock().await;
                    if socket.send_to(&wire, addr).await.is_ok() {
                        let mut st = stats.lock().await;
                        st.packets_sent += 1;
                        st.bytes_sent += payload.len() as u32;
                        st.last_rtp_timestamp = ts;
                        stat_add(|s| s.audio_sent += 1);
                    }
                }
                seq = seq.wrapping_add(1);
                ts = ts.wrapping_add(160);
            }
        }));
    }

    // -- audio recv (STUN/SRTCP/RTP; speaker + echo record) --
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let stats = recv_stats.clone();
        let rssrc = remote_ssrc.clone();
        let rec = recorder.clone();
        let dyn_remote = dyn_remote.clone();
        let local_pwd = p.local_audio_pwd.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut buf = [0u8; 2048];
            while !flag.load(Ordering::Relaxed) {
                let got = tokio::time::timeout(
                    Duration::from_millis(500),
                    socket.recv_from(&mut buf),
                )
                .await;
                let (len, from) = match got {
                    Ok(Ok(v)) => v,
                    _ => continue,
                };
                let data = &buf[..len];
                if len >= 20 && ice::is_stun_message(data) {
                    if ice::is_stun_request(data) {
                        if let Some(txn) = ice::get_transaction_id(data) {
                            let resp = ice::build_binding_response(
                                &txn,
                                from,
                                Some(local_pwd.as_bytes()),
                            );
                            let _ = socket.send_to(&resp, from).await;
                        }
                        let mut dr = dyn_remote.lock().await;
                        *dr = from;
                    }
                    continue;
                }
                if let Ok(rtcp_data) = {
                    let mut c = ctx.lock().await;
                    srtp::unprotect_rtcp(&mut c, data).map_err(|_| ())
                } {
                    for block in rtcp::parse_rtcp(&rtcp_data) {
                        if let rtcp::RtcpBlock::SenderReport { ntp_timestamp, .. } = block {
                            let mut rs = stats.lock().await;
                            rs.last_sr_ntp = ((ntp_timestamp >> 16) & 0xFFFF_FFFF) as u32;
                            rs.last_sr_recv_time = Some(std::time::Instant::now());
                        }
                    }
                    continue;
                }
                let rtp_data = {
                    let mut c = ctx.lock().await;
                    srtp::unprotect(&mut c, data)
                };
                let rtp_data = match rtp_data {
                    Ok(d) => d,
                    Err(_) => continue,
                };
                if let Ok(pkt) = rtp::decode(&rtp_data) {
                    {
                        let mut rs = stats.lock().await;
                        rs.packets_received += 1;
                        if pkt.sequence_number as u32 > rs.highest_seq {
                            rs.highest_seq = pkt.sequence_number as u32;
                        }
                    }
                    stat_add(|s| s.audio_recv += 1);
                    {
                        let mut r = rssrc.lock().await;
                        if *r == 0 {
                            *r = pkt.ssrc;
                        }
                    }
                    let samples: Vec<i16> =
                        pkt.payload.iter().map(|&b| rtp::ulaw_to_linear(b)).collect();
                    rec.lock().await.push_frame(&samples);
                    if let Some(ref tx) = speaker_tx {
                        let _ = tx.try_send(samples);
                    }
                }
            }
        }));
    }

    // -- audio RTCP (5s, 250ms-granular shutdown) --
    {
        let socket = audio_sock.clone();
        let ctx = audio_ctx.clone();
        let ss = send_stats.clone();
        let rs = recv_stats.clone();
        let rssrc = remote_ssrc.clone();
        let dyn_remote = dyn_remote.clone();
        let cname = p.cname.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut ticks = 0u32;
            while !flag.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_millis(250)).await;
                ticks += 1;
                if ticks < 20 {
                    continue;
                }
                ticks = 0;
                let s = ss.lock().await.clone();
                let r = rs.lock().await.clone();
                let remote = *rssrc.lock().await;
                let pkt = if s.packets_sent > 0 {
                    rtcp::build_sender_report(&s, &r, remote, &cname)
                } else {
                    rtcp::build_receiver_report(s.ssrc, &r, remote, &cname)
                };
                let mut c = ctx.lock().await;
                if let Ok(wire) = srtp::protect_rtcp(&mut c, &pkt) {
                    let addr = *dyn_remote.lock().await;
                    let _ = socket.send_to(&wire, addr).await;
                }
            }
        }));
    }

    // -- video send (NAL queue > black IDR, ~15fps) --
    if let (Some(vctx), Some(vaddr)) =
        (video_pair.as_ref().map(|(c, _, _)| c.clone()), video_remote)
    {
        let socket = video_sock.clone();
        let stats = vid_send_stats.clone();
        let vssrc = p.video_ssrc;
        let vctx_send = vctx.clone();
        let flag = shutdown.clone();
        tasks.push(tokio::spawn(async move {
            let mut packetizer = video::VideoPacketizer::new(vssrc);
            let mut interval =
                tokio::time::interval(Duration::from_millis(video::FRAME_INTERVAL_MS));
            while !flag.load(Ordering::Relaxed) {
                interval.tick().await;
                let nals = take_send_latest()
                    .map(|u| u.nals)
                    .unwrap_or_else(video::generate_black_iframe);
                for rtp_pkt in packetizer.packetize_frame(&nals) {
                    let ts = if rtp_pkt.len() >= 8 {
                        u32::from_be_bytes([rtp_pkt[4], rtp_pkt[5], rtp_pkt[6], rtp_pkt[7]])
                    } else {
                        0
                    };
                    let paylen = rtp_pkt.len().saturating_sub(rtp::RTP_HEADER_SIZE);
                    let wire = {
                        let mut c = vctx_send.lock().await;
                        srtp::protect(&mut c, &rtp_pkt)
                    };
                    if let Ok(wire) = wire {
                        if socket.send_to(&wire, vaddr).await.is_ok() {
                            let mut st = stats.lock().await;
                            st.packets_sent += 1;
                            st.bytes_sent += paylen as u32;
                            st.last_rtp_timestamp = ts;
                            stat_add(|s| s.video_sent += 1);
                        }
                    }
                }
            }
        }));

        // -- video recv (SRTP -> depacketize -> AU framing -> incoming queue) --
        {
            let socket = video_sock.clone();
            let vctx = vctx.clone();
            let stats = vid_recv_stats.clone();
            let rssrc = vid_remote_ssrc.clone();
            let vid_pwd = video_pair.as_ref().map(|(_, _, pwd)| pwd.clone()).unwrap_or_default();
            let flag = shutdown.clone();
            tasks.push(tokio::spawn(async move {
                let mut buf = [0u8; 2048];
                let mut depacketizer = video::VideoDepacketizer::new();
                let mut au: Vec<Vec<u8>> = Vec::new();
                while !flag.load(Ordering::Relaxed) {
                    let got = tokio::time::timeout(
                        Duration::from_millis(500),
                        socket.recv_from(&mut buf),
                    )
                    .await;
                    let (len, from) = match got {
                        Ok(Ok(v)) => v,
                        _ => continue,
                    };
                    let data = &buf[..len];
                    if len >= 20 && ice::is_stun_message(data) {
                        if ice::is_stun_request(data) {
                            if let Some(txn) = ice::get_transaction_id(data) {
                                let resp = ice::build_binding_response(
                                    &txn,
                                    from,
                                    Some(vid_pwd.as_bytes()),
                                );
                                let _ = socket.send_to(&resp, from).await;
                            }
                        }
                        continue;
                    }
                    {
                        let mut c = vctx.lock().await;
                        if let Ok(rtcp_data) = srtp::unprotect_rtcp(&mut c, data) {
                            let mut rs = stats.lock().await;
                            for block in rtcp::parse_rtcp(&rtcp_data) {
                                if let rtcp::RtcpBlock::SenderReport { ntp_timestamp, .. } =
                                    block
                                {
                                    rs.last_sr_ntp =
                                        ((ntp_timestamp >> 16) & 0xFFFF_FFFF) as u32;
                                    rs.last_sr_recv_time = Some(std::time::Instant::now());
                                }
                            }
                            continue;
                        }
                    }
                    let rtp_data = {
                        let mut c = vctx.lock().await;
                           srtp::unprotect(&mut c, data)
                    };
                    let rtp_data = match rtp_data {
                        Ok(d) => d,
                        Err(_) => continue,
                    };
                    if let Ok(pkt) = rtp::decode(&rtp_data) {
                        {
                            let mut rs = stats.lock().await;
                            rs.packets_received += 1;
                            if pkt.sequence_number as u32 > rs.highest_seq {
                                rs.highest_seq = pkt.sequence_number as u32;
                            }
                        }
                        stat_add(|s| s.video_recv += 1);
                        {
                            let mut r = rssrc.lock().await;
                            if *r == 0 {
                                *r = pkt.ssrc;
                            }
                        }
                        match depacketizer.depacketize(&pkt.payload, pkt.marker) {
                            Ok(Some(nal)) => {
                                if !is_wrapper_nal(&nal) {
                                    au.push(nal);
                                }
                                if pkt.marker && !au.is_empty() {
                                    push_recv(RecvUnit { nals: std::mem::take(&mut au) });
                                }
                            }
                            Ok(None) => {}
                            Err(_) => {}
                        }
                    }
                }
            }));
        }

        // -- video RTCP (5s) --
        {
            let socket = video_sock.clone();
            let stats = vid_send_stats.clone();
            let rs = vid_recv_stats.clone();
            let rssrc = vid_remote_ssrc.clone();
            let cname = p.cname.clone();
            let flag = shutdown.clone();
            tasks.push(tokio::spawn(async move {
                let mut ticks = 0u32;
                while !flag.load(Ordering::Relaxed) {
                    tokio::time::sleep(Duration::from_millis(250)).await;
                    ticks += 1;
                    if ticks < 20 {
                        continue;
                    }
                    ticks = 0;
                    let s = stats.lock().await.clone();
                    let r = rs.lock().await.clone();
                    let remote = *rssrc.lock().await;
                    let pkt = if s.packets_sent > 0 {
                        rtcp::build_sender_report(&s, &r, remote, &cname)
                    } else {
                        rtcp::build_receiver_report(s.ssrc, &r, remote, &cname)
                    };
                    let mut c = vctx.lock().await;
                    if let Ok(wire) = srtp::protect_rtcp(&mut c, &pkt) {
                        let _ = socket.send_to(&wire, vaddr).await;
                    }
                }
            }));
        }
    }

    // Park until shutdown, then abort loops.
    wait_shutdown(&shutdown).await;
    for t in &tasks {
        t.abort();
    }
    Ok(())
}

async fn wait_shutdown(flag: &std::sync::Arc<AtomicBool>) {
    while !flag.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

// ---------------------------------------------------------------------------
// C ABI (caller frees every return with `ostmac_free`)
// ---------------------------------------------------------------------------

#[no_mangle]
pub extern "C" fn ostmac_video_send_push(nals_json: *const std::os::raw::c_char) -> *mut std::os::raw::c_char {
    match crate::cstr_to_string(nals_json) {
        Ok(s) => string_to_c(video_send_push_json(&s)),
        Err(e) => string_to_c(err_json("arg", e)),
    }
}

#[no_mangle]
pub extern "C" fn ostmac_video_poll_incoming() -> *mut std::os::raw::c_char {
    string_to_c(video_incoming_poll_json())
}

#[no_mangle]
pub extern "C" fn ostmac_call_media() -> *mut std::os::raw::c_char {
    string_to_c(call_media_json())
}

#[no_mangle]
pub extern "C" fn ostmac_call_media_stop() -> *mut std::os::raw::c_char {
    string_to_c(call_media_stop_json())
}

#[no_mangle]
pub extern "C" fn ostmac_live_loopback() -> *mut std::os::raw::c_char {
    string_to_c(live_loopback_json())
}

// ---------------------------------------------------------------------------
// Tests (deterministic: no network/auth/hardware; queues drained per test)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn drain_queues() {
        lock(send_queue()).clear();
        lock(recv_queue()).clear();
    }

    fn b64(nal: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(nal)
    }

    #[test]
    fn send_push_validates_args() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // Not JSON.
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_json("nope")).unwrap();
        assert_eq!(v["ok"], false);
        // Empty array / too many.
        let v: serde_json::Value = serde_json::from_str(&video_send_push_json("[]")).unwrap();
        assert_eq!(v["ok"], false);
        // Bad base64.
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_json(r#"["!!!"]"#)).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "arg");
        drain_queues();
    }

    #[test]
    fn send_push_caps_drop_oldest() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let one = format!(r#"["{}"]"#, b64(&[0x67, 0x42, 0x00]));
        for _ in 0..(SEND_QUEUE_CAP + 3) {
            let v: serde_json::Value =
                serde_json::from_str(&video_send_push_json(&one)).unwrap();
            assert_eq!(v["ok"], true);
        }
        assert_eq!(lock(send_queue()).len(), SEND_QUEUE_CAP);
        drain_queues();
    }

    #[test]
    fn incoming_poll_null_then_latest() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let v: serde_json::Value =
            serde_json::from_str(&video_incoming_poll_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["au"].is_null());
        // Wrapper NALs (PACSI 30, prefix 14) are stripped for VT.
        push_recv(RecvUnit {
            nals: vec![vec![0x1E, 0x00], vec![0x0E, 0x00], vec![0x67, 0x42]],
        });
        let v: serde_json::Value =
            serde_json::from_str(&video_incoming_poll_json()).unwrap();
        assert_eq!(v["au"]["nals"].as_array().unwrap().len(), 1);
        let v: serde_json::Value =
            serde_json::from_str(&video_incoming_poll_json()).unwrap();
        assert!(v["au"].is_null());
        drain_queues();
    }

    #[test]
    fn loopback_black_frame_roundtrips() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // Black IDR [SPS, PPS, IDR] through the real engine data path.
        let nals: Vec<String> = video::generate_black_iframe()
            .iter()
            .map(|n| b64(n))
            .collect();
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_json(&serde_json::to_string(&nals).unwrap()))
                .unwrap();
        assert_eq!(v["ok"], true);
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["units"], 1);
        assert!(v["packets"].as_u64().unwrap() >= 5); // PACSI + prefix + 3 NALs
        assert_eq!(v["aus"], 1);
        assert_eq!(v["nals"], 3); // SPS + PPS + IDR (wrappers stripped)
        // The AU is pollable for the Swift decode join.
        let v: serde_json::Value =
            serde_json::from_str(&video_incoming_poll_json()).unwrap();
        let got = v["au"]["nals"].as_array().unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[0], nals[0]); // SPS bit-identical
        assert_eq!(got[2], nals[2]); // IDR bit-identical
        drain_queues();
    }

    #[test]
    fn loopback_fragmented_slice_reassembles() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        // 4000-byte IDR slice forces FU-A fragmentation across RTP packets.
        let mut idr = vec![0x65u8];
        idr.extend((0..3999u32).map(|i| (i % 251) as u8));
        let sps = vec![0x67u8, 0x42, 0x00, 0x1E];
        let pps = vec![0x68u8, 0xCE, 0x06, 0xE2];
        let arr = vec![b64(&sps), b64(&pps), b64(&idr)];
        let v: serde_json::Value =
            serde_json::from_str(&video_send_push_json(&serde_json::to_string(&arr).unwrap()))
                .unwrap();
        assert_eq!(v["ok"], true);
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert!(v["packets"].as_u64().unwrap() >= 5);
        assert_eq!(v["aus"], 1);
        let v: serde_json::Value =
            serde_json::from_str(&video_incoming_poll_json()).unwrap();
        let got = v["au"]["nals"].as_array().unwrap();
        assert_eq!(got.len(), 3);
        assert_eq!(got[2], arr[2]); // reassembled IDR bit-identical
        drain_queues();
    }

    #[test]
    fn loopback_empty_queue_is_error() {
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        let v: serde_json::Value = serde_json::from_str(&live_loopback_json()).unwrap();
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "empty");
    }

    #[test]
    fn media_stats_idle_shape() {
        let v: serde_json::Value = serde_json::from_str(&call_media_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["media"]["running"], false);
        assert!(v["media"]["audio_sent"].is_number());
        assert!(v["media"]["video_recv"].is_number());
    }

    #[test]
    fn media_stop_idle_is_ok() {
        let v: serde_json::Value = serde_json::from_str(&call_media_stop_json()).unwrap();
        assert_eq!(v["ok"], true);
        assert_eq!(v["media"]["running"], false);
    }

    #[test]
    fn ffi_push_null_is_arg_error() {
        unsafe {
            let p = ostmac_video_send_push(std::ptr::null());
            assert!(!p.is_null());
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["ok"], false);
            assert_eq!(v["error"], "arg");
        }
    }

    #[test]
    fn ffi_poll_roundtrip_shape() {
        use std::os::raw::c_char;
        let _t = test_lock();
        let _c = crate::calls::test_lock();
        drain_queues();
        unsafe {
            let one = CString::new(format!(r#"["{}"]"#, b64(&[0x67, 0x42]))).unwrap();
            let p = ostmac_video_send_push(one.as_ptr() as *const c_char);
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["ok"], true);
            let p = ostmac_live_loopback();
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            assert_eq!(serde_json::from_str::<serde_json::Value>(&s).unwrap()["aus"], 1);
            let p = ostmac_video_poll_incoming();
            let s = std::ffi::CStr::from_ptr(p).to_string_lossy().into_owned();
            crate::ostmac_free(p);
            let v: serde_json::Value = serde_json::from_str(&s).unwrap();
            assert_eq!(v["au"]["nals"].as_array().unwrap().len(), 1);
        }
        drain_queues();
    }
}
