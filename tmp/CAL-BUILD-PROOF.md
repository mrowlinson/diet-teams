# CAL-BUILD-PROOF — calendar two-way sync, BUILD ONLY

- Lane: `lanes/cal-build`, base `main @ 008b27f`.
- Zero live Graph calls, zero EventKit writes. Mock transport + unit tests only.
- Files:
  - `swift/Sources/OstMacCore/CalSync.swift` (engine: config, planner, delta-apply, executor, diagnostics)
  - `swift/Sources/OstMacCore/CalSyncMocks.swift` (mock transport + recording sinks)
  - `swift/Tests/OstMacCoreTests/CalSyncTests.swift` (25 tests)

## Arch

```
MockGraphTransport (delta pages, scripted)
        | fetchDelta(since, window)
        v
CalSyncPlanner.planInbound  ──> [EKWriteOp]   (create/update/delete, EventKit-SHAPED, no EventKit import)
CalSyncPlanner.planOutbound ──> [GraphWriteOp] (create/update/delete, no HTTP)
CalSyncPlanner.planBidirectional = inbound + outbound + conflict resolve
        |
        v
CalSyncExecutor.execute(plan, config, ekSink, graphSink)
  dry-run (default) -> logs all, calls zero sinks
  live -> requires dryRun=OFF AND liveWritesEnabled=ON, else throws, zero sink calls
        |
        v
CalDeltaApply.apply(cached, delta) -> merged [MeetingItem] (pure, feeds week grid)
CalSyncDiagnostics.snapshot(config, lastPlan) -> Diagnostics hook (engine API only, no UI)
```

- Directions: inbound = Graph delta -> EK ops; outbound = EK changes -> Graph ops.
- Every gate decision appended to `CalSyncPlan.log` (`allowlist/window/map/delete/delete-held/dry-run/conflict-teams-wins/checkpoint/refuse-live/live`).
- Held deletes NEVER execute, even in live mode.

## Guard list (binding, test-pinned)

1. dry-run default ON — `CalSync.swift:50` (`dryRun = true`), live needs `liveWritesEnabled` (`:52`, default false `:64`); combined gate `liveExecutionAllowed` (`:103-104`); executor dry-run branch calls zero sinks (`CalSync.swift` execute `plan.dryRun || !liveExecutionAllowed`); live-without-flag throws `liveWritesNotEnabled` before any sink touch.
2. Window +-30d default, HARD MAX 90d — `CalSync.swift:58` default 30, `:59` max 90; `>90` throws `windowTooLarge` (`:79-81`), never clamped; `<1` clamped UP to 30 (logged) so no unbounded pull.
3. Allowlist ONE UPN — `CalSync.swift:46` (`targetUPN: String?`); empty -> `allowlistEmpty` (`:92`); mismatch -> `allowlistMismatch` (`:96`); checked FIRST in both planners, all ops refused.
4. Delete propagation second flag default OFF — `CalSync.swift:56` (`deletionPropagationEnabled = false`); inbound hold (`:350-358`), outbound hold; executor never executes held.

## Conflict rule

- Teams-wins-with-log. Same graphID touched both sides -> Graph op kept, local op dropped, `conflict-teams-wins` log entry with id. Rationale: Teams/Graph copy = shared multi-device truth; local edit must never silently clobber it. See header comment `CalSync.swift:24-31`, `planBidirectional`.

## Mock verdicts

- `swift build`: green (`Build complete!`).
- `swift test --filter CalSyncTests`: 25/25 pass, 0 failures.
- Coverage: empty allowlist refuses (in+out), mismatch refuses (in+out), case-insensitive match, default-30, >90 rejects, 90 accepts, 0 clamps-to-30, dry-run default ON, dry-run executes nothing (0 sink calls), live-without-flag refuses + 0 calls, live-with-both-flags executes mocks, deletes held in/out, deletes flow with flag, held-never-executes-even-live, create-vs-update mapping both directions, graphID-less local delete dropped, conflict Teams-wins, delta upsert/drop, empty-delta noop, mock transport window record, end-to-end mock fetch->plan->dry-run, diagnostics snapshot.
- Full gate: parent-side (this lane ran package build + focused suite only).

## LIVE-TEST-PROTOCOL (owner only, future lane)

NEVER run live sync against the WORK account (16y history). Live testing ONLY on a PERSONAL test account, and ONLY after a later lane adds real transports behind these same gates.

1. Create/use personal test Microsoft account with a near-empty calendar (a few seeded events).
2. Set `targetUPN` = personal test UPN ONLY. Verify mismatch test: work UPN must throw `allowlistMismatch`.
3. Keep `dryRun = true`. Run inbound plan. Inspect log: ops listed, `executedTotal = 0`.
4. Still dry-run: seed a Graph-side delete on test account. Verify `delete-held`, held count 1.
5. Window check: request 91d. Verify `windowTooLarge` throw, no fetch issued.
6. ONLY then: `dryRun = false` + `liveWritesEnabled = true` + delete flag OFF on the TEST account. Verify creates/updates land, deletes still held.
7. Delete flag ON only on test account, one tombstone, verify single delete.
8. NEVER set `targetUPN` to the work UPN until owner explicitly approves after test-account success. NEVER run with delete flag ON against work history without a backup/export first.
