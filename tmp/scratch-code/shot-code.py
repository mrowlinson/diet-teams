#!/usr/bin/env python3
# shot-code.py — top10-code lane: launch demo app with a fenced Swift
# --say, capture the main window by id, terminate. Offline only.
import subprocess, sys, time, os, signal

WT = "/Users/mrowlinson/Projects/BetterTeams/tmp/wt-top10-code"
SCRATCH = os.path.join(WT, "tmp/scratch-code")
APP = os.path.join(SCRATCH, "CodeShot.app")
BIN = os.path.join(APP, "Contents/MacOS/OstMac")
SHOT = os.path.join(WT, "tmp/TOP10-CODE-SHOT.png")

SAY = ("Shipping the fix:\n"
       "```swift\n"
       "func greet(name: String) -> String {\n"
       "    // indent kept: 4sp\n"
       "    let line = \"hi \\(name)\"\n"
       "    return line\n"
       "}\n"
       "```")

def run(*argv, cwd=None):
    r = subprocess.run(argv, capture_output=True, text=True, cwd=cwd)
    if r.returncode != 0:
        print("CMD FAILED:", argv, r.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    return r

print("build...", flush=True)
run("swift", "build", "--product", "OstMac", cwd=os.path.join(WT, "swift"))
BIN_SRC = os.path.join(WT, "swift/.build/debug/OstMac")
os.makedirs(os.path.join(APP, "Contents/MacOS"), exist_ok=True)
os.makedirs(os.path.join(APP, "Contents/Resources"), exist_ok=True)
run("cp", BIN_SRC, BIN)
run("cp", os.path.join(WT, "swift/OstMac-Info.plist"),
    os.path.join(APP, "Contents/Info.plist"))
run("cp", os.path.join(WT, "swift/Resources/OstMac.icns"),
    os.path.join(APP, "Contents/Resources/OstMac.icns"))
open(os.path.join(APP, "Contents/PkgInfo"), "w").write("APPL????")
# Bundle seal (build-app.sh precedent): ad-hoc, taskgated needs _CodeSignature.
run("codesign", "--force", "--deep", "--sign", "-", APP)

print("launch...", flush=True)
# Clear crash-reopen state (our SIGKILL probes arm the "reopen windows?"
# dialog, which would steal the front window).
subprocess.run(["rm", "-rf", os.path.expanduser(
    "~/Library/Saved Application State/dev.ostmac.OstMac.savedState")])
subprocess.run(["defaults", "write", "dev.ostmac.OstMac",
                "NSQuitAlwaysKeepsWindows", "-bool", "false"])
proc = subprocess.Popen(
    [BIN, "--show-code", "-ApplePersistenceIgnoreState", "YES"],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    winid = None
    for _ in range(30):
        time.sleep(1)
        r = subprocess.run(["swift", os.path.join(WT, "tmp/winlist.swift"),
                            str(proc.pid)],
                           capture_output=True, text=True,
                           cwd=os.path.join(WT, "swift"))
        rows = [ln for ln in r.stdout.strip().split("\n") if ln.strip()]

        def area(ln):
            try:
                wh = ln.split()[1]
                w, h = wh.split("x")
                return int(w) * int(h)
            except Exception:
                return 0
        # Largest window wins (dialogs/popovers never outrank main).
        rows.sort(key=area, reverse=True)
        big = [ln for ln in rows if area(ln) > 200_000]
        if big:
            winid = big[0].split()[0]
            print("window:", big[0], flush=True)
            break
        if proc.poll() is not None:
            print("app exited early", file=sys.stderr)
            sys.exit(1)
    if winid is None:
        print("no window found", file=sys.stderr)
        sys.exit(1)
    time.sleep(2)  # let the timeline settle
    run("screencapture", "-l" + winid, "-x", SHOT)
    print("shot:", SHOT, os.path.getsize(SHOT), "bytes")
finally:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
print("done")
