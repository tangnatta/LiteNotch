import SwiftUI

extension SettingsSection {
    var title: String {
        switch self {
        case .general: return "General"
        case .notch: return "Notch"
        case .timer: return "Timer"
        case .music: return "Music"
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .clipboard: return "Clipboard"
        case .agents: return "Agents"
        case .keepAwake: return "Keep awake"
        case .privacy: return "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notch: return "rectangle.topthird.inset.filled"
        case .timer: return "timer"
        case .music: return "music.note"
        case .notifications: return "bell"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        case .agents: return "terminal"
        case .keepAwake: return "cup.and.heat.waves"
        case .privacy: return "hand.raised"
        }
    }
}

/// Categories on the left, one category's options on the right.
struct SettingsTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    @Environment(\.clockOffsetMs) private var offset
    @State private var draft: Settings
    @State private var pending: DispatchWorkItem?
    /// The hue strip was asked for (it also shows for a custom accent).
    @State private var customAccent = false

    init(vm: ViewModel, model: PanelState) {
        self.vm = vm
        self.model = model
        _draft = State(initialValue: vm.settings)
    }

    private var send: (ShellCommand) -> Void { model.send }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            sidebar
                .frame(width: 132)
            Rectangle().fill(NT.hairline).frame(width: 1).accessibilityHidden(true)
            NotchScroll {
                VStack(alignment: .leading, spacing: 9) { pane }
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(model.settingsSection)
        }
        .onChange(of: draft) { _, new in schedule(new) }
        .onChange(of: vm.settings) { _, incoming in
            if pending == nil && incoming != draft { draft = incoming }
        }
    }

    private func schedule(_ s: Settings) {
        // Cancel first: a draft that is back at the current value must not
        // leave an older edit waiting to be sent.
        pending?.cancel()
        pending = nil
        guard s != vm.settings else { return }
        let work = DispatchWorkItem { pending = nil; send(.setSettings(s)) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 2) {
            ForEach(SettingsSection.allCases, id: \.self) { s in
                let on = s == model.settingsSection
                Button { model.settingsSection = s } label: {
                    HStack(spacing: 7) {
                        Image(systemName: s.symbol).glyph(11)
                            .frame(width: 16)
                        Text(verbatim: s.title).nfont(on ? .emphasis : .body).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? NT.text1 : NT.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(on ? NT.fillHi : Color.clear, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
                    .contentShape(Rectangle())
                    .rowHover(inset: 0)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Panes

    @ViewBuilder private var pane: some View {
        switch model.settingsSection {
        case .general: general
        case .notch: NotchPriorityPane(config: $draft.notch, floating: draft.appearance.notchStyle == .floating)
        case .timer: timer
        case .music: music
        case .notifications: notifications
        case .calendar: calendar
        case .clipboard: clipboard
        case .agents: agents
        case .keepAwake: keepAwake
        case .privacy: privacy
        }
    }

    @ViewBuilder private var general: some View {
        toggle("Open on hover", $draft.general.hoverToExpand,
               caption: "Clicking the notch always opens it.")
        toggle("Show on every display", $draft.general.allScreens,
               caption: "When off, it shows on the built-in or main display only.")
        Hairline().padding(.vertical, 2)
        row("Theme") {
            SegmentedPill(options: [(ThemeChoice.system, "System"), (ThemeChoice.dark, "Dark"), (ThemeChoice.light, "Light")],
                          selection: Binding(get: { draft.appearance.theme == .unknown ? .system : draft.appearance.theme },
                                             set: { draft.appearance.theme = $0 }),
                          label: "Theme", height: 22)
        }
        row("Notch") {
            SegmentedPill(options: [(NotchStyle.attached, "Attached"), (NotchStyle.floating, "Floating")],
                          selection: Binding(get: { draft.appearance.notchStyle == .floating ? .floating : .attached },
                                             set: { draft.appearance.notchStyle = $0 }),
                          label: "Notch style", height: 22)
        }
        // A display with a camera housing always draws the closed notch black,
        // so the choice is offered only on one without.
        if !model.hasNotch {
            row("Closed notch") {
                SegmentedPill(options: [(ClosedNotchChoice.dark, "Always dark"), (ClosedNotchChoice.theme, "Match theme")],
                              selection: Binding(get: { draft.appearance.closedNotch == .unknown ? .dark : draft.appearance.closedNotch },
                                                 set: { draft.appearance.closedNotch = $0 }),
                              label: "Closed notch", height: 22)
            }
        }
        materialRow
        row("Accent") {
            HStack(spacing: 5) {
                namedSwatch(.system, help: "Use the accent colour chosen in macOS", label: "System accent") {
                    Circle().fill(NT.color(NT.systemAccent() ?? AppearanceConfig.defaultAccent))
                        .overlay(Image(systemName: "apple.logo").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white).offset(y: -0.5))
                }
                namedSwatch(.mono, help: "Black or white, whichever the theme calls for", label: "Black and white") {
                    Circle().fill(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .white, location: 0.5)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(NT.hairline, lineWidth: 1))
                }
                ForEach(AccentPresets.all, id: \.self) { hex in swatch(hex) }
                customSwatch
            }
        }
        if customAccent || accentChoice.isCustom {
            row("Custom", caption: "Drag, or pick from the screen.") {
                HStack(spacing: 6) {
                    HueStrip(hue: accentHue) { draft.appearance.accent = ColorMath.hex(ColorMath.fromHue($0)) }
                    IconButton(symbol: "eyedropper", label: "Pick from the screen", size: 11, frame: 22,
                               help: "Pick the accent from anywhere on the screen") { model.app?.pickAccent() }
                }
            }
        }
        Hairline().padding(.vertical, 2)
        row("Quit LiteNotch") {
            TextPill(title: "Quit", tint: NT.text1, height: 22) { model.app?.onQuit() }
                .help("Quit LiteNotch")
        }
    }

    /// Solid or Liquid Glass for the open panel. Shown everywhere so the
    /// choice is discoverable, disabled (with the reason) where glass cannot
    /// be drawn; a saved Glass then draws as Solid.
    private var materialRow: some View {
        let reason = GlassSupport.unavailableReason
        return row("Panel", caption: reason.map { "Liquid Glass: \($0)" } ?? "") {
            SegmentedPill(options: [(MaterialChoice.solid, "Solid"), (MaterialChoice.glass, "Glass")],
                          selection: Binding(get: { draft.appearance.material == .glass && reason == nil ? .glass : .solid },
                                             set: { draft.appearance.material = $0 }),
                          label: "Panel material", height: 22)
                .disabled(reason != nil)
                .opacity(reason == nil ? 1 : 0.5)
                .help(reason ?? "Liquid Glass lets the desktop show through the open panel")
        }
    }

    private var accentChoice: AccentChoice { AccentChoice(draft.appearance.accent) }

    /// Where the knob sits: only a custom colour has a place on the strip.
    private var accentHue: Double? {
        guard accentChoice.isCustom, case .color(let hex) = accentChoice, let c = ColorMath.parse(hex) else { return nil }
        return ColorMath.hue(of: c)
    }

    private func namedSwatch<Fill: View>(_ choice: AccentChoice, help: String, label: String,
                                         @ViewBuilder fill: () -> Fill) -> some View {
        let on = accentChoice == choice
        return Button { draft.appearance.accent = choice.raw } label: {
            fill()
                .frame(width: 15, height: 15)
                .padding(2.5)
                .overlay(Circle().strokeBorder(on ? NT.text1 : Color.clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Opens the hue strip; selected while the accent is a custom colour.
    private var customSwatch: some View {
        let on = accentChoice.isCustom
        return Button { customAccent.toggle() } label: {
            Circle().fill(AngularGradient(colors: HueStrip.colors, center: .center))
                .frame(width: 15, height: 15)
                .padding(2.5)
                .overlay(Circle().strokeBorder(on ? NT.text1 : Color.clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Choose any colour")
        .accessibilityLabel(Text(verbatim: "Custom accent"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func swatch(_ hex: String) -> some View {
        let on = accentChoice == .color(hex)
        return Button { draft.appearance.accent = hex } label: {
            Circle().fill(NT.color(hex))
                .frame(width: 15, height: 15)
                .padding(2.5)
                .overlay(Circle().strokeBorder(on ? NT.text1 : Color.clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Use \(hex) as the accent")
        .accessibilityLabel(Text(verbatim: "Accent \(hex)"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var timer: some View {
        stepper("Focus", minutes($draft.pomodoro.focusSecs), 1...240, unit: "min")
        stepper("Short break", minutes($draft.pomodoro.shortBreakSecs), 1...240, unit: "min")
        stepper("Long break", minutes($draft.pomodoro.longBreakSecs), 1...240, unit: "min")
        stepper("Rounds before a long break", $draft.pomodoro.roundsBeforeLong, 1...12)
        toggle("Auto-start breaks", $draft.pomodoro.autoStartBreaks)
        toggle("Auto-start focus", $draft.pomodoro.autoStartFocus)
    }

    @ViewBuilder private var music: some View {
        toggle("Show now playing", $draft.media.enabled,
               caption: "Shows and controls what\u{2019}s playing in any app.")
    }

    @ViewBuilder private var notifications: some View {
        toggle("Show notifications", $draft.notify.enabled)
        toggle("Notifications from other apps", $draft.notify.system, caption: systemCaption)
        if draft.notify.system && model.accessibilityNeeded {
            warningRow("Allow LiteNotch to read other apps\u{2019} notifications in System Settings") {
                TextPill(title: "Open Settings", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    model.app?.onOpenAccessibilitySettings()
                }
                .help("Opens Privacy & Security \u{203A} Accessibility")
            }
            row("Already allowed it?", tint: NT.text2) {
                TextPill(title: "Reset and ask again", tint: NT.text1, height: 22) { model.app?.onResetAccessibility() }
                    .help("macOS forgets the permission when LiteNotch is updated")
            }
        }
        stepper("Banner stays for", $draft.notify.bannerSecs, 2...30, unit: "s")
        toggle("Hold during focus", $draft.notify.dndDuringFocus,
               caption: "Less urgent notifications wait until a focus session ends.")
    }

    private var systemCaption: String {
        if !draft.notify.system { return "Copies other apps\u{2019} banners into the inbox. Needs Accessibility." }
        // While permission is missing the row below says what to do.
        return model.accessibilityNeeded
            ? "Waiting for permission."
            : "Other apps\u{2019} banners land in the inbox."
    }

    @ViewBuilder private var calendar: some View {
        toggle("Show calendar events", $draft.calendar.enabled, caption: calendarCaption)
        if draft.calendar.enabled && model.calendarAccess == .denied {
            warningRow("Allow LiteNotch to see your calendars in System Settings") {
                TextPill(title: "Open Settings", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    model.app?.onOpenCalendarSettings()
                }
                .help("Opens Privacy & Security \u{203A} Calendars. Choose Full Access.")
            }
        }
        row("Remind before it starts", caption: draft.calendar.alertMinutes == 0 ? "No reminder." : "0 turns the reminder off.") {
            HStack(spacing: 6) {
                MiniStepper(value: $draft.calendar.alertMinutes, range: 0...60, label: "Remind before it starts")
                Text(verbatim: "min").nfont(.caption).foregroundStyle(NT.text3)
                    .frame(minWidth: 24, alignment: .leading)
            }
        }
        toggle("Tell me when it starts", $draft.calendar.alertAtStart)
    }

    private var calendarCaption: String {
        if !draft.calendar.enabled {
            return "Your next event on Home and a reminder before it starts. Asks to see your calendars."
        }
        switch model.calendarAccess {
        case .granted: return "Events from the calendars in the Calendar app. All-day events are left out."
        case .denied: return "Waiting for permission."
        case .unknown: return "Asking for permission\u{2026}"
        }
    }

    @ViewBuilder private var clipboard: some View {
        toggle("Clipboard history", $draft.clipboard.enabled)
        toggle("Keep after restart", $draft.general.persistClipboard,
               caption: "When off, history is forgotten when LiteNotch quits.")
        stepper("History size", $draft.clipboard.maxItems, 10...200, step: 10, unit: "items")
        toggle("Skip passwords", $draft.clipboard.ignoreConcealed,
               caption: "Ignores what password managers copy.")
    }

    @ViewBuilder private var agents: some View {
        toggle("Show Claude Code activity", $draft.agent.enabled,
               caption: "Sessions and approval requests appear in the notch.")
        toggle("Usage alerts", $draft.general.usageAlerts,
               caption: "A notification when a usage limit is close.")
        stepper("Approval wait", $draft.agent.approvalTimeoutSecs, 15...120, step: 15, unit: "s")
        let installed = vm.agents.hooksInstalled ?? false
        row("Claude Code", caption: installed ? "Connected" : "Not connected") {
            if installed {
                TextPill(title: "Disconnect", tint: NT.text2, height: 22) { send(.hooksUninstall) }
                    .help("Stop sending Claude Code sessions to LiteNotch")
            } else {
                TextPill(title: "Connect", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    send(.hooksInstall)
                }
                .help("Adds LiteNotch to Claude Code\u{2019}s settings. New sessions show up here.")
            }
        }
        let limits = vm.agents.statuslineInstalled ?? false
        row("Usage limits", caption: limits ? "Shown in Agents \u{203A} Usage" : "Not shown") {
            if limits {
                TextPill(title: "Stop showing usage limits", tint: NT.text2, height: 22) { send(.statuslineUninstall) }
                    .help("Gives Claude Code its previous status line back")
            } else {
                TextPill(title: "Show usage limits", tint: NT.text1, height: 22) { send(.statuslineInstall) }
                    .help("Makes LiteNotch Claude Code\u{2019}s status line, keeping the one you have")
            }
        }
    }

    @ViewBuilder private var keepAwake: some View {
        let c = vm.caffeine
        row("What stays awake") {
            SegmentedPill(options: [(AwakeMode.display, "Mac and screen"), (AwakeMode.system, "Mac only")],
                          selection: Binding(get: { draft.caffeine.defaultMode == .system ? .system : .display },
                                             set: { draft.caffeine.defaultMode = $0 }),
                          label: "Default keep-awake mode", height: 22)
        }
        row("With the lid closed", caption: c.lid == .pending ? "" : lidCaption(c)) {
            NotchToggle(isOn: Binding(get: { c.lid != .off && c.lid != .unknown },
                                      set: { send(.caffeineLid(on: $0)) }),
                        label: "Keep awake with lid closed")
        }
        if c.lid == .pending {
            WarningText(text: lidCaption(c)).nfont(.caption)
        }
        if let g = c.guardText, !g.isEmpty {
            VText(g).nfont(.caption).foregroundStyle(NT.text2).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        stepper("Stop when battery is below", $draft.caffeine.batteryFloorPct, 5...50, step: 5, unit: "%")
        row("Keep awake for", caption: awakeCaption(c)) {
            HStack(spacing: 4) {
                chip("30m", 1800); chip("1h", 3600); chip("2h", 7200); chip("\u{221E}", nil)
            }
        }
    }

    /// While on: for how long. The chips start a new stretch, so none of
    /// them is shown as selected; this line says what is running.
    private func awakeCaption(_ c: CaffeineView) -> String {
        guard c.mode != .off && c.mode != .unknown else { return "" }
        return KeepAwakeText.help(on: true, untilMs: c.untilMs, nowMs: nowMs(Date(), offset: offset))
            .replacingOccurrences(of: " Click to stop.", with: "")
    }

    private func lidCaption(_ c: CaffeineView) -> String {
        switch c.lid {
        case .pending: return "Waiting for your password\u{2026}"
        case .on: return "The Mac stays awake with the lid closed."
        default: return "Asks for an admin password once."
        }
    }

    private var activateMode: AwakeMode {
        let current = vm.caffeine.mode
        if current != .off && current != .unknown { return current }
        let d = draft.caffeine.defaultMode
        return d == .off || d == .unknown ? .display : d
    }

    private func chip(_ title: String, _ secs: Int?) -> some View {
        let c = vm.caffeine
        // Only "until turned off" can be told apart from the view model.
        let selected = secs == nil && c.mode != .off && c.mode != .unknown && c.untilMs == nil
        return Button { send(.caffeineActivate(mode: activateMode, durationSecs: secs)) } label: {
            Text(verbatim: title).nfont(.captionStrong).foregroundStyle(NT.text1)
                .lineLimit(1).fixedSize()
                .frame(minWidth: 22).padding(.horizontal, 6).frame(height: 22)
                .background(NT.fillHi, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? NT.text1 : Color.clear, lineWidth: 1.5))
                .contentShape(Capsule())
                .controlHover(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(secs == nil ? "Keep the Mac awake until you turn it off" : "Keep the Mac awake for \(title)")
        .accessibilityLabel(Text(verbatim: secs == nil ? "Keep awake indefinitely" : "Keep awake for \(title)"))
    }

    @ViewBuilder private var privacy: some View {
        toggle("Usage statistics (stays on this Mac)", $draft.analytics.enabled,
               caption: "Daily counts only. Nothing leaves this Mac.")
        VStack(spacing: 3) {
            ForEach(Array(vm.analytics.prefix(5).enumerated()), id: \.offset) { _, f in
                HStack {
                    Text(verbatim: Format.featureName(f.feature)).nfont(.caption).foregroundStyle(NT.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(f.count)").nfont(.caption).monospacedDigit().foregroundStyle(NT.text1)
                }
            }
            if vm.analytics.isEmpty {
                Text(verbatim: "Nothing counted yet").nfont(.caption).foregroundStyle(NT.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        row("Stored counts") {
            TextPill(title: "Clear counts", tint: NT.text2, height: 22) { send(.analyticsClear) }
        }
    }

    // MARK: Rows

    private func minutes(_ b: Binding<Int>) -> Binding<Int> {
        Binding(get: { b.wrappedValue / 60 }, set: { b.wrappedValue = $0 * 60 })
    }

    private func row<C: View>(_ title: String, caption: String = "", tint: Color = NT.text1,
                              captionTint: Color = NT.text3,
                              @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).nfont(.body).foregroundStyle(tint).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !caption.isEmpty {
                    Text(verbatim: caption).nfont(.caption).foregroundStyle(captionTint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            control()
        }
        .frame(minHeight: 22)
    }

    /// A row whose text is a warning (amber, with an icon).
    private func warningRow<C: View>(_ text: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            WarningText(text: text).nfont(.body)
            Spacer(minLength: 4)
            control()
        }
        .frame(minHeight: 22)
    }

    private func toggle(_ title: String, _ b: Binding<Bool>, caption: String = "") -> some View {
        row(title, caption: caption) { NotchToggle(isOn: b, label: title) }
    }

    private func stepper(_ title: String, _ b: Binding<Int>, _ r: ClosedRange<Int>, step: Int = 1,
                         unit: String = "") -> some View {
        row(title) {
            HStack(spacing: 6) {
                MiniStepper(value: b, range: r, step: step, label: title)
                if !unit.isEmpty {
                    Text(verbatim: unit).nfont(.caption).foregroundStyle(NT.text3)
                        .frame(minWidth: 24, alignment: .leading)
                }
            }
        }
    }
}

/// A strip of every hue: click or drag along it to choose one. The knob
/// shows the current colour's place, when it has one.
struct HueStrip: View {
    var hue: Double?
    var width: CGFloat = 150
    let pick: (Double) -> Void

    /// The strip's colours, left to right (and around the custom swatch).
    static let colors: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        let c = ColorMath.fromHue($0)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// The hue under a point `x` along a strip `width` wide.
    static func hue(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        // Just short of 1, which is the same red as 0.
        return min(max(Double(x / width), 0), 0.999)
    }

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 14)
            .overlay(alignment: .leading) {
                if let hue {
                    Circle().fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                        .frame(width: 12, height: 12)
                        .offset(x: 1 + CGFloat(hue) * (width - 14))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { pick(Self.hue(at: $0.location.x, width: width)) })
            .help("Click or drag to choose a colour")
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: "Accent hue"))
            .accessibilityValue(Text(verbatim: hue.map { "\(Int(($0 * 360).rounded())) degrees" } ?? "not set"))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 1.0 / 24 : -1.0 / 24
                let next = (hue ?? 0) + step
                pick(next - floor(next))
            }
    }
}
