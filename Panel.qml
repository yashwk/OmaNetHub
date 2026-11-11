import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Networking
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "yashwanth.link"
  ipcTarget: "yashwanth.link"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimColor: Qt.darker(foreground, 1.4)
  readonly property string scriptDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/yashwanth.link"

  // Active view tab: "tailnet" | "network" | "firewall"
  property string currentTab: "network"

  // ---------- native network state (Quickshell.Networking) ----------
  // Connection state comes from NetworkManager over D-Bus, not from parsing
  // nmcli output. This is signal-driven, so there is no poll that can miss, no
  // partial read that looks like a disconnect, and no flicker. status.sh is
  // still used for details Networking does not expose (frequency, bitrate,
  // latency, tailscale, firewall).
  readonly property bool nmAvailable: Networking.backend === NetworkBackendType.NetworkManager
  readonly property var netDevices: Networking.devices ? Networking.devices.values : []

  function findNetDevice(type) {
    var devices = netDevices || []
    var fallback = null
    for (var i = 0; i < devices.length; i++) {
      var d = devices[i]
      if (!d || d.type !== type) continue
      if (d.connected) return d
      if (!fallback) fallback = d
    }
    return fallback
  }

  readonly property var wifiDev: findNetDevice(DeviceType.Wifi)
  readonly property var wiredDev: findNetDevice(DeviceType.Wired)
  readonly property var wifiNetworkObjects: wifiDev && wifiDev.networks ? wifiDev.networks.values : []

  // NetworkManager only fills the device's network list while scanning is
  // enabled, and the flag lives on the shared device (one instance per
  // monitor), so track which device this widget turned it on for and always
  // turn it back off when the panel closes or the widget dies.
  property var scannerDev: null
  function setScanner(enabled) {
    var target = root.opened ? root.wifiDev : null
    if (scannerDev && scannerDev !== target) scannerDev.scannerEnabled = false
    scannerDev = target
    if (scannerDev) scannerDev.scannerEnabled = enabled
  }

  function findConnectedWifi() {
    var nets = wifiNetworkObjects || []
    for (var i = 0; i < nets.length; i++) {
      if (nets[i] && nets[i].connected) return nets[i]
    }
    return null
  }
  readonly property var connectedWifi: findConnectedWifi()

  // Which link is actually carrying traffic. Wired wins when both are up,
  // matching the default route. Note this is only wifi/ethernet — VPN and
  // bridge devices are deliberately excluded, which is what used to make a
  // disconnected Wi-Fi box report "tailscale0" as its active connection.
  readonly property string liveKind: {
    if (wiredDev && wiredDev.connected) return "ethernet"
    if (connectedWifi) return "wifi"
    // NetworkManager can omit the active profile from a device's network list
    // for a moment (OWE transition networks, or mid-roam). Trust the device.
    if (wifiDev && wifiDev.connected) return "wifi"
    return ""
  }
  readonly property var liveDevice: liveKind === "ethernet" ? wiredDev : (liveKind === "wifi" ? wifiDev : null)
  readonly property bool wifiRadio: nmAvailable ? Networking.wifiEnabled : true

  // Signal strength 0-100 from the live network object; -1 when unknown.
  readonly property int signal: {
    if (liveKind !== "wifi") return -1
    if (connectedWifi && connectedWifi.signalStrength >= 0) {
      return Math.round(connectedWifi.signalStrength * 100)
    }
    // Fall back to the last polled value rather than dropping to "no signal".
    return signalFallback
  }
  property int signalFallback: -1

  // ---------- live status ----------
  property bool tailscaleUp: false
  property int tailscalePeers: 0
  property string selfHost: "localhost"
  property string selfIp: ""
  property string selfOS: "linux"
  property var peers: []
  property string ssid: connectedWifi ? (connectedWifi.name || "") : polledSsid
  property string polledSsid: ""
  property string netType: liveKind === "wifi" ? "wifi" : (liveKind === "ethernet" ? "ethernet" : "")
  // Networking's `address` is the device's hardware address (MAC), not its IP,
  // so the IPv4 stays sourced from the polled `omarchy-network-status` value.
  property string netIp: polledIp
  property string polledIp: ""
  property bool metered: false
  property string gateway: ""
  property string netIface: liveDevice ? liveDevice.name : ""
  property string netFreq: ""
  property string netBitrate: ""
  property string routerPing: ""
  property string internetPing: ""
  property string signalDbm: ""
  property string bandCurrent: ""
  property string bandSelected: ""
  property string bandAvailable: ""
  property string dnsCurrent: ""
  property string dataRx: ""
  property string dataTx: ""
  property string dataTodayRx: ""
  property string dataTodayTx: ""
  property string dataIface: ""
  property string dataSource: ""
  property bool fwActive: false
  property int fwRules: 0
  property var fwRuleList: []
  property bool statusFresh: false
  // Wall-clock time of the last completed status.sh read, used to skip a
  // redundant poll when the panel is reopened right after one.
  property double statusAt: 0

  property string exitNodeHost: ""
  property string exitNodeIp: ""
  property string exitNodeId: ""
  // Native network objects: authoritative for known/saved state and signal,
  // no polling and no stale badges. `status.sh` scan data is used only for
  // security type, which the Networking API does not expose.
  readonly property var wifiNetworks: {
    if (!nmAvailable) return polledNetworks
    var out = []
    var bySsid = {}
    var nets = wifiNetworkObjects || []
    for (var i = 0; i < nets.length; i++) {
      var n = nets[i]
      if (!n || !n.name) continue
      if (bySsid[n.name]) continue
      bySsid[n.name] = true
      out.push({
        ssid: n.name,
        name: n.name,
        signal: n.signalStrength >= 0 ? Math.round(n.signalStrength * 100) : -1,
        security: securityForSsid(n.name),
        known: !!n.known,
        saved: !!n.known,
        inUse: !!n.connected,
        active: !!n.connected,
        reachable: true
      })
    }
    if (out.length === 0) return polledNetworks
    out.sort(function(a, b) {
      if (a.active !== b.active) return a.active ? -1 : 1
      if (a.saved !== b.saved) return a.saved ? -1 : 1
      return (b.signal || 0) - (a.signal || 0)
    })
    return out
  }
  property var polledNetworks: []
  function securityForSsid(ssid) {
    for (var i = 0; i < polledNetworks.length; i++) {
      if (polledNetworks[i].ssid === ssid) return polledNetworks[i].security || ""
    }
    return ""
  }
  property var savedProfiles: []

  // Wi-Fi inline password and action state
  property string wifiPasswordSsid: ""
  property string wifiPasswordText: ""
  property string wifiActionSsid: ""
  property string wifiActionKind: ""
  property string wifiErrorSsid: ""
  property string wifiErrorMsg: ""
  property bool wifiErrorNeedsPassword: false
  property string wifiForgetSsid: ""
  property string _actionStderrText: ""
  property string _actionStdoutText: ""

  readonly property bool haveTailscale: tailscaleUp || tailscalePeers > 0 || selfIp !== ""
  readonly property bool haveFirewall: fwActive || fwRules > 0
  readonly property string barText: Model.barIcon(signal, netType, tailscaleUp)

  // ---------- input fields ----------
  property string fwNewPort: ""
  property string fwNewProto: "tcp"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  // Opening used to spawn a full status.sh run (~0.5s of forking nmcli) on
  // every click, even when the last reading was a second old. The card is
  // already up by then, but the burst competes with the first paint. Reuse a
  // recent reading; the 5s open-time poll refreshes it soon enough.
  function refreshIfStale() {
    if (root.statusAt && Date.now() - root.statusAt < 2000) return
    refresh()
  }

  function runAction(args) {
    if (actionProc.running) return
    root._actionStderrText = ""
    root._actionStdoutText = ""
    actionProc.command = [root.scriptDir + "/action.sh"].concat(args)
    actionProc.running = true
  }

  function connectWifi(ssid, password, security) {
    if (!ssid || root.wifiActionSsid !== "" || actionProc.running) return
    root.wifiActionSsid = ssid
    root.wifiActionKind = "connect"
    root.wifiErrorSsid = ""
    root.wifiErrorMsg = ""
    root.wifiErrorNeedsPassword = false
    actionProc.stdinSecret = (password !== undefined && password !== null && password !== "") ? password : ""
    if (actionProc.stdinSecret !== "") {
      root.runAction(["wifi-connect", ssid, "--stdin", security || ""])
    } else {
      root.runAction(["wifi-connect", ssid])
    }
  }

  function openWifiPassword(ssid) {
    root.wifiPasswordSsid = ssid
    root.wifiPasswordText = ""
  }

  // Forget is destructive and the profile may be in use, so ask first.
  function requestForgetWifi(ssid) {
    if (!ssid || root.wifiActionSsid !== "" || actionProc.running) return
    root.cancelWifiPassword()
    root.wifiForgetSsid = ssid
  }

  function cancelForgetWifi() {
    root.wifiForgetSsid = ""
    Qt.callLater(function() { if (root.opened && keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function confirmForgetWifi() {
    var ssid = root.wifiForgetSsid
    root.wifiForgetSsid = ""
    if (!ssid) return
    root.wifiActionSsid = ssid
    root.wifiActionKind = "forget"
    root.wifiErrorSsid = ""
    root.wifiErrorMsg = ""
    root.runAction(["wifi-forget", ssid])
  }

  function cancelWifiPassword() {
    actionProc.stdinSecret = ""
    root.wifiPasswordSsid = ""
    root.wifiPasswordText = ""
    if (root.wifiErrorNeedsPassword) {
      root.wifiErrorSsid = ""
      root.wifiErrorMsg = ""
    }
    root.wifiErrorNeedsPassword = false
    Qt.callLater(function() { if (root.opened && keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function rescanWifi() {
    if (actionProc.running || root.wifiActionSsid !== "") return
    root.runAction(["wifi-rescan"])
    root.refresh()
  }

  function copyToClipboard(value, label) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
    omarchyNotify(label + " copied to clipboard")
  }

  function sendPeerFile(peer, files) {
    if (!peer) return
    var target = peer.target || peer.host || peer.ip
    if (!target) return
    var cmd = [root.scriptDir + "/bin/taildrop-direct-send", target]
    if (files && files.length > 0) cmd = cmd.concat(files)
    Quickshell.execDetached(cmd)
    root.close()
  }

  function summonSpeedTest() {
    root.close()
    if (root.bar && root.bar.shell) {
      root.bar.shell.summon("omarchy.speedtest")
    } else {
      Quickshell.execDetached(["omarchy-shell", "shell", "summon", "omarchy.speedtest"])
    }
  }

  function summonWifiQr() {
    root.close()
    if (root.bar && root.bar.shell) {
      root.bar.shell.summon("omarchy.wifiqr")
    } else {
      Quickshell.execDetached(["omarchy-shell", "shell", "summon", "omarchy.wifiqr"])
    }
  }

  function omarchyNotify(message) {
    Quickshell.execDetached([root.scriptDir + "/action.sh", "notify", message])
  }

  Process {
    id: statusProc
    command: [root.scriptDir + "/status.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: Model.parseStatus(text, root)
    }
  }

  Process {
    id: actionProc
    command: []
    property string stdinSecret: ""
    stdinEnabled: true
    onStarted: {
      if (stdinSecret !== "") {
        write(stdinSecret + "\n")
        stdinSecret = ""
      }
    }
    stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionStdoutText = text }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true; onStreamFinished: root._actionStderrText = text }
    onExited: function(exitCode) {
      if (root.wifiActionKind === "connect") {
        if (exitCode !== 0) {
          var err = (actionStderr.text || root._actionStderrText || actionStdout.text || root._actionStdoutText || "").trim()
          err = err.replace(/^Error:\s*/i, "").split("\n")[0]
          root.wifiErrorSsid = root.wifiActionSsid
          root.wifiErrorMsg = err || "Connection failed"
          if (Model.isWifiAuthError(root.wifiErrorMsg) && root.wifiActionSsid !== "") {
            // A rejected passphrase should not cost a second click: reveal the
            // password field (and keep focus out of the key catcher) so the
            // new PSK can be typed straight away.
            root.openWifiPassword(root.wifiActionSsid)
            root.wifiErrorSsid = root.wifiActionSsid
            root.wifiErrorMsg = err || "Wrong password"
            root.wifiErrorNeedsPassword = true
          }
        } else {
          root.wifiErrorSsid = ""
          root.wifiErrorMsg = ""
          root.wifiErrorNeedsPassword = false
          root.wifiPasswordSsid = ""
          root.wifiPasswordText = ""
        }
        root.wifiActionSsid = ""
        root.wifiActionKind = ""
      } else if (root.wifiActionKind === "forget") {
        if (exitCode !== 0) {
          var ferr = (actionStderr.text || root._actionStderrText || actionStdout.text || root._actionStdoutText || "").trim()
          ferr = ferr.replace(/^Error:\s*/i, "").split("\n")[0]
          root.wifiErrorSsid = root.wifiActionSsid
          root.wifiErrorMsg = ferr || "Failed to forget network"
        } else {
          root.wifiErrorSsid = ""
          root.wifiErrorMsg = ""
          root.wifiErrorNeedsPassword = false
          if (root.wifiPasswordSsid === root.wifiActionSsid) root.cancelWifiPassword()
        }
        root.wifiActionSsid = ""
        root.wifiActionKind = ""
      }
      root.refresh()
    }
  }

  Component.onCompleted: {
    refresh()
  }

  Component.onDestruction: {
    if (scannerDev) scannerDev.scannerEnabled = false
    actionProc.stdinSecret = ""
    if (statusProc.running) statusProc.running = false
    if (actionProc.running) actionProc.running = false
  }

  Timer {
    id: statusWatchdog
    interval: 12000
    repeat: false
    running: statusProc.running
    onTriggered: {
      if (statusProc.running) statusProc.running = false
    }
  }

  Timer {
    id: actionWatchdog
    interval: 60000
    repeat: false
    running: actionProc.running
    onTriggered: {
      actionProc.stdinSecret = ""
      if (actionProc.running) actionProc.running = false
      if (root.wifiActionSsid !== "") {
        root.wifiErrorSsid = root.wifiActionSsid
        root.wifiErrorMsg = "Action timed out"
        root.wifiActionSsid = ""
        root.wifiActionKind = ""
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      refreshIfStale()
      // Turn the shared Wi-Fi scanner on so NetworkManager populates the
      // device's network list (it is otherwise known-connections only).
      Qt.callLater(function() { root.setScanner(true) })
    } else {
      root.setScanner(false)
      root.wifiForgetSsid = ""
      cancelWifiPassword()
    }
  }

  // Supplementary details only (frequency, bitrate, latency, data usage,
  // tailscale, firewall). Connection identity is signal-driven from the
  // Networking service, so this does not need to fire often: 5s while the
  // panel is open for fresh latency numbers, 20s while closed.
  Timer {
    interval: root.opened ? 5000 : 20000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // ---------- bar button ----------
  Item {
    anchors.fill: parent

    BarIconButton {
      id: button
      anchors.fill: parent
      bar: root.bar
      text: root.barText
      fixedWidth: Style.space(30)
      tooltipText: "Network Hub"
      onPressed: function(b) { root.toggle() }
    }

    Rectangle {
      anchors.fill: parent
      color: Color.accent
      opacity: 0.25
      radius: Style.cornerRadius
      visible: mainDropArea.containsDrag
    }

    DropArea {
      id: mainDropArea
      anchors.fill: parent
      keys: ["text/uri-list"]
      onEntered: function(drag) {
        if (drag.hasUrls) {
          drag.accept(Qt.CopyAction)
          root.currentTab = "tailnet"
          if (!root.opened) root.open()
        }
      }
      onDropped: function(drop) {
        if (drop.hasUrls) {
          var paths = []
          for (var i = 0; i < drop.urls.length; i++) {
            var p = String(drop.urls[i])
            if (p.indexOf("file://") === 0) {
              paths.push(decodeURIComponent(p.substring(7)))
            } else {
              paths.push(decodeURIComponent(p))
            }
          }
          if (paths.length > 0) {
            // Use the taildrop-menu-send script we just created to pop up the peer selector!
            var cmd = [root.scriptDir + "/bin/taildrop-menu-send"].concat(paths)
            Quickshell.execDetached(cmd)
            drop.accept(Qt.CopyAction)
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    property var activeDropPaths: []
    anchorItem: button
    owner: root
    bar: root.bar
    // No artificial delay between the click and the card appearing. Content
    // that lands later (a Wi-Fi scan, a fresh poll) grows the card through
    // KeyboardPanel's drawnHeight animation, which is far less noticeable
    // than a blank 350ms wait on every open.
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: Math.min(Style.space(760), panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(760)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.wifiPasswordSsid !== "" || root.wifiForgetSsid !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
    }

    // Forget confirmation. Built the way the shell's own panels do it: a
    // sibling overlay takes focus and forwards keys to the dialog, instead of
    // focusing the dialog itself (KeyboardPanel forces focus to its target on
    // open, which would steal it back).
    Item {
      id: forgetOverlay
      anchors.fill: parent
      z: 20
      visible: root.wifiForgetSsid !== ""
      enabled: visible
      focus: visible

      // KeyboardPanel re-asserts focus on keyCatcher when the panel opens, so
      // grab it again whenever the dialog appears.
      onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        forgetConfirm.handleKey(event)
        event.accepted = true
      }

      ConfirmDialog {
        id: forgetConfirm
        anchors.fill: parent
        opened: root.wifiForgetSsid !== ""
        message: "Forget the saved network \"" + root.wifiForgetSsid + "\"? Its password will have to be entered again."
        confirmText: "Forget"
        background: Color.popups.background
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelForgetWifi()
        onConfirmed: root.confirmForgetWifi()
      }
    }

    ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      Binding {
        target: scrollArea.contentItem
        property: "interactive"
        value: panelColumn.implicitHeight > scrollArea.height
      }

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(12)

        // ---------- Modern Header ----------
        PanelHero {
          width: parent.width
          title: "Network Hub"
          meta: {
            var items = []
            if (tailscaleUp) items.push("Tailnet (" + tailscalePeers + " peer" + (tailscalePeers === 1 ? "" : "s") + ")")
            if (ssid !== "") items.push(ssid)
            if (fwActive) items.push("UFW active (" + fwRules + ")")
            return items.length > 0 ? items.join(" · ") : "Offline"
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: Model.signalIcon(root.signal, root.netType)
              textFormat: Text.PlainText
              color: root.signal >= 0 || root.tailscaleUp ? Color.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        // ---------- Flat Segmented Tab Bar ----------
        Row {
          width: parent.width
          spacing: Style.space(4)

          FlatTabButton {
            width: (parent.width - Style.space(8)) / 3
            label: "Network"
            icon: Model.signalIcon(root.signal, root.netType)
            badge: root.signal >= 0 ? root.signal + "%" : ""
            selected: root.currentTab === "network"
            onClicked: root.currentTab = "network"
          }

          FlatTabButton {
            width: (parent.width - Style.space(8)) / 3
            label: "Tailnet"
            useTailscaleIcon: true
            badge: root.tailscaleUp ? String(root.tailscalePeers) : ""
            selected: root.currentTab === "tailnet"
            onClicked: root.currentTab = "tailnet"
          }

          FlatTabButton {
            width: (parent.width - Style.space(8)) / 3
            label: "Firewall"
            icon: "󰒃"
            badge: root.fwActive ? String(root.fwRules) : "off"
            selected: root.currentTab === "firewall"
            onClicked: root.currentTab = "firewall"
          }
        }

        PanelSeparator {}

        // ==========================================
        // TAB 1: NETWORK & TOOLS (Feature Complete)
        // ==========================================
        Column {
          visible: root.currentTab === "network"
          width: parent.width
          spacing: Style.space(10)

          // Unified Network Card
          BorderSurface {
            width: parent.width
            implicitHeight: unifiedNetCol.implicitHeight + Style.space(20)
            color: Style.normalFillFor(root.foreground, Color.accent)
            radius: Style.cornerRadius
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Column {
              id: unifiedNetCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              spacing: Style.space(10)

              // Header Row with QR Code, Speed Test, Restart, and Wi-Fi Switch
              Item {
                width: parent.width
                implicitHeight: Math.max(netHeaderLeft.implicitHeight, netHeaderRight.implicitHeight)

                Row {
                  id: netHeaderLeft
                  anchors.left: parent.left
                  anchors.right: netHeaderRight.left
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    text: Model.signalIcon(root.signal, root.netType)
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    color: Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      text: root.ssid !== "" ? root.ssid : Model.typeLabel(root.netType)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      color: root.foreground
                    }
                    Text {
                      text: root.netType === "wifi"
                        ? Model.formatBand(root.netFreq, root.netIface) + (root.netBitrate !== "" ? " · " + root.netBitrate : "")
                        : (root.netType === "ethernet" ? (root.netIface !== "" ? root.netIface : "Ethernet") : (root.netIface !== "" ? root.netIface : (!root.wifiRadio ? "Wi-Fi Disabled" : "Not connected")))
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.dimColor
                    }
                  }
                }

                // Header Action Buttons: Restart, QR, Speed Test, and Toggle
                Row {
                  id: netHeaderRight
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  PanelActionButton {
                    iconText: "󰑐"
                    tooltipText: "Restart Wi-Fi Subsystem"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.runAction(["wifi-restart"])
                  }

                  PanelActionButton {
                    visible: root.netType === "wifi" && root.ssid !== ""
                    iconText: "󰅙"
                    tooltipText: "Disconnect from Wi-Fi"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.runAction(["wifi-disconnect"])
                  }

                  PanelActionButton {
                    visible: root.netType === "wifi" && root.ssid !== ""
                    iconText: "󰐲"
                    tooltipText: "Show Wi-Fi QR code"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.summonWifiQr()
                  }

                  PanelActionButton {
                    iconText: "󰓅"
                    tooltipText: "Run a speed test"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.summonSpeedTest()
                  }

                  ToggleSwitch {
                    checked: root.wifiRadio
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.runAction(["wifi-toggle"])
                  }
                }
              }

              PanelSeparator { width: parent.width }

              // Diagnostics & Info Rows (connected), two columns to save height:
              // Local IP / Gateway on the first row, Signal / Latency on the second.
              Column {
                visible: root.ssid !== "" || root.netType === "ethernet"
                width: parent.width
                spacing: Style.space(6)

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  InfoRow {
                    width: (parent.width - Style.space(12)) / 2
                    label: "Local IP"
                    value: root.netIp !== "" ? root.netIp : "—"
                    copyable: root.netIp !== ""
                    onCopied: root.copyToClipboard(root.netIp, "Local IP")
                  }
                  InfoRow {
                    width: (parent.width - Style.space(12)) / 2
                    label: "Gateway"
                    value: root.gateway !== "" ? root.gateway : "—"
                    copyable: root.gateway !== ""
                    onCopied: root.copyToClipboard(root.gateway, "Gateway")
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  InfoRow {
                    width: (parent.width - Style.space(12)) / 2
                    label: "Signal"
                    value: (root.signal >= 0 ? root.signal + "%" : "—")
                      + (root.signalDbm !== "" ? " · " + root.signalDbm + " dBm" : "")
                  }
                  InfoRow {
                    visible: root.routerPing !== "" || root.internetPing !== ""
                    width: (parent.width - Style.space(12)) / 2
                    label: "Latency"
                    value: (root.routerPing !== "" ? "󰑩 " + root.routerPing + " ms" : "")
                      + (root.routerPing !== "" && root.internetPing !== "" ? "   " : "")
                      + (root.internetPing !== "" ? "󰖟 " + root.internetPing + " ms" : "")
                  }
                }
              }

              // Unified Wi-Fi list: saved profiles first, then nearby networks
              Column {
                visible: root.wifiRadio && root.wifiNetworks.length > 0
                width: parent.width
                spacing: Style.space(8)

                Column {
                  visible: root.wifiRadio
                  width: parent.width
                  spacing: Style.space(8)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(availWifiTitle.implicitHeight, wifiScanBtn.implicitHeight)

                    Text {
                      id: availWifiTitle
                      text: "WI-FI NETWORKS (" + root.wifiNetworks.length + ")"
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    PanelActionButton {
                      id: wifiScanBtn
                      iconText: "󰑐"
                      tooltipText: "Rescan Wi-Fi networks"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      enabled: !actionProc.running && root.wifiActionSsid === ""
                      opacity: (!actionProc.running && root.wifiActionSsid === "") ? 1.0 : 0.5
                      onClicked: root.rescanWifi()
                    }
                  }

                  Text {
                    visible: root.wifiNetworks.length === 0
                    text: "Scanning for nearby Wi-Fi networks…"
                    textFormat: Text.PlainText
                    color: root.dimColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    width: parent.width
                    wrapMode: Text.WordWrap
                  }

                  // The list scrolls on its own so the connection card above it
                  // and the band/DNS controls below stay in view. The cap is
                  // generous (about four rows) and then a little shorter than
                  // the old fixed 260px so the settings below never clip.
                  ScrollView {
                    id: wifiListScroll
                    width: parent.width
                    // Leave room for the controls below: the panel caps content
                    // height, so billing the list a fixed slice would push the
                    // band/DNS rows out of view.
                    readonly property real maxListHeight: Style.space(208)
                    height: Math.min(wifiListColumn.implicitHeight, maxListHeight)
                    visible: root.wifiNetworks.length > 0
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                    ScrollBar.vertical.policy: wifiListColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

                    Column {
                      id: wifiListColumn
                      width: wifiListScroll.availableWidth
                      spacing: Style.space(6)

                      Repeater {
                        model: root.wifiNetworks

                      BorderSurface {
                        id: netCard
                        width: parent.width
                        implicitHeight: netCardCol.implicitHeight + Style.space(16)
                        color: Style.normalFillFor(root.foreground, Color.accent)
                        radius: Style.cornerRadius
                        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                        Column {
                          id: netCardCol
                          anchors.fill: parent
                          anchors.margins: Style.space(8)
                          spacing: Style.space(8)

                          Item {
                            width: parent.width
                            implicitHeight: Math.max(netRowLeft.implicitHeight, netRowRight.implicitHeight)

                            Row {
                              id: netRowLeft
                              anchors.left: parent.left
                              anchors.right: netRowRight.left
                              anchors.rightMargin: Style.space(8)
                              anchors.verticalCenter: parent.verticalCenter
                              spacing: Style.space(8)

                              Text {
                                text: Model.signalIcon(modelData.signal, "wifi")
                                textFormat: Text.PlainText
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.title
                                color: Color.accent
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Style.space(2)

                                Row {
                                  spacing: Style.space(6)
                                  Text {
                                    text: modelData.ssid
                                    textFormat: Text.PlainText
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.bodySmall
                                    font.bold: true
                                    color: root.foreground
                                    anchors.verticalCenter: parent.verticalCenter
                                    elide: Text.ElideRight
                                    width: Math.min(implicitWidth, Style.space(220))
                                  }
                                }

                                Row {
                                  spacing: Style.space(6)

                                  // Pinned to the start of the second line, so
                                  // every "Saved" pill sits at the same x no
                                  // matter how long the SSID above is.
                                  BorderSurface {
                                    visible: !!modelData.saved
                                    implicitHeight: Style.space(16)
                                    implicitWidth: savedTxt.implicitWidth + Style.space(8)
                                    radius: Style.cornerRadius
                                    color: Style.selectedFillFor(root.foreground, Color.accent)
                                    borderSpec: Border.controlSpec("selected", root.foreground, Color.accent)
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                      id: savedTxt
                                      anchors.centerIn: parent
                                      text: "Saved"
                                      textFormat: Text.PlainText
                                      color: Color.accent
                                      font.family: root.fontFamily
                                      font.pixelSize: Style.font.caption
                                      font.bold: true
                                    }
                                  }

                                  Text {
                                    text: modelData.reachable
                                      ? (modelData.signal + "% signal" + (modelData.security ? " · " + modelData.security : ""))
                                      : "Out of range" + (modelData.security ? " · " + modelData.security : "")
                                    textFormat: Text.PlainText
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    color: root.dimColor
                                    anchors.verticalCenter: parent.verticalCenter
                                  }
                                }
                              }
                            }

                            Row {
                              id: netRowRight
                              anchors.right: parent.right
                              anchors.verticalCenter: parent.verticalCenter
                              spacing: Style.space(6)
                              // The row-wide click target below is declared after
                              // this Row, so lift the buttons above it.
                              z: 1

                              Text {
                                visible: root.wifiActionSsid === modelData.ssid
                                text: "Connecting…"
                                textFormat: Text.PlainText
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.italic: true
                                color: Color.accent
                                anchors.verticalCenter: parent.verticalCenter
                              }

                              Text {
                                visible: root.wifiErrorSsid === modelData.ssid && root.wifiPasswordSsid !== modelData.ssid
                                text: root.wifiErrorMsg
                                textFormat: Text.PlainText
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                color: Color.urgent
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                width: Math.min(implicitWidth, Style.space(160))
                              }

                              PanelActionButton {
                                visible: !!modelData.saved
                                iconText: "󰌋"
                                tooltipText: "Update the saved password"
                                foreground: root.foreground
                                fontFamily: root.fontFamily
                                anchors.verticalCenter: parent.verticalCenter
                                enabled: root.wifiActionSsid === ""
                                onClicked: {
                                  if (root.wifiPasswordSsid === modelData.ssid) {
                                    root.cancelWifiPassword()
                                  } else {
                                    root.openWifiPassword(modelData.ssid)
                                    root.wifiErrorSsid = ""
                                    root.wifiErrorMsg = ""
                                  }
                                }
                              }

                              PanelActionButton {
                                visible: !!modelData.saved
                                iconText: "󰌸"
                                tooltipText: "Forget this saved network"
                                foreground: root.foreground
                                hoverColor: Color.urgent
                                fontFamily: root.fontFamily
                                anchors.verticalCenter: parent.verticalCenter
                                enabled: root.wifiActionSsid === ""
                                onClicked: root.requestForgetWifi(modelData.ssid)
                              }
                            }

                            MouseArea {
                              anchors.fill: parent
                              cursorShape: Qt.PointingHandCursor
                              enabled: root.wifiActionSsid === ""
                              onClicked: {
                                if ((modelData.known && root.wifiErrorSsid !== modelData.ssid) || !Model.isSecured(modelData.security)) {
                                  root.connectWifi(modelData.ssid)
                                } else {
                                  if (root.wifiPasswordSsid === modelData.ssid) {
                                    root.cancelWifiPassword()
                                  } else {
                                    root.openWifiPassword(modelData.ssid)
                                    root.wifiErrorSsid = ""
                                    root.wifiErrorMsg = ""
                                  }
                                }
                              }
                            }
                          }

                          // Inline password entry area
                          Column {
                            width: parent.width
                            spacing: Style.space(6)
                            visible: root.wifiPasswordSsid === modelData.ssid

                            PanelSeparator { width: parent.width }

                            Row {
                              width: parent.width
                              spacing: Style.space(6)

                              // Custom non-native field: see BoundedTextField.qml
                              // for why editable Qt text inputs are avoided.
                              BoundedTextField {
                                id: wifiPwInput
                                width: parent.width - inlineConnectBtn.implicitWidth - inlineCancelBtn.implicitWidth - Style.space(12)
                                password: true
                                maxLength: 256
                                placeholderText: root.wifiErrorNeedsPassword && root.wifiErrorSsid === modelData.ssid
                                  ? "New Wi-Fi Password"
                                  : "Wi-Fi Password"
                                text: root.wifiPasswordSsid === modelData.ssid ? root.wifiPasswordText : ""
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.bodySmall
                                foreground: root.foreground
                                scriptDir: root.scriptDir
                                enabled: root.wifiActionSsid === ""
                                activeFocusOnTab: true
                                onTextChanged: if (root.wifiPasswordSsid === modelData.ssid && text !== root.wifiPasswordText) root.wifiPasswordText = text
                                onAccepted: {
                                  if (text.length > 0 && root.wifiActionSsid === "") {
                                    root.connectWifi(modelData.ssid, text, modelData.security)
                                  }
                                }
                                Keys.onEscapePressed: root.cancelWifiPassword()
                                onVisibleChanged: {
                                  if (visible) {
                                    text = root.wifiPasswordText
                                    Qt.callLater(forceActiveFocus)
                                  }
                                }
                                Component.onCompleted: if (visible) Qt.callLater(forceActiveFocus)
                              }

                              Button {
                                id: inlineConnectBtn
                                text: "Connect"
                                iconText: "󰄬"
                                fontSize: Style.font.caption
                                foreground: Color.accent
                                fontFamily: root.fontFamily
                                bordered: true
                                activeFocusOnTab: true
                                enabled: root.wifiPasswordText.length > 0 && root.wifiActionSsid === ""
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: root.connectWifi(modelData.ssid, root.wifiPasswordText, modelData.security)
                              }

                              Button {
                                id: inlineCancelBtn
                                text: "Cancel"
                                iconText: "󰅙"
                                fontSize: Style.font.caption
                                foreground: root.dimColor
                                fontFamily: root.fontFamily
                                bordered: true
                                activeFocusOnTab: true
                                anchors.verticalCenter: parent.verticalCenter
                                onClicked: root.cancelWifiPassword()
                              }
                            }

                            Text {
                              visible: root.wifiErrorSsid === modelData.ssid
                              text: root.wifiErrorNeedsPassword && root.wifiErrorSsid === modelData.ssid
                                ? "Saved password was rejected. Enter the new password to update the profile."
                                : root.wifiErrorMsg
                              textFormat: Text.PlainText
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              color: Color.urgent
                              width: parent.width
                              wrapMode: Text.WordWrap
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
              }

              // Band Steering & DNS Presets
              Column {
                width: parent.width
                spacing: Style.space(8)

                Row {
                  visible: root.ssid !== "" && root.netType === "wifi"
                  width: parent.width
                  spacing: Style.space(12)

                  Text {
                    text: "Wi-Fi Band"
                    textFormat: Text.PlainText
                    color: root.dimColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    width: Style.space(90)
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Row {
                    spacing: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter

                    SelectableChip {
                      label: "Auto"
                      active: root.bandSelected === "auto" || root.bandSelected === ""
                      onClicked: root.runAction(["set-band", "auto"])
                    }
                    SelectableChip {
                      label: "2.4 GHz"
                      active: root.bandSelected === "2.4"
                      onClicked: root.runAction(["set-band", "2.4"])
                    }
                    SelectableChip {
                      label: "5 GHz"
                      active: root.bandSelected === "5"
                      onClicked: root.runAction(["set-band", "5"])
                    }
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(12)

                  Text {
                    text: "DNS Provider"
                    textFormat: Text.PlainText
                    color: root.dimColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    width: Style.space(90)
                    horizontalAlignment: Text.AlignRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Row {
                    spacing: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter

                    SelectableChip {
                      label: "DHCP"
                      active: root.dnsCurrent.indexOf("DHCP") !== -1
                      onClicked: root.runAction(["set-dns", "DHCP"])
                    }
                    SelectableChip {
                      label: "Cloudflare"
                      active: root.dnsCurrent.indexOf("Cloudflare") !== -1
                      onClicked: root.runAction(["set-dns", "Cloudflare"])
                    }
                    SelectableChip {
                      label: "Google"
                      active: root.dnsCurrent.indexOf("Google") !== -1
                      onClicked: root.runAction(["set-dns", "Google"])
                    }
                    SelectableChip {
                      label: "Mullvad"
                      active: root.dnsCurrent.indexOf("Mullvad") !== -1
                      onClicked: root.runAction(["set-dns", "Mullvad"])
                    }
                    SelectableChip {
                      label: "Custom"
                      active: root.dnsCurrent.indexOf("Custom") !== -1
                      onClicked: root.runAction(["set-dns", "Custom"])
                    }
                  }
                }
              }

              PanelSeparator { width: parent.width }

              // Data usage. Two distinct metrics, labelled so they cannot be
              // confused: "Session" is the interface counter since boot (what
              // btop shows) and "Today" is vnstat's daily total.
              Column {
                width: parent.width
                spacing: Style.space(4)

                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(16)

                  Row {
                    spacing: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                      text: "󰇚"
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: root.dataRx !== "" ? root.dataRx : "—"
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }

                  Row {
                    spacing: Style.space(5)
                    anchors.verticalCenter: parent.verticalCenter
                    Text {
                      text: "󰕒"
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      text: root.dataTx !== "" ? root.dataTx : "—"
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: root.dataTodayRx !== ""
                  text: "Today: 󰇚 " + root.dataTodayRx + "   󰕒 " + root.dataTodayTx
                  textFormat: Text.PlainText
                  color: root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ==========================================
        // TAB 2: TAILNET
        // ==========================================
        Column {
          visible: root.currentTab === "tailnet"
          width: parent.width
          spacing: Style.space(10)

          // Tailscale Status Card (Self Device)
          BorderSurface {
            width: parent.width
            implicitHeight: selfCol.implicitHeight + Style.space(20)
            color: Style.normalFillFor(root.foreground, Color.accent)
            radius: Style.cornerRadius
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Item {
              id: selfCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              implicitHeight: Math.max(selfLeftRow.implicitHeight, selfActionRow.implicitHeight)

              Row {
                id: selfLeftRow
                anchors.left: parent.left
                anchors.right: selfActionRow.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: Model.osIcon(root.selfOS)
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  color: root.tailscaleUp ? Color.accent : root.dimColor
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Row {
                    spacing: Style.space(6)
                    Text {
                      text: root.selfHost + " (This Device)"
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      color: root.foreground
                    }
                    Rectangle {
                      width: Style.space(7)
                      height: Style.space(7)
                      radius: width / 2
                      color: root.tailscaleUp ? "#55dd77" : "#888888"
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  Text {
                    text: root.selfIp !== "" ? root.selfIp : "Tailscale not connected"
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dimColor
                  }

                  Row {
                    visible: (root.exitNodeHost !== "" || root.exitNodeIp !== "")
                    spacing: Style.space(6)

                    Text {
                      text: "Exit Node: " + (root.exitNodeHost !== "" ? (root.exitNodeIp !== "" ? root.exitNodeHost + " (" + root.exitNodeIp + ")" : root.exitNodeHost) : root.exitNodeIp)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      color: Color.accent
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, Style.space(240))
                    }

                    PanelActionButton {
                      iconText: "󰅙"
                      tooltipText: "Disconnect exit node"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.runAction(["clear-exit-node"])
                    }
                  }
                }
              }

              Row {
                id: selfActionRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                PanelActionButton {
                  id: selfActionBtn
                  visible: root.selfIp !== ""
                  iconText: "󰆏"
                  tooltipText: "Copy Tailscale IP"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.copyToClipboard(root.selfIp, "Tailscale IP")
                }

                ToggleSwitch {
                  checked: root.tailscaleUp
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.runAction([root.tailscaleUp ? "ts-down" : "ts-up"])
                }
              }
            }
          }

          // Machines Header
          Item {
            width: parent.width
            implicitHeight: Math.max(peersHeaderLabel.implicitHeight, adminBtn.implicitHeight)

            Text {
              id: peersHeaderLabel
              text: "PEERS (" + root.peers.length + ")"
              textFormat: Text.PlainText
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            PanelActionButton {
              id: adminBtn
              iconText: "󰏌"
              tooltipText: "Open Tailscale admin console (web)"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onClicked: Quickshell.execDetached(["bash", "-c", "xdg-open https://login.tailscale.com/admin/machines"])
            }
          }

          // Peer List
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.peers.length > 0

            Repeater {
              model: root.peers

              BorderSurface {
                id: peerSurface
                width: parent.width
                implicitHeight: peerRow.implicitHeight + Style.space(16)
                color: Style.normalFillFor(root.foreground, Color.accent)
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                Rectangle {
                  anchors.fill: parent
                  color: Color.accent
                  opacity: 0.2
                  radius: Style.cornerRadius
                  visible: peerDropArea.containsDrag
                }

                DropArea {
                  id: peerDropArea
                  anchors.fill: parent
                  keys: ["text/uri-list"]
                  onEntered: function(drag) {
                    if (drag.hasUrls) {
                      drag.accept(Qt.CopyAction)
                    }
                  }
                  onDropped: function(drop) {
                    if (drop.hasUrls) {
                      var paths = []
                      for (var i = 0; i < drop.urls.length; i++) {
                        var p = String(drop.urls[i])
                        if (p.indexOf("file://") === 0) {
                          paths.push(decodeURIComponent(p.substring(7)))
                        } else {
                          paths.push(decodeURIComponent(p))
                        }
                      }
                      if (paths.length > 0) {
                        root.sendPeerFile(modelData, paths)
                        drop.accept(Qt.CopyAction)
                      }
                    }
                  }
                }

                Item {
                  id: peerRow
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  implicitHeight: Math.max(peerLeftRow.implicitHeight, peerActionRow.implicitHeight)

                  Row {
                    id: peerLeftRow
                    anchors.left: parent.left
                    anchors.right: peerActionRow.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: Model.osIcon(modelData.os)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      color: modelData.online ? Color.accent : root.dimColor
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Row {
                        spacing: Style.space(5)
                        Text {
                          text: modelData.host
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                          anchors.verticalCenter: parent.verticalCenter
                          elide: Text.ElideRight
                          width: Math.min(implicitWidth, Style.space(160))
                        }
                        Rectangle {
                          width: Style.space(6)
                          height: Style.space(6)
                          radius: width / 2
                          color: modelData.online ? "#55dd77" : "#888888"
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        // Active Exit Node Tag
                        BorderSurface {
                          id: activeExitTag
                          visible: !!modelData.exitNode
                          implicitHeight: Style.space(18)
                          implicitWidth: activeExitTagRow.implicitWidth + Style.space(10)
                          radius: Style.cornerRadius
                          color: Style.selectedFillFor(root.foreground, Color.accent)
                          borderSpec: Border.controlSpec("selected", root.foreground, Color.accent)
                          anchors.verticalCenter: parent.verticalCenter

                          Row {
                            id: activeExitTagRow
                            anchors.centerIn: parent
                            spacing: Style.space(4)

                            Text {
                              text: "Active Exit Node"
                              textFormat: Text.PlainText
                              color: Color.accent
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              font.bold: true
                              anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                              text: "󰅙"
                              textFormat: Text.PlainText
                              color: Color.accent
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                              anchors.verticalCenter: parent.verticalCenter
                            }
                          }

                          MouseArea {
                            id: activeExitMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: root.runAction(["clear-exit-node"])
                          }

                          PanelToolTip {
                            visible: activeExitMouse.containsMouse
                            text: "Click to disconnect exit node"
                            fontFamily: root.fontFamily
                          }
                        }

                        // Available Exit Node Tag
                        BorderSurface {
                          id: availExitTag
                          visible: !!modelData.exitNodeOption && !modelData.exitNode
                          implicitHeight: Style.space(18)
                          implicitWidth: availExitText.implicitWidth + Style.space(10)
                          radius: Style.cornerRadius
                          color: availExitMouse.containsMouse ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
                          borderSpec: Border.controlSpec(availExitMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            id: availExitText
                            anchors.centerIn: parent
                            text: "Exit Node"
                            textFormat: Text.PlainText
                            color: availExitMouse.containsMouse ? Color.accent : root.dimColor
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: availExitMouse.containsMouse
                          }

                          MouseArea {
                            id: availExitMouse
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            hoverEnabled: true
                            onClicked: root.runAction(["set-exit-node", modelData.dnsName || modelData.ip || modelData.host])
                          }

                          PanelToolTip {
                            visible: availExitMouse.containsMouse
                            text: "Set as exit node"
                            fontFamily: root.fontFamily
                          }
                        }
                      }

                      Text {
                        text: modelData.ip !== "" ? modelData.ip : "Offline"
                        textFormat: Text.PlainText
                        color: root.dimColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  Row {
                    id: peerActionRow
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(4)

                    PanelActionButton {
                      id: copyBtn
                      iconText: "󰆏"
                      tooltipText: "Copy details"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: copyPopup.open()

                      Popup {
                        id: copyPopup
                        y: copyBtn.height + Style.space(4)
                        x: copyBtn.width - width
                        padding: 0
                        background: BorderSurface {
                          color: Color.background
                          borderSpec: Border.flat(root.dimColor, 1)
                          radius: Style.cornerRadius
                          clip: true
                        }
                        Column {
                          width: Style.space(180)
                          CopyChoice {
                            width: parent.width
                            label: "Copy IPv4"
                            icon: "󰩟"
                            onClicked: { root.copyToClipboard(modelData.ip, modelData.host + " IPv4"); copyPopup.close() }
                          }
                          CopyChoice {
                            width: parent.width
                            label: "Copy Hostname"
                            icon: "󰒋"
                            onClicked: { root.copyToClipboard(modelData.host, modelData.host + " Hostname"); copyPopup.close() }
                          }
                          CopyChoice {
                            width: parent.width
                            visible: modelData.dnsName !== ""
                            label: "Copy DNS Name"
                            icon: "󰇖"
                            onClicked: { root.copyToClipboard(modelData.dnsName, modelData.host + " DNS Name"); copyPopup.close() }
                          }
                        }
                      }
                    }

                    PanelActionButton {
                      iconText: "󰒊"
                      tooltipText: "Send files (Taildrop)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      enabled: modelData.online
                      onClicked: root.sendPeerFile(modelData)
                    }
                  }
                }
              }
            }
          }

          Text {
            visible: root.peers.length === 0
            text: root.tailscaleUp ? "No peer devices connected on tailnet." : "Connect Tailscale to view and share with peers."
            textFormat: Text.PlainText
            color: root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            width: parent.width
            wrapMode: Text.WordWrap
          }
        }

        // ==========================================
        // TAB 3: FIREWALL (UFW)
        // ==========================================
        Column {
          visible: root.currentTab === "firewall"
          width: parent.width
          spacing: Style.space(10)

          // Master Firewall Status Card
          BorderSurface {
            width: parent.width
            implicitHeight: fwMasterCol.implicitHeight + Style.space(20)
            color: Style.normalFillFor(root.foreground, Color.accent)
            radius: Style.cornerRadius
            borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

            Item {
              id: fwMasterCol
              anchors.fill: parent
              anchors.margins: Style.space(10)
              implicitHeight: Math.max(fwLeftRow.implicitHeight, fwActionRow.implicitHeight)

              Row {
                id: fwLeftRow
                anchors.left: parent.left
                anchors.right: fwActionRow.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: root.fwActive ? "󰕥" : "󰦞"
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  color: root.fwActive ? Color.accent : root.dimColor
                  anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    text: root.fwActive ? "UFW Firewall Active" : "UFW Firewall Inactive"
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    color: root.fwActive ? "#55dd77" : root.foreground
                  }

                  Text {
                    text: root.fwRules + " active user rules"
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dimColor
                  }
                }
              }

              Row {
                id: fwActionRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                PanelActionButton {
                  iconText: "󰒃"
                  tooltipText: "View UFW rules in terminal"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  anchors.verticalCenter: parent.verticalCenter
                  onClicked: root.runAction(["fw-status"])
                }

                ToggleSwitch {
                  checked: root.fwActive
                  anchors.verticalCenter: parent.verticalCenter
                  onToggled: root.runAction([root.fwActive ? "fw-disable" : "fw-enable"])
                }
              }
            }
          }

          // Open Ports / Rules List Header
          Text {
            text: "ALLOWED INCOMING RULES (" + root.fwRuleList.length + ")"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          // Rules List
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root.fwRuleList.length > 0

            Repeater {
              model: root.fwRuleList

              BorderSurface {
                width: parent.width
                implicitHeight: ruleRow.implicitHeight + Style.space(12)
                color: Style.normalFillFor(root.foreground, Color.accent)
                radius: Style.cornerRadius
                borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                Item {
                  id: ruleRow
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  implicitHeight: Math.max(ruleLeftRow.implicitHeight, ruleDeleteBtn.implicitHeight)

                  Row {
                    id: ruleLeftRow
                    anchors.left: parent.left
                    anchors.right: ruleDeleteBtn.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      text: "󰄬"
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      color: "#55dd77"
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Row {
                        spacing: Style.space(6)
                        Text {
                          text: "Port " + modelData.port + " (" + modelData.proto + ")"
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.bold: true
                        }
                      }

                      Text {
                        text: (modelData.comment !== "" ? modelData.comment + " · " : "") + "From: " + modelData.src
                        textFormat: Text.PlainText
                        color: root.dimColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  PanelActionButton {
                    id: ruleDeleteBtn
                    iconText: "󰩺"
                    tooltipText: "Delete this allow rule"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onClicked: root.runAction(["fw-close", modelData.port, modelData.proto.toLowerCase()])
                  }
                }
              }
            }
          }

          Text {
            visible: root.fwRuleList.length === 0
            text: "No custom user port rules currently defined."
            textFormat: Text.PlainText
            color: root.dimColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator {}

          // Add / Open Port Controls
          Text {
            text: "OPEN A PORT"
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            BoundedTextField {
              id: newPortField
              width: parent.width * 0.45
              placeholderText: "Port (e.g. 8080)"
              digitsOnly: true
              maxLength: 5
              text: root.fwNewPort
              onTextChanged: root.fwNewPort = text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
              scriptDir: root.scriptDir
              activeFocusOnTab: true
            }

            Row {
              spacing: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter

              SelectableChip {
                label: "TCP"
                active: root.fwNewProto === "tcp"
                onClicked: root.fwNewProto = "tcp"
              }

              SelectableChip {
                label: "UDP"
                active: root.fwNewProto === "udp"
                onClicked: root.fwNewProto = "udp"
              }
            }

            Item { width: 1; height: 1 }

            PanelActionButton {
              iconText: "󰐕"
              tooltipText: "Open port (sudo ufw allow)"
              foreground: Color.accent
              fontFamily: root.fontFamily
              enabled: root.fwNewPort !== "" && /^\d+$/.test(root.fwNewPort)
              anchors.verticalCenter: parent.verticalCenter
              onClicked: {
                root.runAction(["fw-open", root.fwNewPort, root.fwNewProto])
                root.fwNewPort = ""
              }
            }
          }

          // Quick Port Presets
          Row {
            width: parent.width
            spacing: Style.space(4)

            PresetPill { label: "22: SSH"; port: "22"; proto: "tcp" }
            PresetPill { label: "80: HTTP"; port: "80"; proto: "tcp" }
            PresetPill { label: "3000: Node"; port: "3000"; proto: "tcp" }
            PresetPill { label: "5173: Vite"; port: "5173"; proto: "tcp" }
            PresetPill { label: "8080: Web"; port: "8080"; proto: "tcp" }
          }
        }
      }
    }

    DropArea {
      id: bigDropArea
      anchors.fill: parent
      keys: ["text/uri-list"]
      onEntered: function(drag) {
        if (drag.hasUrls) {
          drag.accept(Qt.CopyAction)
        }
      }
      onDropped: function(drop) {
        if (drop.hasUrls) {
          var paths = []
          for (var i = 0; i < drop.urls.length; i++) {
            var p = String(drop.urls[i])
            if (p.indexOf("file://") === 0) {
              paths.push(decodeURIComponent(p.substring(7)))
            } else {
              paths.push(decodeURIComponent(p))
            }
          }
          if (paths.length > 0) {
            var onlinePeers = []
            for (var j = 0; j < root.peers.length; j++) {
              if (root.peers[j].online) onlinePeers.push(root.peers[j])
            }
            if (onlinePeers.length === 1) {
              root.sendPeerFile(onlinePeers[0], paths)
              drop.accept(Qt.CopyAction)
            } else if (onlinePeers.length > 1) {
              panel.activeDropPaths = paths
              drop.accept(Qt.CopyAction)
            }
          }
        }
      }

      Rectangle {
        anchors.fill: parent
        color: Color.background
        opacity: 0.95
        visible: bigDropArea.containsDrag || mainDropArea.containsDrag || panel.activeDropPaths.length > 0
        z: 9999

        Column {
          anchors.centerIn: parent
          spacing: Style.space(16)
          visible: panel.activeDropPaths.length === 0

          Text {
            text: "󰒊"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.display * 2
            color: Color.accent
            anchors.horizontalCenter: parent.horizontalCenter
          }
          Text {
            text: "Drop here to send"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            color: root.foreground
            anchors.horizontalCenter: parent.horizontalCenter
          }
        }

        Column {
          anchors.centerIn: parent
          spacing: Style.space(8)
          visible: panel.activeDropPaths.length > 0
          width: parent.width * 0.8

          Text {
            text: "Select device to send to"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            color: root.dimColor
            anchors.horizontalCenter: parent.horizontalCenter
          }

          Column {
            width: parent.width
            spacing: 0
            Repeater {
              model: root.peers
              CopyChoice {
                width: parent.width
                visible: modelData.online
                label: modelData.host + (modelData.ip ? " (" + modelData.ip + ")" : "")
                icon: "󰒊"
                onClicked: {
                  root.sendPeerFile(modelData, panel.activeDropPaths)
                  panel.activeDropPaths = []
                }
              }
            }
            CopyChoice {
              width: parent.width
              label: "Cancel"
              icon: "󰜺"
              onClicked: panel.activeDropPaths = []
            }
          }
        }
      }
    }
  }

  // ---------- Reusable UI Components ----------
  component FlatTabButton: Item {
    id: rootFlatTab
    property string label: ""
    property string icon: ""
    property string badge: ""
    property bool selected: false
    property bool useTailscaleIcon: false
    signal clicked()

    implicitHeight: Style.space(34)

    Row {
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        visible: !rootFlatTab.useTailscaleIcon
        text: rootFlatTab.icon
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: rootFlatTab.selected ? Color.accent : root.foreground
        anchors.verticalCenter: parent.verticalCenter
      }

      TailscaleIcon {
        visible: rootFlatTab.useTailscaleIcon
        iconSize: Style.font.bodySmall * 0.9
        color: rootFlatTab.selected ? Color.accent : root.foreground
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: rootFlatTab.label
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: rootFlatTab.selected
        color: rootFlatTab.selected ? Color.accent : root.foreground
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        visible: rootFlatTab.badge !== ""
        text: rootFlatTab.badge
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: rootFlatTab.selected
        color: rootFlatTab.selected ? Color.accent : root.dimColor
        opacity: rootFlatTab.selected ? 1.0 : 0.7
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // Active bottom accent indicator line
    Rectangle {
      visible: rootFlatTab.selected
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      height: 2
      radius: 1
      color: Color.accent
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: rootFlatTab.clicked()
    }
  }

  component SelectableChip: BorderSurface {
    id: rootChip
    property string label: ""
    property bool active: false
    signal clicked()

    implicitHeight: Style.space(24)
    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    radius: Style.cornerRadius
    color: rootChip.active ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.controlSpec(rootChip.active ? "selected" : "normal", root.foreground, Color.accent)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: rootChip.label
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: rootChip.active
      color: rootChip.active ? Color.accent : root.dimColor
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: rootChip.clicked()
    }
  }

  component ActionButton: BorderSurface {
    id: rootActionBtn
    property string label: ""
    property string icon: ""
    signal clicked()

    implicitHeight: Style.space(34)
    radius: Style.cornerRadius
    color: actionMouse.containsMouse ? Style.selectedFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent)
    borderSpec: Border.controlSpec(actionMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)

    Row {
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        text: rootActionBtn.icon
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: Color.accent
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        text: rootActionBtn.label
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        color: root.foreground
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: actionMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rootActionBtn.clicked()
    }
  }

  component PresetPill: BorderSurface {
    id: rootPresetPill
    property string label: ""
    property string port: ""
    property string proto: "tcp"

    implicitHeight: Style.space(24)
    implicitWidth: presetLabel.implicitWidth + Style.space(10)
    radius: Style.cornerRadius
    color: presetMouse.containsMouse ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
    borderSpec: Border.controlSpec(presetMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)

    Text {
      id: presetLabel
      anchors.centerIn: parent
      text: rootPresetPill.label
      textFormat: Text.PlainText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      color: root.foreground
    }

    MouseArea {
      id: presetMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.fwNewPort = rootPresetPill.port
        root.fwNewProto = rootPresetPill.proto
      }
    }
  }

  component InfoRow: Item {
    id: rootInfoRow
    property string label: ""
    property string value: ""
    property bool copyable: false
    signal copied()

    implicitHeight: 20

    Text {
      id: infoLabel
      text: rootInfoRow.label
      textFormat: Text.PlainText
      color: root.dimColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, parent.width * 0.40)
      elide: Text.ElideRight
    }

    Row {
      anchors.right: parent.right
      anchors.left: infoLabel.right
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        text: rootInfoRow.value
        textFormat: Text.PlainText
        color: infoRowMouse.containsMouse && rootInfoRow.copyable ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        // Fill whatever the label left behind; elide instead of overlapping.
        width: parent.width - (infoCopyIcon.visible ? infoCopyIcon.width + parent.spacing : 0)
        elide: Text.ElideRight
      }

      Text {
        id: infoCopyIcon
        visible: rootInfoRow.copyable
        text: "󰆏"
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: infoRowMouse.containsMouse ? 1.0 : 0.4
        color: infoRowMouse.containsMouse ? Color.accent : root.dimColor
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: infoRowMouse
      anchors.fill: parent
      enabled: rootInfoRow.copyable
      hoverEnabled: true
      cursorShape: rootInfoRow.copyable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (rootInfoRow.copyable) rootInfoRow.copied()
    }
  }

  component CopyChoice: CursorSurface {
    id: copyChoice
    property string label: ""
    property string icon: ""
    signal clicked()

    implicitHeight: Style.space(36)
    radius: 0
    foreground: root.foreground
    hasCursor: mouse.containsMouse

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: copyChoice.clicked()
    }

    Row {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      spacing: Style.space(10)
      Text { text: copyChoice.icon; textFormat: Text.PlainText; color: root.dimColor; font.family: root.fontFamily; anchors.verticalCenter: parent.verticalCenter }
      Text { text: copyChoice.label; textFormat: Text.PlainText; color: root.foreground; font.family: root.fontFamily; anchors.verticalCenter: parent.verticalCenter }
    }
  }

  component TailscaleDot: Rectangle {
    property real size: 2
    width: size
    height: size
    radius: width / 2
  }

  component TailscaleIcon: Item {
    id: tsIconRoot
    property real iconSize: 14
    property color color: root.foreground

    width: iconSize
    height: iconSize
    implicitWidth: iconSize
    implicitHeight: iconSize

    readonly property real dotSize: Math.max(2, tsIconRoot.iconSize * 0.24)
    readonly property real mid: (tsIconRoot.iconSize - dotSize) / 2
    readonly property real end: tsIconRoot.iconSize - dotSize

    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: 0; y: 0; opacity: 0.24 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.mid; y: 0; opacity: 0.24 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.end; y: 0; opacity: 0.24 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: 0; y: tsIconRoot.mid; opacity: 1.0 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.mid; y: tsIconRoot.mid; opacity: 1.0 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.end; y: tsIconRoot.mid; opacity: 1.0 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: 0; y: tsIconRoot.end; opacity: 0.24 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.mid; y: tsIconRoot.end; opacity: 1.0 }
    TailscaleDot { size: tsIconRoot.dotSize; color: tsIconRoot.color; x: tsIconRoot.end; y: tsIconRoot.end; opacity: 0.24 }
  }
}
