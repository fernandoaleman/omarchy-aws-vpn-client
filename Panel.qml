import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// AWS Client VPN widget: connection state in the bar, and a panel for
// picking a profile, connecting through SAML/SSO, and importing .ovpn files.
Panel {
  id: root
  moduleName: "fernandoaleman.aws-vpn-client"
  ipcTarget: "fernandoaleman.aws-vpn-client"
  manageIpc: false

  property int cursor: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Bar glyph tells the state apart at a glance rather than by colour alone,
  // which a theme is free to flatten.
  readonly property string stateGlyph: {
    if (vpn.daemonDown) return "󰀦"
    if (vpn.state === "error") return "󰀦"
    if (vpn.connected) return "󰦝"
    if (vpn.awaitingLogin) return "󰌆"
    if (vpn.transitioning) return "󰔟"
    return "󰖂"
  }
  readonly property color barIconColor: vpn.connected
    ? barForeground
    : (vpn.state === "error" || vpn.daemonDown)
      ? (bar ? bar.urgent : Color.urgent)
      : Qt.darker(barForeground, 1.55)

  // Flat cursor model over everything selectable, so j/k walks the panel in
  // visual order without each section tracking its own index.
  readonly property var rows: {
    var out = []
    if (vpn.daemonDown) {
      out.push({ kind: "daemon" })
      return out
    }
    if (vpn.connected || vpn.transitioning) out.push({ kind: "disconnect" })
    for (var i = 0; i < vpn.profiles.length; i++) {
      out.push({
        kind: "profile",
        sectionHeader: i === 0 ? "PROFILES" : "",
        name: String(vpn.profiles[i].name || ""),
        endpoint: String(vpn.profiles[i].endpoint || ""),
      })
    }
    for (var j = 0; j < vpn.discovered.length; j++) {
      out.push({
        kind: "import",
        sectionHeader: j === 0 ? "IMPORT" : "",
        name: String(vpn.discovered[j].name || ""),
        dir: String(vpn.discovered[j].dir || ""),
        path: String(vpn.discovered[j].path || ""),
      })
    }
    return out
  }

  function clampCursor() {
    if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)
    if (cursor < 0) cursor = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0 || rows.length === 0) return
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + dy))
    scrollCursorIntoView()
  }

  function activateCursor() {
    if (rows.length === 0) return
    clampCursor()
    var row = rows[cursor]
    if (!row) return
    if (row.kind === "daemon") vpn.startDaemon()
    else if (row.kind === "disconnect") vpn.disconnect()
    else if (row.kind === "profile") activateProfile(row.name)
    else if (row.kind === "import") vpn.addProfile(row.path)
  }

  function activateProfile(name) {
    if (vpn.connected && vpn.activeProfile === name) vpn.disconnect()
    else if (vpn.connected || vpn.transitioning) return
    else vpn.connectTo(name)
  }

  function setCursor(index) {
    cursorActive = true
    cursor = index
  }

  function scrollCursorIntoView() {
    Qt.callLater(function () {
      if (!panelFlick || !rowColumn) return
      if (cursor < 0 || cursor >= rowColumn.children.length) return
      var item = rowColumn.children[cursor]
      if (!item || !item.mapToItem) return
      var margin = Style.space(6)
      var top = item.mapToItem(panelFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    if (panelFlick) panelFlick.contentY = 0
    vpn.refreshAll()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: vpn
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refreshAll(); return "ok" }
    function connect(): string { vpn.connectTo(vpn.defaultProfile || ""); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function status(): string { return vpn.label }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: root.stateGlyph
          color: root.barIconColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          // Breathe while the tunnel is coming up or SSO is pending.
          SequentialAnimation on opacity {
            running: vpn.transitioning
            loops: Animation.Infinite
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
          opacity: vpn.connected ? 1.0 : 0.75
        }
      }
    }
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleConnection()
      else if (buttonCode === Qt.MiddleButton) vpn.refreshAll()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var k = String(t || "").toLowerCase()
        if (k === "r") vpn.refreshAll()
        else if (k === "d") vpn.disconnect()
        else if (k === "c") vpn.connectTo(vpn.defaultProfile || "")
        else if (k === "s" && root.cursorActive) {
          var row = root.rows[root.cursor]
          if (row && row.kind === "profile") vpn.setDefaultProfile(row.name)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "AWS VPN"
            meta: vpn.activeProfile !== "" && vpn.connected
              ? vpn.label + " · " + vpn.activeProfile
              : vpn.label
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: vpn.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: root.stateGlyph
                color: vpn.connected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: !vpn.daemonDown
                checked: vpn.connected || vpn.transitioning
                busy: vpn.transitioning || vpn.busy
                foreground: hero.foreground
                onToggled: vpn.toggleConnection()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: vpn.connected || vpn.transitioning
                    ? "Disconnect"
                    : "Connect to " + (vpn.defaultProfile || "default profile")
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          // Tunnel details, only once there is a tunnel.
          Column {
            visible: vpn.connected && (vpn.assignedIp !== "" || vpn.serverIp !== "")
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair {
              visible: vpn.assignedIp !== ""
              label: "Tunnel IP"
              value: vpn.assignedIp
            }
            InfoPair {
              visible: vpn.serverIp !== ""
              label: "Server"
              value: vpn.serverIp
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: vpn.awaitingLogin
              ? "Finish the SSO login in your browser."
              : (vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError)
            color: vpn.lastError !== "" && vpn.actionStatus === "" && !vpn.awaitingLogin
              ? root.urgent
              : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // Everything selectable lives in one column so the flat cursor
          // index lines up with child order for scroll-into-view.
          Column {
            id: rowColumn
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.rows
              // Each entry carries its own section heading so the flat cursor
              // index still lines up 1:1 with this column's children.
              Column {
                id: rowWrapper
                required property var modelData
                required property int index
                width: rowColumn.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  visible: String(rowWrapper.modelData.sectionHeader || "") !== ""
                  width: parent.width
                  text: String(rowWrapper.modelData.sectionHeader || "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Loader {
                  width: parent.width
                  sourceComponent: rowWrapper.modelData.kind === "daemon" ? daemonRow
                    : rowWrapper.modelData.kind === "disconnect" ? disconnectRow
                    : rowWrapper.modelData.kind === "profile" ? profileRow
                    : importRow
                  onLoaded: {
                    item.rowIndex = rowWrapper.index
                    item.rowData = rowWrapper.modelData
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !vpn.daemonDown && vpn.profiles.length === 0 && vpn.discovered.length === 0
            width: parent.width
            text: "No profiles yet.\nDrop an .ovpn file in ~/Downloads, or run:\nomarchy-aws-vpn-client add <file.ovpn>"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

        }
      }
    }
  }

  // ---------------------------------------------------------------- rows

  Component {
    id: profileRow
    ActionRow {
      readonly property string profileName: rowData ? String(rowData.name || "") : ""
      readonly property bool isActive: vpn.connected && vpn.activeProfile === profileName
      readonly property bool isDefault: vpn.defaultProfile === profileName

      glyph: isActive ? "󰦝" : "󰖂"
      title: profileName + (isDefault ? "  ·  default" : "")
      subtitle: rowData && rowData.endpoint
        ? String(rowData.endpoint)
        : "AWS Client VPN profile"
      accent: isActive
      trailingGlyph: isActive ? "󰅖" : "󰐊"
      trailingHint: isActive ? "Disconnect" : "Connect via SSO"
      enabledRow: isActive || !(vpn.connected || vpn.transitioning)
      onActivated: root.activateProfile(profileName)
    }
  }

  Component {
    id: importRow
    ActionRow {
      glyph: "󰈔"
      title: rowData ? String(rowData.name || "") : ""
      subtitle: "Import from " + (rowData ? String(rowData.dir || "") : "")
      trailingGlyph: "󰐕"
      trailingHint: "Add as profile"
      onActivated: vpn.addProfile(rowData ? String(rowData.path || "") : "")
    }
  }

  Component {
    id: disconnectRow
    ActionRow {
      glyph: "󰅖"
      title: vpn.transitioning ? "Cancel" : "Disconnect"
      subtitle: vpn.activeProfile !== "" ? vpn.activeProfile : "Active connection"
      accent: true
      trailingGlyph: "󰅖"
      trailingHint: "Disconnect"
      onActivated: vpn.disconnect()
    }
  }

  Component {
    id: daemonRow
    ActionRow {
      glyph: "󰀦"
      title: "VPN daemon is not running"
      subtitle: "Start openlawsvpn-daemon to connect"
      accent: true
      trailingGlyph: "󰐊"
      trailingHint: "Start daemon"
      onActivated: vpn.startDaemon()
    }
  }

  // A single selectable row: glyph, two lines of text, trailing action button.
  component ActionRow: CursorSurface {
    id: actionRow

    property int rowIndex: 0
    property var rowData: null
    property string glyph: ""
    property string title: ""
    property string subtitle: ""
    property string trailingGlyph: ""
    property string trailingHint: ""
    property bool accent: false
    property bool enabledRow: true

    signal activated()

    hasCursor: root.cursorActive && root.cursor === rowIndex
    foreground: root.foreground
    opacity: enabledRow ? 1.0 : 0.45
    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: actionRow.enabledRow ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: actionRow.enabledRow && !vpn.busy
      onEntered: root.setCursor(actionRow.rowIndex)
      onClicked: actionRow.activated()
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: actionRow.glyph
        color: actionRow.accent ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: actionRow.title
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: actionRow.subtitle !== ""
          text: actionRow.subtitle
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: trailingButton
        visible: actionRow.trailingGlyph !== ""
        iconText: actionRow.trailingGlyph
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: actionRow.enabledRow && !vpn.busy
        tooltipText: actionRow.trailingHint
        Layout.alignment: Qt.AlignVCenter
        onClicked: actionRow.activated()
      }
    }
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Item { Layout.fillWidth: true; implicitHeight: 1 }
    Text {
      textFormat: Text.PlainText
      text: value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
