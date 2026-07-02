#!/usr/bin/env bash
# fm-warp-bridge.sh — Direct IPC bridge to Warp local_control protocol
# Uses: curl, nc (with -U for Unix sockets), jq

set -euo pipefail

FM_WARP_DISCOVERY_DIR="${HOME}/.warp/local-control"
FM_WARP_BRIDGE_VERSION="0.1.0"
FM_WARP_PROTOCOL_VERSION=1

# --- helpers ---

_bridge_uuid() {
  python3 -c 'import uuid; print(uuid.uuid4())'
}

_bridge_find_instance() {
  local channel="${1:-}"
  if [ -z "$channel" ]; then
    # detect channel from the running Warp app
    channel=$(defaults read dev.warp.Warp-Stable ChannelId 2>/dev/null || echo "stable")
  fi
  local record
  record=$(ls "$FM_WARP_DISCOVERY_DIR"/inst_*.json 2>/dev/null | head -1)
  if [ -z "$record" ]; then
    echo "error: no Warp instances found in $FM_WARP_DISCOVERY_DIR" >&2
    echo "  Ensure Warp is running and local control is enabled (Settings > Scripting)" >&2
    return 1
  fi
  local pid port broker
  pid=$(jq -r '.pid' "$record")
  port=$(jq -r '.endpoint.port // empty' "$record")
  broker=$(jq -r '.credential_broker.socket_path // empty' "$record")
  local instance_id
  instance_id=$(jq -r '.instance_id' "$record")
  
  if [ -z "$port" ] || [ "$port" = "null" ]; then
    echo "error: Warp instance found but local control endpoint is disabled" >&2
    echo "  Enable Scripting in Warp Settings to use local control" >&2
    return 1
  fi
  
  # Resolve broker path
  local broker_path="$FM_WARP_DISCOVERY_DIR/$broker"
  
  printf '%s' "{\"instance_id\":\"$instance_id\",\"pid\":$pid,\"port\":$port,\"broker_path\":\"$broker_path\",\"record\":\"$record\"}"
}

_bridge_get_credential() {
  local broker_path="$1"
  local action="$2"
  local request_id
  request_id=$(_bridge_uuid)
  
  local request
  request=$(printf '{"protocol_version":%d,"request_id":"%s","action":"%s"}' \
    "$FM_WARP_PROTOCOL_VERSION" "$request_id" "$action")
  
  local response
  response=$(echo "$request" | nc -U "$broker_path" 2>/dev/null) || {
    echo "error: failed to connect to credential broker at $broker_path" >&2
    return 1
  }
  
  local token
  token=$(printf '%s' "$response" | jq -r '.bearer_token // empty' 2>/dev/null)
  if [ -z "$token" ]; then
    local err_msg
    err_msg=$(printf '%s' "$response" | jq -r '.error.message // "unknown error"' 2>/dev/null)
    echo "error: credential broker: $err_msg" >&2
    return 1
  fi
  
  printf '%s' "$token"
}

_bridge_send_request() {
  local port="$1"
  local credential="$2"
  local action="$3"
  local params="${4:-{}}"
  local request_id
  request_id=$(_bridge_uuid)
  
  local payload
  payload=$(printf '{"protocol_version":%d,"request_id":"%s","target":{},"action":{"kind":"%s","params":%s}}' \
    "$FM_WARP_PROTOCOL_VERSION" "$request_id" "$action" "$params")
  
  curl -s -X POST "http://127.0.0.1:${port}/v1/control" \
    -H "Authorization: Bearer ${credential}" \
    -H "Content-Type: application/json" \
    -d "$payload"
}

_bridge_action() {
  local action="$1"
  local params="${2:-{}}"
  
  local instance
  instance=$(_bridge_find_instance) || return 1
  local port broker_path
  port=$(printf '%s' "$instance" | jq -r '.port')
  broker_path=$(printf '%s' "$instance" | jq -r '.broker_path')
  
  local credential
  credential=$(_bridge_get_credential "$broker_path" "$action") || return 1
  
  _bridge_send_request "$port" "$credential" "$action" "$params"
}

# --- command dispatch ---

case "${1:-help}" in
  discover)
    _bridge_find_instance
    ;;
    
  tab)
    case "${2:-}" in
      create)
        local label=""
        local cwd=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --label) label="$4"; shift 2 ;;
            --cwd) cwd="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        local params='{"tab_type":"terminal"}'
        [ -n "$cwd" ] && params=$(printf '{"tab_type":"terminal","shell":"cd %s && exec $SHELL"}' "$cwd")
        local response
        response=$(_bridge_action "tab.create" "$params") || return 1
        # Parse response for tab/pane ids
        local tab_id pane_id
        tab_id=$(printf '%s' "$response" | jq -r '.response.data.tab.id // empty' 2>/dev/null)
        pane_id=$(printf '%s' "$response" | jq -r '.response.data.pane.id // empty' 2>/dev/null)
        if [ -n "$tab_id" ]; then
          # Rename tab if label provided
          [ -n "$label" ] && _bridge_action "tab.rename" "{\"title\":\"$label\"}" >/dev/null 2>&1 || true
          printf '%s %s' "$tab_id" "$pane_id"
        else
          printf '%s' "$response"
        fi
        ;;
      list)
        _bridge_action "tab.list"
        ;;
      close)
        local tab_id=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --tab) tab_id="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -n "$tab_id" ]; then
          _bridge_action "tab.close" "{\"mode\":\"target\"}" "--tab" "$tab_id"
        else
          _bridge_action "tab.close" "{\"mode\":\"active\"}"
        fi
        ;;
      rename)
        local tab_id="" name=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --tab) tab_id="$4"; shift 2 ;;
            --name) name="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -z "$name" ] && { echo "error: --name required" >&2; return 1; }
        _bridge_action "tab.rename" "{\"title\":\"$name\"}"
        ;;
      *)
        echo "usage: fm-warp-bridge.sh tab create|list|close|rename" >&2
        return 1
        ;;
    esac
    ;;
    
  pane)
    case "${2:-}" in
      list)
        local tab_filter=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --tab) tab_filter="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        _bridge_action "pane.list"
        ;;
      inspect)
        local pane_id=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --pane) pane_id="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        _bridge_action "pane.inspect"
        ;;
      close)
        local pane_id=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --pane) pane_id="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        _bridge_action "pane.close"
        ;;
      focus)
        local pane_id=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --pane) pane_id="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        _bridge_action "pane.focus"
        ;;
      *)
        echo "usage: fm-warp-bridge.sh pane list|inspect|close|focus" >&2
        return 1
        ;;
    esac
    ;;
    
  input)
    case "${2:-}" in
      insert)
        local pane_id="" text=""
        while [ $# -gt 2 ]; do
          case "$3" in
            --pane) pane_id="$4"; shift 2 ;;
            --text) text="$4"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -z "$text" ] && { echo "error: --text required" >&2; return 1; }
        local escaped
        escaped=$(printf '%s' "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
        _bridge_action "input.insert" "{\"text\":$escaped}"
        ;;
      *)
        echo "usage: fm-warp-bridge.sh input insert --pane X --text T" >&2
        return 1
        ;;
    esac
    ;;
    
  app)
    case "${2:-}" in
      active)
        _bridge_action "app.active"
        ;;
      ping)
        _bridge_action "app.ping"
        ;;
      *)
        echo "usage: fm-warp-bridge.sh app active|ping" >&2
        return 1
        ;;
    esac
    ;;
    
  help|--help|-h)
    echo "fm-warp-bridge.sh v$FM_WARP_BRIDGE_VERSION — Warp local control IPC bridge"
    echo "Usage: fm-warp-bridge.sh <command> [args...]"
    echo ""
    echo "Commands:"
    echo "  discover                    Find running Warp instance"
    echo "  tab create --label X --cwd Y  Create terminal tab"
    echo "  tab list                    List all tabs"
    echo "  tab close --tab X           Close tab"
    echo "  tab rename --tab X --name Y Rename tab"
    echo "  pane list [--tab X]         List panes"
    echo "  pane inspect --pane X       Inspect pane"
    echo "  pane close --pane X         Close pane"
    echo "  pane focus --pane X         Focus pane"
    echo "  input insert --pane X --text T  Insert text into pane"
    echo "  app active                  Show active target chain"
    echo "  app ping                    Ping Warp instance"
    ;;
    
  *)
    echo "error: unknown command: $1" >&2
    echo "usage: fm-warp-bridge.sh discover|tab|pane|input|app" >&2
    return 1
    ;;
esac
