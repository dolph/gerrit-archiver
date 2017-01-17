#!/bin/bash
set -ex

DIR=`dirname $(readlink -f $0)`
cd $DIR/..

# Show version information.
rustc --version
cargo --version

# Run linter.
# TODO(dolph): Clippy is unstable and doesn't actually build. Re-enable it when
# it's stable: https://github.com/Manishearth/rust-clippy
# cargo install clippy
# cargo clippy

# Test the project.
cargo test --verbose

# Smoke test the result.
export RUST_LOG=debug
cargo run
./target/debug/gerrit-query
./target/debug/gerrit-query --help
./target/debug/gerrit-query --version
./target/debug/gerrit-query --verbose
