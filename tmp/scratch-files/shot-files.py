#!/usr/bin/env python3
# shot-files.py — top10-files lane: launch demo app on the Files surface,
# capture the main window; relaunch with QuickLook preview, capture the
# QL panel. Offline only (demo seeds, tmp fabrications).
import subprocess, sys, time, os

WT = "/Users/mrowlinson/Projects/BetterTeams/tmp/wt-top10-files"
SCRATCH = os.path.join(WT, "tmp/scratch-files")
APP = os.path.join(SCRATCH, "FilesShot.app")
BIN = os.path.join(APP, "Contents/MacOS/OstMac")
SHOT_MAIN = os.path.join(WT, "docs/shots/top10-files-recents.png")
SHOT_QL = os.path.join(WT, "docs/shots/top10-files-quicklook.png")
WINLIST_MAIN = "/Users/mrowlinson/Projects/BetterTeams/tmp/winlist.swift"

def run(*argv, cwd=None):
    r = subprocess.run(argv, capture_output=True, text=True, cwd=cwd)
    if r.returncode != 0:
        print("CMD FAILED:", argv, r.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    return r

def winlist(pid):
    r = subprocess.run(["swift", WINLIST_MAIN, str(pid)],
                       capture_output=True, text=True,
                       cwd=os.path.join(WT, "swift"))
    return [ln for ln in r.stdout.strip().split("\n") if ln.strip()]

def area(ln):
    try:
        wh = ln.split()[1]
        w, h = wh.split("x")
        return int(w) * int(h)
    except Exception:
        return 0

def launch(args):
    subprocess.run(["rm", "-rf", os.path.expanduser(
        "~/Library/Saved Application State/dev.ostmac.OstMac.savedState")])
    subprocess.run(["defaults", "write", "dev.ostmac.OstMac",
                    "NSQuitAlwaysKeepsWindows", "-bool", "false"])
    return subprocess.Popen(
        [BIN] + args + ["-ApplePersistenceIgnoreState", "YES"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

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
run("codesign", "--force", "--deep", "--sign", "-", APP)

# --- Shot 1: recents view ---
print("launch --show-files...", flush=True)
proc = launch(["--show-files"])
try:
    winid = None
    for _ in range(30):
        time.sleep(1)
        rows = winlist(proc.pid)
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
    time.sleep(2)
    run("screencapture", "-l" + winid, "-x", SHOT_MAIN)
    print("shot:", SHOT_MAIN, os.path.getsize(SHOT_MAIN), "bytes")
finally:
    stop(proc)

time.sleep(2)

# --- Shot 2: QuickLook panel ---
print("launch --show-files-preview...", flush=True)
proc = launch(["--show-files-preview"])
try:
    qlid = None
    for _ in range(30):
        time.sleep(1)
        rows = winlist(proc.pid)
        # QL panels carry no window name: the panel is the largest
        # window that ISN'T the main window (main > 200k px here).
        small = sorted(
            [ln for ln in rows if 30_000 < area(ln) <= 200_000],
            key=area, reverse=True)
        if small:
            qlid = small[0].split()[0]
            print("ql:", small[0], flush=True)
            break
        if proc.poll() is not None:
            print("app exited early", file=sys.stderr)
            sys.exit(1)
    if qlid is None:
        print("windows seen:", file=sys.stderr)
        for ln in winlist(proc.pid):
            print("  ", ln, file=sys.stderr)
        print("no QuickLook window found", file=sys.stderr)
        sys.exit(1)
    time.sleep(1)
    run("screencapture", "-l" + qlid, "-x", SHOT_QL)
    print("shot:", SHOT_QL, os.path.getsize(SHOT_QL), "bytes")
finally:
    stop(proc)
print("done")
