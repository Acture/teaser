#!/opt/homebrew/bin/fish

set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)

cd $repo_root
or exit 1

cargo fmt --check
or exit 1
cargo clippy --workspace --all-targets --all-features -- -D warnings
or exit 1
cargo test --workspace --all-targets
or exit 1
git diff --check
