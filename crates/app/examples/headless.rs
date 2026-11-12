//! Runs the real runtime without the UI, for end-to-end checks:
//!
//! ```sh
//! cargo run -p litenotch-app --example headless -- /tmp/ln-e2e [allow|deny|pass]
//! LITENOTCH_SOCKET=/tmp/ln-e2e/litenotch.sock litenotch status
//! ```
//!
//! Each view-model change is printed as one line of JSON (compact part
//! only). With a decision argument, every approval request is answered with
//! it after it has been shown, standing in for the user's click.

use std::path::PathBuf;
use std::sync::mpsc;

use litenotch_app::ports::MacPorts;
use litenotch_app::runtime::{Config, Runtime};

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = PathBuf::from(args.next().unwrap_or_else(|| "/tmp/ln-headless".into()));
    let auto = args.next();
    let home = std::env::var("HOME").unwrap_or_default();
    let config = Config {
        claude_dir: std::env::var("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from(&home).join(".claude")),
        dir,
        cli_path: "litenotch".into(),
        serve_socket: true,
        clipboard_poll_ms: 500,
    };
    println!("socket: {}", config.socket_path().display());
    // Set LITENOTCH_NOWPLAYING_LIB to the built helper library to see what is playing.
    let ports = MacPorts::for_app(
        std::env::var("LITENOTCH_NOWPLAYING_LIB")
            .ok()
            .map(PathBuf::from),
        &config.dir,
    );
    let (tx, rx) = mpsc::channel::<String>();
    let runtime = Runtime::start(
        config,
        Box::new(ports),
        Box::new(move |view| {
            let _ = tx.send(view.to_string());
        }),
    )
    .expect("runtime starts (is another LiteNotch using this directory?)");
    for view in rx {
        let view: serde_json::Value = serde_json::from_str(&view).unwrap_or_default();
        println!(
            "{}",
            serde_json::json!({"compact": view["compact"], "pending": view["agents"]["pending"],
                "media": view["media"], "week": view["usage"]["week"], "summary": view["usage"]["summary"]})
        );
        let (Some(decision), Some(pending)) = (&auto, view["agents"]["pending"].as_array()) else {
            continue;
        };
        for request in pending {
            let command = serde_json::json!({"cmd": "agent_decide", "request_id": request["id"], "decision": decision});
            let _ = runtime.send(&command.to_string());
        }
    }
}
