//! Keep-awake through IOKit power assertions. The assertion belongs to this
//! process, so the system drops it if LiteNotch exits for any reason.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Awake {
    #[default]
    Off,
    /// Prevent idle system sleep; the display may still turn off.
    System,
    /// Keep the display on as well.
    Display,
}

#[derive(Debug, PartialEq, Eq)]
pub enum PowerError {
    Unsupported,
    Os(i32),
}

impl std::fmt::Display for PowerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PowerError::Unsupported => write!(f, "keep-awake is not supported on this platform"),
            PowerError::Os(code) => write!(f, "power assertion failed (IOReturn {code:#x})"),
        }
    }
}

impl std::error::Error for PowerError {}

/// Holds at most one assertion; switching modes releases the previous one.
#[derive(Debug, Default)]
pub struct PowerAssertion {
    mode: Awake,
    id: Option<u32>,
}

impl PowerAssertion {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn mode(&self) -> Awake {
        self.mode
    }

    pub fn set(&mut self, mode: Awake) -> Result<(), PowerError> {
        if mode == self.mode {
            return Ok(());
        }
        if let Some(id) = self.id.take() {
            imp::release(id);
        }
        self.mode = Awake::Off;
        if mode != Awake::Off {
            self.id = Some(imp::create(mode)?);
            self.mode = mode;
        }
        Ok(())
    }
}

impl Drop for PowerAssertion {
    fn drop(&mut self) {
        if let Some(id) = self.id.take() {
            imp::release(id);
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::{Awake, PowerError};
    use core_foundation::base::TCFType;
    use core_foundation::string::{CFString, CFStringRef};

    const LEVEL_ON: u32 = 255;

    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        fn IOPMAssertionCreateWithName(
            assertion_type: CFStringRef,
            level: u32,
            name: CFStringRef,
            id: *mut u32,
        ) -> i32;
        fn IOPMAssertionRelease(id: u32) -> i32;
    }

    pub fn create(mode: Awake) -> Result<u32, PowerError> {
        let kind = match mode {
            Awake::Display => "PreventUserIdleDisplaySleep",
            _ => "PreventUserIdleSystemSleep",
        };
        let kind = CFString::new(kind);
        let name = CFString::new("LiteNotch keep awake");
        let mut id = 0u32;
        // SAFETY: both strings outlive the call and `id` is a valid out-pointer.
        let rc = unsafe {
            IOPMAssertionCreateWithName(
                kind.as_concrete_TypeRef(),
                LEVEL_ON,
                name.as_concrete_TypeRef(),
                &mut id,
            )
        };
        if rc == 0 {
            Ok(id)
        } else {
            Err(PowerError::Os(rc))
        }
    }

    pub fn release(id: u32) {
        // SAFETY: `id` came from a successful create and is released once.
        unsafe {
            IOPMAssertionRelease(id);
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::{Awake, PowerError};

    pub fn create(_mode: Awake) -> Result<u32, PowerError> {
        Err(PowerError::Unsupported)
    }

    pub fn release(_id: u32) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_off_and_setting_off_is_a_no_op() {
        let mut a = PowerAssertion::new();
        assert_eq!(a.mode(), Awake::Off);
        assert_eq!(a.set(Awake::Off), Ok(()));
        assert_eq!(a.mode(), Awake::Off);
    }

    #[test]
    fn error_messages_are_readable() {
        assert!(PowerError::Unsupported
            .to_string()
            .contains("not supported"));
        assert!(PowerError::Os(0x2c7).to_string().contains("0x2c7"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn assertion_is_visible_to_the_system_and_released() {
        fn listed() -> bool {
            crate::script::run(
                "/usr/bin/pmset",
                &["-g", "assertions"],
                std::time::Duration::from_secs(5),
            )
            .map(|out| {
                // Only this process's line: a LiteNotch the user is running
                // may hold the same assertion.
                let mine = format!("pid {}(", std::process::id());
                out.lines()
                    .any(|l| l.contains(&mine) && l.contains("LiteNotch keep awake"))
            })
            .unwrap_or(false)
        }
        let mut a = PowerAssertion::new();
        a.set(Awake::System).unwrap();
        assert_eq!(a.mode(), Awake::System);
        assert!(listed(), "assertion should appear in pmset -g assertions");
        a.set(Awake::Display).unwrap();
        assert_eq!(a.mode(), Awake::Display);
        assert!(listed());
        a.set(Awake::Display).unwrap();
        a.set(Awake::Off).unwrap();
        assert!(!listed(), "assertion should be gone after Off");
        a.set(Awake::System).unwrap();
        drop(a);
        assert!(!listed(), "assertion should be released on drop");
    }
}
