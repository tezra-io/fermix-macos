#!/bin/bash
#
# The half of the cloud acceptance loop that runs ON the rented Mac.
#
# scripts/cloud_acceptance.sh uploads this file with an env.sh beside it, then
# calls one verb per ssh session. It runs under the Mac's own /bin/bash (3.2),
# as the account Scaleway delivers, inside that account's console session: the
# login item, the launchd agent and every privacy prompt live in that session,
# which is why the driver logs the console in before it calls anything here.
#
# Verbs:
#   prepare                   passwordless sudo, no sleep, autologin for the console;
#                             the account password arrives on stdin, never in argv
#   console                   the user who owns the console (loginwindow owns it as root)
#   reset                     the Stage 0 reset protocol (STAGE0_RUNBOOK §10), prepared hosts only
#   fetch-release <tag> <ver> the release DMG and its sha256 sidecar into artifacts/
#   gate-dmg <dmg>            STAGE0 §8: quarantine, both spctl verdicts, both staples
#   install-dmg <dmg>         mount, copy into the Applications folder, strip quarantine
#   install-zip <zip>         a signed-only candidate, unzipped into the Applications folder
#   activate                  first launch: open the app, open <scheme>://setup, wait for the daemon
#   launch                    a later launch: open the app, wait for the daemon
#   verify                    the probe set (see verify below)
#   quit-gui                  SIGTERM the GUI and prove the daemon keeps answering
#   relaunch                  open the app again and prove both are back
#   chat <text>               one message over the companion wire
#   agent-requirement         the agent's designated requirement (STAGE0 §6)
#   collect                   evidence files into runs/<run id>/
#   reboot                    sudo shutdown -r now
# Artifact names are relative to artifacts/; the driver puts every file there.
#
# Output protocol, one record per line, read by the driver:
#   check|<name>|PASS|<detail>   a gate this run asserts
#   check|<name>|FAIL|<detail>
#   check|<name>|SKIP|<why>      a gate this build or this Mac cannot run
#   fact|<key>|<value>           evidence recorded, not judged
# A refusal (misuse, a missing precondition) exits non-zero with "refusal: ..."
# on stderr. A failed check never exits non-zero: the driver decides the run.
#
# Every python3 call passes a purpose word first (`python3 - <purpose> ...`),
# so the harness can stand in for the two socket clients and pass the JSON
# readers through to the real interpreter.
set -euo pipefail

refuse() {
  echo "refusal: $*" >&2
  exit 1
}

# One record per line: newlines and pipes inside a detail would break the
# driver's parse, so they become spaces.
oneline() {
  printf '%s' "${1:-}" | tr '\n|' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

check() { printf 'check|%s|%s|%s\n' "$1" "$2" "$(oneline "$3")"; }
fact() { printf 'fact|%s|%s\n' "$1" "$(oneline "$2")"; }

require_configuration() {
  local name
  for name in FX_RUN_ID FX_REPOSITORY FX_ARTIFACT_NAME FX_APP_BUNDLE_NAME FX_BUNDLE_ID \
    FX_URL_SCHEME FX_GUI_EXECUTABLE FX_AGENT_EXECUTABLE FX_AGENT_LABEL FX_SUPPORT_DIR \
    FX_ENGINE_RELATIVE_PATH FX_PORT FX_LOG_SUBSYSTEM; do
    [ -n "${!name:-}" ] || refuse "$name is not set; this file is run by scripts/cloud_acceptance.sh"
  done
}

# Where a user's Mac keeps apps. The harness points it at a scratch folder so a
# case never touches the machine it runs on.
APPLICATIONS="${APPLICATIONS:-/Applications}"

configure_paths() {
  WORK="$HOME/fermix-acceptance"
  ARTIFACTS="$WORK/artifacts"
  RUN="$WORK/runs/$FX_RUN_ID"
  PREPARED="$WORK/prepared"
  APP="$APPLICATIONS/$FX_APP_BUNDLE_NAME"
  GUI="$APP/Contents/MacOS/$FX_GUI_EXECUTABLE"
  AGENT="$APP/Contents/MacOS/$FX_AGENT_EXECUTABLE"
  FERMIX_HOME="$HOME/.fermix"
  SUPPORT="$HOME/Library/Application Support/$FX_SUPPORT_DIR"
  RECORD="$SUPPORT/launcher.json"
}

# ---- probes ------------------------------------------------------------------

console_user() { stat -f %Su /dev/console; }

# The GUI's own process: its path is a prefix of the agent's, so the match is
# anchored on both sides.
gui_pid() { pgrep -f "^$GUI( |\$)" | head -1 | grep .; }

live() { curl -sf -m 3 "http://127.0.0.1:$FX_PORT/health/live" >/dev/null 2>&1; }

# What launchd says about the agent's job. A spawn refused by macOS never reaches
# the engine's logs; "state = spawn failed" here is the fact.
agent_job_state() {
  launchctl print "gui/$(id -u)/$FX_AGENT_LABEL" 2>/dev/null |
    sed -n -E 's/^[[:space:]]*((job )?state|pid|last exit code|program) = (.*)$/\1 = \3/p' |
    paste -sd ';' - || true
}

# Background Task Management's disposition for one identifier: the agent's
# label, or the bundle identifier for the app's own login item. The disposition
# line comes before the identifier line in dumpbtm's record.
btm_disposition() {
  sudo sfltool dumpbtm 2>/dev/null |
    awk -v id="$1" '
      /Disposition:/ { disposition = $0 }
      /Identifier:/ && $NF == id { sub(/^[[:space:]]*Disposition:[[:space:]]*/, "", disposition); print disposition; exit }
    ' || true
}

btm_record_count() {
  sudo sfltool dumpbtm 2>/dev/null | awk -v id="$1" '/Identifier:/ && $NF == id { n++ } END { print n + 0 }' || true
}

installed_build() { defaults read "$APP/Contents/Info" CFBundleVersion; }
installed_version() { defaults read "$APP/Contents/Info" CFBundleShortVersionString; }
installed_facts() {
  fact installed_version "$(installed_version)"
  fact installed_build "$(installed_build)"
}

# One value out of a JSON document, by dotted path. Non-zero when the path is
# absent, so a caller can tell "no such field" from an empty one.
json_path() {
  python3 - json-path "$1" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[2]))
for key in sys.argv[3].split("."):
    if not isinstance(value, dict) or key not in value:
        sys.exit(1)
    value = value[key]
print(json.dumps(value) if isinstance(value, (dict, list)) else value)
PY
}

# One management request over daemon.sock: a 4-byte big-endian length, then the
# JSON (management/PROTOCOL.md, Transport). Prints the response; non-zero when
# the daemon refused or did not answer, with the reason on stdout so a check can
# carry it.
manage() {
  python3 - manage "$FERMIX_HOME/daemon.sock" "$1" "$2" <<'PY'
import json, socket, struct, sys
path, method, version = sys.argv[2], sys.argv[3], int(sys.argv[4])
request = {"request_id": "acceptance-" + method, "protocol_version": version, "method": method, "params": {}}
body = json.dumps(request).encode()
try:
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(20)
    connection.connect(path)
    connection.sendall(struct.pack(">I", len(body)) + body)

    def exactly(count):
        data = b""
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise ConnectionError("the daemon closed the connection mid-frame")
            data += chunk
        return data

    length = struct.unpack(">I", exactly(4))[0]
    answer = exactly(length).decode()
except (OSError, ConnectionError) as error:
    print("no answer from %s: %s" % (path, error))
    sys.exit(1)
print(answer)
sys.exit(1 if "error" in json.loads(answer) else 0)
PY
}

gating_failures() {
  python3 - gating-failures "$1" <<'PY'
import json, sys
state = json.load(open(sys.argv[2])).get("result", {})
failures = [f for f in state.get("readiness", {}).get("failures", []) if f.get("gating")]
print(", ".join("%s (%s)" % (f.get("component", "?"), f.get("pane", "?")) for f in failures) or "none")
PY
}

configured_providers() {
  python3 - configured-providers "$1" <<'PY'
import json, sys
state = json.load(open(sys.argv[2])).get("result", {})
print(", ".join(p.get("id", "?") for p in state.get("providers", []) if p.get("configured")) or "none")
PY
}

# One turn over the companion wire (companion/PROTOCOL.md, Chat sequence):
# newline-delimited JSON, client_hello then msg, read until the turn ends.
companion_turn() {
  python3 - companion "$1" "$2" "$3" <<'PY'
import json, socket, sys
path, text, timeout = sys.argv[2], sys.argv[3], float(sys.argv[4])
try:
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(timeout)
    connection.connect(path)
except OSError as error:
    print("event|closed|%s" % error)
    sys.exit(0)
stream = connection.makefile("rwb", buffering=0)

def send(event):
    stream.write((json.dumps(event) + "\n").encode())

def receive():
    line = stream.readline()
    return json.loads(line) if line else None

send({"type": "client_hello", "protocol_version": 1})
hello = receive()
if hello is None or hello.get("type") != "server_hello":
    print("event|closed|no server_hello: %s" % json.dumps(hello))
    sys.exit(0)
print("event|server_hello|versions %s to %s" % (hello.get("min_version"), hello.get("max_version")))
send({"type": "msg", "client_msg_id": "acceptance-1", "profile_id": "main", "text": text, "attach_ids": []})
while True:
    try:
        event = receive()
    except socket.timeout:
        print("event|timeout|no terminal event within %ds" % timeout)
        break
    if event is None:
        print("event|closed|the daemon closed the connection")
        break
    kind = event.get("type")
    if kind == "accepted":
        print("event|accepted|duplicate=%s" % event.get("duplicate"))
    elif kind == "text_done":
        print("event|text_done|%s" % event.get("text", ""))
        break
    elif kind == "turn_error":
        print("event|turn_error|%s: %s" % (event.get("code"), event.get("message")))
        break
    elif kind == "error":
        print("event|error|%s: %s" % (event.get("reason"), event.get("message", "")))
        break
PY
}

# ---- verbs -------------------------------------------------------------------

prepare() {
  local password me console
  IFS= read -r password || refuse "prepare reads the account password from stdin"
  [ -n "$password" ] || refuse "prepare reads the account password from stdin"
  me="$(id -un)"
  if ! sudo -n true 2>/dev/null; then
    printf '%s\n' "$password" |
      sudo -S -p '' sh -c "printf '%s ALL=(ALL) NOPASSWD: ALL\n' '$me' >/etc/sudoers.d/fermix-acceptance && chmod 0440 /etc/sudoers.d/fermix-acceptance" ||
      refuse "could not grant passwordless sudo to $me; the password is the console's sudo password"
  fi
  # A datacenter Mac that sleeps is a Mac whose agent stops answering.
  sudo pmset -a sleep 0 displaysleep 0 disksleep 0
  mkdir -p "$ARTIFACTS" "$RUN"
  : >"$PREPARED"
  console="$(console_user)"
  if [ "$console" != "$me" ]; then
    # loginwindow owns the console. Autologin puts this account's session there
    # on the next boot, which the driver performs.
    sudo sysadminctl -autologin set -userName "$me" -password "$password" >/dev/null 2>&1 ||
      refuse "sysadminctl could not set autologin for $me"
    fact autologin "set for $me; a reboot logs the console in"
  fi
  fact console "$console"
}

require_prepared() {
  [ -f "$PREPARED" ] || refuse "this Mac was not prepared by cloud_acceptance.sh; reset runs only on the rented test Mac"
}

# STAGE0_RUNBOOK §10. The bundle withdraws its own registrations first, because
# a bundle in the Trash cannot. resetbtm is the runbook's last resort, and on a
# rented test Mac there are no other apps' choices to keep.
reset() {
  require_prepared
  if [ -x "$GUI" ]; then
    "$GUI" --unregister-login-items || fact unregister "--unregister-login-items exited $?"
  fi
  pkill -f "$APP/Contents/MacOS/" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$FX_AGENT_LABEL" 2>/dev/null || true
  if [ -n "$(btm_disposition "$FX_AGENT_LABEL")$(btm_disposition "$FX_BUNDLE_ID")" ]; then
    sudo sfltool resetbtm
    fact reset "sfltool resetbtm ran because a registration survived --unregister-login-items"
  fi
  rm -rf "$APP" "$HOME/Applications/$FX_APP_BUNDLE_NAME" "$SUPPORT" "$FERMIX_HOME" \
    "$HOME/Library/Caches/$FX_BUNDLE_ID" "$HOME/Library/Preferences/$FX_BUNDLE_ID.plist"
  # tccutil answers non-zero for an identifier it holds no rows for, which is
  # the state a fresh account is in.
  tccutil reset All "$FX_BUNDLE_ID" >/dev/null 2>&1 || true
  fact reset "fresh account: no bundle, record, home, caches, preferences or privacy rows for $FX_BUNDLE_ID"
}

fetch_release() {
  local tag="$1" version="$2" name dmg base actual expected
  name="$FX_ARTIFACT_NAME-$version.dmg"
  dmg="$ARTIFACTS/$name"
  base="https://github.com/$FX_REPOSITORY/releases/download/$tag"
  curl -fsSL --retry 3 -o "$dmg" "$base/$name" || refuse "could not download $base/$name"
  curl -fsSL --retry 3 -o "$dmg.sha256" "$base/$name.sha256" || refuse "could not download $base/$name.sha256"
  actual="$(shasum -a 256 "$dmg" | awk '{print $1}')"
  expected="$(awk '{print $1}' "$dmg.sha256")"
  [ "$actual" = "$expected" ] || refuse "$name digest $actual is not the release's $expected"
  fact artifact "$name from $base"
  fact artifact_sha256 "$actual"
}

# STAGE0_RUNBOOK §8, the sequence the release runner also runs. Both verdicts
# must read accepted with source=Notarized Developer ID.
gate_dmg() {
  local dmg="$ARTIFACTS/$1" mount verdict
  [ -f "$dmg" ] || refuse "no disk image at $dmg"
  # Simulate a browser download; a headless spctl otherwise never sees quarantine.
  xattr -w com.apple.quarantine "0081;$(date +%s);Safari;$(uuidgen)" "$dmg" || refuse "could not quarantine $1"
  spctl_verdict gatekeeper_dmg -t open --context context:primary-signature "$dmg"
  mount="$(mktemp -d)"
  hdiutil attach "$dmg" -nobrowse -quiet -mountpoint "$mount" || refuse "could not mount $1"
  spctl_verdict gatekeeper_app -t exec "$mount/$FX_APP_BUNDLE_NAME"
  stapler_verdict stapled_dmg "$dmg"
  stapler_verdict stapled_app "$mount/$FX_APP_BUNDLE_NAME"
  hdiutil detach "$mount" -quiet
}

spctl_verdict() {
  local name="$1" verdict
  shift
  if verdict="$(spctl -a -vv "$@" 2>&1)" && [[ "$verdict" == *"Notarized Developer ID"* ]]; then
    check "$name" PASS "$verdict"
  else
    check "$name" FAIL "$verdict"
  fi
}

stapler_verdict() {
  local verdict
  if verdict="$(xcrun stapler validate "$2" 2>&1)"; then
    check "$1" PASS "$verdict"
  else
    check "$1" FAIL "$verdict"
  fi
}

install_dmg() {
  local dmg="$ARTIFACTS/$1" mount
  [ -f "$dmg" ] || refuse "no disk image at $dmg"
  mount="$(mktemp -d)"
  hdiutil attach "$dmg" -nobrowse -quiet -mountpoint "$mount" || refuse "could not mount $1"
  [ -d "$mount/$FX_APP_BUNDLE_NAME" ] || refuse "$1 carries no $FX_APP_BUNDLE_NAME"
  rm -rf "$APP"
  cp -R "$mount/$FX_APP_BUNDLE_NAME" "$APPLICATIONS/" || refuse "could not copy $FX_APP_BUNDLE_NAME into $APPLICATIONS"
  hdiutil detach "$mount" -quiet
  # The copy inherits the image's quarantine. Gatekeeper's verdict is already on
  # record from gate-dmg; the first-launch Open dialog needs a click nobody is
  # here to give, so the attribute goes and the fact says so.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  fact quarantine "stripped after the spctl assessment, so the first-launch Open dialog is not exercised"
  installed_facts
}

install_zip() {
  local zip="$ARTIFACTS/$1"
  [ -f "$zip" ] || refuse "no archive at $zip"
  rm -rf "$APP"
  ditto -x -k "$zip" "$APPLICATIONS/" || refuse "could not unpack $1"
  [ -d "$APP" ] || refuse "$1 did not unpack to $APP"
  installed_facts
}

wait_gui() {
  local seconds="$1" phase="$2" i
  for ((i = 0; i < seconds; i++)); do
    if gui_pid >/dev/null; then
      check "gui_running_after_$phase" PASS "pid $(gui_pid) after ${i}s"
      return 0
    fi
    sleep 1
  done
  check "gui_running_after_$phase" FAIL "no process for $GUI within ${seconds}s"
}

wait_live() {
  local seconds="$1" phase="$2" i
  for ((i = 0; i < seconds; i++)); do
    if live; then
      check "daemon_live_after_$phase" PASS "http://127.0.0.1:$FX_PORT/health/live answered after ${i}s"
      return 0
    fi
    sleep 1
  done
  check "daemon_live_after_$phase" FAIL "no answer on 127.0.0.1:$FX_PORT within ${seconds}s; launchd says: $(agent_job_state)"
}

open_app() {
  [ -d "$APP" ] || refuse "nothing installed at $APP"
  open -a "$APP"
}

# First launch lands on Welcome; <scheme>://setup runs the Starting ladder the
# Welcome button would (STAGE0_RUNBOOK §9), which registers the agent.
activate() {
  open_app
  wait_gui 30 activation
  sleep 3
  open "$FX_URL_SCHEME://setup"
  wait_live 150 activation
  installed_facts
}

launch() {
  open_app
  wait_gui 30 launch
  wait_live 150 launch
  installed_facts
}

verify() {
  local pid disposition state
  if pid="$(gui_pid)"; then
    check gui_running PASS "pid $pid"
  else
    check gui_running FAIL "no process for $GUI"
  fi

  disposition="$(btm_disposition "$FX_AGENT_LABEL")"
  case "$disposition" in
    "") check agent_registered FAIL "Background Task Management has no record for $FX_AGENT_LABEL" ;;
    *disallowed*) check agent_registered FAIL "$disposition: switched off in Login Items" ;;
    *enabled*) check agent_registered PASS "$disposition" ;;
    *) check agent_registered FAIL "$disposition" ;;
  esac
  fact agent_records "$(btm_record_count "$FX_AGENT_LABEL")"

  disposition="$(btm_disposition "$FX_BUNDLE_ID")"
  case "$disposition" in
    "") check login_item_registered FAIL "Background Task Management has no record for $FX_BUNDLE_ID" ;;
    *enabled*) check login_item_registered PASS "$disposition" ;;
    *) check login_item_registered FAIL "$disposition" ;;
  esac

  state="$(agent_job_state)"
  case "$state" in
    *"state = running"*) check agent_job PASS "$state" ;;
    "") check agent_job FAIL "launchd has no job gui/$(id -u)/$FX_AGENT_LABEL" ;;
    *) check agent_job FAIL "$state" ;;
  esac

  if live; then
    check daemon_live PASS "http://127.0.0.1:$FX_PORT/health/live answers"
  else
    check daemon_live FAIL "no answer on http://127.0.0.1:$FX_PORT/health/live"
  fi
  if [ -S "$FERMIX_HOME/daemon.sock" ]; then
    check daemon_socket PASS "$FERMIX_HOME/daemon.sock"
  else
    check daemon_socket FAIL "no socket at $FERMIX_HOME/daemon.sock"
  fi

  verify_engine_identity
  verify_receipt
  verify_readiness
}

# The daemon's own identity from hello, and whether it is the engine the
# installed bundle carries: after an upgrade a stale daemon answering on the
# old engine is the defect this catches.
verify_engine_identity() {
  local answer running bundled arch
  rm -f "$RUN/hello.json"
  if ! answer="$(manage hello 1)"; then
    check engine_hello FAIL "$answer"
    return 0
  fi
  printf '%s\n' "$answer" >"$RUN/hello.json"
  if ! running="$(json_path "$RUN/hello.json" result.engine.source_commit)"; then
    check engine_hello FAIL "hello answered without an engine identity: $answer"
    return 0
  fi
  arch="$(json_path "$RUN/hello.json" result.engine.architecture)"
  fact engine_version "$(json_path "$RUN/hello.json" result.engine.product_version)"
  fact engine_build "$(json_path "$RUN/hello.json" result.engine.build_id)"
  fact engine_commit "$running"
  fact engine_architecture "$arch"
  check engine_hello PASS "engine $(json_path "$RUN/hello.json" result.engine.product_version) build $(json_path "$RUN/hello.json" result.engine.build_id) on $arch"
  if bundled="$(json_path "$APP/$FX_ENGINE_RELATIVE_PATH/$arch/engine-manifest.json" identity.source_commit 2>/dev/null)"; then
    if [ "$bundled" = "$running" ]; then
      check engine_is_bundled PASS "running commit ${running:0:12} is the installed bundle's"
    else
      check engine_is_bundled FAIL "running commit ${running:0:12}, the installed bundle carries ${bundled:0:12}"
    fi
  else
    check engine_is_bundled FAIL "the installed bundle carries no readable engine manifest for $arch"
  fi
}

# The bootstrap record's receipt names the build that registered the agent.
# A drag-over or brew upgrade rebuilds it on the new build's first launch.
verify_receipt() {
  local installed recorded
  if ! installed="$(installed_build 2>/dev/null)"; then
    check registration_receipt FAIL "no installed bundle at $APP to read a build from"
    return 0
  fi
  if [ ! -f "$RECORD" ]; then
    check registration_receipt FAIL "no bootstrap record at $RECORD"
    return 0
  fi
  cp "$RECORD" "$RUN/launcher.json"
  if ! recorded="$(json_path "$RECORD" registered_app_build 2>/dev/null)"; then
    check registration_receipt FAIL "the bootstrap record carries no registration receipt"
    return 0
  fi
  if [ "$recorded" = "$installed" ]; then
    check registration_receipt PASS "build $installed registered the agent"
  else
    check registration_receipt FAIL "the receipt names build $recorded, the installed app is build $installed"
  fi
}

# What the daemon publishes about its own readiness (setup.state.get, protocol
# version 2). Recorded, not judged: a fresh account gates on setup by design.
verify_readiness() {
  local maximum answer
  if [ ! -f "$RUN/hello.json" ]; then
    check readiness SKIP "no hello answer to negotiate a protocol version with"
    return 0
  fi
  maximum="$(json_path "$RUN/hello.json" result.protocol.maximum_version)"
  if [ "$maximum" -lt 2 ]; then
    check readiness SKIP "this engine's management protocol stops at version $maximum; setup.state.get needs 2"
    return 0
  fi
  if ! answer="$(manage setup.state.get 2)"; then
    check readiness FAIL "$answer"
    return 0
  fi
  printf '%s\n' "$answer" >"$RUN/setup-state.json"
  check readiness PASS "status $(json_path "$RUN/setup-state.json" result.readiness.status)"
  fact readiness_gating "$(gating_failures "$RUN/setup-state.json")"
  fact providers_configured "$(configured_providers "$RUN/setup-state.json")"
}

# A GUI quit is never a daemon command. SIGTERM enters the app's ordinary
# termination; osascript's quit would need an Automation grant no ssh session
# can be asked for.
quit_gui() {
  local pid i
  if ! pid="$(gui_pid)"; then
    check gui_quit SKIP "no GUI process to quit"
    return 0
  fi
  kill -TERM "$pid"
  for ((i = 0; i < 20; i++)); do
    gui_pid >/dev/null || break
    sleep 1
  done
  if gui_pid >/dev/null; then
    check gui_quit FAIL "pid $pid still running 20s after SIGTERM"
  else
    check gui_quit PASS "pid $pid exited within ${i}s"
  fi
  if live; then
    check daemon_survives_gui_quit PASS "the daemon still answers"
  else
    check daemon_survives_gui_quit FAIL "the daemon stopped answering when the GUI quit"
  fi
}

relaunch() {
  open_app
  wait_gui 30 relaunch
  wait_live 30 relaunch
}

chat() {
  local text="$1" sock="$FERMIX_HOME/companion.sock" configured events
  if [ ! -S "$sock" ]; then
    check chat SKIP "this engine serves no companion socket, so Chat shows its no-chat sentence"
    return 0
  fi
  if [ ! -f "$RUN/setup-state.json" ]; then
    check chat SKIP "no readiness answer to read a provider from; verify runs first"
    return 0
  fi
  configured="$(configured_providers "$RUN/setup-state.json")"
  if [ "$configured" = none ]; then
    check chat SKIP "no provider is configured; sign in or store a key over VNC, then rerun with --chat"
    return 0
  fi
  events="$(companion_turn "$sock" "$text" 120)"
  printf '%s\n' "$events" >"$RUN/chat-events.txt"
  if grep -q '^event|server_hello|' <<<"$events"; then
    check chat_handshake PASS "$(grep -m1 '^event|server_hello|' <<<"$events" | cut -d'|' -f3-)"
  else
    check chat_handshake FAIL "$(head -1 <<<"$events" | cut -d'|' -f2-)"
    return 0
  fi
  if grep -q '^event|text_done|' <<<"$events"; then
    check chat_reply PASS "$(grep -m1 '^event|text_done|' <<<"$events" | cut -d'|' -f3- | cut -c1-200)"
  else
    check chat_reply FAIL "$(tail -1 <<<"$events" | cut -d'|' -f2-)"
  fi
}

agent_requirement() {
  [ -x "$AGENT" ] || refuse "no agent executable at $AGENT"
  fact agent_requirement "$(codesign -d -r- "$AGENT" 2>&1 | grep '^designated' || echo "no designated requirement")"
}

# Evidence, not verdicts: a collector that answers with an error writes that
# error into its file, which is why every line tolerates a non-zero status.
collect() {
  local uid
  uid="$(id -u)"
  mkdir -p "$RUN"
  sw_vers >"$RUN/sw_vers.txt" 2>&1 || true
  spctl --status >"$RUN/spctl-status.txt" 2>&1 || true
  # The redirects run as the account on purpose: the evidence belongs to it.
  # shellcheck disable=SC2024
  sudo profiles list >"$RUN/profiles.txt" 2>&1 || true
  # shellcheck disable=SC2024
  sudo sfltool dumpbtm >"$RUN/dumpbtm-full.txt" 2>&1 || true
  grep -B 9 -A 9 -F "$FX_BUNDLE_ID" "$RUN/dumpbtm-full.txt" >"$RUN/dumpbtm.txt" 2>&1 || true
  launchctl print "gui/$uid/$FX_AGENT_LABEL" >"$RUN/launchctl-agent.txt" 2>&1 || true
  {
    echo "version $(installed_version 2>&1) build $(installed_build 2>&1)"
    codesign -dv --verbose=2 "$APP" 2>&1
  } >"$RUN/installed.txt" || true
  curl -s -m 3 "http://127.0.0.1:$FX_PORT/health/live" >"$RUN/health.txt" 2>&1 || true
  ls -la "$FERMIX_HOME" >"$RUN/fermix-home.txt" 2>&1 || true
  log show --last 20m --style compact --predicate "subsystem == \"$FX_LOG_SUBSYSTEM\"" >"$RUN/log-app.txt" 2>&1 || true
  log show --last 20m --style compact --predicate "eventMessage CONTAINS \"$FX_AGENT_LABEL\" OR eventMessage CONTAINS \"$FX_BUNDLE_ID\"" >"$RUN/log-system.txt" 2>&1 || true
  fact evidence "$RUN"
}

reboot_mac() {
  sudo shutdown -r now
}

dispatch() {
  local verb="${1:-}"
  shift || true
  case "$verb" in
    prepare) prepare ;;
    console) console_user ;;
    reset) reset ;;
    fetch-release)
      [ $# -eq 2 ] || refuse "usage: fetch-release <tag> <version>"
      fetch_release "$1" "$2"
      ;;
    gate-dmg)
      [ $# -eq 1 ] || refuse "usage: gate-dmg <dmg-name>"
      gate_dmg "$1"
      ;;
    install-dmg)
      [ $# -eq 1 ] || refuse "usage: install-dmg <dmg-name>"
      install_dmg "$1"
      ;;
    install-zip)
      [ $# -eq 1 ] || refuse "usage: install-zip <zip-name>"
      install_zip "$1"
      ;;
    activate) activate ;;
    launch) launch ;;
    verify) verify ;;
    quit-gui) quit_gui ;;
    relaunch) relaunch ;;
    chat)
      [ $# -eq 1 ] || refuse "usage: chat <text>"
      chat "$1"
      ;;
    agent-requirement) agent_requirement ;;
    collect) collect ;;
    reboot) reboot_mac ;;
    *) refuse "usage: remote.sh prepare | console | reset | fetch-release <tag> <version> | gate-dmg <dmg> | install-dmg <dmg> | install-zip <zip> | activate | launch | verify | quit-gui | relaunch | chat <text> | agent-requirement | collect | reboot" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ENV_FILE="$(cd "$(dirname "$0")" && pwd)/env.sh"
  [ -f "$ENV_FILE" ] || refuse "no env.sh beside $0; this file is run by scripts/cloud_acceptance.sh"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  require_configuration
  configure_paths
  mkdir -p "$ARTIFACTS" "$RUN"
  dispatch "$@"
fi
