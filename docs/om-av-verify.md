# om-av-verify: live A/V hardware truth (diagnostic lane, no fixes)

Date: 2026-09-23. Box: owner MacBook Pro, docked (Dell U2723QE), lid
**closed** (`AppleClamshellState = Yes`), iPhone Continuity attached,
BoomAudio virtual driver = system default output. TCC: mic + camera
**authorized**. Lane branch `lanes/om-av-verify`; probes ran from
`tmp/wt-om-av-verify` (cpal 0.15.3, CoreAudio).

## Verdicts

| Device / path | Verdict | Evidence |
|---|---|---|
| Mic hardware (MacBook Pro Microphone) | **WORKING** | ffmpeg AVFoundation 1.0 s capture, 37376 samples, max_volume **-91.0 dB** room tone; cpal F32 HAL stream builds + plays + delivers 512-sample callbacks |
| OstMac mic path (`mic_test_report`) | **BROKEN** | `mic_test` → `no_input`; `mic_level` 3× `has_input:false, peak_db:-60.0`; every named input → `unknown_device` after ~10 s poll timeout |
| Speaker hardware (BoomAudio default out) | **WORKING** | `afplay Glass.aiff` 2.3 s, exit 0; cpal F32 6ch + mono builds + plays OK |
| OstMac tone path (`play_tone`) | **BROKEN** | `tone_play` → `no_output` after 10.05 s; named `BoomAudio` → `unknown_device` after 13.93 s |
| Echo self-check (`tone_check`) | **WORKING** | deterministic, no hardware: `detected:true delay_ms:50.0 corr:1.0000` |
| Call dry-run (offline pipeline) | **WORKING** | `audio 25/25 echo_detected:true video 5pkts/5nals` |
| Device pickers (audio enumeration) | **WORKING** | 5 inputs (`USB3 Digital Audio`, `VEC-LRX-45 USB`, `MacBook Pro Microphone` default, `iPhone Microphone`, `BoomAudio`) + 1 output (`BoomAudio` default); matches system_profiler + ffmpeg lists. Slow: 2.63 s |
| Camera picker (video enumeration) | **WORKING** | `iPhone Camera` + `FaceTime HD Camera`, both `connected=true` |
| Camera iPhone (Continuity) | **WORKING** | 1920×1080 real frames, meanR 111–125, 5 frames/4 s; see `docs/shots/om-av-verify-iphone.png` |
| Camera FaceTime HD (built-in) | **BROKEN (environmental)** | 0 frames in 4 s (×2 runs, identical code as iPhone); ffmpeg open → `Input/output error`. Lid closed; not an OstMac bug. Retest with lid open |

## Root cause (mic + speaker): cpal rejects i16 on this box

Minimal cpal probe (no ost code), all else equal:

- F32 + default config on MacBook mic: **OK**, `play: Ok(())`
- F32 + default 6ch on BoomAudio: **OK**; F32 + mono-forced: **OK**
- i16 + mono (exactly ost-style): **ERROR: stream configuration not supported**

ost `audio.rs` uses `&[i16]`/`&mut [i16]` callbacks everywhere, so every
open fails; the 10 s `poll_started` timeout is the only failure signal
(`mic_probe` costs 20.04 s = 2 timeouts).

## Fast-follow (not fixed in this lane)

1. **F32 audio path**: build cpal streams as F32, convert to i16
   20 ms frames in the callback accumulator (`audio.rs`).
2. **`unknown_device` mislabels open failures**: named devices that
   *resolved* fine report `unknown_device` when the stream build
   fails/times out — the panel then "heals" a healthy pick. Split
   resolve-fail from open-fail.
3. **Fail fast on build error**: surface `build_*_stream` errors
   instead of only the ~10 s poll timeout (mic test + meter + probe
   all hang a full budget per call).
4. **Retest FaceTime HD with the lid open**; retest mic dB numbers
   with speech after F32 lands (room was silent: -91 dB floor).

## Suite

- `cargo test -j2` ost: exit 0, 145 passed, 0 failed.
- `cargo test -j2` ostmac-core: exit 0, 123 passed, 0 failed.
- `swift test`: exit 0, 755 tests, 0 failures (incl. 9 new AvVerifyTests).
- Added only non-hardware unit tests:
  `swift/Tests/OstMacCoreTests/AvVerifyTests.swift` (pure JSON
  decode + camera status words; no device asserted).

Raw probe logs (scratch, not committed): `tmp/om-av-verify-audio*.log`,
`tmp/om-av-verify-camera*.png`, `tmp/cpal-probe/`, `tmp/om-av-verify-cam.swift`.

## Re-verified 2026-09-24 (same box, same lane, no code changes)

All verdicts above reproduced live; timed ostmac-core probe
(`tmp/om-av-verify2-audio.log`):

- Mic hw: ffmpeg 1 s capture `max_volume: -91.0 dB`
  (`mean_volume: -91.0 dB`, 38912 samples) — WORKING.
- OstMic: `mic_test` → `no_input` (10.01 s); named
  `MacBook Pro Microphone` → `unknown_device` (10.36 s);
  `mic_level` 3× `peak_db:-60.0` (10.02 s each) — BROKEN.
- `teams-cli mic-test` (exit 1): resolves
  `Audio input device: MacBook Pro Microphone`, then
  `Failed to build audio input stream: The requested stream
  configuration is not supported by the device` → `Error: No
  audio input device found`. Resolve-OK / open-fail, mislabeled.
- Named-real vs bogus timing split: real names take the ~10 s
  open timeout; `ostmac-no-such-device` fails fast (0.76 s in /
  0.27 s out) — resolve-fail and open-fail are distinguishable,
  supporting fast-follow #2.
- Speaker hw: `afplay Glass.aiff` exit 0, 3.5 s — WORKING.
  OstTone: `tone_play` → `no_output` (10.01 s); named
  `BoomAudio` → `unknown_device` (10.40 s) — BROKEN.
- `tone_check`: `detected:true delay_ms:50.0
  corr:1.0000` — WORKING. `dry_run`: `25/25 echo:true
  5pkts/5nals` — WORKING. `mic_probe`: `input:false
  output:false` (20.21 s = 2 timeouts).
- `audio_devices`: identical 5 inputs + 1 output, same
  defaults (2.02 s) — picker WORKING. Camera discovery lists
  `iPhone Camera` + `FaceTime HD Camera`, both
  `connected=true` — picker WORKING.
- iPhone capture: first 4 s window 0 frames (Continuity
  warmup), retry 1 frame 1920×1080 meanR=97.6, 1.9 MB PNG
  (`tmp/om-av-verify2-iphone.png`; committed
  `docs/shots/om-av-verify-iphone.png` from prior run stands) —
  WORKING but first-open flaky.
- FaceTime HD: 0 frames in 4 s, exit 5; single external
  display online (lid closed) — BROKEN (environmental).
- cpal re-run: F32 mic in OK + play Ok, F32 BoomAudio 6ch
  OK, F32 mono OK, i16 ost-style ERROR
  (`stream configuration not supported`) — root cause holds.
- Suite: ost exit 0 (145 passed), ostmac-core exit 0
  (123 passed), `swift test` exit 0 (755 tests, 0 failures).
