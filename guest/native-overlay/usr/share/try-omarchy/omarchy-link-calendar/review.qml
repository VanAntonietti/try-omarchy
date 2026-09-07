import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root
  property var proposal: null
  property bool resolved: false
  function decide(approved) {
    if (resolved || !proposal) return
    resolved = true
    bridge.write(approved ? "approve\n" : "reject\n")
    proposal = null
  }
  Process {
    id: bridge
    command: ["/usr/bin/python3", "-B", "/usr/share/try-omarchy/omarchy-link-calendar/review.py", "--view"]
    stdinEnabled: true
    running: true
    stdout: SplitParser {
      onRead: data => {
        try { root.proposal = JSON.parse(data) } catch (_) { Qt.quit() }
      }
    }
    onExited: { root.proposal = null; Qt.quit() }
  }
  FloatingWindow {
    id: window
    title: "Omarchy Link · Review Calendar create"
    visible: true
    color: "#1a1b26"
    implicitWidth: 720
    implicitHeight: 540
    onVisibleChanged: if (!visible) { root.proposal = null; Qt.quit() }
    ColumnLayout {
      anchors.fill: parent
      anchors.margins: 24
      Label { text: "Create this event on the hosting Mac?"; color: "#c0caf5"; font.pixelSize: 24; textFormat: Text.PlainText }
      Label { text: "Development · one-shot Review Interlock · no automatic retry"; color: "#9aa5ce"; textFormat: Text.PlainText }
      ScrollView {
        Layout.fillWidth: true
        Layout.fillHeight: true
        TextArea {
          readOnly: true
          wrapMode: TextEdit.Wrap
          textFormat: TextEdit.PlainText
          color: "#c0caf5"
          text: root.proposal ? "Title: " + root.proposal.title + "\n\nStart (UTC): " + root.proposal.startsAt + "\nEnd (UTC): " + root.proposal.endsAt + "\n\nCalendar: " + root.proposal.calendar.title + "\nCalendar ID: " + root.proposal.calendar.id : "Loading canonical proposal…"
        }
      }
      RowLayout {
        Button { text: "Reject"; enabled: !!root.proposal && !root.resolved; onClicked: root.decide(false) }
        Button { text: "Approve this event once"; enabled: !!root.proposal && !root.resolved; onClicked: root.decide(true) }
      }
    }
    Shortcut { sequence: "Esc"; onActivated: root.decide(false) }
  }
}
