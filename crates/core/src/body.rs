//! Water and stretch: two gauges that run down with screen time and are
//! filled again by hand. They replace the Move reminder: when one runs
//! empty the closed notch says so once (a Move peek), then it stays empty
//! and quiet until the user fills it.
//!
//! A gauge is a countdown that can be refilled, so the view model carries
//! when it will be empty (`empty_at_ms`), not a percentage: the shell draws
//! the level itself and nothing here changes by the second. While the user
//! is away (screen locked, Mac asleep, lid shut) it stands still.
//!
//! Water is counted in millilitres, the level shown in percent. The tank
//! holds `TANK_ML`, two cups. A cup is `CUP_ML`, and one drunk soon after
//! the last counts less, down to `SIP_ML` right after it (`water_gain`):
//! drinking little and often is gentler than a lot at once (the kidneys
//! clear about 0.8 to 1 L an hour; spread-out drinks are kept better,
//! though the evidence is small). At 250 ml an hour, about 2 L over a
//! working day (EFSA, the US National Academies, NHS 6 to 8 glasses), the
//! tank empties in about 90 minutes. Stretching is quick taps, `REP_PCT`
//! each, one per movement. There is no goal for the day and nothing counts against the
//! user: an empty gauge only means it is a good moment.

use serde::{Deserialize, Serialize};

/// A full water gauge: two cups.
pub const TANK_ML: u32 = 400;
/// A cup drunk at least `CUP_SPACING_MS` after the last one.
pub const CUP_ML: u32 = 200;
/// A cup drunk right after the last one counts as a sip.
pub const SIP_ML: u32 = 50;
/// How long after a cup the next one counts whole again.
pub const CUP_SPACING_MS: u64 = 15 * 60_000;
/// One stretching movement: ten from empty fill it.
pub const REP_PCT: u32 = 10;
/// Where a gauge starts when turned on or when LiteNotch starts: half, so
/// the first drink or stretch already shows.
pub const START_PCT: u32 = 50;

/// Screen time from full to empty, in minutes, when on.
pub const MIN_MINS: u32 = 5;
pub const MAX_MINS: u32 = 180;

/// Which gauges Home's big card shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum BodyShow {
    /// Water and stretch side by side.
    #[default]
    Both,
    /// Water only, across the whole card.
    Water,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct BodyConfig {
    /// Screen time from full to empty; 0 is off (the default).
    pub water_mins: u32,
    pub stretch_mins: u32,
    pub show: BodyShow,
}

impl Default for BodyConfig {
    fn default() -> Self {
        Self {
            water_mins: 0,
            stretch_mins: 0,
            show: BodyShow::Both,
        }
    }
}

impl BodyConfig {
    pub fn normalized(self) -> Self {
        let on = |mins: u32| {
            if mins == 0 {
                0
            } else {
                mins.clamp(MIN_MINS, MAX_MINS)
            }
        };
        Self {
            water_mins: on(self.water_mins),
            stretch_mins: on(self.stretch_mins),
            ..self
        }
    }

    /// Settings saved when there was one Move reminder: it covered water
    /// and stretching, so both gauges take its interval.
    pub fn from_move(move_mins: u32) -> Self {
        Self {
            water_mins: move_mins,
            stretch_mins: move_mins,
            ..Self::default()
        }
        .normalized()
    }
}

/// What one cup counts for, in ml, by how long ago the last one was:
/// from `SIP_ML` right after it up to `CUP_ML`, in steps of 10 ml.
pub fn water_gain(since_last_ms: Option<u64>) -> u32 {
    let Some(gap) = since_last_ms else {
        return CUP_ML;
    };
    let gap = gap.min(CUP_SPACING_MS);
    let ml = u64::from(SIP_ML) + u64::from(CUP_ML - SIP_ML) * gap / CUP_SPACING_MS;
    ((ml + 5) / 10 * 10) as u32
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Which {
    Water,
    Stretch,
}

/// One gauge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Gauge {
    span_ms: u64,
    /// Screen time left at `since`, or now when not counting.
    left_ms: u64,
    /// Counting down since then; `None` while the user is away.
    since: Option<u64>,
    /// The last time it was filled, and by how much (ml for water, percent
    /// for stretch).
    last: Option<(u64, u32)>,
}

impl Gauge {
    fn start(span_ms: u64) -> Self {
        Self {
            span_ms,
            left_ms: span_ms * u64::from(START_PCT) / 100,
            since: None,
            last: None,
        }
    }

    fn left(&self, now: u64) -> u64 {
        match self.since {
            Some(s) => self.left_ms.saturating_sub(now.saturating_sub(s)),
            None => self.left_ms,
        }
    }

    /// Brings it to `now`, counting or not. Returns when it ran empty if
    /// that happened since the last call.
    ///
    /// While it keeps counting nothing is written: the view model would
    /// change on every settle (the pasteboard poll runs twice a second)
    /// and the shell would redraw the panel each time.
    fn sync(&mut self, counting: bool, now: u64) -> Option<u64> {
        let mut emptied = None;
        if let Some(s) = self.since {
            if self.left_ms > 0 && self.left(now) == 0 {
                emptied = Some(s.saturating_add(self.left_ms));
                self.rebase(now);
            }
        }
        if counting != self.since.is_some() {
            self.rebase(now);
            self.since = counting.then_some(now);
        }
        emptied
    }

    /// Makes `left_ms` the time left at `now`.
    fn rebase(&mut self, now: u64) {
        self.left_ms = self.left(now);
        self.since = self.since.map(|_| now);
    }

    fn deadline(&self) -> Option<u64> {
        let s = self.since?;
        (self.left_ms > 0).then(|| s.saturating_add(self.left_ms))
    }

    /// The same share of a new span.
    fn respan(&mut self, span_ms: u64, now: u64) {
        if span_ms == self.span_ms {
            return;
        }
        self.rebase(now);
        if self.span_ms > 0 {
            self.left_ms =
                (u128::from(self.left_ms) * u128::from(span_ms) / u128::from(self.span_ms)) as u64;
        }
        self.span_ms = span_ms;
    }

    /// Adds `amount` out of `whole` (ml of `TANK_ML`, or percent of 100)
    /// at `now`.
    fn add(&mut self, amount: u32, whole: u32, now: u64) {
        self.rebase(now);
        let more = self.span_ms * u64::from(amount) / u64::from(whole.max(1));
        self.left_ms = self.left_ms.saturating_add(more).min(self.span_ms);
        self.last = Some((now, amount));
    }

    fn view(&self, which: Which) -> GaugeView {
        let label = |amount: u32| match which {
            Which::Water => format!("+{amount} ml"),
            Which::Stretch => "+1".to_string(),
        };
        GaugeView {
            span_ms: self.span_ms,
            left_ms: self.left_ms,
            empty_at_ms: self.deadline(),
            last_ms: self.last.map(|(at, _)| at),
            last_label: self.last.map(|(_, amount)| label(amount)),
        }
    }
}

/// One gauge as the shell draws it. While counting, the level is
/// `(empty_at_ms − now) / span_ms`; otherwise `left_ms / span_ms`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GaugeView {
    pub span_ms: u64,
    pub left_ms: u64,
    pub empty_at_ms: Option<u64>,
    /// When it was last filled, for "20m ago".
    pub last_ms: Option<u64>,
    /// What floats up from the button when it was filled: "+200 ml",
    /// "+50 ml" … for water, "+1" for stretch.
    pub last_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BodyView {
    pub water: Option<GaugeView>,
    pub stretch: Option<GaugeView>,
}

/// Both gauges.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Body {
    water: Option<Gauge>,
    stretch: Option<Gauge>,
}

fn span(mins: u32) -> Option<u64> {
    (mins > 0).then(|| u64::from(mins) * 60_000)
}

impl Body {
    /// Takes new settings at `now`: a gauge turned on starts at half, one whose
    /// interval changed keeps its level, one turned off is gone.
    pub fn set_config(&mut self, cfg: &BodyConfig, counting: bool, now: u64) {
        for (gauge, mins) in [
            (&mut self.water, cfg.water_mins),
            (&mut self.stretch, cfg.stretch_mins),
        ] {
            *gauge = match (gauge.take(), span(mins)) {
                (_, None) => None,
                (None, Some(s)) => Some(Gauge::start(s)),
                (Some(mut g), Some(s)) => {
                    g.sync(counting, now);
                    g.respan(s, now);
                    Some(g)
                }
            };
            if let Some(g) = gauge {
                g.sync(counting, now);
            }
        }
    }

    /// Brings both to `now`. Returns the gauges that ran empty since the
    /// last call, with when.
    pub fn sync(&mut self, counting: bool, now: u64) -> Vec<(Which, u64)> {
        let mut out = Vec::new();
        for (which, gauge) in [
            (Which::Water, &mut self.water),
            (Which::Stretch, &mut self.stretch),
        ] {
            if let Some(at) = gauge.as_mut().and_then(|g| g.sync(counting, now)) {
                out.push((which, at));
            }
        }
        out
    }

    /// A cup of water. Returns what it counted for in ml, or `None` when water is
    /// off.
    pub fn drink(&mut self, counting: bool, now: u64) -> Option<u32> {
        let g = self.water.as_mut()?;
        g.sync(counting, now);
        let gain = water_gain(g.last.map(|(at, _)| now.saturating_sub(at)));
        g.add(gain, TANK_ML, now);
        Some(gain)
    }

    /// One stretching movement.
    pub fn stretch(&mut self, counting: bool, now: u64) -> Option<u32> {
        let g = self.stretch.as_mut()?;
        g.sync(counting, now);
        g.add(REP_PCT, 100, now);
        Some(REP_PCT)
    }

    /// When the next gauge runs empty, while counting.
    pub fn next_deadline(&self) -> Option<u64> {
        [self.water, self.stretch]
            .iter()
            .flatten()
            .filter_map(Gauge::deadline)
            .min()
    }

    pub fn view(&self) -> Option<BodyView> {
        if self.water.is_none() && self.stretch.is_none() {
            return None;
        }
        Some(BodyView {
            water: self.water.map(|g| g.view(Which::Water)),
            stretch: self.stretch.map(|g| g.view(Which::Stretch)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_700_000_000_000;
    const MIN: u64 = 60_000;

    fn both(water: u32, stretch: u32) -> Body {
        let mut b = Body::default();
        let cfg = BodyConfig {
            water_mins: water,
            stretch_mins: stretch,
            ..BodyConfig::default()
        };
        b.set_config(&cfg, true, T0);
        // Full, so the times below are whole spans; `starts_at_half` checks
        // where they really start.
        for g in [&mut b.water, &mut b.stretch].into_iter().flatten() {
            g.left_ms = g.span_ms;
        }
        b
    }

    #[test]
    fn starts_at_half() {
        let mut b = Body::default();
        let cfg = BodyConfig {
            water_mins: 60,
            stretch_mins: 0,
            ..BodyConfig::default()
        };
        b.set_config(&cfg, true, T0);
        assert_eq!(level(&b, Which::Water, T0), u64::from(START_PCT));
        assert_eq!(b.next_deadline(), Some(T0 + 30 * MIN));
        assert_eq!(b.view().unwrap().water.unwrap().last_ms, None);
    }

    fn level(b: &Body, which: Which, now: u64) -> u64 {
        let v = b.view().unwrap();
        let g = match which {
            Which::Water => v.water.unwrap(),
            Which::Stretch => v.stretch.unwrap(),
        };
        let left = g
            .empty_at_ms
            .map_or(g.left_ms, |end| end.saturating_sub(now));
        (left * 100 + g.span_ms / 2) / g.span_ms
    }

    #[test]
    fn off_by_default_and_clamped() {
        assert_eq!(Body::default().view(), None);
        let cfg = BodyConfig {
            water_mins: 1,
            stretch_mins: 9_999,
            show: BodyShow::Water,
        }
        .normalized();
        assert_eq!((cfg.water_mins, cfg.stretch_mins), (MIN_MINS, MAX_MINS));
        assert_eq!(BodyConfig::default().normalized().water_mins, 0);
        assert_eq!(BodyConfig::from_move(20).stretch_mins, 20);
        assert_eq!(BodyConfig::from_move(20).water_mins, 20);
    }

    #[test]
    fn a_gauge_starts_full_and_runs_down_with_screen_time() {
        let mut b = both(60, 45);
        assert_eq!(level(&b, Which::Water, T0), 100);
        assert_eq!(b.next_deadline(), Some(T0 + 45 * MIN));
        assert_eq!(level(&b, Which::Water, T0 + 15 * MIN), 75);
        assert!(b.sync(true, T0 + 30 * MIN).is_empty());
        assert_eq!(level(&b, Which::Stretch, T0 + 30 * MIN), 33);
        assert_eq!(
            b.sync(true, T0 + 45 * MIN),
            [(Which::Stretch, T0 + 45 * MIN)]
        );
        assert_eq!(b.next_deadline(), Some(T0 + 60 * MIN));
        // Empty stays empty and quiet.
        assert_eq!(b.sync(true, T0 + 70 * MIN), [(Which::Water, T0 + 60 * MIN)]);
        assert_eq!(b.next_deadline(), None);
        assert!(b.sync(true, T0 + 90 * MIN).is_empty());
        assert_eq!(level(&b, Which::Water, T0 + 90 * MIN), 0);
    }

    #[test]
    fn the_view_does_not_change_while_it_only_counts_down() {
        let mut b = both(60, 45);
        let before = b.view();
        for minute in 1..40 {
            assert!(b.sync(true, T0 + minute * MIN).is_empty());
        }
        assert_eq!(b.view(), before, "the shell draws the fall itself");
        b.sync(true, T0 + 45 * MIN);
        assert_ne!(b.view(), before, "running empty is news");
    }

    #[test]
    fn away_it_stands_still() {
        let mut b = both(60, 0);
        b.sync(true, T0 + 30 * MIN);
        b.sync(false, T0 + 30 * MIN);
        assert_eq!(b.next_deadline(), None);
        assert_eq!(level(&b, Which::Water, T0 + 90 * MIN), 50);
        b.sync(true, T0 + 90 * MIN);
        assert_eq!(b.next_deadline(), Some(T0 + 120 * MIN));
        // Filled while away (a click after the lid opens, before the shell
        // says so) is kept too.
        b.sync(false, T0 + 100 * MIN);
        b.drink(false, T0 + 100 * MIN);
        assert_eq!(level(&b, Which::Water, T0 + 200 * MIN), 83, "20 min + 30");
    }

    #[test]
    fn cups_count_best_one_at_a_time() {
        assert_eq!(water_gain(None), CUP_ML);
        assert_eq!(water_gain(Some(0)), SIP_ML);
        assert_eq!(water_gain(Some(5 * MIN)), 100);
        assert_eq!(water_gain(Some(7 * MIN + 30_000)), 130, "125 rounds up");
        assert_eq!(water_gain(Some(CUP_SPACING_MS)), CUP_ML);
        assert_eq!(water_gain(Some(3 * CUP_SPACING_MS)), CUP_ML);
        assert_eq!(TANK_ML, 2 * CUP_ML, "a cup is half the tank");

        let mut b = both(60, 0);
        b.sync(true, T0 + 60 * MIN);
        assert_eq!(b.drink(true, T0 + 60 * MIN), Some(200));
        assert_eq!(level(&b, Which::Water, T0 + 60 * MIN), 50);
        assert_eq!(b.drink(true, T0 + 60 * MIN), Some(50), "right after: a sip");
        assert_eq!(level(&b, Which::Water, T0 + 60 * MIN), 63);
        let w = b.view().unwrap().water.unwrap();
        assert_eq!(
            (w.last_ms, w.last_label.as_deref()),
            (Some(T0 + 60 * MIN), Some("+50 ml"))
        );
        // Fifteen minutes later a whole cup again; never past full.
        assert_eq!(b.drink(true, T0 + 75 * MIN), Some(200));
        assert_eq!(level(&b, Which::Water, T0 + 75 * MIN), 88);
        assert_eq!(b.drink(true, T0 + 90 * MIN), Some(200));
        assert_eq!(level(&b, Which::Water, T0 + 90 * MIN), 100);
        let w = b.view().unwrap().water.unwrap();
        assert_eq!(w.last_label.as_deref(), Some("+200 ml"));
    }

    #[test]
    fn stretching_is_quick_taps() {
        let mut b = both(0, 45);
        assert_eq!(b.drink(true, T0), None, "water is off");
        b.sync(true, T0 + 45 * MIN);
        for _ in 0..9 {
            assert_eq!(b.stretch(true, T0 + 45 * MIN), Some(REP_PCT));
        }
        assert_eq!(level(&b, Which::Stretch, T0 + 45 * MIN), 90);
        b.stretch(true, T0 + 45 * MIN);
        assert_eq!(level(&b, Which::Stretch, T0 + 45 * MIN), 100);
        let s = b.view().unwrap().stretch.unwrap();
        assert_eq!(s.last_label.as_deref(), Some("+1"));
        assert_eq!(b.view().unwrap().water, None);
    }

    #[test]
    fn new_settings_keep_the_level() {
        let mut b = both(60, 45);
        b.sync(true, T0 + 30 * MIN);
        let longer = BodyConfig {
            water_mins: 120,
            stretch_mins: 45,
            ..BodyConfig::default()
        };
        b.set_config(&longer, true, T0 + 30 * MIN);
        assert_eq!(level(&b, Which::Water, T0 + 30 * MIN), 50);
        assert_eq!(b.next_deadline(), Some(T0 + 45 * MIN));
        let water_off = BodyConfig {
            water_mins: 0,
            ..longer.clone()
        };
        b.set_config(&water_off, true, T0 + 31 * MIN);
        assert_eq!(b.view().unwrap().water, None);
        // On again: from half.
        b.set_config(&longer, true, T0 + 32 * MIN);
        assert_eq!(level(&b, Which::Water, T0 + 32 * MIN), u64::from(START_PCT));
        b.set_config(&BodyConfig::default(), true, T0 + 33 * MIN);
        assert_eq!(b.view(), None);
        assert_eq!(b.next_deadline(), None);
    }
}
