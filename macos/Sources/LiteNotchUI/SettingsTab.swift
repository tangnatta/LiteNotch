import SwiftUI

extension SettingsSection {
    var title: String {
        switch self {
        case .general: return "General"
        case .notch: return "Notch"
        case .day: return "Work day"
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
        case .day: return "sun.horizon"
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
    /// General's "More options" are shown. Snapshots open them so every
    /// control is drawn and measured.
    @State private var moreLook: Bool

    init(vm: ViewModel, model: PanelState) {
        self.vm = vm
        self.model = model
        _draft = State(initialValue: vm.settings)
        _moreLook = State(initialValue: SettingsTab.showMoreOptions)
    }

    /// Starts General with "More options" open (snapshots and their tests).
    @MainActor static var showMoreOptions = false

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
        let work = DispatchWorkItem {
            pending = nil
            send(.setSettings(s))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Sidebar

    /// Scrolls: with more sections than fit, a fixed column made the whole
    /// tab taller than the panel and cut off the bottom of the pane beside it.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            NotchScroll {
                VStack(spacing: 2) {
                    ForEach(SettingsSection.allCases, id: \.self) { s in
                        let on = s == model.settingsSection
                        Button {
                            model.settingsSection = s
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: s.symbol).glyph(11)
                                    .frame(width: 16)
                                Text(verbatim: s.title).nfont(on ? .emphasis : .body).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(on ? NT.text1 : NT.text2)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                on ? NT.fillHi : Color.clear, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous)
                            )
                            .contentShape(Rectangle())
                            .rowHover(inset: 0)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .id(s)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            // A section opened from elsewhere (a notification, Home) may be
            // one of those below the fold.
            .onAppear { proxy.scrollTo(model.settingsSection) }
            .onChange(of: model.settingsSection) { _, section in proxy.scrollTo(section) }
        }
    }

    // MARK: Panes

    @ViewBuilder private var pane: some View {
        switch model.settingsSection {
        case .general: general
        case .notch:
            NotchPriorityPane(
                config: $draft.notch, island: draft.appearance.notchStyle == .island,
                hasNotch: model.hasNotch
            )
            .environment(\.dayIcons, draft.day.icons)
            .environment(\.dayMotion, draft.day.motion)
        case .day: day
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
        // First: with no Dock icon, this is the only way out.
        row("Quit LiteNotch", caption: "It has no Dock icon; quit it here.") {
            TextPill(title: "Quit", tint: NT.text1, height: 22) { model.app?.onQuit() }
                .help("Quit LiteNotch")
        }
        Hairline().padding(.vertical, 2)
        updateBlock
        Hairline().padding(.vertical, 2)
        if let app = model.app { LaunchAtLoginRow(app: app) }
        toggle(
            "Open on hover", $draft.general.hoverToExpand,
            caption: "Clicking the notch always opens it.")
        toggle(
            "Show on every display", $draft.general.allScreens,
            caption: "When off, it shows on the built-in or main display only.")
        Hairline().padding(.vertical, 2)
        row("Theme") {
            SegmentedPill(
                options: [(ThemeChoice.system, "System"), (ThemeChoice.dark, "Dark"), (ThemeChoice.light, "Light")],
                selection: Binding(
                    get: { draft.appearance.theme == .unknown ? .system : draft.appearance.theme },
                    set: { draft.appearance.theme = $0 }),
                label: "Theme", height: 22)
        }
        accentRow
        Hairline().padding(.vertical, 2)
        moreButton
        if moreLook { moreLookRows }
    }

    /// Choices whose effect a newcomer cannot guess from their names stay
    /// folded away until asked for; every default is the original look.
    private var moreButton: some View {
        Button {
            moreLook.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: moreLook ? "chevron.down" : "chevron.right").glyph(9, .semibold)
                Text(verbatim: "More options").nfont(.bodyMedium)
                Text(verbatim: "notch style, shrink, glass").nfont(.caption).foregroundStyle(NT.text3)
                Spacer(minLength: 0)
            }
            .foregroundStyle(NT.text2)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "More options"))
        .accessibilityValue(Text(verbatim: moreLook ? "Shown" : "Hidden"))
    }

    @ViewBuilder private var moreLookRows: some View {
        row("Notch", caption: "Attached hangs from the top edge. Island floats inside the menu bar.") {
            SegmentedPill(
                options: [(NotchStyle.attached, "Attached"), (NotchStyle.island, "Island")],
                selection: Binding(
                    get: { draft.appearance.notchStyle == .island ? .island : .attached },
                    set: { draft.appearance.notchStyle = $0 }),
                label: "Notch style", height: 22)
        }
        // A display with a camera housing always draws the closed notch black,
        // so the choice is offered only on one without.
        if !model.hasNotch {
            row("Closed notch") {
                SegmentedPill(
                    options: [(ClosedNotchChoice.dark, "Always dark"), (ClosedNotchChoice.theme, "Match theme")],
                    selection: Binding(
                        get: { draft.appearance.closedNotch == .unknown ? .dark : draft.appearance.closedNotch },
                        set: { draft.appearance.closedNotch = $0 }),
                    label: "Closed notch", height: 22)
            }
            wideRow("Shrink", caption: "A thin strip at the top edge instead of the closed notch.") {
                SegmentedPill(
                    options: [
                        (ShrinkChoice.off, "Default"), (ShrinkChoice.whenEmpty, "When empty"),
                        (ShrinkChoice.always, "Always"),
                    ],
                    selection: Binding(
                        get: { draft.appearance.shrink == .unknown ? .off : draft.appearance.shrink },
                        set: { draft.appearance.shrink = $0 }),
                    label: "Shrink", height: 22)
            }
        } else {
            // Beside a camera housing the only useful choice is to keep
            // the sides clear: an empty notch already is just the notch.
            row("Shrink", caption: "Nothing beside the notch while closed. Peeks and notifications still show.") {
                SegmentedPill(
                    options: [(ShrinkChoice.off, "Default"), (ShrinkChoice.always, "Always")],
                    selection: Binding(
                        get: { draft.appearance.shrink == .always ? .always : .off },
                        set: { draft.appearance.shrink = $0 }),
                    label: "Shrink", height: 22)
            }
        }
        materialRow
    }

    @ViewBuilder private var accentRow: some View {
        row("Accent") {
            HStack(spacing: 5) {
                namedSwatch(.system, help: "Use the accent colour chosen in macOS", label: "System accent") {
                    Circle().fill(NT.color(NT.systemAccent() ?? AppearanceConfig.defaultAccent))
                        .overlay(
                            Image(systemName: "apple.logo").font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white).offset(y: -0.5))
                }
                namedSwatch(.mono, help: "Black or white, whichever the theme calls for", label: "Black and white") {
                    Circle().fill(
                        LinearGradient(
                            stops: [.init(color: .black, location: 0.5), .init(color: .white, location: 0.5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
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
                    IconButton(
                        symbol: "eyedropper", label: "Pick from the screen", size: 11, frame: 22,
                        help: "Pick the accent from anywhere on the screen"
                    ) { model.app?.pickAccent() }
                }
            }
        }
    }

    /// This version, the button that asks whether there is a newer one, and
    /// what to do when there is. Only the button (or the opt-in daily check)
    /// contacts GitHub.
    @ViewBuilder private var updateBlock: some View {
        let u = vm.update
        row("LiteNotch \(u.current)", caption: UpdateText.caption(u)) {
            TextPill(
                title: u.status == .checking ? "Checking\u{2026}" : "Check for updates",
                tint: NT.text1, height: 22
            ) { send(.updateCheck) }
            .disabled(u.status == .checking)
            .help("Asks GitHub for the newest release")
        }
        if u.status == .available, let latest = u.latest {
            row("Version \(latest) is available") {
                HStack(spacing: 6) {
                    TextPill(title: "Copy update command", tint: .black, background: NT.allow, height: 22) {
                        model.app?.copyText(UpdateText.command(u))
                    }
                    .help(UpdateText.command(u))
                    if let page = UpdateText.releasePage(u.url) {
                        TextPill(title: "Release page", tint: NT.text1, height: 22) { model.app?.openURL(page) }
                    }
                }
            }
            VText("Paste the command in Terminal if you installed with Homebrew. Otherwise download the new version from the release page.")
                .nfont(.caption).foregroundStyle(NT.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        toggle(
            "Check automatically", $draft.general.checkUpdates,
            caption: "At start and once a day. This contacts GitHub; with it off nothing is sent until you press the button."
        )
        .padding(.top, 6)
    }

    /// Solid or Liquid Glass for the open panel. Shown everywhere so the
    /// choice is discoverable, disabled (with the reason) where glass cannot
    /// be drawn; a saved Glass then draws as Solid. Without a notch the
    /// caption says the closed notch follows when it matches the theme.
    private var materialRow: some View {
        let reason = GlassSupport.unavailableReason
        let caption =
            reason.map { "Liquid Glass: \($0)" }
            ?? (model.hasNotch ? "" : "Glass also covers the closed notch when it matches the theme.")
        return row("Panel", caption: caption) {
            SegmentedPill(
                options: [(MaterialChoice.solid, "Solid"), (MaterialChoice.glass, "Glass")],
                selection: Binding(
                    get: { draft.appearance.material == .glass && reason == nil ? .glass : .solid },
                    set: { draft.appearance.material = $0 }),
                label: "Panel material", height: 22
            )
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

    private func namedSwatch<Fill: View>(
        _ choice: AccentChoice, help: String, label: String,
        @ViewBuilder fill: () -> Fill
    ) -> some View {
        let on = accentChoice == choice
        return Button {
            draft.appearance.accent = choice.raw
        } label: {
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
        return Button {
            customAccent.toggle()
        } label: {
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
        return Button {
            draft.appearance.accent = hex
        } label: {
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
        stepper("Focus", minutes($draft.pomodoro.focusSecs), SettingsLimits.pomodoroMinutes, unit: "min")
        stepper("Short break", minutes($draft.pomodoro.shortBreakSecs), SettingsLimits.pomodoroMinutes, unit: "min")
        stepper("Long break", minutes($draft.pomodoro.longBreakSecs), SettingsLimits.pomodoroMinutes, unit: "min")
        stepper("Rounds before a long break", $draft.pomodoro.roundsBeforeLong, SettingsLimits.rounds)
        toggle("Auto-start breaks", $draft.pomodoro.autoStartBreaks)
        toggle("Auto-start focus", $draft.pomodoro.autoStartFocus)
        Hairline().padding(.vertical, 2)
        wideRow("Heads-up before it ends", caption: "Focus sessions and the timer show the time left for a moment.") {
            SegmentedPill(
                options: SettingsLimits.timeWarningSecs.map { ($0, $0 == 0 ? "Off" : $0 == 600 ? "10 min" : "\($0 / 60)") },
                selection: $draft.peek.timeWarningSecs, label: "Heads-up before it ends", height: 22)
        }
        toggle(
            "Sound when time is up", $draft.sound.enabled,
            caption: "When a timer, a focus session or a break ends.")
        if draft.sound.enabled {
            row("Sound") {
                SoundPicker(name: $draft.sound.name) { send(.soundPreview(name: $0)) }
            }
        }
        Hairline().padding(.vertical, 2)
        wideRow("Eye break", caption: "A quick blink and look away, every so many minutes at the Mac.") {
            SegmentedPill(
                options: SettingsLimits.eyeBreakMins.map { ($0, $0 == 0 ? "Off" : $0 == 20 ? "20 min" : "\($0)") },
                selection: $draft.peek.eyeBreakMins, label: "Eye break", height: 22)
        }
        wideRow("Move", caption: "Stretch, walk or drink water, every so many minutes at the Mac.") {
            SegmentedPill(
                options: SettingsLimits.moveMins.map { ($0, $0 == 0 ? "Off" : $0 == 60 ? "60 min" : "\($0)") },
                selection: $draft.peek.moveMins, label: "Move", height: 22)
        }
        toggle(
            "A few words after a break", $draft.peek.breakQuote,
            caption: "The closed notch shows a short line of encouragement when a break ends.")
        toggle(
            "Remind me if I keep working on a break", $draft.peek.stillWorking,
            caption: "Checks a few times during a break whether the keyboard or mouse is in use.")
    }

    @ViewBuilder private var day: some View {
        toggle(
            "Day progress", $draft.day.enabled,
            caption: "Shows how much of your working day has passed, in the closed notch and on Home.")
        if draft.day.enabled {
            row("Starts") {
                TimeStepper(
                    minutes: Binding(
                        get: { draft.day.startMin },
                        set: { start in
                            draft.day.startMin = start
                            // The core keeps the end at least a span after it.
                            draft.day.endMin = max(draft.day.endMin, start + SettingsLimits.dayMinSpan)
                        }),
                    range: SettingsLimits.dayStart, label: "Starts")
            }
            row("Ends") {
                TimeStepper(
                    minutes: $draft.day.endMin,
                    range: (draft.day.startMin + SettingsLimits.dayMinSpan)...SettingsLimits.dayEnd.upperBound,
                    label: "Ends")
            }
            row("Days") { WeekdayPicker(days: $draft.day.days) }
            wideRow(
                "Icon",
                caption: draft.day.icons == .tree
                    ? "A plant that grows through the day, green in the closed notch."
                    : "Sun and moon by the time of day."
            ) {
                SegmentedPill(
                    options: [(DayIcons.sun, "Default"), (.tree, "Grow a tree")],
                    selection: $draft.day.icons, label: "Icon", height: 22
                ) { icon in
                    switch icon {
                    case .sun: Image(systemName: "sun.max.fill").font(.system(size: 11, weight: .semibold))
                    case .tree: GrowthIcon(stage: .tree, size: 13, color: NT.grow)
                    }
                }
            }
            toggle(
                "Animate", $draft.day.motion,
                caption: "The sun turns slowly, the tree sways. Off, the icon is still and costs nothing.")
            // Home's big card shows the day or the music; the choice only
            // matters while day progress is on, so it lives here.
            row("Home's big card", caption: homeCardCaption) {
                SegmentedPill(
                    options: [(HomeCard.auto, "Auto"), (.day, "Day"), (.media, "Music")],
                    selection: $draft.day.homeCard, label: "Home's big card", height: 22)
            }
        }
    }

    private var homeCardCaption: String {
        switch draft.day.homeCard {
        case .auto: return "Music while something plays, the day otherwise."
        case .day: return "How far through the day, always."
        case .media: return "Now playing, always."
        }
    }

    @ViewBuilder private var music: some View {
        toggle(
            "Show now playing", $draft.media.enabled,
            caption: "Shows and controls what\u{2019}s playing in any app.")
        toggle(
            "Progress ring", $draft.media.progressRing,
            caption: "A ring around the artwork in the closed notch fills as the song plays.")
        toggle(
            "Show a new song for a moment", $draft.peek.trackChange,
            caption: "The closed notch shows the title when the song changes.")
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
        stepper("Banner stays for", $draft.notify.bannerSecs, SettingsLimits.bannerSecs, unit: "s")
        toggle(
            "Hold during focus", $draft.notify.dndDuringFocus,
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
                MiniStepper(value: $draft.calendar.alertMinutes, range: SettingsLimits.alertMinutes, label: "Remind before it starts")
                Text(verbatim: "min").nfont(.caption).foregroundStyle(NT.text3)
                    .frame(minWidth: 24, alignment: .leading)
            }
        }
        toggle("Tell me when it starts", $draft.calendar.alertAtStart)
    }

    private var calendarCaption: String {
        if !draft.calendar.enabled {
            return "A Calendar tab, your next event on Home and a reminder before it starts. Asks to see your calendars."
        }
        switch model.calendarAccess {
        case .granted:
            return "Events from the calendars in the Calendar app; add or change them in the Calendar tab. All-day events are left out."
        case .denied: return "Waiting for permission."
        case .unknown: return "Asking for permission\u{2026}"
        }
    }

    @ViewBuilder private var clipboard: some View {
        toggle("Clipboard history", $draft.clipboard.enabled)
        toggle(
            "Keep after restart", $draft.general.persistClipboard,
            caption: "When off, history is forgotten when LiteNotch quits.")
        stepper("History size", $draft.clipboard.maxItems, SettingsLimits.clipboardItems, step: 10, unit: "items")
        toggle(
            "Skip passwords", $draft.clipboard.ignoreConcealed,
            caption: "Ignores what password managers copy.")
    }

    /// Every agent first, each with its own Connect, then how they behave.
    @ViewBuilder private var agents: some View {
        SectionLabel(text: "Agents")
        let installed = vm.agents.hooksInstalled ?? false
        row("Claude Code", caption: installed ? "Connected \u{00B7} sessions, approvals, questions" : "Not connected") {
            connectPill(
                connected: installed, name: "Claude Code",
                connect: { send(.hooksInstall) }, disconnect: { send(.hooksUninstall) })
        }
        if let warning = AgentsText.otherCopies(
            found: vm.agents.otherCopies ?? 0,
            missing: vm.agents.otherCopiesMissing ?? 0)
        {
            warningRow(warning) {
                TextPill(title: "Remove them", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold) {
                    send(.hooksClean)
                }
                .help("Removes the other copies\u{2019} hooks from Claude Code\u{2019}s settings. This copy stays connected.")
            }
        }
        ForEach(vm.agents.connectors ?? []) { c in
            row(c.name, caption: AgentsText.connectorCaption(c), tint: c.present ? NT.text1 : NT.text2) {
                connectPill(
                    connected: c.installed ?? false, name: c.name,
                    connect: { send(.connectorInstall(agent: c.agent)) },
                    disconnect: { send(.connectorUninstall(agent: c.agent)) })
            }
        }
        if let note = AgentsText.activityOnlyNote(vm.agents.connectors ?? []) {
            VText(note).nfont(.caption).foregroundStyle(NT.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        Hairline().padding(.vertical, 2)
        toggle(
            "Show agent activity", $draft.agent.enabled,
            caption: "Sessions and requests from connected agents appear in the notch.")
        stepper(
            "Wait for my answer", $draft.agent.approvalTimeoutSecs, SettingsLimits.approvalSecs, step: 15, unit: "s",
            caption: "Then the agent asks in its terminal instead.")
        let limits = vm.agents.statuslineInstalled ?? false
        row(
            "Claude Code usage limits",
            caption: limits
                ? "Shown in Agents \u{203A} Usage. Codex\u{2019}s show on their own."
                : "Adds LiteNotch to Claude Code\u{2019}s status line; yours is kept."
        ) {
            if limits {
                TextPill(title: "Stop showing", tint: NT.text2, height: 22) { send(.statuslineUninstall) }
                    .help("Gives Claude Code its previous status line back")
            } else {
                TextPill(title: "Show", tint: NT.text1, height: 22) { send(.statuslineInstall) }
                    .help("Makes LiteNotch Claude Code\u{2019}s status line, keeping the one you have")
            }
        }
        toggle(
            "Usage alerts", $draft.general.usageAlerts,
            caption: "A notification when a Claude Code usage limit is close.")
    }

    private func connectPill(
        connected: Bool, name: String, connect: @escaping () -> Void, disconnect: @escaping () -> Void
    ) -> some View {
        Group {
            if connected {
                TextPill(title: "Disconnect", tint: NT.text2, height: 22, action: disconnect)
                    .help("Stop sending \(name) sessions to LiteNotch")
            } else {
                TextPill(title: "Connect", tint: NT.onAccent, background: NT.accent, height: 22, weight: .semibold, action: connect)
                    .help("Adds LiteNotch to \(name)\u{2019}s settings. New sessions show up in Agents.")
            }
        }
    }

    @ViewBuilder private var keepAwake: some View {
        let c = vm.caffeine
        row("What stays awake") {
            SegmentedPill(
                options: [(AwakeMode.display, "Mac and screen"), (AwakeMode.system, "Mac only")],
                selection: Binding(
                    get: { draft.caffeine.defaultMode == .system ? .system : .display },
                    set: { draft.caffeine.defaultMode = $0 }),
                label: "Default keep-awake mode", height: 22)
        }
        row("With the lid closed", caption: c.lid == .pending ? "" : lidCaption(c)) {
            NotchToggle(isOn: $draft.caffeine.lidClosed, label: "Keep awake with lid closed")
        }
        if c.lid == .pending {
            WarningText(text: lidCaption(c)).nfont(.caption)
        }
        if let g = c.guardText, !g.isEmpty {
            VText(g).nfont(.caption).foregroundStyle(NT.text2).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        stepper("Stop keeping awake below", $draft.caffeine.batteryFloorPct, SettingsLimits.batteryFloor, step: 5, unit: "%")
        VText("One limit for every mode, with the lid open or closed. 0 % means no limit: the Mac stays awake until the battery runs out.")
            .nfont(.caption).foregroundStyle(NT.text2)
            .fixedSize(horizontal: false, vertical: true)
        row("Keep awake now for", caption: awakeCaption(c)) {
            HStack(spacing: 4) {
                chip("30m", 1800)
                chip("1h", 3600)
                chip("2h", 7200)
                chip("\u{221E}", nil)
            }
        }
    }

    /// While on: for how long. The chips start a new stretch, so none of
    /// them is shown as selected; this line says what is running.
    private func awakeCaption(_ c: CaffeineView) -> String {
        guard c.mode != .off && c.mode != .unknown else {
            return "Off. Pick one to start now, or click the cup in the tab bar."
        }
        return KeepAwakeText.help(on: true, untilMs: c.untilMs, nowMs: nowMs(Date(), offset: offset))
            .replacingOccurrences(of: " Click to stop.", with: "")
    }

    /// The lid choice is saved, so the caption says what it does at each moment.
    private func lidCaption(_ c: CaffeineView) -> String {
        switch c.lid {
        case .pending: return "Waiting for your password\u{2026}"
        case .on: return "The Mac stays awake with the lid closed."
        default:
            return draft.caffeine.lidClosed
                ? "Every time keep awake is on. Asks for an admin password once."
                : "The Mac sleeps when the lid closes."
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
        return Button {
            send(.caffeineActivate(mode: activateMode, durationSecs: secs))
        } label: {
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
        toggle(
            "Usage statistics (stays on this Mac)", $draft.analytics.enabled,
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

    private func row<C: View>(
        _ title: String, caption: String = "", tint: Color = NT.text1,
        captionTint: Color = NT.text3,
        @ViewBuilder _ control: () -> C
    ) -> some View {
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

    /// A row whose control is too wide to share a line with its caption:
    /// title and caption on top, the control below, so neither is cut off.
    private func wideRow<C: View>(
        _ title: String, caption: String = "",
        @ViewBuilder _ control: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).nfont(.body).foregroundStyle(NT.text1)
                if !caption.isEmpty {
                    Text(verbatim: caption).nfont(.caption).foregroundStyle(NT.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func stepper(
        _ title: String, _ b: Binding<Int>, _ r: ClosedRange<Int>, step: Int = 1,
        unit: String = "", caption: String = ""
    ) -> some View {
        row(title, caption: caption) {
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

/// Steps through the system alert sounds, playing each as it is chosen.
struct SoundPicker: View {
    @Binding var name: String
    let preview: (String) -> Void

    /// The name `step` places from `name` in the list, wrapping round; the
    /// default when `name` is not a known sound.
    static func next(after name: String, step: Int) -> String {
        let all = SoundConfig.sounds
        guard let i = all.firstIndex(of: name) else { return SoundConfig.defaultName }
        return all[((i + step) % all.count + all.count) % all.count]
    }

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", "Previous sound", step: -1)
            Button {
                preview(name)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill").glyph(9)
                    Text(verbatim: name).nfont(.bodyMedium).lineLimit(1)
                }
                .foregroundStyle(NT.text1)
                .frame(minWidth: 92, minHeight: 22)
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Play \(name)")
            .accessibilityLabel(Text(verbatim: "Sound: \(name). Click to play."))
            arrow("chevron.right", "Next sound", step: 1)
        }
        .background(NT.fill, in: RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
    }

    private func arrow(_ symbol: String, _ label: String, step: Int) -> some View {
        Button {
            name = Self.next(after: name, step: step)
            preview(name)
        } label: {
            Image(systemName: symbol).glyph(9, .bold)
                .foregroundStyle(NT.text2)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .controlHover(RoundedRectangle(cornerRadius: NT.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// Text for the Agents settings; pure so it can be unit tested.
public enum AgentsText {
    /// The line under a connector's name.
    public static func connectorCaption(_ c: ConnectorView) -> String {
        if c.installed ?? false { return "Connected" }
        return c.present ? "Not connected" : "Not found on this Mac"
    }

    /// Says which connected-or-connectable agents cannot show Allow / Deny,
    /// so nobody looks for buttons that are not there; nil when all can.
    public static func activityOnlyNote(_ connectors: [ConnectorView]) -> String? {
        let names = connectors.filter { !$0.approvals }.map(\.name)
        guard !names.isEmpty else { return nil }
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        let (verb, their) = names.count == 1 ? ("has", "its") : ("have", "their")
        let need = names.count == 1 ? "it needs" : "they need"
        return "\(list) \(verb) no approval hook, so the notch shows \(their) activity "
            + "and when \(need) you, not Allow and Deny."
    }

    /// Whether any agent, Claude Code or another, is connected.
    public static func anyConnected(_ agents: AgentsView) -> Bool {
        (agents.hooksInstalled ?? false) || (agents.connectors ?? []).contains { $0.installed ?? false }
    }

    /// The warning when other copies of LiteNotch are registered with Claude
    /// Code; nil when there are none.
    public static func otherCopies(found: Int, missing: Int) -> String? {
        guard found > 0 else { return nil }
        let missing = min(max(missing, 0), found)
        let what = found == 1 ? "1 other copy of LiteNotch also runs" : "\(found) other copies of LiteNotch also run"
        let gone: String
        switch (missing, found) {
        case (0, _): gone = ""
        case (1, 1): gone = " It no longer exists."
        case (let m, let f) where m == f: gone = " None of them exist any more."
        case (let m, _): gone = " \(m) of them no longer exist."
        }
        return "\(what) on every Claude Code event.\(gone)"
    }
}

/// A time of day in half-hour steps: `−  10:00  +`.
struct TimeStepper: View {
    @Binding var minutes: Int
    var range: ClosedRange<Int>
    var step = 30
    var label = ""

    var body: some View {
        HStack(spacing: 2) {
            button("minus", -step, "Earlier")
            Text(verbatim: Format.minutesOfDay(minutes))
                .nfont(.body).monospacedDigit().foregroundStyle(NT.text1)
                .frame(minWidth: 40)
            button("plus", step, "Later")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }

    private func button(_ symbol: String, _ delta: Int, _ name: String) -> some View {
        Button {
            minutes = min(max(minutes + delta, range.lowerBound), range.upperBound)
        } label: {
            Image(systemName: symbol).glyph(NGlyph.small).foregroundStyle(NT.text2)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(name) \(label)"))
    }
}

/// Seven letters, Monday first; a click turns a working day on or off.
struct WeekdayPicker: View {
    @Binding var days: Int
    private static let letters = ["M", "T", "W", "T", "F", "S", "S"]
    private static let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { i in
                let on = days & (1 << i) != 0
                Button {
                    days ^= 1 << i
                } label: {
                    Text(verbatim: Self.letters[i]).nfont(.caption)
                        .foregroundStyle(on ? NT.onAccent : NT.text2)
                        .frame(width: 20, height: 20)
                        .background(on ? NT.accent : NT.hairline, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Self.names[i]))
                .accessibilityValue(Text(verbatim: on ? "Working day" : "Day off"))
            }
        }
    }
}

/// "Launch at login". Its own view because it follows `AppModel` (the system's
/// answer), not the settings draft, and re-reads that answer when it appears:
/// the user may have changed it in System Settings meanwhile.
struct LaunchAtLoginRow: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let status = app.launchAtLogin
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: LoginItemStatus.title).nfont(.body).foregroundStyle(NT.text1)
                Text(verbatim: status.caption).nfont(.caption)
                    .foregroundStyle(status == .off || status == .on ? NT.text3 : NT.text2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if status == .needsApproval {
                TextPill(title: "Open", tint: NT.text1, height: 22) { app.loginItem.openSystemSettings() }
                    .help("Opens Login Items in System Settings")
            }
            NotchToggle(
                isOn: Binding(
                    get: { status.isOn || status == .needsApproval },
                    set: { app.setLaunchAtLogin($0) }),
                label: LoginItemStatus.title)
        }
        .frame(minHeight: 22)
        .onAppear { app.refreshLaunchAtLogin() }
    }
}
