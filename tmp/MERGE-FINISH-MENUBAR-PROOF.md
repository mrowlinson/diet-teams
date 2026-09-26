# MERGE-FINISH: lanes/top10-menubar (da2ec43) into main (31a8d20)

Branch: lanes/merge-finish-menubar. 1 conflict file. Both sides kept. No drops.

## Conflict sites (1 hunk, App.swift only)

Hunk at scene declarations (~L285-321 pre-resolution):
- HEAD (gap-g2): Account WindowGroup (id: AppIdentity.accountWindowID).
- Lane (top10-menubar): MenuBarExtra (popover triage + label).
- Cause: both appended a new Scene after the chat-popout WindowGroup.
- Fix: kept BOTH, HEAD block first then lane block. Order irrelevant (Scene decls).

## Resolution (final file:line)

- swift/Sources/OstMac/App.swift:285-298 — gap-g2 Account WindowGroup (kept verbatim).
- swift/Sources/OstMac/App.swift:299-318 — menubar MenuBarExtra + label (kept verbatim).
- swift/Sources/OstMac/App.swift:226-234 — menubar LazyView call/chat windows (auto-merged, intact).
- swift/Sources/OstMac/App.swift:337,491,712-735,1053,1147-1162,1299,2873-2874,3061,3347
  — presenceTruth store/wiring/tick/observers/undo-toast (all intact).
- swift/Sources/OstMac/SettingsView.swift — auto-merged: truth: PresenceTruthStore (L47,102,121)
  + loginItems: LoginItemStore (L64-67,248+) both present. No hand edit.
- New files from lane: swift/Sources/OstMacChatList/MenuBarViews.swift,
  swift/Sources/OstMacCore/LeanStartup.swift, swift/Tests/OstMacCoreTests/LeanStartupTests.swift.
- Touched by lane: OstMacCore/CameraCapture.swift, OstMacCore/ScreenShare.swift (auto-merged).

## Verification

- swift build: complete (21s). Note: fresh worktree lacked rust/ostmac-core/target/release
  lib; symlinked main checkout's libostmac_core.a (gitignored build artifact, not committed).
- Focused: PresenceTruthTests (31) + LeanStartupTests (15) = 46/46 pass.
- Neighbors: Presence, PresenceSchedule, AccountStore, SettingsOrg, SettingsTrim,
  NotifSettings, ChatList, AppIdentity, AvPanel = 150/150 pass.
- Total: 196 run, 0 failures. Full gate parent-side.
