#!/usr/bin/env bash
#
# Harness for scripts/cloud_acceptance.sh and scripts/cloud_acceptance_remote.sh.
#
# Host-safe and offline: Scaleway, ssh, scp, gh and every macOS command the two
# halves run are doubles that record what they were asked and answer from
# control files, so a case states the Mac it wants and proves what the loop
# did about it. The remote half is sourced with HOME and the Applications
# folder pointed into the scratch directory: nothing here reads or writes the
# machine it runs on, and no server is ever created.
#
# Usage: cloud_acceptance_test.sh
set -euo pipefail

TEST_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CONTROL="$WORK_DIR/control"
EVENTS="$WORK_DIR/events"
OUT="$WORK_DIR/out"
ERR="$WORK_DIR/err"
REAL_USER="$(id -un)"

fail() {
  echo "cloud_acceptance_test: $*" >&2
  exit 1
}

event() { printf '%s\n' "$*" >>"$EVENTS"; }

expect_event() {
  grep -qF -- "$1" "$EVENTS" || fail "$2: expected the event '$1'; events were: $(paste -sd ';' "$EVENTS")"
}

expect_no_event() {
  if grep -qF -- "$1" "$EVENTS"; then fail "$2: did not expect the event '$1'"; fi
}

# The order two events happened in, which is what an upgrade or a reboot proves.
expect_order() {
  local first second
  first="$(grep -nF -- "$1" "$EVENTS" | head -1 | cut -d: -f1)"
  second="$(grep -nF -- "$2" "$EVENTS" | head -1 | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] ||
    fail "$3: expected '$1' before '$2'; events were: $(paste -sd ';' "$EVENTS")"
}

# The first event against the last of the other, for a step the loop repeats.
expect_order_last() {
  local first second
  first="$(grep -nF -- "$1" "$EVENTS" | head -1 | cut -d: -f1)"
  second="$(grep -nF -- "$2" "$EVENTS" | tail -1 | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ] ||
    fail "$3: expected '$1' before the last '$2'; events were: $(paste -sd ';' "$EVENTS")"
}

pass() { echo "  ok   $*"; }

# ---- doubles shared by both halves ------------------------------------------

sleep() { :; }
date() { printf '1700000000\n'; }
uuidgen() { printf 'UUID\n'; }
security() { cat "$CONTROL/identities"; }
git() { printf 'abc1234\n'; }

python3() {
  case "${2:-}" in
    manage)
      if [ -f "$CONTROL/manage-$4.json" ]; then
        cat "$CONTROL/manage-$4.json"
        ! grep -q '"error"' "$CONTROL/manage-$4.json"
      else
        echo "no answer from $3: [Errno 61] Connection refused"
        return 1
      fi
      ;;
    companion) cat "$CONTROL/companion-events" ;;
    *) command python3 "$@" ;;
  esac
}

# ---- the remote half --------------------------------------------------------

export HOME="$WORK_DIR/home"
export FX_RUN_ID=run1 FX_REPOSITORY=tezra-io/fermix-macos FX_ARTIFACT_NAME=Fermix \
  FX_APP_BUNDLE_NAME=Fermix.app FX_BUNDLE_ID=io.tezra.FermixPet FX_URL_SCHEME=fermix \
  FX_GUI_EXECUTABLE=Fermix FX_AGENT_EXECUTABLE=FermixAgent FX_AGENT_LABEL=io.tezra.FermixPet.agent \
  FX_SUPPORT_DIR=Fermix FX_ENGINE_RELATIVE_PATH=Contents/Resources/Engine FX_PORT=4030 \
  FX_LOG_SUBSYSTEM=ai.fermix.app
APPLICATIONS="$WORK_DIR/Applications"

stat() { cat "$CONTROL/console"; }
sudo() {
  event "sudo $*"
  case "$1" in
    -n) [ -f "$CONTROL/sudo-nopass" ] ;;
    -S) : ;;
    *) "$@" ;;
  esac
}
pmset() { event "pmset $*"; }
sysadminctl() { event "sysadminctl $1 $2 $3 $4"; }
profiles() { echo "no configuration profiles"; }
sfltool() {
  case "$1" in
    dumpbtm) cat "$CONTROL/btm" 2>/dev/null || true ;;
    resetbtm)
      event resetbtm
      rm -f "$CONTROL/btm"
      ;;
  esac
}
launchctl() {
  case "$1" in
    print)
      if [ -f "$CONTROL/launchctl" ]; then
        cat "$CONTROL/launchctl"
      else
        echo "Could not find service" >&2
        return 113
      fi
      ;;
    bootout) event "bootout $2" ;;
  esac
}
curl() {
  local out="" url="${!#}"
  event "curl $url"
  while [ $# -gt 0 ]; do
    case "$1" in
      -o)
        out="$2"
        shift
        ;;
    esac
    shift
  done
  if [ -n "$out" ]; then
    case "$out" in
      *.sha256)
        if [ -f "$CONTROL/tampered-sha" ]; then
          echo 0000 >"$out"
        else
          shasum -a 256 "$CONTROL/fake.dmg" | awk '{print $1}' >"$out"
        fi
        ;;
      *) cp "$CONTROL/fake.dmg" "$out" ;;
    esac
    return 0
  fi
  [ -f "$CONTROL/live" ]
}
pgrep() {
  if [ -f "$CONTROL/gui-pid" ]; then cat "$CONTROL/gui-pid"; else return 1; fi
}
kill() {
  event "kill $*"
  rm -f "$CONTROL/gui-pid"
}
pkill() {
  event "pkill $*"
  rm -f "$CONTROL/gui-pid"
}
open() {
  event "open $*"
  if [ -f "$CONTROL/open-starts-gui" ]; then echo 4242 >"$CONTROL/gui-pid"; fi
  if [ -f "$CONTROL/open-starts-daemon" ]; then touch "$CONTROL/live"; fi
}
hdiutil() {
  local mount=""
  case "$1" in
    attach)
      while [ $# -gt 0 ]; do
        case "$1" in
          -mountpoint)
            mount="$2"
            shift
            ;;
        esac
        shift
      done
      mkdir -p "$mount"
      cp -R "$CONTROL/mounted-app" "$mount/$FX_APP_BUNDLE_NAME"
      event attach
      ;;
    detach)
      event detach
      rm -rf "$2"
      ;;
  esac
}
spctl() {
  event "spctl $*"
  if [ "$1" = --status ]; then
    echo "assessments enabled"
    return 0
  fi
  cat "$CONTROL/spctl-verdict"
  if [ -f "$CONTROL/spctl-rejects" ]; then return 3; fi
}
xattr() { event "xattr $1 $2"; }
xcrun() {
  event "xcrun $*"
  echo "The validate action worked!"
}
defaults() {
  case "$3" in
    CFBundleVersion) cat "$CONTROL/installed-build" ;;
    CFBundleShortVersionString) echo 0.2.2 ;;
  esac
}
ditto() {
  event "ditto $*"
  mkdir -p "$APP/Contents/MacOS"
}
codesign() { cat "$CONTROL/requirement"; }
log() { echo "log double"; }
sw_vers() { printf 'ProductName:\tmacOS\nProductVersion:\t26.1\nBuildVersion:\t25B1\n'; }
tccutil() { event "tccutil $*"; }
shutdown() { event "shutdown $*"; }

# shellcheck source=scripts/cloud_acceptance_remote.sh
source "$TEST_SOURCE/scripts/cloud_acceptance_remote.sh"
require_configuration
configure_paths

ENGINE_COMMIT="9f1c0f4a1c6f4b2d8e3a5c7b9d1e3f5a7c9b1d3e"

write_mac_fixtures() {
  local app="$CONTROL/mounted-app"
  head -c 4096 /dev/urandom >"$CONTROL/fake.dmg"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Engine/arm64"
  printf '#!/bin/bash\nprintf "unregister %%s\\n" "$*" >>%q\n' "$EVENTS" >"$app/Contents/MacOS/Fermix"
  printf '#!/bin/bash\n' >"$app/Contents/MacOS/FermixAgent"
  chmod +x "$app/Contents/MacOS/Fermix" "$app/Contents/MacOS/FermixAgent"
  printf '{"identity": {"source_commit": "%s", "architecture": "arm64"}}\n' "$ENGINE_COMMIT" >"$app/Contents/Resources/Engine/arm64/engine-manifest.json"
  printf 'designated => identifier "io.tezra.FermixPet.agent" and anchor apple generic and certificate leaf[subject.OU] = TEAM123456\n' >"$CONTROL/requirement"
  printf '%s: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Fermix (TEAM123456)\n' "artifact" >"$CONTROL/spctl-verdict"
  printf '%s\n' "$REAL_USER" >"$CONTROL/console"
  printf '7\n' >"$CONTROL/installed-build"
  printf '      state = running;pid = 77;last exit code = 0\n' >"$CONTROL/launchctl"
  cat >"$CONTROL/btm" <<BTM
 #1:
      UUID: 1111
      Name: Fermix
      Type: app (0x2)
      Disposition: [enabled, allowed, visible, notified] (11)
      Identifier: io.tezra.FermixPet
 #2:
      UUID: 2222
      Name: Fermix
      Type: agent (0x10)
      Disposition: [enabled, allowed, visible, notified] (11)
      Identifier: io.tezra.FermixPet.agent
      URL: file:///Applications/Fermix.app/Contents/Library/LaunchAgents/io.tezra.FermixPet.agent.plist
BTM
  cat >"$CONTROL/manage-hello.json" <<HELLO
{"request_id": "acceptance-hello", "result": {"protocol": {"current_version": 2, "minimum_version": 1, "maximum_version": 2}, "engine": {"engine_id": "fermix-core", "product_version": "0.11.0", "build_id": "2026092601", "source_commit": "$ENGINE_COMMIT", "architecture": "arm64", "pid": "77"}}}
HELLO
  cat >"$CONTROL/manage-setup.state.get.json" <<STATE
{"request_id": "acceptance-setup.state.get", "result": {"readiness": {"status": "setup_required", "failures": [{"component": "provider", "gating": true, "pane": "providers"}]}, "providers": [{"id": "anthropic", "configured": false}]}}
STATE
}

install_fake_app() {
  mkdir -p "$APPLICATIONS"
  cp -R "$CONTROL/mounted-app" "$APP"
}

write_record() {
  mkdir -p "$SUPPORT"
  printf '{"schema_version": 1, "fermix_home": "%s", "registered_app_build": "%s"}\n' "$FERMIX_HOME" "$1" >"$RECORD"
}

bind_socket() {
  mkdir -p "$(dirname "$1")"
  command python3 - "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY
}

mac_case() {
  rm -rf "$CONTROL" "$HOME" "$APPLICATIONS"
  mkdir -p "$CONTROL" "$HOME" "$APPLICATIONS" "$RUN" "$ARTIFACTS"
  : >"$EVENTS"
  write_mac_fixtures
}

# A verb in a subshell: a refusal exits, and the harness must survive it.
verb() {
  (dispatch "$@") >"$OUT" 2>"$ERR"
}

expect_refusal() {
  local expected="$1"
  shift
  if verb "$@"; then fail "$*: expected a refusal mentioning '$expected'"; fi
  grep -qF -- "$expected" "$ERR" || fail "$*: refusal did not mention '$expected'; stderr was: $(cat "$ERR")"
}

has_check() {
  grep -q "^check|$1|$2|" "$OUT" || fail "$3: expected check $1 $2; output was: $(paste -sd ';' "$OUT")"
}

no_check() {
  if grep -q "^check|$1|" "$OUT"; then fail "$2: did not expect check $1"; fi
}

has_fact() {
  grep -q "^fact|$1|$2" "$OUT" || fail "$3: expected fact $1 = $2; output was: $(paste -sd ';' "$OUT")"
}

echo "remote half"

mac_case
printf 'root\n' >"$CONTROL/console"
printf 'secret\n' | (dispatch prepare) >"$OUT" 2>"$ERR"
expect_event "sudo -S -p" "prepare grants passwordless sudo through the password"
expect_event "pmset -a sleep 0" "prepare keeps the Mac awake"
expect_event "sysadminctl -autologin set" "prepare sets autologin when loginwindow owns the console"
has_fact console root "prepare"
has_fact autologin "set for $REAL_USER" "prepare"
[ -f "$PREPARED" ] || fail "prepare left no marker"
pass "prepare: sudo, no sleep, autologin, marker"

mac_case
touch "$CONTROL/sudo-nopass"
printf 'secret\n' | (dispatch prepare) >"$OUT" 2>"$ERR"
expect_no_event "sudo -S" "a Mac with passwordless sudo is not asked for the password again"
expect_no_event sysadminctl "a console the account owns needs no autologin"
has_fact console "$REAL_USER" "prepare on a logged-in console"
pass "prepare: nothing to change on a prepared, logged-in Mac"

mac_case
if (dispatch prepare) </dev/null >"$OUT" 2>"$ERR"; then fail "prepare accepted an empty password"; fi
grep -q "stdin" "$ERR" || fail "prepare's refusal did not name stdin"
pass "prepare: refuses without a password on stdin"

mac_case
expect_refusal "not prepared" reset
pass "reset: refuses on a Mac prepare never touched"

mac_case
: >"$PREPARED"
install_fake_app
write_record 7
mkdir -p "$FERMIX_HOME" "$HOME/Library/Caches/$FX_BUNDLE_ID"
verb reset || fail "reset refused: $(cat "$ERR")"
expect_event "unregister --unregister-login-items" "reset withdraws the registrations through the bundle"
expect_event "pkill -f" "reset stops the app's processes"
expect_event "bootout gui/$(id -u)/$FX_AGENT_LABEL" "reset boots the agent out"
expect_event resetbtm "reset falls back to resetbtm only when a registration survived"
expect_event "tccutil reset All $FX_BUNDLE_ID" "reset clears the privacy rows"
[ ! -e "$APP" ] && [ ! -e "$RECORD" ] && [ ! -e "$FERMIX_HOME" ] && [ ! -e "$HOME/Library/Caches/$FX_BUNDLE_ID" ] ||
  fail "reset left state behind"
has_fact reset "sfltool resetbtm ran" "reset"
pass "reset: the Stage 0 protocol, resetbtm because rows survived"

mac_case
: >"$PREPARED"
rm -f "$CONTROL/btm"
verb reset || fail "reset refused: $(cat "$ERR")"
expect_no_event resetbtm "no registration, no resetbtm"
has_fact reset "fresh account" "reset"
pass "reset: no resetbtm when nothing is registered"

mac_case
verb fetch-release v0.2.2 0.2.2 || fail "fetch-release refused: $(cat "$ERR")"
expect_event "curl https://github.com/tezra-io/fermix-macos/releases/download/v0.2.2/Fermix-0.2.2.dmg" "fetch-release downloads the DMG"
expect_event "curl https://github.com/tezra-io/fermix-macos/releases/download/v0.2.2/Fermix-0.2.2.dmg.sha256" "fetch-release downloads the sidecar"
[ -f "$ARTIFACTS/Fermix-0.2.2.dmg" ] || fail "fetch-release left no artifact"
has_fact artifact_sha256 "$(shasum -a 256 "$CONTROL/fake.dmg" | awk '{print $1}')" "fetch-release"
pass "fetch-release: the DMG and its sidecar, digest proven"

mac_case
touch "$CONTROL/tampered-sha"
expect_refusal "digest" fetch-release v0.2.2 0.2.2
pass "fetch-release: refuses a DMG the sidecar does not vouch for"

mac_case
cp "$CONTROL/fake.dmg" "$ARTIFACTS/Fermix-0.2.2.dmg"
verb gate-dmg Fermix-0.2.2.dmg || fail "gate-dmg refused: $(cat "$ERR")"
expect_event "xattr -w com.apple.quarantine" "gate-dmg quarantines the image first"
expect_event "spctl -a -vv -t open --context context:primary-signature" "gate-dmg assesses the image as an opened download"
expect_event "spctl -a -vv -t exec" "gate-dmg assesses the app as an executable"
has_check gatekeeper_dmg PASS "gate-dmg"
has_check gatekeeper_app PASS "gate-dmg"
has_check stapled_dmg PASS "gate-dmg"
has_check stapled_app PASS "gate-dmg"
expect_event detach "gate-dmg unmounts the image"
pass "gate-dmg: STAGE0 §8, all four verdicts recorded"

mac_case
cp "$CONTROL/fake.dmg" "$ARTIFACTS/Fermix-0.2.2.dmg"
touch "$CONTROL/spctl-rejects"
printf 'artifact: rejected\nsource=no usable signature\n' >"$CONTROL/spctl-verdict"
verb gate-dmg Fermix-0.2.2.dmg || fail "gate-dmg refused: $(cat "$ERR")"
has_check gatekeeper_dmg FAIL "gate-dmg rejected"
has_check gatekeeper_app FAIL "gate-dmg rejected"
grep -q "^check|gatekeeper_dmg|FAIL|artifact: rejected source=no usable signature" "$OUT" || fail "the verdict text was not carried"
pass "gate-dmg: a rejection is a FAIL that carries spctl's words"

mac_case
cp "$CONTROL/fake.dmg" "$ARTIFACTS/Fermix-0.2.2.dmg"
printf 'artifact: accepted\nsource=Developer ID\n' >"$CONTROL/spctl-verdict"
verb gate-dmg Fermix-0.2.2.dmg || fail "gate-dmg refused: $(cat "$ERR")"
has_check gatekeeper_dmg FAIL "gate-dmg unnotarized"
pass "gate-dmg: accepted without notarization is still a FAIL"

mac_case
cp "$CONTROL/fake.dmg" "$ARTIFACTS/Fermix-0.2.2.dmg"
verb install-dmg Fermix-0.2.2.dmg || fail "install-dmg refused: $(cat "$ERR")"
[ -x "$GUI" ] || fail "install-dmg did not copy the bundle into the Applications folder"
expect_event "xattr -dr com.apple.quarantine" "install-dmg strips the quarantine it inherited"
expect_event detach "install-dmg unmounts the image"
has_fact quarantine stripped "install-dmg"
has_fact installed_build 7 "install-dmg"
pass "install-dmg: copied, quarantine stripped and said so, build recorded"

mac_case
expect_refusal "no disk image" install-dmg Fermix-9.9.9.dmg
pass "install-dmg: refuses an artifact that was never fetched"

mac_case
: >"$ARTIFACTS/Fermix-0.2.1-6.zip"
verb install-zip Fermix-0.2.1-6.zip || fail "install-zip refused: $(cat "$ERR")"
expect_event "ditto -x -k $ARTIFACTS/Fermix-0.2.1-6.zip $APPLICATIONS/" "install-zip unpacks into the Applications folder"
has_fact installed_build 7 "install-zip"
pass "install-zip: the signed-only candidate lands in the Applications folder"

mac_case
install_fake_app
touch "$CONTROL/open-starts-gui" "$CONTROL/open-starts-daemon"
verb activate || fail "activate refused: $(cat "$ERR")"
expect_event "open -a $APP" "activate opens the app"
expect_event "open fermix://setup" "activate runs setup through the url scheme"
expect_order "open -a $APP" "open fermix://setup" "activate opens the app before asking for setup"
has_check gui_running_after_activation PASS "activate"
has_check daemon_live_after_activation PASS "activate"
pass "activate: open, setup, daemon answers"

mac_case
install_fake_app
touch "$CONTROL/open-starts-gui"
verb activate || fail "activate refused: $(cat "$ERR")"
has_check daemon_live_after_activation FAIL "activate without a daemon"
grep -q "launchd says: state = running" "$OUT" || fail "the timeout did not carry launchd's word"
pass "activate: a daemon that never answers is a FAIL that quotes launchd"

mac_case
expect_refusal "nothing installed" activate
pass "activate: refuses with nothing installed"

mac_case
install_fake_app
touch "$CONTROL/open-starts-gui" "$CONTROL/open-starts-daemon"
verb launch || fail "launch refused: $(cat "$ERR")"
expect_no_event "fermix://setup" "a later launch does not run setup again"
has_check daemon_live_after_launch PASS "launch"
pass "launch: open and wait, no setup"

verify_all_green() {
  install_fake_app
  write_record 7
  echo 4242 >"$CONTROL/gui-pid"
  touch "$CONTROL/live"
  bind_socket "$FERMIX_HOME/daemon.sock"
}

mac_case
verify_all_green
verb verify || fail "verify refused: $(cat "$ERR")"
for name in gui_running agent_registered login_item_registered agent_job daemon_live daemon_socket engine_hello engine_is_bundled registration_receipt readiness; do
  has_check "$name" PASS "verify all green"
done
has_fact agent_records 1 "verify"
has_fact engine_commit "$ENGINE_COMMIT" "verify"
has_fact readiness_gating "provider (providers)" "verify"
has_fact providers_configured none "verify"
[ -f "$RUN/hello.json" ] && [ -f "$RUN/setup-state.json" ] && [ -f "$RUN/launcher.json" ] || fail "verify did not keep its answers as evidence"
pass "verify: every probe green, facts and evidence recorded"

mac_case
verify_all_green
printf '      state = spawn failed;last exit code = 78\n' >"$CONTROL/launchctl"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check agent_job FAIL "spawn failed"
grep -q "^check|agent_job|FAIL|state = spawn failed" "$OUT" || fail "launchd's state was not carried"
pass "verify: a refused spawn is a FAIL in launchd's words"

mac_case
verify_all_green
rm -f "$CONTROL/launchctl"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check agent_job FAIL "no job"
grep -q "launchd has no job" "$OUT" || fail "a missing job was not named"
pass "verify: no launchd job is a FAIL"

mac_case
verify_all_green
sed -i '' 's/Disposition: \[enabled, allowed, visible, notified\] (11)$/Disposition: [enabled, disallowed, visible, notified] (9)/' "$CONTROL/btm"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check agent_registered FAIL "disallowed"
grep -q "switched off in Login Items" "$OUT" || fail "the disallowed disposition was not explained"
pass "verify: the Login Items switch off is a FAIL"

mac_case
verify_all_green
rm -f "$CONTROL/btm"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check agent_registered FAIL "no record"
has_check login_item_registered FAIL "no record"
has_fact agent_records 0 "no record"
pass "verify: no Background Task Management record is a FAIL for both principals"

mac_case
verify_all_green
rm -f "$CONTROL/live"
rm -f "$FERMIX_HOME/daemon.sock"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check daemon_live FAIL "daemon down"
has_check daemon_socket FAIL "daemon down"
pass "verify: a silent daemon fails both the health and the socket probe"

mac_case
verify_all_green
write_record 6
verb verify || fail "verify refused: $(cat "$ERR")"
has_check registration_receipt FAIL "stale receipt"
grep -q "the receipt names build 6, the installed app is build 7" "$OUT" || fail "the receipt mismatch was not spelled out"
pass "verify: a receipt from another build is a FAIL"

mac_case
verify_all_green
rm -f "$RECORD"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check registration_receipt FAIL "no record"
pass "verify: no bootstrap record is a FAIL"

mac_case
verify_all_green
rm -f "$CONTROL/manage-hello.json"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check engine_hello FAIL "no hello"
no_check engine_is_bundled "no hello"
has_check readiness SKIP "no hello"
pass "verify: no hello answer fails the identity probe and skips readiness"

mac_case
verify_all_green
sed -i '' "s/$ENGINE_COMMIT/0000000000000000000000000000000000000000/" "$CONTROL/manage-hello.json"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check engine_hello PASS "other engine"
has_check engine_is_bundled FAIL "other engine"
pass "verify: a daemon on another engine than the bundle's is a FAIL"

mac_case
verify_all_green
sed -i '' 's/"maximum_version": 2/"maximum_version": 1/' "$CONTROL/manage-hello.json"
verb verify || fail "verify refused: $(cat "$ERR")"
has_check readiness SKIP "protocol 1"
pass "verify: an engine on protocol 1 skips readiness rather than failing it"

mac_case
echo 4242 >"$CONTROL/gui-pid"
touch "$CONTROL/live"
verb quit-gui || fail "quit-gui refused: $(cat "$ERR")"
expect_event "kill -TERM 4242" "quit-gui sends SIGTERM"
has_check gui_quit PASS "quit-gui"
has_check daemon_survives_gui_quit PASS "quit-gui"
pass "quit-gui: SIGTERM, the GUI leaves, the daemon stays"

mac_case
verb quit-gui || fail "quit-gui refused: $(cat "$ERR")"
has_check gui_quit SKIP "quit-gui without a GUI"
pass "quit-gui: nothing to quit is a SKIP"

mac_case
install_fake_app
touch "$CONTROL/open-starts-gui" "$CONTROL/live"
verb relaunch || fail "relaunch refused: $(cat "$ERR")"
has_check gui_running_after_relaunch PASS "relaunch"
has_check daemon_live_after_relaunch PASS "relaunch"
pass "relaunch: both back"

mac_case
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat SKIP "no companion socket"
grep -q "no companion socket" "$OUT" || fail "the missing wire was not named"
pass "chat: an engine without the companion wire is a SKIP"

mac_case
bind_socket "$FERMIX_HOME/companion.sock"
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat SKIP "no readiness"
pass "chat: no readiness answer to read a provider from is a SKIP"

mac_case
bind_socket "$FERMIX_HOME/companion.sock"
cp "$CONTROL/manage-setup.state.get.json" "$RUN/setup-state.json"
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat SKIP "no provider"
grep -q "no provider is configured" "$OUT" || fail "the missing provider was not named"
pass "chat: no configured provider is a SKIP that says what to do"

chat_ready() {
  bind_socket "$FERMIX_HOME/companion.sock"
  sed 's/"configured": false/"configured": true/' "$CONTROL/manage-setup.state.get.json" >"$RUN/setup-state.json"
}

mac_case
chat_ready
printf 'event|server_hello|versions 1 to 1\nevent|accepted|duplicate=False\nevent|text_done|Hello there.\n' >"$CONTROL/companion-events"
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat_handshake PASS "chat"
has_check chat_reply PASS "chat"
grep -q "^check|chat_reply|PASS|Hello there." "$OUT" || fail "the reply text was not carried"
pass "chat: handshake and a reply"

mac_case
chat_ready
printf 'event|server_hello|versions 1 to 1\nevent|accepted|duplicate=False\nevent|turn_error|request_failed: no model answered\n' >"$CONTROL/companion-events"
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat_reply FAIL "turn error"
grep -q "^check|chat_reply|FAIL|turn_error request_failed: no model answered" "$OUT" || fail "the daemon's error was not carried"
pass "chat: a turn_error is a FAIL in the daemon's words"

mac_case
chat_ready
printf 'event|closed|no server_hello: null\n' >"$CONTROL/companion-events"
verb chat "hello" || fail "chat refused: $(cat "$ERR")"
has_check chat_handshake FAIL "no server_hello"
no_check chat_reply "no server_hello"
pass "chat: no handshake fails without sending"

mac_case
install_fake_app
verb agent-requirement || fail "agent-requirement refused: $(cat "$ERR")"
has_fact agent_requirement 'designated => identifier "io.tezra.FermixPet.agent"' "agent-requirement"
pass "agent-requirement: the designated requirement as a fact"

mac_case
verify_all_green
verb collect || fail "collect refused: $(cat "$ERR")"
for file in sw_vers.txt spctl-status.txt profiles.txt dumpbtm.txt launchctl-agent.txt installed.txt health.txt log-app.txt log-system.txt; do
  [ -f "$RUN/$file" ] || fail "collect wrote no $file"
done
grep -q "Identifier: io.tezra.FermixPet.agent" "$RUN/dumpbtm.txt" || fail "collect did not keep the agent's record"
has_fact evidence "$RUN" "collect"
pass "collect: evidence files, the record among them"

mac_case
verb reboot || fail "reboot refused: $(cat "$ERR")"
expect_event "shutdown -r now" "reboot asks macOS, never the console's power cut"
pass "reboot: sudo shutdown -r now"

mac_case
expect_refusal "usage" nonsense
pass "dispatch: an unknown verb is a usage refusal"

# ---- the driver half ---------------------------------------------------------

echo "driver half"

unset -f ditto open stat
ditto() {
  event "ditto $*"
  : >"${!#}"
}

scw() {
  event "scw $*"
  case "$1 $2 $3" in
    "config get access-key") cat "$CONTROL/access-key" ;;
    "iam ssh-key list") printf '[{"name": "laptop", "public_key": "%s"}]\n' "$(cat "$CONTROL/project-key")" ;;
    "apple-silicon server list") cat "$CONTROL/servers" ;;
    "apple-silicon os list") cat "$CONTROL/os-list" ;;
    "apple-silicon server create") cat "$CONTROL/server" ;;
    "apple-silicon server update") cat "$CONTROL/server" ;;
    "apple-silicon server get") cat "$CONTROL/server" ;;
    "apple-silicon server delete") echo '{}' ;;
    *)
      echo "unexpected scw $*" >&2
      return 2
      ;;
  esac
}

gh() {
  case "$1 $2" in
    "release view") cat "$CONTROL/latest-tag" ;;
    "repo view") echo tezra-io/fermix-macos ;;
    *)
      echo "unexpected gh $*" >&2
      return 2
      ;;
  esac
}

# The remote helper's answers, one file per verb; a numbered file answers the
# nth call of that verb, which is how an upgrade case makes N and N+1 differ.
remote_double() {
  local verb="${1%% *}" count
  count="$(cat "$CONTROL/calls-$verb" 2>/dev/null || echo 0)"
  count=$((count + 1))
  echo "$count" >"$CONTROL/calls-$verb"
  case "$verb" in
    console) cat "$CONTROL/console" ;;
    reboot)
      echo 3 >"$CONTROL/ssh-down-for"
      return 255
      ;;
    *)
      if [ -f "$CONTROL/remote-$verb-$count" ]; then
        cat "$CONTROL/remote-$verb-$count"
      elif [ -f "$CONTROL/remote-$verb" ]; then
        cat "$CONTROL/remote-$verb"
      fi
      ;;
  esac
}

ssh() {
  local target="" command="" down
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) shift ;;
      -n) ;;
      *) if [ -z "$target" ]; then target="$1"; else command="$1"; fi ;;
    esac
    shift
  done
  event "ssh $target $command"
  down="$(cat "$CONTROL/ssh-down-for" 2>/dev/null || echo 0)"
  if [ "$down" -gt 0 ]; then
    echo $((down - 1)) >"$CONTROL/ssh-down-for"
    return 255
  fi
  [ -f "$CONTROL/ssh-up" ] || return 255
  case "$command" in
    true | mkdir*) return 0 ;;
    "bash fermix-acceptance/remote.sh "*) remote_double "${command#bash fermix-acceptance/remote.sh }" ;;
    *)
      echo "unexpected ssh command $command" >&2
      return 2
      ;;
  esac
}

scp() {
  local source="" destination="" arg
  for arg in "$@"; do
    source="$destination"
    destination="$arg"
  done
  event "scp $source $destination"
  case "$source" in
    *:fermix-acceptance/runs/*)
      mkdir -p "$destination"
      printf 'ProductName:\tmacOS\nProductVersion:\t26.1\nBuildVersion:\t25B1\n' >"$destination/sw_vers.txt"
      ;;
  esac
}

# shellcheck source=scripts/cloud_acceptance.sh
source "$TEST_SOURCE/scripts/cloud_acceptance.sh"

STUB_ROOT="$WORK_DIR/repo"
write_stubs() {
  local script
  mkdir -p "$STUB_ROOT/scripts" "$STUB_ROOT/engine"
  cp "$TEST_SOURCE/engine/PIN.json" "$STUB_ROOT/engine/PIN.json"
  for script in fetch_engine verify_engine sign_app verify_staged_app; do
    printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >>%q\n' "$script" "$EVENTS" >"$STUB_ROOT/scripts/$script.sh"
  done
  printf '#!/bin/bash\nprintf "stage_app %%s\\n" "$*" >>%q\nmkdir -p "$3/Contents/MacOS"\n' "$EVENTS" >"$STUB_ROOT/scripts/stage_app.sh"
  printf '#!/bin/bash\nprintf "package_release %%s identity=%%s\\n" "$*" "$MACOS_DEVELOPER_ID" >>%q\nmkdir -p %q/dist\n: >%q/dist/Fermix-$1.dmg\n' "$EVENTS" "$STUB_ROOT" "$STUB_ROOT" >"$STUB_ROOT/scripts/package_release.sh"
  chmod +x "$STUB_ROOT"/scripts/*.sh
  : >"$STUB_ROOT/scripts/cloud_acceptance_remote.sh"
}

CASE=0
driver_case() {
  CASE=$((CASE + 1))
  rm -rf "$CONTROL" "$HOME" "$STUB_ROOT"
  mkdir -p "$CONTROL" "$HOME/.ssh"
  : >"$EVENTS"
  write_stubs
  ROOT_DIR="$STUB_ROOT"
  ENGINE_PIN_DEFAULT_PATH="$STUB_ROOT/engine/PIN.json"
  OUTPUT_ROOT="$WORK_DIR/output-$CASE"
  ZONE=""
  TYPE=M1-M
  MACOS_FILTER=""
  printf 'ssh-ed25519 AAAATESTKEY laptop\n' >"$HOME/.ssh/id_test.pub"
  printf 'ssh-ed25519 AAAATESTKEY laptop\n' >"$CONTROL/project-key"
  printf 'SCWACCESSKEY\n' >"$CONTROL/access-key"
  printf '  1) ABCDEF "Developer ID Application: Fermix Test (TEAM123456)"\n     1 valid identities found\n' >"$CONTROL/identities"
  printf 'v0.2.2\n' >"$CONTROL/latest-tag"
  printf '[]\n' >"$CONTROL/servers"
  cat >"$CONTROL/os-list" <<OS
[{"id": "os-15", "name": "macOS Sequoia", "version": "15.7.1", "is_beta": false},
 {"id": "os-26", "name": "macOS Tahoe", "version": "26.1", "is_beta": false},
 {"id": "os-27", "name": "macOS Golden Gate", "version": "27.0", "is_beta": true}]
OS
  write_server srv-new true
  touch "$CONTROL/ssh-up"
  printf 'm1\n' >"$CONTROL/console"
  printf 'fact|console|m1\n' >"$CONTROL/remote-prepare"
  printf 'fact|reset|fresh account\n' >"$CONTROL/remote-reset"
  printf 'fact|artifact_sha256|abc\n' >"$CONTROL/remote-fetch-release"
  printf 'check|gatekeeper_dmg|PASS|accepted source=Notarized Developer ID\ncheck|gatekeeper_app|PASS|accepted\ncheck|stapled_dmg|PASS|ok\ncheck|stapled_app|PASS|ok\n' >"$CONTROL/remote-gate-dmg"
  printf 'fact|installed_build|7\n' >"$CONTROL/remote-install-dmg"
  printf 'fact|installed_build|8\n' >"$CONTROL/remote-install-zip"
  printf 'check|gui_running_after_activation|PASS|pid 4242\ncheck|daemon_live_after_activation|PASS|answered after 4s\n' >"$CONTROL/remote-activate"
  printf 'check|gui_running_after_launch|PASS|pid 4243\ncheck|daemon_live_after_launch|PASS|answered after 3s\n' >"$CONTROL/remote-launch"
  printf 'check|agent_job|PASS|state = running\ncheck|daemon_live|PASS|answers\ncheck|registration_receipt|PASS|build 7\nfact|engine_version|0.11.0\n' >"$CONTROL/remote-verify"
  printf 'fact|agent_requirement|designated => identifier "io.tezra.FermixPet.agent" and anchor apple generic\n' >"$CONTROL/remote-agent-requirement"
  printf 'check|gui_quit|PASS|exited\ncheck|daemon_survives_gui_quit|PASS|answers\n' >"$CONTROL/remote-quit-gui"
  printf 'check|gui_running_after_relaunch|PASS|pid 4244\ncheck|daemon_live_after_relaunch|PASS|answers\n' >"$CONTROL/remote-relaunch"
  printf 'check|chat|SKIP|this engine serves no companion socket\n' >"$CONTROL/remote-chat"
  printf 'fact|evidence|/Users/m1/fermix-acceptance/runs/x\n' >"$CONTROL/remote-collect"
}

write_server() {
  cat >"$CONTROL/server" <<SERVER
{"id": "$1", "name": "fermix-acceptance", "type": "M1-M", "zone": "fr-par-3", "ip": "51.1.2.3",
 "vnc_url": "vnc://51.1.2.3:59010", "vnc_port": 59010, "ssh_username": "m1", "sudo_password": "pw",
 "status": "ready", "delivered": $2, "deletable_at": "${3:-2035-01-01T00:00:00.000000Z}",
 "deletion_scheduled": ${4:-true}, "os": {"name": "macOS Tahoe", "version": "26.1"}}
SERVER
}

run_driver() {
  (run "$@") >"$OUT" 2>"$ERR"
}

report_dir() { ls -d "$OUTPUT_ROOT"/*/ | head -1; }

has_row() {
  grep -q "^$1	$2	$3	" "$(report_dir)/checks.tsv" || fail "$4: expected check row $1/$2 $3; rows were: $(paste -sd ';' "$(report_dir)/checks.tsv")"
}

driver_case
run_driver --release || fail "run --release failed: $(cat "$ERR"; cat "$OUT")"
expect_event "scw apple-silicon os list zone=fr-par-3 server-type=M1-M -o json" "run lists the macOS versions for the type in the M1 zone"
expect_event "scw apple-silicon server create zone=fr-par-3 type=M1-M name=fermix-acceptance os-id=os-26 commitment-type=duration_24h -o json" "run creates the cheapest type on the newest non-beta macOS with the 24 h commitment"
expect_event "scw apple-silicon server update srv-new zone=fr-par-3 schedule-deletion=true -o json" "run schedules the deletion at creation"
expect_event "ssh m1@51.1.2.3 mkdir -p fermix-acceptance/artifacts" "run makes the remote work folder"
expect_event "scp $STUB_ROOT/scripts/cloud_acceptance_remote.sh m1@51.1.2.3:fermix-acceptance/remote.sh" "run uploads the remote helper"
expect_event "m1@51.1.2.3:fermix-acceptance/env.sh" "run uploads the remote environment"
grep -q "^export FX_BUNDLE_ID=io.tezra.FermixPet$" "$(report_dir)/env.sh" || fail "env.sh does not carry the bundle identifier"
grep -q "^export FX_PORT=4030$" "$(report_dir)/env.sh" || fail "env.sh does not carry the engine port"
for verb in "prepare" "reset" "fetch-release v0.2.2 0.2.2" "gate-dmg Fermix-0.2.2.dmg" "install-dmg Fermix-0.2.2.dmg" "activate" "verify" "agent-requirement" "quit-gui" "relaunch" "chat Say\\ hello\\ in\\ one\\ sentence." "collect"; do
  expect_event "bash fermix-acceptance/remote.sh $verb" "run --release calls $verb"
done
expect_order "remote.sh reset" "remote.sh fetch-release" "the account is reset before anything is installed"
expect_order "remote.sh gate-dmg" "remote.sh install-dmg" "Gatekeeper is asked before the copy"
expect_order "remote.sh install-dmg" "remote.sh activate" "activation follows the install"
expect_order "remote.sh quit-gui" "remote.sh relaunch" "relaunch follows the quit"
expect_no_event "remote.sh launch" "a fresh install activates, it does not merely launch"
expect_no_event "remote.sh reboot" "no reboot unless asked"
expect_no_event "scp $STUB_ROOT/dist" "a release candidate is never uploaded from here"
expect_event "scp m1@51.1.2.3:fermix-acceptance/runs/1700000000 $(report_dir)evidence" "run pulls the evidence"
has_row install gatekeeper_dmg PASS "release run"
has_row install agent_job PASS "release run"
has_row install chat SKIP "release run"
grep -q "^# Cloud acceptance: release v0.2.2" "$(report_dir)/report.md" || fail "the report does not name the candidate"
grep -q "| install | gatekeeper_dmg | PASS |" "$(report_dir)/report.md" || fail "the report does not carry the checks"
grep -q "| Running macOS | 26.1 (25B1) |" "$(report_dir)/report.md" || fail "the report does not carry the Mac's macOS"
grep -q "Mode: fresh install\." "$(report_dir)/report.md" || fail "the report does not name the mode"
grep -q "passed" "$OUT" || fail "the summary did not say the run passed"
pass "run --release: create, schedule deletion, prepare, reset, gate, install, activate, verify, quit, relaunch, chat, collect, report"

driver_case
printf '[{"id": "srv-1", "name": "fermix-acceptance", "type": "M1-M"}]\n' >"$CONTROL/servers"
write_server srv-1 true
run_driver --release v0.2.1 || fail "run --release v0.2.1 failed: $(cat "$ERR")"
expect_no_event "server create" "an existing server is reused"
expect_no_event "schedule-deletion" "an existing server's schedule is left alone"
expect_event "remote.sh fetch-release v0.2.1 0.2.1" "the named tag is fetched"
pass "run --release vX.Y.Z: reuses the server and tests the named release"

driver_case
printf 'check|agent_job|FAIL|state = spawn failed\ncheck|daemon_live|FAIL|no answer\n' >"$CONTROL/remote-verify"
if run_driver --release; then fail "a failed check did not fail the run"; fi
has_row install agent_job FAIL "failed run"
grep -q "FAIL install/agent_job: state = spawn failed" "$OUT" || fail "the summary did not list the failure"
grep -q "failed (2 checks)" "$OUT" || fail "the summary did not count the failures"
expect_event "remote.sh collect" "evidence is still collected after a failure"
pass "run: a FAIL from the Mac fails the run and the report says which"

driver_case
printf 'fact|console|root\nfact|autologin|set for m1; a reboot logs the console in\n' >"$CONTROL/remote-prepare"
run_driver --release || fail "run with a login-window console failed: $(cat "$ERR")"
expect_event "remote.sh reboot" "a console at the login window is rebooted into autologin"
expect_order "remote.sh prepare" "remote.sh reboot" "the reboot follows prepare"
expect_order "remote.sh reboot" "remote.sh console" "the console is checked after the reboot"
expect_order "remote.sh console" "remote.sh reset" "nothing touches the app before the console is owned"
pass "run: loginwindow on the console means autologin and one reboot"

driver_case
printf 'fact|console|root\n' >"$CONTROL/remote-prepare"
printf 'root\n' >"$CONTROL/console"
if run_driver --release; then fail "a console nobody owns did not stop the run"; fi
grep -q "Screen Sharing (vnc://51.1.2.3:59010" "$ERR" || fail "the refusal did not point at Screen Sharing: $(cat "$ERR")"
expect_no_event "remote.sh reset" "nothing touches the app without a console session"
pass "run: a console still at the login window after the reboot is a refusal that names VNC"

driver_case
run_driver --dev || fail "run --dev failed: $(cat "$ERR"; cat "$OUT")"
version="$(product_config marketing_version)"
build="$(product_config build_number)"
expect_event "fetch_engine $STUB_ROOT/engine/PIN.json" "dev builds fetch the pinned engine"
expect_event "verify_engine $STUB_ROOT/engine/PIN.json" "dev builds verify the pinned engine"
expect_event "stage_app $version $build $(report_dir)stage/Fermix.app universal --engine $(report_dir)engine/macos_aarch64 --engine $(report_dir)engine/macos_x86_64" "dev builds stage universal with both engine trees"
expect_event "sign_app $(report_dir)stage/Fermix.app Developer ID Application: Fermix Test (TEAM123456)" "dev builds sign with the one identity"
expect_event "verify_staged_app $(report_dir)stage/Fermix.app universal signed release" "dev builds pass the release audience"
expect_event "ditto -c -k --keepParent $(report_dir)stage/Fermix.app $(report_dir)Fermix-$version-$build.zip" "the signed bundle is zipped"
expect_event "scp $(report_dir)Fermix-$version-$build.zip m1@51.1.2.3:fermix-acceptance/artifacts/Fermix-$version-$build.zip" "the zip is uploaded"
expect_event "remote.sh install-zip Fermix-$version-$build.zip" "the zip is installed"
expect_no_event "remote.sh gate-dmg" "no Gatekeeper gate for a signed-only candidate"
expect_no_event "remote.sh fetch-release" "a dev candidate is not fetched from a release"
expect_no_event package_release "no notarization without credentials"
has_row install gatekeeper_dmg SKIP "dev run"
grep -q "^# Cloud acceptance: dev abc1234 $version ($build)" "$(report_dir)/report.md" || fail "the report does not name the dev candidate"
pass "run --dev: staged, signed, zipped, uploaded, Gatekeeper recorded as skipped"

driver_case
APPLE_ID=a APPLE_TEAM_ID=b APPLE_APP_PASSWORD=c run_driver --dev || fail "run --dev with credentials failed: $(cat "$ERR"; cat "$OUT")"
expect_event "package_release $version $build identity=Developer ID Application: Fermix Test (TEAM123456)" "credentials mean the release artifact"
expect_event "scp $STUB_ROOT/dist/Fermix-$version.dmg m1@51.1.2.3:fermix-acceptance/artifacts/Fermix-$version.dmg" "the DMG is uploaded"
expect_event "remote.sh gate-dmg Fermix-$version.dmg" "a notarized dev DMG is gated"
expect_event "remote.sh install-dmg Fermix-$version.dmg" "and installed"
expect_no_event stage_app "the release script does the staging"
pass "run --dev with notarytool credentials: the release DMG, gated"

driver_case
printf '  1) ABCDEF "Developer ID Application: A (T1)"\n  2) ABCDEF "Developer ID Application: B (T2)"\n     2 valid identities found\n' >"$CONTROL/identities"
if run_driver --dev; then fail "two identities did not stop the dev build"; fi
grep -q "2 Developer ID Application identities" "$ERR" || fail "the identity refusal was not passed on"
expect_no_event "server create" "no server is created before the candidate exists"
pass "run --dev: the identity refusal comes before any server is touched"

driver_case
printf 'fact|agent_requirement|designated => identifier "io.tezra.FermixPet.agent" and anchor apple generic\n' >"$CONTROL/remote-agent-requirement-1"
cp "$CONTROL/remote-agent-requirement-1" "$CONTROL/remote-agent-requirement-2"
run_driver --release --upgrade-from v0.2.1 || fail "run --upgrade-from failed: $(cat "$ERR"; cat "$OUT")"
for verb in "fetch-release v0.2.1 0.2.1" "gate-dmg Fermix-0.2.1.dmg" "install-dmg Fermix-0.2.1.dmg" "activate" "fetch-release v0.2.2 0.2.2" "gate-dmg Fermix-0.2.2.dmg" "install-dmg Fermix-0.2.2.dmg" "launch"; do
  expect_event "bash fermix-acceptance/remote.sh $verb" "upgrade calls $verb"
done
expect_order "remote.sh install-dmg Fermix-0.2.1.dmg" "remote.sh activate" "the old release is activated"
expect_order "remote.sh activate" "remote.sh quit-gui" "the GUI is quit before the bundle is replaced"
expect_order "remote.sh quit-gui" "remote.sh install-dmg Fermix-0.2.2.dmg" "the candidate replaces the bundle after the quit"
expect_order "remote.sh install-dmg Fermix-0.2.2.dmg" "remote.sh launch" "the candidate launches, it does not activate"
[ "$(grep -c "remote.sh verify" "$EVENTS")" = 2 ] || fail "verify did not run once per build"
[ "$(grep -c "remote.sh agent-requirement" "$EVENTS")" = 2 ] || fail "the requirement was not read for both builds"
has_row before-upgrade agent_job PASS "upgrade"
has_row upgrade agent_job PASS "upgrade"
has_row upgrade agent_requirement_stable PASS "upgrade"
grep -q "Mode: upgrade from v0.2.1\." "$(report_dir)/report.md" || fail "the report does not name the upgrade"
pass "run --upgrade-from: old release through setup, candidate over it, requirement stable"

driver_case
printf 'fact|agent_requirement|designated => identifier "io.tezra.FermixPet.agent" and anchor apple generic\n' >"$CONTROL/remote-agent-requirement-1"
printf 'fact|agent_requirement|designated => cdhash H"deadbeef"\n' >"$CONTROL/remote-agent-requirement-2"
if run_driver --release --upgrade-from v0.2.1; then fail "a changed requirement did not fail the run"; fi
has_row upgrade agent_requirement_stable FAIL "changed requirement"
grep -q 'before: designated => identifier "io.tezra.FermixPet.agent" and anchor apple generic; after: designated => cdhash H"deadbeef"' "$(report_dir)/checks.tsv" ||
  fail "the two requirements were not recorded"
pass "run --upgrade-from: a changed designated requirement is a FAIL that shows both"

driver_case
run_driver --release --reboot --chat "What time is it?" || fail "run --reboot failed: $(cat "$ERR"; cat "$OUT")"
expect_event "remote.sh reboot" "the reboot is asked for"
expect_order "remote.sh collect" "remote.sh reboot" "the reboot follows the first collection"
expect_order_last "remote.sh reboot" "remote.sh console" "the console is awaited after the reboot"
[ "$(grep -c "remote.sh console" "$EVENTS")" = 2 ] || fail "the console was not checked once after prepare and once after the reboot"
[ "$(grep -c "remote.sh verify" "$EVENTS")" = 2 ] || fail "verify did not run again after the reboot"
[ "$(grep -c "remote.sh collect" "$EVENTS")" = 2 ] || fail "collect did not run again after the reboot"
has_row reboot agent_job PASS "reboot"
expect_event "remote.sh chat What\\ time\\ is\\ it\\?" "the chat text is the one given"
grep -q "Mode: fresh install, then reboot\." "$(report_dir)/report.md" || fail "the report does not name the reboot"
pass "run --reboot: reboot, wait for the console, verify and collect again"

driver_case
run_driver --release --type M4-S --macos Sequoia || fail "run with type and macOS failed: $(cat "$ERR")"
expect_event "scw apple-silicon os list zone=fr-par-1 server-type=M4-S -o json" "an M4 defaults to fr-par-1"
expect_event "os-id=os-15" "--macos narrows the choice by name"
pass "run --type --macos: the zone follows the type, the macOS follows the filter"

driver_case
if run_driver --release --macos Ventura; then fail "an unmatched --macos did not stop the run"; fi
grep -q "no macOS matches 'Ventura'" "$ERR" || fail "the macOS refusal was not clear: $(cat "$ERR")"
pass "run --macos: an unmatched filter is a refusal before anything is created"

driver_case
rm -f "$CONTROL/servers"
if run_driver --release; then fail "a failed server listing did not stop the run"; fi
grep -q "could not list the Apple silicon servers" "$ERR" || fail "the listing refusal was not clear: $(cat "$ERR")"
expect_no_event "server create" "a listing that failed never rents a second server"
pass "run: a failed server listing is a refusal, never a second lease"

driver_case
: >"$CONTROL/access-key"
if run_driver --release; then fail "missing scw credentials did not stop the run"; fi
grep -q "scw init" "$ERR" || fail "the credentials refusal did not say how to fix it"
pass "run: scw without credentials is a refusal"

driver_case
printf 'ssh-ed25519 AAAAOTHERKEY desk\n' >"$CONTROL/project-key"
if run_driver --release; then fail "an unregistered ssh key did not stop the run"; fi
grep -q "registered with the Scaleway project" "$ERR" || fail "the ssh key refusal was not clear: $(cat "$ERR")"
expect_no_event "server create" "no server is created for a key the Mac would refuse"
pass "run: a local ssh key the project does not know is a refusal"

driver_case
if run_driver; then fail "run without a mode did not refuse"; fi
grep -q -- "--release \[vX.Y.Z\] or --dev" "$ERR" || fail "the usage refusal was not clear"
if run_driver --dev v0.2.2; then fail "a tag with --dev did not refuse"; fi
pass "run: usage refusals"

driver_case
printf '[{"id": "srv-1", "name": "fermix-acceptance"}]\n' >"$CONTROL/servers"
write_server srv-1 true 2020-01-01T00:00:00Z true
(down) >"$OUT" 2>"$ERR" || fail "down failed: $(cat "$ERR")"
expect_event "scw apple-silicon server delete srv-1 zone=fr-par-3 -o json" "down deletes once the lease allows"
grep -q "billing stops when the deletion completes" "$OUT" || fail "down did not say what happens to billing"
pass "down: deletes a server whose lease has run"

driver_case
printf '[{"id": "srv-1", "name": "fermix-acceptance"}]\n' >"$CONTROL/servers"
write_server srv-1 true 2035-01-01T00:00:00Z false
(down) >"$OUT" 2>"$ERR" || fail "down failed: $(cat "$ERR")"
expect_no_event "server delete" "down never deletes inside the 24 h lease"
expect_event "scw apple-silicon server update srv-1 zone=fr-par-3 schedule-deletion=true -o json" "down schedules the deletion when it is not"
grep -q "24-hour lease allows deletion in" "$OUT" || fail "down did not say when the lease allows deletion"
pass "down: inside the lease it schedules the deletion and says when"

driver_case
(down) >"$OUT" 2>"$ERR" || fail "down with no server failed: $(cat "$ERR")"
grep -q "nothing is billing" "$OUT" || fail "down did not say nothing is billing"
pass "down: no server, nothing to do"

driver_case
printf '[{"id": "srv-1", "name": "fermix-acceptance"}]\n' >"$CONTROL/servers"
write_server srv-1 true
(status) >"$OUT" 2>"$ERR" || fail "status failed: $(cat "$ERR")"
grep -q "ssh       ssh m1@51.1.2.3" "$OUT" || fail "status did not print the ssh command"
grep -q "vnc       vnc://51.1.2.3:59010" "$OUT" || fail "status did not print the VNC url"
grep -q "deletable in" "$OUT" || fail "status did not print the lease"
pass "status: server, ssh, vnc and lease"

echo "cloud_acceptance_test: all cases passed"
