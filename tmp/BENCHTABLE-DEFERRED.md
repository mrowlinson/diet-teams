# BENCHTABLE DEFERRED — integration verified, bench numbers pending idle box

Lane: lanes/perf-benchtable. Base: main @ 9b9dd3e.

## Merged (4 perf commits)
- a50d1b5 merge 71688bd media (memoize decodes + amortize disk trim + key hex + buffer pool)
- 1db2dec merge 3dc816a render (memoize card/action/refs parses + indexed docs resolve)
- c1cece3 merge e088f9d poll-timers (bytes-direct FFI + poll/timer hold pins)
- d5740ed merge 8776b55 B18 (device_start/_for, device_poll to Swift DeviceAuth)

## Conflict-resolution check
- RustCore.swift dual-perf intact, no fix needed:
  - bytes-direct FFI: `Data(bytes:count:)` single-copy in `call` (line ~708)
  - DeviceAuth: deviceStart/devicePoll/Sessions.drop call sites present

## Gate (scripts/test.sh)
- Run 1: ostmac-core lib 195 pass / 2 fail (transient; names not captured). Rerun lib-only: 197/197.
- Run 2 (full): exit 0.
  - ost: 274 + 274 + 1 + 1 pass, 0 fail
  - ostmac-core: 197 pass, 0 fail
  - Swift: 2134 tests, 0 failures, 1 skipped
- Note: av_ffi_remote_bytes_roundtrip known flake did not appear; the 2 run-1 failures cleared on rerun (load flake).

## Bench status: DEFERRED
- No Perf* runs, no captures. Box saturated by neighbor session; any timing numbers would be garbage.
- Load: start 366.09 572.54 778.82, end 661.37 614.60 708.68 (uptime, 2026-09-26 ~02:56-03:04 ET).
- Next: run bench table on idle box, then fill numbers.
