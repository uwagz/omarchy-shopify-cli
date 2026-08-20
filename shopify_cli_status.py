#!/usr/bin/env python3
"""Omarchy Shopify CLI status helper.

Finds running `shopify theme dev` / `shopify app dev` sessions owned by the
current user and prints one JSON document describing them. The shell's
Service.qml runs this on a timer; everything that could be slow (the Shopify
CLI itself) happens in a detached background fetch whose result is cached on
disk, so a poll is always a cheap /proc walk.

Read-only by design: the only Shopify CLI commands ever executed are

  shopify theme info --development --json --path <dir> [--store ...]
  shopify app info --json --path <dir>

and only when details are enabled (the default) for a session we have not
already resolved. Nothing is ever pushed, pulled, published, or deployed.

Usage:
  status.py [--no-details]          print the status JSON
  status.py --fetch <kind> <cache> <dir> [--store S] [--auth-alias A] [--environment E] [--config C]
                                    internal: resolve details for one session
"""

import os
import sys
import time

HELPER_VERSION = 1
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache"), "omarchy-shopify-cli")
FETCH_TIMEOUT_SEC = 90
FETCH_STALE_SEC = 120
DEFAULT_THEME_PORT = 9292
DEFAULT_THEME_HOST = "127.0.0.1"
DEFAULT_GRAPHIQL_PORT = 3457
DEFAULT_THEME_APP_EXTENSION_PORT = 9293


def _json_dumps(value):
  """Minimal JSON encoder for the plain dict/list/str/int/bool/None we emit;
  avoids importing json (which drags in re) on the hot poll path."""
  if value is None: return "null"
  if value is True: return "true"
  if value is False: return "false"
  if isinstance(value, int): return str(value)
  if isinstance(value, float): return repr(value)
  if isinstance(value, str):
    out = ['"']
    for ch in value:
      if ch == '"': out.append('\\"')
      elif ch == "\\": out.append("\\\\")
      elif ch == "\n": out.append("\\n")
      elif ch == "\r": out.append("\\r")
      elif ch == "\t": out.append("\\t")
      elif ord(ch) < 0x20: out.append("\\u%04x" % ord(ch))
      else: out.append(ch)
    out.append('"')
    return "".join(out)
  if isinstance(value, (list, tuple)): return "[" + ",".join(_json_dumps(v) for v in value) + "]"
  if isinstance(value, dict): return "{" + ",".join(_json_dumps(str(k)) + ":" + _json_dumps(v) for k, v in value.items()) + "}"
  return _json_dumps(str(value))


# ----------------------------------------------------------------- utilities

def which(name):
  """shutil.which without importing shutil (which alone costs ~4 ms per poll)."""
  for directory in (os.environ.get("PATH") or os.defpath).split(os.pathsep):
    if not directory:
      continue
    candidate = os.path.join(directory, name)
    if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
      return candidate
  return None


def read_text(path, limit=1 << 20):
  try:
    with open(path, "rb") as handle:
      return handle.read(limit).decode("utf-8", "replace")
  except OSError:
    return ""


def clock_ticks():
  try:
    return os.sysconf("SC_CLK_TCK") or 100
  except (ValueError, OSError):
    return 100


def boot_time():
  for line in read_text("/proc/stat").splitlines():
    if line.startswith("btime "):
      try:
        return int(line.split()[1])
      except (IndexError, ValueError):
        break
  return 0


def normalize_store(value):
  """Turn any of `example`, `example.myshopify.com`, `https://example.myshopify.com/`
  into `example.myshopify.com`. Returns "" for empty input."""
  text = str(value or "").strip()
  if text == "":
    return ""
  if "://" in text:
    text = text.split("://", 1)[1]
  text = text.split("/")[0].strip().lower()
  if text == "":
    return ""
  if "." not in text:
    text += ".myshopify.com"
  return text


def short_store(store):
  value = normalize_store(store)
  return value[: -len(".myshopify.com")] if value.endswith(".myshopify.com") else value


def load_toml(path):
  try:
    import tomllib  # Python 3.11+; lazy, only when a toml file is actually read
  except ImportError:
    return {}
  try:
    with open(path, "rb") as handle:
      return tomllib.load(handle)
  except Exception:
    # Untrusted input: a deeply nested table raises RecursionError, which is
    # not an OSError/ValueError. Nothing here is worth crashing the poll for.
    return {}


def atomic_write_json(path, payload):
  import json
  os.makedirs(os.path.dirname(path), exist_ok=True)
  tmp = path + ".tmp"
  with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
  os.replace(tmp, path)


# ------------------------------------------------------------ process scan

CLI_BASENAMES = {"shopify", "shopify.js", "shopify.cmd", "shopify-cli"}

# The Shopify CLI is a Node package; the process executing it is one of these
# (or a standalone binary named shopify). Anything else with "shopify theme
# dev" in its arguments — an editor opening files by those names, a shell
# wrapper quoting the command — is not the CLI and must not be listed (or
# signalled) as a session.
RUNTIME_EXES = {"node", "nodejs", "bun", "deno"}


def cli_index(argv):
  """Index of the token that is the Shopify CLI executable, or -1.

  Only argv[0] (a binary or shim) or argv[1] (interpreter + script) can be
  the CLI. A `shopify` token deeper in argv belongs to some other program's
  arguments. Package-runner wrappers (`npx shopify theme dev`) are rejected
  here too — the CLI child process they spawn is matched on its own, which
  is also the right target for a stop signal."""
  for index, token in enumerate(argv[:2]):
    base = os.path.basename(token)
    if base in CLI_BASENAMES:
      return index
    if token.endswith("/@shopify/cli/bin/run.js") or token.endswith("/@shopify/cli/bin/run"):
      return index
  return -1


def executable_is_cli(pid):
  """True when the process image is a JS runtime or a shopify binary."""
  try:
    exe = os.path.basename(os.readlink("/proc/%d/exe" % pid))
  except OSError:
    return False
  return exe in RUNTIME_EXES or exe in CLI_BASENAMES


def dev_command(argv):
  """('theme'|'app', index_of_dev_token) when argv is `shopify <kind> dev`, else (None, -1).

  Sub-commands the CLI spawns for itself (`shopify notifications list`,
  `shopify theme info`) fall through here because their verb is not `dev`."""
  index = cli_index(argv)
  if index < 0 or index + 2 >= len(argv):
    return None, -1
  kind = argv[index + 1]
  if kind in ("theme", "app") and argv[index + 2] == "dev":
    return kind, index + 2
  return None, -1


VALUE_FLAGS = {
  "--store": "store", "-s": "store",
  "--theme": "theme", "-t": "theme",
  "--port": "port",
  "--host": "host",
  "--path": "path",
  "--auth-alias": "authAlias",
  "--environment": "environment", "-e": "environment",
  "--config": "config", "-c": "config",
  "--live-reload": "liveReload",
  "--localhost-port": "localhostPort",
  "--theme-app-extension-port": "themeAppExtensionPort",
  "--tunnel-url": "tunnelUrl",
}

BOOL_FLAGS = {
  "--theme-editor-sync": "themeEditorSync",
  "--use-localhost": "useLocalhost",
}


def parse_flags(tokens):
  flags = {}
  index = 0
  while index < len(tokens):
    token = tokens[index]
    if token.startswith("--") and "=" in token:
      name, value = token.split("=", 1)
      if name in VALUE_FLAGS and VALUE_FLAGS[name] not in flags:
        flags[VALUE_FLAGS[name]] = value
    elif token in VALUE_FLAGS:
      if index + 1 < len(tokens) and not tokens[index + 1].startswith("-"):
        if VALUE_FLAGS[token] not in flags:
          flags[VALUE_FLAGS[token]] = tokens[index + 1]
        index += 1
    elif token in BOOL_FLAGS:
      flags[BOOL_FLAGS[token]] = "1"
    index += 1
  return flags


ENV_FLAGS = {
  "SHOPIFY_FLAG_STORE": "store",
  "SHOPIFY_FLAG_THEME_ID": "theme",
  "SHOPIFY_FLAG_PORT": "port",
  "SHOPIFY_FLAG_HOST": "host",
  "SHOPIFY_FLAG_PATH": "path",
  "SHOPIFY_FLAG_AUTH_ALIAS": "authAlias",
  "SHOPIFY_FLAG_ENVIRONMENT": "environment",
  "SHOPIFY_FLAG_APP_CONFIG": "config",
  "SHOPIFY_FLAG_LIVE_RELOAD": "liveReload",
  "SHOPIFY_FLAG_THEME_EDITOR_SYNC": "themeEditorSync",
  "SHOPIFY_FLAG_LOCALHOST_PORT": "localhostPort",
  "SHOPIFY_FLAG_USE_LOCALHOST": "useLocalhost",
  "SHOPIFY_FLAG_THEME_APP_EXTENSION_PORT": "themeAppExtensionPort",
  "SHOPIFY_FLAG_TUNNEL_URL": "tunnelUrl",
}


def read_environ(pid):
  env = {}
  raw = read_text("/proc/%d/environ" % pid)
  for entry in raw.split("\0"):
    if "=" not in entry:
      continue
    key, value = entry.split("=", 1)
    if key in ENV_FLAGS:
      env[ENV_FLAGS[key]] = value
  return env


def socket_inodes(pid):
  inodes = set()
  fd_dir = "/proc/%d/fd" % pid
  try:
    for name in os.listdir(fd_dir):
      try:
        target = os.readlink(os.path.join(fd_dir, name))
      except OSError:
        continue
      if target.startswith("socket:[") and target.endswith("]"):
        inodes.add(target[8:-1])
  except OSError:
    pass
  return inodes


def listening_ports(pids):
  """TCP ports any of these pids listen on, via their socket inodes. Own processes only."""
  inodes = set()
  for pid in pids:
    inodes |= socket_inodes(pid)
  if not inodes:
    return []
  ports = []
  for table in ("/proc/net/tcp", "/proc/net/tcp6"):
    for line in read_text(table).splitlines()[1:]:
      parts = line.split()
      if len(parts) < 10:
        continue
      local, state, inode = parts[1], parts[3], parts[9]
      if state != "0A" or inode not in inodes:  # 0A = LISTEN
        continue
      try:
        ports.append(int(local.rsplit(":", 1)[1], 16))
      except (IndexError, ValueError):
        continue
  return sorted(set(ports))


def process_start(pid, hz, btime):
  stat = read_text("/proc/%d/stat" % pid)
  # comm can contain spaces/parens; everything after the last ')' is fixed-order.
  tail = stat.rsplit(")", 1)[-1].split()
  try:
    ppid = int(tail[1])
    start_ticks = int(tail[19])
  except (IndexError, ValueError):
    return 0, 0, 0
  started_ts = btime + start_ticks / float(hz) if btime else 0
  return ppid, start_ticks, int(started_ts)


OWN_PIDS = []


def descendants(pid, hz, btime):
  """All descendant pids of `pid` among the user's processes (the app dev CLI
  runs the app server and extension dev servers as children, and that is
  where the interesting ports live). Reads /proc/<pid>/stat once per own
  process, so only called when an app session exists."""
  children = {}
  for other in OWN_PIDS:
    ppid, _, _ = process_start(other, hz, btime)
    children.setdefault(ppid, []).append(other)
  result = []
  stack = [pid]
  while stack:
    current = stack.pop()
    for child in children.get(current, []):
      if child not in result:
        result.append(child)
        stack.append(child)
  return result


def scan_processes():
  uid = os.getuid()
  hz = clock_ticks()
  btime = boot_time()
  found = {}
  del OWN_PIDS[:]
  for name in os.listdir("/proc"):
    if not name.isdigit():
      continue
    pid = int(name)
    if pid == os.getpid():
      continue
    try:
      if os.stat("/proc/%d" % pid).st_uid != uid:
        continue
    except OSError:
      continue
    OWN_PIDS.append(pid)
    raw = read_text("/proc/%d/cmdline" % pid, 1 << 16)
    if not raw:
      continue
    argv = [token for token in raw.split("\0") if token != ""]
    kind, dev_index = dev_command(argv)
    if kind is None:
      continue
    if not executable_is_cli(pid):
      continue
    ppid, start_ticks, started_ts = process_start(pid, hz, btime)
    found[pid] = {
      "pid": pid,
      "ppid": ppid,
      "kind": kind,
      "argv": argv,
      "hz": hz,
      "btime": btime,
      "flags": parse_flags(argv[dev_index + 1:]),
      "startTicks": start_ticks,
      "startedTs": started_ts,
    }

  # `npm exec shopify theme dev` (or a re-exec'd worker) shows up as a parent
  # and child that both match. Keep the topmost one: that is the process the
  # user launched and the one a SIGINT should go to.
  result = []
  for pid, proc in found.items():
    ancestor = proc["ppid"]
    nested = False
    hops = 0
    while ancestor > 1 and hops < 64:
      if ancestor in found:
        nested = True
        break
      ancestor, _, _ = process_start(ancestor, hz, btime)
      hops += 1
    if not nested:
      result.append(proc)
  result.sort(key=lambda item: (item["startedTs"], item["pid"]))
  return result


# ------------------------------------------------------------------ details

def theme_environment(project_dir, environment):
  """{store, theme} from the first matching [environments.<name>] block of
  shopify.theme.toml, for sessions started with -e/--environment."""
  if not environment:
    return {}
  config = load_toml(os.path.join(project_dir, "shopify.theme.toml"))
  environments = config.get("environments") if isinstance(config, dict) else None
  if not isinstance(environments, dict):
    return {}
  for name in str(environment).split(","):
    entry = environments.get(name.strip())
    if isinstance(entry, dict):
      return {"store": str(entry.get("store") or ""), "theme": str(entry.get("theme") or "")}
  return {}


def app_toml_details(project_dir, config_name):
  """shopify.app[.<config>].toml carries the app name, client id, and dev
  store, which is everything the old `shopify app info -j` call gave us — so
  app sessions never need the CLI at all."""
  candidates = []
  if config_name:
    candidates.append(os.path.join(project_dir, "shopify.app.%s.toml" % config_name))
  candidates.append(os.path.join(project_dir, "shopify.app.toml"))
  for path in candidates:
    if not os.path.isfile(path):
      continue
    config = load_toml(path)
    if not isinstance(config, dict):
      continue
    build = config.get("build") if isinstance(config.get("build"), dict) else {}
    return {
      "appName": str(config.get("name") or ""),
      "clientId": str(config.get("client_id") or ""),
      "devStore": str(build.get("dev_store_url") or ""),
      "applicationUrl": str(config.get("application_url") or ""),
      "configPath": path,
    }
  return {}


def cache_path_for(proc):
  return os.path.join(CACHE_DIR, "%d-%d.json" % (proc["pid"], proc["startTicks"]))


def read_cache(path):
  import json
  try:
    with open(path, "r", encoding="utf-8") as handle:
      data = json.load(handle)
    return data if isinstance(data, dict) else None
  except (OSError, ValueError):
    return None


def start_fetch(proc, cache_path, project_dir):
  """Spawn a detached copy of this script to run the CLI and fill the cache.
  Returns immediately; the next poll sees the result."""
  marker = cache_path + ".fetching"
  try:
    age = time.time() - os.stat(marker).st_mtime
    if age < FETCH_STALE_SEC:
      return
  except OSError:
    pass
  os.makedirs(CACHE_DIR, exist_ok=True)
  with open(marker, "w", encoding="utf-8") as handle:
    handle.write(str(int(time.time())))
  command = [sys.executable, os.path.abspath(__file__), "--fetch", proc["kind"], cache_path, project_dir]
  flags = proc["flags"]
  # `--flag=value`: a value that begins with "-" is kept as the flag's value
  # (parse_flags on the other side would otherwise skip a bare "-…" token).
  if flags.get("store"):
    command.append("--store=" + flags["store"])
  if flags.get("authAlias"):
    command.append("--auth-alias=" + flags["authAlias"])
  if flags.get("environment"):
    command.append("--environment=" + flags["environment"])
  if flags.get("config"):
    command.append("--config=" + flags["config"])
  import subprocess
  try:
    subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)
  except OSError:
    try:
      os.unlink(marker)
    except OSError:
      pass


def run_fetch(args):
  """--fetch <kind> <cache> <dir> [--store S] [--auth-alias A] [--environment E] [--config C]"""
  if len(args) < 3:
    return 2
  import subprocess, json, re
  kind, cache_path, project_dir = args[0], args[1], args[2]
  extra = parse_flags(args[3:])
  shopify = which("shopify")
  payload = {"ok": False, "fetchedTs": int(time.time()), "error": "", "data": None}
  marker = cache_path + ".fetching"
  if not shopify:
    payload["error"] = "Shopify CLI not found"
  else:
    if kind == "theme":
      # `--flag=value` (not `--flag value`): a value that begins with "-"
      # then stays the flag's argument instead of parsing as a new option.
      command = [shopify, "theme", "info", "--development", "--json", "--no-color", "--path=" + project_dir]
      if extra.get("store"):
        command.append("--store=" + extra["store"])
      if extra.get("environment"):
        command.append("--environment=" + extra["environment"])
    else:
      command = [shopify, "app", "info", "--json", "--no-color", "--path=" + project_dir]
      if extra.get("config"):
        command.append("--config=" + extra["config"])
    if extra.get("authAlias"):
      command.append("--auth-alias=" + extra["authAlias"])
    env = dict(os.environ)
    # Never let a background status probe pop a browser login or an
    # interactive prompt: CI mode makes the CLI fail fast instead.
    env["CI"] = "1"
    env["SHOPIFY_CLI_NO_ANALYTICS"] = "1"
    env["SHOPIFY_FLAG_NO_COLOR"] = "1"
    try:
      completed = subprocess.run(command, cwd=project_dir if os.path.isdir(project_dir) else None,
                                 env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                 timeout=FETCH_TIMEOUT_SEC, check=False)
      stdout = completed.stdout or ""
      data = None
      # The CLI may print notices before the JSON; take the last JSON object.
      for candidate in (stdout.strip(), stdout[stdout.find("{"):] if "{" in stdout else ""):
        if not candidate:
          continue
        try:
          data = json.loads(candidate)
          break
        except Exception:
          continue
      if isinstance(data, dict):
        payload["ok"] = True
        payload["data"] = data
      else:
        message = (completed.stderr or stdout or "").strip()
        message = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", message)
        message = re.sub(r"[│╭╮╰╯─]+", " ", message)
        message = re.sub(r"\s+", " ", message).strip()
        payload["error"] = (message[:200] if message else "shopify %s info returned no JSON" % kind)
    except subprocess.TimeoutExpired:
      payload["error"] = "shopify %s info timed out" % kind
    except OSError as error:
      payload["error"] = str(error)
  try:
    atomic_write_json(cache_path, payload)
  finally:
    try:
      os.unlink(marker)
    except OSError:
      pass
  return 0


def theme_details_from(data):
  theme = data.get("theme") if isinstance(data.get("theme"), dict) else data
  return {
    "themeId": str(theme.get("id") or ""),
    "themeName": str(theme.get("name") or ""),
    "themeRole": str(theme.get("role") or ""),
    "detailStore": str(theme.get("shop") or theme.get("store") or data.get("shop") or data.get("store") or ""),
    "previewUrl": str(theme.get("preview_url") or theme.get("previewUrl") or ""),
    "editorUrl": str(theme.get("editor_url") or theme.get("editorUrl") or ""),
  }


def app_details_from(data):
  configuration = data.get("configuration") if isinstance(data.get("configuration"), dict) else {}
  hidden = data.get("_hiddenConfig") if isinstance(data.get("_hiddenConfig"), dict) else {}
  build = configuration.get("build") if isinstance(configuration.get("build"), dict) else {}
  return {
    "appName": str(data.get("name") or configuration.get("name") or ""),
    "clientId": str(configuration.get("client_id") or data.get("client_id") or ""),
    "detailStore": str(hidden.get("dev_store_url") or build.get("dev_store_url") or ""),
    "applicationUrl": str(configuration.get("application_url") or ""),
  }


def cleanup_cache(keep):
  try:
    names = os.listdir(CACHE_DIR)
  except OSError:
    return
  for name in names:
    if not (name.endswith(".json") or name.endswith(".fetching") or name.endswith(".tmp")):
      continue
    base = name.split(".")[0]
    if base in keep:
      continue
    try:
      os.unlink(os.path.join(CACHE_DIR, name))
    except OSError:
      pass


# ------------------------------------------------------------------- status

def build_session(proc, installed, want_details, now):
  pid = proc["pid"]
  flags = dict(read_environ(pid))      # env first …
  flags.update(proc["flags"])          # … explicit flags win
  cwd = ""
  try:
    cwd = os.readlink("/proc/%d/cwd" % pid)
  except OSError:
    pass
  project_dir = flags.get("path") or cwd
  if project_dir and not os.path.isabs(project_dir) and cwd:
    project_dir = os.path.join(cwd, project_dir)
  project_dir = os.path.normpath(project_dir) if project_dir else ""
  # The dev command may come from the repo itself (npm script, Makefile), so
  # `--path` is untrusted and can name a file or a path outside the project.
  # Everything downstream — the "reveal folder" xdg-open, the terminal's
  # --dir=, the fetch cwd — expects a real directory, so fall back to the
  # process's own cwd when it is not one.
  if project_dir and not os.path.isdir(project_dir):
    project_dir = cwd if cwd and os.path.isdir(cwd) else ""
  session = {
    "pid": pid,
    "kind": proc["kind"],
    "projectDir": project_dir,
    "projectName": os.path.basename(project_dir.rstrip("/")) if project_dir else "",
    "startedTs": proc["startedTs"],
    "startTicks": proc["startTicks"],
    "elapsedSec": max(0, now - proc["startedTs"]) if proc["startedTs"] else 0,
    "store": "",
    "storeShort": "",
    "host": flags.get("host") or "",
    "port": 0,
    "themeId": flags.get("theme") or "",
    "themeName": "",
    "themeRole": "",
    "appName": "",
    "clientId": "",
    "previewUrl": "",
    "editorUrl": "",
    "applicationUrl": "",
    "environment": flags.get("environment") or "",
    "authAlias": flags.get("authAlias") or "",
    "config": flags.get("config") or "",
    # theme dev modes worth surfacing when they differ from the defaults
    "themeEditorSync": flags.get("themeEditorSync") == "1",
    "liveReload": flags.get("liveReload") or "",
    # app dev: every TCP port the CLI or one of its children listens on, and
    # the well-known ones derived from them
    "ports": [],
    "graphiqlUrl": "",
    "localAppUrl": "",
    "tunnelUrl": flags.get("tunnelUrl") or "",
    "detailsState": "none",   # none | pending | ready | error
    "detailsError": "",
  }

  store = flags.get("store") or ""
  if proc["kind"] == "theme":
    env_block = theme_environment(project_dir, flags.get("environment"))
    if not store:
      store = env_block.get("store") or ""
    if not session["themeId"]:
      session["themeId"] = env_block.get("theme") or ""
    try:
      session["port"] = int(flags.get("port") or 0)
    except ValueError:
      session["port"] = 0
    if not session["port"]:
      ports = listening_ports([pid])
      session["port"] = ports[0] if ports else DEFAULT_THEME_PORT
    if not session["host"]:
      session["host"] = DEFAULT_THEME_HOST
  else:
    # `shopify app dev` serves GraphiQL itself (default port 3457, the (g)
    # key in its own hint line) and runs the app / extension dev servers as
    # child processes; collect the whole tree's listening ports.
    tree = [pid] + descendants(pid, proc["hz"], proc["btime"])
    ports = listening_ports(tree)
    session["ports"] = ports
    if DEFAULT_GRAPHIQL_PORT in ports:
      session["graphiqlUrl"] = "http://localhost:%d/graphiql" % DEFAULT_GRAPHIQL_PORT
    if flags.get("useLocalhost") == "1":
      try:
        local_port = int(flags.get("localhostPort") or 0)
      except ValueError:
        local_port = 0
      if not local_port:
        others = [port for port in ports if port not in (DEFAULT_GRAPHIQL_PORT, DEFAULT_THEME_APP_EXTENSION_PORT)]
        local_port = others[0] if len(others) == 1 else 0
      if local_port:
        session["localAppUrl"] = "https://localhost:%d" % local_port
    toml_details = app_toml_details(project_dir, flags.get("config"))
    if toml_details:
      session["appName"] = toml_details["appName"]
      session["clientId"] = toml_details["clientId"]
      session["applicationUrl"] = toml_details["applicationUrl"]
      if not store:
        store = toml_details["devStore"]
      session["detailsState"] = "ready"

  cache_key = "%d-%d" % (pid, proc["startTicks"])
  needs_cli = proc["kind"] == "theme" or session["detailsState"] != "ready"
  if want_details and installed and needs_cli and project_dir:
    cache_path = cache_path_for(proc)
    cached = read_cache(cache_path)
    if cached is None:
      session["detailsState"] = "pending"
      start_fetch(proc, cache_path, project_dir)
    elif cached.get("ok") and isinstance(cached.get("data"), dict):
      details = theme_details_from(cached["data"]) if proc["kind"] == "theme" else app_details_from(cached["data"])
      for key, value in details.items():
        if key == "detailStore":
          if not store:
            store = value
        elif value and not session.get(key):
          session[key] = value
      session["detailsState"] = "ready"
    else:
      session["detailsState"] = "error"
      session["detailsError"] = str(cached.get("error") or "Could not read session details")

  session["store"] = normalize_store(store)
  session["storeShort"] = short_store(store)
  return session, cache_key


def version_from_script(script_path):
  """Version from the package.json above a CLI script
  (…/@shopify/cli/bin/run.js → …/@shopify/cli/package.json)."""
  if not script_path:
    return ""
  try:
    directory = os.path.dirname(os.path.realpath(script_path))
  except OSError:
    return ""
  for _ in range(3):
    candidate = os.path.join(directory, "package.json")
    if os.path.isfile(candidate):
      text = read_text(candidate, 1 << 16)
      if '"name": "@shopify/cli"' in text or '"name":"@shopify/cli"' in text:
        marker = text.find('"version"')
        if marker != -1:
          rest = text[marker + len('"version"'):]
          quote = rest.find('"')
          end = rest.find('"', quote + 1) if quote != -1 else -1
          if quote != -1 and end != -1:
            return rest[quote + 1:end]
      return ""
    directory = os.path.dirname(directory)
  return ""


CLI_TARGET_CACHE = os.path.join(CACHE_DIR, "cli-target")


def cli_version(cli_path, hint_scripts):
  """Version of the installed CLI without running it (`shopify version`
  boots node for ~300 ms). Order: the executable on PATH, the script path of
  a running session, a cached target, and finally — when PATH holds a
  version-manager shim such as mise — one `mise which shopify` whose result
  is cached and re-validated by file read on every poll."""
  if not cli_path:
    return ""
  version = version_from_script(cli_path)
  if version:
    return version
  for script in hint_scripts:
    version = version_from_script(script)
    if version:
      _write_cli_target(script)
      return version
  cached = read_text(CLI_TARGET_CACHE, 4096).strip()
  if cached:
    version = version_from_script(cached)
    if version:
      return version
  try:
    real = os.path.basename(os.path.realpath(cli_path))
  except OSError:
    real = ""
  if real == "mise":
    import subprocess
    try:
      completed = subprocess.run(["mise", "which", "shopify"], capture_output=True, text=True, timeout=5, check=False)
      target = (completed.stdout or "").strip().splitlines()
      target = target[-1] if target else ""
    except (OSError, subprocess.TimeoutExpired):
      target = ""
    if target:
      version = version_from_script(target)
      _write_cli_target(target if version else "")
      return version
  return ""


def _write_cli_target(path):
  try:
    os.makedirs(CACHE_DIR, exist_ok=True)
    with open(CLI_TARGET_CACHE, "w", encoding="utf-8") as handle:
      handle.write(str(path or ""))
  except OSError:
    pass


def build_status(want_details):
  now = int(time.time())
  shopify = which("shopify")
  installed = shopify is not None
  sessions = []
  keep = set()
  hint_scripts = []
  for proc in scan_processes():
    try:
      session, cache_key = build_session(proc, installed, want_details, now)
    except Exception:
      # Skip a session we cannot describe rather than failing the whole poll
      # and leaving the panel stale for every other session.
      continue
    sessions.append(session)
    keep.add(cache_key)
    index = cli_index(proc["argv"])
    if index >= 0:
      hint_scripts.append(proc["argv"][index])
  cleanup_cache(keep)
  theme_count = sum(1 for item in sessions if item["kind"] == "theme")
  app_count = sum(1 for item in sessions if item["kind"] == "app")
  return {
    "ok": True,
    "helperVersion": HELPER_VERSION,
    "installed": installed,
    "cliPath": shopify or "",
    "cliVersion": cli_version(shopify, hint_scripts) if installed else "",
    "detailsEnabled": bool(want_details),
    "generatedTs": now,
    "themeCount": theme_count,
    "appCount": app_count,
    "sessions": sessions,
  }


# The panel captures a pid at poll time; by the time the user clicks Stop the
# session may have exited and Linux may have recycled that pid to another of
# the user's processes. Signal only when the process at that pid still has the
# exact start time the session was seen with, so a recycled pid is left alone.
def run_signal(args):
  """--signal <pid> <startTicks> <INT|TERM>"""
  if len(args) < 3:
    return 2
  try:
    pid = int(args[0])
    want_ticks = int(args[1])
  except ValueError:
    return 2
  name = str(args[2]).upper()
  import signal as signal_module
  sig = {"INT": signal_module.SIGINT, "TERM": signal_module.SIGTERM}.get(name)
  if sig is None or pid <= 1:
    return 2
  # An unknown start time (0) must never match: /proc/<pid>/stat being
  # unreadable would otherwise let a recycled pid pass the identity check.
  if want_ticks <= 0:
    return 2
  try:
    if os.stat("/proc/%d" % pid).st_uid != os.getuid():
      return 1
  except OSError:
    return 1

  # Delivering the signal to a numeric pid is a TOCTOU: the process can exit
  # and the pid be recycled between the start-time check and the kill, so the
  # signal would hit an unrelated process. A pidfd pins the exact process
  # instance — pidfd_send_signal is delivered to that instance or fails with
  # ESRCH, never to a reused pid. We open the pidfd first, then confirm the
  # pinned process still has the session's start time, then signal the fd.
  pidfd_open = getattr(os, "pidfd_open", None)
  pidfd_send = getattr(signal_module, "pidfd_send_signal", None)
  if pidfd_open is not None and pidfd_send is not None:
    try:
      pidfd = pidfd_open(pid)
    except OSError:
      return 1
    try:
      _, start_ticks, _ = process_start(pid, clock_ticks(), 0)
      if start_ticks != want_ticks:
        return 1
      pidfd_send(pidfd, sig)
      return 0
    except (OSError, ValueError):
      return 1
    finally:
      os.close(pidfd)

  # Fallback for kernels/interpreters without pidfd: re-check immediately
  # before the kill to narrow (not eliminate) the window.
  _, start_ticks, _ = process_start(pid, clock_ticks(), 0)
  if start_ticks != want_ticks:
    return 1
  _, start_ticks2, _ = process_start(pid, clock_ticks(), 0)
  if start_ticks2 != want_ticks:
    return 1
  try:
    os.kill(pid, sig)
  except OSError:
    return 1
  return 0


def main(argv):
  if argv and argv[0] == "--fetch":
    return run_fetch(argv[1:])
  if argv and argv[0] == "--signal":
    return run_signal(argv[1:])
  want_details = "--no-details" not in argv
  # Paths read from /proc can hold non-UTF-8 bytes (surrogateescape), which
  # print() refuses to encode. Write bytes with replacement instead.
  payload = _json_dumps(build_status(want_details)).encode("utf-8", "replace")
  sys.stdout.buffer.write(payload + b"\n")
  sys.stdout.buffer.flush()
  return 0


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
