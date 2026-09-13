// Notification center — the bar-widget entry point of this plugin.
//
// A bell in the bar opens a panel listing the archived notification history
// (the same per-file store under ~/.local/state/omarchy/notifications/history/
// that the toast replay reads). Entries stay until removed by hand: the ✕ on
// a card deletes that entry, "Clear all" empties the store. The list model
// lives on the Service so every monitor's panel shows the same rows.
//
// Left-click the bell: open/close the panel. Right-click: toggle DND.

import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui
import "components"

Panel {
  id: root
  moduleName: "thetxeagle.notifications"
  ipcTarget: "notification-center"

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("thetxeagle.notifications") : null
  readonly property bool dnd: service ? service.doNotDisturb : false
  readonly property int historyCount: service && service.historyModel ? service.historyModel.count : 0

  // The widget's shell.json bar entry is the user's config surface: set
  // "historyLimit" on it to change how much history the daemon keeps —
  //   { "id": "thetxeagle.notifications", "historyLimit": 50 }
  // Defaults to the stock 10. Pushed to the service rather than bound,
  // because the service owns the on-disk trim and must keep a sane default
  // when the bell isn't in the bar.
  readonly property int configuredHistoryLimit: {
    var v = settings ? Number(settings.historyLimit) : NaN
    return isFinite(v) && v >= 1 ? Math.min(1000, Math.round(v)) : 10
  }
  onConfiguredHistoryLimitChanged: pushHistoryLimit()
  onServiceChanged: pushHistoryLimit()
  Component.onCompleted: pushHistoryLimit()

  function pushHistoryLimit() {
    if (service && service.historyLimit !== configuredHistoryLimit)
      service.historyLimit = configuredHistoryLimit
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function timeLabel(ts) {
    var t = Number(ts || 0)
    if (!t) return ""
    var d = new Date(t)
    var now = new Date()
    if (d.toDateString() === now.toDateString()) return Qt.formatTime(d, "hh:mm")
    if (now.getTime() - t < 6 * 86400000) return Qt.formatDateTime(d, "ddd hh:mm")
    return Qt.formatDate(d, "d MMM")
  }

  // The model is filled lazily: read the directory when the panel opens, and
  // re-read (debounced) while it stays open and new entries get archived.
  onOpenedChanged: if (opened && service) service.refreshHistoryModel()

  Connections {
    target: root.service
    enabled: root.service !== null
    function onHistoryMutated() {
      if (root.opened) refreshDebounce.restart()
    }
  }

  Timer {
    id: refreshDebounce
    interval: 250
    repeat: false
    onTriggered: if (root.opened && root.service) root.service.refreshHistoryModel()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.dnd ? "󰂛" : "󰂚"
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.setDoNotDisturb(!root.dnd)
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + Style.space(10)
        + (root.historyCount > 0 ? list.contentHeight : empty.implicitHeight + Style.space(20)),
      Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        implicitHeight: Math.max(headerTitle.implicitHeight, clearAllButton.implicitHeight)

        Text {
          id: headerTitle
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Notifications"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Button {
          id: clearAllButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: root.historyCount > 0
          text: "Clear all"
          fontSize: Style.font.bodySmall
          foreground: root.bar ? root.bar.foreground : Color.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          bordered: true
          onClicked: if (root.service) root.service.clearHistory()
        }
      }

      Text {
        id: empty
        anchors.top: header.bottom
        anchors.topMargin: Style.space(20)
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.historyCount === 0
        text: "No notifications"
        color: root.bar ? Qt.darker(root.bar.foreground, 1.5) : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      ListView {
        id: list
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.historyCount > 0
        clip: true
        spacing: Style.space(8)
        model: root.service ? root.service.historyModel : null
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Item {
          id: rowSlot
          required property int index
          required property string app
          required property string appIcon
          required property string summary
          required property string body
          required property string image
          required property string glyph
          required property int urgency
          required property double timestamp
          required property int originalId

          width: ListView.view.width
          implicitHeight: card.implicitHeight

          NotificationCard {
            id: card
            width: parent.width
            app: rowSlot.app
            appIcon: rowSlot.appIcon
            summary: rowSlot.summary
            body: rowSlot.body
            image: rowSlot.image
            glyph: rowSlot.glyph
            urgency: rowSlot.urgency
            timestamp: rowSlot.timestamp
            cornerRadius: root.service ? root.service.cornerRadius : Style.cornerRadius
            fontFamily: root.bar ? root.bar.fontFamily : ""

            // ✕ deletes this entry from history (file + image copies + row).
            onCloseRequested: if (root.service) root.service.deleteHistoryEntry(rowSlot.timestamp, rowSlot.originalId)
            // Click = act on the notification: jump to the sender's window,
            // relaunching the app if it's gone. The entry leaves history only
            // when that worked — clearing a notification whose action failed
            // would swallow it silently. Identity is captured up front: the
            // delegate can be recycled before the async focus/launch answers.
            onCardClicked: {
              if (!root.service) return
              var ts = rowSlot.timestamp
              var oid = rowSlot.originalId
              root.service.focusApp({ app: rowSlot.app, appIcon: rowSlot.appIcon }, function(handled) {
                if (!handled || !root.service) return
                root.service.deleteHistoryEntry(ts, oid)
                root.close()
              })
            }
          }

          // Quiet received-at label. It sits where the card's hover ✕
          // appears, so it yields while the card is hovered.
          Text {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: card.borderTop + Style.space(6)
            anchors.rightMargin: card.borderRight + Style.space(10)
            visible: !card.hovered
            text: root.timeLabel(rowSlot.timestamp)
            color: Qt.darker(Color.notifications.text, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
