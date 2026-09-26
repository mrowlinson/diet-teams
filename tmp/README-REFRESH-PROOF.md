# README-REFRESH PROOF (docs + shots ONLY, zero product edits)

Lane: `lanes/readme-refresh`. Worktree: `tmp/wt-readme-refresh`.
Base: main @ db0e53d (verified `git rev-parse` before work).

## Sections rewritten (README.md)

- Intro: + in-frame Teams apps one-liner.
- Hero block: 3 fresh shots (this lane) + `top10-files-recents.png`
  (current, Sep 26). Removed 5 stale om-reskin/om-better heroes.
- Ten headlines replaced (old: generic app tour; new: shipped-on-main
  top-10 + gap closes):
  1. apps frame (TEAMS-FRAME-FULL-PROOF)
  2. presence truth (TOP10-PRESENCE-PROOF)
  3. unified files (TOP10-FILES-PROOF)
  4. code messaging (TOP10-CODE-PROOF + WIRE-PRE-PROOF)
  5. menu-bar + lean startup (TOP10-MENUBAR-PROOF)
  6. offline search (gap-g6g7 commit 3c7de0f)
  7. side-by-side accounts (GAP-G2-PROOF)
  8. pop-outs: chat (E1-POPOUT-PROOF) + channel/meeting/file (gap-g8
     commit 81b718a)
  9. screenshare (TOP10-SHARE-PROOF)
  10. call banner+ring (GAP-G3G5-PROOF + GAP-G4-PROOF CallKit verdict)
- By-area: kept all prior content, reorganized into Chat / Teams-meetings-
  calls / Notifications-accounts (G1 unified notifs, G5 Focus default-on)
  / Productivity / Session-diagnostics; + jump-to-context (GAP-G9-PROOF).
- Calendar EXCLUDED (CAL-BUILD-PROOF: engine-only, mock transport, no UI).
- Untouched: Requirements → License (build/usage/arch/test/upstream).

## Shots (this lane, --demo only, window-id capture, viewed)

| file | flags | px | viewed |
|---|---|---|---|
| docs/shots/readme-hero-main.png | --demo-rich | 3292x2092 | rail+rich thread, DEMO badge, canned names |
| docs/shots/readme-hero-code.png | --show-code | 3292x2092 | python received + swift sent, highlighted, fences stripped |
| docs/shots/readme-hero-teams.png | --demo --show-teams | 3292x2092 | Engineering/Design channels, DEMO badge, canned names |

All ≥1440x900 (1600x1000 logical @2x). App name "Better Teams" in every
title bar. Zero real data. Script: tmp/scratch-readme/shot-readme.py.

Retake note: first teams attempt ran `--show-teams` WITHOUT `--demo` →
live-mode spinner + real account strip. Deleted, never committed; retake
is demo-only (verified pixels: no account strip).

## Grep-clean lines (worktree, 2026-09-26)

- `grep -in "diet teams|diet-teams" README.md docs/*.md` → no hits.
  (`DietDesign`/`DietShowcase` module identifiers remain in Architecture;
  they are code names, not product naming — renaming is product scope.)
- `grep -in "calendar|cal-build" README.md` → no hits.
- README image links: all 4 resolve under docs/shots/ (3 new + 1 existing).

## Build note (shots only, no source touched)

- Staged main-checkout .a was stale (missing `ostmac_files_recents`) →
  ran ./scripts/build-rust.sh in-worktree (green, 5 pre-existing
  warnings), then debug `swift build --product OstMac` + ad-hoc-signed
  scratch .app. `git status`: README.md + 3 png + proof + script only.
- No tests: docs+shots lane, zero product edits. No main commit (parent
  merges).
