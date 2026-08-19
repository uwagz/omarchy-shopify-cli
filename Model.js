// Pure helpers for the Shopify CLI panel. No QML state in here so the same code
// can be exercised from node (`node -e 'require("./Model.js")'`) and from the
// shell.

function normalizeStore(value) {
  var text = String(value || "").trim().toLowerCase()
  if (text === "") return ""
  text = text.replace(/^[a-z]+:\/\//, "").split("/")[0]
  if (text === "") return ""
  if (text.indexOf(".") === -1) text += ".myshopify.com"
  return text
}

function shortStore(value) {
  var store = normalizeStore(value)
  var suffix = ".myshopify.com"
  if (store.length > suffix.length && store.indexOf(suffix) === store.length - suffix.length) {
    return store.slice(0, -suffix.length)
  }
  return store
}

function kindLabel(kind) {
  return String(kind || "") === "app" ? "app" : "theme"
}

function kindGlyph(kind) {
  return String(kind || "") === "app" ? "󰀻" : "󰏘"
}

function pluralize(count, singular, plural) {
  return count === 1 ? singular : (plural || singular + "s")
}

function formatDuration(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  if (total < 60) return total + "s"
  var minutes = Math.floor(total / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  var rest = minutes % 60
  if (hours < 24) return rest > 0 ? hours + "h " + rest + "m" : hours + "h"
  var days = Math.floor(hours / 24)
  return days + "d " + (hours % 24) + "h"
}

// "1 theme + 1 app", "2 themes", "" when idle.
function countSummary(themeCount, appCount) {
  var parts = []
  var themes = Number(themeCount) || 0
  var apps = Number(appCount) || 0
  if (themes > 0) parts.push(themes + " " + pluralize(themes, "theme"))
  if (apps > 0) parts.push(apps + " " + pluralize(apps, "app"))
  return parts.join(" + ")
}

// Primary name for a session row: the store is what you think of first, then
// the project folder, then whatever the CLI told us.
function sessionTitle(session) {
  if (!session) return "Session"
  if (session.storeShort) return String(session.storeShort)
  if (session.store) return shortStore(session.store)
  if (session.kind === "app" && session.appName) return String(session.appName)
  if (session.projectName) return String(session.projectName)
  return kindLabel(session.kind) + " dev"
}

// Bar label for `showLabel`: a single session shows its store, several show
// the count breakdown. Keep it terse — it lives in the bar.
function barLabel(sessions, themeCount, appCount) {
  var list = Array.isArray(sessions) ? sessions : []
  if (list.length === 0) return ""
  if (list.length === 1) return sessionTitle(list[0])
  return countSummary(themeCount, appCount)
}

function previewUrl(session) {
  if (!session || session.kind !== "theme") return ""
  if (session.previewUrl) return String(session.previewUrl)
  var host = String(session.host || "127.0.0.1")
  var port = Number(session.port) || 9292
  return "http://" + host + ":" + port
}

function storefrontUrl(session) {
  var store = normalizeStore(session ? session.store : "")
  return store ? "https://" + store : ""
}

function adminUrl(session) {
  var store = normalizeStore(session ? session.store : "")
  return store ? "https://" + store + "/admin" : ""
}

function editorUrl(session) {
  if (!session || session.kind !== "theme") return ""
  if (session.editorUrl) return String(session.editorUrl)
  var store = normalizeStore(session.store)
  var id = String(session.themeId || "")
  return store && id ? "https://" + store + "/admin/themes/" + id + "/editor" : ""
}

// The shareable preview link `shopify theme dev` prints for (p): the live
// storefront rendered with the development theme.
function sharePreviewUrl(session) {
  if (!session || session.kind !== "theme") return ""
  var store = normalizeStore(session.store)
  var id = String(session.themeId || "")
  return store && id ? "https://" + store + "/?preview_theme_id=" + id : ""
}

function adminThemeUrl(session) {
  if (!session || session.kind !== "theme") return ""
  var store = normalizeStore(session.store)
  var id = String(session.themeId || "")
  return store && id ? "https://" + store + "/admin/themes/" + id : ""
}

function adminAppUrl(session) {
  if (!session || session.kind !== "app") return ""
  var store = normalizeStore(session.store)
  var id = String(session.clientId || "")
  return store && id ? "https://" + store + "/admin/apps/" + id : ""
}

function graphiqlUrl(session) {
  return session && session.kind === "app" ? String(session.graphiqlUrl || "") : ""
}

function localAppUrl(session) {
  return session && session.kind === "app" ? String(session.localAppUrl || "") : ""
}

// Seconds the session has been running, from its start time when known.
function elapsedSeconds(session, nowSec) {
  if (!session) return 0
  var started = Number(session.startedTs) || 0
  if (started > 0 && nowSec) return Math.max(0, Math.floor(nowSec) - started)
  return Number(session.elapsedSec) || 0
}

// Everything about a session list except the clock; Service uses it to
// avoid republishing an identical list (and rebuilding every row) each poll.
function sessionsSignature(sessions) {
  var list = Array.isArray(sessions) ? sessions : []
  var parts = []
  for (var i = 0; i < list.length; i++) {
    var copy = {}
    for (var key in list[i]) if (key !== "elapsedSec") copy[key] = list[i][key]
    parts.push(JSON.stringify(copy))
  }
  return parts.join("\n")
}

// The link Enter / a click on the row opens.
function primaryUrl(session) {
  if (!session) return ""
  if (session.kind === "theme") return previewUrl(session)
  return localAppUrl(session) || adminAppUrl(session) || String(session.applicationUrl || "") || adminUrl(session)
}

function primaryHint(session) {
  if (!session) return ""
  if (session.kind === "theme") return "Open local preview"
  if (localAppUrl(session)) return "Open local app"
  if (adminAppUrl(session)) return "Open app in admin"
  if (session.applicationUrl) return "Open app URL"
  return "Open store admin"
}

// Ordered {kind, label, url, action?} for the per-row link menu; URL entries
// only when they resolve, plus terminal actions (Liquid console, app logs)
// that carry an `action` instead of a URL.
function linkOptions(session) {
  var options = []
  function push(kind, label, url) {
    if (url) options.push({ kind: kind, label: label, url: String(url) })
  }
  if (!session) return options
  if (session.kind === "theme") {
    push("preview", "Local preview (t)", previewUrl(session))
    push("editor", "Theme editor (e)", editorUrl(session))
    push("share", "Share preview (p)", sharePreviewUrl(session))
    push("adminTheme", "Theme in admin", adminThemeUrl(session))
  } else {
    push("localApp", "Local app", localAppUrl(session))
    push("graphiql", "GraphiQL (g)", graphiqlUrl(session))
    push("adminApp", "App in admin", adminAppUrl(session))
    push("appUrl", "App URL", session.applicationUrl)
  }
  push("storefront", "Storefront", storefrontUrl(session))
  push("admin", "Store admin", adminUrl(session))
  if (session.kind === "theme") options.push({ kind: "console", label: "Liquid console (terminal)", url: "", action: "console" })
  else options.push({ kind: "logs", label: "App logs (terminal)", url: "", action: "logs" })
  return options
}

// Ordered {kind, label, value} for the copy menu.
function copyOptions(session) {
  var options = []
  function push(kind, label, value) {
    var text = String(value || "")
    if (text !== "") options.push({ kind: kind, label: label, value: text })
  }
  if (!session) return options
  var links = linkOptions(session)
  for (var i = 0; i < links.length; i++) push("url:" + links[i].kind, links[i].label, links[i].url)
  push("store", "Store domain", normalizeStore(session.store))
  if (session.kind === "theme") push("themeId", "Theme ID", session.themeId)
  else push("clientId", "Client ID", session.clientId)
  push("path", "Project path", session.projectDir)
  return options
}

// Secondary line under the session title. `nowSec` (optional) makes the
// running time live without touching the session object.
function sessionMeta(session, nowSec) {
  if (!session) return ""
  var parts = []
  if (session.kind === "theme") {
    if (session.themeName) parts.push(String(session.themeName))
    else if (session.themeId) parts.push("Theme " + session.themeId)
    else parts.push("Theme dev")
    if (session.port) parts.push(":" + session.port)
    if (session.themeEditorSync === true) parts.push("editor sync")
    if (session.liveReload && String(session.liveReload) !== "hot-reload") parts.push("live reload " + session.liveReload)
  } else {
    parts.push(session.appName ? String(session.appName) : "App dev")
  }
  if (session.projectName && String(session.projectName) !== sessionTitle(session)) parts.push(String(session.projectName))
  parts.push(formatDuration(elapsedSeconds(session, nowSec)))
  return parts.join(" · ")
}

function sessionDetailHint(session) {
  if (!session) return ""
  if (session.detailsState === "pending") return "Fetching details…"
  if (session.detailsState === "error") return String(session.detailsError || "Details unavailable")
  return ""
}

// Tooltip shown when hovering the bar icon: one line per session.
function tooltipText(sessions, installed, nowSec) {
  if (installed === false) return "Shopify CLI is not installed"
  var list = Array.isArray(sessions) ? sessions : []
  if (list.length === 0) return "No Shopify dev sessions"
  var lines = []
  for (var i = 0; i < list.length; i++) {
    var session = list[i]
    var line = sessionTitle(session) + " (" + kindLabel(session.kind) + ")"
    line += " · " + formatDuration(elapsedSeconds(session, nowSec))
    lines.push(line)
  }
  return lines.join("\n")
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, error: "Empty status output" }
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object") return { ok: false, error: "Malformed status output" }
    var sessions = Array.isArray(data.sessions) ? data.sessions : []
    var normalized = []
    for (var i = 0; i < sessions.length; i++) {
      var session = sessions[i] || {}
      session.id = String(session.pid || i)
      session.kind = kindLabel(session.kind)
      normalized.push(session)
    }
    return {
      ok: true,
      installed: data.installed === true,
      cliPath: String(data.cliPath || ""),
      cliVersion: String(data.cliVersion || ""),
      detailsEnabled: data.detailsEnabled === true,
      generatedTs: Number(data.generatedTs) || 0,
      themeCount: Number(data.themeCount) || 0,
      appCount: Number(data.appCount) || 0,
      sessions: normalized
    }
  } catch (e) {
    return { ok: false, error: "Failed to parse status output" }
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeStore: normalizeStore,
    shortStore: shortStore,
    kindLabel: kindLabel,
    kindGlyph: kindGlyph,
    pluralize: pluralize,
    formatDuration: formatDuration,
    countSummary: countSummary,
    sessionTitle: sessionTitle,
    barLabel: barLabel,
    previewUrl: previewUrl,
    storefrontUrl: storefrontUrl,
    adminUrl: adminUrl,
    editorUrl: editorUrl,
    sharePreviewUrl: sharePreviewUrl,
    adminThemeUrl: adminThemeUrl,
    adminAppUrl: adminAppUrl,
    graphiqlUrl: graphiqlUrl,
    localAppUrl: localAppUrl,
    elapsedSeconds: elapsedSeconds,
    sessionsSignature: sessionsSignature,
    primaryUrl: primaryUrl,
    primaryHint: primaryHint,
    linkOptions: linkOptions,
    copyOptions: copyOptions,
    sessionMeta: sessionMeta,
    sessionDetailHint: sessionDetailHint,
    tooltipText: tooltipText,
    parseStatus: parseStatus
  }
}
