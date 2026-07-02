#!/usr/bin/env bash
# bin/backends/warp.sh — Warp terminal session-provider adapter (IPC direct).
#
# Container shape: ONE Warp window labeled "Firstmate", ONE tab per task
# (mirrors tmux/herdr). Target string: "<window-id>:<tab-id>:<pane-id>".
# Bridge: bin/fm-warp-bridge.sh (bash, curl+nc+jq+python3).
#
# Known protocol gaps (not in local_control's 55 actions):
#   pane capture/read — no ActionKind; uses osascript fallback
#   send-key (Enter/C-c/Escape) — no ActionKind; uses osascript fallback
#   cwd query — always empty; pane.inspect returns creation-time cwd only
#   busy state — always 'unknown'
#
# Requires: fm-warp-bridge.sh, curl, nc (macOS -U), jq, python3, osascript

FM_BACKEND_WARP_BRIDGE="${FM_BACKEND_LIB_DIR}/fm-warp-bridge.sh"

# --- tool checks ---

fm_backend_warp_tool_check() {
  command -v curl >/dev/null 2>&1 || { echo "error: backend=warp requires curl" >&2; return 1; }
  command -v nc >/dev/null 2>&1 || { echo "error: backend=warp requires nc (netcat)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=warp requires jq" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || { echo "error: backend=warp requires python3" >&2; return 1; }
  [ -x "$FM_BACKEND_WARP_BRIDGE" ] || { echo "error: backend=warp bridge not found at $FM_BACKEND_WARP_BRIDGE" >&2; return 1; }
  return 0
}

fm_backend_warp_version_check() {
  fm_backend_warp_tool_check || return 1
  local ping
  ping=$("$FM_BACKEND_WARP_BRIDGE" app ping 2>/dev/null) || {
    echo "error: Warp IPC ping failed; ensure Warp is running and Scripting enabled (Settings > Scripting)" >&2
    return 1
  }
  local version
  version=$(printf '%s' "$ping" | jq -r '.response.data.instance.client_version // empty' 2>/dev/null)
  [ -n "$version" ] && echo "notice: Warp $version detected via IPC" >&2
  return 0
}

# --- session ---

fm_backend_warp_session() {
  printf 'default'
}

fm_backend_warp_container_ensure() {
  fm_backend_warp_version_check || return 1
  local ping wsid discovered
  ping=$("$FM_BACKEND_WARP_BRIDGE" app ping 2>/dev/null) || return 1
  discovered=$("$FM_BACKEND_WARP_BRIDGE" discover 2>/dev/null) || return 1
  local instance_id port
  instance_id=$(printf '%s' "$discovered" | jq -r '.instance_id // empty' 2>/dev/null)
  port=$(printf '%s' "$discovered" | jq -r '.port // empty' 2>/dev/null)
  [ -n "$instance_id" ] || { echo "error: could not discover Warp instance" >&2; return 1; }
  printf '%s:%s' "$instance_id" "$port"
}

fm_backend_warp_create_task() {
  local container=$1 label=$2 cwd=$3 instance_id port tab_out tab_id pane_id
  instance_id=${container%%:*}
  port=${container#*:}
  local args=""
  [ -n "$cwd" ] && args="--cwd $cwd"
  tab_out=$("$FM_BACKEND_WARP_BRIDGE" tab create --label "$label" $args 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$tab_out" | awk '{print $1}')
  pane_id=$(printf '%s' "$tab_out" | awk '{print $2}')
  [ -n "$tab_id" ] || return 1
  printf '%s:%s:%s' "$instance_id" "$tab_id" "$pane_id"
}

fm_backend_warp_parse_target() {
  local target=$1
  FM_BACKEND_WARP_WINDOW=${target%%:*}
  local rest=${target#*:}
  FM_BACKEND_WARP_TAB=${rest%%:*}
  FM_BACKEND_WARP_PANE=${rest#*:}
  [ -n "$FM_BACKEND_WARP_WINDOW" ] && [ -n "$FM_BACKEND_WARP_TAB" ] && [ -n "$FM_BACKEND_WARP_PANE" ] && [ "$FM_BACKEND_WARP_PANE" != "$rest" ]
}

fm_backend_warp_target_ready() {
  fm_backend_warp_parse_target "$1" || return 1
  return 0
}

# --- capture (NOT in protocol: osascript fallback via lsof bundle-id match) ---
#
# Warp local_control has no pane.read / capture-pane action.
# Fallback: use osascript to get the active terminal window's contents.
# Limitation: can only capture the FOCUSED Warp window/pane, not arbitrary
# targets. Returns empty string for non-focused targets.
fm_backend_warp_capture() {
  local target=$1 lines=${2:-50}
  local captured
  captured=$(osascript -e '
    tell application "System Events"
      set proc to first process whose bundle identifier is "dev.warp.Warp-Stable"
      if proc exists then
        set win to front window of proc
        if win exists then
          -- Get window title as approximate tab identifier
          set winTitle to title of win
          return "__WARP_CAPTURE:" & winTitle & linefeed
        end if
      end if
    end tell
    return "__WARP_CAPTURE:unknown"
  ' 2>/dev/null) || { printf ''; return 0; }
  # Return just the window title as proof-of-life; full content capture
  # requires JXA terminal-access API beyond Security & Privacy scope.
  printf '%s\n' "$captured" | tail -n "$lines"
}

# --- send literal (unsubmitted text via input.insert) ---

fm_backend_warp_send_literal() {
  local target=$1 text=$2 pane_id
  fm_backend_warp_parse_target "$target" || return 1
  "$FM_BACKEND_WARP_BRIDGE" input insert --pane "$FM_BACKEND_WARP_PANE" --text "$text" >/dev/null 2>&1
}

# --- send text line (text + enter via input.insert with \n) ---

fm_backend_warp_send_text_line() {
  local target=$1 text=$2
  fm_backend_warp_parse_target "$target" || return 1
  "$FM_BACKEND_WARP_BRIDGE" input insert --pane "$FM_BACKEND_WARP_PANE" --text "${text}
" >/dev/null 2>&1
}

# --- normalize key ---

fm_backend_warp_normalize_key() {
  case "$1" in
    Enter|enter) printf 'return' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# --- send key (NOT in protocol: osascript fallback) ---
#
# Warp local_control has no tab/pane.sendKey action. Use osascript to send
# keystrokes to the Warp process. Only works for the FOCUSED window.
fm_backend_warp_send_key() {
  local target=$1 key
  key=$(fm_backend_warp_normalize_key "$2")
  case "$key" in
    return)
      osascript -e '
        tell application "System Events"
          tell process "Warp"
            keystroke return
          end tell
        end tell
      ' >/dev/null 2>&1
      ;;
    escape)
      osascript -e '
        tell application "System Events"
          tell process "Warp"
            key code 53
          end tell
        end tell
      ' >/dev/null 2>&1
      ;;
    ctrl+c)
      osascript -e '
        tell application "System Events"
          tell process "Warp"
            keystroke "c" using {control down}
          end tell
        end tell
      ' >/dev/null 2>&1
      ;;
    *)
      # Unknown key - try as literal character
      "$FM_BACKEND_WARP_BRIDGE" input insert --pane "" --text "$key" >/dev/null 2>&1
      ;;
  esac
}

# --- send text submit ---

fm_backend_warp_send_text_submit() {
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0
  fm_backend_warp_send_literal "$target" "$text" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  local typed
  typed=$(fm_backend_warp_capture "$target" 6) || { printf 'unknown'; return 0; }
  while :; do
    fm_backend_warp_send_key "$target" Enter || true
    sleep "$sleep_s"
    local after
    after=$(fm_backend_warp_capture "$target" 6) || { printf 'unknown'; return 0; }
    if [ "$after" != "$typed" ]; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# --- kill (tab.close via bridge) ---

fm_backend_warp_kill() {
  local target=$1 tab_id
  fm_backend_warp_parse_target "$target" || return 0
  "$FM_BACKEND_WARP_BRIDGE" tab close --tab "$FM_BACKEND_WARP_TAB" >/dev/null 2>&1 || true
}

# --- busy state (always unknown — no native primitive) ---

fm_backend_warp_busy_state() {
  printf 'unknown'
}

# --- current path (empty — no live cwd query in protocol) ---

fm_backend_warp_current_path() {
  printf ''
}

# --- list live tabs with fm- prefix labels ---

fm_backend_warp_list_live() {
  local session=$1 tabs
  tabs=$("$FM_BACKEND_WARP_BRIDGE" tab list 2>/dev/null) || return 0
  printf '%s' "$tabs" | jq -r --arg label_prefix "fm-" '
    .response.data.tabs[]?
    | select(.title // "" | startswith($label_prefix))
    | "\(.window_id // "?"):\(.tab_id):\(.pane_id // "")\t\(.title)"
  ' 2>/dev/null
}

# --- resolve bare selector (fallback for ad hoc names without meta) ---

fm_backend_warp_resolve_bare_selector() {
  local name=$1 tabs tab_id window_id pane_id
  tabs=$("$FM_BACKEND_WARP_BRIDGE" tab list 2>/dev/null) || {
    echo "error: no Warp tabs found" >&2
    return 1
  }
  tab_id=$(printf '%s' "$tabs" | jq -r --arg name "$name" '
    .response.data.tabs[]? | select(.title == $name) | .tab_id
  ' 2>/dev/null | head -1)
  [ -n "$tab_id" ] || { echo "error: no Warp tab named $name" >&2; return 1; }
  window_id=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '
    .response.data.tabs[]? | select(.tab_id == $tab) | .window_id // "?"
  ' 2>/dev/null | head -1)
  pane_id=$(printf '%s' "$tabs" | jq -r --arg tab "$tab_id" '
    .response.data.tabs[]? | select(.tab_id == $tab) | .pane_id // ""
  ' 2>/dev/null | head -1)
  printf '%s:%s:%s' "$window_id" "$tab_id" "$pane_id"
}
