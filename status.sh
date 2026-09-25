#!/bin/bash
export PATH="/usr/bin:/bin"
export LC_ALL=C

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

strip_delims() {
  printf '%s' "$1" | tr -d '\r\n\t'
}

# ---------- tailscale ----------
if command -v tailscale >/dev/null 2>&1 && timeout 3 tailscale status >/dev/null 2>&1; then
  json=$(timeout 3 tailscale status --json 2>/dev/null | head -c 131072)
  ts_out=$(echo "$json" | jq -r '
    (.Self // {}) as $self |
    (if ($self.Online // false) then "1" else "0" end) as $up |
    ($self.HostName // "localhost" | gsub("[\r\n\t]"; "")) as $shost |
    ($self.TailscaleIPs[0] // "" | gsub("[\r\n\t]"; "")) as $sip |
    ($self.OS // "linux" | gsub("[\r\n\t]"; "")) as $sos |
    ([.Peer // {} | to_entries[] | select(.value.Online == true)] | length) as $online_count |
    "ts\t\($up)\t\($online_count)\t\($shost)\t\($sip)\t\($sos)",

    (.ExitNodeStatus // null) as $ens |
    (if $ens != null and (($ens.ID // "") != "" or ($ens.TailscaleIPs // []) != []) then
      ([.Peer // {} | to_entries[] | .value | select((.ID != null and .ID == $ens.ID) or .ExitNode == true) | .HostName][0] // ((($ens.TailscaleIPs[0] // "Exit Node") | split("/")[0])))
    else "" end | gsub("[\r\n\t]"; "")) as $ehost |
    (if $ens != null and ($ens.TailscaleIPs // []) != [] then ($ens.TailscaleIPs[0] | split("/")[0]) else "" end | gsub("[\r\n\t]"; "")) as $eip |
    ($ens.ID // "" | gsub("[\r\n\t]"; "")) as $eid |
    "exitnode\t\($ehost)\t\($eip)\t\($eid)",

    ([.Peer // {} | to_entries[] | .value] | sort_by((((.ExitNode // false) or ($ens != null and $ens.ID != null and $ens.ID != "" and .ID == $ens.ID)) | not), (.Online // false | not)) | .[0:50] | .[] |
      "peer\t\(.HostName // "" | gsub("[\r\n\t]"; ""))\t\(.TailscaleIPs[0] // "" | gsub("[\r\n\t]"; ""))\t\(.OS // "linux" | gsub("[\r\n\t]"; ""))\t\(if .Online then "1" else "0" end)\t\((.DNSName // "") | sub("\\.$"; "") | gsub("[\r\n\t]"; ""))\t\(if (.ExitNode == true or ($ens != null and $ens.ID != null and $ens.ID != "" and .ID == $ens.ID)) then "1" else "0" end)\t\(if .ExitNodeOption then "1" else "0" end)")
  ' 2>/dev/null)
  if [ -n "$ts_out" ]; then
    printf '%s\n' "$ts_out"
  else
    printf 'ts\t0\t0\tlocalhost\t\tlinux\n'
    printf 'exitnode\t\t\t\n'
  fi
else
  printf 'ts\t0\t0\tlocalhost\t\tlinux\n'
  printf 'exitnode\t\t\t\n'
fi

# ---------- network ----------
dev_status=$(timeout 2 nmcli -t -f DEVICE,TYPE,STATE dev status 2>/dev/null)
active=$(echo "$dev_status" | awk -F: '$3 ~ /^connected/ && ($2=="wifi" || $2=="ethernet") {print $1; exit}')
[ -z "$active" ] && active=$(echo "$dev_status" | awk -F: '$3 ~ /^connected/ && $2 != "loopback" {print $1; exit}')
ssid=""; type=""; ip=""; signal=""; metered=0; freq=""
if [ -n "$active" ]; then
  type=$(timeout 2 nmcli -t -f GENERAL.TYPE device show "$active" 2>/dev/null | head -n 1 | cut -d: -f2 | head -c 32)
  ip=$(timeout 2 nmcli -t -f IP4.ADDRESS device show "$active" 2>/dev/null | head -n 1 | cut -d: -f2 | cut -d/ -f1 | head -c 64)
  timeout 2 nmcli -t -f GENERAL.METERED device show "$active" 2>/dev/null | grep -q "^GENERAL.METERED:yes" && metered=1
  if [ "$type" = "wifi" ]; then
    ssid=$(timeout 2 nmcli -t -f ACTIVE,SSID dev wifi 2>/dev/null | grep "^yes:" | head -n 1 | sed 's/^yes://' | sed 's/\\:/:/g' | head -c 128)
    ssid=$(strip_delims "$ssid")
    signal=$(timeout 2 nmcli -t -f ACTIVE,SIGNAL dev wifi 2>/dev/null | grep "^yes:" | head -n 1 | cut -d: -f2 | head -c 16)
    freq=$(timeout 2 nmcli -t -f ACTIVE,FREQ dev wifi 2>/dev/null | grep "^yes:" | head -n 1 | cut -d: -f2 | head -c 32)
  fi
fi

gateway=$(timeout 2 ip route show default 2>/dev/null | awk '{print $3}' | head -n 1 | head -c 64)
wifi_radio=0
[[ "$(timeout 2 nmcli radio wifi 2>/dev/null)" == "enabled" ]] && wifi_radio=1

printf 'net\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ssid" "$(strip_delims "$type")" "$(strip_delims "$ip")" "$signal" "$metered" "$(strip_delims "$gateway")" "$wifi_radio" "$(strip_delims "$active")" "$(strip_delims "$freq")"

# ---------- wifi scan (when wifi radio is enabled and disconnected) ----------
if [ "$wifi_radio" -eq 1 ] && [ -z "$ssid" ]; then
  uuids=$(timeout 2 nmcli -t -f UUID,TYPE connection show 2>/dev/null | awk -F: '$2 ~ /^(802-11-wireless|wifi)$/ {print $1}')
  saved_ssids=""
  if [ -n "$uuids" ]; then
    saved_ssids=$(timeout 2 nmcli -g 802-11-wireless.ssid connection show $uuids 2>/dev/null | sed '/^$/d')
  fi
  saved_names=$(timeout 2 nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '
    $NF ~ /^(802-11-wireless|wifi)$/ {
      name = $1
      for (i = 2; i < NF; i++) {
        name = name ":" $i
      }
      gsub(/\\:/, ":", name)
      print name
    }
  ')
  saved=$(printf '%s\n%s\n' "$saved_ssids" "$saved_names")
  timeout 4 nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list 2>/dev/null | awk -F: -v saved="$saved" -v cur_ssid="$ssid" '
  BEGIN {
    split(saved, s_arr, "\n")
    for (i in s_arr) {
      if (s_arr[i] != "") known_map[s_arr[i]] = 1
    }
  }
  {
    in_use = ($1 ~ /\*/) ? 1 : 0
    if (NF < 4) next
    sec = $NF
    sig = $(NF-1) + 0
    ssid = $2
    for (i = 3; i <= NF - 2; i++) {
      ssid = ssid ":" $i
    }
    gsub(/\\:/, ":", ssid)
    gsub(/[\r\n\t]/, "", ssid)
    gsub(/[\r\n\t]/, "", sec)
    if (ssid == "" || ssid == "--") next
    if (!(ssid in max_sig) || sig > max_sig[ssid]) {
      max_sig[ssid] = sig
      sec_map[ssid] = sec
    }
    if (in_use == 1 || (cur_ssid != "" && ssid == cur_ssid)) {
      in_use_map[ssid] = 1
    }
  }
  END {
    for (s in max_sig) {
      k = (s in known_map) ? 1 : 0
      u = (s in in_use_map) ? in_use_map[s] : 0
      print s "\t" max_sig[s] "\t" sec_map[s] "\t" k "\t" u
    }
  }' | sort -t$'\t' -k5,5nr -k4,4nr -k2,2nr | head -n 40 | awk -F'\t' '{
    gsub(/[\r\n\t]/, "", $1)
    gsub(/[\r\n\t]/, "", $3)
    printf "wifinet\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5
  }'
fi

# ---------- network diagnostics (from omarchy-network-status) ----------
if command -v omarchy-network-status >/dev/null 2>&1; then
  net_verbose=$(timeout 3 omarchy-network-status --verbose 2>/dev/null | head -c 4096)
  bitrate=$(echo "$net_verbose" | awk '$1=="bitrate"{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | xargs)
  router_ping=$(echo "$net_verbose" | awk '$1=="router_ping_ms"{print $2}')
  internet_ping=$(echo "$net_verbose" | awk '$1=="internet_ping_ms"{print $2}')
  signal_dbm=$(echo "$net_verbose" | awk '$1=="signal_dbm"{print $2}')
  printf 'netdiag\t%s\t%s\t%s\t%s\n' "$(strip_delims "$bitrate")" "$(strip_delims "$router_ping")" "$(strip_delims "$internet_ping")" "$(strip_delims "$signal_dbm")"
fi

# ---------- network band & dns ----------
if command -v omarchy-network-band >/dev/null 2>&1; then
  band_out=$(timeout 2 omarchy-network-band 2>/dev/null | head -c 2048)
  cur_band=$(echo "$band_out" | awk '$1=="band"{print $2}')
  sel_band=$(echo "$band_out" | awk '$1=="selected"{print $2}')
  avail_band=$(echo "$band_out" | awk '$1=="available"{print $2}')
  printf 'netband\t%s\t%s\t%s\n' "$(strip_delims "$cur_band")" "$(strip_delims "$sel_band")" "$(strip_delims "$avail_band")"
fi

if command -v omarchy-dns >/dev/null 2>&1; then
  cur_dns=$(timeout 2 omarchy-dns 2>/dev/null | head -n 1 | head -c 256 | xargs)
  printf 'netdns\t%s\n' "$(strip_delims "$cur_dns")"
fi

# ---------- data usage ----------
if command -v vnstat >/dev/null 2>&1; then
  viface="${active:-$(timeout 2 ip route show default 2>/dev/null | awk '{print $5}' | head -n 1 | head -c 64)}"
  viface="${viface:-$(timeout 3 vnstat --oneline 2>/dev/null | head -n 1 | cut -d\; -f2 | head -c 64 | xargs)}"
  vn_cmd=(vnstat -d 1 --json)
  [ -n "$viface" ] && vn_cmd+=( -i "$viface" )
  vn_json=$("${vn_cmd[@]}" 2>/dev/null | head -c 1048576)
  rx=$(echo "$vn_json" | jq -r '((.interfaces[0].traffic.day[-1] // {}) | .rx // 0)' 2>/dev/null)
  tx=$(echo "$vn_json" | jq -r '((.interfaces[0].traffic.day[-1] // {}) | .tx // 0)' 2>/dev/null)
  case "$rx" in ''|*[!0-9]*) rx=0 ;; esac
  case "$tx" in ''|*[!0-9]*) tx=0 ;; esac
  printf 'data\t%s\t%s\tvnstat\n' "$(human "${rx:-0}")" "$(human "${tx:-0}")"

  # daily cap alert (cap file: bytes as integer)
  cap_file="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/link-data-cap"
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
  if [ -f "$cap_file" ]; then
    cap=$(head -c 32 "$cap_file" 2>/dev/null)
    case "$cap" in *[!0-9]*) cap=0 ;; esac
    if [ "$cap" -gt 0 ] && [ $((rx + tx)) -ge "$cap" ] && [ ! -f "$state_dir/link-cap-notified" ]; then
      mkdir -p "$state_dir"
      touch "$state_dir/link-cap-notified"
      omarchy notification send -u critical -g 󰌗 "Data cap reached" "$(human $((rx + tx))) used today"
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
  done < <(tail -n +3 /proc/net/dev 2>/dev/null | sed 's/://')
  printf 'data\t%s\t%s\tproc\n' "$(human "$rx")" "$(human "$tx")"
fi

# ---------- firewall ----------
fw_state=$(timeout 3 systemctl is-active ufw 2>/dev/null)
[ "$fw_state" = "active" ] && a=1 || a=0
rules=$(grep -c "^-A ufw-user-input" /etc/ufw/user.rules 2>/dev/null)
printf 'fw\t%s\t%s\n' "$a" "${rules:-0}"

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
  }' /etc/ufw/user.rules 2>/dev/null | head -n 50 | while IFS=$'\t' read -r action proto port src raw_comment; do
    comment=$(decode_hex "$raw_comment")
    clean_comment=$(strip_delims "$comment")
    printf 'fwrule\t%s\t%s\t%s\t%s\t%s\n' "$(strip_delims "$action")" "$(strip_delims "$proto")" "$(strip_delims "$port")" "$(strip_delims "$src")" "$clean_comment"
  done
fi