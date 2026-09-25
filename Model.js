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
  var dataSource = ""
  var fwActive = false
  var fwRules = 0
  var fwRuleList = []
  var seenRules = {}

  var exitNodeHost = ""
  var exitNodeIp = ""
  var exitNodeId = ""
  var wifiNetworks = []

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
    } else if (parts[0] === "net" && parts.length >= 6) {
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
      dataRx = sanitizeText(parts[1])
      dataTx = sanitizeText(parts[2])
      dataSource = sanitizeText(parts[3])
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
  root.wifiNetworks = wifiNetworks
  root.ssid = ssid
  root.netType = netType
  root.netIp = netIp
  root.signal = signal
  root.metered = metered
  root.gateway = gateway
  root.wifiRadio = wifiRadio
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
  root.dataSource = dataSource
  root.fwActive = fwActive
  root.fwRules = fwRules
  root.fwRuleList = fwRuleList
  root.statusFresh = true
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

function wifiSecurityIcon(security) {
  return isSecured(security) ? "󰌾" : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    sanitizeText: sanitizeText,
    sanitizeSsid: sanitizeSsid,
    parseStatus: parseStatus,
    typeLabel: typeLabel,
    osIcon: osIcon,
    signalIcon: signalIcon,
    barIcon: barIcon,
    formatBand: formatBand,
    isSecured: isSecured,
    wifiSecurityIcon: wifiSecurityIcon
  }
}