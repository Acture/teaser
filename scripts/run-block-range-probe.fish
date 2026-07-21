#!/opt/homebrew/bin/fish

set expected_commit 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28

if test (count $argv) -lt 1 -o (count $argv) -gt 2
	printf 'usage: fish scripts/run-block-range-probe.fish GHOSTTY_SOURCE [ZIG]\n' >&2
	exit 2
end

set ghostty_source (path resolve $argv[1])
set script_dir (path resolve (dirname (status filename)))
set repo_root (path resolve $script_dir/..)
set patch_file $repo_root/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch
set zig_bin /opt/homebrew/opt/zig@0.15/bin/zig
if test (count $argv) -eq 2
	set zig_bin (path resolve $argv[2])
end

if not command -q git
	printf 'error: git is required\n' >&2
	exit 1
end
if not test -d $ghostty_source/.git
	printf 'error: not a Ghostty Git checkout: %s\n' $ghostty_source >&2
	exit 1
end
if not test -x $zig_bin
	printf 'error: Zig 0.15 not found at %s\n' $zig_bin >&2
	printf 'install it with: brew install zig@0.15\n' >&2
	exit 1
end

set source_commit (git -C $ghostty_source rev-parse $expected_commit 2>/dev/null)
if test $status -ne 0 -o "$source_commit" != $expected_commit
	printf 'error: source checkout does not contain pinned commit %s\n' $expected_commit >&2
	exit 1
end

set work_dir (mktemp -d /tmp/taco-block-probe.XXXXXX)
printf 'INFO cloning pinned Ghostty into %s\n' $work_dir
git clone --quiet --no-hardlinks $ghostty_source $work_dir/ghostty
or exit 1
git -C $work_dir/ghostty checkout --quiet --detach $expected_commit
or exit 1
git -C $work_dir/ghostty apply $patch_file
or exit 1

set -lx ZIG_LOCAL_CACHE_DIR $work_dir/zig-local-cache
set -lx ZIG_GLOBAL_CACHE_DIR $work_dir/zig-global-cache
cd $work_dir/ghostty
or exit 1
$zig_bin build test-lib-vt \
	-Dtest-filter='tracked semantic output survives reflow'
or exit 1

printf 'PASS tracked semantic output survived 80 -> 7 -> 80 column reflow\n'
printf 'INFO retained probe checkout at %s\n' $work_dir/ghostty
