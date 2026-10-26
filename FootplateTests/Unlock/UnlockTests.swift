@testable import Footplate
import XCTest

// The unlock's plain functions (design 3.4, after Android's
// UnlockTest.kt): which picks pass the gate, what the prompt says,
// which gate a phone offers, and the number typed back where it has
// no screen lock. Run and setup approvals are always behind the gate:
// the model tests pin that, since it is the model's rule, not a plain
// function's.
final class UnlockTests: XCTestCase {
    private let asUser = [AskWeight(kind: "as-user", line: "writes who a sender is: U024BE7LH on slack becomes a user of the yard")]
    private let slack = Identity(source: "slack", sender: "U024BE7LH", channel: "C1")

    /// A mapping ask's options as the yard writes them: the users,
    /// someone new, nobody, and you decide last.
    private let mapping = [
        AskOption(label: "jo", consequence: "messages from U024BE7LH count as jo's"),
        AskOption(label: "Someone new", consequence: "pick this and write the new user's name with your answer"),
        AskOption(label: mappingNobody, consequence: "ignores U024BE7LH in slack"),
        AskOption(label: youDecide, consequence: "leave it to yardmaster"),
    ]

    private let routine = [
        AskOption(label: "Move them now", consequence: "all 64 links point at the new source tonight"),
        AskOption(label: youDecide, consequence: "leave it to yardmaster"),
    ]

    func testWhichPicksPassTheGate() {
        // A mapping pick of a user and of someone new writes an identity.
        XCTAssertTrue(needsGate(weight: asUser, identity: slack, options: mapping, option: 1), "a user")
        XCTAssertTrue(needsGate(weight: asUser, identity: slack, options: mapping, option: 2), "someone new")
        // Nobody and you decide write none, and go without the gate.
        XCTAssertFalse(needsGate(weight: asUser, identity: slack, options: mapping, option: 3), "nobody")
        XCTAssertFalse(needsGate(weight: asUser, identity: slack, options: mapping, option: 4), "you decide")
        // A class the phone does not know is weighty all the same.
        let unknown = [AskWeight(kind: "rails", line: "a class of a later yard")]
        XCTAssertTrue(needsGate(weight: unknown, identity: nil, options: routine, option: 1), "an unknown class")
        XCTAssertTrue(needsGate(weight: unknown, identity: nil, options: routine, option: 2), "an unknown class, you decide")
        // A routine card has no weight, and passes no gate.
        XCTAssertFalse(needsGate(weight: [], identity: nil, options: routine, option: 1), "a routine card")
        // A mapping ask a yard from before cards were weighed wrote:
        // no weight, no gate.
        XCTAssertFalse(needsGate(weight: [], identity: slack, options: mapping, option: 1), "an unweighed mapping card")
        // An option the card does not have is gated: in doubt, the gate.
        XCTAssertTrue(needsGate(weight: asUser, identity: slack, options: mapping, option: 9), "an option past the card's")
        // `You decide` other than last is no you decide of the yard's.
        let odd = [AskOption(label: youDecide, consequence: ""), AskOption(label: "jo", consequence: "")]
        XCTAssertTrue(needsGate(weight: asUser, identity: slack, options: odd, option: 1), "you decide not last")
    }

    func testThePromptSaysWhatIsPickedAndWhereAndIsNeverEmpty() {
        XCTAssertEqual(pickReason(option: "jo", yard: "laptop"), "pick jo in laptop")
        XCTAssertEqual(pickReason(option: "Someone new", yard: "south"), "pick Someone new in south")
        XCTAssertEqual(pickReason(option: "", yard: "laptop"), "pick in laptop")
        XCTAssertEqual(pickReason(option: "jo", yard: ""), "pick jo")
        XCTAssertEqual(pickReason(option: "", yard: ""), "pick")
        XCTAssertEqual(approveReason(what: "yardr depot tidy --merged", yard: "laptop"), "approve yardr depot tidy --merged in laptop")
        XCTAssertEqual(approveReason(what: "setup of courier", yard: "south"), "approve setup of courier in south")
        XCTAssertEqual(approveReason(what: "", yard: "laptop"), "approve in laptop")
        XCTAssertEqual(approveReason(what: "setup of courier", yard: ""), "approve setup of courier")
        XCTAssertEqual(approveReason(what: "", yard: ""), "approve")
    }

    func testAPhoneWithoutAScreenLockTakesTheNumberTypedBack() {
        XCTAssertEqual(gateOf(canEvaluate: true), .prompt)
        XCTAssertEqual(gateOf(canEvaluate: false), .typeBack)
        XCTAssertTrue(typedBack("7", 7))
        XCTAssertTrue(typedBack("7\n", 7), "a pasted line break")
        XCTAssertFalse(typedBack("8", 7))
        XCTAssertFalse(typedBack("", 7))
        XCTAssertFalse(typedBack("ask 7", 7))
    }

    func testYardMachineCommandsArePerTypeAndNeverBare() {
        let bead = "yd-x"
        XCTAssertEqual(secretCommand(bead: bead, ask: 18), "yardr bead answer yd-x 18 --secret")
        let plainRun = Run(argv: ["yardr", "depot", "tidy"], command: "yardr depot tidy", ask: [])
        XCTAssertEqual(approveCommand(bead: bead, ask: 9, run: plainRun), "yardr bead answer yd-x 9 --approve")
        let valuedRun = Run(argv: [], command: "yardr hook add", ask: ["url", "token"])
        XCTAssertEqual(
            approveCommand(bead: bead, ask: 9, run: valuedRun),
            "yardr bead answer yd-x 9 --approve --value url=<value> --value token=<value>"
        )
        let typedSetup = Setup(pack: "courier", candidates: [])
        XCTAssertEqual(setupCommand(bead: bead, ask: 44, option: 2, setup: typedSetup), "yardr bead answer yd-x 44 2 --secret")
        let candidateSetup = Setup(pack: "courier", candidates: [SetupCandidate(source: "courier-existing")])
        XCTAssertEqual(setupCommand(bead: bead, ask: 44, option: 2, setup: candidateSetup), "yardr bead answer yd-x 44 2 --account courier-existing")
        let existingAccount = Setup(
            pack: "courier", given: true,
            candidates: [SetupCandidate(source: "courier-existing")]
        )
        XCTAssertEqual(setupCommand(bead: bead, ask: 44, option: 2, setup: existingAccount), "yardr bead answer yd-x 44 2")
        XCTAssertEqual(pickCommand(bead: bead, ask: 7, option: 1), "yardr bead answer yd-x 7 1 [words]")
    }
}
