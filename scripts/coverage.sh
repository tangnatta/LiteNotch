#!/bin/sh
# Runs the Rust tests under coverage and fails below the 90 % line budget.
# Needs: cargo install cargo-llvm-cov; rustup component add llvm-tools
set -eu
cd "$(dirname "$0")/.."
export CARGO_TARGET_DIR=target/cov
exec cargo llvm-cov --workspace --fail-under-lines 90 "$@"
