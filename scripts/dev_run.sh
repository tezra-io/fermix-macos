#!/usr/bin/env bash
#
# Build, stage, and ad-hoc sign a Fermix app bundle for local inspection.
#
# This is the dev loop's equivalent of a release: the same stage_app.sh,
# sign_app.sh, and verify_staged_app.sh a signed release runs, differing only in
# the two places a dev machine must differ — the architecture is this machine's
# slice instead of universal2, and the identity is ad-hoc rather than a
# Developer ID. Nothing else is a separate code path, so a bundle that opens
# here is the bundle a release produces.
#
# It does not launch anything. The `open` command is printed for the operator to
# run deliberately, because launching the GUI is what triggers the microphone
# consent prompt and what starts a login-item transaction, and neither belongs
# in a build script. It never registers an SMAppService, never touches the
# keychain, and never writes a bootstrap record.
#
# The staged bundle carries an EMPTY engine slot until Stage 0 pins the signed
# engine trees, so the app has no engine of its own. The prerequisites printed
# at the end are how to give it one to talk to; they follow the fermix
# checkout's docs/DEVELOPMENT.md.
#
# Usage: dev_run.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/product_config.sh
source "$ROOT_DIR/scripts/product_config.sh"

APP_BUNDLE_NAME="$(product_config app_bundle_name)"
BUNDLE_ID="$(product_config bundle_identifier)"
AGENT_LABEL="$(product_config agent_service_label)"
VERSION="$(product_config marketing_version)"
BUILD_NUMBER="$(product_config build_number)"

DIST_DIR="$ROOT_DIR/Apps/Fermix/dist"
APP="$DIST_DIR/$APP_BUNDLE_NAME"

# The bootstrap record the GUI and the agent read. Production code reads no
# FERMIX_HOME, so this file is the only way to point either at a home.
BOOTSTRAP_RECORD="\$HOME/Library/Application Support/Fermix/launcher.json"

mkdir -p "$DIST_DIR"
"$ROOT_DIR/scripts/stage_app.sh" "$VERSION" "$BUILD_NUMBER" "$APP" native
"$ROOT_DIR/scripts/sign_app.sh" "$APP" -
"$ROOT_DIR/scripts/verify_staged_app.sh" "$APP" native signed

cat <<NEXT

dev_run: staged and ad-hoc signed
  $APP

This bundle does not open, and that is a property of the signature rather than
a fault in the build. It embeds the updater framework, and under the hardened
runtime macOS validates every library a process loads against the process's own
team. An ad-hoc signature has no team, so the framework is refused and the app
exits before it draws anything.

What this bundle is for is the layout, the inventory and the signing structure,
which scripts/verify_staged_app.sh has just checked. To open a dev build:

  Apps/Fermix/script/build_and_run.sh   one stable self-signed identity, so the
                                        microphone grant survives a rebuild
  scripts/dev_e2e.sh up                 the Developer ID loop, with the engine
                                        and the background agent

Engine prerequisites, from the fermix checkout's docs/DEVELOPMENT.md. This
bundle's engine slot is empty until Stage 0, so every surface it draws comes
from a daemon you start yourself:

  1. Build the packaged app engine, in the fermix checkout:

       touch apps/fermix_core/lib/fermix_core/build_info.ex
       FERMIX_BUILD_ID=local-test \\
       FERMIX_BUILD_SOURCE_COMMIT=0000000000000000000000000000000000000000 \\
       FERMIX_BUILD_DISTRIBUTION=macos_app \\
       FERMIX_BUILD_TARGET=macos_aarch64 \\
       MIX_ENV=prod mix release fermix_app_engine --overwrite

     Afterwards, touch build_info.ex again so the next dev compile reverts to
     the standalone identity literals.

  2. Run it against a disposable home on a spare port, never ~/.fermix:

       FERMIX_HOME=\$HOME/.fermix-apptest PORT=4530 \\
         _build/prod/rel/fermix_app_engine/bin/fermix_app_engine daemon
       curl http://127.0.0.1:4530/health/live

  3. Point this app at that home by writing the bootstrap record. The GUI and
     the agent read no FERMIX_HOME, so this file is the only way:

       $BOOTSTRAP_RECORD
       {"schema_version": 1, "fermix_home": "\$HOME/.fermix-apptest"}

  4. Stop the daemon when you are done:

       _build/prod/rel/fermix_app_engine/bin/fermix_app_engine stop

Nothing here registered a login item. The app's own Activate flow is what
registers the GUI ($BUNDLE_ID) and the background service
($AGENT_LABEL), each independently.
NEXT
