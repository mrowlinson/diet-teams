#!/usr/bin/env python3
"""frame-harness: window-id frame-loop capture + STATS (base e87c64f).
Launch app, resolve window via winlist, screencapture -l loop, md5 STATS.
Usage: frame-harness.py <tag> [--fps N] [--secs N] [--settle-wait S]
                        [--fast] -- [extra-app-args...]
Out: tmp/perf-frames/<tag>/f-NNNN.png + STATS.txt. Never activates.
FAST trigger: mean shot ms > 500 -> use --fast (cgshot helper) instead.
"""
import argparse
import hashlib
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
APP = REPO + "/swift/.build/release/Better Teams.app/Contents/MacOS/OstMac"
WINLIST = HERE + "/winlist"
CGSHOT = HERE + "/cgshot"
OUTBASE = HERE + "/perf-frames"


def windows_of(pid):
    r = subprocess.run([WINLIST, str(pid)], capture_output=True, text=True)
    wins = []
    for line in r.stdout.splitlines():
        parts = line.split(" ", 2)
        if len(parts) < 2:
            continue
        try:
            wid = int(parts[0])
            w, h = (int(x) for x in parts[1].split("x"))
        except ValueError:
            continue
        wins.append((wid, w, h, parts[2] if len(parts) > 2 else ""))
    return wins


def settle_index(md5s):
    for i in range(len(md5s) - 2):
        if md5s[i] == md5s[i + 1] == md5s[i + 2]:
            return i
    return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tag")
    ap.add_argument("--fps", type=float, default=5)
    ap.add_argument("--secs", type=float, default=12)
    ap.add_argument("--settle-wait", type=float, default=0)
    ap.add_argument("--fast", action="store_true")
    ap.add_argument("extra", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    extra = [x for x in a.extra if x != "--"]

    grab = ["screencapture", "-x"]
    fast = a.fast
    if fast and not os.path.exists(CGSHOT):
        sys.exit("no cgshot helper; build cgshot.swift first")
    outdir = os.path.join(OUTBASE, a.tag)
    os.makedirs(outdir, exist_ok=True)
    for f in os.listdir(outdir):
        os.remove(os.path.join(outdir, f))
    subprocess.run(
        ["defaults", "write", "dev.ostmac.OstMac",
         "NSQuitAlwaysKeepsWindows", "-bool", "false"], check=False)
    args = [APP, "-ApplePersistenceIgnoreState", "YES"] + extra
    print("launch:", args, flush=True)
    t0 = time.monotonic()
    proc = subprocess.Popen(args)
    try:
        wins, t_win = [], None
        for _ in range(60):
            time.sleep(1)
            if proc.poll() is not None:
                sys.exit(f"APP EXITED EARLY {proc.returncode}")
            wins = windows_of(proc.pid)
            if any(w >= 800 for _, w, _, _ in wins):
                t_win = time.monotonic()
                break
        if t_win is None:
            sys.exit(f"no window; last={wins}")
        wid = max(
            [w for w in wins if w[1] >= 800] or wins,
            key=lambda t: t[1] * t[2])
        print(f"WID={wid[0]} {wid[1]}x{wid[2]} {wid[3]!r} "
              f"launch_ms={int((t_win - t0) * 1000)}", flush=True)
        if a.settle_wait > 0:
            time.sleep(a.settle_wait)
        period = 1.0 / a.fps
        n = int(a.fps * a.secs)
        shots = []
        t_start = time.monotonic()
        for i in range(n):
            tick = t_start + i * period
            now = time.monotonic()
            if tick > now:
                time.sleep(tick - now)
            out = os.path.join(outdir, f"f-{i:04d}.png")
            t_shot = time.monotonic()
            if fast:
                subprocess.run([CGSHOT, str(wid[0]), out], check=False)
            else:
                subprocess.run(grab + [f"-l{wid[0]}", out], check=False)
            shots.append((time.monotonic() - t_shot) * 1000)
        wall = time.monotonic() - t_start
        files = sorted(f for f in os.listdir(outdir) if f.endswith(".png"))
        sizes = [os.path.getsize(os.path.join(outdir, f)) for f in files]
        md5s = []
        for f in files:
            with open(os.path.join(outdir, f), "rb") as fh:
                md5s.append(hashlib.md5(fh.read()).hexdigest()[:12])
        runs = sum(1 for a_, b in zip(md5s, md5s[1:]) if a_ == b)
        mean_ms = sum(shots) / len(shots)
        stats = (
            f"tag={a.tag} wid={wid[0]} win={wid[1]}x{wid[2]}\n"
            f"launch_ms={int((t_win - t0) * 1000)}\n"
            f"frames={len(files)} wall_s={wall:.1f} "
            f"fps={len(files) / wall:.2f}\n"
            f"shot_ms_max={max(shots):.0f} shot_ms_mean={mean_ms:.0f} "
            f"fast_trigger={'yes' if mean_ms > 500 else 'no'}\n"
            f"bytes_min={min(sizes)} bytes_max={max(sizes)} "
            f"bytes_last={sizes[-1]}\n"
            f"identical_adjacent={runs}/{len(files) - 1}\n"
            f"settle_idx={settle_index(md5s)}\n"
            f"md5_first3={' '.join(md5s[:3])}\n"
            f"md5_last3={' '.join(md5s[-3:])}\n")
        with open(os.path.join(outdir, "STATS.txt"), "w") as fh:
            fh.write(stats)
        print(stats, flush=True)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
