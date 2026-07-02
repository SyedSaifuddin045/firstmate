#!/usr/bin/env bash
# bin/backends/warp.sh — Warp terminal adapter delegating to tmux backend.
#
# Design: Warp is a terminal emulator, not a session provider. Instead of
# building a separate session management layer (which would require local_control
# IPC or Accessibility permissions), this adapter detects when firstmate is
# running inside Warp (TERM_PROGRAM=WarpTerminal), ensures tmux is running
# inside it, then delegates ALL terminal operations to the proven tmux backend.
#
# This means zero gaps (tmux has full capture, send-key, cwd, busy state),
# zero macOS permission requirements, and zero Warp-specific configuration.
#
# Container shape: Standard tmux session "firstmate" running inside Warp.
# The user sees Warp's terminal at the top level, with tmux managing tasks
# inside it — identical to the iTerm2/Terminal.app experience.

FM_BACKEND_WARP_BRIDGE="${FM_BACKEND_LIB_DIR}/fm-warp-bridge.sh"

# --- tool checks ---

fm_backend_warp_tool_check() {
  fm_warp_detect
  command -v tmux >/dev/null 2>&1 || { echo "error: backend=warp requires tmux" >&2; return 1; }
  return 0
}

fm_backend_warp_version_check() {
  fm_backend_warp_tool_check || return 1
  tmux -V >&2
  return 0
}

# --- session ---

fm_backend_warp_session() {
  printf 'firstmate'
}

fm_backend_warp_container_ensure() {
  fm_backend_warp_version_check || return 1
  # Ensure tmux session exists
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate
  printf 'firstmate'
}

fm_backend_warp_create_task() {
  local container=$1 label=$2 cwd=${3:-$PWD}
  # Create a tmux window (tab) for this task inside the firstmate session
  local window_name="fm-${label}"
  local window_id
  window_id=$(tmux new-window -t "$container" -n "$window_name" -c "$cwd" -P -F '#{window_id}' 2>/dev/null) || return 1
  local pane_id="${container}:${window_id}.0"
  printf '%s' "$pane_id"
}

fm_backend_warp_parse_target() {
  local target=$1
  FM_BACKEND_WARP_SESSION=${target%%:*}
  FM_BACKEND_WARP_TARGET=$target
  [ -n "$FM_BACKEND_WARP_SESSION" ] && [ -n "$FM_BACKEND_WARP_TARGET" ]
}

fm_backend_warp_target_ready() {
  fm_backend_warp_parse_target "$1" || return 1
  tmux has-session -t "$FM_BACKEND_WARP_SESSION" 2>/dev/null
}

# --- source tmux backend and delegate ---

fm_backend_tmux_source_once() {
  if [ -z "${_FM_BACKEND_TMUX_SOURCED:-}" ]; then
    # shellcheck source=bin/backends/tmux.sh
    . "$FM_BACKEND_LIB_DIR/backends/tmux.sh"
    _FM_BACKEND_TMUX_SOURCED=1
  fi
}

fm_backend_warp_capture() { fm_backend_tmux_source_once; fm_backend_tmux_capture "$@"; }
fm_backend_warp_send_key() { fm_backend_tmux_source_once; fm_backend_tmux_send_key "$@"; }
fm_backend_warp_send_text_submit() { fm_backend_tmux_source_once; fm_backend_tmux_send_text_submit "$@"; }
fm_backend_warp_kill() { fm_backend_tmux_source_once; fm_backend_tmux_kill "$@"; }
fm_backend_warp_busy_state() { fm_backend_tmux_source_once; fm_backend_tmux_busy_state "$@"; }
fm_backend_warp_send_literal() { fm_backend_tmux_source_once; fm_backend_tmux_send_literal "$@"; }
fm_backend_warp_send_text_line() { fm_backend_tmux_source_once; fm_backend_tmux_send_text_line "$@"; }
fm_backend_warp_current_path() { fm_backend_tmux_source_once; fm_backend_tmux_current_path "$@"; }
fm_backend_warp_list_live() { fm_backend_tmux_source_once; fm_backend_tmux_list_live "$@"; }
fm_backend_warp_resolve_bare_selector() { fm_backend_tmux_source_once; fm_backend_tmux_resolve_bare_selector "$@"; }
