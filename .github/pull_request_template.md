## What and why

<!-- One or two sentences. Link the issue if there is one: Fixes #123 -->

## Checklist

- [ ] `cargo fmt --all`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace`
- [ ] `swift test --package-path macos` (if the shell changed)
- [ ] A bug fix has a test that fails without the fix
- [ ] View-model change: fixtures regenerated (`cargo run -p litenotch-core --example fixtures -- macos/Fixtures`)
- [ ] Steady work added (timer, animation, poll)? Benchmark scenario added or `scripts/bench.sh --check` still passes
- [ ] User-visible change: entry added under the next version in `CHANGELOG.md`
- [ ] Touches approvals, the socket, the root helper or other security invariants in `CLAUDE.md`? Say so here
