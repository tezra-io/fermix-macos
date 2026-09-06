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
IDENTITY='Developer ID Application: Fermix Test (TEAM123456)'

launchctl() {
  local label="${2##*/}" file
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
  if [ "${4:-}" = '--register-background-service' ]; then
    record_uses_dev_home || fail "GUI registration received the wrong bootstrap home"
    event register
    printf 'program = %s/Contents/MacOS/FermixAgent\n' "$APP" >"$DEV_E2E_TEST_CONTROL/agent"
    python3 -c 'import socket,sys;s=socket.socket(socket.AF_UNIX);s.bind(sys.argv[1]);s.close()' "$DEV_HOME/daemon.sock"
    touch "$DEV_E2E_TEST_CONTROL/live"
  fi
}

setup_case() {
  WORK_DIR="$(mktemp -d /private/tmp/fermix-dev-loop-test.XXXXXX)"
  trap 'rm -rf "$WORK_DIR"' EXIT
  ROOT_DIR="$WORK_DIR/repo"
  APP="$ROOT_DIR/Apps/Fermix/dist-e2e/FermixPet.app"
  DEV_HOME="$WORK_DIR/dev home"
  ENGINE_SRC="$WORK_DIR/engine"
  ENGINE_TREE="$ENGINE_SRC/_build/prod/rel/fermix_app_engine"
  RECORD_DIR="$WORK_DIR/records"
  RECORD="$RECORD_DIR/launcher.json"
  RECORD_BACKUP="$RECORD_DIR/launcher.json.pre-dev"
  export DEV_E2E_TEST_CONTROL="$WORK_DIR/control" DEV_E2E_TEST_EVENTS="$WORK_DIR/events"
  export DEV_E2E_TEST_APP="$APP"
  export DEV_E2E_TEST_SOURCE="$TEST_SOURCE" DEV_E2E_TEST_LABEL="$AGENT_LABEL"
  export DEV_E2E_TEST_IDENTITY="$IDENTITY"
  mkdir -p "$ROOT_DIR/scripts" "$DEV_E2E_TEST_CONTROL" "$RECORD_DIR" "$DEV_HOME" "$ENGINE_SRC/scripts/dev"
  : >"$DEV_E2E_TEST_EVENTS"
  write_identities "$IDENTITY"
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
  printf '{"fermix_home":"%s","schema_version":1}' "$DEV_HOME" >"$RECORD"
}

case_foreign() {
  printf 'program = /Applications/FermixPet.app/Contents/MacOS/FermixAgent\n' >"$DEV_E2E_TEST_CONTROL/agent"
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
  printf '/Applications/FermixPet.app/Contents/MacOS/FermixAgent\n' >"$DEV_E2E_TEST_CONTROL/executable"
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
  printf 'original record' >"$RECORD_BACKUP"
  down >/dev/null
  [ "$(cat "$DEV_E2E_TEST_EVENTS")" = $'unregister\nquit-gui\nstop' ] || fail "down did not unregister before shutdown"
  [ "$(cat "$RECORD")" = 'original record' ] || fail "original record was not restored"
}

case_port() {
  stage_and_sign "$IDENTITY" >/dev/null
  local production="$WORK_DIR/production.plist"
  "$TEST_SOURCE/scripts/render_launch_agent_plist.sh" "$production"
  if plutil -extract EnvironmentVariables.PORT raw -o - "$production" >/dev/null 2>&1; then
    fail "the production agent inherited the development port"
  fi
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

write_escaped_dev_record() {
  python3 -c 'import json,sys;print(json.dumps({"fermix_home":sys.argv[1],"schema_version":1}).replace("/", "\\/"))' \
    "$DEV_HOME" >"$RECORD"
}

case_escaped_record() {
  write_escaped_dev_record
  point_record_at_dev_home >/dev/null
  [ ! -e "$RECORD_BACKUP" ] || fail "mistook escaped dev-home JSON for another home"
  printf 'original record' >"$RECORD_BACKUP"
  write_escaped_dev_record
  point_record_at_dev_home >/dev/null
  [ "$(cat "$RECORD_BACKUP")" = 'original record' ] || fail "replaced the original backup"
}

case_escaped_down() {
  write_escaped_dev_record
  down >/dev/null
  [ ! -e "$RECORD" ] || fail "left an escaped dev-home record behind"
}

case_invalid_record() {
  local malformed
  for malformed in '{invalid' '{"fermix_home":27,"schema_version":1}'; do
    printf '%s' "$malformed" >"$RECORD"
    if (point_record_at_dev_home) >"$WORK_DIR/refusal" 2>&1; then fail "accepted a malformed bootstrap record"; fi
    [ "$(cat "$RECORD")" = "$malformed" ] || fail "changed the malformed record"
    [ ! -e "$RECORD_BACKUP" ] || fail "backed up malformed JSON as another home"
    if (down) >"$WORK_DIR/refusal" 2>&1; then fail "down ignored a malformed bootstrap record"; fi
    [ "$(cat "$RECORD")" = "$malformed" ] || fail "removed malformed JSON"
  done
}

if [ "${1:-}" = '--case' ]; then
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
    escaped_record) case_escaped_record ;;
    escaped_down) case_escaped_down ;;
    invalid_record) case_invalid_record ;;
    no_identity) case_no_identity ;;
    two_identities) case_two_identities ;;
    signed_with_identity) case_signed_with_identity ;;
    version_owner) case_version_owner ;;
    version_foreign) case_version_foreign ;;
    *) fail "unknown test case: $2" ;;
  esac
  exit
fi

failed=0
for scenario in foreign foreign_pid unknown_owner pid_owner restart manual_open down port build_version invalid_version escaped_record escaped_down invalid_record no_identity two_identities signed_with_identity version_owner version_foreign; do
  if bash "$0" --case "$scenario"; then echo "ok $scenario"; else failed=1; echo "FAILED $scenario" >&2; fi
done
exit "$failed"
