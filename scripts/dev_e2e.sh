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
#   scripts/dev_e2e.sh down        quit the app, unregister its agent, stop the
#                                  engine (the dev identity keeps its record)
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
# registers the bundled background agent. (The last of those could not fire
# under the development identity anyway: the preflight counts copies of this
# bundle's own identifier, and an installed Fermix.app carries another one.) Its staged plist pins PORT=4530
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
# THE BUNDLE IT STAGES IS A DIFFERENT APP TO macOS. The whole run reads the
# product configuration through the development overlay
# (scripts/product.dev.json, see scripts/product_config.sh), so the staged
# bundle is "Fermix Dev.app", identifier io.tezra.FermixPet.dev, agent label
# io.tezra.FermixPet.dev.agent, url scheme fermix-dev, and its support folder is
# ~/Library/Application Support/Fermix Dev. macOS keys the launchd job on the
# label, the login item, the TCC grants and the copy count on the identifier,
# and there is one launcher.json per support folder — so the development
# identity has a bootstrap record OF ITS OWN and this loop never touches the
# installed app's record, its grants, its agent or its home. It refuses a
# registered service under the DEVELOPMENT label that belongs to another
# bundle, and unregisters its own before replacing its bundle. The installed
# app, if there is one, is not inspected and not changed.
#
# The one thing the two identities still share is the login keychain, which is
# why the dev home carries its own secret profile (below).
#
# THE APP IS BUILT AGAINST THE SDK THE RELEASE IS BUILT AGAINST. The runners
# select Xcode 26 (.github/workflows/fermix-app.yml), and a Mac with a selected
# Xcode builds with that Xcode's own SDK and is left alone. A Mac with only the
# Command Line Tools takes whichever SDK they installed last as its default,
# and since their update of 2026-09-20 that is the macOS 27 SDK, where SwiftUI's
# property wrappers are macros whose plugin ships with Xcode and not with the
# Command Line Tools: every `@State` in the tree fails with "plugin for module
# 'SwiftUIMacros' not found" and staging never produces a binary. The Command
# Line Tools keep the macOS 26 SDK beside the new one, so on such a Mac the
# staging build is pointed at it through SDKROOT. That is resolved before
# anything is touched, and `up` refuses, saying what to install, where that SDK
# is missing too.
#
# A build pointed at an SDK that way has `sdk 15.0` recorded in both
# executables by the linker, where it should record the SDK's own version, and
# macOS reads that field to decide which design a process is drawn in: left
# alone, the dev app gets the controls from before Liquid Glass and is not the
# app the release ships. So both executables are restamped with the SDK's real
# version, before they are signed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The development identity, for this process and every script it runs: staging,
# both plist renderers, signing and verification are separate processes and all
# of them have to read the same identity, so the overlay is exported rather
# than passed.
export PRODUCT_CONFIG_OVERLAY="$ROOT_DIR/scripts/product.dev.json"
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
APP_BUNDLE_NAME="$(product_config app_bundle_name)"
APP="$ROOT_DIR/Apps/Fermix/dist-e2e/$APP_BUNDLE_NAME"
GUI_EXECUTABLE="$(product_config gui_executable_name)"
AGENT_EXECUTABLE="$(product_config agent_executable_name)"
DEV_FLAG="--development-engine"
# The major version of the SDK the release is built with (see the header).
APP_SDK_MAJOR=26
ENGINE_TREE="$ENGINE_SRC/_build/prod/rel/fermix_app_engine"
# The development identity's own support folder, which is where its one
# bootstrap record lives. The installed app's folder is a different name and
# nothing here computes it.
RECORD_DIR="$HOME/Library/Application Support/$(product_config support_directory_name)"
RECORD="$RECORD_DIR/launcher.json"
# The development identity's lifecycle journal, beside its record. The file is
# there exactly while a transaction is unfinished: the app removes it on the
# way out of every transaction that completes.
JOURNAL="$RECORD_DIR/lifecycle-journal.json"
# The two principals this bundle registers with SMAppService, under the
# development identity. Both resolve the Fermix home through the record above.
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
# and the one whose Team ID the shipped app's grants are keyed to. Exactly
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

# The engine's release runs the asset tools the tailwind and esbuild packages
# download into _build. Tailwind's standalone binary, as published for Apple
# silicon, carries an ad hoc signature that does not cover the file, and macOS 27
# kills it at launch for that: the release died with "`mix tailwind fermix_web
# --minify` exited with 137" (2026-09-20). The package reads a tool's version by
# running it, so it then downloads the same bytes again on every build and
# nothing ever repairs itself. Signing the file again ad hoc covers it as it
# stands, which is all a local build tool needs.
#
# The release's own first step installs the tools, so it is run here ahead of
# the release: a clean worktree is repaired before its first build rather than
# after a failed one. A tool whose signature verifies is left exactly as it is.
make_asset_tools_runnable() {
  local tool
  (cd "$ENGINE_SRC/apps/fermix_web" && MIX_ENV=prod mix assets.setup >/dev/null)
  for tool in "$ENGINE_SRC"/_build/tailwind-* "$ENGINE_SRC"/_build/esbuild-*; do
    [ -f "$tool" ] || continue
    codesign --verify "$tool" 2>/dev/null && continue

    echo "dev_e2e: $(basename "$tool") cannot run as downloaded (its signature does not verify); signing it ad hoc"
    codesign --force --sign - "$tool" 2>/dev/null || fail "cannot sign $tool"
  done
}

build_engine() {
  require_engine_source
  echo "dev_e2e: building the app engine from $ENGINE_SRC ($(engine_branch) at $(engine_commit | cut -c1-12), $(engine_tree_state) tree, as it stands)..."
  (
    cd "$ENGINE_SRC"
    mix deps.get --only prod >/dev/null
    make_asset_tools_runnable
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

# The SDK to point the staging build at, or nothing where this Mac's own default
# builds the app (see the header). It can refuse, so `up` asks before it
# touches anything.
buildable_sdk() {
  local developer default_version sdk
  developer="$(xcode-select -p)" || fail "no developer directory is selected; run xcode-select --install"
  # A selected Xcode carries the macro plugins for its own SDK.
  case "$developer" in
    */CommandLineTools) ;;
    *) return 0 ;;
  esac

  default_version="$(xcrun --show-sdk-version)"
  case "$default_version" in
    '' | *[!0-9.]*) fail "cannot read the default SDK version (xcrun --show-sdk-version said '$default_version')" ;;
  esac
  [ "${default_version%%.*}" -gt "$APP_SDK_MAJOR" ] || return 0

  sdk="$developer/SDKs/MacOSX$APP_SDK_MAJOR.sdk"
  [ -d "$sdk" ] || fail "$(
    cat <<REFUSAL
the Command Line Tools default to the macOS $default_version SDK, which cannot compile
SwiftUI without Xcode, and the macOS $APP_SDK_MAJOR SDK is not installed beside it at
$sdk.
Install Xcode and select it (sudo xcode-select -s /Applications/Xcode.app), or
install Command Line Tools that carry the macOS $APP_SDK_MAJOR SDK.
REFUSAL
  )"
  printf '%s\n' "$sdk"
}

# Records the SDK's real version in both executables (see the header). vtool
# rewrites the load command in place and warns that the signature is now
# invalid, which is what is wanted here: signing is the next step.
stamp_sdk() {
  local sdk="${1:?stamp_sdk <sdk>}" version name binary minos
  version="$(xcrun --sdk "$sdk" --show-sdk-version)"
  for name in "$GUI_EXECUTABLE" "$AGENT_EXECUTABLE"; do
    binary="$APP/Contents/MacOS/$name"
    minos="$(xcrun vtool -show-build "$binary" | awk '$1 == "minos" { print $2; exit }')"
    [ -n "$minos" ] || fail "cannot read the deployment target of $binary"
    xcrun vtool -set-build-version macos "$minos" "$version" -replace -output "$binary" "$binary" 2>/dev/null ||
      fail "cannot record SDK $version in $binary"
  done
}

stage_and_sign() {
  local identity="${1:?stage_and_sign <signing-identity> [sdk]}" sdk="${2:-}" build_number
  build_number="$(next_dev_build_number)" || return 1
  if [ -n "$sdk" ]; then
    echo "dev_e2e: the default SDK here cannot build SwiftUI without Xcode; building against $sdk"
    export SDKROOT="$sdk"
  fi
  echo "dev_e2e: staging and signing the app (debug build $build_number, $identity)..."
  "$ROOT_DIR/scripts/stage_app.sh" 0.1.0 "$build_number" "$APP" native --configuration debug \
    --engine "$ENGINE_TREE" --cosign "$(command -v cosign)" >/dev/null
  [ -z "$sdk" ] || stamp_sdk "$sdk"
  # Into the dict the renderer already writes, beside the PATH it declares: a
  # whole-dict insert would refuse the key that is there, and replacing the dict
  # would drop the PATH the agent refuses to launch without.
  plutil -insert EnvironmentVariables.PORT -string "$PORT" \
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

# The development identity's bootstrap record, pointed at the dev home.
#
# Written rather than swapped: this record is in the development identity's own
# support folder, so there is nothing of the installed app's to move aside and
# nothing to put back. The app resolves the account from getpwuid(geteuid()) and
# reads no FERMIX_HOME, so this file is the only way to name a home, and the
# development configuration refuses to register unless it names the dev home.
write_dev_record() {
  mkdir -p "$DEV_HOME" "$RECORD_DIR"
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

# A lifecycle transaction the last run left unfinished. The product opens
# Recovery on one and starts nothing until the person acknowledges it, which is
# right for an installed app and a dead end here: the GUI this loop opens answers
# `--register-background-service` with recoveryPending, registers nothing, and
# `up` waits a minute for an agent nobody asked launchd for (2026-09-20, after
# macOS had refused the agent once and left an enable at its mutate phase).
#
# By the time this runs the loop has itself unregistered both principals, quit
# the app and stopped the engine, so whatever the record was guarding is undone.
# Removing it is this loop's acknowledgement, and it is the development
# identity's own journal: the installed app's is in another folder.
acknowledge_interrupted_transaction() {
  [ -f "$JOURNAL" ] || return 0
  echo "dev_e2e: the last run left a lifecycle transaction unfinished ($(tr -d '\n' <"$JOURNAL" | cut -c1-120)); acknowledging it"
  rm -f "$JOURNAL"
}

# Whether macOS is refusing the agent on the operator's own say-so. System
# Settings > General > Login Items & Extensions carries one Allow in the
# Background switch per app. While it is off SMAppService answers every
# registration with "Operation not permitted", launchd never gets a job, and
# nothing this loop or the app can do turns it back on: on 2026-09-20 that read
# as "launchd: no job" and cost an hour looking at the build. Background Task
# Management records the switch as `disallowed` on the agent's own item, where
# the disposition line comes before the identifier line.
agent_disallowed() {
  sfltool dumpbtm 2>/dev/null |
    awk -v label="$AGENT_LABEL" '/Disposition:/ { disposition = $0 } /Identifier:/ && index($0, label) { print disposition; exit }' |
    grep -q disallowed
}

start_engine() {
  # Registration runs through the opened GUI's journaled lifecycle.
  local state
  for _ in $(seq 1 60); do
    if live && [ -S "$DEV_HOME/daemon.sock" ]; then return 0; fi
    sleep 1
  done
  if agent_disallowed; then
    fail "$(
      cat <<REFUSAL
macOS is not allowing ${APP_BUNDLE_NAME%.app} to run in the background, so it refused the
agent ("Operation not permitted") and no engine started. The build is fine.
Turn ${APP_BUNDLE_NAME%.app} on under System Settings > General > Login Items & Extensions >
Allow in the Background, then run: scripts/dev_e2e.sh up --fast
REFUSAL
    )"
  fi
  state="$(agent_job_state)"
  fail "the bundled agent did not bring up $DEV_HOME/daemon.sock and port $PORT within 60s (launchd: ${state:-no job}; logs: $DEV_HOME/logs/)"
}

up() {
  local fast="${1:-}" identity sdk
  identity="$(signing_identity)" || return 1
  sdk="$(buildable_sdk)" || return 1
  ensure_secret_profile || return 1
  unregister_dev_services
  quit_app
  stop_engine
  live && fail "port $PORT is still occupied; refusing to start a second engine"
  acknowledge_interrupted_transaction
  [ "$fast" = "--fast" ] || build_engine
  stage_and_sign "$identity" "$sdk"
  write_dev_record
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
  bundle  $APP_LABEL, agent $AGENT_LABEL
  home    $DEV_HOME
  record  $RECORD
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
  echo "dev_e2e: down. ($DEV_HOME and $RECORD are kept; delete them yourself for a fresh start)"
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
  if [ -f "$RECORD" ]; then
    echo "record   $RECORD: $(cat "$RECORD")"
  else
    echo "record   absent at $RECORD, so the development configuration refuses to register. Run up."
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    up) up "${2:-}" ;;
    down) down ;;
    status) status ;;
    *) fail "usage: dev_e2e.sh up [--fast] | down | status" ;;
  esac
fi
