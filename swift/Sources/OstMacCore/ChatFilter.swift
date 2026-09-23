// ChatFilter.swift — om-rules lane: notify/skip decision.
//
// Port of TeamsNotifier's TeamsCore/ChatFilter.swift, adapted for OstMac's
// RealtimeMessage (sender/senderID/text/raw/messageType/isEdit) and
// per-chat RulesConfig resolution. Two deliberate improvements over the
// TeamsNotifier semantics:
// - Keywords match whole words (case-insensitive, Unicode word
//   boundaries): "outage" skips "outages". Entries starting with `re:`
//   are raw case-insensitive regexes; invalid regexes never match.
// - Gates resolve per chat from in-scope rules in list order (see
//   RulesConfig.effective(forChat:)); keyword kinds merge in order.
//
// Skipped from the port: observability (no logging — the app decides what
// a skip/notify means for its UI).
import Foundation

/// Notify/skip decision. Pure; every branch covered by tests.
///
/// - Muted: everything skipped (reason "muted"). The app sets
///   `rules.muted` to the effective value before calling decide.
/// - Teams per-chat mute: chats muted in the Teams client skip with
///   reason "teams-muted". Beats everything below (keywords, meeting
///   signals, mentions); only the global mute above keeps its reason.
///   (OstMac passes an empty set today — no per-chat mute source yet;
///   the gate is ready for one.)
/// - Keyword block: a block word in the message plain text forces SKIP
///   (reason "keyword-block"), through any filter notify. Checked first
///   after mute, so it beats the keyword allow below.
/// - Structural bodies (never notifiable, beat keyword-allow but yield
///   to keyword-block above so a blocked word keeps its reason):
///   empty-text, raw JSON ("json-blob"), fenced code ("code-blob"),
///   Facilitator close ("facilitator-close": folds, never opens).
/// - Meeting-start: Play beacons, meeting-metadata blobs, Facilitator
///   opens notify ONCE per chat per activity window (reason
///   "meeting-starting": the caller posts the synthesized "Meeting
///   starting: <chat>" body, never the raw text); repeats skip
///   ("meeting-start-suppressed"). Facilitator closes and
///   meeting-thread empty/JSON/code bodies extend an open window
///   (fold, never notify). The stateful overload below owns the
///   window; the stateless decide always takes the first-signal
///   branch (documented; the app uses the overload).
/// - Keyword allow: an allow word in the message plain text forces
///   NOTIFY (reason "keyword-allow"), through any filter skip (own,
///   type, edit, noisy). Both keyword gates yield to mute.
/// - Keyword match: case-insensitive WHOLE WORDS against the message
///   text, any chat; `re:` entries are case-insensitive regexes.
///   Opposing hits: BLOCK wins.
/// - Own messages: skipped (when skipOwnMessages). Sender match is MRI
///   preferred with a display-name backup (when matchByDisplayName).
/// - Non-text types: skipped unless listed in notifyTypes. A "*" entry
///   (written when the only-these-message-types rule is absent/disabled)
///   allows every type. An UNKNOWN type (core omitted `message_type`)
///   passes the gate — it cannot be classified, and failing closed
///   would silence new installs on old cores.
/// - Edits: skipped unless notifyOnEdit.
/// - Noisy chats (display name contains loudSubstring, case-insensitive):
///   notify ONLY on owner mention (MRI preferred, display-name backup
///   when matchByDisplayName) or — when noisyChannelMentions —
///   channel/Everyone mention.
/// - All other chats: notify.
public enum ChatFilter {
    public enum Decision: Sendable, Equatable {
        case notify(reason: String)
        case skip(reason: String)
    }

    /// Skip reason used for the mute gate.
    public static let mutedReason = "muted"

    /// Skip reason for chats muted in the Teams client. Beats every gate
    /// below the global mute, including meeting-starting and
    /// keyword-allow.
    public static let teamsMutedReason = "teams-muted"

    /// Notify reason for the meeting-start gate. The caller posts the
    /// synthesized "Meeting starting: <chat>" body for this reason,
    /// never the triggering message's raw text.
    public static let meetingStartingReason = "meeting-starting"

    /// Stateless decide: meeting open-signals (Play beacons, meeting
    /// blobs, Facilitator opens) always take the first-signal branch
    /// (notify "meeting-starting"). Prefer the stateful overload: it
    /// suppresses repeats within the per-chat window.
    public static func decide(
        message: RealtimeMessage,
        chatDisplayName: String,
        ownerMRI: String?,
        rules: RulesConfig,
        teamsMutedChatIDs: Set<String> = []
    ) -> Decision {
        decideCore(
            message: message, chatDisplayName: chatDisplayName,
            ownerMRI: ownerMRI, eff: rules.effective(forChat: chatDisplayName),
            teamsMutedChatIDs: teamsMutedChatIDs,
            claimMeetingStart: { _ in true },
            noteMeetingActivity: { _ in }
        )
    }

    /// Stateful decide: first meeting signal per chat notifies
    /// ("meeting-starting"); repeats within the per-chat window skip
    /// ("meeting-start-suppressed"); a later meeting (gap > window)
    /// notifies again. The app keeps one MeetingStartDedup for the
    /// process and passes `now` per message.
    public static func decide(
        message: RealtimeMessage,
        chatDisplayName: String,
        ownerMRI: String?,
        rules: RulesConfig,
        meetingDedup: inout MeetingStartDedup,
        now: Date,
        teamsMutedChatIDs: Set<String> = []
    ) -> Decision {
        decideCore(
            message: message, chatDisplayName: chatDisplayName,
            ownerMRI: ownerMRI, eff: rules.effective(forChat: chatDisplayName),
            teamsMutedChatIDs: teamsMutedChatIDs,
            claimMeetingStart: { chatID in meetingDedup.shouldNotify(chatID: chatID, date: now) },
            noteMeetingActivity: { chatID in meetingDedup.observe(chatID: chatID, date: now) }
        )
    }

    static func decideCore(
        message: RealtimeMessage,
        chatDisplayName: String,
        ownerMRI: String?,
        eff: EffectiveRules,
        teamsMutedChatIDs: Set<String>,
        claimMeetingStart: (String) -> Bool,
        noteMeetingActivity: (String) -> Void
    ) -> Decision {
        // Mute gate first: suppresses all message notifications.
        if eff.muted {
            return .skip(reason: mutedReason)
        }
        // Teams per-chat mute: beats everything below (keyword gates,
        // meeting signals, mentions). Above the meeting branch on
        // purpose: a muted skip claims no window, so unmuting later
        // still fires meeting-starting for that meeting.
        if teamsMutedChatIDs.contains(message.chatID) {
            return .skip(reason: teamsMutedReason)
        }
        // Keyword block beats everything below (keeps its reason even
        // on structural/meeting bodies).
        let text = message.text
        if KeywordMatch.contains(text, eff.blockKeywords) {
            return .skip(reason: "keyword-block")
        }
        // Structural bodies: never notifiable, beat keyword-allow.
        // Meeting-thread folds extend an open window (never open one).
        switch MeetingSignal.classify(
            text: text, content: message.raw ?? text,
            chatID: message.chatID, senderName: message.sender,
            chatDisplayName: chatDisplayName
        ) {
        case .emptyText:
            if MeetingSignal.isMeetingThread(message.chatID) { noteMeetingActivity(message.chatID) }
            return .skip(reason: "empty-text")
        case .jsonBlob:
            if MeetingSignal.isMeetingThread(message.chatID) { noteMeetingActivity(message.chatID) }
            return .skip(reason: "json-blob")
        case .codeBlob:
            if MeetingSignal.isMeetingThread(message.chatID) { noteMeetingActivity(message.chatID) }
            return .skip(reason: "code-blob")
        case .facilitatorClose:
            noteMeetingActivity(message.chatID)
            return .skip(reason: "facilitator-close")
        case .playBeacon, .meetingBlob, .facilitatorOpen:
            if claimMeetingStart(message.chatID) {
                return .notify(reason: meetingStartingReason)
            }
            return .skip(reason: "meeting-start-suppressed")
        case .normal:
            break
        }
        if KeywordMatch.contains(text, eff.allowKeywords) {
            return .notify(reason: "keyword-allow")
        }
        // Own message?
        if eff.skipOwnMessages, isOwnMessage(
            senderMRI: message.senderID, senderName: message.sender,
            ownerMRI: ownerMRI, ownerDisplayName: eff.ownerDisplayName,
            matchByName: eff.matchByDisplayName
        ) {
            return .skip(reason: "own-message")
        }
        // Type gate on first messagetype segment (Text, RichText, ...).
        // Unknown (core omitted it): pass — unclassifiable, never skip.
        let rawType = (message.messageType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawType.isEmpty {
            let head = rawType.split(separator: "/").first.map(String.init) ?? rawType
            if !eff.notifyTypes.contains(NotifyRule.allowAllMarker),
               !eff.notifyTypes.contains(where: { $0.caseInsensitiveCompare(head) == .orderedSame })
            {
                return .skip(reason: "type:\(head)")
            }
        }
        // Edits.
        if message.isEdit, !eff.notifyOnEdit {
            return .skip(reason: "edit")
        }
        // Noisy-chat rule.
        if isLoudChat(chatDisplayName, substring: eff.loudSubstring) {
            if Mentions.mentionsOwner(message.mentions, ownerMRI: ownerMRI, ownerDisplayName: eff.ownerDisplayName, matchByName: eff.matchByDisplayName) {
                return .notify(reason: "loud-owner-mention")
            }
            if eff.noisyChannelMentions, Mentions.mentionsChannelOrEveryone(message.mentions) {
                return .notify(reason: "loud-channel-mention")
            }
            return .skip(reason: "loud-no-mention")
        }
        return .notify(reason: "chat-message")
    }

    static func isOwnMessage(senderMRI: String?, senderName: String, ownerMRI: String?, ownerDisplayName: String, matchByName: Bool = true) -> Bool {
        if let ownerMRI, !ownerMRI.isEmpty, let sender = senderMRI, !sender.isEmpty {
            return sender.caseInsensitiveCompare(ownerMRI) == .orderedSame
        }
        // MRI unknown: fall back to sender display-name match (unless the
        // name-backup gate is off: IDs only). Empty names never match
        // (avoid muting everything when unconfigured).
        guard matchByName else { return false }
        let a = senderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = ownerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !a.isEmpty && a == b
    }

    static func isLoudChat(_ name: String, substring: String) -> Bool {
        guard !substring.isEmpty else { return false }
        return name.range(of: substring, options: .caseInsensitive) != nil
    }
}

/// Keyword matching with whole-word boundaries plus opt-in regex.
///
/// - Plain entries match case-insensitively on word boundaries
///   ("outage" hits "OUTAGE in prod", misses "outages"). Boundary
///   markers attach only where the phrase edge is a word char, so
///   symbol-heavy entries ("c++", "#release") still match.
/// - `re:`-prefixed entries are raw case-insensitive regexes
///   ("re:sev-?\\d+" hits "sev123"). Invalid regexes never match.
/// - Empty lists never hit; blank entries are skipped.
public enum KeywordMatch {
    /// Prefix marking a raw-regex keyword.
    public static let regexPrefix = "re:"

    public static func contains(_ text: String, _ keywords: [String]) -> Bool {
        guard !keywords.isEmpty, !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for raw in keywords {
            let kw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kw.isEmpty else { continue }
            if kw.hasPrefix(regexPrefix) {
                let pattern = String(kw.dropFirst(regexPrefix.count))
                guard !pattern.isEmpty,
                      let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                else { continue }
                if re.firstMatch(in: text, range: range) != nil { return true }
            } else {
                guard let re = try? NSRegularExpression(pattern: wordPattern(for: kw), options: .caseInsensitive) else { continue }
                if re.firstMatch(in: text, range: range) != nil { return true }
            }
        }
        return false
    }

    /// Escaped literal with `\b` where the phrase edge is a word char.
    static func wordPattern(for phrase: String) -> String {
        let esc = NSRegularExpression.escapedPattern(for: phrase)
        let pre = phrase.first.map(isWordChar) == true ? "\\b" : ""
        let suf = phrase.last.map(isWordChar) == true ? "\\b" : ""
        return pre + esc + suf
    }

    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}
