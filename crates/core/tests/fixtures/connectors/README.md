# Connector fixtures

Payloads the agents send to their hooks, used by `crates/core/tests/connectors.rs`
and `crates/cli/tests/cli.rs`.

- `antigravity/`: copied from the examples in
  <https://antigravity.google/docs/hooks> (Nov 2026). `PreInvocation-first`
  and `Stop-busy` change one field of those examples (`invocationNum` 0,
  `fullyIdle` false).
- `codex/`: built from the JSON schemas in
  <https://github.com/openai/codex/tree/main/codex-rs/hooks/schema/generated>
  (`*.command.input.schema.json`): every required field is present. The docs
  give no sample `tool_input`, so that part is made up.
- `gemini/`: built from the field lists in
  <https://geminicli.com/docs/hooks/reference> (the base fields plus each
  event's own). The docs have no sample payloads, and the keys inside
  `Notification.details` are not documented.

None of these has been produced by a live run of the agent itself.
