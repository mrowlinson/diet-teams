//! Manual probe: status, trouter-start code, device-code start (network).
//! `cargo run --example probe` (unsigned env expected: trouter -2).

fn main() {
    println!("version: {}", env!("CARGO_PKG_VERSION"));
    println!("status: {}", ostmac_core::status_json());
    println!("trouter_start: {}", ostmac_core::trouter_start());
    println!("trouter_poll: {}", ostmac_core::trouter_poll_json());
    println!("trouter_stop: {}", ostmac_core::trouter_stop());
    if std::env::var("OSTMAC_PROBE_DEVICE").is_ok() {
        let s = ostmac_core::device_start_json();
        println!("device_start: {}", s);
        if let Some(sess) = serde_json::from_str::<serde_json::Value>(&s)
            .ok()
            .and_then(|v| v["session"].as_str().map(|x| x.to_string()))
        {
            println!("device_poll: {}", ostmac_core::device_poll_json(&sess));
        }
    } else {
        println!("device_start: skipped (set OSTMAC_PROBE_DEVICE=1)");
    }
}
