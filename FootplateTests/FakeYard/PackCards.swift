import CryptoKit
import Foundation

// Depot pack cards as the yard sends them in `Bead` (yardr design y6gp, the
// sentences of packSummaryDoes in internal/store/runask_packcard.go and the
// wire of AskPack, AskPackFile and AskPlanObject in internal/store).
//
// `starter` is the summary card of starter installed into a depot with none
// of it. Its files are the first lines of the pack's own, so that the card is
// small; the hashes, sizes and counts on its sentences are those of the
// excerpts, as the yard's are of the files. `moved` holds what starter does
// not: a changed file, a file the closing count folded in, a source the
// import adds. `whole` is the same pack as a whole card, which has no
// summary and no files.
enum PackCards {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The pack's digest as `pack check` prints it, over the pack's files
    /// before filling: any 64 hex digits stand for it.
    static let digest = sha256("starter")
    static let label = "embedded in yardr 0.9.4"

    struct File {
        var name: String
        var text: String
        var action = "create"
        /// The diff of a change, old against new; a create's is made from
        /// its text.
        var diff = ""
        var oldSHA = ""

        var newSHA: String { PackCards.sha256(text) }
        /// The lines of the text: a blank one is a line, and the newline
        /// that ends the last is none.
        var lines: [Substring] {
            var split = text.split(separator: "\n", omittingEmptySubsequences: false)
            if split.last?.isEmpty == true { split.removeLast() }
            return split
        }
        var unified: String {
            diff.isEmpty ? "--- (none)\n+++ \(name)\n@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 + "\n" }.joined() : diff
        }
    }

    /// The files starter writes, in the plan's order.
    static let files: [File] = [
        File(name: "roles/builder.md", text: """
        # Builder

        You implement one bead, in its own worktree on branch `yard/<bead>`.

        Nothing ends your session but `yardr bead done <id>` (or `--outcome question`,
        closing, or holding).

        1. Read the bead first (`yardr prime --bead <id>`): its goal, notes and edges.
           When you have read the bead and the files it names, write a plan note
           (`yardr bead note <id>`): the decisions the bead asks for and the files
           you will change. Then start.
        2. Run the depot's test command on the base before you change anything, and
           note what is already red: a failure you inherit is not yours to fix.

        """),
        File(name: "roles/merger.md", text: "# Merger\n\nYou resolve one merge conflict: the assembly could not rebase a bead's branch\nonto its depot's base.\n"),
        File(name: "roles/review-security.md", text: "# Security reviewer\n\nYou review one bead for security alone, in the bead's own worktree on branch\n`yard/<bead>`, after another reviewer has reviewed it against its goal.\n"),
        File(name: "roles/reviewer.md", text: "# Reviewer\n\nYou review one bead that a builder finished, in the bead's own worktree on\nbranch `yard/<bead>`, and you review forward.\n"),
        File(name: "roles/yardmaster.md", text: "# Yardmaster\n\nYou coordinate the work in this yard across its depots, in one or two\nsessions. You do not implement: builders do.\n"),
        File(name: "flows/default/approved.md", text: "summary: The approved bead is landed on the depot's base from here, one bead at a time.\n\nThe approved bead is landed on the depot's base from here, one bead at a time:\nby an assembly script or by a person merging by hand.\n"),
        File(name: "flows/default/backlog.md", text: "New beads wait here, where `yardr bead create` puts them, until the yardmaster\nhas shaped them. No agent works this stage.\n"),
        File(name: "flows/default/clear.md", text: "summary: A bead waits here for a person's yes before it lands.\n\nA bead here waits for your yes before it lands: it was built, reviewed and\ntested, and landing it is now your call.\n"),
        File(name: "flows/default/decide.md", text: "A bead here waits for a person: {{operator}} decides. No agent works this\nstage. The bead carries the question and the options.\n"),
        File(name: "flows/default/new.md", text: "A builder implements the bead here, on branch `yard/<bead>` in the bead's own\nworktree.\n\nBefore the bead leaves as `done`:\n"),
        File(name: "flows/default/review-security.md", text: "summary: The reviewed bead is reviewed once more, for security alone, by another agent.\n\nThe bead was reviewed against its goal in `review`, and is reviewed here a\nsecond time, for security alone.\n"),
        File(name: "flows/default/review.md", text: "summary: The finished bead is reviewed against its goal; what the reviewer can fix is fixed, not sent back.\n\nThe finished bead is reviewed here, on its branch `yard/<bead>`, against the\nbead: its goal, its \"done when\" and the builder's notes.\n"),
        File(name: "flows/train/in-pr.md", text: "summary: The train's pull request is open; a person says whether it is merged.\n\nThe train's pull request is open against the base, at the commit the\nreviewers approved.\n"),
        File(name: "flows/train/merge.md", text: "summary: A conflict between the train's branch and the base is resolved.\n\nA conflict between the train's branch and the base is resolved here:\nrebasing `yard/<train>` onto the base conflicted.\n"),
        File(name: "scripts/merge-local", text: """
        #!/bin/sh
        # merge-local: an assembly that lands a bead's branch directly on its depot's
        # local base branch. Run it as the cmd of an exec group routed for the stage
        # beads wait to land in (approved); limit 1 on the group makes a serial merge
        # queue. See docs/line.md, section 4.
        #
        # It reads everything from the environment the exec runner gives it:
        # YARDR_BEAD, YARDR_DEPOT, YARDR_DEPOT_PATH, YARDR_BASE, YARDR_BRANCH,

        """),
    ]

    private static func and(_ words: [String]) -> String {
        words.count < 2 ? words.joined() : words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1]
    }

    /// A summary card's sentences for `files` installed into depot `yard`,
    /// and where each file's line stands among them (-1 for a file the
    /// closing count folds in: its sentence is the fold's).
    static func sentences(files: [File], folded: Int = 0, sources: [String] = []) -> (does: [String], lines: [Int]) {
        let lined = files.count - folded
        let created = files.filter { $0.action == "create" }.count + 6
        let changed = files.filter { $0.action == "change" }.count
        var does = [
            "pack starter (\(label)), of kind git, into depot yard: \(created) to create, \(changed) to change, 0 unchanged, and 0 dropped and left where they stand, digest sha256:\(digest). It asks nothing. It runs 1 program of the pack: scripts/merge-local.",
            "this is a first install: depot yard holds no import of pack starter.",
            "the plan uses mapping --flow default.",
        ]
        var lines: [Int] = []
        for (i, file) in files.enumerated() {
            guard i < lined else {
                lines.append(-1)
                continue
            }
            lines.append(does.count)
            let diff = file.unified.split(separator: "\n")
            let added = diff.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
            let removed = diff.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
            does.append("file \(file.name): \(file.action), sha256 \(file.oldSHA.isEmpty ? "(none)" : file.oldSHA) -> sha256 \(file.newSHA), \(file.text.utf8.count) bytes (\(added) insertions, \(removed) deletions).")
        }
        if folded > 0 {
            let bytes = files.suffix(folded).reduce(0) { $0 + $1.text.utf8.count + ($1.action == "change" ? $1.diff.utf8.count : 0) }
            does.append("\(folded) more file\(folded == 1 ? "" : "s"), \(bytes) bytes, stand in the full text without a line of their own, under digest sha256:\(digest) and each under its own sha256 there.")
        }
        does += [
            "groups to create: yard-builders, yard-reviewers, yard-assembly.",
            "routes to create: stage new, stage review, stage approved.",
            "group yard-assembly: cmd sets YARDR_LAND=squash before the script.",
            "depot yard would follow flow starter.default; it follows default now.",
        ]
        for source in sources {
            does.append("source \(source): added, its calls go to https://wired.example.com/v1, with command files wired/limits sha256 \(sha256("#!/bin/sh\nexit 0\n")).")
        }
        let bytes = files.reduce(0) { $0 + $1.text.utf8.count + ($1.action == "change" ? $1.diff.utf8.count : 0) }
        does += [
            "in all: \(created) to create, \(changed) to change, 0 unchanged, 0 not in the pack.",
            "the full text stands behind this card, on this bead's page: \(files.count) files, \(bytes) bytes.",
        ]
        return (does, lines)
    }

    private static func object(_ file: File) -> [String: Any] {
        var out: [String: Any] = ["kind": "file", "name": file.name, "action": file.action,
                                  "file_new_sha256": file.newSHA, "text": file.text, "diff": file.unified]
        if !file.oldSHA.isEmpty { out["file_old_sha256"] = file.oldSHA }
        return out
    }

    private static var others: [[String: Any]] {[
        ["kind": "group", "name": "yard-builders", "action": "create"],
        ["kind": "group", "name": "yard-reviewers", "action": "create"],
        // Fields the phone reads none of, passed over.
        ["kind": "group", "name": "yard-assembly", "action": "create", "env": ["YARDR_LAND=squash"], "keeps": ["limit"]],
        ["kind": "route", "name": "stage new", "action": "create"],
        ["kind": "route", "name": "stage review", "action": "create"],
        ["kind": "route", "name": "stage approved", "action": "create"],
    ]}

    private static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The `Bead` reply for a bead holding the one ask, a pack apply of
    /// starter: a summary card, or a whole one.
    static func bead(_ id: String, files: [File], folded: Int = 0, sources: [(name: String, text: String, file: String)] = [], summary: Bool = true) -> String {
        let card = sentences(files: files, folded: folded, sources: sources.map { $0.name })
        var run: [String: Any] = [
            "argv": ["pack", "apply", "starter", "--depot", "yard", "--flow", "default"],
            "command": "yardr pack apply starter --depot yard --flow default",
            "description": "Import a pack into a depot: set the yard to what the pack says",
            "does": card.does,
            "back": "no one command takes it back: read the standing state with yardr pack check starter --depot yard in a terminal",
            "pack": [
                "name": "starter", "kind": "git", "depot": "yard", "label": label,
                "mappings": ["flow": "default"],
                "plan": ["objects": files.map(object) + others],
                "digest": digest,
            ] as [String: Any],
        ]
        if summary {
            var pack = run["pack"] as! [String: Any]
            pack["summary"] = true
            pack["files"] = zip(files, card.lines).map { ["name": $0.name, "line": $1] as [String: Any] }
            run["pack"] = pack
        }
        if !sources.isEmpty {
            run["carried"] = sources.map { source in
                ["name": source.name, "text": source.text,
                 "files": [["program": source.file, "text": "#!/bin/sh\nexit 0\n", "sha256": sha256("#!/bin/sh\nexit 0\n")]]] as [String: Any]
            }
        }
        let made = files.map { "file " + $0.name } + ["group yard-builders", "group yard-reviewers", "group yard-assembly"]
        return json(["result": [
            "id": id, "title": "Install starter", "body": "", "stage": "new", "labels": [String](), "notes": [Any](),
            "asks": [[
                "ask": 61, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z",
                "question": "Install the starter pack into depot yard?",
                "context": ["The depot yard has no way of working yet."], "options": [Any](), "state": "open",
                "run": run,
                "weight": [["class": "code", "line": "the first install of pack starter into depot yard makes \(and(made))"]],
            ]],
        ]])
    }

    /// starter's summary card.
    static var starter: String { bead("yd-pack", files: files) }

    /// The same pack as a whole card: sentences, the plan and no summary.
    static var whole: String { bead("yd-pack-whole", files: Array(files.prefix(2)), summary: false) }

    /// A summary card whose plan changes a file, folds the last file into
    /// the closing count and adds a source.
    static var moved: String {
        let changed = File(
            name: "roles/builder.md", text: "# Builder\n\nYou implement one bead.\n", action: "change",
            diff: "--- roles/builder.md\n+++ roles/builder.md\n@@ -1,3 +1,3 @@\n # Builder\n \n-You implement a bead.\n+You implement one bead.\n",
            oldSHA: sha256("# Builder\n\nYou implement a bead.\n"))
        let list = [changed] + Array(files.dropFirst().prefix(3)) + [files[files.count - 1]]
        return bead("yd-pack-moved", files: list, folded: 1,
                    sources: [(name: "wired", text: "name: wired\nbase: https://wired.example.com/v1\n", file: "wired/limits")])
    }
}
