//! Unix-socket server for the `litenotch` CLI.
//!
//! One request line per connection. The reply may take a while (an approval
//! waits for the user), so each connection has a short-lived thread that
//! also notices when the client goes away.

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use litenotch_core::ipc::{Request, Response, MAX_REQUEST_BYTES};

/// Connections served at once; more are refused.
const MAX_CONNECTIONS: usize = 32;
#[cfg(not(test))]
const READ_TIMEOUT: Duration = Duration::from_secs(5);
#[cfg(test)]
const READ_TIMEOUT: Duration = Duration::from_millis(600);
/// Longest a connection is kept waiting for its reply. Longer than any
/// approval can stay pending.
const MAX_WAIT: Duration = Duration::from_secs(150);
const LIVENESS_INTERVAL: Duration = Duration::from_millis(250);

pub enum ServerEvent {
    Request {
        request: Request,
        conn: u64,
        reply: Sender<Response>,
    },
    /// The client disconnected before its reply was sent.
    Gone { conn: u64 },
}

pub struct Server {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    /// Closing this end wakes the accept loop. It must not depend on the
    /// socket file, which may already be gone when the server stops.
    wake: Option<UnixStream>,
    thread: Option<JoinHandle<()>>,
}

impl Server {
    /// Binds `path` and serves until dropped. Fails with `AddrInUse` if
    /// another LiteNotch is already listening there.
    pub fn start(
        path: &Path,
        sink: impl Fn(ServerEvent) + Send + Sync + 'static,
    ) -> std::io::Result<Server> {
        if path.exists() {
            if UnixStream::connect(path).is_ok() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AddrInUse,
                    "LiteNotch is already running",
                ));
            }
            std::fs::remove_file(path)?;
        }
        let listener = UnixListener::bind(path)?;
        crate::store::set_mode(path, 0o600)?;
        listener.set_nonblocking(true)?;
        let (wake, wake_rx) = UnixStream::pair()?;
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let stop = Arc::clone(&stop);
            let sink: Arc<dyn Fn(ServerEvent) + Send + Sync> = Arc::new(sink);
            std::thread::Builder::new()
                .name("litenotch-ipc".into())
                .spawn(move || {
                    accept_loop(listener, wake_rx, stop, sink);
                })?
        };
        Ok(Server {
            path: path.to_path_buf(),
            stop,
            wake: Some(wake),
            thread: Some(thread),
        })
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Closing our end makes the other end readable, which ends the poll.
        drop(self.wake.take());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

fn accept_loop(
    listener: UnixListener,
    wake: UnixStream,
    stop: Arc<AtomicBool>,
    sink: Arc<dyn Fn(ServerEvent) + Send + Sync>,
) {
    let active = Arc::new(AtomicUsize::new(0));
    let next_conn = AtomicU64::new(1);
    loop {
        let woken = wait_readable(&listener, &wake);
        if woken || stop.load(Ordering::SeqCst) {
            break;
        }
        let Ok((stream, _)) = listener.accept() else {
            continue;
        };
        // An accepted socket inherits the listener's non-blocking flag.
        if stream.set_nonblocking(false).is_err() {
            continue;
        }
        if !peer_is_current_user(&stream) || active.load(Ordering::SeqCst) >= MAX_CONNECTIONS {
            continue;
        }
        active.fetch_add(1, Ordering::SeqCst);
        let conn = next_conn.fetch_add(1, Ordering::SeqCst);
        let (sink, active_in_thread) = (Arc::clone(&sink), Arc::clone(&active));
        let spawned = std::thread::Builder::new()
            .name("litenotch-conn".into())
            .spawn(move || {
                serve(stream, conn, &*sink);
                active_in_thread.fetch_sub(1, Ordering::SeqCst);
            });
        if spawned.is_err() {
            active.fetch_sub(1, Ordering::SeqCst);
        }
    }
}

#[repr(C)]
struct PollFd {
    fd: i32,
    events: i16,
    revents: i16,
}

const POLLIN: i16 = 0x1;

/// Blocks until the listener has a connection or the wake socket fires.
/// Returns true when it was the wake socket (or polling itself failed, in
/// which case stopping is the only safe answer).
fn wait_readable(listener: &UnixListener, wake: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    #[cfg(target_os = "macos")]
    type Nfds = u32;
    #[cfg(not(target_os = "macos"))]
    type Nfds = std::ffi::c_ulong;
    extern "C" {
        fn poll(fds: *mut PollFd, nfds: Nfds, timeout: i32) -> i32;
    }
    let mut fds = [
        PollFd {
            fd: listener.as_raw_fd(),
            events: POLLIN,
            revents: 0,
        },
        PollFd {
            fd: wake.as_raw_fd(),
            events: POLLIN,
            revents: 0,
        },
    ];
    // SAFETY: `fds` is a valid array of two pollfd-layout structs and both
    // descriptors stay open for the duration of the call.
    let n = unsafe { poll(fds.as_mut_ptr(), 2, -1) };
    if n < 0 {
        return std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted;
    }
    fds[1].revents != 0
}

fn serve(mut stream: UnixStream, conn: u64, sink: &(dyn Fn(ServerEvent) + Send + Sync)) {
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
    let request = match read_request(&stream) {
        Ok(request) => request,
        Err(message) => {
            let _ = stream.write_all(Response::Error { message }.to_line().as_bytes());
            return;
        }
    };
    let (reply, replies) = mpsc::channel();
    sink(ServerEvent::Request {
        request,
        conn,
        reply,
    });
    let started = Instant::now();
    loop {
        match replies.recv_timeout(LIVENESS_INTERVAL) {
            Ok(response) => {
                let _ = stream.write_all(response.to_line().as_bytes());
                return;
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {
                if client_gone(&stream) || started.elapsed() > MAX_WAIT {
                    sink(ServerEvent::Gone { conn });
                    return;
                }
            }
        }
    }
}

/// Reads one request line. The whole line must arrive within
/// `READ_TIMEOUT`, so a client trickling bytes cannot hold a connection.
fn read_request(mut stream: &UnixStream) -> Result<Request, String> {
    let deadline = Instant::now() + READ_TIMEOUT;
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err("request timed out".to_string());
        }
        let _ = stream.set_read_timeout(Some(left));
        match stream.read(&mut chunk) {
            Ok(0) => return Err("incomplete request".to_string()),
            Ok(n) => {
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.iter().position(|b| *b == b'\n') {
                    bytes.truncate(end);
                    break;
                }
                if bytes.len() > MAX_REQUEST_BYTES {
                    return Err("request too large".to_string());
                }
            }
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Err("request timed out".to_string());
            }
            Err(e) => return Err(format!("read failed: {e}")),
        }
    }
    let line = String::from_utf8(bytes).map_err(|_| "request is not UTF-8".to_string())?;
    Request::parse(&line)
}

/// True once the peer has closed its end.
fn client_gone(stream: &UnixStream) -> bool {
    if stream.set_nonblocking(true).is_err() {
        return true;
    }
    let mut byte = [0u8; 1];
    let gone = match (&*stream).read(&mut byte) {
        Ok(0) => true,
        Ok(_) => false,
        Err(e) => e.kind() != std::io::ErrorKind::WouldBlock,
    };
    let _ = stream.set_nonblocking(false);
    gone
}

/// Only processes of the same user may talk to the app. The socket's
/// permissions already enforce this; checking the peer is a second line.
#[cfg(any(target_os = "macos", target_os = "freebsd"))]
fn peer_is_current_user(stream: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    extern "C" {
        fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
        fn geteuid() -> u32;
    }
    let (mut uid, mut gid) = (u32::MAX, u32::MAX);
    // SAFETY: the descriptor is open for the lifetime of `stream`, and both
    // out-pointers are valid for writes.
    let ok = unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0;
    // SAFETY: geteuid has no preconditions.
    ok && uid == unsafe { geteuid() }
}

#[cfg(not(any(target_os = "macos", target_os = "freebsd")))]
fn peer_is_current_user(_stream: &UnixStream) -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::temp_dir;
    use litenotch_core::agent::Decision;
    use std::io::{BufRead, BufReader};
    use std::sync::Mutex;

    fn roundtrip(path: &Path, line: &str) -> String {
        let mut stream = UnixStream::connect(path).unwrap();
        stream.write_all(line.as_bytes()).unwrap();
        let mut out = String::new();
        BufReader::new(stream).read_line(&mut out).unwrap();
        out
    }

    #[test]
    fn stops_even_when_the_socket_file_is_already_gone() {
        let dir = temp_dir("server-gone");
        let path = dir.join("s.sock");
        let (server, _log) = echo_server(&path);
        std::fs::remove_dir_all(&dir).unwrap();
        let (done, finished) = mpsc::channel();
        std::thread::spawn(move || {
            drop(server);
            let _ = done.send(());
        });
        assert!(finished.recv_timeout(Duration::from_secs(5)).is_ok());
    }

    /// A server that answers every request with `Ok` and records events.
    fn echo_server(path: &Path) -> (Server, Arc<Mutex<Vec<String>>>) {
        let log = Arc::new(Mutex::new(Vec::new()));
        let server = {
            let log = Arc::clone(&log);
            Server::start(path, move |event| match event {
                ServerEvent::Request { request, reply, .. } => {
                    log.lock().unwrap().push(format!("{request:?}"));
                    let _ = reply.send(Response::Ok);
                }
                ServerEvent::Gone { conn } => log.lock().unwrap().push(format!("gone {conn}")),
            })
            .unwrap()
        };
        (server, log)
    }

    #[test]
    fn answers_a_request_and_restricts_the_socket_to_the_user() {
        use std::os::unix::fs::PermissionsExt;
        let path = temp_dir("srv-ok").join("s.sock");
        let (_server, log) = echo_server(&path);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            roundtrip(&path, &Request::Status.to_line()),
            Response::Ok.to_line()
        );
        assert_eq!(log.lock().unwrap().as_slice(), ["Status"]);
    }

    #[test]
    fn rejects_garbage_incomplete_and_oversized_requests() {
        let path = temp_dir("srv-bad").join("s.sock");
        let (_server, log) = echo_server(&path);
        assert!(roundtrip(&path, "not json\n").contains("\"type\":\"error\""));
        assert!(
            roundtrip(&path, "{\"type\":\"decide\",\"decision\":\"allow\"}\n").contains("error")
        );

        // No newline, then the client half-closes.
        let mut stream = UnixStream::connect(&path).unwrap();
        stream.write_all(b"{\"type\":\"status\"}").unwrap();
        stream.shutdown(std::net::Shutdown::Write).unwrap();
        let mut out = String::new();
        BufReader::new(stream).read_line(&mut out).unwrap();
        assert!(out.contains("incomplete request"), "{out}");

        let huge = format!(
            "{{\"type\":\"notify\",\"title\":\"{}\"}}\n",
            "x".repeat(MAX_REQUEST_BYTES + 10)
        );
        let mut stream = UnixStream::connect(&path).unwrap();
        // The server stops reading at the limit, so the write may fail part-way.
        let _ = stream.write_all(huge.as_bytes());
        let mut out = String::new();
        let _ = BufReader::new(stream).read_line(&mut out);
        assert!(out.is_empty() || out.contains("request too large"), "{out}");
        assert!(
            log.lock().unwrap().is_empty(),
            "no bad request reached the handler"
        );
    }

    #[test]
    fn a_slow_reply_is_delivered_and_a_vanished_client_is_reported() {
        let path = temp_dir("srv-slow").join("s.sock");
        type Held = Vec<(u64, Sender<Response>)>;
        let held: Arc<Mutex<Held>> = Arc::default();
        let gone: Arc<Mutex<Vec<u64>>> = Arc::default();
        let _server = {
            let (held, gone) = (Arc::clone(&held), Arc::clone(&gone));
            Server::start(&path, move |event| match event {
                ServerEvent::Request { conn, reply, .. } => {
                    held.lock().unwrap().push((conn, reply))
                }
                ServerEvent::Gone { conn } => gone.lock().unwrap().push(conn),
            })
            .unwrap()
        };
        let wait_for = |n: usize| {
            let deadline = Instant::now() + Duration::from_secs(5);
            while held.lock().unwrap().len() < n && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(10));
            }
            assert_eq!(held.lock().unwrap().len(), n);
        };

        // Client 1 waits; the reply arrives later.
        let mut waiting = UnixStream::connect(&path).unwrap();
        waiting
            .write_all(Request::Status.to_line().as_bytes())
            .unwrap();
        wait_for(1);
        std::thread::sleep(Duration::from_millis(300));
        held.lock().unwrap()[0]
            .1
            .send(Response::Decision {
                decision: Decision::Allow,
            })
            .unwrap();
        let mut out = String::new();
        BufReader::new(&waiting).read_line(&mut out).unwrap();
        assert_eq!(
            out,
            Response::Decision {
                decision: Decision::Allow
            }
            .to_line()
        );

        // Client 2 gives up before any reply.
        let mut quitter = UnixStream::connect(&path).unwrap();
        quitter
            .write_all(Request::Status.to_line().as_bytes())
            .unwrap();
        wait_for(2);
        let conn = held.lock().unwrap()[1].0;
        drop(quitter);
        let deadline = Instant::now() + Duration::from_secs(5);
        while gone.lock().unwrap().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(gone.lock().unwrap().as_slice(), [conn]);
    }

    #[test]
    fn a_client_trickling_bytes_is_cut_off_at_the_deadline() {
        let path = temp_dir("srv-slow-loris").join("s.sock");
        let (_server, log) = echo_server(&path);
        let mut stream = UnixStream::connect(&path).unwrap();
        let started = Instant::now();
        // Each byte arrives well inside any per-read timeout.
        let mut writer = stream.try_clone().unwrap();
        std::thread::spawn(move || {
            for _ in 0..40 {
                if writer.write_all(b" ").is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        let mut out = String::new();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        BufReader::new(&mut stream).read_line(&mut out).unwrap();
        assert!(out.contains("request timed out"), "{out}");
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
        assert!(log.lock().unwrap().is_empty());
    }

    #[test]
    fn non_utf8_requests_are_rejected() {
        let path = temp_dir("srv-utf8").join("s.sock");
        let (_server, _) = echo_server(&path);
        let mut stream = UnixStream::connect(&path).unwrap();
        stream.write_all(b"\xff\xfe\n").unwrap();
        let mut out = String::new();
        BufReader::new(stream).read_line(&mut out).unwrap();
        assert!(out.contains("not UTF-8"), "{out}");
    }

    #[test]
    fn a_dropped_reply_channel_closes_the_connection() {
        let path = temp_dir("srv-drop").join("s.sock");
        let _server = Server::start(&path, |_event| {}).unwrap();
        assert_eq!(roundtrip(&path, &Request::Status.to_line()), "");
    }

    #[test]
    fn a_second_server_is_refused_and_a_stale_socket_is_replaced() {
        let path = temp_dir("srv-dup").join("s.sock");
        let (first, _) = echo_server(&path);
        let err = Server::start(&path, |_| {}).err().unwrap();
        assert_eq!(err.kind(), std::io::ErrorKind::AddrInUse);
        drop(first);
        assert!(!path.exists(), "the socket is removed on shutdown");

        // A socket file left by a crashed process is replaced.
        drop(UnixListener::bind(&path).unwrap());
        assert!(path.exists());
        let (_second, _) = echo_server(&path);
        assert_eq!(
            roundtrip(&path, &Request::Status.to_line()),
            Response::Ok.to_line()
        );
    }

    #[test]
    fn many_clients_are_served_concurrently() {
        let path = temp_dir("srv-many").join("s.sock");
        let (_server, log) = echo_server(&path);
        let handles: Vec<_> = (0..16)
            .map(|_| {
                let path = path.clone();
                std::thread::spawn(move || roundtrip(&path, &Request::Status.to_line()))
            })
            .collect();
        for handle in handles {
            assert_eq!(handle.join().unwrap(), Response::Ok.to_line());
        }
        assert_eq!(log.lock().unwrap().len(), 16);
    }
}
