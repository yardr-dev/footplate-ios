@testable import Footplate
import UIKit
import XCTest

// A long-press on a letter offers its whole text to copy, the
// person's own and the yard's alike; a letter with no text (an
// image alone) offers nothing. A known full id chips in mail, and an
// unknown one is asked about once: the yard confirming it chips it,
// refusing it leaves it plain, and answering nothing for want of a
// link asks again when mail next comes into view. A chip's tap
// presents the bead as a sheet over the conversation, leaving the
// tab alone. An open ask a letter names stands under it as a preview,
// by footplate's rules: a number alone where one bead carries it, the
// bead's own with `on`, once each, in the order named, and gone with
// the board that decides it. A letter's pictures stand in rows keyed by
// their place, so one picture carried twice is two rows under two keys.
// The composer's microphone (footplate-ios-tedd) is held over a fake
// recognizer: the gate read as the composer appears, the first tap's line
// and prompts, the words written after the draft, a stop that keeps them, a
// cross that puts the draft back, a send that ends the recording first,
// what a call, the background or a typed edit does to it, silence and
// failure, and the engine opened once per tap and shut once per recording.
@MainActor
final class ConversationModelTests: XCTestCase {
    private var home: FakeFollowed!
    private var mailroom: Mailroom!
    private var model: ConversationModel!
    private var dictation: FakeDictation!
    private var timers: FakeTimers!

    override func setUp() {
        super.setUp()
        home = FakeFollowed()
        mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        dictation = FakeDictation()
        let timers = FakeTimers()
        self.timers = timers
        let now = parseInstant("2026-10-08T10:11:00Z")!
        // The model's two bounds, the stop's wait for the final words and the
        // quiet time, are waits the test lets go: none ends by itself.
        model = ConversationModel(
            mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! },
            dictation: dictation, finalWait: .seconds(3), quietWait: .seconds(60),
            wait: { try await timers.wait($0) }
        )
    }

    override func tearDown() {
        model.leave()
        model = nil
        mailroom = nil
        home = nil
        dictation = nil
        timers = nil
        super.tearDown()
    }

    func testCopyMessageOffersTheLettersWholeText() {
        let rows: [(text: String, copy: String?)] = [
            ("Meet at the shed.", "Meet at the shed."),
            ("Read https://x.example/a then.", "Read https://x.example/a then."),
            ("", nil),
        ]
        for (text, copy) in rows {
            let theirs = Shown(seq: 1, mine: false, text: text, time: "09:30")
            XCTAssertEqual(copyableMessage(theirs), copy, text)
            let mine = Shown(seq: 2, mine: true, text: text, time: "09:31")
            XCTAssertEqual(copyableMessage(mine), copy, "own: \(text)")
        }
    }

    /// The same bytes picked twice reach the conversation as two files of
    /// one hash. Their rows are keyed by place, in the order drawn: keyed by
    /// the hash they would share one id, which SwiftUI warns of, and may
    /// reuse one row's view for both.
    func testALetterCarryingOnePictureTwiceKeysItsRowsByPlace() {
        let first = ShownImage(hash: "aa", name: "photo 1.jpg", bytes: Data([1]))
        let again = ShownImage(hash: "aa", name: "photo 2.jpg", bytes: Data([1]))
        let other = ShownImage(hash: "bb", name: "photo 3.jpg", missed: true)
        XCTAssertEqual(first.hash, again.hash)
        let letter = Shown(seq: 1, mine: true, text: "", time: "09:30", images: [first, again, other])
        XCTAssertEqual(placedImages(letter), [
            PlacedImage(id: 0, image: first),
            PlacedImage(id: 1, image: again),
            PlacedImage(id: 2, image: other),
        ])
        // A letter of words alone has no row.
        XCTAssertEqual(placedImages(Shown(seq: 2, mine: false, text: "Hello.", time: "09:31")), [])
    }

    /// A known full id chips, and a closed bead chips once the yard
    /// confirms it; the yard is asked once per id the mail names, never
    /// for one the app knows or a bare suffix.
    func testKnownIdsChipAndTheYardConfirmsTheRestOnceEach() async throws {
        home.up(loaded(open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster")]))
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old; yd-links moves next, past bay w311."),
        ], more: false)
        home.holdBeadReads("yd-old", count: 1)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the question") { [home] in home?.beadAsked == ["yd-old"] }
        XCTAssertEqual(model.state.knownBeads, ["yd-links"])
        home.releaseBeadRead("yd-old")
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-links", "yd-old"] }
        XCTAssertEqual(home.beadAsked, ["yd-old"], "the known id and the bare suffix are no question")
    }

    /// An id the yard refuses stays plain, and is asked once: a refusal
    /// answers the question.
    func testAnIdTheYardRefusesStaysPlainAndIsAskedOnce() async throws {
        home.beadRefuse = ApiError.refused(code: "no_bead", message: "no bead yd-old")
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old."),
        ], more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the question") { [home] in home?.beadAsked == ["yd-old"] }
        XCTAssertTrue(model.state.knownBeads.isEmpty)
        // Mail coming into view again asks nothing more.
        model.leave()
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters again") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the second page read") { [home] in home?.completedPageCalls.count == 2 }
        XCTAssertEqual(home.beadAsked, ["yd-old"])
    }

    /// An id the yard did not answer for want of a link is asked again
    /// when mail next comes into view.
    func testAnIdUnansweredForWantOfALinkIsAskedAgain() async throws {
        home.beadRefuse = ApiError.away
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old."),
        ], more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the first question") { [home] in home?.beadAsked == ["yd-old"] }
        try await waitFor("the first answer") { [home] in home?.beadCompleted == ["yd-old"] }
        XCTAssertTrue(model.state.knownBeads.isEmpty)
        home.beadRefuse = nil
        model.leave()
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the second question") { [home] in home?.beadAsked == ["yd-old", "yd-old"] }
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-old"] }
    }

    /// The yard's notices name beads too: a known id chips, and an
    /// unknown one is asked once.
    func testTheYardsNoticesNameBeadsToo() async throws {
        home.up(loaded(
            open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster")],
            notices: [Notification(seq: 11, at: "2026-10-08T09:31:00Z", kind: "noted", bead: "yd-shed", text: "yd-shed noted; see yd-links (ask 3)")]
        ))
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: yardRow)
        try await waitFor("the notices") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-links", "yd-shed"] }
        XCTAssertEqual(home.beadAsked, ["yd-shed"])
        XCTAssertEqual(model.state.letters.map(\.asks), [[]], "a notice names an ask, and no preview stands under it: mail alone has them, as the desktop's")
    }

    /// Reading the state of a long conversation stays cheap
    /// (footplate-ios-g0jx): a stamp per letter once made a fresh
    /// formatter per letter, so one reading of three hundred letters
    /// cost about 67 ms on the simulator and the screen paid it once
    /// per bubble. Fifty readings that took about 3.3 s there must
    /// stay well under this bound; it is a simulator bound, not a
    /// phone's, and set loose for a slower Mac.
    func testReadingALongConversationStateStaysCheap() async throws {
        var all: [Letter] = []
        for seq in 1...300 {
            let mine = seq % 2 == 0
            all.append(Letter(
                seq: Int64(seq), at: "2026-10-08T09:30:00Z",
                from: mine ? "jo" : "yardmaster", to: mine ? "yardmaster" : "jo",
                text: seq % 10 == 0 ? "Is ask 3 on yd-links yours?" : "All quiet through the night watch.", read: true
            ))
        }
        home.up(Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 300,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working")],
            users: [User(name: "jo")],
            inbox: Inbox(mail: all, unread: 0, last: 0, from: []),
            notifications: Notifications(),
            // An open ask the letters name: each reading finds and
            // previews it in thirty of them.
            asks: Asks(open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster", since: "2026-10-08T09:00:00Z")])
        ))
        func page(before: Int64) -> Page {
            let older = before > 0 ? all.filter { $0.seq < before } : all
            let slice = Array(older.suffix(30))
            return Page(letters: slice, more: older.count > slice.count)
        }
        home.pages["yardmaster|0"] = page(before: 0)
        var before: Int64 = 271
        while before > 1 {
            home.pages["yardmaster|\(before)"] = page(before: before)
            before -= 30
        }
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the first page") { [model] in model?.state.letters.count == 30 }
        var loads = 0
        while model.state.more, loads < 20 {
            loads += 1
            await model.older()
        }
        XCTAssertEqual(model.state.letters.count, 300)
        XCTAssertEqual(model.state.letters.filter { !$0.asks.isEmpty }.count, 30)
        // One reading to warm the formatters, then fifty against the clock.
        _ = model.state
        let start = ContinuousClock.now
        for _ in 0..<50 { _ = model.state.letters.count }
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(1500), "fifty readings of a 300 letter state took \(elapsed)")
    }

    /// A chip's tap presents the bead as a sheet over the conversation
    /// and leaves the tab on the crew: nothing is pushed, nowhere
    /// switched. The sheet shuts, and never follows to another
    /// conversation.
    func testAChipsTapPresentsTheSheetAndLeavesTheTabAlone() {
        let nav = Nav()
        model.open(yard: "", with: "yardmaster")
        XCTAssertNil(model.state.sheet)
        model.openBead("yd-old")
        XCTAssertEqual(model.state.sheet, BeadRoute(yard: "", bead: "yd-old"))
        XCTAssertEqual(nav.place, .crew)
        model.closeBeadSheet()
        XCTAssertNil(model.state.sheet)
        model.openBead("yd-old")
        model.open(yard: "", with: "signalman")
        XCTAssertNil(model.state.sheet, "the sheet never follows to another conversation")
    }

    // MARK: - The asks a letter names

    /// An open ask of the queue from the yardmaster, 7 minutes old at the
    /// model's 10:11.
    private func openAsk(_ bead: String, _ ask: Int64, _ question: String = "Move the links?") -> OpenAsk {
        OpenAsk(bead: bead, ask: ask, question: question, asker: "yardmaster", since: "2026-10-08T10:04:00Z")
    }

    private func decidedAsk(_ bead: String, _ ask: Int64) -> DecidedAsk {
        DecidedAsk(bead: bead, ask: ask, question: "Move the links?", asker: "yardmaster", state: "answered")
    }

    private func mail(_ seq: Int64, _ text: String, mine: Bool = false) -> Letter {
        Letter(seq: seq, at: "2026-10-08T09:3\(seq):00Z", from: mine ? "jo" : "yardmaster", to: mine ? "yardmaster" : "jo", text: text)
    }

    /// Opens the conversation with the yardmaster over `letters` and a
    /// board holding `open` and `decided`.
    private func openConversation(_ letters: [Letter], open: [OpenAsk] = [], decided: [DecidedAsk] = []) async throws {
        home.up(loaded(open: open, decided: decided))
        home.pages["yardmaster|0"] = Page(letters: letters, more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == letters.count }
    }

    /// An open ask a letter names, the person's own or another's, stands
    /// under it as the desktop shows it: its kind and number, how long it
    /// waits and the question's first line. A re-ask and a letter that
    /// names none have none.
    func testAnOpenAskALetterNamesStandsUnderIt() async throws {
        try await openConversation([
            mail(1, "I put the grant to you as a card (ask 3)."),
            mail(2, "The turn (yd-zulu) waits, and re-ask 4 stands plain."),
            mail(3, "First.\n\n- See ask 3 again.", mine: true),
        ], open: [openAsk("yardr-n8ta", 3, "Grant yardmaster replace on google-docs?\nIt reads the documents.")])
        let preview = AskPreview(bead: "yardr-n8ta", ask: 3, kind: "ask", question: "Grant yardmaster replace on google-docs?", waits: "7m")
        XCTAssertEqual(model.state.letters.map(\.asks), [[preview], [], [preview]])
        XCTAssertEqual(preview.head, "Waiting on you · ask 3 · asked 7m")
    }

    /// Several asks a letter names stand in the order its words name them,
    /// not the queue's, and one named twice stands once, however it is named.
    func testSeveralAsksStandInTheOrderNamedEachOnce() async throws {
        try await openConversation([
            mail(1, "ask 5 first, ask 3 on yd-b, ask 5 again, ask 3 and ask 2."),
            mail(2, "ask 3, then ask 5 on yd-a."),
        ], open: [openAsk("yd-a", 5), openAsk("yd-b", 3)], decided: [decidedAsk("yd-c", 2)])
        XCTAssertEqual(model.state.letters.map { $0.asks.map(\.id) }, [["yd-a 5", "yd-b 3"], ["yd-b 3", "yd-a 5"]])
    }

    /// A number two beads share, a decided ask and one the yard does not
    /// list stay plain words; with its bead a shared number is one ask
    /// again, and an ask on a bead that does not carry it is none.
    func testASharedDecidedOrUnknownAskStaysPlain() async throws {
        try await openConversation([
            mail(1, "ask 3, ask 99 and ask 2."),
            mail(2, "ask 3 on yardr-n8ta is yours."),
            mail(3, "ask 4 is open on one bead and decided on another."),
            mail(4, "ask 3 on yardr-9zzz and ask 2 on yardr-n8ta."),
        ], open: [openAsk("yardr-n8ta", 3), openAsk("yardr-3msx", 3), openAsk("yardr-4aaa", 4)],
        decided: [decidedAsk("yardr-n8ta", 2), decidedAsk("yardr-4bbb", 4)])
        XCTAssertEqual(model.state.letters.map { $0.asks.map(\.id) }, [[], ["yardr-n8ta 3"], [], []])
    }

    /// A secret ask shows the first line of its question with its kind in
    /// the head, and no value: the queue holds none. A run ask says its
    /// kind. The first line is the first that says something, in plain words.
    func testASecretAndARunAskKeepTheirKindAndTheirFirstLine() async throws {
        let secret = OpenAsk(
            bead: "yd-s", ask: 9, question: "\n  Give yardmaster the GitHub token\r\nand where it goes\u{2028}and more",
            asker: "yardmaster", since: "2026-10-08T10:11:00Z", secret: Secret(source: "github", env: ["TOKEN"], line: "The GitHub token")
        )
        let run = OpenAsk(
            bead: "yd-r", ask: 10, question: "Ring\u{7} the\tbell?",
            asker: "yardmaster", since: "2026-10-06T10:11:00Z", run: Run(command: "yardr doctor")
        )
        try await openConversation([mail(1, "ask 9 and ask 10")], open: [secret, run])
        let asks = model.state.letters[0].asks
        XCTAssertEqual(asks, [
            AskPreview(bead: "yd-s", ask: 9, kind: "secret ask", question: "Give yardmaster the GitHub token", waits: "now"),
            AskPreview(bead: "yd-r", ask: 10, kind: "run ask", question: "Ring the\tbell?", waits: "2d"),
        ])
        XCTAssertEqual(asks.map(\.head), ["Waiting on you · secret ask 9 · asked now", "Waiting on you · run ask 10 · asked 2d"])
        // A part the yard gave no word for leaves the head.
        XCTAssertEqual(AskPreview(bead: "yd-s", ask: 25527, kind: "ask", question: "", waits: "").head, "Waiting on you · ask 25527")
    }

    /// The next board takes the preview of an ask it decides, with nothing
    /// told to the conversation, and gives it back where the ask is open.
    func testThePreviewGoesWithTheNextBoardThatDecidesTheAsk() async throws {
        try await openConversation([mail(1, "Shall I land it (ask 3 on yd-links)?")], open: [openAsk("yd-links", 3)])
        XCTAssertEqual(model.state.letters[0].asks.map(\.id), ["yd-links 3"])
        home.up(loaded(open: [], decided: [decidedAsk("yd-links", 3)]))
        XCTAssertEqual(model.state.letters[0].asks, [])
        home.up(loaded(open: [openAsk("yd-links", 3)]))
        XCTAssertEqual(model.state.letters[0].asks.map(\.id), ["yd-links 3"])
    }

    /// How long an ask waits, as the desktop's `waits` says it: whole
    /// minutes under an hour, hours under a day, then days; none for a time
    /// that is none, and `now` for one still to come.
    func testHowLongAnAskWaitsIsSaidAsTheDesktopSaysIt() {
        let now = parseInstant("2026-10-08T10:11:00Z")!
        let rows: [(since: String, said: String)] = [
            ("2026-10-08T10:11:00Z", "now"),
            ("2026-10-08T10:10:01Z", "now"),
            ("2026-10-08T10:10:00Z", "1m"),
            ("2026-10-08T10:04:00Z", "7m"),
            // The yard's instants carry fractions; the desktop counts whole seconds.
            ("2026-10-08T10:04:00.9Z", "7m"),
            ("2026-10-08T09:12:00Z", "59m"),
            ("2026-10-08T09:11:00Z", "1h"),
            ("2026-10-08T08:11:00Z", "2h"),
            ("2026-10-07T10:12:00Z", "23h"),
            ("2026-10-07T10:11:00Z", "1d"),
            ("2026-10-05T10:11:00Z", "3d"),
            ("2026-10-08T10:12:30Z", "now"),
            ("", ""),
            ("yesterday", ""),
        ]
        for (since, said) in rows {
            XCTAssertEqual(waits(since, now: now), said, since)
        }
    }

    // MARK: - Dictation (footplate-ios-tedd)

    /// The microphone is drawn from the gate as the phone answers when the
    /// composer reads it, and from nothing before: not from an earlier
    /// read, and no prompt or microphone is made ready by reading. A model
    /// downloaded, or a consent changed in Settings, shows at the next read.
    func testTheMicrophoneIsDrawnFromTheGateReadAtTheComposersAppearanceAndNeverKept() async throws {
        try await openConversation([])
        XCTAssertEqual(dictation.standingReads, 0)
        XCTAssertEqual(model.state.dictation, DictationShown())
        dictation.current = DictationStanding(onDevice: false, speech: .granted, microphone: .granted)
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown())
        dictation.current.onDevice = true
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(microphone: true))
        dictation.current.speech = .denied
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(line: refusalWords(.speechDenied), settings: true))
        dictation.current.speech = .granted
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(microphone: true))
        XCTAssertEqual(dictation.standingReads, 4, "every read asks the phone")

        // Where no locale hears on the device, the composer says so once
        // per conversation open, naming the language, with no microphone or
        // Settings link (footplate-ios-sz3n). A later read keeps the line;
        // it leaves with the gate, and the next open is told again.
        dictation.current = DictationStanding(onDevice: false, speech: .granted, microphone: .granted, language: "English")
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(line: unheardWords("English"), settings: false))
        XCTAssertFalse(model.state.dictation.microphone)
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation.line, unheardWords("English"))
        dictation.current.onDevice = true
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(microphone: true))
        dictation.current.onDevice = false
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown())
        model.leave()
        try await openConversation([])
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation.line, unheardWords("English"))
        XCTAssertFalse(model.state.dictation.microphone)

        // Reading made nothing ready: no prompt, no microphone.
        XCTAssertEqual(dictation.begun, 0)
        XCTAssertTrue(dictation.asked.isEmpty)
        // The yard's notices are read, not answered: no field, no microphone.
        model.open(yard: "", with: yardRow)
        XCTAssertEqual(model.state.dictation, DictationShown())
    }

    /// An icon drawn from a read that the phone has since contradicted
    /// records nothing: the tap reads the gate again, and asks nothing.
    func testATapWhereThePhoneDoesNotHearOnTheDeviceOpensNothing() async throws {
        try await openConversation([])
        dictation.current = DictationStanding(onDevice: true, speech: .undecided, microphone: .undecided)
        model.readDictationGate()
        XCTAssertTrue(model.state.dictation.microphone)
        dictation.current.onDevice = false
        await model.dictate()
        XCTAssertEqual(model.state.dictation, DictationShown())
        XCTAssertEqual(dictation.begun, 0)
        XCTAssertTrue(dictation.asked.isEmpty)
    }

    /// The first tap says what is heard and where it goes, then asks for
    /// speech, then for the microphone, then records, in that order and
    /// never the microphone before the prompts are answered. The line
    /// stands while that recording does, and a later tap asks and says
    /// nothing.
    func testTheFirstTapSaysWhatIsHeardThenAsksSpeechThenTheMicrophoneThenRecords() async throws {
        try await openConversation([])
        dictation.current = DictationStanding(onDevice: true, speech: .undecided, microphone: .undecided)
        dictation.holdPrompts = true
        model.readDictationGate()
        let tap = Task { await model.dictate() }
        try await waitFor("the first tap's line") { [model] in model?.state.dictation.line == dictationLine }
        XCTAssertEqual(model.state.dictation.recording, .starting)
        XCTAssertEqual(dictation.begun, 0, "no microphone before the prompts are answered")
        dictation.answerPrompts()
        await tap.value
        XCTAssertEqual(dictation.asked, ["speech", "microphone"])
        XCTAssertEqual(dictation.begun, 1)
        XCTAssertEqual(model.state.dictation.recording, .listening)
        XCTAssertEqual(model.state.dictation.line, dictationLine)
        model.cancelDictation()
        XCTAssertNil(model.state.dictation.line)
        dictation.holdPrompts = false
        await model.dictate()
        XCTAssertEqual(dictation.asked, ["speech", "microphone"], "decided consents are not asked again")
        XCTAssertEqual(dictation.begun, 2)
        XCTAssertNil(model.state.dictation.line)
        model.cancelDictation()
    }

    /// The words heard are written after the draft as they come, the field
    /// taking each write; a stop shuts the microphone at once and keeps the
    /// words the recognizer ends with, and the strip's bars read the sound
    /// while it is heard.
    func testTheWordsHeardAreWrittenAfterTheDraftAndAStopKeepsThem() async throws {
        try await openConversation([])
        model.readDictationGate()
        model.draft("Land")
        await model.dictate()
        XCTAssertEqual(model.state.dictation.recording, .listening)
        let run = dictation.run
        let written = model.state.dictation.written
        run.level(0.4)
        try await waitFor("the sound") { [model] in model?.levels == [0.4] }
        run.say("it")
        try await waitFor("the first words") { [model] in model?.state.draft == "Land it" }
        XCTAssertGreaterThan(model.state.dictation.written, written, "the field takes what the model wrote")
        run.say("it tonight")
        try await waitFor("the next words") { [model] in model?.state.draft == "Land it tonight" }
        let stop = Task { await model.stopDictation() }
        try await waitFor("the stop") { [model] in model?.state.dictation.recording == .finishing }
        XCTAssertEqual(run.finishes, 1)
        XCTAssertEqual(dictation.stopped, 1, "the microphone is shut at the stop, before the final")
        run.say("it tonight.", final: true)
        await stop.value
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(model.state.draft, "Land it tonight.")
        XCTAssertTrue(model.levels.isEmpty)
        XCTAssertEqual(dictation.begun, 1)
        XCTAssertEqual(dictation.stopped, 1)
    }

    /// A cross drops what was heard and puts the draft back as it was at the
    /// tap, empty or not; the field follows the model's write.
    func testACrossDropsTheWordsAndPutsBackTheDraftAsItWasAtTheTap() async throws {
        try await openConversation([])
        model.readDictationGate()
        for before in ["Land", ""] {
            model.draft(before)
            await model.dictate()
            let run = dictation.run
            run.say("it tonight")
            try await waitFor("the words") { [model] in model?.state.draft == dictated(before, "it tonight") }
            let written = model.state.dictation.written
            model.cancelDictation()
            XCTAssertEqual(model.state.draft, before)
            XCTAssertGreaterThan(model.state.dictation.written, written, "the field takes the draft put back")
            XCTAssertNil(model.state.dictation.recording)
            XCTAssertFalse(run.microphoneOpen)
            // What the recognizer says after is nobody's.
            run.say("and more", final: true)
            for _ in 0..<5 { await Task.yield() }
            XCTAssertEqual(model.state.draft, before)
        }
        XCTAssertEqual(dictation.begun, 2)
        XCTAssertEqual(dictation.stopped, 2)
    }

    /// A send that finds a recording stops it, waits for the final, takes
    /// the words into the letter and sends them with what was typed; one
    /// that heard nothing sends nothing.
    func testASendDuringARecordingStopsInsertsAndSends() async throws {
        try await openConversation([])
        model.readDictationGate()
        model.draft("Land")
        await model.dictate()
        dictation.run.say("it tonight")
        try await waitFor("the words") { [model] in model?.state.draft == "Land it tonight" }
        let sending = Task { await model.send() }
        try await waitFor("the stop a send makes") { [model] in model?.state.dictation.recording == .finishing }
        XCTAssertEqual(home.mailCalls, 0, "nothing goes before the final settles")
        dictation.run.say("it tonight.", final: true)
        await sending.value
        XCTAssertEqual(home.sent.map { "\($0.0)|\($0.1)" }, ["yardmaster|Land it tonight."])
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(model.state.draft, "")
        XCTAssertEqual(dictation.stopped, 1)

        await model.dictate()
        let silent = Task { await model.send() }
        try await waitFor("the stop") { [model] in model?.state.dictation.recording == .finishing }
        dictation.run.say("", final: true)
        await silent.value
        XCTAssertEqual(home.mailCalls, 1, "a recording that heard nothing sends nothing")
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(dictation.begun, 2)
        XCTAssertEqual(dictation.stopped, 2)
    }

    /// A call that takes the microphone, the app going to the background and
    /// the screen being left each end the recording where it stands: the
    /// microphone shut, the words heard kept in the draft.
    func testACallTheBackgroundAndTheScreenLeavingEndTheRecordingWithItsWordsStanding() async throws {
        try await openConversation([])
        model.readDictationGate()
        let endings: [(String, @MainActor () -> Void)] = [
            ("a call takes the microphone", { [self] in dictation.run.interrupt() }),
            ("the app goes to the background", { [self] in model.backgrounded() }),
            ("the screen is left", { [self] in model.leave() }),
        ]
        var recordings = 0
        for (what, end) in endings {
            model.open(yard: "", with: "yardmaster")
            model.draft("Land")
            await model.dictate()
            recordings += 1
            XCTAssertEqual(model.state.dictation.recording, .listening, what)
            dictation.run.say("it tonight")
            try await waitFor(what) { [model] in model?.state.draft == "Land it tonight" }
            end()
            try await waitFor(what) { [model] in model?.state.dictation.recording == nil }
            XCTAssertEqual(model.state.draft, "Land it tonight", what)
            XCTAssertEqual(dictation.begun, recordings, what)
            XCTAssertEqual(dictation.stopped, recordings, what)
            XCTAssertFalse(dictation.run.microphoneOpen, what)
        }
    }

    /// Silence says nothing and writes nothing: an empty final, or the
    /// recognizer's word that it heard no speech, ends the recording with the
    /// draft as it was and no error under the field.
    func testSilenceInsertsNothingAndSaysNothing() async throws {
        try await openConversation([])
        model.readDictationGate()
        let endings: [(String, @MainActor (FakeRun) -> Void)] = [
            ("an empty final", { $0.say("", final: true) }),
            ("no speech heard", { $0.fail(.notHeard) }),
        ]
        for (what, end) in endings {
            model.draft("Land")
            await model.dictate()
            end(dictation.run)
            try await waitFor(what) { [model] in model?.state.dictation.recording == nil }
            XCTAssertEqual(model.state.draft, "Land", what)
            XCTAssertNil(model.state.error, what)
        }
        XCTAssertEqual(dictation.begun, 2)
        XCTAssertEqual(dictation.stopped, 2)
    }

    /// A recognizer that fails says so under the field, in words, and the
    /// words it had given stand; the next tap clears the line. A stop names
    /// the domain and code it stopped with, so that a person on a real
    /// device can tell us what the recognizer said (footplate-ios-p2py),
    /// and what primes a device that has never dictated
    /// (footplate-ios-f8bt); the other failures say no word of the keyboard.
    func testATaskErrorIsSaidUnderTheFieldAndTheWordsStand() async throws {
        try await openConversation([])
        model.readDictationGate()
        for failure in [DictationFailure.stopped(domain: "kAFAssistantErrorDomain", code: 203), .unavailable, .couldNotStart] {
            model.draft("Land")
            await model.dictate()
            XCTAssertNil(model.state.error, "a tap clears the line before it")
            dictation.run.say("it")
            try await waitFor("\(failure)") { [model] in model?.state.draft == "Land it" }
            dictation.run.fail(failure)
            try await waitFor("\(failure)") { [model] in model?.state.dictation.recording == nil }
            XCTAssertEqual(model.state.error, failure.words)
            XCTAssertNotNil(model.state.error)
            if case .stopped(let domain, let code) = failure {
                XCTAssertTrue(
                    model.state.error?.contains("(\(domain) \(code))") == true,
                    "the line names the domain and code: \(model.state.error ?? "none")"
                )
                XCTAssertTrue(
                    model.state.error?.contains("dictate once from the keyboard's microphone") == true,
                    "the line tells what primes the device: \(model.state.error ?? "none")"
                )
            } else {
                XCTAssertFalse(
                    model.state.error?.contains("keyboard") == true,
                    "only a stop tells of the keyboard: \(model.state.error ?? "none")"
                )
            }
            XCTAssertEqual(model.state.draft, "Land it")
        }
        XCTAssertEqual(dictation.begun, 3)
        XCTAssertEqual(dictation.stopped, 3)
    }

    /// A recognizer that will not begin leaves the microphone shut and says
    /// so; where it no longer hears on the device the microphone goes too.
    func testARecognizerThatWillNotBeginLeavesTheMicrophoneShutAndSaysSo() async throws {
        try await openConversation([])
        model.readDictationGate()
        dictation.beginFails = .couldNotStart
        await model.dictate()
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(model.state.error, DictationFailure.couldNotStart.words)
        XCTAssertTrue(model.state.dictation.microphone)
        XCTAssertEqual(dictation.begun, 0)
        dictation.beginFails = .unavailable
        dictation.whenBegun = { [dictation] in dictation?.current.onDevice = false }
        await model.dictate()
        XCTAssertEqual(model.state.error, DictationFailure.unavailable.words)
        XCTAssertEqual(model.state.dictation, DictationShown())
        XCTAssertEqual(dictation.begun, 0)
    }

    /// A refused consent hides the microphone and names which it was: speech
    /// first, and the microphone is never asked after it; a restricted one
    /// asks nothing; each with the way to Settings. The consent given back
    /// there shows when the app next reads the gate.
    func testADeniedOrRestrictedConsentHidesTheMicrophoneAndNamesWhichWasRefused() async throws {
        try await openConversation([])
        dictation.current = DictationStanding(onDevice: true, speech: .undecided, microphone: .undecided)
        dictation.speechAnswer = .denied
        model.readDictationGate()
        await model.dictate()
        XCTAssertEqual(dictation.asked, ["speech"], "the microphone is not asked after a refusal")
        XCTAssertEqual(model.state.dictation, DictationShown(line: refusalWords(.speechDenied), settings: true))

        dictation.current = DictationStanding(onDevice: true, speech: .granted, microphone: .undecided)
        dictation.microphoneAnswer = .denied
        model.readDictationGate()
        await model.dictate()
        XCTAssertEqual(dictation.asked, ["speech", "microphone"])
        XCTAssertEqual(model.state.dictation, DictationShown(line: refusalWords(.microphoneDenied), settings: true))

        dictation.current = DictationStanding(onDevice: true, speech: .restricted, microphone: .granted)
        model.readDictationGate()
        await model.dictate()
        XCTAssertEqual(dictation.asked, ["speech", "microphone"])
        XCTAssertEqual(model.state.dictation, DictationShown(line: refusalWords(.speechRestricted), settings: true))
        XCTAssertEqual(dictation.begun, 0)

        dictation.current = DictationStanding(onDevice: true, speech: .granted, microphone: .granted)
        model.readDictationGate()
        XCTAssertEqual(model.state.dictation, DictationShown(microphone: true))
    }

    /// The person's own edit while a recording stands ends it with the words
    /// heard so far, which are in the text they edited; nothing more is
    /// written over it.
    func testAnEditWhileARecordingStandsEndsItKeepingTheWords() async throws {
        try await openConversation([])
        model.readDictationGate()
        model.draft("Land")
        await model.dictate()
        let run = dictation.run
        run.say("it tonight")
        try await waitFor("the words") { [model] in model?.state.draft == "Land it tonight" }
        model.draft("Land it tonight, please")
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(model.state.draft, "Land it tonight, please")
        XCTAssertEqual(dictation.stopped, 1)
        run.say("it tonight now", final: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(model.state.draft, "Land it tonight, please")
    }

    /// A stop does not wait for a recognizer that never says it is done: at
    /// the bound the words that stand are the words.
    func testAStopWaitsForTheFinalOnlyAsLongAsTheBound() async throws {
        try await openConversation([])
        model.readDictationGate()
        model.draft("Land")
        await model.dictate()
        dictation.run.say("it tonight")
        try await waitFor("the words") { [model] in model?.state.draft == "Land it tonight" }
        let stop = Task { await model.stopDictation() }
        try await waitFor("the bound") { [timers] in timers?.waiting.contains(.seconds(3)) == true }
        XCTAssertEqual(model.state.dictation.recording, .finishing)
        timers.fire(.seconds(3))
        await stop.value
        XCTAssertNil(model.state.dictation.recording)
        XCTAssertEqual(model.state.draft, "Land it tonight")
        XCTAssertEqual(dictation.stopped, 1)
        XCTAssertNil(model.state.error)
    }

    /// A recording that hears no words ends itself after the quiet time, the
    /// microphone shut and nothing said; words begin the quiet time again,
    /// and a stop takes the timer away.
    func testARecordingThatHearsNoWordsEndsItselfAfterTheQuietTime() async throws {
        try await openConversation([])
        model.readDictationGate()
        model.draft("Land")
        await model.dictate()
        try await waitFor("the quiet timer") { [timers] in timers?.waiting == [.seconds(60)] }
        dictation.run.say("it")
        try await waitFor("the words") { [model] in model?.state.draft == "Land it" }
        try await waitFor("the quiet time begun again") { [timers] in timers?.started.count == 2 }
        XCTAssertEqual(timers.waiting, [.seconds(60)], "the earlier timer is gone, one stands")
        XCTAssertEqual(model.state.dictation.recording, .listening)
        timers.fire(.seconds(60))
        try await waitFor("the quiet end") { [model] in model?.state.dictation.recording == nil }
        XCTAssertEqual(model.state.draft, "Land it", "the words that stand are kept")
        XCTAssertNil(model.state.error)
        XCTAssertEqual(dictation.stopped, 1)
        XCTAssertTrue(timers.waiting.isEmpty)

        // One that heard nothing at all ends with the draft as it was.
        await model.dictate()
        try await waitFor("the quiet timer") { [timers] in timers?.waiting == [.seconds(60)] }
        timers.fire(.seconds(60))
        try await waitFor("the quiet end") { [model] in model?.state.dictation.recording == nil }
        XCTAssertEqual(model.state.draft, "Land it")
        XCTAssertEqual(dictation.begun, 2)
        XCTAssertEqual(dictation.stopped, 2)

        // A stop takes the quiet timer away: it cannot end what it did not start.
        await model.dictate()
        try await waitFor("the quiet timer") { [timers] in timers?.waiting == [.seconds(60)] }
        let stop = Task { await model.stopDictation() }
        try await waitFor("the bound") { [timers] in timers?.waiting == [.seconds(3)] }
        dictation.run.say("", final: true)
        await stop.value
        XCTAssertTrue(timers.waiting.isEmpty)
    }

    /// The cross, tapped while the prompts stand, starts nothing: the
    /// microphone is not opened when they are answered.
    func testTheCrossWhileThePromptsStandStartsNothing() async throws {
        try await openConversation([])
        dictation.current = DictationStanding(onDevice: true, speech: .undecided, microphone: .undecided)
        dictation.holdPrompts = true
        model.readDictationGate()
        let tap = Task { await model.dictate() }
        try await waitFor("the prompts") { [model] in model?.state.dictation.recording == .starting }
        model.cancelDictation()
        XCTAssertEqual(model.state.dictation, DictationShown(microphone: true))
        dictation.answerPrompts()
        await tap.value
        XCTAssertEqual(dictation.begun, 0)
        XCTAssertNil(model.state.dictation.recording)
    }

    /// The microphone is opened once for each tap that records and shut once
    /// for each recording, however it ended, and a tap that is turned away
    /// opens none.
    func testTheMicrophoneIsOpenedOncePerRecordingAndShutOnce() async throws {
        try await openConversation([])
        model.readDictationGate()
        // Ended by a stop, by a cross and by a call.
        await model.dictate()
        let stopping = Task { await model.stopDictation() }
        try await waitFor("the stop") { [model] in model?.state.dictation.recording == .finishing }
        dictation.run.say("one", final: true)
        await stopping.value
        await model.dictate()
        model.cancelDictation()
        await model.dictate()
        dictation.run.interrupt()
        try await waitFor("the call") { [model] in model?.state.dictation.recording == nil }
        XCTAssertEqual(dictation.begun, 3)
        XCTAssertEqual(dictation.stopped, 3)
        XCTAssertTrue(dictation.runs.allSatisfy { !$0.microphoneOpen })
        // A tap while one stands opens no second, and a refused one none.
        await model.dictate()
        await model.dictate()
        XCTAssertEqual(dictation.begun, 4)
        model.cancelDictation()
        dictation.current.speech = .denied
        await model.dictate()
        XCTAssertEqual(dictation.begun, 4)
        XCTAssertEqual(dictation.stopped, 4)
    }

    // MARK: - Helpers

    private func waitFor(_ what: String, _ match: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !match() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)")
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loaded(open: [OpenAsk] = [], decided: [DecidedAsk] = [], notices: [Footplate.Notification] = []) -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 10,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [],
            users: [],
            inbox: Inbox(),
            notifications: Notifications(notifications: notices),
            asks: Asks(open: open, decided: decided)
        )
    }
}
