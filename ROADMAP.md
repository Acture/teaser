# TACO roadmap

This roadmap is ordered by risk and usable outcomes, not by visual feature count.
A milestone starts only after the previous milestone's exit gates pass.

## M0 — Foundation and risk retirement

Goal: prove that the selected boundaries can support TACO without rebuilding Ghostty
or placing orchestration on the render path.

Deliverables:

- clean-clone native AppKit host containing a pinned `libghostty` surface and all
  required app resources;
- runtime tick/wakeup, main-thread/lifetime, signed-bundle, Chinese/English IME,
  selection, clipboard, resize, and 120 Hz smoke tests;
- minimal Ghostty semantic-range API experiment and one persisted shell block;
- daemon-owned PTY Session with exclusive detach/reattach, bounded replay, and a
  binary Surface data plane;
- Swift/Rust UniFFI control-path spike with no raw terminal data crossing it;
- Claude and Codex ACP capability smoke tests, explicitly compared with native CLI
  mode rather than treated as equivalent;
- tmux `-CC` parser plus one `taco-bridge` pane covering arbitrary bytes, Unicode,
  bracketed paste, mouse input, resize, flow control, and capture repair;
- best-effort Zed Accessibility tiling and same-window frame restoration.

Exit gates:

- benchmark methodology is locked for the same Ghostty revision, configuration,
  hardware, workload, and refresh rate;
- direct-terminal behavior targets no more than 10% regression from the same Ghostty
  revision; any revised SLO is measurement-backed and recorded before v0.1;
- semantic blocks require only a narrow embedding/query patch, not a new terminal
  model, reflow implementation, or renderer;
- terminal hot paths contain no UniFFI, JSON, or SQLite calls;
- one real child keeps the same PID across Surface detach/reattach, while a second
  live Surface is rejected and replay gaps are explicit;
- explicit Session termination reaps a stubborn descendant in the verified owning
  process group before the attachment closes;
- all spikes have repeatable automated or scripted checks.

Failure policy: stop and revise the foundation. Do not compensate for a failed gate
by adding a second terminal renderer or an unbounded Ghostty fork.

## v0.1 — Daily terminal workspace

Goal: replace the normal local terminal window for daily shell and TUI work.

Deliverables:

- tabs, splits, focus, resize, zoom, command palette, and workspace restoration;
- direct PTY `TerminalSurface` and terminal-grid Neovim;
- Quick Look/Image I/O image preview;
- adjacent Zed desktop companion with safe permission degradation;
- `taco`, `taco shell`, and `taco open` CLI flows.

Exit gate: shell, Neovim, image preview, and external Zed can be used together for a
full work session without input regressions or manual window repair.

## v0.2 — Semantic blocks

Goal: add Warp-like command affordances without replacing terminal-native drawing.

Deliverables:

- fish, zsh, and bash OSC 133/OSC 7 shell integration;
- bounded SQLite BlockStore with live ranges, snapshots, retention controls, and
  eviction handling;
- block status, copy, jump, confirm-before-rerun, focused-pane search, and workspace
  search;
- opaque alternate-screen behavior for TUIs.

Exit gate: command boundaries and copied text remain correct across wrapping,
scrollback, resize, failed commands, prompts spanning multiple lines, and eviction.

## v0.3 — Native agent sessions

Goal: add structured Claude and Codex experiences without inheriting their terminal
composers or pretending ACP covers every vendor CLI feature.

Deliverables:

- ACP protocol/capability negotiation and supervised pinned adapters;
- `taco agent claude` and `taco agent codex`;
- structured turns, plans, tool calls, approvals, diffs, images, and resources;
- reusable native `InputSurface` for multiline input and attachments;
- native `claude` and `codex` remain usable in TerminalSurface;
- adapter crash isolation and transcript preservation.

Exit gate: both structured sessions complete the same supported edit/review workflow
with typed approvals and artifacts, while unsupported adapter capabilities degrade
explicitly and native CLI mode remains available.

## v0.4 — Persistent and remote sessions

Goal: support durable local/remote terminal work without making tmux the UI host.

Deliverables:

- local tmux control-mode backend;
- system SSH command sessions and SSH-carried tmux control mode for preconfigured
  host-key and key/agent authentication;
- separate bootstrap UX for password, MFA, and first-host-key prompts;
- Mosh opaque sessions with visible capability degradation;
- reconnect, flow control, stale-session handling, and pane-size synchronization.

Exit gate: TACO can restart and reattach tmux panes; recovered text is marked
semantic-degraded when block lifecycle was missed; SSH loss does not misroute panes;
Mosh roams while its owning TACO PTY lives and never claims unsupported semantics.

## v1.0 — Daily-driver release

Goal: ship a supportable macOS application rather than a collection of demos.

Deliverables:

- crash recovery, accessibility, permissions UX, bounded history, logs, diagnostics,
  and upgrades;
- Developer ID signing, notarization, GitHub release artifacts, and Homebrew cask;
- Ghostty update gates and accurate third-party notices generated from dependencies
  actually bundled at release time;
- user guide, contributor guide, benchmark report, and CI.

Release criteria:

- shell/Neovim, image, external Zed, native agent CLIs, and structured ACP sessions
  coexist in one daily workflow;
- unsupported CLIs/TUIs work through an unmodified PTY;
- direct terminal and tmux bridge meet the recorded M0 SLOs;
- tmux/SSH recovery and Mosh degradation behave deterministically;
- denied permissions and crashed adapters degrade safely;
- there are no third-party plugin APIs or accidental compatibility promises.

## Explicitly deferred

- native reusable Zed editor surface or Neovim remote-UI renderer;
- Warp-style arbitrary block folding, reordering, or widget containers;
- third-party plugins, ExtensionKit/WASM host, or stable surface SDK;
- custom roaming daemon or replacement for Mosh/tmux;
- Linux/Windows host;
- arbitrary external-GUI embedding or private macOS APIs.
