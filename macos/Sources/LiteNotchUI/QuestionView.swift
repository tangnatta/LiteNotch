import SwiftUI

/// What the user has picked so far for one request's questions. Pure, so the
/// rules (single choice replaces, typed text and a choice exclude each other
/// for single choice, nothing is sent until every question has an answer)
/// are tested without a view.
public struct QuestionDraft: Equatable {
    public private(set) var picked: [[String]]
    public private(set) var typed: [String]
    /// Multiple choice only: answers of the user's own already added, any number.
    public private(set) var extras: [[String]]
    /// The most answers one question takes (also the core's limit).
    public static let maxAnswers = 16
    /// The question on screen; several questions are asked one at a time.
    public private(set) var step = 0
    /// Option notes opened in full ("question.option"); the rest show
    /// `noteLimit` characters and a "More" button.
    public private(set) var expandedNotes: Set<String> = []
    public static let noteLimit = 200
    /// Questions opened in full; a long one shows `questionLimit`
    /// characters and an inline "More", like a long note.
    public private(set) var expandedQuestions: Set<Int> = []
    public static let questionLimit = 200
    private let multi: [Bool]
    private let open: [Bool]

    public init(_ questions: [AgentQuestion]) {
        picked = Array(repeating: [], count: questions.count)
        typed = Array(repeating: "", count: questions.count)
        extras = Array(repeating: [], count: questions.count)
        multi = questions.map(\.multiSelect)
        open = questions.map { $0.options.isEmpty }
    }

    public var count: Int { picked.count }
    public var isLast: Bool { step >= count - 1 }
    /// The question on screen has an answer.
    public var currentAnswered: Bool { !answers[step].isEmpty }
    /// No choices to pick from: the typed line is the whole answer.
    public func isOpen(_ q: Int) -> Bool { open.indices.contains(q) && open[q] }
    public func isMulti(_ q: Int) -> Bool { multi.indices.contains(q) && multi[q] }
    /// The note has more than the short view shows.
    public static func isLongNote(_ note: String) -> Bool { note.count > noteLimit }
    public func isExpanded(_ q: Int, _ i: Int) -> Bool { expandedNotes.contains("\(q).\(i)") }
    public mutating func toggleNote(_ q: Int, _ i: Int) {
        let key = "\(q).\(i)"
        if !expandedNotes.insert(key).inserted { expandedNotes.remove(key) }
    }
    /// What to draw of a note: all of it when opened, else the first
    /// `noteLimit` characters ending in an ellipsis.
    public func shownNote(_ note: String, _ q: Int, _ i: Int) -> String {
        guard Self.isLongNote(note), !isExpanded(q, i) else { return note }
        return String(note.prefix(Self.noteLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
    /// The question has more than the short view shows.
    public static func isLongQuestion(_ text: String) -> Bool { text.count > questionLimit }
    public func isQuestionExpanded(_ q: Int) -> Bool { expandedQuestions.contains(q) }
    public mutating func toggleQuestion(_ q: Int) {
        if !expandedQuestions.insert(q).inserted { expandedQuestions.remove(q) }
    }
    /// What to draw of a question: all of it when opened, else the first
    /// `questionLimit` characters ending in an ellipsis.
    public func shownQuestion(_ text: String, _ q: Int) -> String {
        guard Self.isLongQuestion(text), !isQuestionExpanded(q) else { return text }
        return String(text.prefix(Self.questionLimit - 1)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
    public mutating func next() { if currentAnswered, !isLast { step += 1 } }
    public mutating func back() { if step > 0 { step -= 1 } }

    public mutating func toggle(_ label: String, in q: Int) {
        guard picked.indices.contains(q) else { return }
        if multi[q] {
            if let i = picked[q].firstIndex(of: label) { picked[q].remove(at: i) } else { picked[q].append(label) }
        } else {
            picked[q] = picked[q] == [label] ? [] : [label]
            typed[q] = ""
        }
    }

    public mutating func type(_ text: String, in q: Int) {
        guard typed.indices.contains(q) else { return }
        typed[q] = text
        if !multi[q], !text.isEmpty { picked[q] = [] }
    }

    /// Multiple choice: the typed text becomes an answer of its own and the
    /// line is empty again for the next. Single choice has just the one line.
    public mutating func commit(_ q: Int) {
        guard extras.indices.contains(q), multi[q] else { return }
        let text = typed[q].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, answers[q].count < Self.maxAnswers else { return }
        if !extras[q].contains(text), !picked[q].contains(text) { extras[q].append(text) }
        typed[q] = ""
    }

    public mutating func removeExtra(at i: Int, in q: Int) {
        guard extras.indices.contains(q), extras[q].indices.contains(i) else { return }
        extras[q].remove(at: i)
    }

    /// Whether one more own answer can still be added.
    public func canAdd(_ q: Int) -> Bool {
        extras.indices.contains(q) && multi[q] && answers[q].count < Self.maxAnswers
    }

    /// One list per question: the chosen labels, the added ones, then the
    /// text still in the line if any.
    public var answers: [[String]] {
        picked.indices.map { q in
            let text = typed[q].trimmingCharacters(in: .whitespacesAndNewlines)
            let base = picked[q] + extras[q]
            return base + (text.isEmpty || base.contains(text) ? [] : [text])
        }
    }

    public var isComplete: Bool { answers.allSatisfy { !$0.isEmpty } }

    /// Picking one choice of a single-choice question moves on by itself:
    /// to the next question, or sends if it was the last.
    public func movesOnClick(_ q: Int) -> Bool { !isMulti(q) && !isOpen(q) }
    /// One single-choice question: no Send button, the click sends.
    public var answersOnClick: Bool { count == 1 && movesOnClick(0) }
    /// How many answers question `q` has, for "Send 2".
    public func given(_ q: Int) -> Int { answers.indices.contains(q) ? answers[q].count : 0 }
}

/// The questions of an `AskUserQuestion`, one layout per kind:
///  - single choice: radio rows, a click answers (and moves on);
///  - multiple choice: checkbox rows, "Choose any", Next / Send counts them;
///  - open question (no choices): a roomy typing field, nothing else;
///  - several questions: a stepper, one at a time, with progress dots, Back
///    and Next, so each fits the panel; Send appears on the last.
/// A line for another answer sits under any choices. Everything is drawn with
/// `verbatim`, and answering stays inert for a moment like Allow does
/// (`ApprovalView.armDelay`).
struct QuestionForm: View {
    let request: PermissionRequest
    let armed: Bool
    let send: (ShellCommand) -> Void
    var keyboard: (Bool) -> Void = { _ in }

    @Environment(\.isSnapshot) private var snapshot
    @State private var draft: QuestionDraft
    /// Which question's line has the keyboard. The panel only becomes a key
    /// window while a field says it is focused (as in the clipboard search).
    @FocusState private var focus: Int?

    /// README previews only: a half-answered form to draw instead of an empty one.
    @MainActor static var previewDraft: QuestionDraft?

    @MainActor init(
        request: PermissionRequest, armed: Bool, send: @escaping (ShellCommand) -> Void,
        keyboard: @escaping (Bool) -> Void = { _ in }
    ) {
        self.request = request
        self.armed = armed
        self.send = send
        self.keyboard = keyboard
        _draft = State(initialValue: Self.previewDraft ?? QuestionDraft(request.questions))
    }

    private var live: Bool { armed || snapshot }

    var body: some View {
        let q = draft.step
        let question = request.questions[q]
        VStack(alignment: .leading, spacing: 8) {
            if draft.count > 1 { progress }
            NotchScroll {
                questionBlock(q, question)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))

            HStack(spacing: 8) {
                button("Answer in Terminal", fg: NT.text1, bg: NT.fillHi, enabled: true) {
                    keyboard(false)
                    send(.agentDecide(requestId: request.id, decision: .pass))
                }
                .help("Show Claude Code\u{2019}s own question in the terminal instead")
                if draft.step > 0 {
                    button("Back", fg: NT.text1, bg: NT.fillHi, enabled: true) { draft.back() }
                }
                if !draft.answersOnClick {
                    if draft.isLast {
                        button(
                            sendTitle, fg: .black, bg: NT.allow,
                            enabled: draft.isComplete && live
                        ) { submit() }
                        .help("Send these answers to Claude Code")
                    } else {
                        button(
                            "Next", fg: .black, bg: NT.allow,
                            enabled: draft.currentAnswered
                        ) { draft.next() }
                    }
                }
            }
        }
        .onDisappear { keyboard(false) }
    }

    private var sendTitle: String {
        let n = draft.count == 1 && draft.isMulti(0) ? draft.given(0) : 0
        return n > 1 ? "Send \(n) answers" : "Send answer"
    }

    /// `Question 2 of 3` with a dot per question; answered ones are filled.
    private var progress: some View {
        HStack(spacing: 6) {
            Text(verbatim: "Question \(draft.step + 1) of \(draft.count)")
                .nfont(.captionStrong).foregroundStyle(NT.text2)
            HStack(spacing: 4) {
                ForEach(0..<draft.count, id: \.self) { i in
                    Circle()
                        .fill(i == draft.step ? NT.accent : (draft.given(i) > 0 ? NT.text2 : NT.fillHi))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Question \(draft.step + 1) of \(draft.count)"))
    }

    /// Return: in multiple choice, adds what is typed; with nothing typed (or in
    /// single choice and open questions) it goes on, like the button.
    private func returnPressed(_ q: Int) {
        if draft.isMulti(q), !draft.typed[q].trimmingCharacters(in: .whitespaces).isEmpty {
            draft.commit(q)
            return
        }
        guard live, draft.currentAnswered else { return }
        focus = nil
        if draft.isLast { submit() } else { draft.next() }
    }

    private func submit() {
        guard draft.isComplete else { return }
        send(.agentAnswer(requestId: request.id, answers: draft.answers))
    }

    /// After a single-choice pick: move on, or send if it was the last.
    private func advance() {
        guard live, draft.currentAnswered else { return }
        if draft.isLast { submit() } else { draft.next() }
    }

    @ViewBuilder
    private func questionBlock(_ q: Int, _ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if !question.header.isEmpty {
                    VText(question.header).nfont(.captionStrong).foregroundStyle(NT.text2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(NT.fillHi, in: Capsule())
                }
                if question.multiSelect {
                    Text(verbatim: "Choose any").nfont(.caption).foregroundStyle(NT.text3)
                }
            }
            Text(questionText(q, question.question))
                .fixedSize(horizontal: false, vertical: true)
                .environment(
                    \.openURL,
                    OpenURLAction { _ in
                        draft.toggleQuestion(q)
                        return .handled
                    })
            ForEach(Array(question.options.enumerated()), id: \.offset) { i, option in
                optionRow(q, i, question, option)
            }
            ForEach(Array(draft.extras[q].enumerated()), id: \.offset) { i, text in
                extraRow(q, i, text)
            }
            otherField(q, roomy: draft.isOpen(q), multi: question.multiSelect)
        }
    }

    /// The question, and for a long one an inline "More" / "Less" at its
    /// end: Claude Code's questions often carry a paragraph of context, which
    /// should not push the choices out of sight.
    private func questionText(_ q: Int, _ text: String) -> AttributedString {
        var out = AttributedString(ApprovalPresentation.visible(draft.shownQuestion(text, q)))
        out.font = NType.emphasis.font
        out.foregroundColor = NT.text1
        if QuestionDraft.isLongQuestion(text) {
            var more = AttributedString(draft.isQuestionExpanded(q) ? " Less" : " More")
            more.font = NType.captionStrong.font
            more.foregroundColor = NT.accent
            more.link = URL(string: "litenotch-question://\(q)")
            out.append(more)
        }
        return out
    }

    /// The option's text: label, its note, and for a long note an inline
    /// "More" / "Less" link at the end. A link, not a button, because the
    /// whole row is the choice and a button cannot sit inside a button.
    private func optionText(_ q: Int, _ i: Int, _ option: QuestionOption) -> AttributedString {
        var label = AttributedString(ApprovalPresentation.visible(option.label))
        label.font = NType.bodyMedium.font
        label.foregroundColor = NT.text1
        guard !option.description.isEmpty else { return label }
        let shown = draft.shownNote(option.description, q, i)
        var note = AttributedString("  " + ApprovalPresentation.visible(shown))
        note.font = NType.caption.font
        note.foregroundColor = NT.text2
        label.append(note)
        if QuestionDraft.isLongNote(option.description) {
            var more = AttributedString(draft.isExpanded(q, i) ? " Less" : " More")
            more.font = NType.captionStrong.font
            more.foregroundColor = NT.accent
            more.link = URL(string: "litenotch-note://\(q).\(i)")
            label.append(more)
        }
        return label
    }

    /// An answer of the user's own, added to a multiple-choice question.
    private func extraRow(_ q: Int, _ i: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.square.fill").glyph(12, .regular).foregroundStyle(NT.accent)
            VText(ApprovalPresentation.visible(text)).nfont(.bodyMedium).foregroundStyle(NT.text1)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            IconButton(symbol: "xmark.circle.fill", label: "Remove \(text)", size: 11, frame: 22) {
                draft.removeExtra(at: i, in: q)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(NT.fillHi, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    private func optionRow(_ q: Int, _ i: Int, _ question: AgentQuestion, _ option: QuestionOption) -> some View {
        let on = draft.picked[q].contains(option.label)
        let symbol =
            question.multiSelect
            ? (on ? "checkmark.square.fill" : "square")
            : (on ? "largecircle.fill.circle" : "circle")
        let clickMoves = draft.movesOnClick(q)
        let choose = {
            draft.toggle(option.label, in: q)
            if clickMoves { advance() }
        }
        return
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).glyph(12, .regular)
                    .foregroundStyle(on ? NT.accent : NT.text2)
                // Label and its note share a line (and wrap together): a
                // list of choices has to fit the panel without scrolling.
                Text(optionText(q, i, option))
                    .lineLimit(QuestionDraft.isLongNote(option.description) || draft.isExpanded(q, i) ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(
                        \.openURL,
                        OpenURLAction { _ in
                            draft.toggleNote(q, i)
                            return .handled
                        })
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                on ? NT.fillHi : Color.clear,
                in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous)
            )
            .contentShape(Rectangle())
            .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
            .onTapGesture(perform: choose)
            .disabled(clickMoves && !live)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: option.label))
            .accessibilityHint(Text(verbatim: option.description))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: Text(verbatim: "Choose"), choose)
            .accessibilityAction(.default, choose)
    }

    /// Under choices: one line, "Something else…". With no choices at all
    /// (an open question) it is the answer itself: taller, grows to four lines.
    @ViewBuilder
    private func otherField(_ q: Int, roomy: Bool, multi: Bool) -> some View {
        let binding = Binding(get: { draft.typed[q] }, set: { draft.type($0, in: q) })
        let prompt = roomy ? "Type your answer\u{2026}" : (multi ? "Add your own\u{2026}" : "Something else\u{2026}")
        HStack(alignment: roomy ? .top : .center, spacing: 6) {
            Image(systemName: "pencil").glyph(11, .regular).foregroundStyle(NT.text3)
                .padding(.top, roomy ? 4 : 0)
            if snapshot {
                Text(verbatim: draft.typed[q].isEmpty ? prompt : draft.typed[q])
                    .nfont(.body).foregroundStyle(NT.text3)
                Spacer(minLength: 0)
            } else {
                TextField(
                    "", text: binding,
                    prompt: Text(verbatim: prompt).foregroundColor(NT.text3),
                    axis: .vertical
                )
                .lineLimit(roomy ? 3...4 : 1...1)
                .textFieldStyle(.plain).font(NType.body.font).foregroundStyle(NT.text1)
                .focused($focus, equals: q)
                .onChange(of: focus) { _, f in keyboard(f != nil) }
                .onSubmit { returnPressed(q) }
                .accessibilityLabel(Text(verbatim: roomy ? "Your answer" : "Another answer"))
            }
        }
        .overlay(alignment: .trailing) {
            if multi, draft.canAdd(q), !draft.typed[q].trimmingCharacters(in: .whitespaces).isEmpty {
                IconButton(symbol: "plus.circle.fill", label: "Add this answer", size: 12, frame: 24) {
                    draft.commit(q)
                    focus = q
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, roomy ? 6 : 0)
        .frame(minHeight: roomy ? 58 : 26, alignment: roomy ? .top : .center)
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    private func button(
        _ title: String, fg: Color, bg: Color, enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(verbatim: title).nfont(.emphasis).foregroundStyle(fg)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(bg, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain).disabled(!enabled)
        .accessibilityLabel(Text(verbatim: title))
    }
}
