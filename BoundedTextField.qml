import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Single-line input that never instantiates Qt Quick Controls' native
// TextField/TextInput. QQuickTextInput reads QMimeData::text() from the
// clipboard whenever clipboard data changes while the field is writable,
// even when the user did not paste. That read is not byte-bounded before
// native insertion, so a delivered clipboard offer can consume memory or
// block the shared shell's GUI thread.
//
// This control keeps the editable buffer in QML and handles keys directly.
// Clipboard paste is an explicit action routed through bin/clipboard-paste,
// which streams wl-paste through `head -c` under `timeout`, so nothing in
// this process reads the native clipboard.
FocusScope {
  id: root

  // The editable value. User edits assign this property, matching the
  // writable TextField API used by the panel.
  property string text: ""
  property string placeholderText: ""
  property bool password: false
  property bool digitsOnly: false
  property int maxLength: 256
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY
  property string scriptDir: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/yashwanth.link"

  // Emitted on Return/Enter. The owner decides what accepting means.
  signal accepted()

  property font font: Qt.font({ family: Style.font.family, pixelSize: Style.font.body })

  readonly property string _displayText: password ? "•".repeat(text.length) : text
  readonly property int _selStart: Math.min(_anchor, _cursor)
  readonly property int _selEnd: Math.max(_anchor, _cursor)
  readonly property bool _hasSelection: _anchor !== _cursor

  property int _cursor: 0
  property int _anchor: 0
  property bool _internalEdit: false
  property bool _cursorVisible: true

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hoverArea.containsMouse || activeFocus
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)
  readonly property real leftPadding: horizontalPadding + _borderLeft
  readonly property real rightPadding: horizontalPadding + _borderRight
  readonly property real topPadding: verticalPadding + _borderTop
  readonly property real bottomPadding: verticalPadding + _borderBottom
  readonly property real _contentWidth: Math.max(0, width - leftPadding - rightPadding)
  readonly property real _scrollOffset: Math.max(0, cursorMetrics.advanceWidth - _contentWidth + 2)

  readonly property real _borderTop: _borderSpec && _borderSpec.widths ? _borderSpec.widths.top : 0
  readonly property real _borderRight: _borderSpec && _borderSpec.widths ? _borderSpec.widths.right : 0
  readonly property real _borderBottom: _borderSpec && _borderSpec.widths ? _borderSpec.widths.bottom : 0
  readonly property real _borderLeft: _borderSpec && _borderSpec.widths ? _borderSpec.widths.left : 0
  readonly property real _borderWidth: Math.max(_borderTop, _borderRight, _borderBottom, _borderLeft)
  readonly property color _borderColor: _borderSpec && _borderSpec.color ? _borderSpec.color : "transparent"

  implicitWidth: 120
  implicitHeight: Math.max(30, fontMetrics.height + topPadding + bottomPadding)
  activeFocusOnTab: true
  opacity: enabled ? 1 : 0.6

  onTextChanged: {
    if (!_internalEdit) {
      _cursor = text.length
      _anchor = _cursor
    }
  }

  onActiveFocusChanged: {
    _cursorVisible = true
    if (activeFocus) {
      _cursor = Math.min(_cursor, text.length)
      _anchor = Math.min(_anchor, text.length)
    }
  }

  onEnabledChanged: if (!enabled) focus = false

  // Drop control characters and anything the field must not accept. This
  // runs on keyboard text and on the already byte-capped paste result.
  function _sanitize(value) {
    var out = ""
    var limit = Math.max(0, maxLength)
    for (var i = 0; i < value.length && out.length < limit; i++) {
      var code = value.charCodeAt(i)
      if (code < 0x20 || code === 0x7f || (code >= 0x80 && code <= 0x9f)) continue
      if (digitsOnly && (code < 0x30 || code > 0x39)) continue
      out += value.charAt(i)
    }
    return out
  }

  function _replaceSelection(replacement) {
    var insert = _sanitize(replacement)
    if (insert.length === 0 && !_hasSelection) return
    var start = _selStart
    var end = _selEnd
    var next = String(text.substring(0, start) + insert + text.substring(end))
    if (next.length > maxLength) next = next.substring(0, maxLength)
    _internalEdit = true
    text = next
    _internalEdit = false
    _cursor = Math.min(start + insert.length, next.length)
    _anchor = _cursor
    _cursorVisible = true
  }

  function _deleteSelection() {
    if (!_hasSelection) return false
    var start = _selStart
    var end = _selEnd
    _internalEdit = true
    text = text.substring(0, start) + text.substring(end)
    _internalEdit = false
    _cursor = start
    _anchor = start
    _cursorVisible = true
    return true
  }

  function _moveCursor(position, extend) {
    var p = Math.max(0, Math.min(text.length, position))
    if (extend) {
      if (_anchor === _cursor) _anchor = _cursor
      _cursor = p
    } else {
      _cursor = p
      _anchor = p
    }
    _cursorVisible = true
  }

  function _selectAll() {
    _anchor = 0
    _cursor = text.length
    _cursorVisible = true
  }

  // selection is "clipboard" or "primary" (middle-click selection).
  function _paste(selection) {
    if (!enabled || pasteProc.running) return
    pasteProc.selection = selection
    pasteProc.running = true
  }

  Keys.onPressed: function(event) {
    if (!enabled) return

    // Leave Escape to the owner (cancel password entry / close panel).
    if (event.key === Qt.Key_Escape) return

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.accepted()
      event.accepted = true
      return
    }

    var ctrl = !!(event.modifiers & Qt.ControlModifier)
    var shift = !!(event.modifiers & Qt.ShiftModifier)

    if (ctrl && event.key === Qt.Key_A) {
      root._selectAll()
      event.accepted = true
      return
    }

    if (ctrl && event.key === Qt.Key_U) {
      root._selectAll()
      root._replaceSelection("")
      event.accepted = true
      return
    }

    // Ctrl+V, Shift+Insert, and the platform paste shortcut all use the
    // same bounded helper. Ctrl+Shift+V (paste plain) is covered by the
    // explicit Ctrl+V check.
    var paste = event.matches(StandardKey.Paste)
      || (ctrl && event.key === Qt.Key_V)
      || (shift && event.key === Qt.Key_Insert)
    if (paste) {
      root._paste("clipboard")
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Backspace) {
      if (!root._deleteSelection() && root._cursor > 0) {
        root._internalEdit = true
        root.text = root.text.substring(0, root._cursor - 1) + root.text.substring(root._cursor)
        root._internalEdit = false
        root._cursor -= 1
        root._anchor = root._cursor
        root._cursorVisible = true
      }
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Delete) {
      if (!root._deleteSelection() && root._cursor < root.text.length) {
        root._internalEdit = true
        root.text = root.text.substring(0, root._cursor) + root.text.substring(root._cursor + 1)
        root._internalEdit = false
        root._anchor = root._cursor
        root._cursorVisible = true
      }
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Left) {
      if (!shift && root._hasSelection) root._moveCursor(root._selStart, false)
      else root._moveCursor(root._cursor - 1, shift)
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Right) {
      if (!shift && root._hasSelection) root._moveCursor(root._selEnd, false)
      else root._moveCursor(root._cursor + 1, shift)
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_Home) {
      root._moveCursor(0, shift)
      event.accepted = true
      return
    }

    if (event.key === Qt.Key_End) {
      root._moveCursor(root.text.length, shift)
      event.accepted = true
      return
    }

    // Printable text. Ctrl and Meta combinations are shortcuts, not input.
    // Alt is allowed so AltGr-produced characters still work.
    if (event.text.length > 0 && !ctrl && !(event.modifiers & Qt.MetaModifier)) {
      var printable = root._sanitize(event.text)
      if (printable.length > 0) root._replaceSelection(printable)
      event.accepted = true
      return
    }
  }

  Timer {
    interval: 530
    repeat: true
    running: root.activeFocus && root.enabled
    onTriggered: root._cursorVisible = !root._cursorVisible
  }

  MouseArea {
    id: hoverArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    cursorShape: Qt.IBeamCursor
    onClicked: function(mouse) {
      if (!root.enabled) return
      root.forceActiveFocus()
      if (mouse.button === Qt.MiddleButton) root._paste("primary")
      else root._moveCursor(root.text.length, false)
    }
    onDoubleClicked: {
      if (!root.enabled) return
      root.forceActiveFocus()
      root._selectAll()
    }
  }

  Rectangle {
    anchors.fill: parent
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    radius: Style.cornerRadius
    border.width: root._borderWidth
    border.color: root._borderColor
  }

  FontMetrics {
    id: fontMetrics
    font: root.font
  }

  // Prefix widths for the cursor and selection rectangles in display text.
  TextMetrics {
    id: cursorMetrics
    font: root.font
    text: root._displayText.substring(0, root._cursor)
  }
  TextMetrics {
    id: selStartMetrics
    font: root.font
    text: root._displayText.substring(0, root._selStart)
  }
  TextMetrics {
    id: selEndMetrics
    font: root.font
    text: root._displayText.substring(0, root._selEnd)
  }

  Item {
    id: content
    anchors.fill: parent
    anchors.leftMargin: root.leftPadding
    anchors.rightMargin: root.rightPadding
    clip: true

    Rectangle {
      visible: root._hasSelection
      x: -root._scrollOffset + selStartMetrics.advanceWidth
      width: Math.max(0, selEndMetrics.advanceWidth - selStartMetrics.advanceWidth)
      height: fontMetrics.height
      anchors.verticalCenter: parent.verticalCenter
      color: root.selectionTint
    }

    Text {
      id: textItem
      x: -root._scrollOffset
      anchors.verticalCenter: parent.verticalCenter
      visible: root.text.length > 0
      text: root._displayText
      textFormat: Text.PlainText
      color: root.foreground
      font: root.font
    }

    Text {
      visible: root.text.length === 0
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      text: root.placeholderText
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Qt.darker(root.foreground, 1.6)
      font: root.font
    }

    Rectangle {
      visible: root.activeFocus && root._cursorVisible && root.enabled
      x: -root._scrollOffset + cursorMetrics.advanceWidth
      width: 1
      height: fontMetrics.height
      anchors.verticalCenter: parent.verticalCenter
      color: root.foreground
    }
  }

  // The helper enforces a 4096-byte output cap and a 2-second deadline on
  // wl-paste before any text reaches this process.
  Process {
    id: pasteProc
    property string selection: "clipboard"
    command: [
      root.scriptDir + "/bin/clipboard-paste",
      "4096",
      "2",
      selection
    ]
    stdout: StdioCollector {
      id: pasteOut
      waitForEnd: true
      onStreamFinished: root._replaceSelection(pasteOut.text)
    }
  }
}