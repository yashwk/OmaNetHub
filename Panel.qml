import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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

  // ---------- live status ----------
  property bool tailscaleUp: false
  property int tailscalePeers: 0
  property string selfHost: "localhost"
  property string selfIp: ""
  property string selfOS: "linux"
  property var peers: []
  property string ssid: ""
  property string netType: ""
  property string netIp: ""
  property int signal: -1
  property bool metered: false
  property string gateway: ""
  property bool wifiRadio: true
  property string netIface: ""
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
  property string dataSource: ""
  property bool fwActive: false
  property int fwRules: 0
  property var fwRuleList: []
  property bool statusFresh: false

  readonly property bool haveTailscale: tailscaleUp || tailscalePeers > 0 || selfIp !== ""
  readonly property bool haveFirewall: fwActive || fwRules > 0
  readonly property string barText: Model.barIcon(signal, netType, tailscaleUp)

  // ---------- input fields ----------
  property string fwNewPort: ""
  property string fwNewProto: "tcp"

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function runAction(args) {
    actionProc.command = [root.scriptDir + "/action.sh"].concat(args)
    actionProc.running = true
  }

  function copyToClipboard(value, label) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
    omarchyNotify(label + " copied to clipboard")
  }

  function sendPeerFile(peer, files) {
    if (!peer) return
    var targetIp = peer.ip || peer.host
    if (!targetIp) return
    var cmd = [root.scriptDir + "/bin/taildrop-direct-send", targetIp, peer.host]
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
    onExited: root.refresh()
  }

  Component.onCompleted: refresh()

  property bool panelReady: false

  Timer {
    id: settleTimer
    interval: 350
    onTriggered: root.panelReady = true
  }

  onOpenedChanged: {
    if (opened) {
      panelReady = false
      settleTimer.restart()
      refresh()
    }
  }

  Timer {
    interval: 3000
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
      tooltipText: "Network Hub (" + (root.ssid !== "" ? root.ssid : Model.typeLabel(root.netType)) + ")"
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
    open: root.opened && root.panelReady
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: Math.min(Style.space(620), panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620)))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
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
            icon: "󰞷"
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
                      text: root.netType === "wifi" ? Model.formatBand(root.netFreq, root.netIface) : (root.netIface !== "" ? root.netIface : "Connected")
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

              // Diagnostics & Info Rows
              Column {
                width: parent.width
                spacing: Style.space(8)

                InfoRow {
                  label: "Local IP"
                  value: root.netIp !== "" ? root.netIp : "—"
                  copyable: root.netIp !== ""
                  onCopied: root.copyToClipboard(root.netIp, "Local IP")
                }
                InfoRow {
                  label: "Gateway"
                  value: root.gateway !== "" ? root.gateway : "—"
                  copyable: root.gateway !== ""
                  onCopied: root.copyToClipboard(root.gateway, "Gateway")
                }
                InfoRow {
                  label: "Signal Strength"
                  value: (root.signalDbm !== "" ? root.signalDbm + " dBm · " : "") + (root.signal >= 0 ? root.signal + "%" : "—") + (root.netBitrate !== "" ? " · " + root.netBitrate : "")
                }
                InfoRow {
                  visible: root.routerPing !== "" || root.internetPing !== ""
                  label: "Latency"
                  value: (root.routerPing !== "" ? "󰋜 " + root.routerPing + " ms (Router)   " : "") + (root.internetPing !== "" ? "󰖟 " + root.internetPing + " ms (Internet)" : "")
                }
              }

              PanelSeparator { width: parent.width }

              // Band Steering & DNS Presets (using GridLayout for perfect label alignment)
              GridLayout {
                width: parent.width
                columns: 2
                rowSpacing: Style.space(8)
                columnSpacing: Style.space(12)

                Text {
                  text: "Wi-Fi Band"
                  textFormat: Text.PlainText
                  color: root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                }
                Row {
                  spacing: Style.space(4)
                  Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter

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

                Text {
                  text: "DNS Provider"
                  textFormat: Text.PlainText
                  color: root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                }
                Row {
                  spacing: Style.space(4)
                  Layout.alignment: Qt.AlignLeft | Qt.AlignVCenter

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

              PanelSeparator { width: parent.width }

              // Compact Single-Row Data Usage Footer
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
                    text: "Down: " + (root.dataRx !== "" ? root.dataRx : "—")
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
                    text: "Up: " + (root.dataTx !== "" ? root.dataTx : "—")
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                }

                Text {
                  text: "(Today · " + (root.dataSource || "vnstat") + ")"
                  textFormat: Text.PlainText
                  color: root.dimColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
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
              iconText: "󰌷"
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
                        }
                        Rectangle {
                          width: Style.space(6)
                          height: Style.space(6)
                          radius: width / 2
                          color: modelData.online ? "#55dd77" : "#888888"
                          anchors.verticalCenter: parent.verticalCenter
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
                            icon: "󰖟"
                            onClicked: { root.copyToClipboard(modelData.dnsName, modelData.host + " DNS Name"); copyPopup.close() }
                          }
                        }
                      }
                    }

                    PanelActionButton {
                      iconText: "󰒊"
                      tooltipText: "Send files to " + modelData.host + " (Taildrop)"
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
                  text: root.fwActive ? "󰒃" : "󰒄"
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
                  iconText: "󰞷"
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
                    iconText: "󰅖"
                    tooltipText: "Close port " + modelData.port + "/" + modelData.proto.toLowerCase()
                    foreground: "#ff5555"
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

            TextField {
              id: newPortField
              width: parent.width * 0.45
              placeholderText: "Port (e.g. 8080)"
              text: root.fwNewPort
              onTextChanged: root.fwNewPort = text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              foreground: root.foreground
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
                label: modelData.host
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

    width: parent.width
    implicitHeight: 20

    Text {
      text: rootInfoRow.label
      textFormat: Text.PlainText
      color: root.dimColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        text: rootInfoRow.value
        textFormat: Text.PlainText
        color: infoRowMouse.containsMouse && rootInfoRow.copyable ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
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