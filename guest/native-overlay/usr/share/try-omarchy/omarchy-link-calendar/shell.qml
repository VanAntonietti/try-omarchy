import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var snapshot: ({calendars: [], events: []})
  property string selectedRange: "today"
  property string selectedCalendar: ""
  property string failure: "Loading Calendar…"

  function clearAndClose() {
    root.snapshot = ({calendars: [], events: []})
    window.visible = false
    Qt.quit()
  }
  function select() {
    root.snapshot = ({calendars: [], events: []})
    root.failure = "Loading Calendar…"
    bridge.write(JSON.stringify({range: root.selectedRange, calendar: root.selectedCalendar}) + "\n")
  }
  function accept(data) {
    try {
      var value = JSON.parse(data)
      if (value.closed) { root.clearAndClose(); return }
      root.snapshot = {calendars: value.calendars || [], events: value.error ? [] : (value.events || [])}
      root.failure = value.error || ""
    } catch (_) { root.clearAndClose() }
  }

  Process {
    id: bridge
    command: ["/usr/bin/python3", "-B", "/usr/share/try-omarchy/omarchy-link-calendar/bridge.py"]
    stdinEnabled: true
    running: true
    stdout: SplitParser { onRead: data => root.accept(data) }
    onExited: root.clearAndClose()
  }

  FloatingWindow {
    id: window
    title: "Omarchy Link · Calendar"
    visible: true
    color: "#1a1b26"
    implicitWidth: 760
    implicitHeight: 600
    onVisibleChanged: if (!visible) Qt.quit()

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 24
      spacing: 16
      Label { text: "Calendar"; color: "#c0caf5"; font.pixelSize: 28; textFormat: Text.PlainText }
      Label { text: "Hosting Mac · read-only · closes when locked"; color: "#9aa5ce"; textFormat: Text.PlainText }
      RowLayout {
        Button { text: "Today"; highlighted: root.selectedRange === "today"; onClicked: { root.selectedRange = "today"; root.select() } }
        Button { text: "Next 7 days"; highlighted: root.selectedRange === "seven-days"; onClicked: { root.selectedRange = "seven-days"; root.select() } }
        ComboBox {
          id: calendars
          Layout.fillWidth: true
          model: [{id: "", title: "All calendars"}].concat(root.snapshot.calendars || [])
          textRole: "title"
          // Host-owned names must never be interpreted as rich text.
          contentItem: Text { text: calendars.displayText; textFormat: Text.PlainText; color: "#c0caf5"; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight }
          delegate: ItemDelegate { required property var modelData; width: calendars.width; contentItem: Text { text: modelData.title; textFormat: Text.PlainText; elide: Text.ElideRight } }
          currentIndex: {
            var entries = model
            for (var i = 0; i < entries.length; i++) if (entries[i].id === root.selectedCalendar) return i
            return 0
          }
          onActivated: { root.selectedCalendar = model[index].id; root.select() }
        }
      }
      Label {
        Layout.fillWidth: true
        text: root.failure || ((root.snapshot.events || []).length ? "" : "No events in this view")
        color: "#9aa5ce"
        textFormat: Text.PlainText
      }
      ListView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        spacing: 12
        model: root.snapshot.events || []
        delegate: Rectangle {
          required property var modelData
          width: ListView.view.width
          height: 90
          radius: 8
          color: "#24283b"
          ColumnLayout {
            anchors.fill: parent
            anchors.margins: 12
            Text { Layout.fillWidth: true; text: modelData.title; textFormat: Text.PlainText; color: "#c0caf5"; font.pixelSize: 16; elide: Text.ElideRight }
            Text {
              Layout.fillWidth: true
              text: Qt.formatDateTime(new Date(modelData.startsAt), "ddd MMM d hh:mm") + " – " + Qt.formatDateTime(new Date(modelData.endsAt), "ddd MMM d hh:mm") + (modelData.allDay ? " · All day" : "")
              textFormat: Text.PlainText
              color: "#9aa5ce"
              elide: Text.ElideRight
            }
          }
        }
      }
    }
    Shortcut { sequence: "Esc"; onActivated: root.clearAndClose() }
  }
}
