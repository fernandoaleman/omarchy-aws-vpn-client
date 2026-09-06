import QtQuick
import Quickshell
import Quickshell.Io

// State and actions for the AWS VPN widget. Everything goes through the
// omarchy-aws-vpn-client CLI, which owns the D-Bus conversation with the
// openlawsvpn daemon; this file only polls it and shells out to it.
Item {
  id: root

  property var settings: ({})

  // Run the CLI shipped inside this plugin rather than whatever happens to be
  // on PATH, so a fresh `omarchy plugin add` works with no extra install step.
  readonly property string cliPath: {
    var url = String(Qt.resolvedUrl("bin/omarchy-aws-vpn-client"))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  // --- connection state, from `omarchy-aws-vpn-client status --json` -------------
  // state is one of: idle, connecting, waiting_saml, connected,
  // disconnecting, error, daemon-down, unknown
  property string state: "unknown"
  property string label: "Checking…"
  property string activeProfile: ""
  property string serverIp: ""
  property string assignedIp: ""

  // --- profiles, from `omarchy-aws-vpn-client list --json` -----------------------
  property var profiles: []
  property string defaultProfile: ""

  // --- importable .ovpn files, from `omarchy-aws-vpn-client discover --json` -----
  property var discovered: []

  property string actionStatus: ""
  property string lastError: ""

  readonly property bool connected: state === "connected"
  readonly property bool transitioning: state === "connecting"
                                     || state === "waiting_saml"
                                     || state === "disconnecting"
  readonly property bool awaitingLogin: state === "waiting_saml"
  readonly property bool daemonDown: state === "daemon-down"
  readonly property bool busy: connectProcess.running || controlProcess.running
                            || profileProcess.running

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 3600)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function profileByName(name) {
    for (var i = 0; i < profiles.length; i++)
      if (profiles[i].name === name) return profiles[i]
    return null
  }

  // ------------------------------------------------------------------ poll

  function refresh() {
    if (!statusProcess.running) {
      statusProcess.command = [root.cliPath, "status", "--json"]
      statusProcess.running = true
    }
  }

  function refreshProfiles() {
    if (!listProcess.running) {
      listProcess.command = [root.cliPath, "list", "--json"]
      listProcess.running = true
    }
  }

  function refreshDiscovered() {
    if (!discoverProcess.running) {
      discoverProcess.command = [root.cliPath, "discover", "--json"]
      discoverProcess.running = true
    }
  }

  function refreshAll() {
    refresh()
    refreshProfiles()
    refreshDiscovered()
  }

  // --------------------------------------------------------------- actions

  function connectTo(name) {
    if (connectProcess.running || transitioning || connected) return
    lastError = ""
    setActionStatus(name ? "Connecting to " + name + "…" : "Connecting…")
    // Long-lived: the CLI stays up through the SAML round-trip, opening the
    // browser and waiting for the tunnel, so this Process runs for the whole
    // login. Quickshell keeps it async, so the panel stays responsive.
    connectProcess.command = name
      ? [root.cliPath, "connect", name]
      : [root.cliPath, "connect"]
    connectProcess.running = true
    fastPoll.restart()
  }

  function disconnect() {
    if (controlProcess.running) return
    setActionStatus("Disconnecting…")
    controlProcess.command = [root.cliPath, "disconnect"]
    controlProcess.running = true
    fastPoll.restart()
  }

  function toggleConnection() {
    if (connected || transitioning) disconnect()
    else connectTo(defaultProfile || "")
  }

  function addProfile(path) {
    if (profileProcess.running || !path) return
    setActionStatus("Importing profile…")
    profileProcess.command = [root.cliPath, "add", path]
    profileProcess.running = true
  }

  function removeProfile(name) {
    if (profileProcess.running || !name) return
    setActionStatus("Removing " + name + "…")
    profileProcess.command = [root.cliPath, "remove", name]
    profileProcess.running = true
  }

  function setDefaultProfile(name) {
    if (profileProcess.running || !name) return
    setActionStatus(name + " is now the default")
    profileProcess.command = [root.cliPath, "default", name]
    profileProcess.running = true
  }

  function startDaemon() {
    if (controlProcess.running) return
    setActionStatus("Starting daemon…")
    controlProcess.command = ["pkexec", "systemctl", "start", "openlawsvpn-daemon"]
    controlProcess.running = true
    fastPoll.restart()
  }

  function setActionStatus(text) {
    actionStatus = text
    actionStatusTimer.restart()
  }

  // -------------------------------------------------------------- plumbing

  function applyStatus(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "").trim()) } catch (e) { parsed = null }
    if (!parsed) {
      root.state = "unknown"
      root.label = "Unavailable"
      return
    }
    root.state = String(parsed.state || "unknown")
    root.label = String(parsed.label || root.state)
    root.activeProfile = String(parsed.profile || "")
    root.serverIp = String(parsed.server_ip || "")
    root.assignedIp = String(parsed.assigned_ip || "")

    // Poll quickly only while something is actually moving.
    if (root.transitioning && !fastPoll.running) fastPoll.start()
    else if (!root.transitioning && fastPoll.running) fastPoll.stop()
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: listProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(text || "").trim()) } catch (e) { parsed = null }
        if (!parsed) return
        root.profiles = parsed.profiles || []
        root.defaultProfile = String(parsed.default || "")
      }
    }
  }

  Process {
    id: discoverProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(text || "").trim()) } catch (e) { parsed = null }
        root.discovered = parsed ? (parsed.files || []) : []
      }
    }
  }

  Process {
    id: connectProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") root.lastError = msg.split("\n")[0]
      }
    }
    onExited: function(exitCode) {
      root.refresh()
      if (exitCode === 0) {
        root.lastError = ""
        root.setActionStatus("Connected")
      } else {
        root.setActionStatus("")
      }
      fastPoll.stop()
    }
  }

  Process {
    id: controlProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") root.lastError = msg.split("\n")[0]
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.lastError = ""
      root.refresh()
    }
  }

  Process {
    id: profileProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var msg = String(text || "").trim()
        if (msg !== "") root.lastError = msg.split("\n")[0]
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.lastError = ""
      root.refreshProfiles()
      root.refreshDiscovered()
    }
  }

  Timer {
    id: pollTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // While connecting or waiting on SSO, poll hard enough that the panel
  // tracks the login instead of lagging a whole refresh interval behind.
  Timer {
    id: fastPoll
    interval: 1000
    repeat: true
    running: false
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Component.onCompleted: refreshAll()
}
