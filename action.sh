#!/bin/bash
export PATH="/usr/bin:/bin"
export LC_ALL=C

# Network Hub actions: <verb> [args...]
#   notify <message>
#   ts-up | ts-down | set-exit-node [target] | clear-exit-node
#   wifi-connect <ssid> [--stdin [security]] | wifi-disconnect | wifi-rescan
#   wifi-forget <ssid>
#   wifi-toggle | wifi-restart | wifi-qr | speedtest
#   fw-enable | fw-disable | fw-open <port> [proto] | fw-close <port> [proto]

verb=$1
shift || true

# Strip markup delimiters and control characters before notification rendering
clean() {
  printf '%s' "$1" | tr -d "<>\"&'" | tr -d '[:cntrl:]'
}

notify() {
  omarchy notification send -u low -g 󰌗 "Network Hub" "$(clean "$1")" 2>/dev/null
}
fail() {
  omarchy notification send -u critical -g 󰌗 "Network Hub" "$(clean "$1")" 2>/dev/null
}

# Print the UUIDs of every saved Wi-Fi profile that belongs to an SSID.
# Profiles are matched by 802-11-wireless.ssid first (the authoritative link)
# and by connection NAME second, because NM lets a profile be renamed
# independently of its SSID and older setups often have no ssid property set.
# Usage: wifi_profile_uuids <ssid>
wifi_profile_uuids() {
  local want="$1" uuid ssid name
  for uuid in $(timeout 5 nmcli -t -f UUID,TYPE connection show 2>/dev/null \
      | awk -F: '$2 ~ /^(802-11-wireless|wifi)$/ {print $1}'); do
    ssid=$(timeout 2 nmcli -g 802-11-wireless.ssid connection show uuid "$uuid" 2>/dev/null)
    # nmcli escapes ':' in values as '\:', which would break the comparison
    ssid=${ssid//\\:/:}
    if [ -n "$ssid" ] && [ "$ssid" = "$want" ]; then
      printf '%s\n' "$uuid"
      continue
    fi
    name=$(timeout 2 nmcli --escape no -g connection.id connection show uuid "$uuid" 2>/dev/null)
    if [ -n "$name" ] && [ "$name" = "$want" ]; then
      printf '%s\n' "$uuid"
    fi
  done
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
  set-exit-node)
    target="$1"
    if [ -z "$target" ]; then
      if timeout 10 tailscale set --exit-node="" >/dev/null 2>&1 || (command -v sudo >/dev/null 2>&1 && timeout 10 sudo -n tailscale set --exit-node="" >/dev/null 2>&1) || (command -v pkexec >/dev/null 2>&1 && timeout 10 pkexec tailscale set --exit-node="" >/dev/null 2>&1); then
        notify "Exit node disconnected"
      else
        fail "Failed to disconnect exit node"
        echo "Failed to disconnect exit node" >&2
        exit 1
      fi
    else
      if timeout 10 tailscale set --exit-node="$target" >/dev/null 2>&1 || (command -v sudo >/dev/null 2>&1 && timeout 10 sudo -n tailscale set --exit-node="$target" >/dev/null 2>&1) || (command -v pkexec >/dev/null 2>&1 && timeout 10 pkexec tailscale set --exit-node="$target" >/dev/null 2>&1); then
        notify "Exit node set to $target"
      else
        fail "Failed to set exit node to $target"
        echo "Failed to set exit node to $target" >&2
        exit 1
      fi
    fi
    ;;
  clear-exit-node)
    if timeout 10 tailscale set --exit-node="" >/dev/null 2>&1 || (command -v sudo >/dev/null 2>&1 && timeout 10 sudo -n tailscale set --exit-node="" >/dev/null 2>&1) || (command -v pkexec >/dev/null 2>&1 && timeout 10 pkexec tailscale set --exit-node="" >/dev/null 2>&1); then
      notify "Exit node disconnected"
    else
      fail "Failed to disconnect exit node"
      echo "Failed to disconnect exit node" >&2
      exit 1
    fi
    ;;
  wifi-connect)
    ssid="$1"
    pw=""
    sec="$3"
    if [ "$2" = "--stdin" ]; then
      IFS= read -r pw || true
    fi
    if [ -z "$ssid" ]; then
      fail "No Wi-Fi network specified"
      echo "No Wi-Fi network specified" >&2
      exit 1
    fi
    case "$ssid" in
      -*)
        fail "Invalid Wi-Fi network name"
        echo "Invalid Wi-Fi network name: $ssid" >&2
        exit 1
        ;;
    esac
    if [ -n "$pw" ]; then
      key_mgmt="wpa-psk"
      sec_lc=$(printf '%s' "$sec" | tr '[:upper:]' '[:lower:]')
      case "$sec_lc" in
        *eap*|*802.1x*|*8021x*)
          fail "Enterprise Wi-Fi needs extra setup"
          echo "Enterprise Wi-Fi not supported inline: $ssid" >&2
          exit 1
          ;;
        *sae*|*wpa3*)
          key_mgmt="sae"
          ;;
      esac
      # Saved profiles may be renamed, so match by SSID first, NAME second.
      # Update every profile for this SSID: a stale duplicate would otherwise
      # keep autoconnecting with the old PSK and fail again later.
      mapfile -t profiles < <(wifi_profile_uuids "$ssid")
      u="${profiles[0]:-}"
      created=0
      if [ -z "$u" ]; then
        u=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || { hex=$(tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c 32); printf '%s-%s-%s-%s-%s' "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"; })
        timeout 10 nmcli connection add type wifi con-name "$ssid" ssid "$ssid" connection.uuid "$u" autoconnect yes >/dev/null 2>&1
        created=1
        profiles=("$u")
      fi
      for p in "${profiles[@]}"; do
        # With no security hint (the saved-profile update flow), keep whatever
        # key management the profile already uses instead of forcing wpa-psk.
        p_kmgmt="$key_mgmt"
        if [ -z "$sec" ]; then
          existing=$(timeout 2 nmcli -g 802-11-wireless-security.key-mgmt connection show uuid "$p" 2>/dev/null | head -n 1)
          case "$existing" in
            wpa-psk|sae|wpa-eap-suite-b-192) p_kmgmt="$existing" ;;
          esac
        fi
        printf 'set wifi-sec.key-mgmt %s\nset wifi-sec.psk %s\nsave\nquit\n' "$p_kmgmt" "$pw" | timeout 10 nmcli connection edit uuid "$p" >/dev/null 2>&1
      done
      out=$(timeout 25 nmcli connection up uuid "$u" 2>&1)
      rc=$?
      if [ $rc -ne 0 ] && [ "$created" -eq 1 ]; then
        timeout 5 nmcli connection delete uuid "$u" >/dev/null 2>&1 || true
      fi
    else
      out=$(timeout 25 nmcli dev wifi connect "$ssid" 2>&1)
      rc=$?
      if [ $rc -ne 0 ]; then
        out=$(timeout 15 nmcli connection up id "$ssid" 2>&1)
        rc=$?
      fi
    fi
    if [ $rc -eq 0 ]; then
      notify "Connected to $ssid"
    else
      err=$(echo "$out" | sed 's/^Error: //' | head -n 1)
      fail "${err:-Failed to connect to $ssid}"
      echo "$err" >&2
      exit $rc
    fi
    ;;
  wifi-disconnect)
    active=$(timeout 5 nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null | awk -F: '$2=="wifi" && $3 ~ /^connected/ {print $1; exit}')
    if [ -n "$active" ]; then
      if timeout 10 nmcli device disconnect "$active" >/dev/null 2>&1; then
        notify "Wi-Fi disconnected"
      else
        fail "Failed to disconnect Wi-Fi"
        exit 1
      fi
    else
      notify "Wi-Fi disconnected"
    fi
    ;;
  wifi-forget)
    ssid="$1"
    if [ -z "$ssid" ]; then
      fail "No Wi-Fi network specified"
      echo "No Wi-Fi network specified" >&2
      exit 1
    fi
    case "$ssid" in
      -*)
        fail "Invalid Wi-Fi network name"
        echo "Invalid Wi-Fi network name: $ssid" >&2
        exit 1
        ;;
    esac
    # Never delete a profile we just failed to find: an empty list would make
    # "forget" a silent no-op that still reports success.
    mapfile -t forgotten < <(wifi_profile_uuids "$ssid")
    if [ "${#forgotten[@]}" -eq 0 ]; then
      fail "No saved profile for $ssid"
      echo "No saved Wi-Fi profile for $ssid" >&2
      exit 1
    fi
    # Disconnect first when the profile is active, otherwise NM falls back to
    # autoconnecting it again right after deletion.
    active_uuid=$(timeout 5 nmcli -t -f UUID,TYPE,ACTIVE connection show 2>/dev/null \
      | awk -F: '$2 ~ /^(802-11-wireless|wifi)$/ && $3=="yes" {print $1; exit}')
    for uuid in "${forgotten[@]}"; do
      if [ -n "$active_uuid" ] && [ "$uuid" = "$active_uuid" ]; then
        timeout 10 nmcli connection down uuid "$uuid" >/dev/null 2>&1 || true
      fi
      timeout 10 nmcli connection delete uuid "$uuid" >/dev/null 2>&1 || {
        fail "Failed to forget $ssid"
        echo "Failed to delete profile $uuid" >&2
        exit 1
      }
    done
    notify "Forgot Wi-Fi network $ssid"
    ;;
  wifi-rescan)
    timeout 5 nmcli dev wifi rescan >/dev/null 2>&1 && notify "Wi-Fi scan refreshed" || true
    ;;
  wifi-toggle)
    current=$(timeout 3 nmcli radio wifi 2>/dev/null)
    if [ "$current" = "enabled" ]; then
      timeout 5 nmcli radio wifi off >/dev/null 2>&1 && notify "Wi-Fi turned off" || fail "Failed to turn off Wi-Fi"
    else
      timeout 5 nmcli radio wifi on >/dev/null 2>&1 && notify "Wi-Fi turned on" || fail "Failed to turn on Wi-Fi"
    fi
    ;;
  wifi-restart)
    if command -v omarchy-restart-wifi >/dev/null 2>&1; then
      omarchy-restart-wifi >/dev/null 2>&1 && notify "Wi-Fi restarted" || fail "Wi-Fi restart failed"
    else
      timeout 5 nmcli radio wifi off && sleep 1 && timeout 5 nmcli radio wifi on && notify "Wi-Fi reset" || fail "Wi-Fi reset failed"
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
    if [[ ! "$band" =~ ^(auto|2\.4|5)$ ]]; then
      fail "Invalid band selection"
      exit 1
    fi
    if command -v omarchy-network-band >/dev/null 2>&1; then
      omarchy-network-band "$band" >/dev/null 2>&1 && notify "Band set to $band" || fail "Failed to set band"
    fi
    ;;
  set-dns)
    provider="$1"
    if [[ ! "$provider" =~ ^(DHCP|Cloudflare|Google|Mullvad|Custom)$ ]]; then
      fail "Invalid DNS provider"
      exit 1
    fi
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
    sudo -n ufw enable >/dev/null 2>&1 && notify "Firewall enabled" || fail "Failed to enable firewall (sudo needed)"
    ;;
  fw-disable)
    sudo -n ufw disable >/dev/null 2>&1 && notify "Firewall disabled" || fail "Failed to disable firewall (sudo needed)"
    ;;
  fw-open)
    port="$1"
    proto="$2"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      fail "Invalid port number"
      exit 1
    fi
    if [[ -n "$proto" && ! "$proto" =~ ^(tcp|udp)$ ]]; then
      fail "Invalid protocol"
      exit 1
    fi
    rule="$port"
    [ -n "$proto" ] && rule="$port/$proto"
    sudo -n ufw allow "$rule" >/dev/null 2>&1 && notify "Port $rule opened" || fail "Port $rule not opened (sudo needed)"
    ;;
  fw-close)
    port="$1"
    proto="$2"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      fail "Invalid port number"
      exit 1
    fi
    if [[ -n "$proto" && ! "$proto" =~ ^(tcp|udp)$ ]]; then
      fail "Invalid protocol"
      exit 1
    fi
    rule="$port"
    [ -n "$proto" ] && rule="$port/$proto"
    sudo -n ufw delete allow "$rule" >/dev/null 2>&1 && notify "Port $rule closed" || fail "Port $rule not closed (sudo needed)"
    ;;
  install-nautilus)
    "$(dirname "$0")/bin/install-nautilus-extension" && notify "Taildrop Nautilus extension installed" || fail "Failed to install Nautilus extension"
    ;;
  uninstall-nautilus)
    "$(dirname "$0")/bin/uninstall-nautilus-extension" && notify "Taildrop Nautilus extension removed" || fail "Failed to remove Nautilus extension"
    ;;
esac