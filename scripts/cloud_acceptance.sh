#!/usr/bin/env bash
#
# Cloud acceptance: install and upgrade the app on a rented, clean Mac mini and
# report what macOS did. The "does it start for a new user, does it upgrade for
# an existing one, does the background agent run without macOS blocking it"
# session of docs/STAGE0_RUNBOOK.md, on a Scaleway Apple silicon server that
# is reached over ssh and torn down when its lease allows.
#
#   scripts/cloud_acceptance.sh run --release [vX.Y.Z]   the published release (default: the latest)
#   scripts/cloud_acceptance.sh run --dev                the current checkout, built and signed here
#       --upgrade-from vX.Y.Z   install that release first and take it through
#                               setup, then put the candidate over it
#       --reboot                reboot the Mac afterwards and prove the agent
#                               and the login item come back
#       --chat "<text>"         the message the companion-wire check sends
#       --type <M1-M>           Scaleway server type (default M1-M, the cheapest)
#       --zone <fr-par-3>       default: fr-par-3 for M1, fr-par-1 for the rest
#       --macos <text>          choose the macOS by name or version substring;
#                               default: the newest non-beta one for the type
#   scripts/cloud_acceptance.sh status                   the server, its lease and how to reach it
#   scripts/cloud_acceptance.sh ssh | vnc                open a shell, or Screen Sharing
#   scripts/cloud_acceptance.sh down                     delete the server once its lease allows
#
# One server, named fermix-acceptance, is reused for as long as it exists; each
# run resets the account to a fresh user first (STAGE0_RUNBOOK §10). The Apple
# licence puts a 24-hour minimum on every lease, powering the Mac off does not
# stop the charge, and only deletion does, so `run` schedules the deletion at
# creation and `down` deletes as soon as the lease allows. The console and the
# API show the same `deletable_at`.
#
# What one run proves, in order, each as a check the report records:
#   Gatekeeper accepts the quarantined DMG and the app inside it, both stapled
#   (release and notarized dev candidates; a signed-only dev candidate skips it);
#   first launch plus <scheme>://setup registers the login item and the agent,
#   launchd runs the agent, the daemon answers /health/live and daemon.sock,
#   hello names the engine the bundle carries, and the bootstrap record's
#   receipt names the installed build; the GUI quits without taking the daemon
#   down and relaunches; a chat message gets a reply when the engine serves the
#   companion wire and a provider is configured (otherwise recorded as skipped);
#   with --upgrade-from, the agent's designated requirement is unchanged across
#   N to N+1 (STAGE0 §6) and the new build's first launch rebuilt the
#   registration; with --reboot, everything is back after a reboot.
# Not exercised: the first-launch Open dialog (quarantine is stripped after the
# assessment), the in-app Sparkle update (the feed is fixed to the published
# appcast), the microphone prompt (fires at the first voice call).
#
# A --dev candidate is built here from the checkout as it stands, with the
# engine engine/PIN.json pins, signed with the one Developer ID Application
# identity in the login keychain. With notarytool credentials in the
# environment (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD) it is the release
# artifact, scripts/package_release.sh's DMG; without them it is a signed zip,
# and the Gatekeeper gate is recorded as skipped.
#
# Needs: scw (brew install scw; scw init) with a project whose ssh keys include
# one of ~/.ssh/*.pub, jq, gh (release lookup and engine download), cosign
# (engine verification, --dev only).
#
# Output: output/acceptance/<run id>-<label>/report.md with checks, facts and
# the evidence pulled from the Mac. The exit status is non-zero when any check
# failed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
# shellcheck source=scripts/engine_pin.sh
source "$ROOT_DIR/scripts/engine_pin.sh"
# shellcheck source=scripts/signing_identity.sh
source "$ROOT_DIR/scripts/signing_identity.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
ARTIFACT_NAME="${APP_BUNDLE_NAME%.app}"
BUNDLE_ID="$(product_config bundle_identifier)"
URL_SCHEME="$(product_config url_scheme)"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
AGENT_LABEL="$(product_config agent_service_label)"
SUPPORT_DIR="$(product_config support_directory_name)"
ENGINE_RELATIVE_PATH="$(product_config engine_relative_path)"

# The production engine's loopback port (the daemon's own `setup.origin` in
# hello), and the app's unified-log subsystem (AppLog.swift). Neither is
# product configuration; both are what the probes read.
ENGINE_PORT=4030
LOG_SUBSYSTEM="ai.fermix.app"

SERVER_NAME="${CLOUD_ACCEPTANCE_SERVER_NAME:-fermix-acceptance}"
TYPE="${CLOUD_ACCEPTANCE_TYPE:-M1-M}"
ZONE="${CLOUD_ACCEPTANCE_ZONE:-}"
MACOS_FILTER=""
OUTPUT_ROOT="$ROOT_DIR/output/acceptance"
# Relative to the remote account's home; the login shell starts there.
REMOTE_WORK="fermix-acceptance"

fail() {
  echo "cloud_acceptance: $*" >&2
  exit 1
}

say() { echo "cloud_acceptance: $*" >&2; }

# ---- prerequisites -----------------------------------------------------------

require_tools() {
  local tool
  for tool in scw jq ssh scp gh python3; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed (scw: brew install scw && scw init)"
  done
  [ -n "$(scw config get access-key 2>/dev/null)" ] ||
    fail "scw has no credentials; run scw init with an API key that can manage Apple silicon servers"
}

# The Mac accepts only the keys registered with the Scaleway project, so a
# local key that is not there would fail at the first ssh, an hour and a few
# euros later.
require_project_ssh_key() {
  local registered key
  registered="$(scw_json iam ssh-key list | jq -r '.[].public_key' | awk '{print $2}')"
  for key in $(cat "$HOME"/.ssh/*.pub 2>/dev/null | awk '{print $2}'); do
    if grep -qxF "$key" <<<"$registered"; then return 0; fi
  done
  fail "none of the keys in ~/.ssh/*.pub is registered with the Scaleway project, so the Mac would refuse every ssh login. Register one: scw iam ssh-key create name=<name> public-key=\"\$(cat ~/.ssh/id_ed25519.pub)\""
}

resolve_zone() {
  if [ -z "$ZONE" ]; then
    case "$TYPE" in
      M1*) ZONE=fr-par-3 ;;
      *) ZONE=fr-par-1 ;;
    esac
  fi
}

# ---- Scaleway ----------------------------------------------------------------

scw_json() { scw "$@" -o json; }

# Explicit failures throughout this section: bash drops errexit inside a
# command substitution, and a listing that failed quietly would read as "no
# server" and rent a second one.
find_server() {
  local list
  list="$(scw_json apple-silicon server list zone="$ZONE")" || fail "could not list the Apple silicon servers in $ZONE"
  jq -c --arg name "$SERVER_NAME" '[.[] | select(.name == $name)] | first // empty' <<<"$list"
}

server_get() { scw_json apple-silicon server get "$1" zone="$ZONE"; }

# The newest macOS that is not a beta, narrowed by --macos when given.
choose_os() {
  local list
  list="$(scw_json apple-silicon os list zone="$ZONE" server-type="$TYPE")" || fail "could not list the macOS versions for $TYPE in $ZONE"
  jq -c --arg filter "$MACOS_FILTER" '
      [.[] | select(.is_beta | not) | select(($filter == "") or ((.name + " " + .version) | test($filter; "i")))]
      | sort_by(.version | split(".") | map(tonumber? // 0)) | last // empty' <<<"$list"
}

create_server() {
  local os id
  os="$(choose_os)" || exit 1
  [ -n "$os" ] || fail "no macOS matches '$MACOS_FILTER' for $TYPE in $ZONE; see scw apple-silicon os list zone=$ZONE server-type=$TYPE"
  say "creating $TYPE in $ZONE with $(jq -r '.name + " " + .version' <<<"$os"): the lease runs 24 hours minimum and its deletion is scheduled for the end of it"
  id="$(scw_json apple-silicon server create zone="$ZONE" type="$TYPE" name="$SERVER_NAME" os-id="$(jq -r .id <<<"$os")" commitment-type=duration_24h | jq -r .id)" ||
    fail "the server was not created; check the Scaleway console"
  [ -n "$id" ] && [ "$id" != null ] || fail "the server was not created; check the Scaleway console"
  scw_json apple-silicon server update "$id" zone="$ZONE" schedule-deletion=true >/dev/null ||
    fail "$SERVER_NAME ($id) was created but its deletion could not be scheduled; schedule it in the console or run down"
  printf '%s\n' "$id"
}

# Ready and delivered. A non-default macOS takes about an hour to install, so
# the wait is generous and reports each change of state.
wait_ready() {
  local id="$1" json status delivered last="" i
  for ((i = 0; i < 300; i++)); do
    json="$(server_get "$id")" || fail "could not read $SERVER_NAME ($id) from Scaleway"
    status="$(jq -r .status <<<"$json")"
    delivered="$(jq -r .delivered <<<"$json")"
    if [ "$status" = ready ] && [ "$delivered" = true ]; then
      printf '%s\n' "$json"
      return 0
    fi
    [ "$status" != error ] || fail "$SERVER_NAME is in the error state; check the Scaleway console"
    if [ "$status/$delivered" != "$last" ]; then
      say "$SERVER_NAME is $status (delivered: $delivered)"
      last="$status/$delivered"
    fi
    sleep 20
  done
  fail "$SERVER_NAME did not become ready in time"
}

find_or_create_server() {
  local server id
  server="$(find_server)" || exit 1
  if [ -n "$server" ]; then
    id="$(jq -r .id <<<"$server")"
    say "reusing $SERVER_NAME ($id, $(jq -r .type <<<"$server") in $ZONE)"
  else
    id="$(create_server)" || exit 1
  fi
  wait_ready "$id"
}

read_server() {
  SERVER_ID="$(jq -r .id <<<"$1")"
  IP="$(jq -r .ip <<<"$1")"
  SSH_USER="$(jq -r .ssh_username <<<"$1")"
  SUDO_PASSWORD="$(jq -r .sudo_password <<<"$1")"
  VNC_URL="$(jq -r .vnc_url <<<"$1")"
  DELETABLE_AT="$(jq -r .deletable_at <<<"$1")"
  DELETION_SCHEDULED="$(jq -r .deletion_scheduled <<<"$1")"
  SERVER_TYPE="$(jq -r .type <<<"$1")"
  SERVER_OS="$(jq -r '.os.name + " " + .os.version' <<<"$1")"
  # One known_hosts per server: a new server is a new host key, and a file the
  # user's own known_hosts never sees.
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$OUTPUT_ROOT/known_hosts-$SERVER_ID" -o LogLevel=ERROR)
}

# Seconds until the lease allows deletion; negative once it does. A server
# that is still starting has no deletable_at yet.
seconds_until_deletable() {
  [ -n "$1" ] && [ "$1" != null ] || fail "$SERVER_NAME has no deletable_at yet; it is still being delivered"
  python3 - "$1" <<'PY'
import datetime, sys
stamp = sys.argv[1].replace("Z", "+00:00")
if "." in stamp:
    head, tail = stamp.split(".", 1)
    stamp = head + tail[tail.index("+"):]
deletable = datetime.datetime.fromisoformat(stamp)
print(int((deletable - datetime.datetime.now(datetime.timezone.utc)).total_seconds()))
PY
}

# ---- ssh ---------------------------------------------------------------------

ssh_run() { ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$IP" "$1"; }

remote_command() {
  printf 'bash %s/remote.sh' "$REMOTE_WORK"
  printf ' %q' "$@"
}

remote() { ssh -n "${SSH_OPTS[@]}" "$SSH_USER@$IP" "$(remote_command "$@")"; }

wait_ssh() {
  local i
  for ((i = 0; i < 60; i++)); do
    if ssh_run true 2>/dev/null; then return 0; fi
    sleep 10
  done
  fail "$SSH_USER@$IP did not answer ssh within 10 minutes; the console's Overview page shows the SSH command and the VNC URL: $VNC_URL"
}

wait_ssh_down() {
  local i
  for ((i = 0; i < 12; i++)); do
    if ! ssh_run true 2>/dev/null; then return 0; fi
    sleep 5
  done
  fail "$SSH_USER@$IP is still answering ssh a minute after the reboot was asked for"
}

console_owner() { remote console 2>/dev/null || true; }

wait_console() {
  local i
  for ((i = 0; i < 30; i++)); do
    if [ "$(console_owner)" = "$SSH_USER" ]; then return 0; fi
    sleep 10
  done
  return 1
}

write_remote_env() {
  printf 'export %s=%q\n' \
    FX_RUN_ID "$RUN_ID" \
    FX_REPOSITORY "$REPOSITORY" \
    FX_ARTIFACT_NAME "$ARTIFACT_NAME" \
    FX_APP_BUNDLE_NAME "$APP_BUNDLE_NAME" \
    FX_BUNDLE_ID "$BUNDLE_ID" \
    FX_URL_SCHEME "$URL_SCHEME" \
    FX_GUI_EXECUTABLE "$GUI_EXECUTABLE" \
    FX_AGENT_EXECUTABLE "$AGENT_EXECUTABLE" \
    FX_AGENT_LABEL "$AGENT_LABEL" \
    FX_SUPPORT_DIR "$SUPPORT_DIR" \
    FX_ENGINE_RELATIVE_PATH "$ENGINE_RELATIVE_PATH" \
    FX_PORT "$ENGINE_PORT" \
    FX_LOG_SUBSYSTEM "$LOG_SUBSYSTEM" >"$RUN_DIR/env.sh"
}

install_remote_helper() {
  ssh_run "mkdir -p $REMOTE_WORK/artifacts $REMOTE_WORK/runs/$RUN_ID" || fail "could not make $REMOTE_WORK on the Mac"
  scp "${SSH_OPTS[@]}" "$ROOT_DIR/scripts/cloud_acceptance_remote.sh" "$SSH_USER@$IP:$REMOTE_WORK/remote.sh" || fail "could not upload the remote helper"
  scp "${SSH_OPTS[@]}" "$RUN_DIR/env.sh" "$SSH_USER@$IP:$REMOTE_WORK/env.sh" || fail "could not upload the remote environment"
}

upload_artifact() {
  scp "${SSH_OPTS[@]}" "$1" "$SSH_USER@$IP:$REMOTE_WORK/artifacts/$(basename "$1")" || fail "could not upload $1"
}

# The console must belong to the account before anything touches the app:
# login items, launchd's gui domain and every prompt live in that session.
# Scaleway delivers the Mac at the login window; prepare sets autologin and one
# reboot logs it in.
prepare_mac() {
  local console
  if ! printf '%s\n' "$SUDO_PASSWORD" |
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP" "$(remote_command prepare)" | record_lines prepare; then
    fail "the Mac refused prepare; see $RUN_DIR"
  fi
  console="$(fact_value prepare console)"
  if [ "$console" != "$SSH_USER" ]; then
    say "the console belongs to $console, not $SSH_USER; rebooting into the autologin session"
    reboot_and_wait
  fi
  [ "$(console_owner)" = "$SSH_USER" ] ||
    fail "the console still does not belong to $SSH_USER after a reboot. Log in once over Screen Sharing ($VNC_URL, password on the server's Overview page), then run again"
}

reboot_and_wait() {
  # The connection drops as the Mac goes down, which ssh reports as a failure.
  remote reboot >/dev/null 2>&1 || true
  wait_ssh_down
  wait_ssh
  wait_console || fail "nobody owns the console $SSH_USER's session should own after the reboot; log in once over Screen Sharing ($VNC_URL) and run again"
}

# ---- the record --------------------------------------------------------------

record_lines() {
  local phase="$1" line name result detail
  while IFS= read -r line; do
    case "$line" in
      check\|*)
        name="$(cut -d'|' -f2 <<<"$line")"
        result="$(cut -d'|' -f3 <<<"$line")"
        detail="$(cut -d'|' -f4- <<<"$line")"
        printf '%s\t%s\t%s\t%s\n' "$phase" "$name" "$result" "$detail" >>"$CHECKS"
        echo "  [$result] $phase/$name: $detail"
        ;;
      fact\|*)
        name="$(cut -d'|' -f2 <<<"$line")"
        detail="$(cut -d'|' -f3- <<<"$line")"
        printf '%s\t%s\t%s\n' "$phase" "$name" "$detail" >>"$FACTS"
        echo "  - $phase/$name: $detail"
        ;;
      *) echo "  $line" ;;
    esac
  done
}

record_check() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$CHECKS"; echo "  [$3] $1/$2: $4"; }
record_fact() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$FACTS"; echo "  - $1/$2: $3"; }

fact_value() {
  awk -F'\t' -v phase="$1" -v key="$2" '$1 == phase && $2 == key { value = $3 } END { print value }' "$FACTS"
}

# One remote verb, recorded under a phase. A refusal from the remote ends the
# run: a failed check is a fact, a refused verb is a broken run.
step() {
  local phase="$1" log
  shift
  STEP=$((STEP + 1))
  log="$RUN_DIR/remote/$(printf '%02d' "$STEP")-$1.log"
  say "$phase: $*"
  if ! remote "$@" | tee "$log" | record_lines "$phase"; then
    fail "the Mac refused '$*' (phase $phase); see $log"
  fi
}

failures() { awk -F'\t' '$3 == "FAIL"' "$CHECKS" | wc -l | tr -d ' '; }

# ---- the candidate -----------------------------------------------------------

latest_release_tag() { gh release view --repo "$REPOSITORY" --json tagName -q .tagName; }

# The release path: the Mac downloads the DMG itself and proves the sha256
# sidecar, so the bytes under test are the published ones.
release_candidate() {
  CANDIDATE_TAG="${1:-$(latest_release_tag)}"
  [ -n "$CANDIDATE_TAG" ] || fail "no release tag: gh release view --repo $REPOSITORY answered nothing"
  CANDIDATE_VERSION="${CANDIDATE_TAG#v}"
  CANDIDATE_KIND=dmg
  CANDIDATE_FILE="$ARTIFACT_NAME-$CANDIDATE_VERSION.dmg"
  CANDIDATE_LABEL="release $CANDIDATE_TAG"
  CANDIDATE_SOURCE="https://github.com/$REPOSITORY/releases/tag/$CANDIDATE_TAG"
}

fetch_release_on_mac() {
  step "$1" fetch-release "$2" "${2#v}"
}

# The dev path: built here from the checkout as it stands. With notarytool
# credentials it is the release artifact; without them a signed zip, so the
# Gatekeeper gate is skipped and the report says so.
dev_candidate() {
  local version build identity stage app zip target engine_flags=()
  version="$(product_config marketing_version)"
  build="$(product_config build_number)"
  identity="$(signing_identity)" || exit 1
  CANDIDATE_VERSION="$version"
  CANDIDATE_LABEL="dev $(git -C "$ROOT_DIR" rev-parse --short HEAD) $version ($build)"
  CANDIDATE_SOURCE="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref HEAD) at $(git -C "$ROOT_DIR" rev-parse HEAD)"
  if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    say "building the notarized release artifact for $version ($build)"
    MACOS_DEVELOPER_ID="$identity" "$ROOT_DIR/scripts/package_release.sh" "$version" "$build" || fail "packaging refused"
    CANDIDATE_KIND=dmg
    CANDIDATE_PATH="$ROOT_DIR/dist/$ARTIFACT_NAME-$version.dmg"
  else
    say "no notarytool credentials in the environment (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD): the candidate is signed but not notarized, so the Gatekeeper gate is skipped"
    stage="$RUN_DIR/stage"
    app="$stage/$APP_BUNDLE_NAME"
    mkdir -p "$stage"
    [ "$(engine_pin_state "$ENGINE_PIN_DEFAULT_PATH")" = pinned ] || fail "engine/PIN.json is unpinned; a candidate ships an engine"
    "$ROOT_DIR/scripts/fetch_engine.sh" "$ENGINE_PIN_DEFAULT_PATH" "$RUN_DIR/engine-download" || fail "the pinned engine could not be fetched"
    "$ROOT_DIR/scripts/verify_engine.sh" "$ENGINE_PIN_DEFAULT_PATH" "$RUN_DIR/engine-download" "$RUN_DIR/engine" || fail "the pinned engine did not verify"
    for target in "${ENGINE_PIN_TARGETS[@]}"; do
      engine_flags+=(--engine "$RUN_DIR/engine/$target")
    done
    "$ROOT_DIR/scripts/stage_app.sh" "$version" "$build" "$app" universal "${engine_flags[@]}" || fail "staging refused"
    "$ROOT_DIR/scripts/sign_app.sh" "$app" "$identity" || fail "signing refused"
    "$ROOT_DIR/scripts/verify_staged_app.sh" "$app" universal signed release || fail "the release audience refused the staged bundle"
    zip="$RUN_DIR/$ARTIFACT_NAME-$version-$build.zip"
    ditto -c -k --keepParent "$app" "$zip" || fail "could not archive $app"
    CANDIDATE_KIND=zip
    CANDIDATE_PATH="$zip"
  fi
  CANDIDATE_FILE="$(basename "$CANDIDATE_PATH")"
}

# Gate, install and start one artifact. The first install of a run activates
# (Welcome, then setup); an install over a running account launches, and the
# new build's first launch rebuilds the registration itself.
install_and_start() {
  local phase="$1" kind="$2" file="$3" how="$4"
  case "$kind" in
    dmg)
      step "$phase" gate-dmg "$file"
      step "$phase" install-dmg "$file"
      ;;
    zip)
      record_check "$phase" gatekeeper_dmg SKIP "a signed-only candidate is not notarized, so Gatekeeper is not asked"
      step "$phase" install-zip "$file"
      ;;
  esac
  step "$phase" "$how"
  step "$phase" verify
  step "$phase" agent-requirement
}

# ---- the report --------------------------------------------------------------

write_report() {
  local report="$RUN_DIR/report.md" macos="not collected" outcome
  if [ -f "$RUN_DIR/evidence/sw_vers.txt" ]; then
    macos="$(awk '/ProductVersion/ { v = $NF } /BuildVersion/ { b = $NF } END { print v " (" b ")" }' "$RUN_DIR/evidence/sw_vers.txt")"
  fi
  if [ "$(failures)" = 0 ]; then outcome="passed"; else outcome="failed ($(failures) checks)"; fi
  {
    echo "# Cloud acceptance: $CANDIDATE_LABEL"
    echo
    echo "Run $RUN_ID $outcome. Candidate: $CANDIDATE_KIND $CANDIDATE_FILE from $CANDIDATE_SOURCE. Mode: $MODE_LABEL."
    echo
    echo "## Mac"
    echo
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Server | $SERVER_NAME, $SERVER_TYPE in $ZONE ($SERVER_ID) |"
    echo "| Ordered macOS | $SERVER_OS |"
    echo "| Running macOS | $macos |"
    echo "| Address | $SSH_USER@$IP, Screen Sharing $VNC_URL |"
    echo "| Lease | deletable from $DELETABLE_AT (UTC), deletion scheduled: $DELETION_SCHEDULED |"
    echo
    echo "## Checks"
    echo
    echo "| Phase | Check | Result | Detail |"
    echo "|---|---|---|---|"
    awk -F'\t' '{ printf "| %s | %s | %s | %s |\n", $1, $2, $3, $4 }' "$CHECKS"
    echo
    echo "## Facts"
    echo
    echo "| Phase | Fact | Value |"
    echo "|---|---|---|"
    awk -F'\t' '{ printf "| %s | %s | %s |\n", $1, $2, $3 }' "$FACTS"
    echo
    echo "## Evidence"
    echo
    if [ -d "$RUN_DIR/evidence" ]; then
      (cd "$RUN_DIR/evidence" && find . -type f | sort | sed 's|^\./|- evidence/|')
    else
      echo "- none pulled from the Mac"
    fi
    echo "- remote/ holds every verb's output"
    echo
    echo "## Not exercised by this run"
    echo
    echo "- The first-launch Open dialog for a quarantined app: quarantine is stripped after the spctl assessment."
    echo "- The in-app Sparkle update: the feed is fixed to the published appcast, so that path runs only once the site publishes it."
    echo "- The microphone prompt: it fires at the first voice call, which this run does not place."
  } >"$report"
  echo
  echo "cloud_acceptance: $outcome; report at $report"
  awk -F'\t' '$3 == "FAIL" { printf "  FAIL %s/%s: %s\n", $1, $2, $4 }' "$CHECKS"
  echo "cloud_acceptance: the lease allows deletion from $DELETABLE_AT UTC (scheduled: $DELETION_SCHEDULED); scripts/cloud_acceptance.sh down deletes it as soon as it can"
}

# ---- verbs -------------------------------------------------------------------

run() {
  local mode="" tag="" upgrade_from="" reboot=no chat_text="Say hello in one sentence." server old_requirement new_requirement
  while [ $# -gt 0 ]; do
    case "$1" in
      --release)
        mode=release
        if [ $# -gt 1 ] && [ "${2#v}" != "$2" ]; then
          tag="$2"
          shift
        fi
        ;;
      --dev) mode=dev ;;
      --upgrade-from)
        [ $# -gt 1 ] || fail "--upgrade-from needs a release tag"
        upgrade_from="$2"
        shift
        ;;
      --reboot) reboot=yes ;;
      --chat)
        [ $# -gt 1 ] || fail "--chat needs a message"
        chat_text="$2"
        shift
        ;;
      --type)
        [ $# -gt 1 ] || fail "--type needs a server type"
        TYPE="$2"
        shift
        ;;
      --zone)
        [ $# -gt 1 ] || fail "--zone needs a zone"
        ZONE="$2"
        shift
        ;;
      --macos)
        [ $# -gt 1 ] || fail "--macos needs a name or version"
        MACOS_FILTER="$2"
        shift
        ;;
      *) fail "unknown argument $1; usage: run (--release [vX.Y.Z] | --dev) [--upgrade-from vX.Y.Z] [--reboot] [--chat <text>] [--type T] [--zone Z] [--macos M]" ;;
    esac
    shift
  done
  [ -n "$mode" ] || fail "run needs --release [vX.Y.Z] or --dev"
  [ "$mode" = release ] || [ -z "$tag" ] || fail "a tag goes with --release"

  require_tools
  resolve_zone
  require_project_ssh_key
  REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner)" || fail "gh could not name this repository; is gh signed in?"

  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$OUTPUT_ROOT/$RUN_ID-$mode"
  CHECKS="$RUN_DIR/checks.tsv"
  FACTS="$RUN_DIR/facts.tsv"
  STEP=0
  mkdir -p "$RUN_DIR/remote"
  : >"$CHECKS"
  : >"$FACTS"

  case "$mode" in
    release) release_candidate "$tag" ;;
    dev) dev_candidate ;;
  esac
  if [ -n "$upgrade_from" ]; then
    MODE_LABEL="upgrade from $upgrade_from"
  else
    MODE_LABEL="fresh install"
  fi
  [ "$reboot" = no ] || MODE_LABEL="$MODE_LABEL, then reboot"

  server="$(find_or_create_server)" || exit 1
  read_server "$server"
  record_fact server type "$SERVER_TYPE in $ZONE, $SERVER_OS"
  record_fact server deletable_at "$DELETABLE_AT (deletion scheduled: $DELETION_SCHEDULED)"
  wait_ssh
  write_remote_env
  install_remote_helper
  prepare_mac
  [ "$mode" = release ] || upload_artifact "$CANDIDATE_PATH"

  step reset reset

  if [ -n "$upgrade_from" ]; then
    fetch_release_on_mac before-upgrade "$upgrade_from"
    install_and_start before-upgrade dmg "$ARTIFACT_NAME-${upgrade_from#v}.dmg" activate
    old_requirement="$(fact_value before-upgrade agent_requirement)"
    step before-upgrade quit-gui
    [ "$mode" != release ] || fetch_release_on_mac upgrade "$CANDIDATE_TAG"
    install_and_start upgrade "$CANDIDATE_KIND" "$CANDIDATE_FILE" launch
    new_requirement="$(fact_value upgrade agent_requirement)"
    if [ "$old_requirement" = "$new_requirement" ]; then
      record_check upgrade agent_requirement_stable PASS "the agent's designated requirement is unchanged across the upgrade"
    else
      record_check upgrade agent_requirement_stable FAIL "before: $old_requirement; after: $new_requirement"
    fi
    PHASE=upgrade
  else
    [ "$mode" != release ] || fetch_release_on_mac install "$CANDIDATE_TAG"
    install_and_start install "$CANDIDATE_KIND" "$CANDIDATE_FILE" activate
    PHASE=install
  fi

  step "$PHASE" quit-gui
  step "$PHASE" relaunch
  step "$PHASE" chat "$chat_text"
  step "$PHASE" collect

  if [ "$reboot" = yes ]; then
    say "rebooting the Mac to prove the agent and the login item come back"
    reboot_and_wait
    sleep 20
    step reboot verify
    step reboot collect
  fi

  scp -r "${SSH_OPTS[@]}" "$SSH_USER@$IP:$REMOTE_WORK/runs/$RUN_ID" "$RUN_DIR/evidence" || fail "could not pull the evidence from the Mac"
  write_report
  [ "$(failures)" = 0 ]
}

# The server's canonical object into the SERVER_* variables; non-zero when
# there is no server of that name.
load_server() {
  local server
  server="$(find_server)" || exit 1
  [ -n "$server" ] || return 1
  server="$(server_get "$(jq -r .id <<<"$server")")" || fail "could not read $SERVER_NAME from Scaleway"
  read_server "$server"
  SERVER_STATUS="$(jq -r .status <<<"$server")"
}

status() {
  local remaining
  require_tools
  resolve_zone
  if ! load_server; then
    echo "no server named $SERVER_NAME in $ZONE"
    return 0
  fi
  remaining="$(seconds_until_deletable "$DELETABLE_AT")" || exit 1
  echo "server    $SERVER_NAME ($SERVER_ID): $SERVER_TYPE in $ZONE, $SERVER_OS, $SERVER_STATUS"
  echo "ssh       ssh $SSH_USER@$IP"
  echo "vnc       $VNC_URL (password on the server's Overview page)"
  if [ "$remaining" -gt 0 ]; then
    echo "lease     deletable in $((remaining / 3600)) h $(((remaining % 3600) / 60)) min ($DELETABLE_AT UTC); deletion scheduled: $DELETION_SCHEDULED"
  else
    echo "lease     deletable now; deletion scheduled: $DELETION_SCHEDULED"
  fi
}

open_ssh() {
  require_tools
  resolve_zone
  load_server || fail "no server named $SERVER_NAME in $ZONE"
  exec ssh "${SSH_OPTS[@]}" "$SSH_USER@$IP"
}

open_vnc() {
  require_tools
  resolve_zone
  load_server || fail "no server named $SERVER_NAME in $ZONE"
  echo "Screen Sharing: $VNC_URL, user $SSH_USER, password on the server's Overview page in the console"
  open "$VNC_URL"
}

# Deletion is what stops the charge. Before the lease allows it, the one thing
# to do is make sure the deletion is scheduled.
down() {
  local remaining
  require_tools
  resolve_zone
  if ! load_server; then
    echo "no server named $SERVER_NAME in $ZONE; nothing is billing"
    return 0
  fi
  remaining="$(seconds_until_deletable "$DELETABLE_AT")" || exit 1
  if [ "$remaining" -le 0 ]; then
    scw_json apple-silicon server delete "$SERVER_ID" zone="$ZONE" >/dev/null || fail "Scaleway refused the deletion of $SERVER_ID"
    echo "deleting $SERVER_NAME ($SERVER_ID); billing stops when the deletion completes, about 30 minutes"
    return 0
  fi
  if [ "$DELETION_SCHEDULED" != true ]; then
    scw_json apple-silicon server update "$SERVER_ID" zone="$ZONE" schedule-deletion=true >/dev/null || fail "Scaleway refused to schedule the deletion of $SERVER_ID"
    echo "deletion scheduled"
  fi
  echo "the 24-hour lease allows deletion in $((remaining / 3600)) h $(((remaining % 3600) / 60)) min ($DELETABLE_AT UTC); it is scheduled and needs nothing from you. Run down again after that to delete it sooner than the schedule does."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    run) shift; run "$@" ;;
    status) status ;;
    ssh) open_ssh ;;
    vnc) open_vnc ;;
    down) down ;;
    *) fail "usage: cloud_acceptance.sh run (--release [vX.Y.Z] | --dev) [--upgrade-from vX.Y.Z] [--reboot] [--chat <text>] [--type T] [--zone Z] [--macos M] | status | ssh | vnc | down" ;;
  esac
fi
