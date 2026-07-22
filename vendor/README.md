# Vendored Dependencies

## Ghostty

- Upstream: <https://github.com/ghostty-org/ghostty>
- Tag: `v1.3.1`
- Commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- License: MIT; see `ghostty/LICENSE` and `../THIRD_PARTY_NOTICES.md`

`vendor/ghostty` is a Git submodule pinned to the commit above. Initialize it
after cloning TACO:

```fish
git submodule update --init -- vendor/ghostty
```

The submodule must remain clean. TACO-owned experiments and patches live in
`patches/ghostty`; application code belongs outside the submodule.

### Verify the semantic-range test

The parent-owned patch adds one terminal-level test proving that raw OSC 133
command output remains readable while the screen reflows from 80 to 7 columns
and back. Run it in a disposable checkout so the submodule remains unchanged:

```fish
set probe_dir (mktemp -d /tmp/taco-ghostty-probe.XXXXXX)
git clone --quiet --no-hardlinks vendor/ghostty $probe_dir/ghostty
git -C $probe_dir/ghostty checkout --quiet --detach \
	332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
git -C $probe_dir/ghostty apply \
	$PWD/patches/ghostty/0001-test-tracked-semantic-output-reflow.patch
cd $probe_dir/ghostty
/opt/homebrew/opt/zig@0.15/bin/zig build test \
	-Dapp-runtime=none \
	'-Dtest-filter=tracked semantic output survives reflow through OSC 133'
```

The first build may download Ghostty dependencies. Zig build outputs and caches
stay in the disposable checkout. Do not use `test-lib-vt` at this pin: it also
compiles Ghostty's C ABI target, which fails on the upstream
`semantic_prompt.Command` union before reaching the filtered Terminal test.

### Update the pin

Fetch an explicitly verified upstream tag, check out its exact commit in the
submodule, and stage the resulting gitlink. Then rebase parent-owned patches,
update this file and `THIRD_PARTY_NOTICES.md`, review the old-to-new upstream
diff, and rerun the semantic test plus `fish scripts/check.fish`. Never use
`git submodule update --remote` as an implicit upgrade.
