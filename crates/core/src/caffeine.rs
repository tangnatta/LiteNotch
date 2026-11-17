//! Keep-awake state machine (system / display assertions plus closed-lid mode).
//!
//! Pure logic: the platform layer performs the returned [`CaffeineEffect`]s.

use serde::{Deserialize, Serialize};

/// Which sleep assertion is held.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AwakeMode {
    /// No assertion.
    #[default]
    Off,
    /// Prevent idle system sleep only.
    System,
    /// Prevent display sleep (implies system).
    Display,
}

/// Closed-lid mode progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LidState {
    /// Not requested.
    #[default]
    Off,
    /// Requested; waiting for the privileged step to report back.
    Pending,
    /// Active.
    On,
}

/// Latest power source reading.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PowerStatus {
    /// True when plugged in.
    pub on_ac: bool,
    /// Battery percentage; `None` on machines without a battery.
    pub battery_pct: Option<u8>,
}

impl Default for PowerStatus {
    /// Plugged in, no battery info: never trips a guard.
    fn default() -> Self {
        Self {
            on_ac: true,
            battery_pct: None,
        }
    }
}

/// Caffeine settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CaffeineConfig {
    /// What the cup starts when nothing else is chosen.
    pub default_mode: AwakeMode,
    /// On battery below this percentage keeping awake turns off, in every
    /// mode, with or without the lid closed; 0 = no limit.
    pub battery_floor_pct: u8,
    /// Keep awake with the lid closed: a saved choice, applied whenever
    /// keep awake is turned on, until the user changes it.
    pub lid_closed: bool,
}

impl Default for CaffeineConfig {
    fn default() -> Self {
        Self {
            default_mode: AwakeMode::Display,
            battery_floor_pct: 10,
            lid_closed: false,
        }
    }
}

/// Side effect for the platform layer to perform.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaffeineEffect {
    /// Hold this assertion (`Off` releases it).
    SetAssertion(AwakeMode),
    /// Start the privileged closed-lid step; answer with `lid_result`.
    EnableLid,
    /// Revert the closed-lid step.
    DisableLid,
    /// Show a notification.
    Notice {
        /// Short title.
        title: String,
        /// Details.
        body: String,
    },
}

/// View model for the UI.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CaffeineSnapshot {
    /// Current assertion.
    pub mode: AwakeMode,
    /// Lid state.
    pub lid: LidState,
    /// Whole seconds left (rounded up) when a timer is set.
    pub remaining_secs: Option<u32>,
    /// Absolute end time when a timer is set.
    pub until_ms: Option<u64>,
    /// Why a guard switched things off, until the next activation or recovery.
    pub guard: Option<String>,
}

/// Closed-lid mode turns itself off after this long in one stretch, so a
/// Mac left in a bag does not stay awake until its battery is flat. The
/// platform's root helper has its own, slightly longer cap as a backstop.
pub const LID_MAX_HOURS: u64 = 12;

/// The keep-awake state machine.
#[derive(Debug, Clone)]
pub struct Caffeine {
    cfg: CaffeineConfig,
    mode: AwakeMode,
    lid: LidState,
    /// When closed-lid mode last came on; meaningful only while it is on.
    lid_since_ms: u64,
    until_ms: Option<u64>,
    guard: Option<String>,
    power: PowerStatus,
}

fn notice(title: &str, body: String) -> CaffeineEffect {
    CaffeineEffect::Notice {
        title: title.to_string(),
        body,
    }
}

impl Caffeine {
    /// New idle instance; power is assumed to be AC until reported.
    pub fn new(cfg: CaffeineConfig) -> Self {
        Self {
            cfg: Self::clamp(cfg),
            mode: AwakeMode::Off,
            lid: LidState::Off,
            lid_since_ms: 0,
            until_ms: None,
            guard: None,
            power: PowerStatus::default(),
        }
    }

    fn clamp(mut cfg: CaffeineConfig) -> CaffeineConfig {
        cfg.battery_floor_pct = cfg.battery_floor_pct.min(100);
        cfg
    }

    /// Current settings.
    pub fn config(&self) -> &CaffeineConfig {
        &self.cfg
    }

    /// Replace settings (percentages clamped to 100); the battery limit is
    /// checked on the next `on_power`. A changed lid choice applies at once
    /// while keep awake is on, and otherwise waits for the next time it is.
    pub fn set_config(&mut self, cfg: CaffeineConfig) -> Vec<CaffeineEffect> {
        self.cfg = Self::clamp(cfg);
        self.apply_lid()
    }

    /// Makes the lid state match the saved choice, while keep awake is on.
    fn apply_lid(&mut self) -> Vec<CaffeineEffect> {
        if self.mode == AwakeMode::Off {
            return Vec::new();
        }
        match (self.cfg.lid_closed, self.lid) {
            (true, LidState::Off) => {
                self.lid = LidState::Pending;
                vec![CaffeineEffect::EnableLid]
            }
            (false, LidState::Pending | LidState::On) => {
                self.lid = LidState::Off;
                vec![CaffeineEffect::DisableLid]
            }
            _ => Vec::new(),
        }
    }

    /// Why the battery forbids keeping awake now; one limit for every mode.
    fn violation(&self) -> Option<String> {
        if self.power.on_ac {
            return None;
        }
        match self.power.battery_pct {
            Some(p) if p < self.cfg.battery_floor_pct => Some(format!("Battery at {p}%")),
            _ => None,
        }
    }

    /// Turn everything off, emitting only the effects that actually change state.
    fn shut_down(&mut self) -> Vec<CaffeineEffect> {
        let mut fx = Vec::new();
        if self.lid != LidState::Off {
            self.lid = LidState::Off;
            fx.push(CaffeineEffect::DisableLid);
        }
        if self.mode != AwakeMode::Off {
            self.mode = AwakeMode::Off;
            fx.push(CaffeineEffect::SetAssertion(AwakeMode::Off));
        }
        self.until_ms = None;
        fx
    }

    /// Hold `mode`, optionally for `duration_secs` (`None` or `Some(0)` means no timer).
    /// `AwakeMode::Off` is the same as `deactivate`. Refused (with a notice) when a battery guard trips.
    pub fn activate(
        &mut self,
        mode: AwakeMode,
        duration_secs: Option<u32>,
        now_ms: u64,
    ) -> Vec<CaffeineEffect> {
        if mode == AwakeMode::Off {
            return self.deactivate(now_ms);
        }
        if let Some(why) = self.violation() {
            return vec![notice("Caffeine not started", why)];
        }
        self.guard = None;
        self.until_ms = duration_secs
            .filter(|d| *d > 0)
            .map(|d| now_ms.saturating_add(u64::from(d) * 1000));
        if self.mode == mode {
            return Vec::new();
        }
        let was_off = self.mode == AwakeMode::Off;
        self.mode = mode;
        let mut fx = vec![CaffeineEffect::SetAssertion(mode)];
        // Turning keep awake on brings the saved lid choice with it.
        if was_off {
            fx.extend(self.apply_lid());
        }
        fx
    }

    /// Release the assertion and lid mode and clear any guard message.
    pub fn deactivate(&mut self, _now_ms: u64) -> Vec<CaffeineEffect> {
        self.guard = None;
        self.shut_down()
    }

    /// Platform reports whether the privileged lid step worked. A success that
    /// arrives after lid mode was cancelled (the password prompt can stay open
    /// for minutes) is answered with `DisableLid` so the platform reverts it.
    pub fn lid_result(&mut self, ok: bool, now_ms: u64) -> Vec<CaffeineEffect> {
        if self.lid == LidState::Off && ok {
            return vec![CaffeineEffect::DisableLid];
        }
        if self.lid != LidState::Pending {
            return Vec::new();
        }
        if ok {
            self.lid = LidState::On;
            self.lid_since_ms = now_ms;
            Vec::new()
        } else {
            self.lid = LidState::Off;
            vec![notice(
                "Lid mode failed",
                "The privileged step did not complete.".to_string(),
            )]
        }
    }

    /// The platform found that the Mac is no longer kept awake with the lid
    /// closed although the mode is on (its helper stopped). Says so instead
    /// of leaving the mode shown as on.
    pub fn lid_lost(&mut self) -> Vec<CaffeineEffect> {
        if self.lid != LidState::On {
            return Vec::new();
        }
        self.lid = LidState::Off;
        vec![
            CaffeineEffect::DisableLid,
            notice(
                "Lid mode stopped",
                "The Mac is no longer kept awake with the lid closed. It starts again the next time keep awake is turned on."
                    .to_string(),
            ),
        ]
    }

    /// The Mac slept while closed-lid mode was on and the lid shut, so macOS
    /// ignored the sleep-disabled flag. Ends the mode and says so, instead of
    /// leaving it shown as on.
    pub fn lid_slept(&mut self) -> Vec<CaffeineEffect> {
        if self.lid != LidState::On {
            return Vec::new();
        }
        self.lid = LidState::Off;
        vec![
            CaffeineEffect::DisableLid,
            notice(
                "Mac slept with the lid closed",
                "Closed-lid mode did not keep it awake, so sessions and timers paused. It starts again the next time keep awake is turned on."
                    .to_string(),
            ),
        ]
    }

    /// When closed-lid mode turns itself off, while it is on.
    fn lid_deadline(&self) -> Option<u64> {
        (self.lid == LidState::On)
            .then(|| self.lid_since_ms.saturating_add(LID_MAX_HOURS * 3_600_000))
    }

    /// Feed a power reading and apply the battery limit.
    pub fn on_power(&mut self, status: PowerStatus, _now_ms: u64) -> Vec<CaffeineEffect> {
        self.power = status;
        let Some(why) = self.violation() else {
            self.guard = None;
            return Vec::new();
        };
        if self.mode == AwakeMode::Off && self.lid == LidState::Off {
            return Vec::new();
        }
        let mut fx = self.shut_down();
        self.guard = Some(why.clone());
        fx.push(notice("Caffeine turned off", why));
        fx
    }

    /// Expire the timer and the closed-lid limit if due; idempotent for the
    /// same `now_ms`.
    pub fn tick(&mut self, now_ms: u64) -> Vec<CaffeineEffect> {
        let mut fx = match self.until_ms {
            Some(u) if now_ms >= u => self.shut_down(),
            _ => Vec::new(),
        };
        if self.lid_deadline().is_some_and(|d| now_ms >= d) {
            self.lid = LidState::Off;
            fx.push(CaffeineEffect::DisableLid);
            fx.push(notice(
                "Lid mode turned off",
                format!("It had been on for {LID_MAX_HOURS} hours. It starts again the next time keep awake is turned on."),
            ));
        }
        fx
    }

    /// View model; `remaining_secs` is derived from `now_ms` (clock going backwards just
    /// shows more time left).
    pub fn snapshot(&self, now_ms: u64) -> CaffeineSnapshot {
        let remaining_secs = self.until_ms.map(|u| {
            let ms = u.saturating_sub(now_ms);
            u32::try_from(ms.div_ceil(1000)).unwrap_or(u32::MAX)
        });
        CaffeineSnapshot {
            mode: self.mode,
            lid: self.lid,
            remaining_secs,
            until_ms: self.until_ms,
            guard: self.guard.clone(),
        }
    }

    /// When `tick` next needs to run.
    pub fn next_deadline(&self) -> Option<u64> {
        [self.until_ms, self.lid_deadline()]
            .into_iter()
            .flatten()
            .min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn batt(p: u8) -> PowerStatus {
        PowerStatus {
            on_ac: false,
            battery_pct: Some(p),
        }
    }
    fn ac() -> PowerStatus {
        PowerStatus {
            on_ac: true,
            battery_pct: Some(50),
        }
    }
    fn c() -> Caffeine {
        Caffeine::new(CaffeineConfig::default())
    }
    /// What turning the lid choice on or off does: the choice is saved, and
    /// applied now if keep awake is on. Starting keep awake with it set brings
    /// the lid along.
    trait LidChoice {
        fn set_lid(&mut self, on: bool, now_ms: u64) -> Vec<CaffeineEffect>;
    }
    impl LidChoice for Caffeine {
        fn set_lid(&mut self, on: bool, now_ms: u64) -> Vec<CaffeineEffect> {
            let mut cfg = self.config().clone();
            cfg.lid_closed = on;
            let fx = self.set_config(cfg);
            if on && self.snapshot(now_ms).mode == AwakeMode::Off {
                let m = self.config().default_mode;
                return self.activate(m, None, now_ms);
            }
            fx
        }
    }
    fn is_notice(e: &CaffeineEffect) -> bool {
        matches!(e, CaffeineEffect::Notice { .. })
    }

    #[test]
    fn defaults_match_contract() {
        let cfg = CaffeineConfig::default();
        assert_eq!(cfg.default_mode, AwakeMode::Display);
        assert_eq!(cfg.battery_floor_pct, 10);
        assert!(!cfg.lid_closed);
        assert_eq!(AwakeMode::default(), AwakeMode::Off);
        assert_eq!(LidState::default(), LidState::Off);
        let p = PowerStatus::default();
        assert!(p.on_ac && p.battery_pct.is_none());
    }

    #[test]
    fn new_is_idle() {
        let k = c();
        let s = k.snapshot(0);
        assert_eq!(s.mode, AwakeMode::Off);
        assert_eq!(s.lid, LidState::Off);
        assert_eq!(s.remaining_secs, None);
        assert_eq!(s.until_ms, None);
        assert_eq!(s.guard, None);
        assert_eq!(k.next_deadline(), None);
        assert_eq!(k.config(), &CaffeineConfig::default());
    }

    #[test]
    fn activate_sets_assertion_and_timer() {
        let mut k = c();
        let fx = k.activate(AwakeMode::System, Some(60), 1000);
        assert_eq!(fx, vec![CaffeineEffect::SetAssertion(AwakeMode::System)]);
        let s = k.snapshot(1000);
        assert_eq!(s.remaining_secs, Some(60));
        assert_eq!(s.until_ms, Some(61_000));
        assert_eq!(k.next_deadline(), Some(61_000));
    }

    #[test]
    fn activate_same_mode_only_resets_timer_without_effects() {
        let mut k = c();
        k.activate(AwakeMode::Display, Some(10), 0);
        assert!(k.activate(AwakeMode::Display, Some(100), 5000).is_empty());
        assert_eq!(k.next_deadline(), Some(105_000));
        assert!(k.activate(AwakeMode::Display, None, 6000).is_empty());
        assert_eq!(k.next_deadline(), None);
    }

    #[test]
    fn activate_switching_mode_emits_new_assertion() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        let fx = k.activate(AwakeMode::Display, None, 1);
        assert_eq!(fx, vec![CaffeineEffect::SetAssertion(AwakeMode::Display)]);
    }

    #[test]
    fn activate_zero_duration_means_indefinite() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(0), 0);
        assert_eq!(k.next_deadline(), None);
        assert!(k.tick(u64::MAX).is_empty());
    }

    #[test]
    fn activate_off_deactivates() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        let fx = k.activate(AwakeMode::Off, None, 1);
        assert_eq!(fx, vec![CaffeineEffect::SetAssertion(AwakeMode::Off)]);
        assert_eq!(k.snapshot(1).mode, AwakeMode::Off);
    }

    #[test]
    fn activate_huge_duration_saturates() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(u32::MAX), u64::MAX - 5);
        assert_eq!(k.next_deadline(), Some(u64::MAX));
        k.activate(AwakeMode::System, Some(u32::MAX), 0);
        assert_eq!(k.snapshot(0).remaining_secs, Some(u32::MAX));
    }

    #[test]
    fn remaining_secs_clamps_to_u32_max() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        k.until_ms = Some(u64::MAX);
        assert_eq!(k.snapshot(0).remaining_secs, Some(u32::MAX));
    }

    #[test]
    fn deactivate_when_idle_is_silent() {
        let mut k = c();
        assert!(k.deactivate(0).is_empty());
        assert!(k.deactivate(0).is_empty());
    }

    #[test]
    fn deactivate_clears_timer_lid_and_guard() {
        let mut k = c();
        k.activate(AwakeMode::Display, Some(5), 0);
        k.set_lid(true, 0);
        k.lid_result(true, 0);
        let fx = k.deactivate(1);
        assert_eq!(
            fx,
            vec![
                CaffeineEffect::DisableLid,
                CaffeineEffect::SetAssertion(AwakeMode::Off)
            ]
        );
        let s = k.snapshot(1);
        assert_eq!(
            (s.mode, s.lid, s.until_ms),
            (AwakeMode::Off, LidState::Off, None)
        );
        assert!(k.deactivate(2).is_empty());
    }

    #[test]
    fn tick_expires_timer_once() {
        let mut k = c();
        k.activate(AwakeMode::Display, Some(2), 0);
        assert!(k.tick(1999).is_empty());
        let fx = k.tick(2000);
        assert_eq!(fx, vec![CaffeineEffect::SetAssertion(AwakeMode::Off)]);
        assert!(k.tick(2000).is_empty());
        assert!(k.tick(9000).is_empty());
        assert_eq!(k.next_deadline(), None);
    }

    #[test]
    fn tick_expiry_disables_lid() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(1), 0);
        k.set_lid(true, 0);
        k.lid_result(true, 0);
        let fx = k.tick(1000);
        assert_eq!(
            fx,
            vec![
                CaffeineEffect::DisableLid,
                CaffeineEffect::SetAssertion(AwakeMode::Off)
            ]
        );
    }

    #[test]
    fn tick_without_timer_is_noop() {
        let mut k = c();
        assert!(k.tick(5).is_empty());
        k.activate(AwakeMode::System, None, 0);
        assert!(k.tick(u64::MAX).is_empty());
    }

    #[test]
    fn clock_going_backwards_extends_remaining() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(10), 100_000);
        assert_eq!(k.snapshot(100_000).remaining_secs, Some(10));
        assert_eq!(k.snapshot(50_000).remaining_secs, Some(60));
        assert!(k.tick(50_000).is_empty());
        assert_eq!(k.snapshot(200_000).remaining_secs, Some(0));
    }

    #[test]
    fn remaining_rounds_up() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(10), 0);
        assert_eq!(k.snapshot(9_001).remaining_secs, Some(1));
        assert_eq!(k.snapshot(9_999).remaining_secs, Some(1));
    }

    #[test]
    fn set_lid_while_off_activates_default_mode_then_pending() {
        let mut k = c();
        let fx = k.set_lid(true, 0);
        assert_eq!(
            fx,
            vec![
                CaffeineEffect::SetAssertion(AwakeMode::Display),
                CaffeineEffect::EnableLid
            ]
        );
        let s = k.snapshot(0);
        assert_eq!((s.mode, s.lid), (AwakeMode::Display, LidState::Pending));
    }

    #[test]
    fn set_lid_while_active_keeps_mode_and_timer() {
        let mut k = c();
        k.activate(AwakeMode::System, Some(30), 0);
        let fx = k.set_lid(true, 1);
        assert_eq!(fx, vec![CaffeineEffect::EnableLid]);
        assert_eq!(k.snapshot(1).mode, AwakeMode::System);
        assert_eq!(k.next_deadline(), Some(30_000));
    }

    #[test]
    fn set_lid_repeated_is_silent() {
        let mut k = c();
        k.set_lid(true, 0);
        assert!(k.set_lid(true, 1).is_empty());
        k.lid_result(true, 2);
        assert!(k.set_lid(true, 3).is_empty());
    }

    #[test]
    fn set_lid_off_variants() {
        let mut k = c();
        assert!(k.set_lid(false, 0).is_empty());
        k.set_lid(true, 0);
        assert_eq!(k.set_lid(false, 1), vec![CaffeineEffect::DisableLid]);
        assert_eq!(k.snapshot(1).lid, LidState::Off);
        assert_eq!(k.snapshot(1).mode, AwakeMode::Display);
        k.set_lid(true, 2);
        k.lid_result(true, 3);
        assert_eq!(k.set_lid(false, 4), vec![CaffeineEffect::DisableLid]);
    }

    /// From review: the root helper stops after its cap, and the mode kept
    /// showing as on. The core now ends the mode itself, first, and says so.
    #[test]
    fn lid_mode_turns_itself_off_after_twelve_hours() {
        const H: u64 = 3_600_000;
        let mut k = c();
        k.set_lid(true, 0);
        assert_eq!(
            k.next_deadline(),
            None,
            "not while the password prompt is open"
        );
        k.lid_result(true, 1_000);
        assert_eq!(k.next_deadline(), Some(1_000 + 12 * H));
        assert!(k.tick(1_000 + 12 * H - 1).is_empty());
        let fx = k.tick(1_000 + 12 * H);
        assert_eq!(fx[0], CaffeineEffect::DisableLid);
        assert!(is_notice(&fx[1]));
        assert_eq!(k.snapshot(0).lid, LidState::Off);
        // Keep-awake itself stays on; only the lid part ended.
        assert_ne!(k.snapshot(0).mode, AwakeMode::Off);
        assert_eq!(k.next_deadline(), None);
        assert!(k.tick(1_000 + 13 * H).is_empty(), "once");

        // Turning it off and on again starts a new stretch.
        k.set_lid(true, 20 * H);
        k.lid_result(true, 20 * H);
        assert_eq!(k.next_deadline(), Some(32 * H));
        k.set_lid(false, 21 * H);
        assert_eq!(k.next_deadline(), None);
        assert!(k.tick(40 * H).is_empty());

        // With a keep-awake timer, whichever comes first.
        let mut k = c();
        k.activate(AwakeMode::System, Some(3600), 0);
        k.set_lid(true, 0);
        k.lid_result(true, 0);
        assert_eq!(k.next_deadline(), Some(H));
        let fx = k.tick(H);
        assert!(fx.contains(&CaffeineEffect::DisableLid));
        assert_eq!(k.snapshot(H).lid, LidState::Off);
        assert_eq!(
            fx.iter().filter(|e| is_notice(e)).count(),
            0,
            "the timer ending needs no lid notice"
        );
    }

    #[test]
    fn a_lost_helper_ends_lid_mode_with_a_notice() {
        let mut k = c();
        assert!(k.lid_lost().is_empty());
        k.set_lid(true, 0);
        assert!(
            k.lid_lost().is_empty(),
            "nothing to lose while the prompt is open"
        );
        k.lid_result(true, 1);
        let fx = k.lid_lost();
        assert_eq!(fx[0], CaffeineEffect::DisableLid);
        assert!(is_notice(&fx[1]));
        assert_eq!(k.snapshot(2).lid, LidState::Off);
        assert!(k.lid_lost().is_empty());
    }

    #[test]
    fn sleeping_with_lid_mode_on_ends_it_with_a_notice() {
        let mut k = c();
        assert!(k.lid_slept().is_empty());
        k.set_lid(true, 0);
        k.lid_result(true, 1);
        let fx = k.lid_slept();
        assert_eq!(fx[0], CaffeineEffect::DisableLid);
        assert!(is_notice(&fx[1]));
        assert_eq!(k.snapshot(2).lid, LidState::Off);
        assert!(k.lid_slept().is_empty());
    }

    #[test]
    fn lid_result_success_and_failure() {
        let mut k = c();
        k.set_lid(true, 0);
        assert!(k.lid_result(true, 1).is_empty());
        assert_eq!(k.snapshot(1).lid, LidState::On);

        let mut k = c();
        k.set_lid(true, 0);
        let fx = k.lid_result(false, 1);
        assert_eq!(fx.len(), 1);
        assert!(is_notice(&fx[0]));
        assert_eq!(k.snapshot(1).lid, LidState::Off);
        assert_eq!(k.snapshot(1).mode, AwakeMode::Display);
    }

    #[test]
    fn lid_result_ignored_when_not_pending() {
        let mut k = c();
        assert_eq!(k.lid_result(true, 0), vec![CaffeineEffect::DisableLid]);
        assert!(k.lid_result(false, 0).is_empty());
        assert_eq!(k.snapshot(0).lid, LidState::Off);
        k.set_lid(true, 0);
        k.lid_result(true, 0);
        assert!(k.lid_result(false, 1).is_empty());
        assert_eq!(k.snapshot(1).lid, LidState::On);
    }

    #[test]
    fn late_lid_success_after_deactivate_is_reverted() {
        let mut k = c();
        k.set_lid(true, 0);
        k.deactivate(1);
        assert_eq!(k.lid_result(true, 2), vec![CaffeineEffect::DisableLid]);
        assert_eq!(k.snapshot(2).lid, LidState::Off);
    }

    #[test]
    fn low_battery_turns_everything_off_with_notice() {
        let mut k = c();
        k.activate(AwakeMode::Display, Some(60), 0);
        k.set_lid(true, 0);
        k.lid_result(true, 0);
        let fx = k.on_power(batt(9), 1);
        assert_eq!(fx.len(), 3);
        assert_eq!(fx[0], CaffeineEffect::DisableLid);
        assert_eq!(fx[1], CaffeineEffect::SetAssertion(AwakeMode::Off));
        assert!(is_notice(&fx[2]));
        let s = k.snapshot(1);
        assert_eq!(
            (s.mode, s.lid, s.until_ms),
            (AwakeMode::Off, LidState::Off, None)
        );
        assert_eq!(s.guard.as_deref(), Some("Battery at 9%"));
        assert!(k.on_power(batt(8), 2).is_empty());
    }

    #[test]
    fn battery_at_floor_is_allowed() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        assert!(k.on_power(batt(10), 1).is_empty());
        assert_eq!(k.snapshot(1).mode, AwakeMode::System);
    }

    #[test]
    fn mid_battery_without_lid_does_nothing() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        assert!(k.on_power(batt(20), 1).is_empty());
        assert_eq!(k.snapshot(1).guard, None);
    }

    #[test]
    fn ac_power_never_trips_guards() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        let fx = k.on_power(
            PowerStatus {
                on_ac: true,
                battery_pct: Some(1),
            },
            1,
        );
        assert!(fx.is_empty());
        assert_eq!(k.snapshot(1).mode, AwakeMode::System);
    }

    #[test]
    fn activate_refused_on_low_battery() {
        let mut k = c();
        k.on_power(batt(5), 0);
        let fx = k.activate(AwakeMode::System, None, 1);
        assert_eq!(fx.len(), 1);
        assert!(is_notice(&fx[0]));
        assert_eq!(k.snapshot(1).mode, AwakeMode::Off);
    }

    #[test]
    fn guard_clears_on_recovery_and_on_activate() {
        let mut k = c();
        k.activate(AwakeMode::System, None, 0);
        k.on_power(batt(5), 1);
        assert!(k.snapshot(1).guard.is_some());
        k.on_power(ac(), 2);
        assert_eq!(k.snapshot(2).guard, None);

        k.on_power(batt(50), 3);
        k.activate(AwakeMode::System, None, 4);
        k.on_power(batt(5), 5);
        assert!(k.snapshot(5).guard.is_some());
        k.deactivate(6);
        assert_eq!(k.snapshot(6).guard, None);
    }

    #[test]
    fn low_battery_while_idle_sets_no_guard() {
        let mut k = c();
        assert!(k.on_power(batt(3), 0).is_empty());
        assert_eq!(k.snapshot(0).guard, None);
    }

    #[test]
    fn low_battery_with_only_pending_lid_shuts_down() {
        let mut k = c();
        k.set_lid(true, 0);
        let fx = k.on_power(batt(1), 1);
        assert_eq!(fx[0], CaffeineEffect::DisableLid);
        assert_eq!(k.snapshot(1).lid, LidState::Off);
    }

    #[test]
    fn set_config_clamps_and_takes_effect() {
        let mut k = c();
        k.set_config(CaffeineConfig {
            battery_floor_pct: 200,
            ..Default::default()
        });
        assert_eq!(k.config().battery_floor_pct, 100);
        k.activate(AwakeMode::System, None, 0);
        assert!(!k.on_power(batt(99), 1).is_empty());
        let k2 = Caffeine::new(CaffeineConfig {
            battery_floor_pct: 250,
            ..Default::default()
        });
        assert_eq!(k2.config().battery_floor_pct, 100);
    }

    #[test]
    fn config_serde_defaults_and_roundtrip() {
        let cfg: CaffeineConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(cfg, CaffeineConfig::default());
        let cfg: CaffeineConfig =
            serde_json::from_str(r#"{"default_mode":"system","lid_closed":true}"#).unwrap();
        assert_eq!(cfg.default_mode, AwakeMode::System);
        assert!(cfg.lid_closed);
        // Settings saved by earlier versions, with the lid-only limits, still load.
        let old: CaffeineConfig = serde_json::from_str(
            r#"{"battery_floor_pct":15,"lid_battery_floor_pct":25,"lid_requires_ac":true}"#,
        )
        .unwrap();
        assert_eq!((old.battery_floor_pct, old.lid_closed), (15, false));
        let s = serde_json::to_string(&CaffeineEffect::SetAssertion(AwakeMode::Display)).unwrap();
        assert_eq!(s, r#"{"set_assertion":"display"}"#);
        let snap = c().snapshot(0);
        let back: CaffeineSnapshot =
            serde_json::from_str(&serde_json::to_string(&snap).unwrap()).unwrap();
        assert_eq!(back, snap);
        let enc = serde_json::to_string(&LidState::Pending).unwrap();
        assert_eq!(enc, r#""pending""#);
    }

    #[test]
    fn notice_text_is_unicode_safe() {
        let n = notice("แบตต่ำ ☕", "ไม่พอ".to_string());
        assert_eq!(
            n,
            CaffeineEffect::Notice {
                title: "แบตต่ำ ☕".into(),
                body: "ไม่พอ".into()
            }
        );
    }

    fn with_floor(floor: u8) -> Caffeine {
        Caffeine::new(CaffeineConfig {
            battery_floor_pct: floor,
            lid_closed: true,
            ..Default::default()
        })
    }

    fn on_with_lid(k: &mut Caffeine) -> Vec<CaffeineEffect> {
        let fx = k.activate(AwakeMode::System, None, 0);
        k.lid_result(true, 0);
        fx
    }

    #[test]
    fn the_saved_lid_choice_comes_with_keep_awake_every_time_it_is_turned_on() {
        let mut k = with_floor(10);
        assert_eq!(
            on_with_lid(&mut k),
            vec![
                CaffeineEffect::SetAssertion(AwakeMode::System),
                CaffeineEffect::EnableLid
            ]
        );
        assert_eq!(k.snapshot(0).lid, LidState::On);
        // Off takes both away; on brings both back, with no new choice made.
        let fx = k.deactivate(1);
        assert_eq!(
            fx,
            vec![
                CaffeineEffect::DisableLid,
                CaffeineEffect::SetAssertion(AwakeMode::Off)
            ]
        );
        assert!(k.config().lid_closed);
        assert_eq!(
            k.activate(AwakeMode::Display, None, 2),
            vec![
                CaffeineEffect::SetAssertion(AwakeMode::Display),
                CaffeineEffect::EnableLid
            ]
        );
    }

    #[test]
    fn without_the_lid_choice_keep_awake_never_brings_the_lid() {
        let mut k = c();
        assert_eq!(
            k.activate(AwakeMode::System, None, 0),
            vec![CaffeineEffect::SetAssertion(AwakeMode::System)]
        );
        k.deactivate(1);
        assert_eq!(
            k.activate(AwakeMode::System, None, 2),
            vec![CaffeineEffect::SetAssertion(AwakeMode::System)]
        );
    }

    #[test]
    fn changing_the_choice_while_off_only_saves_it_and_while_on_applies_it() {
        let mut k = c();
        let mut cfg = k.config().clone();
        cfg.lid_closed = true;
        assert!(
            k.set_config(cfg.clone()).is_empty(),
            "nothing starts by itself"
        );
        assert_eq!(k.snapshot(0).mode, AwakeMode::Off);
        cfg.lid_closed = false;
        k.set_config(cfg.clone());
        k.activate(AwakeMode::System, None, 0);
        cfg.lid_closed = true;
        assert_eq!(k.set_config(cfg.clone()), vec![CaffeineEffect::EnableLid]);
        k.lid_result(true, 0);
        cfg.lid_closed = false;
        assert_eq!(k.set_config(cfg), vec![CaffeineEffect::DisableLid]);
        assert_eq!(
            k.snapshot(0).mode,
            AwakeMode::System,
            "keep awake carries on"
        );
    }

    #[test]
    fn a_failed_lid_step_keeps_the_choice_and_changing_the_timer_does_not_ask_again() {
        let mut k = with_floor(10);
        k.activate(AwakeMode::System, None, 0);
        let fx = k.lid_result(false, 1);
        assert!(is_notice(&fx[0]));
        assert!(k.config().lid_closed);
        // Picking another duration is not turning keep awake on.
        assert!(k.activate(AwakeMode::System, Some(3600), 2).is_empty());
        assert_eq!(k.snapshot(2).lid, LidState::Off);
        // Turning it off and on again does ask, because the choice is still set.
        k.deactivate(3);
        assert!(k
            .activate(AwakeMode::System, None, 4)
            .contains(&CaffeineEffect::EnableLid));
    }

    #[test]
    fn one_battery_limit_covers_every_mode_with_or_without_the_lid() {
        // Floor 30: both modes stop below it, together.
        let mut k = with_floor(30);
        on_with_lid(&mut k);
        assert!(k.on_power(batt(30), 1).is_empty());
        let fx = k.on_power(batt(29), 2);
        assert!(fx.contains(&CaffeineEffect::DisableLid));
        assert!(fx.contains(&CaffeineEffect::SetAssertion(AwakeMode::Off)));
        assert_eq!(fx.iter().filter(|f| is_notice(f)).count(), 1);
        // And a start is refused below it, lid choice or not.
        assert!(is_notice(&k.activate(AwakeMode::System, None, 3)[0]));
        assert_eq!(k.snapshot(3).mode, AwakeMode::Off);
        let mut plain = Caffeine::new(CaffeineConfig {
            battery_floor_pct: 30,
            ..Default::default()
        });
        plain.on_power(batt(29), 0);
        assert!(is_notice(&plain.activate(AwakeMode::System, None, 1)[0]));
    }

    #[test]
    fn a_limit_of_zero_means_no_restriction_in_either_mode() {
        let mut k = with_floor(0);
        k.on_power(batt(1), 0);
        assert!(on_with_lid(&mut k).contains(&CaffeineEffect::EnableLid));
        assert!(k.on_power(batt(0), 1).is_empty());
        let s = k.snapshot(1);
        assert_eq!(
            (s.mode, s.lid, s.guard),
            (AwakeMode::System, LidState::On, None)
        );
        let mut plain = Caffeine::new(CaffeineConfig {
            battery_floor_pct: 0,
            ..Default::default()
        });
        plain.on_power(batt(1), 0);
        assert!(!plain.activate(AwakeMode::Display, None, 1).is_empty());
        assert!(plain.on_power(batt(0), 2).is_empty());
    }

    #[test]
    fn an_unknown_battery_level_never_trips_the_limit() {
        let mut k = with_floor(50);
        on_with_lid(&mut k);
        let unknown = PowerStatus {
            on_ac: false,
            battery_pct: None,
        };
        assert!(k.on_power(unknown, 1).is_empty());
        assert_eq!(k.snapshot(1).lid, LidState::On);
    }
}
