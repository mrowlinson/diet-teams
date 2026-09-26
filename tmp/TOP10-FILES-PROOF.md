# TOP10-FILES PROOF — #9 unified files view

Lane: top10-files. Branch: `lanes/top10-files`. Worktree: `tmp/wt-top10-files`. Base: main @ 700ffe9.
Scope: files surface ONLY (Swift + one additive Rust endpoint).

## Tip

- `lanes/top10-files` head (this commit): top10-files #9 unified files view
- proof: this file + `docs/shots/top10-files-*.png` (committed below the tip)

## Research (#9 demand)

- MSP consensus: files scatter — per-chat Shared tabs, per-channel
  folders, OneDrive/SharePoint each siloed. No single surface.
- Q&A uploads not appearing: drive uploads with no conversation
  attachment (exports, uploads) surface in NO conversation list.

## Root causes found

1. Shared tab is per-conversation (`SharedFilesStore.open(chatID:)`):
   N chats = N disjoint lists; channels likewise. No merge anywhere.
2. No drive-recents core endpoint: `/me/drive/recent` (the
   OneDrive+SharePoint recents leg that catches conversation-less
   uploads) had no ost/FFI/Swift path.
3. No Files rail section: sidebar hosts chats/teams/contacts/.../shifts
   but files only exist as a conversation-pane tab.

## Build

- `rust/ost/src/api/files.rs` (+`mod.rs` export, ledger §59 [minor]):
  `drive_recents_path` (`/me/drive/recent?$top=N`) +
  `list_drive_recents_data` (same driveItem parse as children,
  folders filtered, sender None). 2 unit tests.
- `rust/ostmac-core/src/lib.rs`: `files_recents_json` (`{ok,files}`,
  Shared-tab row projection) + `ostmac_files_recents(limit)` extern
  (limit<=0 → 25). Header decl in `ostmac_core.h`.
- `swift/.../OstMacCore/UnifiedFiles.swift` (new): `UnifiedFileSource`
  (chat/channel/drive) + `UnifiedFileRow` (SharedFile + leg + origin
  name) + `UnifiedFilesStore` (TaskGroup fan-out over specs + drive
  recents; partial-leg merge; first-wins dedupe by drive-scoped key;
  reuses Shared-tab sort/filter/sort, save/saveAs defaults, share-link,
  upload pre-gate) + `UnifiedFilesView` (recents list, source badges,
  sort + source + type controls, Save-first Preview + Save inline,
  Share…/Open/Copy-link context menu, panel + drop upload) +
  `ShareSheet` (NSSharingServicePicker).
- Save-first flows: Preview = local copy or save-then-QL
  (`QuickLookPreview.shared`); Share = saved bytes or save-then-pick.
  Demo saves fabricate real bytes under
  `$TMPDIR/UnifiedFilesDemo/` (never ~/Downloads) so QL/share work
  offline with zero network.
- Wiring: `SidebarSection.files` (rail icon `folder`, after Teams) +
  `SidebarColumn` case + `AppState.unifiedFiles` (demo: canned rows;
  live: `specsFor` caps 10 chats + 20 channels) + `--show-files` /
  `--show-files-preview` flags (isDemo-offline) + refresh hooks.
- Demo seed: chat pdf + channel xlsx + chat png + drive-only
  `qna-export-sept.csv` (newest; the conversation-less row).

## Suites

- New: `Top10FilesTests` 32 tests, 0 failures (merge/dedupe/sort,
  source+type filters, specs caps, share payloads, demo flows,
  save-then-preview/share, upload gate+upsert, nav hooks).
- Rust: ost `api::files::` 26 passed (2 new); staticlib rebuilt, zero
  new warnings (5 pre-existing in calling/trouter untouched).
- Neighbors (all green): file-stack 64 (SharedFiles,
  RowDepth, FolderNav, FileLink, FolderBrowsing, DropQuick) + nav 23
  (AppNavRail, ReskinTeams, ReskinChat, ShiftsFull). 3 section-list
  tests updated 8→9 (Files after Teams).
- `swift build` (all targets): green, zero new warnings.

## Acceptance

1. Chat file + channel file in ONE recents view: shot shows all four
   demo rows (`qna-export-sept.csv` OneDrive, `launch-checklist.xlsx`
   Channel, `empty-states.png` + `onboarding-mocks.pdf` Chat),
   newest-first; `testLoadMergesChatChannelAndDrive` pins it.
2. QuickLook opens: shot shows the QL panel over the first row's demo
   copy (`qna-export-sept.csv`, "Open with Numbers");
   `testDemoPreviewSavesThenPreviews` pins save-then-preview.
3. Share-sheet upload path: `testDemoShareUsesSavedBytes` (bytes to
   the picker after save-first); link share via context menu.

## Shots (window-ID captures, --demo only, viewed)

- `docs/shots/top10-files-recents.png`: `--show-files` — Files rail
  section, 4 merged rows with source badges, Preview/Save inline.
- `docs/shots/top10-files-quicklook.png`: `--show-files-preview` —
  QL panel over the demo copy (nameless window finder: largest
  non-main window; QL panels set no CGWindowName).
- Script: `tmp/scratch-files/shot-files.py` (debug .app assemble +
  sign + winlist + `screencapture -l`; apps terminated after).

## Files

- new: `UnifiedFiles.swift`, `Top10FilesTests.swift`,
  `docs/shots/top10-files-recents.png`,
  `docs/shots/top10-files-quicklook.png`,
  `tmp/scratch-files/shot-files.py`, `tmp/TOP10-FILES-PROOF.md`
- touch (additive): `rust/ost/.../files.rs`, `rust/ost/.../mod.rs`,
  `rust/ost/OSTMAC-PATCHES.md` (§59), `rust/ostmac-core/src/lib.rs`,
  `ostmac_core.h`, `Models.swift` (DriveRecentsResponse),
  `RustCore.swift` (driveRecents), `DemoData.swift` (seeds),
  `SidebarColumn.swift`, `AppNavRail.swift`, `App.swift` (state +
  flags + refresh), 3 section-list tests (8→9)

## Live rule

No live verification, zero prod footprint: shots `--show-files*`
(demo) only, no live launches, no uploads, no link creation. Own shot
PIDs only, all terminated. Residual: live fan-out untested against
real Graph (specs capped 10+20; partial-leg merge tolerates per-chat
404s) — owner live pass recommended post-merge.
