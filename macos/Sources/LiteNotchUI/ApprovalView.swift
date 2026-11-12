import SwiftUI

struct ApprovalHeader: View {
    let index: Int
    let total: Int
    let notch: CGSize
    let ear: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(NT.accent).frame(width: 8, height: 8)
                Text(verbatim: "Approval needed").nfont(12, .semibold).foregroundStyle(NT.text1)
            }
            Spacer(minLength: notch.width + 24)
            if total > 1 {
                Text(verbatim: "\(index) of \(total)")
                    .nfont(11.5, .medium).monospacedDigit().foregroundStyle(NT.text2)
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
            HStack(spacing: 8) {
                VText(request.project).nfont(12, .medium).foregroundStyle(NT.text2).lineLimit(1)
                VText(request.toolName)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(NT.text1)
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(NT.fillHi, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .lineLimit(1)
                Spacer(minLength: 8)
                EverySecond { now in
                    let left = Format.secondsLeft(until: request.expiresMs, nowMs: now)
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
                        Text(verbatim: Format.countdown(seconds: left)).monospacedDigit()
                    }
                    .nfont(11.5, .medium)
                    .foregroundStyle(left <= 15 ? NT.accent : NT.text2)
                    .accessibilityLabel(Text(verbatim: "Expires in \(left) seconds"))
                }
            }

            NotchScroll {
                VText(p.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(NT.text1)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: .infinity)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if p.showTruncatedNotice {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(verbatim: ApprovalPresentation.truncatedNotice).nfont(11.5, .medium)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(NT.accentText)
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
                .nfont(12.5, .semibold)
                .foregroundStyle(foreground(d))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background(d), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        // Deliberately no `.keyboardShortcut` on any decision.
        .accessibilityLabel(Text(verbatim: title(d)))
    }

    private func title(_ d: Decision) -> String {
        switch d {
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .pass: return "Answer in terminal"
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
