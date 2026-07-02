#!/usr/bin/env bash
# fm-warp-bridge.sh — Warp terminal detection and tmux environment bridge.
#
# This script detects if we're running inside Warp (TERM_PROGRAM=WarpTerminal),
# ensures tmux is available and running, and provides a reliable environment
# for firstmate to operate via the tmux backend.
#
# Design: Instead of controlling Warp directly (local_control is not available
# on stable builds, and Accessibility keystroke simulation requires user
# permission), we detect Warp and auto-launch tmux inside it. All terminal
# operations delegate to the proven tmux backend.
#
# Key insight: Firstmate's tmux backend works perfectly inside Warp because
# Warp is a fully capable terminal emulator. The only missing piece was
# auto-detection — which this script provides.

set -euo pipefail

FM_WARP_BRIDGE_VERSION="0.2.0"

# --- detection ---

fm_warp_detect() {
  [ "${TERM_PROGRAM:-}" = "WarpTerminal" ]
}

fm_warp_check() {
  if ! fm_warp_detect; then
    echo "error: not running inside Warp terminal (TERM_PROGRAM=${TERM_PROGRAM:-unset})" >&2
    return 1
  fi
  echo "detected Warp terminal (v$(osascript -e 'tell application "Warp" to get version' 2>/dev/null || echo "unknown"))" >&2
  return 0
}

# --- tmux environment ---

fm_warp_ensure_tmux() {
  command -v tmux >/dev/null 2>&1 || {
    echo "error: tmux is required but not installed" >&2
    echo "  Install: brew install tmux" >&2
    return 1
  }
  if [ -n "${TMUX:-}" ]; then
    echo "already inside a tmux session ($TMUX)" >&2
    return 0
  fi
  echo "auto-starting tmux session for firstmate inside Warp..." >&2
  exec tmux new-session -s firstmate -d \; attach 2>/dev/null || {
    exec tmux new-session -s firstmate 2>/dev/null || {
      echo "error: failed to start tmux" >&2
      return 1
    }
  }
}

# --- command dispatch ---

case "${1:-help}" in
  detect)
    if fm_warp_detect; then
      echo "TERM_PROGRAM=WarpTerminal"
      return 0
    else
      echo "not-warp"
      return 1
    fi
    ;;
  check)
    fm_warp_check
    ;;
  ensure-tmux)
    fm_warp_ensure_tmux
    ;;
  help|--help|-h)
    echo "fm-warp-bridge.sh v$FM_WARP_BRIDGE_VERSION — Warp detection & tmux launcher"
    echo "Usage: fm-warp-bridge.sh <command>"
    echo ""
    echo "Commands:"
    echo "  detect       Check if running inside Warp (exit 0 if yes)"
    echo "  check        Verbose check with version info"
    echo "  ensure-tmux  Start tmux if not already in one"
    echo ""
    echo "Design: Detects Warp via TERM_PROGRAM env var, then delegates all"
    echo "terminal operations to tmux backend running inside Warp."
    ;;
  *)
    echo "error: unknown command: $1" >&2
    echo "usage: fm-warp-bridge.sh detect|check|ensure-tmux" >&2
    return 1
    ;;
esac
