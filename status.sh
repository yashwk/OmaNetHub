#!/bin/bash

# Emits tab-separated status blocks for the Network Hub panel:
#   ts\t<up 0/1>\t<peersOnline>\t<selfHost>\t<selfIp>\t<selfOS>
#   peer\t<host>\t<ip>\t<os>\t<online 0/1>\t<curAddr>
#   net\t<ssid>\t<type>\t<ip>\t<signal%>\t<metered 0/1>\t<gateway>\t<wifiRadio 0/1>
#   data\t<rx>\t<tx>\t<source vnstat|proc>
#   fw\t<active 0/1>\t<ruleCount>
#   fwrule\t<action>\t<proto>\t<port>\t<src>\t<comment>

human() {
  awk -v b="$1" 'BEGIN {
    if (b < 1024) printf "%dB", b
    else if (b < 1048576) printf "%.1fKB", b / 1024
    else if (b < 1073741824) printf "%.1fMB", b / 1048576
    else printf "%.2fGB", b / 1073741824
  }'
}

decode_hex() {
  local hex="$1"
  if [[ -n "$hex" && "$hex" =~ ^[0-9a-fA-F]+$ ]]; then
    local escaped=$(echo "$hex" | sed 's/../\\x&/g')
    echo -e "$escaped"
  else
    echo "$hex"
  fi
}

# ---------- tailscale ----------
if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
  json=$(tailscale status --json 2>/dev/null)
  up=$(echo "$json" | jq -r 'if (.Self.Online // false) then 1 else 0 end')
  self_host=$(echo "$json" | jq -r '.Self.HostName // "localhost"')
  self_ip=$(echo "$json" | jq -r '.Self.TailscaleIPs[0] // ""')
  self_os=$(echo "$json" | jq -r '.Self.OS // "linux"')
  peers=$(echo "$json" | jq '[.Peer // [] | .[] | select(.Online == true)] | length')
  echo -e "ts\t$up\t$peers\t$self_host\t$self_ip\t$self_os"

  echo "$json" | jq -r '.Peer // [] | .[] | [(.HostName // ""), (.TailscaleIPs[0] // ""), (.OS // "linux"), (if .Online then "1" else "0" end), (.DNSName // "")] | @tsv' \
    | while IFS=$'\t' read -r host pip os online dnsname; do
        clean_dns="${dnsname%.}"
        echo -e "peer\t$host\t$pip\t$os\t$online\t$clean_dns"
      done
else
  echo -e "ts\t0\t0\tlocalhost\t\tlinux"
fi

# ---------- network ----------
active=$(nmcli -t -f DEVICE,STATE dev status 2>/dev/null | grep ":connected" | head -1 | cut -d: -f1)
ssid=""; type=""; ip=""; signal=""; metered=0; freq=""
if [ -n "$active" ]; then
  type=$(nmcli -t -f GENERAL.TYPE device show "$active" 2>/dev/null | cut -d: -f2)
  ip=$(nmcli -t -f IP4.ADDRESS device show "$active" 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1)
  nmcli -t -f GENERAL.METERED device show "$active" 2>/dev/null | grep -q "^GENERAL.METERED:yes" && metered=1
  if [ "$type" = "wifi" ]; then
    ssid=$(nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep "^yes:" | head -1 | cut -d: -f2)
    signal=$(nmcli -t -f ACTIVE,SIGNAL dev wifi 2>/dev/null | grep "^yes:" | head -1 | cut -d: -f2)
    freq=$(nmcli -t -f ACTIVE,FREQ dev wifi 2>/dev/null | grep "^yes:" | head -1 | cut -d: -f2)
  fi
fi

gateway=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
wifi_radio=0
[[ "$(nmcli radio wifi 2>/dev/null)" == "enabled" ]] && wifi_radio=1

echo -e "net\t$ssid\t$type\t$ip\t$signal\t$metered\t$gateway\t$wifi_radio\t$active\t$freq"

# ---------- network diagnostics (from omarchy-network-status) ----------
if command -v omarchy-network-status >/dev/null 2>&1; then
  net_verbose=$(omarchy-network-status --verbose 2>/dev/null)
  bitrate=$(echo "$net_verbose" | awk '$1=="bitrate"{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)
  router_ping=$(echo "$net_verbose" | awk '$1=="router_ping_ms"{print $2}')
  internet_ping=$(echo "$net_verbose" | awk '$1=="internet_ping_ms"{print $2}')
  signal_dbm=$(echo "$net_verbose" | awk '$1=="signal_dbm"{print $2}')
  echo -e "netdiag\t$bitrate\t$router_ping\t$internet_ping\t$signal_dbm"
fi

# ---------- network band & dns ----------
if command -v omarchy-network-band >/dev/null 2>&1; then
  band_out=$(omarchy-network-band 2>/dev/null)
  cur_band=$(echo "$band_out" | awk '$1=="band"{print $2}')
  sel_band=$(echo "$band_out" | awk '$1=="selected"{print $2}')
  avail_band=$(echo "$band_out" | awk '$1=="available"{print $2}')
  echo -e "netband\t$cur_band\t$sel_band\t$avail_band"
fi

if command -v omarchy-dns >/dev/null 2>&1; then
  cur_dns=$(omarchy-dns 2>/dev/null | head -1 | xargs)
  echo -e "netdns\t$cur_dns"
fi

# ---------- data usage ----------
if command -v vnstat >/dev/null 2>&1; then
  viface="${active:-$(vnstat --oneline 2>/dev/null | cut -d: -f1 | xargs)}"
  rx=$(vnstat -d 1 --json "$viface" 2>/dev/null | jq -r '((.interfaces[0].traffic.day[0] // {}) | .rx // 0)')
  tx=$(vnstat -d 1 --json "$viface" 2>/dev/null | jq -r '((.interfaces[0].traffic.day[0] // {}) | .tx // 0)')
  echo -e "data\t$(human "${rx:-0}")\t$(human "${tx:-0}")\tvnstat"

  # daily cap alert (cap file: bytes as integer)
  cap_file="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/link-data-cap"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
  if [ -f "$cap_file" ]; then
    cap=$(cat "$cap_file")
    case "$cap" in *[!0-9]*) cap=0 ;; esac
    if [ "$cap" -gt 0 ] && [ $((rx + tx)) -ge "$cap" ] && [ ! -f "$state_dir/link-cap-notified" ]; then
      mkdir -p "$state_dir"
      touch "$state_dir/link-cap-notified"
      omarchy notification send "Data cap reached" "$(human $((rx + tx))) used today" -u critical -g 󰇣
    elif [ $((rx + tx)) -lt "$cap" ] && [ -f "$state_dir/link-cap-notified" ]; then
      rm -f "$state_dir/link-cap-notified"
    fi
  fi
else
  rx=0; tx=0
  while read -r iface rest; do
    case "$iface" in wl*|enp*|eth*|wlan*)
      rx=$((rx + $(echo "$rest" | awk '{print $1}')))
      tx=$((tx + $(echo "$rest" | awk '{print $9}')))
      ;;
    esac
  done < <(tail -n +3 /proc/net/dev | sed 's/://')
  echo -e "data\t$(human "$rx")\t$(human "$tx")\tproc"
fi

# ---------- firewall ----------
active=$(systemctl is-active ufw 2>/dev/null)
[ "$active" = "active" ] && a=1 || a=0
rules=$(grep -c "^-A ufw-user-input" /etc/ufw/user.rules 2>/dev/null)
echo -e "fw\t$a\t${rules:-0}"

if [ -f /etc/ufw/user.rules ]; then
  awk '/^### tuple ###/ {
    action = $4;
    proto = $5;
    port = $6;
    src = $7;
    comment = "";
    for (i=8; i<=NF; i++) {
      if ($i ~ /^comment=/) {
        comment = substr($i, 9);
      }
    }
    print action "\t" proto "\t" port "\t" src "\t" comment
  }' /etc/ufw/user.rules 2>/dev/null | while IFS=$'\t' read -r action proto port src raw_comment; do
    comment=$(decode_hex "$raw_comment")
    echo -e "fwrule\t$action\t$proto\t$port\t$src\t$comment"
  done
fi