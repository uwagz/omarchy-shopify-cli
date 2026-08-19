import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "uwagz.shopify-cli"
  ipcTarget: "uwagz.shopify-cli"
  manageIpc: false

  property string focusSection: "header"
  property int sessionIndex: 0
  property bool cursorActive: false
  property bool menuOpen: false
  property double nowMs: Date.now()
  property int phraseIndex: 0
  readonly property var activePhrases: [
    "Syncing sections",
    "Pushing pixels",
    "Hot-reloading Liquid",
    "Rendering snippets",
    "Watching assets",
    "Serving storefronts",
    "Bundling blocks",
    "Polishing themes",
    "Tunneling apps",
    "Compiling templates"
  ]
  readonly property string heroPhraseText: activePhrases[phraseIndex % activePhrases.length]

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color iconColor: shopify.active ? foreground : dim
  readonly property color barIconColor: shopify.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property color barSurface: bar ? bar.background : Color.bar.background
  readonly property bool showSessions: shopify.installed && shopify.sessions.length > 0
  readonly property bool showBarLabel: shopify.showLabel && shopify.barLabel !== "" && !(bar && bar.vertical)
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property string heroMeta: {
    if (!shopify.installed) return "Shopify CLI not installed"
    if (!shopify.everPolled) return "Checking for sessions"
    if (shopify.active) return heroPhraseText
    return "No dev sessions running"
  }

  function selectedSession() {
    if (shopify.sessions.length === 0) return null
    return shopify.sessions[Math.max(0, Math.min(sessionIndex, shopify.sessions.length - 1))]
  }

  // Running times are derived from each session's startedTs and this clock,
  // so the session objects themselves never change between polls.
  readonly property int nowSec: Math.floor(nowMs / 1000)
  // Tick every second only while a session is under a minute old (the label
  // shows seconds); after that the label is in minutes, so 30s is plenty.
  readonly property bool hasYoungSession: {
    for (var i = 0; i < shopify.sessions.length; i++) {
      if (Model.elapsedSeconds(shopify.sessions[i], nowSec) < 60) return true
    }
    return false
  }

  function ensureCursor() {
    if (sessionIndex < 0) sessionIndex = 0
    if (sessionIndex >= shopify.sessions.length) sessionIndex = Math.max(0, shopify.sessions.length - 1)
    if (focusSection === "sessions" && !showSessions) focusSection = "header"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy !== 0) {
      if (focusSection === "header") {
        if (dy > 0 && showSessions) { focusSection = "sessions"; sessionIndex = 0 }
      } else if (focusSection === "sessions") {
        if (dy < 0) {
          if (sessionIndex <= 0) focusSection = "header"
          else sessionIndex--
        } else if (sessionIndex < shopify.sessions.length - 1) {
          sessionIndex++
        }
      }
    } else if (dx !== 0 && focusSection === "sessions") {
      // Right opens the link menu on the row, left closes whatever is open.
      var row = selectedRow()
      if (row) {
        if (dx > 0) row.openLinkMenu()
        else row.closeMenus()
      }
    }
    ensureCursor()
    scrollCursorIntoView()
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "header") shopify.refresh()
    else if (focusSection === "sessions") shopify.openSession(selectedSession())
  }

  function selectedRow() {
    if (!sessionColumn || sessionIndex < 0 || sessionIndex >= sessionColumn.children.length) return null
    return sessionColumn.children[sessionIndex]
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "sessions") scrollItemIntoView(selectedRow())
  }

  function setSessionCursor(index) {
    cursorActive = true
    focusSection = "sessions"
    sessionIndex = index
    scrollCursorIntoView()
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    if (panelFlick) panelFlick.contentY = 0
  }

  function stopSelectedSession() {
    var session = selectedSession()
    if (session && focusSection === "sessions") shopify.stopSession(session)
  }

  // Nothing running and the user asked for a quiet bar: Bar.qml collapses a
  // slot whose item is invisible, so the icon returns the moment a session
  // starts (the service keeps polling regardless).
  visible: shopify.showWhenIdle || shopify.active
  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    shopify.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onSessionIndexChanged: scrollCursorIntoView()
  onShowSessionsChanged: ensureCursor()

  Service {
    id: shopify
    settings: root.settings
    panelOpen: root.opened
  }

  Connections {
    target: shopify
    function onSessionsChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { shopify.refresh(); return "ok" }
    function status(): string { return shopify.statusText }
    function sessions(): string { return JSON.stringify(shopify.sessions) }
    function count(): string { return String(shopify.sessionCount) }
    function config(): string { return JSON.stringify({ settings: root.settings, fetchDetails: shopify.fetchDetails, refreshIntervalSec: shopify.refreshIntervalSec, showWhenIdle: shopify.showWhenIdle, showLabel: shopify.showLabel }) }
  }

  Row {
    id: barRow
    anchors.fill: parent
    spacing: 0

    BarIconButton {
      id: button
      bar: root.bar
      tooltipText: root.opened ? "" : shopify.tooltipText
      iconComponent: Component {
        Item {
          ShopifyIcon {
            anchors.centerIn: parent
            iconSize: Style.space(14)
            color: root.barIconColor
            innerColor: root.barSurface
            badgeText: shopify.sessionCount > 1 ? String(shopify.sessionCount) : ""
          }
        }
      }
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.RightButton) shopify.openSession(shopify.sessions.length > 0 ? shopify.sessions[0] : null)
        else if (buttonCode === Qt.MiddleButton) shopify.refresh()
        else root.toggle()
      }
    }

    WidgetButton {
      id: labelButton
      visible: root.showBarLabel
      bar: root.bar
      text: shopify.barLabel
      tooltipText: root.opened ? "" : shopify.tooltipText
      horizontalMargin: 4
      onPressed: function(buttonCode) { button.pressed(buttonCode) }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.menuOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onDeleteRequested: root.stopSelectedSession()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var session = root.selectedSession()
        // t / e / p mirror the hint line `shopify theme dev` prints.
        if (t === "r" || t === "R") shopify.refresh()
        else if (t === "t" || t === "T") shopify.openPreview(session)
        else if (t === "e" || t === "E") shopify.openEditor(session)
        else if (t === "p" || t === "P") shopify.openSharePreview(session)
        else if (t === "g" || t === "G") shopify.openGraphiql(session)
        else if (t === "o" || t === "O") shopify.openSession(session)
        else if (t === "a" || t === "A") shopify.openAdmin(session)
        else if (t === "s" || t === "S") shopify.openStorefront(session)
        else if (t === "c" || t === "C") { var row = root.selectedRow(); if (row) row.openCopyMenu() }
        else if (t === "f" || t === "F") shopify.revealProject(session)
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

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero (not this Panel) — reach panel state via `header`.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setHeaderCursor() }

            PanelHero {
              id: hero
              width: parent.width
              // Version trails the title muted and a step smaller. PanelHero's
              // title Text is AutoText, so a <font> tag switches it to styled
              // text without touching the shared component.
              title: shopify.cliVersion !== ""
                ? "Shopify CLI <font color=\"" + String(root.dim) + "\" size=\"-1\">" + shopify.cliVersion.replace(/[^0-9A-Za-z.\-+]/g, "") + "</font>"
                : "Shopify CLI"
              meta: root.heroMeta
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: shopify.active ? 1.0 : 0.5
              iconComponent: Component {
                ShopifyIcon {
                  iconSize: Style.font.display
                  color: root.iconColor
                  innerColor: Color.popups.background
                }
              }

              // Refresh on the trailing edge: the header's only cursor target.
              trailingControl: Component {
                PanelActionButton {
                  id: refreshButton
                  iconText: "󰑐"
                  tooltipText: "Refresh"
                  foreground: hero.foreground
                  fontFamily: hero.fontFamily
                  hasCursor: header.ringVisible
                  enabled: !shopify.busy
                  onHovered: function(on) { if (on) header.focusHero() }
                  onClicked: shopify.refresh()
                }
              }
            }
          }

          Text {
            visible: shopify.actionStatus !== "" || shopify.lastError !== ""
            width: parent.width
            text: shopify.actionStatus !== "" ? shopify.actionStatus : shopify.lastError
            color: shopify.lastError !== "" && shopify.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          CursorSurface {
            visible: !shopify.installed
            width: parent.width
            implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground

            Text {
              id: missingText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12)
              text: "Shopify CLI is not installed or not on PATH. Install it with `npm install -g @shopify/cli`."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator {
            visible: shopify.installed
            foreground: root.foreground
          }

          Column {
            visible: shopify.installed
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DEV SESSIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: !root.showSessions
              width: parent.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: "No theme or app dev sessions running."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignLeft
              }

              Text {
                width: parent.width
                text: "Start one with `shopify theme dev` or `shopify app dev`."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignLeft
                wrapMode: Text.WordWrap
              }
            }

            Column {
              id: sessionColumn
              visible: root.showSessions
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: shopify.sessions
                SessionRow {
                  required property var modelData
                  required property int index
                  width: sessionColumn.width
                  session: modelData
                  rowIndex: index
                }
              }
            }
          }
        }
      }
    }
  }

  Timer {
    id: clockTimer
    interval: root.hasYoungSession ? 1000 : 30000
    running: root.opened && shopify.active
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && shopify.active
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.activePhrases.length
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  component SessionRow: CursorSurface {
    id: sessionRow
    property var session: null
    property int rowIndex: 0
    readonly property string title: Model.sessionTitle(session)
    readonly property string meta: Model.sessionMeta(session, root.nowSec)
    readonly property string hint: Model.sessionDetailHint(session)
    readonly property string primaryUrl: Model.primaryUrl(session)
    readonly property bool stopping: session && shopify.stoppingId === String(session.id || "")
    readonly property var linkOptions: Model.linkOptions(session)
    readonly property var copyOptions: Model.copyOptions(session)
    property int menuIndex: 0

    hasCursor: root.cursorActive && root.focusSection === "sessions" && root.sessionIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: Math.max(sessionContent.implicitHeight, stopButton.implicitHeight) + Style.spacing.rowPaddingX

    function openLinkMenu() {
      if (linkOptions.length === 0) return
      copyPopup.close()
      menuIndex = 0
      linkPopup.open()
    }

    function openCopyMenu() {
      if (copyOptions.length === 0) return
      linkPopup.close()
      menuIndex = 0
      copyPopup.open()
    }

    function closeMenus() {
      linkPopup.close()
      copyPopup.close()
    }

    function moveMenuCursor(delta, count) {
      if (count === 0) return
      menuIndex = Math.max(0, Math.min(count - 1, menuIndex + delta))
    }

    function chooseLink(index) {
      if (index < 0 || index >= linkOptions.length) return
      shopify.runLinkOption(session, linkOptions[index])
      linkPopup.close()
    }

    function chooseCopy(index) {
      if (index < 0 || index >= copyOptions.length) return
      shopify.copyToClipboard(copyOptions[index].value, copyOptions[index].label)
      copyPopup.close()
    }

    function handleMenuKey(event, count, choose, popup) {
      if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left || event.text === "h") {
        popup.close(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Down || event.text === "j") {
        moveMenuCursor(1, count); event.accepted = true; return
      }
      if (event.key === Qt.Key_Up || event.text === "k") {
        moveMenuCursor(-1, count); event.accepted = true; return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        choose(menuIndex); event.accepted = true
      }
    }

    // Set while the pointer is over one of the action buttons, so the row's
    // own tooltip yields to the button's.
    property int actionHoverCount: 0
    function trackActionHover(on) { actionHoverCount = Math.max(0, actionHoverCount + (on ? 1 : -1)) }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      hoverEnabled: true
      cursorShape: sessionRow.primaryUrl !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.setSessionCursor(sessionRow.rowIndex)
      onClicked: shopify.openSession(sessionRow.session)
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && sessionRow.actionHoverCount === 0 && sessionRow.primaryUrl !== "" && !root.menuOpen
      text: Model.primaryHint(sessionRow.session)
      fontFamily: root.fontFamily
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        text: Model.kindGlyph(sessionRow.session ? sessionRow.session.kind : "")
        color: sessionRow.stopping ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
        opacity: sessionRow.stopping ? 0.45 : 1.0

        SequentialAnimation on opacity {
          running: sessionRow.stopping
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      ColumnLayout {
        id: sessionContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        // Title followed by a small, quiet kind tag ("theme" / "app") that
        // trails the text rather than floating at the far edge of the row.
        Row {
          id: titleRow
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            id: titleText
            width: Math.min(implicitWidth, Math.max(0, titleRow.width - kindTag.implicitWidth - titleRow.spacing))
            text: sessionRow.title
          textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Text {
            id: kindTag
            anchors.baseline: titleText.baseline
            text: Model.kindLabel(sessionRow.session ? sessionRow.session.kind : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.85
          }
        }

        Text {
          Layout.fillWidth: true
          text: sessionRow.stopping ? "Stopping…" : sessionRow.meta
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: sessionRow.hint !== "" && !sessionRow.stopping
          text: sessionRow.hint
          textFormat: Text.PlainText
          color: sessionRow.session && sessionRow.session.detailsState === "error" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          opacity: 0.85
        }
      }

      PanelActionButton {
        id: linkButton
        onHovered: function(on) { sessionRow.trackActionHover(on) }
        iconText: "󰖟"
        tooltipText: "Open…"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: sessionRow.linkOptions.length > 0
        Layout.alignment: Qt.AlignVCenter
        onClicked: sessionRow.openLinkMenu()
      }

      PanelActionButton {
        id: copyButton
        onHovered: function(on) { sessionRow.trackActionHover(on) }
        iconText: "󰆏"
        tooltipText: "Copy…"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: sessionRow.copyOptions.length > 0
        Layout.alignment: Qt.AlignVCenter
        onClicked: sessionRow.openCopyMenu()
      }

      PanelActionButton {
        id: stopButton
        onHovered: function(on) { sessionRow.trackActionHover(on) }
        iconText: "󰓛"
        tooltipText: "Stop session"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        enabled: !sessionRow.stopping
        Layout.alignment: Qt.AlignVCenter
        onClicked: shopify.stopSession(sessionRow.session)
      }

      Popup {
        id: linkPopup
        x: linkButton.x + linkButton.width - width
        y: linkButton.y + linkButton.height + Style.space(4)
        width: Style.space(280)
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpenedChanged: {
          root.menuOpen = opened || copyPopup.opened
          if (opened) Qt.callLater(function() { linkPopupContent.forceActiveFocus() })
          else if (root.opened && !copyPopup.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
        background: BorderSurface {
          color: Color.popups.background
          borderSpec: Border.flat(root.dim, 1)
          radius: Style.cornerRadius
        }
        contentItem: Column {
          id: linkPopupContent
          width: parent.width
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            sessionRow.handleMenuKey(event, sessionRow.linkOptions.length, sessionRow.chooseLink, linkPopup)
          }

          Repeater {
            model: sessionRow.linkOptions
            MenuChoice {
              required property var modelData
              required property int index
              width: parent.width
              label: String(modelData.label || "")
              detail: String(modelData.url || (modelData.action ? "opens a terminal" : ""))
              glyph: modelData.action ? "󰆍" : "󰏌"
              selected: sessionRow.menuIndex === index
              onHovered: sessionRow.menuIndex = index
              onChosen: sessionRow.chooseLink(index)
            }
          }
        }
      }

      Popup {
        id: copyPopup
        x: copyButton.x + copyButton.width - width
        y: copyButton.y + copyButton.height + Style.space(4)
        width: Style.space(280)
        padding: 0
        modal: false
        focus: true
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        onOpenedChanged: {
          root.menuOpen = opened || linkPopup.opened
          if (opened) Qt.callLater(function() { copyPopupContent.forceActiveFocus() })
          else if (root.opened && !linkPopup.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
        background: BorderSurface {
          color: Color.popups.background
          borderSpec: Border.flat(root.dim, 1)
          radius: Style.cornerRadius
        }
        contentItem: Column {
          id: copyPopupContent
          width: parent.width
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            sessionRow.handleMenuKey(event, sessionRow.copyOptions.length, sessionRow.chooseCopy, copyPopup)
          }

          Repeater {
            model: sessionRow.copyOptions
            MenuChoice {
              required property var modelData
              required property int index
              width: parent.width
              label: String(modelData.label || "")
              detail: String(modelData.value || "")
              glyph: "󰆏"
              selected: sessionRow.menuIndex === index
              onHovered: sessionRow.menuIndex = index
              onChosen: sessionRow.chooseCopy(index)
            }
          }
        }
      }
    }
  }

  component MenuChoice: CursorSurface {
    id: menuChoice
    signal chosen()
    signal hovered()
    property string label: ""
    property string detail: ""
    property string glyph: ""
    property bool selected: false

    foreground: root.foreground
    hasCursor: selected
    implicitHeight: Style.space(48)
    radius: 0

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: menuChoice.hovered()
      onClicked: menuChoice.chosen()
    }

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(10)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: menuChoice.label
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: menuChoice.detail !== ""
          text: menuChoice.detail
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideMiddle
        }
      }

      Text {
        text: menuChoice.glyph
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
