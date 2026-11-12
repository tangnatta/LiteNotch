import SwiftUI

extension SettingsSection {
    var title: String {
        switch self {
        case .general: return "General"
        case .timer: return "Timer"
        case .music: return "Music"
        case .notifications: return "Notifications"
        case .clipboard: return "Clipboard"
        case .agents: return "Agents"
        case .keepAwake: return "Keep awake"
        case .privacy: return "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .timer: return "timer"
        case .music: return "music.note"
        case .notifications: return "bell"
        case .clipboard: return "doc.on.clipboard"
        case .agents: return "sparkles"
        case .keepAwake: return "cup.and.saucer"
        case .privacy: return "hand.raised"
        }
    }
}

/// Categories on the left, one category's options on the right.
struct SettingsTab: View {
    let vm: ViewModel
    @ObservedObject var model: PanelState

    @State private var draft: Settings
    @State private var pending: DispatchWorkItem?

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
            NotchScroll {
                VStack(alignment: .leading, spacing: 7) { pane }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(NT.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                        Image(systemName: s.symbol).font(.system(size: 10.5, weight: .semibold))
                            .frame(width: 16)
                        Text(verbatim: s.title).nfont(11.5, on ? .semibold : .regular).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(on ? NT.text1 : NT.text2)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(on ? NT.fillHi : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
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
        case .timer: timer
        case .music: music
        case .notifications: notifications
        case .clipboard: clipboard
        case .agents: agents
        case .keepAwake: keepAwake
        case .privacy: privacy
        }
    }

    @ViewBuilder private var general: some View {
        toggle("Hover to expand", $draft.general.hoverToExpand,
               caption: "Clicking the notch opens and closes it either way.")
        toggle("Show on every display", $draft.general.allScreens,
               caption: "Off: only the built-in display, or the main one.")
        SectionLabel(text: "Appearance").padding(.top, 6)
        row("Theme") {
            SegmentedPill(options: [(ThemeChoice.system, "System"), (ThemeChoice.dark, "Dark"), (ThemeChoice.light, "Light")],
                          selection: Binding(get: { draft.appearance.theme == .unknown ? .system : draft.appearance.theme },
                                             set: { draft.appearance.theme = $0 }),
                          label: "Theme", height: 22)
        }
        row("Accent") {
            HStack(spacing: 5) {
                ForEach(AccentPresets.all, id: \.self) { hex in swatch(hex) }
                TextPill(title: "Pick\u{2026}", height: 22) { model.app?.pickAccent() }
                    .help("Pick the accent from anywhere on the screen")
            }
        }
        SectionLabel(text: "App").padding(.top, 6)
        row("Quit LiteNotch") {
            TextPill(title: "Quit", tint: NT.text1, height: 22) { model.app?.onQuit() }
        }
    }

    private func swatch(_ hex: String) -> some View {
        let on = ColorMath.normalize(draft.appearance.accent) == hex
        return Button { draft.appearance.accent = hex } label: {
            Circle().fill(NT.color(hex))
                .frame(width: 15, height: 15)
                .padding(2.5)
                .overlay(Circle().strokeBorder(on ? NT.text1 : Color.clear, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(hex)
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
               caption: "Artwork and controls for whatever macOS reports as playing, from any app.")
    }

    @ViewBuilder private var notifications: some View {
        toggle("Show notifications", $draft.notify.enabled)
        toggle("Notifications from other apps", $draft.notify.system, caption: systemCaption)
        if draft.notify.system && model.accessibilityNeeded {
            row("Allow LiteNotch under Accessibility", tint: NT.accent) {
                TextPill(title: "Open Settings", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    model.app?.onOpenAccessibilitySettings()
                }
            }
            row("Already allowed? Each new build needs it again.", tint: NT.text2) {
                TextPill(title: "Reset and ask again", height: 22) { model.app?.onResetAccessibility() }
            }
        }
        stepper("Banner stays for", $draft.notify.bannerSecs, 2...30, unit: "s")
        toggle("Mute during focus", $draft.notify.dndDuringFocus)
    }

    private var systemCaption: String {
        if !draft.notify.system { return "Reads other apps' banners through Accessibility." }
        // While permission is missing the row below says what to do.
        return model.accessibilityNeeded
            ? "Waiting for permission."
            : "On. Banners from other apps land in the inbox."
    }

    @ViewBuilder private var clipboard: some View {
        toggle("Clipboard history", $draft.clipboard.enabled)
        toggle("Keep on restart", $draft.general.persistClipboard,
               caption: "Off: history lives in memory only.")
        stepper("History size", $draft.clipboard.maxItems, 10...200, step: 10, unit: "items")
        toggle("Skip password-manager entries", $draft.clipboard.ignoreConcealed)
    }

    @ViewBuilder private var agents: some View {
        toggle("Claude Code integration", $draft.agent.enabled)
        toggle("Usage alerts", $draft.general.usageAlerts)
        stepper("Approval timeout", $draft.agent.approvalTimeoutSecs, 15...120, step: 15, unit: "s")
        let installed = vm.agents.hooksInstalled ?? false
        row("Claude Code hooks", caption: installed ? "Installed" : "Not installed") {
            if installed {
                TextPill(title: "Remove", tint: NT.text2, height: 22) { send(.hooksUninstall) }
            } else {
                TextPill(title: "Install", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    send(.hooksInstall)
                }
            }
        }
    }

    @ViewBuilder private var keepAwake: some View {
        let c = vm.caffeine
        row("When on, keep awake") {
            SegmentedPill(options: [(AwakeMode.display, "Display on"), (AwakeMode.system, "System only")],
                          selection: Binding(get: { draft.caffeine.defaultMode == .system ? .system : .display },
                                             set: { draft.caffeine.defaultMode = $0 }),
                          label: "Default keep-awake mode", height: 22)
        }
        row("With the lid closed", caption: lidCaption(c), captionTint: c.lid == .pending ? NT.accent : NT.text3) {
            NotchToggle(isOn: Binding(get: { c.lid != .off && c.lid != .unknown },
                                      set: { send(.caffeineLid(on: $0)) }),
                        label: "Keep awake with lid closed")
        }
        if let g = c.guardText, !g.isEmpty {
            VText(g).nfont(10.5).foregroundStyle(NT.text2).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        stepper("Stop below battery", $draft.caffeine.batteryFloorPct, 5...50, step: 5, unit: "%")
        row("Keep awake for") {
            HStack(spacing: 4) {
                chip("30m", 1800); chip("1h", 3600); chip("2h", 7200); chip("\u{221E}", nil)
            }
        }
    }

    private func lidCaption(_ c: CaffeineView) -> String {
        switch c.lid {
        case .pending: return "waiting for password\u{2026}"
        case .on: return "On. Asks for an admin password once."
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
        Button { send(.caffeineActivate(mode: activateMode, durationSecs: secs)) } label: {
            Text(verbatim: title).nfont(11, .semibold).foregroundStyle(NT.text1)
                .lineLimit(1).fixedSize()
                .frame(minWidth: 22).padding(.horizontal, 6).frame(height: 22)
                .background(NT.fillHi, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: secs == nil ? "Keep awake indefinitely" : "Keep awake for \(title)"))
    }

    @ViewBuilder private var privacy: some View {
        toggle("Count feature usage on this Mac", $draft.analytics.enabled,
               caption: "Per-day counters only. Nothing is uploaded.")
        VStack(spacing: 3) {
            ForEach(Array(vm.analytics.prefix(5).enumerated()), id: \.offset) { _, f in
                HStack {
                    Text(verbatim: Format.featureName(f.feature)).nfont(11).foregroundStyle(NT.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "\(f.count)").nfont(11, .medium).monospacedDigit().foregroundStyle(NT.text1)
                }
            }
            if vm.analytics.isEmpty {
                Text(verbatim: "Nothing counted yet").nfont(11).foregroundStyle(NT.text3)
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
                Text(verbatim: title).nfont(11.5).foregroundStyle(tint).lineLimit(1)
                if !caption.isEmpty {
                    Text(verbatim: caption).nfont(10.5).foregroundStyle(captionTint)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
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
                if !unit.isEmpty {
                    Text(verbatim: unit).nfont(10.5).foregroundStyle(NT.text3)
                }
                MiniStepper(value: b, range: r, step: step, label: title)
            }
        }
    }
}
