# Warp Backend — Empirical Verification & Protocol Reference

## Overview

Firstmate `backend=warp` enables terminal session management inside [Warp](https://warp.dev), the GPU-accelerated macOS terminal, using Warp's built-in `local_control` IPC protocol directly — no external daemon, no Rust compilation, no `warpctrl` binary.

The bridge (`bin/fm-warp-bridge.sh`) communicates with a running Warp instance over its Unix-socket credential broker (for scoped auth tokens) and HTTP API at `http://127.0.0.1:<port>/v1/control`.

## Protocol Architecture

Warp's `local_control` protocol has three layers:

### 1. Discovery (`~/.warp/local-control/`)

When Warp starts with local control enabled (Settings → Scripting), it writes an `inst_<channel>.json` record:

```json
{
  "instance_id": "uuid",
  "pid": 1234,
  "channel": "stable",
  "endpoint": {"port": 54921},
  "credential_broker": {"socket_path": "inst_stable.sock"}
}
```

The bridge reads this file to discover the active Warp instance.

### 2. Credential Exchange (Unix Socket)

Actions require scoped bearer tokens. The bridge connects to `inst_stable.sock` via `nc -U` and sends a credential request:

```json
{"protocol_version": 1, "request_id": "uuid", "action": "input.insert"}
```

The broker replies with:

```json
{"bearer_token": "token", "scopes": ["input.insert"], "expires_at": "..."}
```

### 3. HTTP API (`http://127.0.0.1:<port>/v1/control`)

All actions are POSTed with `Authorization: Bearer <token>`:

```json
{
  "protocol_version": 1,
  "request_id": "uuid",
  "target": {},
  "action": {"kind": "input.insert", "params": {"text": "echo hello"}}
}
```

## ActionKind Catalog (55 actions, all Implemented)

### Instance
- `instance.list`, `instance.inspect`

### App
- `app.ping`, `app.version`, `app.active`, `app.focus`

### Window
- `window.list`, `window.inspect`, `window.create`, `window.focus`, `window.close`

### Tab
- `tab.list`, `tab.inspect`, `tab.create`, `tab.activate`, `tab.move`
- `tab.close`, `tab.rename`, `tab.reset_name`, `tab.color.set`, `tab.color.clear`

### Pane
- `pane.list`, `pane.inspect`, `pane.split`, `pane.focus`, `pane.navigate`
- `pane.resize`, `pane.maximize`, `pane.unmaximize`, `pane.close`
- `pane.rename`, `pane.reset_name`

### Session
- `session.list`, `session.inspect`, `session.activate`, `session.previous`, `session.next`, `session.reopen_closed`

### Input
- `input.insert`, `input.replace`

### Theme, Appearance, Setting, Keybinding, Action, Surface, File
- 18+ surface/settings/file actions (see `catalog.rs:167-296`)

## Protocol Gaps (vs firstmate backend requirements)

| Required by firstmate | In protocol? | Workaround |
|---|---|---|
| Pane content capture | ❌ No `pane.read` | osascript (focused window only, title only) |
| Send key (Enter/Escape/C-c) | ❌ No `pane.sendKey` | osascript System Events |
| Live cwd query | ❌ `pane.inspect` returns frozen creation cwd | Return empty (same as tmux) |
| Busy state | ❌ No `agent.get` | Always `unknown` (same as tmux) |
| Tab create with cwd | ✅ `tab.create` w/ `TabCreate` | Via bridge |
| Tab list | ✅ `tab.list` | Via bridge |
| Tab close | ✅ `tab.close` | Via bridge |
| Tab rename | ✅ `tab.rename` | Via bridge |
| Input insert text | ✅ `input.insert` | Via bridge |

## Verification Checklist

### Prerequisites
- [ ] Warp installed (Stable channel)
- [ ] Warp running
- [ ] Warp Settings → Scripting enabled

### Step-by-step

```bash
# 1. Check discovery
ls ~/.warp/local-control/inst_*.json
# Expected: file exists with endpoint.port set

# 2. Bridge discover
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh discover
# Expected: JSON with instance_id, pid, port, broker_path

# 3. Bridge ping
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh app ping
# Expected: Warp version response JSON

# 4. Tab create
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh tab create --label fm-test
# Expected: tab_id pane_id (two space-separated uuids)

# 5. Tab list
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh tab list
# Expected: JSON array of tabs with titles

# 6. Input insert
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh input insert --text "echo hello"
# Expected: acknowledgment JSON

# 7. Tab close
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh tab close --tab <tab_id>
# Expected: acknowledgment JSON

# 8. App active
bash ~/.local/share/firstmate/bin/fm-warp-bridge.sh app active
# Expected: active target chain JSON
```

### Firstmate integration test

```bash
# Set backend
export FM_BACKEND=warp

# Try a backend-aware command (requires fm-spawn.sh to support --backend)
fm-spawn.sh --backend warp ...

# Or use the dispatch directly
fm-backend.sh source warp
fm_backend_warp_version_check
```

## Design Decisions

### D1: Bash bridge over Rust
The `local_control` crate (Warp's Rust IPC client) has workspace-internal deps (`base64`, `chrono`, `rand`, `serde`, `reqwest`, `libc`) that require the full Warp workspace to compile. A standalone extraction was estimated at 1-2 days of surgery. Bash (`curl`+`nc -U`+`jq`+`python3`) achieves the same wire protocol in 293 lines, zero compilation.

### D2: IPC direct over `warpctrl` CLI
`warpctrl` (the reference CLI for local_control) is not bundled with Warp and is only available by building from source. Direct IPC gives full protocol access without requiring a separate binary.

### D3: osascript fallback for missing actions
Three firstmate-required operations (capture, send-key, live-cwd) have no ActionKind. AppleScript via `osascript` fills minimal gaps but only targets the FOCUSED window — background pane targeting is not available through Accessibility API without full Automation permission.

### D4: `unknown` for busy state
Unlike herdr's native `agent.get`, Warp's ActionKind has no agent-state query. The backend returns `unknown`, which causes fm-watch.sh to fall back to its own pane-hash + `FM_BUSY_REGEX` detection (same path as tmux).

## Source References

- `crates/local_control/src/protocol.rs` — Request/Response envelope types
- `crates/local_control/src/catalog.rs` — ActionKind enum (55 actions, macro-generated)
- `crates/local_control/src/auth.rs` — CredentialRequest/ScopedCredential exchange
- `crates/local_control/src/discovery.rs` — InstanceRecord discovery protocol
- `crates/local_control/src/client.rs` — Reference Rust IPC client (credential + HTTP flow)
