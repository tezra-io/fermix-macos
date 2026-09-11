#!/usr/bin/env bash
#
# One-command dev loop for the Fermix app with its engine embedded and
# RUNNING — the "click around a live app" setup, not the Stage 0 acceptance
# session (docs/E2E_RUNBOOK.md owns that).
#
#   scripts/dev_e2e.sh up          build engine + stage + sign + verify,
#                                  point the app at the dev home, open the app,
#                                  register its agent, refresh the live window
#   scripts/dev_e2e.sh up --fast   same, but reuse the already-built engine
#   scripts/dev_e2e.sh down        quit the app, stop the engine, remove the
#                                  dev-home record (restoring any original)
#   scripts/dev_e2e.sh status      what is running, and where
#
# Fixed dev-loop facts (constants, not knobs): home ~/.fermix-macos, port
# 4530, secret profile fermix-macos (its own keychain prefix, so a secret
# saved in the app never lands in the live daemon's items), engine built from
# the worktree at ~/.cache/fermix-engine-m34
# (FERMIX_REPO names the checkout it is a worktree of, for the refusal that
# tells you how to create it). The live daemon on ~/.fermix:4030 and the mix
# dev daemon on ~/.fermix-dev:4031 are untouched.
#
# The engine is built from that worktree EXACTLY AS IT STANDS, uncommitted work
# included. This loop neither fetches, resets nor creates it: a dev loop that
# ran `reset --hard` discarded the very tree it exists to run (it did, until
# 2026-09-05). Switch its branch yourself; `status` prints which one it is on.
#
# The app is opened in its DEVELOPMENT configuration (`--development-engine`),
# which is why the bundle is staged `--configuration debug`: that configuration
# compiles into debug builds only. It means activation does not ask the three
# refusals that name an installed copy — the bundle is in a build directory,
# your Homebrew launch agent is registered, and a second copy exists — and
# registers the bundled background agent. Its staged plist pins PORT=4530
# before signing, so launchd restarts use the same isolated port as first boot.
# The normal production plist and the GUI's login preference are unchanged.
#
# THE BUNDLE IS SIGNED WITH YOUR DEVELOPER ID, NEVER AD HOC. The agent is
# registered through SMAppService, and macOS keys that registration on the Team
# ID of the code it registered: the launch constraint it keeps for the agent
# and the bundle it looks the agent up in both derive from it. An ad-hoc
# signature carries no Team ID, so its identity is the cdhash of one build; the
# next rebuild is a different program to the constraint launchd kept, the agent
# dies at spawn with an AMFI launch constraint violation, and once the bundle
# directory has been replaced the item cannot find its bundle at all (exit 78,
# "not a bundle"). Both were observed on every rebuild on 2026-09-05; see
# docs/design/M34_MACOS_APP_RCA_2026-09-05.md. The identity is resolved before
# anything is touched, and `up` refuses without exactly one.
#
# IT REWRITES THIS ACCOUNT'S BOOTSTRAP RECORD. There is one launcher.json per
# account (~/Library/Application Support/Fermix/launcher.json) and no override
# for it: the app resolves the account from getpwuid(geteuid()) on purpose, so
# a dev loop cannot be given a record of its own. `up` therefore moves the
# existing record aside and writes one pointing at the dev home, and `down`
# puts it back. While the loop is up, anything that reads the record reads the
# dev home — so a registered FermixPet background item would follow this loop's
# home on its next relaunch, and a crash between `up` and `down` would leave it
# pointing there. `up` refuses any registered item owned by another bundle.
# This loop's own item is unregistered before its bundle or record is replaced.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"
FERMIX_REPO="${FERMIX_REPO:-$HOME/projects/fermix}"
# The developer's own engine worktree, so this loop is immune to whatever branch
# the main fermix checkout happens to be on (concurrent sessions switch it) and
# still builds the work in progress.
ENGINE_SRC="$HOME/.cache/fermix-engine-m34"
DEV_HOME="$HOME/.fermix-macos"
PORT=4530
# The engine names its keychain items fermix:<ENV> under the config's
# [fermix_core] profile, never under the home. A home without a profile of its
# own therefore reads and WRITES production's items: on 2026-09-05 a Telegram
# bot token saved from the app replaced the live daemon's, and the live daemon
# polled the new bot after its next restart. The dev home carries this profile
# before the engine ever boots on it.
SECRET_PROFILE="fermix-macos"
APP="$ROOT_DIR/Apps/Fermix/dist-e2e/FermixPet.app"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
DEV_FLAG="--development-engine"
ENGINE_TREE="$ENGINE_SRC/_build/prod/rel/fermix_app_engine"
RECORD_DIR="$HOME/Library/Application Support/Fermix"
RECORD="$RECORD_DIR/launcher.json"
RECORD_BACKUP="$RECORD_DIR/launcher.json.pre-dev"
# The two principals an installed Fermix registers with SMAppService. Both
# resolve the Fermix home through the record this loop swaps.
AGENT_LABEL="$(product_config agent_service_label)"
APP_LABEL="$(product_config bundle_identifier)"

fail() {
  echo "dev_e2e: $*" >&2
  exit 1
}

live() {
  curl -sf -m 1 "http://127.0.0.1:$PORT/health/live" >/dev/null 2>&1
}

# The one signing identity this loop uses: the Developer ID Application
# certificate in the login keychain, which is the identity a release carries
# and the one whose Team ID the shipped FermixPet's grants are keyed to. Exactly
# one, or a refusal that says what to import; a second identity would make the
# choice silent.
signing_identity() {
  local listing matches count
  listing="$(security find-identity -v -p codesigning 2>/dev/null)" || listing=""
  matches="$(printf '%s\n' "$listing" | grep -F 'Developer ID Application:' || true)"
  count="$(printf '%s' "$matches" | grep -c '"' || true)"
  case "$count" in
    1) printf '%s\n' "$matches" | sed -E 's/^[^"]*"([^"]*)".*$/\1/' ;;
    0) fail "no Developer ID Application identity in the login keychain. The background agent is registered through SMAppService, which keys on the Team ID of the signed code; an ad-hoc signature has none, so every rebuild is a new program to launchd and the agent stops launching. Import the certificate this team releases with (docs/E2E_RUNBOOK.md, "Importing your Developer ID on this Mac"), then run up again" ;;
    *) fail "$count Developer ID Application identities in the login keychain; keep exactly one so the choice is not silent" ;;
  esac
}

# The dev home's secrets live under their own keychain prefix. A missing config
# is written with the profile alone (the engine's first boot fills in the
# rest); a config with no [fermix_core] table gets the table appended; a
# config that names another profile, or none inside an existing table, is
# refused rather than edited, because that table is the engine's to write.
ensure_secret_profile() {
  local config="$DEV_HOME/config.toml"
  if [ ! -f "$config" ]; then
    mkdir -p "$DEV_HOME"
    printf '[fermix_core]\nprofile = "%s"\n' "$SECRET_PROFILE" >"$config"
    echo "dev_e2e: wrote $config with secret profile $SECRET_PROFILE"
    return 0
  fi
  python3 - "$config" "$SECRET_PROFILE" <<'PROFILE'
import sys, tomllib
path, wanted = sys.argv[1], sys.argv[2]
with open(path, "rb") as source:
    document = tomllib.load(source)
core = document.get("fermix_core")
if core is None:
    with open(path, "a", encoding="utf-8") as target:
        target.write(f'\n[fermix_core]\nprofile = "{wanted}"\n')
    print(f"dev_e2e: added secret profile {wanted} to {path}")
elif core.get("profile") != wanted:
    found = core.get("profile")
    sys.exit(
        f"dev_e2e: {path} sets [fermix_core] profile = {found!r}, not {wanted!r}. "
        "Without its own profile this home reads and writes the live daemon's keychain "
        f"items; set profile = \"{wanted}\" in that table, then run up again"
    )
PROFILE
}

# The engine worktree is the developer's, so this loop only checks that it is
# there. Creating it would pick a branch nobody asked for, and syncing it would
# discard uncommitted work — which is the whole reason this loop exists.
require_engine_source() {
  [ -e "$ENGINE_SRC/.git" ] || fail "$(
    cat <<REFUSAL
no engine worktree at $ENGINE_SRC.
This loop builds your engine work in progress and will not create or move it.
Make one from your fermix checkout, on the branch you are working on:
  git -C $FERMIX_REPO worktree add $ENGINE_SRC <branch>
REFUSAL
  )"
  [ -f "$ENGINE_SRC/mix.exs" ] || fail "$ENGINE_SRC carries no mix.exs, so it is not a fermix checkout"
}

engine_branch() {
  git -C "$ENGINE_SRC" rev-parse --abbrev-ref HEAD
}

engine_commit() {
  git -C "$ENGINE_SRC" rev-parse HEAD
}

# Whether the worktree carries changes the commit does not describe. The
# manifest can only name a commit, so a dirty tree is said out loud at build
# time rather than hidden behind a clean-looking hash.
engine_tree_state() {
  if [ -z "$(git -C "$ENGINE_SRC" status --porcelain)" ]; then
    echo "clean"
  else
    echo "dirty"
  fi
}

build_engine() {
  require_engine_source
  echo "dev_e2e: building the app engine from $ENGINE_SRC ($(engine_branch) at $(engine_commit | cut -c1-12), $(engine_tree_state) tree, as it stands)..."
  (
    cd "$ENGINE_SRC"
    mix deps.get --only prod >/dev/null
    # BuildInfo recompiles itself when these inputs change (__mix_recompile__?),
    # so no manual invalidation is needed. The source commit is the worktree's
    # real HEAD: a bundle stamped with zeroes could not say which revision it
    # was built from, and a fix that had never reached this worktree looked
    # applied because nothing in the bundle contradicted it.
    FERMIX_BUILD_ID="dev-e2e" \
      FERMIX_BUILD_SOURCE_COMMIT="$(engine_commit)" \
      FERMIX_BUILD_DISTRIBUTION=macos_app \
      FERMIX_BUILD_TARGET="macos_$(uname -m | sed 's/arm64/aarch64/')" \
      MIX_ENV=prod mix release fermix_app_engine --overwrite >/dev/null
  )
}

next_dev_build_number() {
  local epoch
  epoch="$(date -u +%s)" || return 1
  python3 - "$APP/Contents/Info.plist" "$epoch" <<'PY'
import pathlib
import plistlib
import sys

def positive_integer(value):
    if not isinstance(value, str) or not value.isascii() or not value.isdecimal() or int(value) <= 0:
        raise ValueError("the prior CFBundleVersion and current epoch must be positive integers")
    return int(value)

try:
    current = positive_integer(sys.argv[2])
    previous = 0
    path = pathlib.Path(sys.argv[1])
    if path.exists():
        with path.open("rb") as source:
            previous = positive_integer(plistlib.load(source)["CFBundleVersion"])
    print(max(previous + 1, current))
except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
    sys.exit(f"dev_e2e: cannot determine development build number: {error}")
PY
}

stage_and_sign() {
  local identity="${1:?stage_and_sign <signing-identity>}" build_number
  build_number="$(next_dev_build_number)" || return 1
  echo "dev_e2e: staging and signing the app (debug build $build_number, $identity)..."
  "$ROOT_DIR/scripts/stage_app.sh" 0.1.0 "$build_number" "$APP" native --configuration debug \
    --engine "$ENGINE_TREE" --cosign "$(command -v cosign)" >/dev/null
  plutil -insert EnvironmentVariables -json "{\"PORT\":\"$PORT\"}" \
    "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist"
  "$ROOT_DIR/scripts/sign_app.sh" "$APP" "$identity" >/dev/null
  "$ROOT_DIR/scripts/verify_staged_app.sh" "$APP" native signed development >/dev/null
}

# The pid of an app instance running this bundle in the development
# configuration, if one is up.
gui_pattern() {
  python3 -c 'import re,sys;print("^" + re.escape(sys.argv[1]) + r"([[:space:]]|$)")' \
    "$APP/Contents/MacOS/$GUI_EXECUTABLE"
}

gui_instances() {
  pgrep -f -- "$(gui_pattern)"
}

development_instance() {
  local escaped
  escaped="$(python3 -c 'import re,sys;print(re.escape(sys.argv[1]))' "$APP/Contents/MacOS/$GUI_EXECUTABLE")"
  pgrep -f -- "^$escaped $DEV_FLAG([[:space:]]|$)"
}

quit_app() {
  local result=0
  pkill -TERM -f -- "$(gui_pattern)" 2>/dev/null || result=$?
  [ "$result" = 0 ] || [ "$result" = 1 ] || fail "could not stop this bundle's GUI"
  for _ in $(seq 1 15); do
    result=0
    gui_instances >/dev/null || result=$?
    [ "$result" != 1 ] || return 0
    [ "$result" = 0 ] || fail "could not inspect this bundle's GUI"
    sleep 1
  done
  fail "the running app did not quit; quit it by hand and try again"
}

# LaunchServices hands --args to a NEW process only: opening a bundle that is
# already running activates it and drops them. The app would then come up in the
# PRODUCT configuration, where activation refuses on this Mac — and the flag
# would look like it had worked. So the previous instance is quit first, and the
# flag is read back off the process that actually came up.
open_app() {
  open "$APP" --args "$DEV_FLAG" "$@"
  for _ in $(seq 1 20); do
    development_instance >/dev/null && return 0
    sleep 1
  done
  fail "the app did not come up carrying $DEV_FLAG (a release build refuses it; this stages debug)"
}

# Whether an installed Fermix has a login item registered for this account.
# Read-only: `launchctl print` on a service target that does not exist exits
# non-zero and changes nothing.
registered_login_items() {
  local label report found=""
  for label in "$AGENT_LABEL" "$APP_LABEL"; do
    [ -n "$label" ] || fail "product_config returned an empty service label"
    if report="$(launchctl print "gui/$(id -u)/$label" 2>&1)"; then
      found="$found $label"
    elif [[ "$report" != *"Could not find service"* ]]; then
      fail "could not inspect $label: $report"
    fi
  done
  printf '%s' "${found# }"
}

# The build number of the staged dev bundle, or nothing when none is staged.
staged_bundle_version() {
  plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist" 2>/dev/null || true
}

# SMAppService may publish only a relative BundleProgram. Its launchctl PID
# then ties the job to its actual executable, including an exec'd bundled BEAM.
# A job launchd could not spawn has no PID, but it does publish the parent
# bundle version, and this loop's build numbers are epoch-derived (never a CI
# run number), so a match with the staged bundle is ownership evidence too.
require_dev_service_owner() {
  local label="$1" report executable path pid version
  for _ in $(seq 1 20); do
    report="$(launchctl print "gui/$(id -u)/$label" 2>&1)" ||
      fail "could not verify ownership of $label; its registration changed"
    executable="$(printf '%s\n' "$report" | sed -n 's/^[[:space:]]*program = //p')"
    path="$(printf '%s\n' "$report" | sed -n 's/^[[:space:]]*path = //p')"
    if [ -z "$executable" ] && [ "$path" = "$APP/Contents/Library/LaunchAgents/$AGENT_LABEL.plist" ]; then
      return 0
    fi
    version="$(printf '%s\n' "$report" | sed -n 's/^[[:space:]]*parent bundle version = //p')"
    if [ -z "$executable" ] && [ -n "$version" ] && [ "$version" = "$(staged_bundle_version)" ]; then
      return 0
    fi
    pid="$(printf '%s\n' "$report" | sed -n 's/^[[:space:]]*pid = //p')"
    if [ -z "$executable" ] && [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
      executable="$(ps -p "$pid" -o comm= 2>/dev/null)" || executable=""
    fi
    case "$executable" in
      "$APP/Contents/"*) return 0 ;;
      /*) fail "$label belongs to another bundle ($executable); refusing to replace the app or bootstrap record" ;;
    esac
    sleep 1
  done
  fail "could not verify ownership of $label within 20s; no service or bootstrap record was changed"
}

unregister_dev_services() {
  local registered label
  registered="$(registered_login_items)" || fail "could not inspect Fermix login items"
  [ -n "$registered" ] || return 0
  for label in $registered; do require_dev_service_owner "$label"; done
  [ -x "$APP/Contents/MacOS/$GUI_EXECUTABLE" ] || fail "the registered dev bundle cannot unregister its services"
  "$APP/Contents/MacOS/$GUI_EXECUTABLE" --unregister-login-items || fail "could not unregister dev login items"
  for _ in $(seq 1 20); do
    registered="$(registered_login_items)" || fail "could not verify dev service removal"
    [ -n "$registered" ] || return 0
    sleep 1
  done
  fail "dev login items remained registered after 20s; the bundle and bootstrap record were kept"
}

# Decode the JSON string: BootstrapStore may escape its path separators.
record_uses_dev_home() {
  local stored_path
  stored_path="$(plutil -extract fermix_home raw -expect string -o - "$RECORD" 2>/dev/null)" ||
    fail "could not parse fermix_home from $RECORD; the record was kept"
  [[ "$stored_path" = /* ]] || fail "$RECORD does not name an absolute Fermix home; the record was kept"
  [ "$stored_path" = "$DEV_HOME" ]
}

point_record_at_dev_home() {
  mkdir -p "$DEV_HOME" "$RECORD_DIR"
  if [ -f "$RECORD" ] && ! record_uses_dev_home; then
    [ -f "$RECORD_BACKUP" ] && fail "both $RECORD and $RECORD_BACKUP exist; resolve by hand"
    mv "$RECORD" "$RECORD_BACKUP"
    echo "dev_e2e: existing launcher.json saved to launcher.json.pre-dev"
  fi
  printf '{"fermix_home":"%s","schema_version":1}' "$DEV_HOME" >"$RECORD"
}

stop_engine() {
  # The engine runs with Erlang distribution off, so the release's rpc `stop`
  # cannot reach it; the management lifecycle is the sanctioned stop path.
  [ -S "$DEV_HOME/daemon.sock" ] || return 0
  FERMIX_HOME="$DEV_HOME" python3 "$ENGINE_SRC/scripts/dev/engine_stop.py" ||
    fail "could not stop the running engine (home $DEV_HOME)"
  for _ in $(seq 1 15); do
    [ -S "$DEV_HOME/daemon.sock" ] || return 0
    sleep 1
  done
  fail "engine did not release $DEV_HOME/daemon.sock within 15s"
}

# What launchd says about the agent's job, for the refusal that names it: a
# spawn refused by macOS never reaches the engine's logs, and 2026-09-05 was
# spent reading a bare timeout where "job state = spawn failed" was the fact.
agent_job_state() {
  launchctl print "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null |
    sed -n -E 's/^[[:space:]]*(job state|last exit code) = (.*)$/\1 \2/p' | paste -sd ';' - || true
}

start_engine() {
  # Registration runs through the opened GUI's journaled lifecycle.
  local state
  for _ in $(seq 1 60); do
    if live && [ -S "$DEV_HOME/daemon.sock" ]; then return 0; fi
    sleep 1
  done
  state="$(agent_job_state)"
  fail "the bundled agent did not bring up $DEV_HOME/daemon.sock and port $PORT within 60s (launchd: ${state:-no job}; logs: $DEV_HOME/logs/)"
}

up() {
  local fast="${1:-}" identity
  identity="$(signing_identity)" || return 1
  ensure_secret_profile || return 1
  unregister_dev_services
  quit_app
  stop_engine
  live && fail "port $PORT is still occupied; refusing to start a second engine"
  [ "$fast" = "--fast" ] || build_engine
  stage_and_sign "$identity"
  point_record_at_dev_home
  # The opened GUI registers its helper through its journaled lifecycle, the
  # same path the product takes. (The spawn refusals seen on 2026-09-05 were
  # the ad-hoc identity, not which process registered; see the header.)
  open_app --register-background-service
  start_engine
  # Reopen the existing GUI after health succeeds so Home reads the live engine.
  open "$APP"
  cat <<DONE
dev_e2e: up.
  app     $APP  ($DEV_FLAG)
  home    $DEV_HOME
  source  $ENGINE_SRC ($(engine_branch))
  engine  http://127.0.0.1:$PORT  (health, setup)
  signed  $identity
  secrets keychain prefix fermix:$SECRET_PROFILE (never the live daemon's)
  setup   FERMIX_HOME=$DEV_HOME python3 $ENGINE_SRC/scripts/dev/management_request.py setup.session.create
  done?   scripts/dev_e2e.sh down
DONE
}

down() {
  unregister_dev_services
  quit_app
  if [ -S "$DEV_HOME/daemon.sock" ]; then
    stop_engine
    echo "dev_e2e: engine stopped"
  else
    echo "dev_e2e: engine was not running"
  fi
  if [ -f "$RECORD_BACKUP" ]; then
    mv "$RECORD_BACKUP" "$RECORD"
    echo "dev_e2e: original launcher.json restored"
  elif [ -f "$RECORD" ] && record_uses_dev_home; then
    rm "$RECORD"
    echo "dev_e2e: dev-home record removed"
  fi
  echo "dev_e2e: down. ($DEV_HOME is kept; delete it yourself for a fresh start)"
}

status() {
  local identity
  if live; then echo "engine   live on $PORT (home $DEV_HOME)"; else echo "engine   not running"; fi
  if identity="$(signing_identity 2>/dev/null)"; then
    echo "identity $identity"
  else
    echo "identity none usable; up refuses (one Developer ID Application identity is required)"
  fi
  if [ -e "$ENGINE_SRC/.git" ]; then
    echo "source   $ENGINE_SRC ($(engine_branch)), built as it stands"
  else
    echo "source   absent at $ENGINE_SRC"
  fi
  if ! gui_instances >/dev/null; then
    echo "app      not running"
  elif development_instance >/dev/null; then
    echo "app      running ($DEV_FLAG)"
  else
    echo "app      running without $DEV_FLAG, so activation will refuse. Run up again."
  fi
  if [ -f "$RECORD" ]; then echo "record   $(cat "$RECORD")"; else echo "record   absent (defaults to ~/.fermix)"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    up) up "${2:-}" ;;
    down) down ;;
    status) status ;;
    *) fail "usage: dev_e2e.sh up [--fast] | down | status" ;;
  esac
fi
