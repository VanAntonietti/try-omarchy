import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ShellRoot {
  id: root

  property var snapshot: ({ calendars: [], events: [] })
  property string selectedRange: "today"
  property string selectedCalendar: ""
  property bool loading: false
  property string failure: ""
  readonly property string demoDate: {
    var configured = Quickshell.env("OMARCHY_LINK_DEMO_DATE")
    return configured ? configured : Qt.formatDate(new Date(), "yyyy-MM-dd")
  }
  readonly property color background: "#1a1b26"
  readonly property color surface: "#24283b"
  readonly property color foreground: "#c0caf5"
  readonly property color muted: "#9aa5ce"
  readonly property color accent: "#7aa2f7"
  readonly property color urgent: "#f7768e"

  function brokerCommand() {
    var command = [
      "/usr/local/bin/omarchy-link", "demo-agenda",
      "--date", root.demoDate,
      "--range", root.selectedRange
    ]
    if (root.selectedCalendar)
      command.push("--calendar", root.selectedCalendar)
    return command
  }

  function refresh() {
    if (agendaProcess.running) return
    root.loading = true
    root.failure = ""
    agendaProcess.command = root.brokerCommand()
    agendaProcess.running = true
  }

  function acceptAgenda(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed.source !== "invented"
          || !parsed.range
          || !Array.isArray(parsed.calendars)
          || !Array.isArray(parsed.events))
        throw new Error("unexpected broker response")
      root.snapshot = parsed
    } catch (error) {
      root.failure = "The invented agenda response was invalid."
      root.snapshot = ({ calendars: [], events: [] })
    }
  }

  function calendarOptions() {
    var result = [{ id: "", title: "All calendars", color: root.accent }]
    var calendars = root.snapshot.calendars || []
    for (var index = 0; index < calendars.length; index++)
      result.push(calendars[index])
    return result
  }

  function calendarFor(identifier) {
    var calendars = root.snapshot.calendars || []
    for (var index = 0; index < calendars.length; index++)
      if (calendars[index].id === identifier) return calendars[index]
    return ({ title: "Calendar", color: root.muted })
  }

  function selectRange(value) {
    if (root.loading || root.selectedRange === value) return
    root.selectedRange = value
    root.refresh()
  }

  function selectCalendar(identifier) {
    if (root.loading || root.selectedCalendar === identifier) return
    root.selectedCalendar = identifier
    root.refresh()
  }

  component FilterChip: Rectangle {
    id: chip
    required property string label
    property bool selected: false
    signal activated()

    implicitWidth: labelText.implicitWidth + 24
    implicitHeight: 32
    radius: 8
    color: selected ? root.accent : (pointer.containsMouse ? "#343b58" : root.surface)
    border.width: selected ? 0 : 1
    border.color: "#414868"

    Text {
      id: labelText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.selected ? root.background : root.foreground
      font.family: "monospace"
      font.pixelSize: 13
      font.bold: chip.selected
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !root.loading
      onClicked: chip.activated()
    }
  }

  Process {
    id: agendaProcess
    stdout: StdioCollector {
      id: agendaOutput
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: agendaError
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode === 0) {
        root.acceptAgenda(agendaOutput.text)
      } else {
        root.failure = String(agendaError.text || "The invented agenda is unavailable.").trim()
        root.snapshot = ({ calendars: [], events: [] })
      }
    }
  }

  Component.onCompleted: root.refresh()

  FloatingWindow {
    id: window
    visible: true
    title: "Omarchy Link · Calendar development demo"
    color: root.background
    implicitWidth: 760
    implicitHeight: 640
    minimumSize: Qt.size(620, 480)
    onVisibleChanged: if (!visible) Qt.quit()

    Rectangle {
      anchors.fill: parent
      color: root.background

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: 28
        spacing: 18

        RowLayout {
          Layout.fillWidth: true
          spacing: 12

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 3

            Text {
              textFormat: Text.PlainText
              text: "Calendar"
              color: root.foreground
              font.family: "monospace"
              font.pixelSize: 28
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: "Development data · no Mac Calendar access"
              color: root.muted
              font.family: "monospace"
              font.pixelSize: 13
            }
          }

          Rectangle {
            implicitWidth: sourceLabel.implicitWidth + 20
            implicitHeight: 28
            radius: 14
            color: "#1f2335"
            border.width: 1
            border.color: "#414868"

            Text {
              id: sourceLabel
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "INVENTED"
              color: "#9ece6a"
              font.family: "monospace"
              font.pixelSize: 11
              font.bold: true
              font.letterSpacing: 1
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: 8

          FilterChip {
            label: "Today"
            selected: root.selectedRange === "today"
            onActivated: root.selectRange("today")
          }
          FilterChip {
            label: "Next 7 days"
            selected: root.selectedRange === "seven-days"
            onActivated: root.selectRange("seven-days")
          }
          Item { Layout.fillWidth: true }
          Text {
            textFormat: Text.PlainText
            text: root.demoDate
            color: root.muted
            font.family: "monospace"
            font.pixelSize: 13
          }
        }

        Flickable {
          Layout.fillWidth: true
          Layout.preferredHeight: calendarFilters.implicitHeight
          contentWidth: calendarFilters.implicitWidth
          contentHeight: height
          clip: true

          Row {
            id: calendarFilters
            spacing: 8

            Repeater {
              model: root.calendarOptions()

              FilterChip {
                required property var modelData
                label: modelData.title
                selected: root.selectedCalendar === modelData.id
                onActivated: root.selectCalendar(modelData.id)
              }
            }
          }
        }

        Rectangle {
          Layout.fillWidth: true
          height: 1
          color: "#414868"
        }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          BusyIndicator {
            anchors.centerIn: parent
            running: root.loading
            visible: running
            palette.dark: root.accent
          }

          Text {
            anchors.centerIn: parent
            width: parent.width - 48
            visible: !root.loading && root.failure !== ""
            textFormat: Text.PlainText
            text: root.failure
            color: root.urgent
            font.family: "monospace"
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            anchors.centerIn: parent
            visible: !root.loading && root.failure === ""
              && (root.snapshot.events || []).length === 0
            textFormat: Text.PlainText
            text: "No invented events in this view"
            color: root.muted
            font.family: "monospace"
            font.pixelSize: 14
          }

          Flickable {
            anchors.fill: parent
            visible: !root.loading && root.failure === ""
              && (root.snapshot.events || []).length > 0
            contentWidth: width
            contentHeight: eventList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: eventList
              width: parent.width
              spacing: 10

              Repeater {
                model: root.snapshot.events || []

                Rectangle {
                  id: eventRow
                  required property var modelData
                  width: eventList.width
                  implicitHeight: eventContent.implicitHeight + 24
                  radius: 10
                  color: root.surface
                  border.width: 1
                  border.color: "#414868"
                  readonly property var calendar: root.calendarFor(modelData.calendarId)

                  RowLayout {
                    id: eventContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 14

                    Rectangle {
                      Layout.preferredWidth: 4
                      Layout.preferredHeight: 46
                      radius: 2
                      color: eventRow.calendar.color
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 4

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: eventRow.modelData.title
                        color: root.foreground
                        font.family: "monospace"
                        font.pixelSize: 15
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: eventRow.calendar.title
                        color: root.muted
                        font.family: "monospace"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                      }
                    }

                    ColumnLayout {
                      Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                      spacing: 4

                      Text {
                        Layout.alignment: Qt.AlignRight
                        textFormat: Text.PlainText
                        text: eventRow.modelData.date
                        color: root.foreground
                        font.family: "monospace"
                        font.pixelSize: 13
                      }
                      Text {
                        Layout.alignment: Qt.AlignRight
                        textFormat: Text.PlainText
                        text: eventRow.modelData.allDay
                          ? "All day"
                          : eventRow.modelData.startTime + "–" + eventRow.modelData.endTime
                        color: root.muted
                        font.family: "monospace"
                        font.pixelSize: 12
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "Esc or close the window to leave the demo"
          color: "#565f89"
          font.family: "monospace"
          font.pixelSize: 11
          horizontalAlignment: Text.AlignRight
        }
      }

      Shortcut {
        sequence: "Esc"
        onActivated: Qt.quit()
      }
    }
  }
}
