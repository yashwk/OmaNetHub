#!/bin/bash

# Network Hub actions: <verb> [args...]
#   notify <message>
#   ts-up | ts-down
#   ts-send <machine> [files...]
#   wifi-toggle | wifi-restart | wifi-qr | speedtest
#   fw-enable | fw-disable | fw-open <port> [proto] | fw-close <port> [proto]

verb=$1
shift || true

notify() {
  omarchy notification send "Network Hub" "$1" -u low -g 󰇣 2>/dev/null
}
fail() {
  omarchy notification send "Network Hub" "$1" -u critical -g 󰇣 2>/dev/null
}

case "$verb" in
  notify)
    notify "$1"
    ;;
  ts-up)
    tailscale up --accept-routes >/dev/null 2>&1 && notify "Tailscale connected" || fail "Tailscale failed to start"
    ;;
  ts-down)
    tailscale down >/dev/null 2>&1 && notify "Tailscale disconnected" || fail "Tailscale failed to stop"
    ;;
  ts-send)
    machine="$1"
    shift || true
    if command -v omarchy-tailscale-send >/dev/null 2>&1; then
      omarchy-tailscale-send "$machine" "$@" &
    elif command -v omarchy >/dev/null 2>&1; then
      omarchy tailscale send "$machine" "$@" &
    else
      tailscale file cp "$@" "$machine:" >/dev/null 2>&1 && notify "Sent to $machine" || fail "Taildrop failed"
    fi
    ;;
  wifi-toggle)
    current=$(nmcli radio wifi 2>/dev/null)
    if [ "$current" = "enabled" ]; then
      nmcli radio wifi off >/dev/null 2>&1 && notify "Wi-Fi turned off" || fail "Failed to turn off Wi-Fi"
    else
      nmcli radio wifi on >/dev/null 2>&1 && notify "Wi-Fi turned on" || fail "Failed to turn on Wi-Fi"
    fi
    ;;
  wifi-restart)
    if command -v omarchy >/dev/null 2>&1; then
      omarchy restart wifi >/dev/null 2>&1 && notify "Wi-Fi restarted" || fail "Wi-Fi restart failed"
    else
      nmcli radio wifi off && sleep 1 && nmcli radio wifi on && notify "Wi-Fi reset" || fail "Wi-Fi reset failed"
    fi
    ;;
  wifi-qr)
    omarchy-shell shell summon omarchy.wifiqr >/dev/null 2>&1 &
    ;;
  speedtest)
    omarchy-shell shell summon omarchy.speedtest >/dev/null 2>&1 &
    ;;
  set-band)
    band="$1"
    if command -v omarchy-network-band >/dev/null 2>&1; then
      omarchy-network-band "$band" >/dev/null 2>&1 && notify "Band set to $band" || fail "Failed to set band"
    fi
    ;;
  set-dns)
    provider="$1"
    if [ "$provider" = "Custom" ]; then
      omarchy-launch-floating-terminal-with-presentation "omarchy-dns Custom" &
    elif command -v omarchy-dns >/dev/null 2>&1; then
      omarchy-dns "$provider" >/dev/null 2>&1 && notify "DNS set to $provider" || fail "Failed to set DNS"
    fi
    ;;
  fw-status)
    omarchy-launch-floating-terminal-with-presentation "sudo ufw status verbose" &
    ;;
  fw-enable)
    sudo ufw enable >/dev/null 2>&1 && notify "Firewall enabled" || fail "Failed to enable firewall"
    ;;
  fw-disable)
    sudo ufw disable >/dev/null 2>&1 && notify "Firewall disabled" || fail "Failed to disable firewall"
    ;;
  fw-open)
    port="$1"
    proto="$2"
    rule="$port"
    [ -n "$proto" ] && rule="$port/$proto"
    sudo ufw allow "$rule" >/dev/null 2>&1 && notify "Port $rule opened" || fail "Port $rule not opened (sudo needed)"
    ;;
  fw-close)
    port="$1"
    proto="$2"
    rule="$port"
    [ -n "$proto" ] && rule="$port/$proto"
    sudo ufw delete allow "$rule" >/dev/null 2>&1 && notify "Port $rule closed" || fail "Port $rule not closed (sudo needed)"
    ;;
  install-nautilus)
    EXT_DIR="$HOME/.local/share/nautilus-python/extensions"
    SRC_PY="$(dirname "$0")/nautilus-extension/taildrop.py"
    if [ ! -f "$EXT_DIR/taildrop.py" ] || ! cmp -s "$SRC_PY" "$EXT_DIR/taildrop.py"; then
      mkdir -p "$EXT_DIR"
      cp "$SRC_PY" "$EXT_DIR/"
      nautilus -q || true
    fi
    ;;
esac