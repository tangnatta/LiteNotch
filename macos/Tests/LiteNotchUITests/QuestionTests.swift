import XCTest
@testable import LiteNotchUI

final class QuestionTests: XCTestCase {
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private func questions(multi: Bool = false, count: Int = 1) -> [AgentQuestion] {
        (0..<count).map { i in
            AgentQuestion(header: "H\(i)", question: "Q\(i)?", multiSelect: multi,
                          options: [QuestionOption(label: "A"), QuestionOption(label: "B")])
        }
    }

    func testSingleChoiceReplacesAndTypedTextExcludesAChoice() {
        var d = QuestionDraft(questions())
        d.toggle("A", in: 0); d.toggle("B", in: 0)
        XCTAssertEqual(d.answers, [["B"]])
        d.type("  other ", in: 0)
        XCTAssertEqual(d.answers, [["other"]], "typing replaces the choice")
        d.toggle("A", in: 0)
        XCTAssertEqual(d.answers, [["A"]], "choosing clears the typed text")
        d.toggle("A", in: 0)
        XCTAssertFalse(d.isComplete, "choosing it again takes it back")
    }

    func testMultipleChoiceKeepsEveryPickAndTypedText() {
        var d = QuestionDraft(questions(multi: true))
        d.toggle("A", in: 0); d.toggle("B", in: 0); d.type("C", in: 0)
        XCTAssertEqual(d.answers, [["A", "B", "C"]])
        d.toggle("A", in: 0)
        XCTAssertEqual(d.answers, [["B", "C"]])
    }

    func testSendNeedsEveryQuestionAnsweredAndOnlyOneSingleQuestionSendsOnClick() {
        var d = QuestionDraft(questions(count: 2))
        XCTAssertFalse(d.answersOnClick)
        d.toggle("A", in: 0)
        XCTAssertFalse(d.isComplete)
        d.type("   ", in: 1)
        XCTAssertFalse(d.isComplete, "blank text is not an answer")
        d.toggle("B", in: 1)
        XCTAssertTrue(d.isComplete)
        XCTAssertTrue(QuestionDraft(questions()).answersOnClick)
        XCTAssertFalse(QuestionDraft(questions(multi: true)).answersOnClick)
    }

    func testOutOfRangeIndexesAreIgnored() {
        var d = QuestionDraft(questions())
        d.toggle("A", in: 3); d.type("x", in: -1)
        XCTAssertEqual(d, QuestionDraft(questions()))
    }

    func testTheCommandCarriesOneListPerQuestion() throws {
        let json = ShellCommand.agentAnswer(requestId: "req-1", answers: [["A", "B"], ["x"]]).encode()
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["cmd"] as? String, "agent_answer")
        XCTAssertEqual(obj["request_id"] as? String, "req-1")
        XCTAssertEqual(obj["answers"] as? [[String]], [["A", "B"], ["x"]])
    }

    func testAQuestionOffersNoAllowOrDenyAndHasItsOwnHeadline() throws {
        let r = PermissionRequest(id: "r", sessionId: "s", project: "LiteNotch", toolName: "AskUserQuestion",
                                  summary: "", detail: "{}", truncated: true, createdMs: 0, expiresMs: 1,
                                  questions: questions())
        let p = ApprovalPresentation(r)
        XCTAssertTrue(p.isQuestion)
        XCTAssertEqual(p.offeredDecisions, [.pass])
        XCTAssertFalse(p.showTruncatedNotice)
        XCTAssertEqual(ApprovalPresentation.headline(r), "Claude Code has a question in LiteNotch")
    }

    func testARequestWithoutQuestionsDecodes() throws {
        let json = #"{"id":"r","session_id":"s","project":"p","tool_name":"Bash","summary":"ls","detail":"ls","created_ms":0,"expires_ms":1}"#
        let r = try Self.decoder.decode(PermissionRequest.self, from: Data(json.utf8))
        XCTAssertTrue(r.questions.isEmpty)
        let q = #"{"id":"r","session_id":"s","project":"p","tool_name":"AskUserQuestion","summary":"","detail":"","created_ms":0,"expires_ms":1,"questions":[{"header":"h","question":"q","multi_select":true,"options":[{"label":"A","description":"d"}]}]}"#
        let withQ = try Self.decoder.decode(PermissionRequest.self, from: Data(q.utf8))
        XCTAssertTrue(withQ.questions[0].multiSelect)
        XCTAssertEqual(withQ.questions[0].options[0].description, "d")
    }

    func testSeveralQuestionsAreAskedOneAtATimeAndNextNeedsAnAnswer() {
        var d = QuestionDraft(questions(count: 3))
        XCTAssertEqual(d.step, 0); XCTAssertEqual(d.count, 3); XCTAssertFalse(d.isLast)
        d.next()
        XCTAssertEqual(d.step, 0, "no answer, no next")
        d.toggle("A", in: 0); d.next()
        XCTAssertEqual(d.step, 1)
        d.back()
        XCTAssertEqual(d.step, 0)
        d.back()
        XCTAssertEqual(d.step, 0)
        d.next(); d.toggle("B", in: 1); d.next()
        XCTAssertTrue(d.isLast)
        d.next()
        XCTAssertEqual(d.step, 2, "stops on the last")
        XCTAssertFalse(d.isComplete)
        d.type("x", in: 2)
        XCTAssertTrue(d.isComplete)
    }

    func testAnOpenQuestionHasOnlyTheTypedLine() {
        let open = AgentQuestion(header: "", question: "Name?", options: [])
        var d = QuestionDraft([open])
        XCTAssertTrue(d.isOpen(0))
        XCTAssertFalse(d.movesOnClick(0))
        XCTAssertFalse(d.answersOnClick, "typing needs Send")
        XCTAssertFalse(d.isComplete)
        d.type("greet", in: 0)
        XCTAssertEqual(d.answers, [["greet"]])
    }

    func testOnlySingleChoiceMovesOnByItself() {
        let d = QuestionDraft(questions(count: 2) + questions(multi: true))
        XCTAssertTrue(d.movesOnClick(0))
        XCTAssertFalse(d.movesOnClick(2))
        XCTAssertFalse(d.answersOnClick, "several questions need Send at the end")
        XCTAssertEqual(d.given(2), 0)
    }

    func testMultipleChoiceTakesSeveralOfTheUsersOwnAnswers() {
        var d = QuestionDraft(questions(multi: true))
        d.toggle("A", in: 0)
        d.type("first", in: 0); d.commit(0)
        d.type("  second ", in: 0); d.commit(0)
        XCTAssertEqual(d.typed[0], "", "the line is empty again after adding")
        XCTAssertEqual(d.extras[0], ["first", "second"])
        d.type("third", in: 0)
        XCTAssertEqual(d.answers, [["A", "first", "second", "third"]], "text still in the line counts")
        d.removeExtra(at: 0, in: 0)
        XCTAssertEqual(d.answers, [["A", "second", "third"]])
    }

    func testAnOwnAnswerIsNotAddedTwiceOrWhenBlank() {
        var d = QuestionDraft(questions(multi: true))
        d.type("x", in: 0); d.commit(0); d.type("x", in: 0); d.commit(0)
        d.type("  ", in: 0); d.commit(0)
        d.toggle("A", in: 0); d.type("A", in: 0); d.commit(0)
        XCTAssertEqual(d.answers, [["A", "x"]])
    }

    func testSingleChoiceKeepsOneLineOnly() {
        var d = QuestionDraft(questions())
        d.type("mine", in: 0); d.commit(0)
        XCTAssertTrue(d.extras[0].isEmpty, "adding is for multiple choice")
        XCTAssertEqual(d.answers, [["mine"]])
        XCTAssertFalse(d.canAdd(0))
    }

    func testTheNumberOfAnswersIsLimited() {
        var d = QuestionDraft(questions(multi: true))
        for i in 0..<(QuestionDraft.maxAnswers + 3) { d.type("n\(i)", in: 0); d.commit(0) }
        XCTAssertEqual(d.answers[0].count, QuestionDraft.maxAnswers)
        XCTAssertFalse(d.canAdd(0))
    }
}
