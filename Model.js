function sanitizeText(str) {
  if (str === null || str === undefined) return ""
  return String(str)
    .replace(/<[^>]*>/g, "")                      // Strip all HTML tags
    .replace(/[<>&"']/g, "")                      // Strip markup delimiters
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, "") // Strip ASCII control characters
    .replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/g, "") // Strip zero-width & bidi format characters
    .trim()
    .substring(0, 256)                            // Bound field length for layout safety
}

function sanitizeSsid(str) {
  if (str === null || str === undefined) return ""
  return String(str)
    .replace(/\x1B\[[0-9;]*[a-zA-Z]/g, "")        // Strip ANSI escape codes
    .replace(/[\u0000-\u001F\u007F-\u009F]/g, "") // Strip ASCII control characters
    .replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u2064\uFEFF]/g, "") // Strip zero-width & bidi format characters
    .trim()
    .substring(0, 128)                            // Bound field length for layout safety
}

// Builds the single Wi-Fi list shown in the panel: saved profiles first
// (active one on top, then strongest signal), followed by unsaved scans
// strongest first. A saved profile absorbs the matching scan so its row keeps
// live signal/security data instead of appearing twice.
function mergeWifiList(scanned, saved) {
  var out = []
  var bySsid = {}

  for (var i = 0; i < scanned.length; i++) {
    var s = scanned[i]
    if (bySsid[s.ssid]) continue
    bySsid[s.ssid] = s
  }

  var savedNames = {}
  for (var j = 0; j < saved.length; j++) {
    var p = saved[j]
    var hit = bySsid[p.ssid]
    // Keep the active connection listed even if the scan was stale or failed,
    // so the row you are connected through never disappears.
    if (!hit && !p.active) continue
    savedNames[p.ssid] = true
    out.push({
      ssid: p.ssid,
      name: p.name,
      signal: hit ? hit.signal : -1,
      security: hit ? hit.security : "",
      known: true,
      inUse: p.active || (hit ? hit.inUse : false),
      active: p.active,
      saved: true,
      reachable: !!hit
    })
  }

  // Active connection first, then saved entries by signal, then the rest.
  for (var k = 0; k < scanned.length; k++) {
    var n = scanned[k]
    if (savedNames[n.ssid]) continue
    out.push({
      ssid: n.ssid,
      name: n.ssid,
      signal: n.signal,
      security: n.security,
      known: false,
      inUse: n.inUse,
      active: n.inUse,
      saved: false,
      reachable: true
    })
  }

  out.sort(function(a, b) {
    if (a.active !== b.active) return a.active ? -1 : 1
    if (a.saved !== b.saved) return a.saved ? -1 : 1
    return (b.signal || 0) - (a.signal || 0)
  })

  return out.slice(0, 60)
}

function parseStatus(text, root) {
  var tailscaleUp = false
  var tailscalePeers = 0
  var selfHost = "localhost"
  var selfIp = ""
  var selfOS = "linux"
  var peers = []
  var ssid = ""
  var netType = ""
  var netIp = ""
  var signal = -1
  var metered = false
  var gateway = ""
  var wifiRadio = true
  var netIface = ""
  var netFreq = ""
  var netBitrate = ""
  var routerPing = ""
  var internetPing = ""
  var signalDbm = ""
  var bandCurrent = ""
  var bandSelected = ""
  var bandAvailable = ""
  var dnsCurrent = ""
  var dataRx = ""
  var dataTx = ""
  var dataTodayRx = ""
  var dataTodayTx = ""
  var dataIface = ""
  var dataSource = ""
  var fwActive = false
  var fwRules = 0
  var fwRuleList = []
  var seenRules = {}

  var exitNodeHost = ""
  var exitNodeIp = ""
  var exitNodeId = ""
  var wifiNetworks = []
  var savedProfiles = []
  var sawNetLine = false

  var safeText = String(text || "").substring(0, 32768)
  var lines = safeText.split("\n").slice(0, 200)
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts[0] === "ts" && parts.length >= 4) {
      tailscaleUp = parts[1] === "1"
      tailscalePeers = Math.max(0, Math.min(parseInt(parts[2], 10) || 0, 9999))
      selfHost = sanitizeText(parts[3] || "localhost")
      if (parts.length >= 5) selfIp = sanitizeText(parts[4])
      if (parts.length >= 6) selfOS = sanitizeText(parts[5])
    } else if (parts[0] === "exitnode" && parts.length >= 2) {
      exitNodeHost = sanitizeText(parts[1] || "")
      if (parts.length >= 3) exitNodeIp = sanitizeText(parts[2] || "")
      if (parts.length >= 4) exitNodeId = sanitizeText(parts[3] || "")
    } else if (parts[0] === "peer" && parts.length >= 4) {
      var pHName = sanitizeText(parts[1])
      var pPip = sanitizeText(parts[2])
      var pOs = (parts.length >= 4 && parts[3]) ? sanitizeText(parts[3].toLowerCase()) : "linux"
      var pOnline = (parts.length >= 5) ? (parts[4] === "1" || parts[4] === "true") : true
      var pDns = (parts.length >= 6) ? sanitizeText(parts[5]) : ""
      var pExitNode = (parts.length >= 7) ? (parts[6] === "1" || parts[6] === "true") : false
      var pExitNodeOption = (parts.length >= 8) ? (parts[7] === "1" || parts[7] === "true") : false
      if (peers.length < 50) {
        peers.push({
          host: pHName,
          ip: pPip,
          os: pOs,
          online: pOnline,
          dnsName: pDns,
          exitNode: pExitNode,
          exitNodeOption: pExitNodeOption,
          target: pDns !== "" ? pDns : (pPip !== "" ? pPip : pHName)
        })
      }
    } else if (parts[0] === "wifinet" && parts.length >= 3) {
      var wSsid = sanitizeSsid(parts[1])
      var wSig = parseInt(parts[2], 10)
      var wSec = (parts.length >= 4) ? sanitizeText(parts[3]) : ""
      var wKnown = (parts.length >= 5) ? (parts[4] === "1" || parts[4] === "true") : false
      var wInUse = (parts.length >= 6) ? (parts[5] === "1" || parts[5] === "true") : false
      if (wSsid !== "" && wifiNetworks.length < 50) {
        wifiNetworks.push({
          ssid: wSsid,
          signal: isNaN(wSig) ? 0 : Math.min(100, Math.max(0, wSig)),
          security: wSec,
          known: wKnown,
          inUse: wInUse
        })
      }
    } else if (parts[0] === "wifsaved" && parts.length >= 3) {
      var pName = sanitizeText(parts[1])
      var pSsid = sanitizeSsid(parts[2])
      var pActive = parts.length >= 4 ? parts[3] === "1" : false
      if (pName !== "" && savedProfiles.length < 50) {
        savedProfiles.push({ name: pName, ssid: pSsid !== "" ? pSsid : pName, active: pActive })
      }
    } else if (parts[0] === "net" && parts.length >= 6) {
      sawNetLine = true
      ssid = sanitizeSsid(parts[1])
      netType = sanitizeText(parts[2])
      netIp = sanitizeText(parts[3])
      var sigParsed = parseInt(parts[4], 10)
      signal = isNaN(sigParsed) ? -1 : Math.min(100, Math.max(0, sigParsed))
      metered = parts[5] === "1"
      if (parts.length >= 7) gateway = sanitizeText(parts[6])
      if (parts.length >= 8) wifiRadio = parts[7] === "1"
      if (parts.length >= 9) netIface = sanitizeText(parts[8])
      if (parts.length >= 10) netFreq = sanitizeText(parts[9])
    } else if (parts[0] === "netdiag" && parts.length >= 2) {
      netBitrate = sanitizeText(parts[1] || "")
      if (parts.length >= 3) routerPing = sanitizeText(parts[2] || "")
      if (parts.length >= 4) internetPing = sanitizeText(parts[3] || "")
      if (parts.length >= 5) signalDbm = sanitizeText(parts[4] || "")
    } else if (parts[0] === "netband" && parts.length >= 2) {
      bandCurrent = sanitizeText(parts[1] || "")
      if (parts.length >= 3) bandSelected = sanitizeText(parts[2] || "")
      if (parts.length >= 4) bandAvailable = sanitizeText(parts[3] || "")
    } else if (parts[0] === "netdns" && parts.length >= 2) {
      dnsCurrent = sanitizeText(parts[1] || "")
    } else if (parts[0] === "data" && parts.length >= 4) {
      // data <sessionRx> <sessionTx> <todayRx> <todayTx> <iface>
      // Session counters come from /sys/class/net (since boot, matches btop);
      // today is vnstat's daily total. Either pair may be blank.
      dataRx = sanitizeText(parts[1])
      dataTx = sanitizeText(parts[2])
      dataTodayRx = (parts.length >= 5) ? sanitizeText(parts[3]) : ""
      dataTodayTx = (parts.length >= 6) ? sanitizeText(parts[4]) : ""
      dataIface = (parts.length >= 6) ? sanitizeText(parts[5]) : ""
      dataSource = dataTodayRx !== "" ? "both" : "session"
    } else if (parts[0] === "fw" && parts.length >= 3) {
      fwActive = parts[1] === "1"
      fwRules = Math.max(0, Math.min(parseInt(parts[2], 10) || 0, 9999))
    } else if (parts[0] === "fwrule" && parts.length >= 4) {
      var action = sanitizeText(parts[1])
      var proto = sanitizeText(parts[2])
      var port = sanitizeText(parts[3])
      var src = (parts.length >= 5) ? sanitizeText(parts[4]) : ""
      var comment = (parts.length >= 6) ? sanitizeText(parts[5]) : ""
      var ruleKey = port + "/" + proto + ":" + src + ":" + comment
      if (!seenRules[ruleKey] && port && port !== "any" && fwRuleList.length < 50) {
        seenRules[ruleKey] = true
        fwRuleList.push({
          action: action,
          proto: proto.toUpperCase(),
          port: port,
          src: src === "0.0.0.0/0" ? "Anywhere" : src,
          comment: comment
        })
      }
    }
  }

  root.tailscaleUp = tailscaleUp
  root.tailscalePeers = tailscalePeers
  root.selfHost = selfHost
  root.selfIp = selfIp
  root.selfOS = selfOS
  root.exitNodeHost = exitNodeHost
  root.exitNodeIp = exitNodeIp
  root.exitNodeId = exitNodeId
  root.peers = peers
  // The panel derives `wifiNetworks` from the native Networking service and
  // uses these polled rows only for security type and as a fallback.
  root.polledNetworks = mergeWifiList(wifiNetworks, savedProfiles)
  root.savedProfiles = savedProfiles
  // Connection identity now comes from the native Networking service, so the
  // polled values are only retained as fallbacks for the details it cannot
  // report. Never overwrite the live bindings: assigning to a readonly
  // property is a QML error.
  if (sawNetLine) {
    root.polledSsid = ssid
    root.polledIp = netIp
    root.signalFallback = signal
    root.metered = metered
    root.gateway = gateway
  }
  root.netIface = netIface
  root.netFreq = netFreq
  root.netBitrate = netBitrate
  root.routerPing = routerPing
  root.internetPing = internetPing
  root.signalDbm = signalDbm
  root.bandCurrent = bandCurrent
  root.bandSelected = bandSelected
  root.bandAvailable = bandAvailable
  root.dnsCurrent = dnsCurrent
  root.dataRx = dataRx
  root.dataTx = dataTx
  root.dataTodayRx = dataTodayRx
  root.dataTodayTx = dataTodayTx
  root.dataIface = dataIface
  root.dataSource = dataSource
  root.fwActive = fwActive
  root.fwRules = fwRules
  root.fwRuleList = fwRuleList
  root.statusFresh = true
  root.statusAt = Date.now()
}

function typeLabel(type) {
  if (type === "wifi") return "Wi-Fi"
  if (type === "ethernet") return "Ethernet"
  return type === "" ? "Offline" : type
}

function osIcon(os) {
  var s = String(os || "").toLowerCase()
  if (s.indexOf("android") !== -1) return "󰀲"
  if (s.indexOf("linux") !== -1 || s.indexOf("arch") !== -1) return "󰌽"
  if (s.indexOf("darwin") !== -1 || s.indexOf("macos") !== -1 || s.indexOf("ios") !== -1 || s.indexOf("apple") !== -1) return "󰀵"
  if (s.indexOf("windows") !== -1) return "󰖳"
  return "󰾰"
}

function signalIcon(signal, type) {
  if (type === "ethernet") return "󰈀"
  if (signal < 0) return "󰤮"
  if (signal >= 75) return "󰤨"
  if (signal >= 50) return "󰤥"
  if (signal >= 25) return "󰤢"
  return "󰤟"
}

function barIcon(signal, netType, tailscaleUp) {
  if (netType === "ethernet") return "󰈀"
  if (netType === "wifi") {
    if (signal < 0) return "󰤮"
    if (signal >= 75) return "󰤨"
    if (signal >= 50) return "󰤥"
    if (signal >= 25) return "󰤢"
    return "󰤟"
  }
  if (tailscaleUp) return "󰖂"
  return "󰤮"
}

function formatBand(freq, iface) {
  var parts = []
  if (iface) parts.push(iface)
  var n = parseInt(freq, 10)
  if (!isNaN(n) && n > 0) {
    if (n >= 5000) parts.push("5 GHz")
    else if (n >= 2400) parts.push("2.4 GHz")
    else parts.push(n + " MHz")
  }
  return parts.length > 0 ? parts.join(" · ") : "Connected"
}

function isSecured(security) {
  var s = String(security || "").trim().toLowerCase()
  return s !== "" && s !== "--" && s !== "none"
}

// True when a connection failure looks like a rejected/absent passphrase
// rather than, say, a DHCP or out-of-range problem. NetworkManager reports a
// failed WPA 4-way handshake as "Secrets were required, but not provided", so
// that phrasing covers both a changed password and a locked keyring.
function isWifiAuthError(message) {
  var s = String(message || "").toLowerCase()
  if (s === "") return false
  return s.indexOf("secrets were required") !== -1
    || s.indexOf("no secrets") !== -1
    || s.indexOf("psk") !== -1
    || s.indexOf("pre-shared key") !== -1
    || s.indexOf("handshake") !== -1
    || s.indexOf("4-way") !== -1
    || s.indexOf("wrong password") !== -1
    || s.indexOf("invalid password") !== -1
    || s.indexOf("authentication") !== -1
}

function wifiSecurityIcon(security) {
  return isSecured(security) ? "󰌾" : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    sanitizeText: sanitizeText,
    sanitizeSsid: sanitizeSsid,
    parseStatus: parseStatus,
    mergeWifiList: mergeWifiList,
    typeLabel: typeLabel,
    osIcon: osIcon,
    signalIcon: signalIcon,
    barIcon: barIcon,
    formatBand: formatBand,
    isSecured: isSecured,
    isWifiAuthError: isWifiAuthError,
    wifiSecurityIcon: wifiSecurityIcon
  }
}