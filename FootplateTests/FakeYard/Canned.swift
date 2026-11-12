import Foundation

// The fake yard's replies to the calls of design 3.1, taken from the
// examples of yardr's docs/api.md (cut to fewer rows, with a field or
// two the phone does not read left in, so a test sees them passed
// over). Ported from footplate-android's fake/Canned.kt.

enum Canned {
    static let replies: [String: String] = [
        "Head": #"{"result": 151}"#,
        "Settings": #"{"result": {"blob_max_bytes": "8388608", "files_max": "64", "operator": "jo", "operator_note": "I read diffs, not prose", "operator_style": "show"}}"#,
        "GetUser": #"{"result": {"name": "jo", "role": "operator", "cursor": 12, "notification_cursor": 10}}"#,
        "Users": #"{"result": [{"name": "jo", "role": "operator", "cursor": 0, "notification_cursor": 0}]}"#,
        "Crew": #"{"result": [{"name": "signalman", "enabled": true, "model": "sonnet", "kind": "claude", "state": "running", "status": "idle", "login_screen": true, "login_led": true, "started_at": "2026-10-08T09:30:00Z"}, {"name": "yardmaster", "enabled": true, "model": "opus", "kind": "claude", "state": "running", "status": "working", "started_at": "2026-10-08T09:30:00Z"}]}"#,
        "UserInbox": #"{"result": {"mail": [{"seq": 13, "at": "2026-10-08T09:30:00Z", "from": "yardmaster", "to": "jo", "text": "The shed is painted. Shall I land it?", "read": false, "reactions": [{"from": "jo", "emoji": "👍"}], "files": [{"hash": "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581", "type": "image/png", "bytes": 70, "name": "shed.png"}]}, {"seq": 51, "at": "2026-10-08T09:30:00Z", "from": "josephine@north", "to": "jo", "text": "I am at the other machine until four.", "read": false, "as": "jo", "files": null}], "unread": 2, "last": 51, "from": ["yardmaster", "josephine@north"]}}"#,
        "Conversation": #"{"result": [{"seq": 13, "at": "2026-10-08T09:30:00Z", "from": "yardmaster", "to": "jo", "text": "The shed is painted. Shall I land it?", "read": false}, {"seq": 36, "at": "2026-10-08T09:30:00Z", "from": "jo", "to": "yardmaster", "text": "On the train. Land the shed when it is green.", "read": false, "via": "phone"}], "more": true}"#,
        "PutBlob": #"{"result": {"hash": "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581", "type": "image/jpeg", "bytes": 11}}"#,
        "Mail": "{}",
        "MailPeer": "{}",
        "AckUserInbox": "{}",
        "UserNotifications": #"{"result": {"notifications": [{"seq": 10, "at": "2026-10-08T09:30:00Z", "kind": "created", "bead": "yd-shed", "text": "yd-shed created (all) by yardmaster originator=jo stage=new title=Paint the shed type=task", "read": false}, {"seq": 11, "at": "2026-10-08T09:30:00Z", "kind": "noted", "bead": "yd-shed", "text": "yd-shed noted (all) by yardmaster note=1 on \"Paint the shed\"", "read": false}], "unread": 2, "last": 11}}"#,
        "AckUserNotifications": "{}",
        "UserAsks": #"{"result": {"open": [{"bead": "yd-links", "bead_title": "Move the links", "topic": "topic:linear-out", "ask": 3, "question": "Move this yard's links to the declared source now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z"}, {"bead": "yd-map", "bead_title": "Who wrote in", "topic": "", "ask": 7, "question": "Who is U024BE7LH on slack?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "identity": {"source": "slack", "sender": "U024BE7LH", "channel": "C1"}, "weight": [{"class": "as-user", "line": "writes who a sender is: U024BE7LH on slack becomes a user of the yard"}]}, {"bead": "yd-tidy", "bead_title": "Tidy the sidings", "topic": "", "ask": 9, "question": "Remove the merged worktrees now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "run": {"argv": ["yardr", "depot", "tidy", "--merged"], "command": "yardr depot tidy --merged", "description": "removes the worktrees of landed beads"}}], "decided": [{"bead": "yd-greet", "bead_title": "The greeting", "ask": 5, "question": "What should the tone of the greeting be?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "declined", "words": "the greeting can wait"}]}}"#,
        "Bead": #"{"result": {"id": "yd-links", "title": "Move the links", "body": "The links file declares the new source.", "stage": "new", "topic": "topic:linear-out", "labels": ["topic:linear-out"], "notes": [{"seq": 2, "kind": "note", "author": "yardmaster", "text": "the test passed on a copy", "at": "2026-10-08T09:30:00Z"}], "asks": [{"ask": 3, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Move this yard's links to the declared source now?", "context": ["The links file declares the new source; 64 links still point at the old one."], "options": [{"label": "Move them now", "consequence": "all 64 links point at the new source tonight"}, {"label": "After Friday", "consequence": "keep the old source until the release is out"}, {"label": "You decide", "consequence": "leave it to yardmaster"}], "recommend": 1, "why": "the test passed", "about": [{"id": "yd-train", "title": "Release train", "stage": "new"}], "state": "open"}]}}"#,
        "AnswerAsk": "{}",
        "ApproveAsk": "{}",
        "DevicePairCloseSelf": #"{"result": {"user": "jo", "device": "phone2", "state": "ended", "expires": "2026-10-08T09:30:00Z"}}"#,
        "ApproveSetup": "{}",
        "GiveSecret": #"{"result": {"given": ["INPUT"], "file": "", "login": "claude-ab12"}}"#,
        "DeferAsk": "{}",
        "DeclineAsk": "{}",
        "Flows": flowsJSON,
    ]

    /// The hashes of the files `yd-shots`' note carries.
    static let shotHash = String(repeating: "5a", count: 32)
    static let pageHash = String(repeating: "7b", count: 32)
    static let bareHash = String(repeating: "9c", count: 32)

    /// `Bead` by the bead it names; any other bead is answered with
    /// the one of `replies`.
    static let beads: [String: String] = [
        "yd-map": #"{"result": {"id": "yd-map", "title": "Who wrote in", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 7, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Who is U024BE7LH on slack?", "context": ["a delivery arrived from U024BE7LH in C1, who maps to nobody."], "options": [{"label": "jo", "consequence": "messages from U024BE7LH count as jo's"}, {"label": "Someone new", "consequence": "pick this and write the new user's name with your answer"}, {"label": "Nobody — ignore this sender", "consequence": "ignores U024BE7LH in slack: their messages are dropped, and no further card is offered"}, {"label": "You decide", "consequence": "leave it to yardmaster"}], "recommend": 1, "why": "jo wrote from this workspace before", "about": [], "state": "open", "identity": {"source": "slack", "sender": "U024BE7LH", "channel": "C1"}, "weight": [{"class": "as-user", "line": "writes who a sender is: U024BE7LH on slack becomes a user of the yard"}]}]}}"#,
        "yd-tidy": #"{"result": {"id": "yd-tidy", "title": "Tidy the sidings", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 9, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Remove the merged worktrees now?", "context": ["12 worktrees belong to landed beads."], "options": [], "state": "open", "run": {"argv": ["yardr", "depot", "tidy", "--merged"], "command": "yardr depot tidy --merged", "description": "removes the worktrees of landed beads", "does": ["deletes 12 directories under ~/.yardr/worktrees"]}}]}}"#,
        // A bead whose notes carry files, as the yard serves a note's: a
        // note with none has no `files`; another carries a picture, a page
        // and a file with no name.
        "yd-shots": shots,
        // A depot pack's card, as a summary and as a whole, and a summary
        // that holds what starter's does not (PackCards).
        "yd-pack": PackCards.starter,
        "yd-pack-whole": PackCards.whole,
        "yd-pack-moved": PackCards.moved,
        // A user device pair card, as docs/api.md's UserAsks example has
        // it, with the trust weight the yard gives a new device.
        "yd-pair": pairCard(bead: "yd-pair", user: "jo", device: "watch"),
        // The same card for another user's device: an operator's to approve
        // for a member, whose pairing the operator's phone cannot end.
        "yd-pair-hal": pairCard(bead: "yd-pair-hal", user: "hal", device: "phone2"),
        "yd-words": #"{"result": {"id": "yd-words", "title": "A words answer", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 12, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "When can we talk?", "context": ["The asker needs a time."], "options": [], "state": "open"}]}}"#,
        "yd-courier": #"{"result": {"id": "yd-courier", "title": "Set up courier", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 44, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Update courier for the yard?", "context": ["A courier account already stands on the yard."], "options": [{"label": "Read", "consequence": "the yard reads the parcels"}, {"label": "Read and write", "consequence": "the yard reads and writes the parcels"}, {"label": "You decide", "consequence": "leave it to yardmaster"}], "recommend": 1, "why": "reading is enough for now", "about": [], "state": "open", "setup": {"pack": "courier", "label": "courier", "given": true, "does": ["keeps the courier account", "grants read of the parcels"]}, "weight": [{"class": "credential", "line": "gives a credential or an address to the yard"}]}]}}"#,
        "yd-token": #"{"result": {"id": "yd-token", "title": "The callback token", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 18, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "What is the callback token?", "context": ["The hook cannot register without it."], "options": [], "state": "open", "secret": {"source": "crm", "env": ["CRM_UPDATE_TOKEN"], "line": "the token the yard calls back with"}, "weight": [{"class": "credential", "line": "gives a credential or an address to the yard"}]}]}}"#,
        // A harness's sign-in, as the yard writes its secret asks: the
        // daemon's ask for the one-time code the page gave, the ask for an
        // API key at a crew member's login screen, and the code of a
        // user's own login.
        "yd-login": #"{"result": {"id": "yd-login", "title": "Claude Code sign-in", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 34, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Paste what Claude Code's sign-in page gave you", "context": ["Sign in on this page: https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&scope=user%3Ainference&state=Xk3v", "Claude Code's login waits for what the page gives you (Paste code here if prompted >).", "What you type goes to the login in the yard's memory and is kept nowhere."], "options": [], "state": "open", "secret": {"source": "", "env": ["INPUT"], "login": "claude-ab12", "line": "a secret: INPUT, for the waiting login claude-ab12"}, "weight": [{"class": "credential", "line": "INPUT, for the waiting login claude-ab12"}]}]}}"#,
        "yd-key": #"{"result": {"id": "yd-key", "title": "Claude Code API key", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 22, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "What is the API key Claude Code runs with?", "context": ["yardmaster is at Claude Code's login screen."], "options": [], "state": "open", "secret": {"source": "", "env": ["ANTHROPIC_API_KEY"], "crew": "yardmaster", "harness": "claude", "line": "a secret: ANTHROPIC_API_KEY, the API key Claude Code runs with, asked for crew member yardmaster; it is read by every Claude Code session that burns the operator's login, from its next start"}, "weight": [{"class": "credential", "line": "ANTHROPIC_API_KEY, the API key Claude Code runs with, asked for crew member yardmaster"}]}]}}"#,
        "yd-own": #"{"result": {"id": "yd-own", "title": "hal's Claude Code sign-in", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 36, "to": "hal", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Paste what Claude Code's sign-in page gave you", "context": ["Sign in on this page: https://claude.ai/oauth/authorize?code=true&state=Qw9z"], "options": [], "state": "open", "secret": {"source": "", "env": ["INPUT"], "login": "claude-ab13", "as": "hal", "line": "a secret: INPUT, for hal's waiting login claude-ab13"}, "weight": [{"class": "credential", "line": "INPUT, for hal's waiting login claude-ab13"}]}]}}"#,
    ]

    /// A pairing card, ask 65: `user device pair <user> <device>`, at the
    /// address the new device reaches the yard at.
    private static func pairCard(bead: String, user: String, device: String) -> String {
        #"{"result": {"id": "\#(bead)", "title": "Pair \#(user)'s \#(device)", "body": "", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 65, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Pair \#(user)'s \#(device)?", "context": ["\#(user) asked for the \#(device) to be paired."], "options": [], "state": "open", "run": {"argv": ["user", "device", "pair", "\#(user)", "\#(device)", "--url", "https://mac.example.net"], "command": "yardr user device pair \#(user) \#(device) --url https://mac.example.net", "does": ["opens a pairing for the device \#(device) of \#(user), reached at https://mac.example.net.", "\#(user) has 1 device: phone (never used).", "Approval opens the pairing for that device alone: its code is good for ten minutes and for one device, and whoever has the code within those minutes is answered with that device's token.", "Nothing in the yard keeps the code after it is used or runs out.", "The new device then calls as \#(user) until yardr user device rm \#(user) \#(device), and \#(user) will then have 2 devices."], "back": "yardr user device pair --end ends it while it stands; once the code is used, yardr user device rm \#(user) \#(device) removes the device"}, "weight": [{"class": "trust", "line": "widens who the yard listens to: a new device \#(device) of \#(user) speaks as them: whoever holds its token calls as \#(user) until the device is removed"}]}]}}"#
    }

    /// What approving `yd-pair` answers (docs/api.md's `ApproveAsk`
    /// example): the pairing it opened, once. `qr` is as the yard's
    /// `PairingQR` makes it from the other fields.
    static func pairingApproved(code: String = "K7QM-2XPD", address: String = "https://mac.example.net", expires: String, qr: String, yard: String = "", channelKey: String = "", user: String = "jo", device: String = "watch") -> String {
        var pairing = #""user": "\#(user)", "device": "\#(device)", "code": "\#(code)", "address": "\#(address)", "expires": "\#(expires)", "qr": "\#(qr)""#
        if !yard.isEmpty { pairing += #", "yard": "\#(yard)""# }
        if !channelKey.isEmpty { pairing += #", "channel_key": "\#(channelKey)""# }
        return #"{"result": {"bead": "yd-pair", "ask": 65, "asker": "yardmaster", "argv": ["user", "device", "pair", "\#(user)", "\#(device)", "--url", "https://mac.example.net"], "does": ["opens a pairing for the device \#(device) of \#(user), reached at https://mac.example.net."], "result": "a pairing was opened for the device \#(device) of \#(user), good until 09:30:00: the code was shown to the approver alone and is kept nowhere", "pairing": {\#(pairing)}}}"#
    }

    /// `yd-shots`: written here and not as a literal of the table, which
    /// `scripts/fake-edge` serves as it stands, with the hashes unresolved.
    private static var shots: String {
        #"{"result": {"id": "yd-shots", "title": "Shots on the card", "body": "", "stage": "new", "labels": [], "notes": [{"seq": 1, "kind": "note", "author": "builder", "text": "Nothing attached.", "at": "2026-10-08T09:30:00Z"}, {"seq": 2, "kind": "note", "author": "builder", "text": "The shot.", "at": "2026-10-08T09:40:00Z", "files": [{"hash": "\#(shotHash)", "type": "image/png", "bytes": 4160, "name": "shot.png"}, {"hash": "\#(pageHash)", "type": "text/html; charset=utf-8", "bytes": 900, "name": "page.html"}, {"hash": "\#(bareHash)", "type": "application/octet-stream", "bytes": 12}]}], "asks": []}}"#
    }

    private static var flowsJSON: String {
        let backlog = (1...12).map { #"{"bead": "yd-draft-\#($0)", "title": "Draft \#($0)", "expected": "—", "working": false}"# }
            .joined(separator: ",")
        return #"{"result": {"travelling": 7, "depots": [{"name": "yard", "kind": "git", "travelling": 5, "flows": [{"name": "default", "type": "", "source": "store", "stages": [{"stage": "new", "group": "muse-builders", "human": false, "lamp": "fault", "terminal": false, "limit": 4, "taken": 2, "beads": [{"bead": "yd-gate", "title": "Mend the gate", "expected": "—", "remark": "blocked by yd-train", "tone": "amber", "working": false}, {"bead": "yd-train", "title": "Release train", "expected": "—", "remark": "", "tone": "none", "working": true, "worker": "herdr train-new", "group": "muse-builders", "kind": "claude", "model": "opus", "entered_stage_at": "2026-10-08T09:30:00Z"}]}, {"stage": "review", "group": "muse-reviewers", "human": false, "lamp": "turn", "terminal": false, "limit": 2, "taken": 1, "beads": [{"bead": "yd-shed", "title": "Paint the shed", "expected": "—", "remark": "waits for mckean", "tone": "amber", "working": false}]}, {"stage": "decide", "group": "mckean", "human": true, "lamp": "none", "terminal": false, "limit": 1, "taken": 0, "beads": [{"bead": "yd-seal", "title": "Seal the tender", "expected": "—", "remark": "", "tone": "none", "working": false}]}, {"stage": "backlog", "lamp": "none", "terminal": false, "beads": ["# + backlog + #"]}] }], "elsewhere": [{"bead": "yd-fence", "title": "Paint the fence", "expected": "—", "remark": "held by yardmaster", "tone": "red", "held_by": "yardmaster", "working": false}]}, {"name": "drafts", "kind": "dir", "travelling": 1, "flows": [{"name": "default", "type": "", "source": "store", "stages": [{"stage": "new", "group": "muse-builders", "human": false, "lamp": "none", "terminal": false, "limit": 4, "taken": 2, "beads": [{"bead": "yd-greet", "title": "The greeting", "expected": "—", "remark": "", "tone": "none", "working": false}]}, {"stage": "shipped", "group": "elders", "human": true, "lamp": "none", "terminal": true, "beads": []}]}], "elsewhere": []}], "unassigned": [{"bead": "yd-crm", "title": "Read the CRM", "expected": "—", "remark": "", "tone": "none", "working": false}]}}"#
    }
}
