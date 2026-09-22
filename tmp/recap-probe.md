# om-recap-probe findings — 2026-09-22

## 0. verdict: BLOCKED (1/3 feasible, 1/3 license-gated, 1/3 no-API)

## 1. transcript: FEASIBLE (delegated, work accounts only)
- v1.0 endpoints, verified in docs:
- `GET /me/onlineMeetings/{meetingId}/transcripts/{transcriptId}`
- `GET /me/onlineMeetings/{meetingId}/transcripts/{transcriptId}/content`
- `GET /me/adhocCalls/{callId}/transcripts/{transcriptId}/content`
- `GET /users/{userId}/onlineMeetings/getAllTranscripts` (+ delta sync)
- delegated perm: `OnlineMeetingTranscript.Read.All` (meetings), `CallTranscripts.Read.All` (adhoc)
- personal MS accounts: NOT supported (docs explicit)
- 2 tenant-admin kill switches: Graph-transcript-access OFF = 403 `GraphAccessToTranscriptsDisabled`; speaker-attribution OFF blocks `text/vtt`, unattributed format still works
- no channel-meeting transcripts via getAllTranscripts; no meetings from create-onlineMeeting API w/o calendar event
- ost gap: graph token fetched with scope `https://graph.microsoft.com/.default` on Teams 1st-party client `1fec8e78-...` (`rust/ost/src/auth/oauth.rs:79-98`). new scope needs consent-flow change + live tenant test. no existing recap code in ost (`src/api/graph.rs` = chat list only)
- follow-up lane possible: transcript-only, work accounts, tenant permitting

## 2. AI summary (recap notes/action items/mentions): LICENSE-GATED
- v1.0 endpoints, verified:
- `GET /copilot/users/{userId}/onlineMeetings/{meetingId}/aiInsights/{aiInsightId}` (get + list)
- delegated perm: `OnlineMeetingAiInsight.Read.All`; personal accounts NOT supported
- hard gate: EVERY app user must hold M365 Copilot license. no usage-based pay, no eval mode (docs explicit)
- insights post-meeting only, lag up to 4h; meeting must not be expired
- coverage: private scheduled, town hall, webinar, Meet Now. NO channel meetings
- global cloud only (Gov L4/L5, China: no)

## 3. whiteboard content: NO PUBLIC API
- 0 hits for "whiteboard" in full Graph permissions reference (569KB, ms.date 2026-09-14, fetched 2026-09-22)
- 2 web searches: zero Graph whiteboard-content endpoints; only transcript/aiInsight results
- no `callTranscript`/`callAiInsight` whiteboard linkage in docs
- whiteboard read = BLOCKED unless via undocumented/unsupported path (not probed, out of scope)

## refs (all bodies opened, not snippets)
- `https://learn.microsoft.com/en-us/graph/api/calltranscript-get?view=graph-rest-1.0`
- `https://learn.microsoft.com/en-us/graph/api/callaiinsight-get?view=graph-rest-1.0` (redirects to m365copilot `callaiinsight-get`, ms.date 2026-04-03)
- `https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/meeting-transcripts/meeting-insights` (raw: `MicrosoftDocs/msteams-docs@main`, ms.date 2026-06-18)
- `https://learn.microsoft.com/en-us/graph/permissions-reference` (ms.date 2026-09-14)
- ost: `rust/ost/src/auth/oauth.rs`, `rust/ost/src/auth/mod.rs`, `rust/ost/src/api/client.rs`, `rust/ost/src/api/graph.rs`
