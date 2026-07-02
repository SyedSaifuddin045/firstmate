# Warp Backend — Design & Rationale

## What Changed (v1 → v2)

| Aspect | v1 (IPC Direct) | v2 (tmux-inside-Warp) |
|---|---|---|
| Protocol | Warp local_control HTTP API + Unix socket | tmux session management |
| Detection | `~/.warp/local-control/inst_*.json` discovery files | `TERM_PROGRAM=WarpTerminal` env var |
| Capture | osascript (focused window only, title only) | tmux `capture-pane` — full |
| Send-key | osascript System Events (focused only) | tmux `send-keys` — targetable |
| Live cwd | `pane.inspect` (frozen creation-time cwd) | tmux `display -p '#{pane_current_path}'` |
| Busy state | Always `unknown` | tmux pane hash + regex |

## Why v1 Was Discarded

After the PR merged, real-world testing revealed:

1. **No local_control on Stable** — The `local_control` IPC protocol only ships on Warp's internal dogfood builds. Stable build has NO `~/.warp/local-control/` directory, NO `inst_*.json` discovery files, NO HTTP API on port 9277 (that port is `terminal-server`, not the control API). Warp must be built from source with `--features=local_control` to enable it.

2. **No Accessibility permission** — `keystroke` and `key code` via System Events require macOS Accessibility permission (`UI elements enabled = false`). User was unwilling to grant it. Without it, `send-key` for Enter/Escape/C-c doesn't work.

3. **Protocol gaps remain even with local_control** — Even on dogfood builds, there's no `pane.read`, no `foreground_cwd`, no busy state query. The IPC approach was fundamentally incomplete.

## The tmux-inside-Warp Solution

Warp is a **terminal emulator** — it runs shells (bash, zsh, fish) normally. tmux runs perfectly inside Warp. By detecting Warp via `TERM_PROGRAM=WarpTerminal` and auto-launching tmux, we get:

- Full feature parity with the native tmux backend
- Zero gaps — capture, send-key, cwd, busy state all work
- Zero permissions — Warp detection uses env var, not file access
- Zero config — auto-detects, auto-starts tmux

## Detection Flow

```bash
fm_backend_detect() → "warp"
  ├─ TERM_PROGRAM=WarpTerminal is set
  └─ tmux -V is available (auto-install if missing)
```

## Architecture

```
Warp Terminal
  └─ shell (bash/zsh/fish)
       └─ tmux session "firstmate"
            ├─ window "fm-task-1" (pane 0)
            ├─ window "fm-task-2" (pane 0)
            └─ ...
```

The bridge (`fm-warp-bridge.sh`) is trivially simple — it checks `TERM_PROGRAM` and calls `tmux` commands. No IPC, no credential exchange, no JSON protocol.

## Files

| File | Purpose | Lines |
|---|---|---|
| `bin/fm-warp-bridge.sh` | Warp detection + tmux launcher | ~100 |
| `bin/backends/warp.sh` | Thin adapter sourcing tmux backend | ~100 |

## Rationale for Not Pursuing local_control Further

- Stable build doesn't have it. Most users run Stable.
- Even on dogfood builds, 4 of 8 required operations have no ActionKind.
- Building Warp from source with `--features=local_control` is heavy (Rust workspace, ~30min build).
- tmux is lighter, faster, already works.

If Warp later enables local_control by default on Stable, the v1 bridge can be restored alongside this approach — but tmux-inside-Warp will always be more capable because tmux provides the missing primitives natively.

## Related

- `AGENTS.md §15` — backend implementation guide
- `fm-backend.sh` — auto-detection in `fm_backend_detect()`
- `plans/2026-07-02-warp-backend-accessibility.md` — original implementation plan
