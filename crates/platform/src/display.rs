//! Lid and display state, for closed-lid keep-awake.
//!
//! With sleep disabled (`pmset disablesleep 1`) closing the lid no longer
//! sleeps the Mac, and nothing turns the built-in display off by itself.
//! The runtime watches the lid here and puts the display to sleep.
//!
//! The lid is not polled: the power manager sends a "clamshell state
//! changed" message to anyone registered for its general interest messages,
//! and [`LidWatcher`] listens for that on a thread of its own.

use std::time::Duration;

/// The lid as the power manager reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Clamshell {
    pub closed: bool,
    /// A display other than the built-in one is active (clamshell mode with
    /// a monitor): the display must then stay on.
    pub external_display: bool,
}

/// `None` on a Mac without a lid, or when it cannot be read.
pub fn clamshell() -> Option<Clamshell> {
    imp::clamshell()
}

/// Reports the lid's state once at start and again each time it changes.
/// Dropping it stops listening.
pub struct LidWatcher {
    inner: imp::Watcher,
}

impl LidWatcher {
    /// `None` when the system offers no lid notifications.
    pub fn start(sink: impl Fn(Clamshell) + Send + 'static) -> Option<LidWatcher> {
        imp::Watcher::start(Box::new(sink)).map(|inner| LidWatcher { inner })
    }
}

impl Drop for LidWatcher {
    fn drop(&mut self) {
        self.inner.stop();
    }
}

/// Turns the displays off now (the same as `pmset displaysleepnow`, which
/// needs no administrator rights).
pub fn sleep_display() {
    let _ = crate::script::run(
        "/usr/bin/pmset",
        &["displaysleepnow"],
        Duration::from_secs(5),
    );
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Clamshell;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::string::CFString;
    use std::ffi::{c_char, c_void};
    use std::sync::mpsc;
    use std::thread::JoinHandle;

    type IoObject = u32;
    type Sink = Box<dyn Fn(Clamshell) + Send>;
    type InterestCallback = extern "C" fn(*mut c_void, IoObject, u32, *mut c_void);

    /// `kIOPMMessageClamshellStateChange`:
    /// iokit_family_msg(sub_iokit_powermanagement, 0x100).
    const CLAMSHELL_CHANGED: u32 = 0xE003_4100;

    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        fn IOServiceMatching(name: *const c_char) -> *mut c_void;
        fn IOServiceGetMatchingService(main_port: u32, matching: *mut c_void) -> IoObject;
        fn IORegistryEntryCreateCFProperty(
            entry: IoObject,
            key: *const c_void,
            allocator: *const c_void,
            options: u32,
        ) -> *const c_void;
        fn IOObjectRelease(object: IoObject) -> i32;
        fn IONotificationPortCreate(main_port: u32) -> *mut c_void;
        fn IONotificationPortDestroy(port: *mut c_void);
        fn IONotificationPortGetRunLoopSource(port: *mut c_void) -> *mut c_void;
        fn IOServiceAddInterestNotification(
            port: *mut c_void,
            service: IoObject,
            interest: *const c_char,
            callback: InterestCallback,
            refcon: *mut c_void,
            notification: *mut IoObject,
        ) -> i32;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFRunLoopGetCurrent() -> *mut c_void;
        fn CFRunLoopAddSource(rl: *mut c_void, source: *mut c_void, mode: *const c_void);
        fn CFRunLoopRun();
        fn CFRunLoopStop(rl: *mut c_void);
        fn CFRunLoopWakeUp(rl: *mut c_void);
        fn CFRunLoopSourceCreate(
            allocator: *const c_void,
            order: isize,
            context: *mut SourceContext,
        ) -> *mut c_void;
        fn CFRunLoopSourceSignal(source: *mut c_void);
        fn CFRunLoopSourceInvalidate(source: *mut c_void);
        fn CFRelease(cf: *const c_void);
        static kCFRunLoopDefaultMode: *const c_void;
    }

    /// `CFRunLoopSourceContext` (version 0); only `perform` is used.
    #[repr(C)]
    struct SourceContext {
        version: isize,
        info: *mut c_void,
        retain: *const c_void,
        release: *const c_void,
        copy_description: *const c_void,
        equal: *const c_void,
        hash: *const c_void,
        schedule: *const c_void,
        cancel: *const c_void,
        perform: Option<extern "C" fn(*mut c_void)>,
    }

    /// Runs on the watcher thread when `stop` signals: ends its run loop.
    extern "C" fn stop_run_loop(_: *mut c_void) {
        // SAFETY: called by the run loop on its own thread.
        unsafe { CFRunLoopStop(CFRunLoopGetCurrent()) };
    }

    extern "C" fn on_message(refcon: *mut c_void, _: IoObject, message: u32, _: *mut c_void) {
        if message != CLAMSHELL_CHANGED {
            return;
        }
        // SAFETY: `refcon` is the `Sink` owned by the watcher thread, which
        // outlives the notification it registered.
        let sink = unsafe { &*(refcon as *const Sink) };
        if let Some(state) = clamshell() {
            sink(state);
        }
    }

    pub struct Watcher {
        /// The listening thread's run loop and its stop source, as addresses
        /// (CF objects are not `Send`). A signalled source stays pending
        /// until its run loop runs, so a stop can never be lost, even one
        /// sent before the loop has started.
        run_loop: usize,
        stop_source: usize,
        thread: Option<JoinHandle<()>>,
    }

    impl Watcher {
        pub fn start(sink: Sink) -> Option<Watcher> {
            let (ready_tx, ready_rx) = mpsc::channel::<Option<(usize, usize)>>();
            let thread = std::thread::Builder::new()
                .name("litenotch-lid".into())
                .spawn(move || listen(sink, ready_tx))
                .ok()?;
            match ready_rx.recv() {
                Ok(Some((run_loop, stop_source))) => Some(Watcher {
                    run_loop,
                    stop_source,
                    thread: Some(thread),
                }),
                _ => {
                    let _ = thread.join();
                    None
                }
            }
        }

        pub fn stop(&mut self) {
            // SAFETY: the source and run loop belong to the thread joined
            // below, which keeps both alive until its loop has ended; both
            // calls are safe from any thread.
            unsafe {
                CFRunLoopSourceSignal(self.stop_source as *mut c_void);
                CFRunLoopWakeUp(self.run_loop as *mut c_void);
            }
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    fn listen(sink: Sink, ready: mpsc::Sender<Option<(usize, usize)>>) {
        let sink: Box<Sink> = Box::new(sink);
        // SAFETY: every IOKit / CF object created here is released before
        // the function returns; `sink` lives until then too.
        unsafe {
            let service =
                IOServiceGetMatchingService(0, IOServiceMatching(c"IOPMrootDomain".as_ptr()));
            let port = if service == 0 {
                std::ptr::null_mut()
            } else {
                IONotificationPortCreate(0)
            };
            let mut notifier: IoObject = 0;
            let registered = !port.is_null()
                && IOServiceAddInterestNotification(
                    port,
                    service,
                    c"IOGeneralInterest".as_ptr(),
                    on_message,
                    &*sink as *const Sink as *mut c_void,
                    &mut notifier,
                ) == 0;
            if !registered {
                if !port.is_null() {
                    IONotificationPortDestroy(port);
                }
                if service != 0 {
                    IOObjectRelease(service);
                }
                let _ = ready.send(None);
                return;
            }
            let run_loop = CFRunLoopGetCurrent();
            CFRunLoopAddSource(
                run_loop,
                IONotificationPortGetRunLoopSource(port),
                kCFRunLoopDefaultMode,
            );
            let mut context = SourceContext {
                version: 0,
                info: std::ptr::null_mut(),
                retain: std::ptr::null(),
                release: std::ptr::null(),
                copy_description: std::ptr::null(),
                equal: std::ptr::null(),
                hash: std::ptr::null(),
                schedule: std::ptr::null(),
                cancel: std::ptr::null(),
                perform: Some(stop_run_loop),
            };
            let stop_source = CFRunLoopSourceCreate(std::ptr::null(), 0, &mut context);
            if stop_source.is_null() {
                IOObjectRelease(notifier);
                IONotificationPortDestroy(port);
                IOObjectRelease(service);
                let _ = ready.send(None);
                return;
            }
            CFRunLoopAddSource(run_loop, stop_source, kCFRunLoopDefaultMode);
            if let Some(state) = clamshell() {
                sink(state);
            }
            let _ = ready.send(Some((run_loop as usize, stop_source as usize)));
            CFRunLoopRun();
            CFRunLoopSourceInvalidate(stop_source);
            CFRelease(stop_source);
            IOObjectRelease(notifier);
            IONotificationPortDestroy(port);
            IOObjectRelease(service);
        }
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGGetActiveDisplayList(max: u32, displays: *mut u32, count: *mut u32) -> i32;
        fn CGDisplayIsBuiltin(display: u32) -> u32;
    }

    pub fn clamshell() -> Option<Clamshell> {
        // SAFETY: IOServiceMatching returns a dictionary that
        // IOServiceGetMatchingService consumes; the service is released below.
        let service = unsafe {
            IOServiceGetMatchingService(0, IOServiceMatching(c"IOPMrootDomain".as_ptr()))
        };
        if service == 0 {
            return None;
        }
        let key = CFString::from_static_string("AppleClamshellState");
        // SAFETY: `service` is a valid registry entry and `key` outlives the
        // call; a non-null result is a +1 CF object we take ownership of.
        let value = unsafe {
            let raw = IORegistryEntryCreateCFProperty(
                service,
                key.as_concrete_TypeRef().cast(),
                std::ptr::null(),
                0,
            );
            IOObjectRelease(service);
            (!raw.is_null()).then(|| CFType::wrap_under_create_rule(raw.cast()))
        }?;
        let closed = value.downcast::<CFBoolean>().map(bool::from)?;
        Some(Clamshell {
            closed,
            external_display: has_external_display(),
        })
    }

    fn has_external_display() -> bool {
        let mut displays = [0u32; 16];
        let mut count = 0u32;
        // SAFETY: the buffer holds 16 ids and `count` is a valid out-pointer.
        let rc = unsafe { CGGetActiveDisplayList(16, displays.as_mut_ptr(), &mut count) };
        if rc != 0 {
            return false;
        }
        displays[..count.min(16) as usize]
            .iter()
            // SAFETY: plain query on a display id from the list.
            .any(|d| unsafe { CGDisplayIsBuiltin(*d) } == 0)
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    pub fn clamshell() -> Option<super::Clamshell> {
        None
    }

    pub struct Watcher;

    impl Watcher {
        pub fn start(_sink: Box<dyn Fn(super::Clamshell) + Send>) -> Option<Watcher> {
            None
        }

        pub fn stop(&mut self) {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    fn the_lid_state_can_be_read_on_a_laptop() {
        // A desktop Mac has no lid and reports nothing; a laptop running the
        // tests has its lid open.
        if let Some(c) = clamshell() {
            assert!(!c.closed);
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn the_watcher_reports_the_current_state_and_stops_cleanly() {
        let (tx, rx) = std::sync::mpsc::channel();
        let watcher = LidWatcher::start(move |c| {
            let _ = tx.send(c);
        });
        if clamshell().is_some() {
            let watcher = watcher.expect("a laptop offers lid notifications");
            let first = rx.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(!first.closed);
            let started = std::time::Instant::now();
            drop(watcher);
            assert!(started.elapsed() < Duration::from_secs(2));
        }
    }

    /// The security review's L7: a stop right after start must not hang.
    #[cfg(target_os = "macos")]
    #[test]
    fn stopping_at_once_after_starting_never_hangs() {
        if clamshell().is_none() {
            return;
        }
        for _ in 0..50 {
            let started = std::time::Instant::now();
            drop(LidWatcher::start(|_| {}));
            assert!(started.elapsed() < Duration::from_secs(2));
        }
    }
}
