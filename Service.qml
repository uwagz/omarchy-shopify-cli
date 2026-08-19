import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Headless state for the Shopify CLI panel: polls status.py, keeps the parsed
// session list, and owns every side-effecting action (open links, copy,
// stop a session). Panel.qml only renders what lives here.
Item {
  id: root

  property var settings: ({})
  // Set by the panel; polls speed up to 2s while it is open so a session you
  // just started shows up as you look, and slow down to refreshIntervalSec
  // the rest of the time.
  property bool panelOpen: false

  property bool installed: true
  property bool refreshing: false
  property bool everPolled: false
  property string statusText: "Checking…"
  property string cliPath: ""
  property string cliVersion: ""
  property string lastError: ""
  property string actionStatus: ""
  property var sessions: []
  property int themeCount: 0
  property int appCount: 0
  property double generatedTs: 0
  // pid of the session we just sent SIGINT to, so its row can show progress
  // until the next poll confirms it went away.
  property string stoppingId: ""

  readonly property bool active: sessions.length > 0
  readonly property int sessionCount: sessions.length
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)
  readonly property int activeIntervalMs: panelOpen ? 2000 : refreshIntervalSec * 1000
  readonly property bool fetchDetails: boolSetting("fetchDetails", true)
  readonly property bool showWhenIdle: boolSetting("showWhenIdle", true)
  readonly property bool showLabel: boolSetting("showLabel", false)
  readonly property bool busy: statusProcess.running
  readonly property string countSummary: Model.countSummary(themeCount, appCount)
  readonly property string barLabel: Model.barLabel(sessions, themeCount, appCount)
  // generatedTs advances every poll, so the durations here stay fresh even
  // when the session list itself was not republished.
  readonly property string tooltipText: Model.tooltipText(sessions, installed, generatedTs)
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-shopify-cli"

  // status.py ships next to this file, wherever the plugin was installed.
  readonly property string helperPath: {
    var url = String(Qt.resolvedUrl("status.py"))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  property string _statusOutput: ""
  property string _statusError: ""
  property string _sessionsSignature: ""

  signal sessionsRefreshed()

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

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).toLowerCase()
    if (text === "true" || text === "1" || text === "yes") return true
    if (text === "false" || text === "0" || text === "no") return false
    return fallback
  }

  function elideStatus(text) {
    var value = String(text || "").replace(/\s+/g, " ").trim()
    return value.length > 140 ? value.substring(0, 137) + "…" : value
  }

  function flashStatus(text) {
    actionStatus = String(text || "")
    actionStatusTimer.restart()
  }

  function refresh() {
    if (statusProcess.running) return
    _statusOutput = ""
    _statusError = ""
    refreshing = true
    // -S skips site-packages: the helper is stdlib-only and it trims startup.
    var command = ["python3", "-S", helperPath]
    if (!fetchDetails) command.push("--no-details")
    statusProcess.command = command
    statusProcess.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    if (!parsed.ok) {
      lastError = parsed.error || "Failed to read status"
      console.warn("shopify-cli", lastError)
      return
    }
    installed = parsed.installed
    cliPath = parsed.cliPath
    cliVersion = parsed.cliVersion
    themeCount = parsed.themeCount
    appCount = parsed.appCount
    generatedTs = parsed.generatedTs
    // Only publish a new array when something other than the clock changed:
    // a fresh JS array makes the Repeater rebuild every row (two Popups each),
    // and at 2s polls that is the single biggest cost of the panel. Rows
    // compute their running time from startedTs themselves.
    var signature = Model.sessionsSignature(parsed.sessions)
    if (signature !== _sessionsSignature) {
      _sessionsSignature = signature
      sessions = parsed.sessions
    }
    if (stoppingId !== "") {
      var stillThere = false
      for (var i = 0; i < sessions.length; i++) if (String(sessions[i].id) === stoppingId) stillThere = true
      if (!stillThere) stoppingId = ""
    }
    if (!installed) statusText = "Shopify CLI not installed"
    else if (sessions.length === 0) statusText = "No dev sessions"
    else statusText = countSummary
    lastError = ""
    everPolled = true
    sessionsRefreshed()
  }

  function sessionById(id) {
    for (var i = 0; i < sessions.length; i++) if (String(sessions[i].id) === String(id)) return sessions[i]
    return null
  }

  function openUrl(url) {
    var target = String(url || "").trim()
    if (target === "") return
    Quickshell.execDetached(["omarchy-launch-browser", target])
  }

  function openSession(session) {
    openUrl(Model.primaryUrl(session))
  }

  // Same letters `shopify theme dev` prints in its own hint line:
  //   (t) local preview, (e) theme editor, (p) shareable preview link.
  function openPreview(session) { openUrl(Model.previewUrl(session)) }
  function openEditor(session) { openUrl(Model.editorUrl(session)) }
  function openSharePreview(session) { openUrl(Model.sharePreviewUrl(session)) }
  function openAdmin(session) { openUrl(Model.adminUrl(session)) }
  function openStorefront(session) { openUrl(Model.storefrontUrl(session)) }
  // `shopify app dev` hint line: (g) GraphiQL.
  function openGraphiql(session) { openUrl(Model.graphiqlUrl(session)) }

  // Terminal actions, run in the session's project directory with the same
  // CLI binary the session uses. The terminal closes when the command ends.
  function runInTerminal(projectDir, args) {
    var cli = cliPath || "shopify"
    var command = ["setsid", "uwsm-app", "--", "xdg-terminal-exec"]
    if (projectDir) command.push("--dir=" + projectDir)
    command.push(cli)
    for (var i = 0; i < args.length; i++) command.push(String(args[i]))
    Quickshell.execDetached(command)
  }

  // Liquid REPL against the session's store and (dev) theme.
  function openConsole(session) {
    if (!session || session.kind !== "theme") return
    var args = ["theme", "console"]
    if (session.store) args.push("--store", session.store)
    if (session.themeId) args.push("--theme", session.themeId)
    if (session.environment) args.push("--environment", session.environment)
    if (session.authAlias) args.push("--auth-alias", session.authAlias)
    runInTerminal(session.projectDir, args)
  }

  // Live app log stream for the session's app.
  function openAppLogs(session) {
    if (!session || session.kind !== "app") return
    var args = ["app", "logs"]
    if (session.config) args.push("--config", session.config)
    if (session.store) args.push("--store", session.store)
    if (session.authAlias) args.push("--auth-alias", session.authAlias)
    runInTerminal(session.projectDir, args)
  }

  // Dispatch for link-menu entries that are not plain URLs.
  function runLinkOption(session, option) {
    if (!option) return
    if (option.action === "console") openConsole(session)
    else if (option.action === "logs") openAppLogs(session)
    else openUrl(option.url)
  }

  function copyToClipboard(value, label) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(text) + " | wl-copy"])
    flashStatus("Copied " + (label || "to clipboard"))
  }

  function copyStore(session) {
    if (!session) return
    copyToClipboard(Model.normalizeStore(session.store), "store domain")
  }

  function copyPrimaryUrl(session) {
    if (!session) return
    copyToClipboard(Model.primaryUrl(session), "link")
  }

  // Same as Ctrl+C in the terminal that runs the dev server — the CLI gets to
  // clean up after itself. A process started in the background by a
  // non-interactive shell ignores SIGINT, so if it is still around a few
  // seconds later the settle timer follows up with SIGTERM. Never SIGKILL.
  property string stoppingPid: ""

  function stopSession(session) {
    if (!session || !session.pid) return
    stoppingId = String(session.id)
    stoppingPid = String(session.pid)
    flashStatus("Stopping " + Model.sessionTitle(session) + "…")
    Quickshell.execDetached(["kill", "-INT", stoppingPid])
    settleTimer.ticks = 0
    settleTimer.restart()
  }

  function revealProject(session) {
    var path = session ? String(session.projectDir || "") : ""
    if (path === "") return
    Quickshell.execDetached(["xdg-open", path])
  }

  // The bar injects `settings` a tick after the widget is created, so the
  // first poll must not fire synchronously on startup or it would run with
  // manifest defaults (and, with fetchDetails on, call the CLI before the
  // user's choice had arrived). Poll shortly after creation and again
  // whenever settings change; the periodic timer takes over from there.
  onSettingsChanged: delayedRefresh.restart()

  Timer {
    id: firstPoll
    interval: 400
    repeat: false
    running: true
    onTriggered: if (!root.everPolled) root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: root.activeIntervalMs
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  Timer {
    id: delayedRefresh
    interval: 600
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // After a stop the CLI takes a moment to exit; re-poll a few times so the
    // row disappears without waiting for the next periodic refresh.
    id: settleTimer
    property int ticks: 0
    interval: 1000
    repeat: true
    running: false
    onTriggered: {
      settleTimer.ticks += 1
      root.refresh()
      if (settleTimer.ticks === 3 && root.stoppingId !== "" && root.stoppingPid !== "") {
        Quickshell.execDetached(["kill", "-TERM", root.stoppingPid])
      }
      if (settleTimer.ticks >= 8 || root.stoppingId === "") {
        settleTimer.running = false
        root.stoppingId = ""
        root.stoppingPid = ""
      }
    }
  }

  Timer {
    // A poll that never exits would otherwise block every later poll forever
    // (each one is skipped while the previous is still running).
    id: pollWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (statusProcess.running) statusProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    // Cached bytecode for the helper lives in the cache dir, never next to
    // the source (a __pycache__ there would trip the plugin hot-reload watcher).
    environment: ({ PYTHONPYCACHEPREFIX: root.cacheDir + "/pycache" })
    stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true; onStreamFinished: root._statusError = text }
    onExited: function(exitCode) {
      root.refreshing = false
      pollWatchdog.stop()
      var stdout = String(statusStdout.text || root._statusOutput || "")
      var stderr = String(statusStderr.text || root._statusError || "")
      if (exitCode === 0) root.applyStatus(stdout)
      else {
        root.lastError = root.elideStatus(stderr || stdout || "Could not read Shopify CLI status")
        root.everPolled = true
      }
    }
  }
}
