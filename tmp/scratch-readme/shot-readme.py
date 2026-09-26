#!/usr/bin/env python3
# shot-readme.py — readme-refresh lane: fresh hero shots from current demo.
# Offline only (--demo variants). Window-ID captures, never activated.
import subprocess, sys, time, os

WT = "/Users/mrowlinson/Projects/BetterTeams/tmp/wt-readme-refresh"
SCRATCH = os.path.join(WT, "tmp/scratch-readme")
APP = os.path.join(SCRATCH, "ReadmeShot.app")
BIN = os.path.join(APP, "Contents/MacOS/OstMac")
WINLIST = os.path.join(WT, "tmp/winlist.swift")

SHOTS = [
    ("readme-hero-main.png", ["--demo-rich"]),
    ("readme-hero-code.png", ["--show-code"]),
    ("readme-hero-teams.png", ["--demo", "--show-teams"]),
]

def run(*argv, cwd=None):
    r = subprocess.run(argv, capture_output=True, text=True, cwd=cwd)
    if r.returncode != 0:
        print("CMD FAILED:", argv, r.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    return r

def winlist(pid):
    r = subprocess.run(["swift", WINLIST, str(pid)],
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

def try_resize(pid, w=1600, h=1000):
    script = (f'tell application "System Events" to tell '
              f'(first process whose unix id is {pid}) to set size of '
              f'front window to {{{w}, {h}}}')
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True)
    print("resize:", "ok" if r.returncode == 0 else r.stderr.strip()[:200],
          flush=True)

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

only = sys.argv[1:] or None
for name, args in SHOTS:
    if only and name not in only and name.replace("readme-", "") not in only:
        continue
    out = os.path.join(WT, "docs/shots", name)
    print(f"launch {args} -> {name}...", flush=True)
    proc = launch(args)
    try:
        winid = None
        for i in range(30):
            time.sleep(1)
            rows = winlist(proc.pid)
            rows.sort(key=area, reverse=True)
            big = [ln for ln in rows if area(ln) > 200_000]
            if big:
                winid = big[0].split()[0]
                print("window:", big[0], flush=True)
                break
            if proc.poll() is not None:
                print("APP EXITED EARLY", flush=True)
                sys.exit(1)
        if not winid:
            print("NO WINDOW", flush=True)
            sys.exit(1)
        try_resize(proc.pid)
        time.sleep(1)
        rows = winlist(proc.pid)
        rows.sort(key=area, reverse=True)
        if rows:
            winid = rows[0].split()[0]
            print("window-after-resize:", rows[0], flush=True)
        time.sleep(2)
        run("screencapture", "-l", winid, "-x", out)
        print("saved:", out, os.path.getsize(out), flush=True)
    finally:
        stop(proc)
    time.sleep(1)
print("done", flush=True)
