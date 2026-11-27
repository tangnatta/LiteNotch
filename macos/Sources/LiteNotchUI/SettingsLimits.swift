import Foundation

/// The ranges Settings offers, in one place. Each must lie within what the
/// core keeps (`core::schema`, written to `Fixtures/schema.json`):
/// `ParityTests` fails when a control offers a value the core would change.
enum SettingsLimits {
    static let pomodoroMinutes = 1...240
    static let rounds = 1...12
    static let bannerSecs = 2...30
    static let clipboardItems = 10...200
    static let approvalSecs = 15...120
    static let alertMinutes = 0...60
    static let batteryFloor = 0...50
    /// Choices of the segmented controls, 0 meaning off.
    static let timeWarningSecs = [0, 60, 180, 300, 600]
    static let eyeBreakMins = [0, 5, 10, 15, 20]
    /// Screen time from full to empty when a gauge is on (Settings offers
    /// only on and off). Water: about 2 L over a working day, 250 ml an
    /// hour, the tank holding two 200 ml cups. Stretch: once an hour.
    static let waterMins = 90
    static let stretchMins = 60
    /// Office hours: the end is at least `dayMinSpan` after the start.
    static let dayMinSpan = 30
    static let dayStart = 0...(24 * 60 - dayMinSpan)
    static let dayEnd = dayMinSpan...(24 * 60)
}
