//! How long ago the keyboard or mouse was last used, for the reminder that
//! the user is still working during a break. One call into Core Graphics
//! when the core asks (a few times per break); nothing polls. It needs no
//! permission and tells nothing about what was typed.

/// Whole seconds since the last keyboard, mouse or trackpad event, or
/// `None` where that cannot be read.
pub fn input_idle_secs() -> Option<u32> {
    imp::seconds().map(to_secs)
}

/// Rounds down; a negative or unreadable value counts as just now.
fn to_secs(s: f64) -> u32 {
    if s.is_finite() && s > 0.0 {
        s.min(f64::from(u32::MAX)) as u32
    } else {
        0
    }
}

#[cfg(target_os = "macos")]
mod imp {
    /// `kCGEventSourceStateHIDSystemState`: input from the hardware.
    const HID_SYSTEM_STATE: i32 = 1;
    /// `kCGAnyInputEventType`.
    const ANY_INPUT: u32 = !0;

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) -> f64;
    }

    pub fn seconds() -> Option<f64> {
        // SAFETY: a pure query taking two plain integers.
        Some(unsafe { CGEventSourceSecondsSinceLastEventType(HID_SYSTEM_STATE, ANY_INPUT) })
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn seconds() -> Option<f64> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seconds_round_down_and_odd_values_count_as_now() {
        assert_eq!(to_secs(12.9), 12);
        assert_eq!(to_secs(-1.0), 0);
        assert_eq!(to_secs(f64::NAN), 0);
        assert_eq!(to_secs(1e12), u32::MAX);
    }

    #[test]
    fn reads_without_failing() {
        if cfg!(target_os = "macos") {
            assert!(input_idle_secs().is_some());
        }
    }
}
