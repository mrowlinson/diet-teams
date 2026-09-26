# HARNESS-BUILD-PROOF (lanes/perf-harness-build, base e87c64f)

## TOP-5 (numbers + disk paths)
1. launch_ms=3527, wid=2486 (winlist resolve, demo; no capture needed)
2. ARRIVE inject chatID=demo msgId=arrive-1 open=demo (hook fired into OPEN chat)
3. ARRIVE done posted=1 skipped=0 last=chat-message (real handleRealtime path)
4. ARRIVE inject-edit editedID=arrive-1 +2.1s (--demo-arrive-edit follow-up works)
5. FRAME SMOKE BLOCKED (env): screencapture hangs 30s+ full-screen and -l;
   other lane's capture also stuck 87s+ no output. Agent tree = tmux (no TCC
   GUI owner). settle_index unit probe 3/3 (1/-1/0). Resume: run smoke from
   Terminal.app with Screen Recording granted.
- harness: tmp/wt-perf-harness-build/tmp/frame-harness.py
- winlist: tmp/wt-perf-harness-build/tmp/winlist (.swift seed beside it)
- hook: tmp/wt-perf-harness-build/swift/Sources/OstMac/App.swift (arrive*)
- arrive log: $TMPDIR/om-arrive-proof.jsonl (transient; quoted above)
- frames dir (empty, blocked): tmp/wt-perf-harness-build/tmp/perf-frames/

## What was built
- tmp/frame-harness.py: proto + settle idx (3-equal run), per-shot ms +
  max/mean, FAST trigger (mean>500), --fps/--secs/--settle-wait/--fast,
  tag dir tmp/perf-frames/<tag>/. Spec-exact per PARTIAL §2.
- App.swift delay hook (demo-only): --demo-arrive-after/--demo-arrive-text/
  --demo-arrive-edit; fires in openContentIfAllowed after showNotifLive
  block via handleRealtime into openChatID; ARRIVE logs (stdout+JSONL).
- winlist compiled: tmp/winlist (57KB).

## Verification detail
- Functional hook test (--demo-arrive-after 3 --demo-arrive-edit): all 3
  ARRIVE lines above; chatID==open proves right-chat targeting.
- Bad value (--demo-arrive-after banana): no ARRIVE file, clean exit.
  Flag absent: no-op (arriveAfter nil).
- Build: scripts/build-app.sh green (460s).
- Smoke command (for Terminal rerun):
  python3 tmp/frame-harness.py arrival -- --demo --demo-arrive-after 6
  PASS = STATS identical < frames-1.

## Scope exception (build fix, base red)
- e87c64f does not compile: calls.rs x2 calls
  TeamsRegion::from_env_or_default, removed by §57. Restored 8-line
  helper in rust/ost/src/calling/signaling.rs + ledger §58 [minor].
  Without it no lane can build.
