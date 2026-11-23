# Contributing to LiteNotch

Thanks for helping. LiteNotch is a small notch / dynamic-island utility for
macOS: a Rust core with a thin SwiftUI shell. It is a prototype, so the best
contributions are bug fixes, tests, and small focused improvements.

## What we want, and what we do not

- **Welcome:** bug fixes, tests, accessibility and polish, docs, performance
  wins, anything on the "Not done yet" list in [CLAUDE.md](CLAUDE.md).
- **Ask first:** new features. Open an issue and describe the problem. The app
  is intentionally small, with a memory and CPU budget (idle ≤ 0.5 % CPU,
  ≤ 30 MB), so features that need polling, timers or new permissions need a
  conversation. Things deliberately left out (file shelf, Codex usage,
  listening ports) are listed in CLAUDE.md.
- **Security problems:** do not open a public issue; see [SECURITY.md](SECURITY.md).

## Set up

Requirements: an Apple silicon Mac, Xcode command line tools, and Rust via
rustup.

```sh
brew install rustup                                # once; the compiler version is pinned in rust-toolchain.toml
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
scripts/build-app.sh                              # → dist/LiteNotch.app
open dist/LiteNotch.app
```

## Before you open a pull request

Run what CI runs:

```sh
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
scripts/coverage.sh                    # Rust line coverage must stay ≥ 90 %
cargo deny check                       # advisories, licences (brew install cargo-deny)
swift test --package-path macos        # needs scripts/build-app.sh first
scripts/bench.sh --check               # only if you added steady work
```

If you changed the view model, regenerate the shell's fixtures:

```sh
cargo run -p litenotch-core --example fixtures -- macos/Fixtures
```

## Where things go

| Change | Where |
|---|---|
| Behaviour, state, settings, rules | `crates/core` (no I/O, no clock, no threads) |
| macOS calls (pasteboard, power, osascript) | `crates/platform` |
| Pixels | `macos/Sources/LiteNotchUI` |

Rust owns everything except pixels: put logic in the core and keep the shell
dumb. [CLAUDE.md](CLAUDE.md) is the architecture guide; read "How it works" and
"Rules that are easy to break" before a non-trivial change.

## Rules that are easy to break

- Core modules take `now_ms` and never read a clock.
- No `unwrap` / `expect` / `panic!` outside tests.
- Nothing that changes every second goes into the view model; anything that
  moves continuously in the shell must be a Core Animation layer animation.
- Tests must not touch your real pasteboard, `~/.claude`, or
  `~/Library/Application Support/LiteNotch`.
- Do not weaken a security invariant (CLAUDE.md lists them; each has a test).

## Tests

Every bug fix comes with a test that fails without the fix. New behaviour
comes with tests in the same pull request. Add new tabs and Settings sections
to `OverflowTests`.

## Pull requests

- `main` is protected. Branch from `main`, open a pull request, and wait for CI
  (`rust`, `app`) and a review. Never push to `main`.
- Keep a pull request to one change. Describe what and why.
- Add a line to the next version's section of [CHANGELOG.md](CHANGELOG.md) for
  anything users will notice.
- Releases are cut by the maintainer (see "Releasing" in CLAUDE.md).

## Using AI coding tools

Fine, and the repo is set up for it (CLAUDE.md is read by Claude Code). You are
still responsible for the change: run the checks above and read your diff.

## License

By contributing you agree your work is released under the
[GPL-3.0](LICENSE), like the rest of the project.
