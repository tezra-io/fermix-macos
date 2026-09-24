#!/usr/bin/env bash
# Host-safe lifecycle tests: every process/service command is a double.
set -euo pipefail

TEST_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

event() { printf '%s\n' "$*" >>"$DEV_E2E_TEST_EVENTS"; }
sleep() { :; }
date() { printf '%s\n' 1700000000; }
curl() {
  [ -f "$DEV_E2E_TEST_CONTROL/live" ] || return 1
  touch "$DEV_E2E_TEST_CONTROL/health-checked"
}
ps() { cat "$DEV_E2E_TEST_CONTROL/executable"; }
# The keychain listing: one Developer ID identity unless a case says otherwise.
security() { cat "$DEV_E2E_TEST_CONTROL/identities"; }
# Background Task Management's record, which is empty unless a case writes one.
sfltool() { cat "$DEV_E2E_TEST_CONTROL/btm" 2>/dev/null || true; }
# The toolchain this case's Mac has: a selected Xcode on the release's own SDK
# unless a case says otherwise. vtool's two verbs are the whole of what the loop
# asks of it, and the rewrite is an event so a case can prove where it falls.
xcode-select() { cat "$DEV_E2E_TEST_CONTROL/developer-dir"; }
xcrun() {
  case "$*" in
    '--show-sdk-version') cat "$DEV_E2E_TEST_CONTROL/default-sdk-version" ;;
    '--sdk '*' --show-sdk-version') printf '26.5\n' ;;
    'vtool -show-build '*) printf '    minos 15.0\n      sdk 15.0\n' ;;
    'vtool -set-build-version macos '*) event "stamp ${!###*/} $4 $5" ;;
    *) echo "unexpected xcrun $*" >&2; return 2 ;;
  esac
}
IDENTITY='Developer ID Application: Fermix Test (TEAM123456)'

launchctl() {
  local label="${2##*/}" file
  # Every service this loop looks at, so a case can prove which identity's
  # registrations it reads.
  printf '%s\n' "$label" >>"$DEV_E2E_TEST_CONTROL/inspected"
  case "$label" in
    "$AGENT_LABEL") file="$DEV_E2E_TEST_CONTROL/agent" ;;
    "$APP_LABEL") file="$DEV_E2E_TEST_CONTROL/login" ;;
    *) echo "unexpected service $label" >&2; return 2 ;;
  esac
  if [ -f "$file" ]; then cat "$file"; return; fi
  echo "Could not find service $label in domain" >&2
  return 113
}

pgrep() {
  local pattern="${!#}" kind found=1
  for kind in gui helper; do
    [ -f "$DEV_E2E_TEST_CONTROL/$kind" ] || continue
    [[ "$(cat "$DEV_E2E_TEST_CONTROL/$kind")" =~ $pattern ]] || continue
    printf '%s\n' 123
    found=0
  done
  return "$found"
}

pkill() {
  local pattern="${!#}" kind found=1
  for kind in gui helper; do
    [ -f "$DEV_E2E_TEST_CONTROL/$kind" ] || continue
    [[ "$(cat "$DEV_E2E_TEST_CONTROL/$kind")" =~ $pattern ]] || continue
    event "quit-$kind"
    rm "$DEV_E2E_TEST_CONTROL/$kind"
    found=0
  done
  return "$found"
}

open() {
  if [ "$#" = 1 ]; then
    [ -f "$DEV_E2E_TEST_CONTROL/gui" ] || fail "reopen found no existing GUI"
    [ -f "$DEV_E2E_TEST_CONTROL/health-checked" ] || fail "reopened before the engine was verified healthy"
    event reopen
    return
  fi
  event open
  rm -f "$DEV_E2E_TEST_CONTROL/health-checked"
  printf '%s %s\n' "$APP/Contents/MacOS/$GUI_EXECUTABLE" "$DEV_FLAG" >"$DEV_E2E_TEST_CONTROL/gui"
  if [ "${4:-}" = '--register-background-service' ] && [ ! -f "$DEV_E2E_TEST_CONTROL/btm" ]; then
    [ "$(plutil -extract fermix_home raw -o - "$RECORD" 2>/dev/null)" = "$DEV_HOME" ] ||
      fail "GUI registration received the wrong bootstrap home"
    event register
    printf 'program = %s/Contents/MacOS/FermixAgent\n' "$APP" >"$DEV_E2E_TEST_CONTROL/agent"
    python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$DEV_HOME/daemon.sock"
    touch "$DEV_E2E_TEST_CONTROL/live"
  fi
}

# The heavy work replaced, and the paths pointed inside this case's work
# directory. RECORD_DIR and RECORD are deliberately NOT overridden: they are
# what the script derives from the product configuration and the account, and
# the account is this case's own (see the --case entry below).
setup_case() {
  ROOT_DIR="$WORK_DIR/repo"
  APP="$ROOT_DIR/Apps/Fermix/dist-e2e/$APP_BUNDLE_NAME"
  DEV_HOME="$WORK_DIR/dev home"
  ENGINE_SRC="$WORK_DIR/engine"
  ENGINE_TREE="$ENGINE_SRC/_build/prod/rel/fermix_app_engine"
  export DEV_E2E_TEST_CONTROL="$WORK_DIR/control" DEV_E2E_TEST_EVENTS="$WORK_DIR/events"
  export DEV_E2E_TEST_APP="$APP"
  export DEV_E2E_TEST_SOURCE="$TEST_SOURCE" DEV_E2E_TEST_LABEL="$AGENT_LABEL"
  export DEV_E2E_TEST_IDENTITY="$IDENTITY"
  mkdir -p "$ROOT_DIR/scripts" "$DEV_E2E_TEST_CONTROL" "$DEV_HOME" "$ENGINE_SRC/scripts/dev"
  : >"$DEV_E2E_TEST_EVENTS"
  : >"$DEV_E2E_TEST_CONTROL/inspected"
  write_identities "$IDENTITY"
  printf '%s\n' /Applications/Xcode.app/Contents/Developer >"$DEV_E2E_TEST_CONTROL/developer-dir"
  printf '26.5\n' >"$DEV_E2E_TEST_CONTROL/default-sdk-version"
  write_stubs
  "$ROOT_DIR/scripts/stage_app.sh"
  : >"$DEV_E2E_TEST_EVENTS"
}

# The `security find-identity -v -p codesigning` listing for the named
# identities, in its real shape: a numbered line per identity and a count.
write_identities() {
  local index=1 name
  : >"$DEV_E2E_TEST_CONTROL/identities"
  for name in "$@"; do
    printf '  %d) %040X "%s"\n' "$index" "$index" "$name" >>"$DEV_E2E_TEST_CONTROL/identities"
    index=$((index + 1))
  done
  printf '     %d valid identities found\n' "$#" >>"$DEV_E2E_TEST_CONTROL/identities"
}

write_stubs() {
  cat >"$DEV_E2E_TEST_CONTROL/gui-stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  '--unregister-login-items')
    echo unregister >>"$DEV_E2E_TEST_EVENTS"
    rm -f "$DEV_E2E_TEST_CONTROL/agent" "$DEV_E2E_TEST_CONTROL/login" ;;
  '--development-engine --register-background-service')
    echo 'background registration must run inside the opened GUI, not a maintenance process' >&2
    exit 1 ;;
  *) echo "unexpected maintenance arguments: $*" >&2; exit 2 ;;
esac
STUB
  cat >"$ROOT_DIR/scripts/stage_app.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo stage >>"$DEV_E2E_TEST_EVENTS"
printf '%s\n' "${SDKROOT:-}" >"$DEV_E2E_TEST_CONTROL/staged-sdk"
mkdir -p "$DEV_E2E_TEST_APP/Contents/MacOS" "$DEV_E2E_TEST_APP/Contents/Library/LaunchAgents"
python3 -c 'import pathlib,plistlib,sys;pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({"CFBundleVersion":sys.argv[2]}))' \
  "$DEV_E2E_TEST_APP/Contents/Info.plist" "${2:-1}"
cp "$DEV_E2E_TEST_CONTROL/gui-stub" "$DEV_E2E_TEST_APP/Contents/MacOS/Fermix"
chmod +x "$DEV_E2E_TEST_APP/Contents/MacOS/Fermix"
"$DEV_E2E_TEST_SOURCE/scripts/render_launch_agent_plist.sh" "$DEV_E2E_TEST_APP/Contents/Library/LaunchAgents/$DEV_E2E_TEST_LABEL.plist"
STUB
  cat >"$ROOT_DIR/scripts/sign_app.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
port="$(plutil -extract EnvironmentVariables.PORT raw -o - "$DEV_E2E_TEST_APP/Contents/Library/LaunchAgents/$DEV_E2E_TEST_LABEL.plist")"
[ "$port" = 4530 ]
[ "$2" = "$DEV_E2E_TEST_IDENTITY" ] || { echo "signed with '$2', not the keychain's Developer ID identity" >&2; exit 1; }
echo sign >>"$DEV_E2E_TEST_EVENTS"
STUB
  cat >"$ROOT_DIR/scripts/verify_staged_app.sh" <<'STUB'
#!/usr/bin/env bash
echo verify >>"$DEV_E2E_TEST_EVENTS"
STUB
  cat >"$ENGINE_SRC/scripts/dev/engine_stop.py" <<'STUB'
import os
from pathlib import Path
with open(os.environ["DEV_E2E_TEST_EVENTS"], "a") as events:
    events.write("stop\n")
Path(os.environ["FERMIX_HOME"], "daemon.sock").unlink()
Path(os.environ["DEV_E2E_TEST_CONTROL"], "live").unlink(missing_ok=True)
STUB
  chmod +x "$ROOT_DIR/scripts/"*.sh
}

owned_service() {
  printf 'program = %s/Contents/MacOS/FermixAgent\n' "$APP" >"$DEV_E2E_TEST_CONTROL/agent"
  printf '%s %s\n' "$APP/Contents/MacOS/$GUI_EXECUTABLE" "$DEV_FLAG" >"$DEV_E2E_TEST_CONTROL/gui"
  printf '%s/Contents/MacOS/FermixAgent\n' "$APP" >"$DEV_E2E_TEST_CONTROL/helper"
  python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$DEV_HOME/daemon.sock"
  touch "$DEV_E2E_TEST_CONTROL/live"
  mkdir -p "$RECORD_DIR"
  printf '{"fermix_home":"%s","schema_version":1}' "$DEV_HOME" >"$RECORD"
}

# The installed app's value for a configuration key, read with the overlay
# unset. Nothing here restates an identity: both halves come from the one
# reader, so a case comparing them fails the day the overlay stops overriding
# a key rather than the day someone edits a literal.
production_config() {
  (
    unset PRODUCT_CONFIG_OVERLAY
    # shellcheck source=scripts/product_config.sh
    source "$TEST_SOURCE/scripts/product_config.sh"
    product_config "$1"
  )
}

# A service registered under the DEVELOPMENT label that some other bundle owns.
# The installed app's own label is never looked at, so this is the only
# ownership question the loop can ask.
case_foreign() {
  printf 'program = /Applications/Fermix.app/Contents/MacOS/FermixAgent\n' >"$DEV_E2E_TEST_CONTROL/agent"
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "accepted another bundle's service"; fi
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing another bundle's service"
  [ ! -e "$RECORD" ] || fail "changed the bootstrap record"
}

case_pid_owner() {
  owned_service
  printf 'path = (submitted by smd)\nprogram identifier = Contents/MacOS/FermixAgent (mode: 2)\npid = 123\n' >"$DEV_E2E_TEST_CONTROL/agent"
  printf '%s/Contents/Resources/Engine/arm64/erts/bin/beam.smp\n' "$APP" >"$DEV_E2E_TEST_CONTROL/executable"
  down >/dev/null
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = $'unregister\nquit-gui\nstop' ] || fail "did not resolve the submitted agent's ownership"
}

# A job launchd could not spawn: no pid, only the parent bundle version. The
# staged bundle's own build number proves ownership; any other version does not.
case_version_owner() {
  owned_service
  stage_and_sign "$IDENTITY" >/dev/null
  : >"$DEV_E2E_TEST_EVENTS"
  printf 'path = (submitted by smd)\nprogram identifier = Contents/MacOS/FermixAgent (mode: 2)\nparent bundle version = 1700000000\njob state = spawn failed\n' >"$DEV_E2E_TEST_CONTROL/agent"
  down >/dev/null
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = $'unregister\nquit-gui\nstop' ] || fail "did not own the unspawned job by its bundle version: $(cat "$DEV_E2E_TEST_EVENTS")"
}

case_version_foreign() {
  owned_service
  stage_and_sign "$IDENTITY" >/dev/null
  : >"$DEV_E2E_TEST_EVENTS"
  printf 'path = (submitted by smd)\nprogram identifier = Contents/MacOS/FermixAgent (mode: 2)\nparent bundle version = 42\n' >"$DEV_E2E_TEST_CONTROL/agent"
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "accepted an unspawned job of another build"; fi
  grep -Fq 'could not verify ownership' "$WORK_DIR/refusal" || fail "the version mismatch was not an ownership refusal"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated a job of another build"
}

case_foreign_pid() {
  printf 'path = (submitted by smd)\npid = 123\n' >"$DEV_E2E_TEST_CONTROL/agent"
  printf '/Applications/Fermix.app/Contents/MacOS/FermixAgent\n' >"$DEV_E2E_TEST_CONTROL/executable"
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "accepted another bundle's submitted service"; fi
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing another process owner"
}

case_unknown_owner() {
  printf 'path = (submitted by smd)\nprogram identifier = Contents/MacOS/FermixAgent (mode: 2)\n' >"$DEV_E2E_TEST_CONTROL/agent"
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "accepted a service without ownership evidence"; fi
  grep -Fq 'could not verify ownership' "$WORK_DIR/refusal" || fail "ownership refusal did not explain the failure"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated an unverified service"
}

case_restart() {
  owned_service
  up --fast >/dev/null
  expected=$'unregister\nquit-gui\nstop\nstage\nsign\nverify\nopen\nregister\nreopen'
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = "$expected" ] || fail "incorrect restart order: $(cat "$DEV_E2E_TEST_EVENTS")"
}

case_manual_open() {
  open_app >/dev/null
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = open ] || fail "manual dev launch requested background registration"
  [ ! -e "$DEV_E2E_TEST_CONTROL/agent" ] || fail "manual dev launch registered an agent"
  [ ! -e "$DEV_HOME/daemon.sock" ] || fail "manual dev launch started an engine"
}

case_down() {
  owned_service
  down >/dev/null
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = $'unregister\nquit-gui\nstop' ] || fail "down did not unregister before shutdown"
  # The record is the development identity's own file. There is nothing of
  # anyone else's to put back and nothing to remove, so the bundle can be
  # opened again without another up.
  [ "$(plutil -extract fermix_home raw -o - "$RECORD")" = "$DEV_HOME" ] ||
    fail "down changed the development identity's own record"
}

# The port is written into the staged development plist and nowhere else. The
# comparison is the installed app's own plist, rendered with the overlay unset,
# because that is the file this loop must not have changed the shape of.
#
# The PATH is the opposite case: it is rendered into every agent plist, so the
# development bundle keeps it while it adds its port, and the installed one
# carries it without one.
case_port() {
  stage_and_sign "$IDENTITY" >/dev/null
  local production="$WORK_DIR/production.plist" expected_path
  expected_path="$(product_config agent_search_path)"
  [ "$(plutil -extract EnvironmentVariables.PORT raw -o - \
        "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist")" = "$PORT" ] ||
    fail "the development agent plist lost its port"
  [ "$(plutil -extract EnvironmentVariables.PATH raw -o - \
        "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist")" = "$expected_path" ] ||
    fail "the development agent plist lost its PATH when the port was added"
  ( unset PRODUCT_CONFIG_OVERLAY; "$TEST_SOURCE/scripts/render_launch_agent_plist.sh" "$production" )
  if plutil -extract EnvironmentVariables.PORT raw -o - "$production" >/dev/null 2>&1; then
    fail "the production agent inherited the development port"
  fi
  [ "$(plutil -extract EnvironmentVariables.PATH raw -o - "$production")" = "$expected_path" ] ||
    fail "the installed app's agent plist declares no PATH"
  [ "$(plutil -extract Label raw -o - "$production")" != "$AGENT_LABEL" ] ||
    fail "the installed app's agent plist carries the development label"
}

case_build_version() {
  local first second
  stage_and_sign "$IDENTITY" >/dev/null
  first="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
  [ "$first" = 1700000000 ] || fail "the first development build did not use the current epoch"
  stage_and_sign "$IDENTITY" >/dev/null
  second="$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")"
  [ "$second" = 1700000001 ] || fail "rebuilding without a clock advance reused its bundle version"
}

case_invalid_version() {
  local invalid
  for invalid in broken 0; do
    plutil -replace CFBundleVersion -string "$invalid" "$APP/Contents/Info.plist"
    if (stage_and_sign "$IDENTITY") >"$WORK_DIR/refusal" 2>&1; then fail "accepted an invalid prior build number"; fi
    [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "staged before validating the prior bundle version"
    [ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" = "$invalid" ] || fail "overwrote the invalid bundle"
  done
}

# No Developer ID in the keychain: refuse before the running loop is touched,
# and say why an ad-hoc signature is not an option for a registered agent.
case_no_identity() {
  owned_service
  write_identities
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "staged an ad-hoc bundle for a registered agent"; fi
  grep -Fq 'Team ID' "$WORK_DIR/refusal" || fail "the identity refusal did not name the Team ID rule"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing for a missing identity"
  [ -S "$DEV_HOME/daemon.sock" ] || fail "stopped the running engine without an identity to rebuild with"
}

case_two_identities() {
  write_identities "$IDENTITY" 'Developer ID Application: Other Team (TEAM654321)'
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "chose between two identities silently"; fi
  grep -Fq '2 Developer ID Application identities' "$WORK_DIR/refusal" || fail "the ambiguity refusal did not count the identities"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing an ambiguous identity"
}

case_signed_with_identity() {
  owned_service
  up --fast >/dev/null
  grep -q '^sign$' "$DEV_E2E_TEST_EVENTS" || fail "up did not sign the bundle"
  [ "$(status | sed -n 's/^identity //p')" = "$IDENTITY" ] || fail "status did not name the keychain identity"
}

# The dev home's keychain prefix is its own. A fresh home is created with the
# profile; a config without the core table gets it appended and keeps its other
# tables; a config that names another profile is refused before anything else
# happens, because that home would be writing into the live daemon's items.
case_profile_fresh_home() {
  rm -rf "$DEV_HOME"
  up --fast >/dev/null
  grep -q '^profile = "fermix-macos"$' "$DEV_HOME/config.toml" || fail "a fresh dev home did not get its secret profile"
}

case_profile_appended() {
  owned_service
  printf '[fermix_channels.telegram]\nenabled = true\n' >"$DEV_HOME/config.toml"
  up --fast >/dev/null
  python3 - "$DEV_HOME/config.toml" <<'CHECK' || fail "the profile was not appended beside the existing tables"
import sys, tomllib
with open(sys.argv[1], "rb") as source:
    document = tomllib.load(source)
assert document["fermix_core"]["profile"] == "fermix-macos", document
assert document["fermix_channels"]["telegram"]["enabled"] is True, document
CHECK
}

case_profile_foreign() {
  owned_service
  printf '[fermix_core]\nprofile = "general"\n' >"$DEV_HOME/config.toml"
  if (up --fast) >"$WORK_DIR/refusal" 2>&1; then fail "accepted a dev home on another secret profile"; fi
  grep -Fq "live daemon's keychain items" "$WORK_DIR/refusal" || fail "the profile refusal did not say why"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing the profile"
  [ "$(cat "$DEV_HOME/config.toml")" = $'[fermix_core]\nprofile = "general"' ] || fail "edited the refused config"
}

# The bundle this loop stages is a different app to macOS than the installed
# one: a different bundle name, and a launchd plist that registers a different
# label for a different bundle identifier. Every value is compared with the
# installed app's own, so this fails the day the overlay stops overriding one.
case_development_identity() {
  local plist
  stage_and_sign "$IDENTITY" >/dev/null
  plist="$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"

  [ "$(basename "$APP")" != "$(production_config app_bundle_name)" ] ||
    fail "staged the installed app's bundle name"
  [ "$APP_LABEL" != "$(production_config bundle_identifier)" ] ||
    fail "staged the installed app's bundle identifier"
  [ "$AGENT_LABEL" != "$(production_config agent_service_label)" ] ||
    fail "staged the installed app's agent label"
  [ "$(plutil -extract Label raw -o - "$plist")" = "$AGENT_LABEL" ] ||
    fail "the staged agent plist registers another label"
  [ "$(plutil -extract AssociatedBundleIdentifiers.0 raw -o - "$plist")" = "$APP_LABEL" ] ||
    fail "the staged agent plist names another bundle"
}

# There is one launcher.json per support folder and the development identity
# has its own, so the installed app's record is a file this loop has no name
# for: `up` writes only inside its own folder and leaves the other untouched.
case_installed_record_untouched() {
  local installed
  installed="$HOME/Library/Application Support/$(production_config support_directory_name)/launcher.json"
  mkdir -p "$(dirname "$installed")"
  printf 'the installed app record' >"$installed"
  owned_service
  up --fast >/dev/null

  [ "$RECORD" != "$installed" ] || fail "the loop writes the installed app's record"
  [ "$(cat "$installed")" = 'the installed app record' ] || fail "rewrote the installed app's record"
  [ "$(plutil -extract fermix_home raw -o - "$RECORD")" = "$DEV_HOME" ] ||
    fail "the development identity's record does not name the dev home"
}

# Which registrations the loop reads. Both development principals are
# inspected, so the assertion is not vacuous, and neither installed one is: a
# loop that reads another bundle's registration is a loop that can act on it.
case_installed_labels_untouched() {
  local inspected
  owned_service
  up --fast >/dev/null
  inspected="$(sort -u "$DEV_E2E_TEST_CONTROL/inspected")"

  printf '%s\n' "$inspected" | grep -Fqx "$AGENT_LABEL" ||
    fail "the development agent was never inspected"
  printf '%s\n' "$inspected" | grep -Fqx "$APP_LABEL" ||
    fail "the development login item was never inspected"
  ! printf '%s\n' "$inspected" | grep -Fqx "$(production_config agent_service_label)" ||
    fail "inspected the installed app's agent"
  ! printf '%s\n' "$inspected" | grep -Fqx "$(production_config bundle_identifier)" ||
    fail "inspected the installed app's login item"
}

# The SDK the app is staged against. A Mac with only the Command Line Tools, once
# they default to an SDK newer than the release's, cannot compile SwiftUI at
# all, so staging is pointed at the release's SDK beside it and both executables
# are restamped before signing; every other Mac is left exactly as it was.
command_line_tools() {
  local tools="$WORK_DIR/CommandLineTools"
  mkdir -p "$tools/SDKs"
  printf '%s\n' "$tools" >"$DEV_E2E_TEST_CONTROL/developer-dir"
  printf '%s\n' "$1" >"$DEV_E2E_TEST_CONTROL/default-sdk-version"
  printf '%s\n' "$tools"
}

case_toolchain_xcode() {
  owned_service
  up --fast >/dev/null
  [ -z "$(cat "$DEV_E2E_TEST_CONTROL/staged-sdk")" ] || fail "a selected Xcode was pointed at another SDK"
  ! grep -q '^stamp ' "$DEV_E2E_TEST_EVENTS" || fail "restamped executables a selected Xcode built"
}

case_toolchain_current_tools() {
  owned_service
  command_line_tools 26.5 >/dev/null
  up --fast >/dev/null
  [ -z "$(cat "$DEV_E2E_TEST_CONTROL/staged-sdk")" ] || fail "overrode a default SDK that builds the app"
  ! grep -q '^stamp ' "$DEV_E2E_TEST_EVENTS" || fail "restamped executables built on the default SDK"
}

case_toolchain_newer_tools() {
  local tools expected
  owned_service
  tools="$(command_line_tools 27.0)"
  mkdir -p "$tools/SDKs/MacOSX26.sdk"
  up --fast >/dev/null
  [ "$(cat "$DEV_E2E_TEST_CONTROL/staged-sdk")" = "$tools/SDKs/MacOSX26.sdk" ] ||
    fail "staged against '$(cat "$DEV_E2E_TEST_CONTROL/staged-sdk")', not the release's SDK"
  # Stamped after staging and before signing, both executables, keeping the
  # deployment target the build gave them.
  expected=$'unregister\nquit-gui\nstop\nstage\n'"stamp $GUI_EXECUTABLE 15.0 26.5"$'\n'"stamp $AGENT_EXECUTABLE 15.0 26.5"$'\nsign\nverify\nopen\nregister\nreopen'
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = "$expected" ] || fail "incorrect order: $(cat "$DEV_E2E_TEST_EVENTS")"
}

case_toolchain_no_buildable_sdk() {
  local output
  owned_service
  command_line_tools 27.0 >/dev/null
  if output="$(up --fast 2>&1)"; then fail "staged with no SDK that can build the app"; fi
  [[ "$output" == *"macOS 26 SDK is not installed"* ]] || fail "the refusal did not name the missing SDK: $output"
  [ ! -s "$DEV_E2E_TEST_EVENTS" ] || fail "mutated before refusing for a missing SDK"
}

# An unfinished lifecycle record from the last run makes the opened GUI refuse
# the registration, so `up` acknowledges it, after it has unregistered and
# stopped everything itself and never before, and only the development
# identity's own journal.
case_interrupted_transaction() {
  local installed
  installed="$HOME/Library/Application Support/$(production_config support_directory_name)"
  owned_service
  mkdir -p "$installed"
  printf '{"kind":"enable","phase":"mutate"}' >"$JOURNAL"
  printf '{"kind":"restart","phase":"drain"}' >"$installed/lifecycle-journal.json"
  up --fast >/dev/null
  [ ! -e "$JOURNAL" ] || fail "left the development identity's unfinished record in place"
  [ -f "$installed/lifecycle-journal.json" ] || fail "removed the installed app's lifecycle journal"
  [ "$(sed -n 1,3p "$DEV_E2E_TEST_EVENTS" | paste -sd, -)" = 'unregister,quit-gui,stop' ] ||
    fail "acknowledged the record before unregistering and stopping"
}

# The operator has the app's background switch off in System Settings. macOS then
# refuses every registration, so no job ever appears, and the loop says which
# switch to turn on rather than reporting a bare "no job".
case_agent_disallowed() {
  local output
  owned_service
  cat >"$DEV_E2E_TEST_CONTROL/btm" <<BTM
                 Name: FermixAgent
          Disposition: [enabled, disallowed, notified] (0x9)
           Identifier: 8.$AGENT_LABEL
BTM
  if output="$(up --fast 2>&1)"; then fail "reported up with the agent refused"; fi
  [[ "$output" == *"Allow in the Background"* ]] || fail "the refusal did not name the switch: $output"
  [[ "$output" == *"up --fast"* ]] || fail "the refusal did not say how to go on: $output"
}

if [ "${1:-}" = '--case' ]; then
  WORK_DIR="$(mktemp -d /private/tmp/fermix-dev-loop-test.XXXXXX)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  # The account this case runs in. dev_e2e.sh derives the development
  # identity's support folder from the account at source time, so the fake
  # account exists before it is sourced and every case then reads the record
  # path the script really computes rather than one the harness chose.
  export HOME="$WORK_DIR/account"
  mkdir -p "$HOME"
  # shellcheck source=scripts/dev_e2e.sh
  source "$TEST_SOURCE/scripts/dev_e2e.sh"
  # Source defines these boundaries; the test replaces their heavy work.
  build_engine() { event build; }
  engine_branch() { printf 'test\n'; }
  setup_case
  case "$2" in
    foreign) case_foreign ;;
    foreign_pid) case_foreign_pid ;;
    unknown_owner) case_unknown_owner ;;
    pid_owner) case_pid_owner ;;
    restart) case_restart ;;
    manual_open) case_manual_open ;;
    down) case_down ;;
    port) case_port ;;
    build_version) case_build_version ;;
    invalid_version) case_invalid_version ;;
    development_identity) case_development_identity ;;
    installed_record_untouched) case_installed_record_untouched ;;
    installed_labels_untouched) case_installed_labels_untouched ;;
    no_identity) case_no_identity ;;
    two_identities) case_two_identities ;;
    signed_with_identity) case_signed_with_identity ;;
    version_owner) case_version_owner ;;
    version_foreign) case_version_foreign ;;
    profile_fresh_home) case_profile_fresh_home ;;
    profile_appended) case_profile_appended ;;
    profile_foreign) case_profile_foreign ;;
    interrupted_transaction) case_interrupted_transaction ;;
    agent_disallowed) case_agent_disallowed ;;
    toolchain_xcode) case_toolchain_xcode ;;
    toolchain_current_tools) case_toolchain_current_tools ;;
    toolchain_newer_tools) case_toolchain_newer_tools ;;
    toolchain_no_buildable_sdk) case_toolchain_no_buildable_sdk ;;
    *) fail "unknown test case: $2" ;;
  esac
  exit
fi

failed=0
for scenario in foreign foreign_pid unknown_owner pid_owner restart manual_open down port build_version invalid_version development_identity installed_record_untouched installed_labels_untouched no_identity two_identities signed_with_identity version_owner version_foreign profile_fresh_home profile_appended profile_foreign interrupted_transaction agent_disallowed toolchain_xcode toolchain_current_tools toolchain_newer_tools toolchain_no_buildable_sdk; do
  if bash "$0" --case "$scenario"; then echo "ok $scenario"; else failed=1; echo "FAILED $scenario" >&2; fi
done
exit "$failed"
