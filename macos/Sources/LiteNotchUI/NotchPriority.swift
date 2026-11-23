import SwiftUI

// Settings › Notch: which running activity the closed notch shows first,
// which it shows beside it, and which it leaves to Home. The preview at the
// top draws the real closed-notch view for a chosen situation, so what the
// user sets is what they will see.

/// The rule the core applies (`Core::compact`), repeated here only so the
/// settings preview can show its result without a round trip.
public enum NotchPriority {
    /// The activities running in a made-up situation, for the preview.
    public struct Situation: Equatable, Identifiable {
        public var id: String
        public var title: String
        public var running: [ActivityKind]
        public var waiting: Bool
    }

    public static let situations: [Situation] = [
        Situation(id: "meeting", title: "Meeting soon", running: [.pomodoro, .calendar], waiting: false),
        Situation(id: "music", title: "Focus + music", running: [.pomodoro, .media], waiting: false),
        Situation(id: "agent", title: "Agent waiting", running: [.pomodoro], waiting: true),
        Situation(id: "busy", title: "Everything", running: NotchConfig.liveOrder, waiting: true),
    ]

    /// What the closed notch shows of `running` under `config`: the first
    /// in the order, and the second if two places are on.
    public static func resolve(_ running: [ActivityKind], config: NotchConfig) -> (first: ActivityKind?, second: ActivityKind?) {
        let order = normalizedOrder(config.order)
        let shown = order.filter { running.contains($0) && !config.hidden.contains($0) }
        return (shown.first, config.twoPlaces && shown.count > 1 ? shown[1] : nil)
    }

    /// Every live activity once: the given order first, anything it lacks
    /// after it at its default place. Mirrors `NotchConfig::normalized`.
    public static func normalizedOrder(_ order: [ActivityKind]) -> [ActivityKind] {
        var out: [ActivityKind] = []
        for kind in order + NotchConfig.liveOrder where NotchConfig.liveOrder.contains(kind) && !out.contains(kind) {
            out.append(kind)
        }
        return out
    }

    /// `order` with `kind` moved one place up (`by: -1`) or down (`by: 1`).
    public static func move(_ kind: ActivityKind, by step: Int, in order: [ActivityKind]) -> [ActivityKind] {
        var out = normalizedOrder(order)
        guard let i = out.firstIndex(of: kind) else { return out }
        let j = i + step
        guard out.indices.contains(j) else { return out }
        out.swapAt(i, j)
        return out
    }

    public static func name(_ kind: ActivityKind) -> String {
        switch kind {
        case .meeting: return "Meeting agenda"
        case .calendar: return "Event about to start"
        case .timer: return "Countdown timer"
        case .pomodoro: return "Focus session"
        case .media: return "Music"
        case .caffeine: return "Keep awake"
        case .agent: return "Agent working"
        case .day: return "Day progress"
        default: return kind.rawValue
        }
    }

    public static func symbol(_ kind: ActivityKind) -> String {
        switch kind {
        case .meeting: return "person.2.fill"
        case .calendar: return "calendar"
        case .timer: return "hourglass"
        case .pomodoro: return "timer"
        case .media: return "music.note"
        case .caffeine: return "cup.and.heat.waves.fill"
        case .agent: return "terminal.fill"
        case .day: return "sun.max.fill"
        default: return "circle"
        }
    }

    /// A still stand-in for a running activity, for the preview.
    static func sample(_ kind: ActivityKind) -> CompactView {
        func view(_ title: String, _ value: String) -> CompactView {
            CompactView(kind: kind, title: title, value: value, endsAtMs: nil, totalSecs: nil, count: 1)
        }
        switch kind {
        case .meeting: return view("Stand-up", "3:12")
        case .calendar: return view("Design review", "4:59")
        case .timer: return view("Timer", "12:40")
        case .pomodoro: return view("Focus", "9:59")
        case .media: return view("Weightless", "Marconi Union")
        case .caffeine: return view("Awake", "")
        case .agent: return view("api", "working")
        case .day: return view("Day", "37%")
        default: return view("", "")
        }
    }

    /// What the preview draws for a situation.
    public static func content(for situation: Situation, config: NotchConfig) -> ClosedContent {
        let (first, second) = resolve(situation.running, config: config)
        return ClosedContent(
            primary: first.map(sample), secondary: second.map(sample),
            waiting: situation.waiting && config.waitingDot)
    }

    /// One line saying what the preview shows and what it leaves out.
    public static func explanation(for situation: Situation, config: NotchConfig) -> String {
        let (first, second) = resolve(situation.running, config: config)
        let rest = situation.running.filter { $0 != first && $0 != second }.map(name)
        var parts: [String] = []
        switch (first, second) {
        case (nil, _): parts.append("Nothing in the notch.")
        case (let a?, nil): parts.append("\(name(a)) only.")
        case (let a?, let b?): parts.append("\(name(a)) first, \(name(b).lowercased()) beside it.")
        }
        if !rest.isEmpty { parts.append("On Home only: \(rest.map { $0.lowercased() }.joined(separator: ", ")).") }
        if situation.waiting { parts.append(config.waitingDot ? "The dot: an agent is waiting." : "No sign of the waiting agent.") }
        return parts.joined(separator: " ")
    }
}

/// The settings pane.
struct NotchPriorityPane: View {
    @Binding var config: NotchConfig
    let island: Bool
    /// Whether this display has a camera housing.
    var hasNotch = true
    @State private var situation = NotchPriority.situations[0]

    private var order: [ActivityKind] { NotchPriority.normalizedOrder(config.order) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            NotchPreview(
                content: NotchPriority.content(for: situation, config: config), island: island,
                hasNotch: hasNotch)
            SegmentedPill(
                options: NotchPriority.situations.map { (value: $0.id, title: $0.title) },
                selection: Binding(
                    get: { situation.id },
                    set: { id in situation = NotchPriority.situations.first { $0.id == id } ?? situation }),
                label: "Situation to preview", height: 22
            )
            .frame(maxWidth: .infinity)
            Text(verbatim: NotchPriority.explanation(for: situation, config: config))
                .nfont(.caption).foregroundStyle(NT.text2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            Hairline().padding(.vertical, 2)
            option("Show two at once", "The second activity sits beside the first.", $config.twoPlaces)
            option("Dot when an agent is waiting", "A small dot until you answer it or open the inbox.", $config.waitingDot)
            Hairline().padding(.vertical, 2)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Order").nfont(.body).foregroundStyle(NT.text1)
                    Text(verbatim: "The highest one running gets the notch. Switch one off to keep it on Home only.")
                        .nfont(.caption).foregroundStyle(NT.text3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                TextPill(title: "Reset", tint: NT.text2, height: 22) { config = .default }
                    .help("Back to the order LiteNotch comes with")
                    .disabled(config == .default)
                    .opacity(config == .default ? 0.5 : 1)
            }
            VStack(spacing: 2) {
                ForEach(Array(order.enumerated()), id: \.element) { index, kind in
                    row(kind, index: index)
                }
            }
        }
    }

    private func option(_ title: String, _ caption: String, _ value: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).nfont(.body).foregroundStyle(NT.text1)
                Text(verbatim: caption).nfont(.caption).foregroundStyle(NT.text3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            NotchToggle(isOn: value, label: title)
        }
        .frame(minHeight: 22)
    }

    private func row(_ kind: ActivityKind, index: Int) -> some View {
        let shown = !config.hidden.contains(kind)
        let name = NotchPriority.name(kind)
        return HStack(spacing: 6) {
            Text(verbatim: "\(index + 1)").nfont(.caption).monospacedDigit().foregroundStyle(NT.text3)
                .frame(width: 12, alignment: .trailing)
            Image(systemName: NotchPriority.symbol(kind)).glyph(11)
                .foregroundStyle(shown ? NT.text1 : NT.text3).frame(width: 18)
            Text(verbatim: name).nfont(.body).foregroundStyle(shown ? NT.text1 : NT.text3).lineLimit(1)
            Spacer(minLength: 4)
            arrow("chevron.up", "Move \(name) up", enabled: index > 0) {
                config.order = NotchPriority.move(kind, by: -1, in: config.order)
            }
            arrow("chevron.down", "Move \(name) down", enabled: index < order.count - 1) {
                config.order = NotchPriority.move(kind, by: 1, in: config.order)
            }
            NotchToggle(
                isOn: Binding(
                    get: { shown },
                    set: { on in
                        config.hidden.removeAll { $0 == kind }
                        if !on { config.hidden.append(kind) }
                    }),
                label: "Show \(name) in the notch")
        }
        .padding(.leading, 2)
        .frame(height: 26)
    }

    private func arrow(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).glyph(9, .bold)
                .foregroundStyle(NT.text2)
                .frame(width: 22, height: 22)
                .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// A strip of menu bar with the closed notch in it, drawn by the same view
/// and sized by the same layout the real notch uses, for this kind of
/// display (with or without a camera housing) and the chosen style.
struct NotchPreview: View {
    let content: ClosedContent
    let island: Bool
    var hasNotch = true

    /// The stand-in screen: a 32 pt menu bar; a notch a little narrower
    /// than a MacBook's so two activities fit in the pane.
    static let bar: CGFloat = 32
    static let notchWidth: CGFloat = 150

    /// The layout the preview is drawn with.
    static func layout(island: Bool, hasNotch: Bool) -> NotchLayout {
        NotchLayout(
            style: island ? .island : .attached,
            notch: CGSize(width: hasNotch ? notchWidth : NotchGeometry.fallbackSize.width, height: bar),
            hasNotch: hasNotch, menuBarHeight: bar)
    }

    /// Width of the black shape: exactly what the layout gives the content.
    static func shapeWidth(_ layout: NotchLayout, content: ClosedContent) -> CGFloat {
        let width = layout.size(for: .closed, content: content).width
        return layout.island ? width : width - 2 * NotchGeometry.closedEar
    }

    var body: some View {
        let layout = Self.layout(island: island, hasNotch: hasNotch)
        let width = Self.shapeWidth(layout, content: content)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous).fill(NT.fillHi)
            Group {
                if island {
                    ClosedActivityView(
                        content: content, notchWidth: layout.centerWidth, ear: 0,
                        wing: layout.wingWidth(for: content),
                        edgePadding: NotchGeometry.islandWingPadding,
                        artworkSize: min(20, layout.capsuleHeight - 4),
                        artworkInset: (layout.capsuleHeight - min(20, layout.capsuleHeight - 4)) / 2,
                        oneRow: layout.oneRow
                    )
                    .frame(width: width, height: layout.capsuleHeight)
                    .background(Color.black, in: Capsule())
                    .padding(.top, NotchGeometry.islandMargin)
                } else {
                    ClosedActivityView(
                        content: content, notchWidth: layout.notch.width, ear: 0,
                        wing: layout.wingWidth(for: content), oneRow: layout.oneRow
                    )
                    .frame(width: width, height: Self.bar)
                    .background(
                        Color.black,
                        in: UnevenRoundedRectangle(
                            bottomLeadingRadius: NotchGeometry.closedBottomRadius,
                            bottomTrailingRadius: NotchGeometry.closedBottomRadius, style: .continuous))
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.bar + 10)
        .clipShape(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Preview: \(ClosedActivityView.spoken(content))"))
    }
}
