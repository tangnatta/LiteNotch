import SwiftUI

/// The strip beside the notch while approvals wait: what it is on the
/// left, and with more than one, `1 of 2` and arrows to look through them.
struct ApprovalHeader: View {
    let index: Int
    let total: Int
    let notch: CGSize
    let ear: CGFloat
    var step: (Int) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(NT.accent).frame(width: 8, height: 8)
                Text(verbatim: "Approval needed").nfont(.emphasis).foregroundStyle(NT.text1)
            }
            Spacer(minLength: notch.width + 24)
            if total > 1 {
                HStack(spacing: 0) {
                    IconButton(symbol: "chevron.left", label: "Previous request", size: NGlyph.small,
                               tint: index > 1 ? NT.text1 : NT.text3) { step(-1) }
                        .disabled(index <= 1)
                    Text(verbatim: "\(index) of \(total)")
                        .nfont(.bodyMedium).monospacedDigit().foregroundStyle(NT.text2)
                        .accessibilityLabel(Text(verbatim: "Request \(index) of \(total)"))
                    IconButton(symbol: "chevron.right", label: "Next request", size: NGlyph.small,
                               tint: index < total ? NT.text1 : NT.text3) { step(1) }
                        .disabled(index >= total)
                }
            }
        }
        .padding(.horizontal, ear + 16)
    }
}

/// Permission prompt. Security rules, all enforced here and in
/// `ApprovalPresentation`:
///  - every string is rendered with `Text(verbatim:)`;
///  - a truncated command never gets an Allow button;
///  - nothing is bound to a keyboard shortcut (no way to Allow from the keys);
///  - Allow stays inert for a short moment after the prompt appears so a click
///    already in flight cannot approve something the user has not read.
struct ApprovalView: View {
    let request: PermissionRequest
    let send: (ShellCommand) -> Void

    @Environment(\.isSnapshot) private var snapshot
    @State private var armed = false
    static let armDelay: TimeInterval = 0.6

    var body: some View {
        let p = ApprovalPresentation(request)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VText(ApprovalPresentation.headline(request))
                    .nfont(.title).foregroundStyle(NT.text1)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                EverySecond { now in
                    let left = Format.secondsLeft(until: request.expiresMs, nowMs: now)
                    Text(verbatim: "Expires in \(Format.countdown(seconds: left))")
                        .nfont(.bodyMedium).monospacedDigit()
                        .foregroundStyle(left <= 15 ? NT.warning : NT.text2)
                        .fixedSize()
                        .help("Unanswered requests go back to the terminal")
                        .accessibilityLabel(Text(verbatim: "Expires in \(left) seconds"))
                }
            }

            NotchScroll {
                VText(p.detail)
                    .font(.system(size: NType.body.size, design: .monospaced))
                    .foregroundStyle(NT.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: NT.radiusContainer, style: .continuous))

            if p.showTruncatedNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").glyph(11, .regular)
                    Text(verbatim: ApprovalPresentation.truncatedNotice).nfont(.bodyMedium)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(NT.warning)
            }

            HStack(spacing: 8) {
                ForEach(p.offeredDecisions, id: \.self) { d in
                    decisionButton(d)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: request.id) {
            armed = false
            try? await Task.sleep(nanoseconds: UInt64(Self.armDelay * 1_000_000_000))
            armed = true
        }
    }

    @ViewBuilder
    private func decisionButton(_ d: Decision) -> some View {
        let isAllow = d == .allow
        let enabled = !isAllow || armed || snapshot
        Button {
            send(.agentDecide(requestId: request.id, decision: d))
        } label: {
            Text(verbatim: title(d))
                .nfont(.emphasis)
                .foregroundStyle(foreground(d))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background(d), in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help(d))
        // Deliberately no `.keyboardShortcut` on any decision.
        .accessibilityLabel(Text(verbatim: title(d)))
    }

    private func title(_ d: Decision) -> String {
        switch d {
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .pass: return "Answer in Terminal"
        }
    }
    private func help(_ d: Decision) -> String {
        switch d {
        case .allow: return "Let Claude Code run this once"
        case .deny: return "Don\u{2019}t run it; Claude Code is told no"
        case .pass: return "Show Claude Code\u{2019}s own prompt in the terminal instead"
        }
    }
    private func foreground(_ d: Decision) -> Color {
        switch d {
        case .allow: return .black
        case .deny: return NT.deny
        case .pass: return NT.text1
        }
    }
    private func background(_ d: Decision) -> Color {
        switch d {
        case .allow: return NT.allow
        case .deny: return NT.deny.opacity(0.16)
        case .pass: return NT.fillHi
        }
    }
}
