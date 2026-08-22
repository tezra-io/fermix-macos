#!/usr/bin/env bash
#
# Render the one LaunchAgents property list from Product.json.
#
# `SMAppService.agent(plistName:)` reads this file out of the staged bundle at
# Contents/Library/LaunchAgents/<agent_service_label>.plist, so the label, the
# program, and the associated bundle identifier all have to agree with the
# bundle around it. Every value comes from the product configuration; nothing is
# restated here.
#
# BundleProgram is relative to the app bundle on purpose: an absolute path would
# break the moment the app moved or was replaced by an update, and launchd
# resolves the relative form against the registering bundle.
#
# KeepAlive is unconditional because the two lifecycle transactions depend on
# it: `restart daemon` commits a shutdown and waits for launchd to bring a
# different pid back, while `disable background service` unregisters the job
# *before* committing the shutdown, so nothing is left to relaunch.
#
# Usage: render_launch_agent_plist.sh <out_plist_path>
set -euo pipefail

OUT="${1:?usage: render_launch_agent_plist.sh <out_plist_path>}"

# shellcheck source=scripts/product_config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/product_config.sh"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

LABEL="$(xml_escape "$(product_config agent_service_label)")"
BUNDLE_ID="$(xml_escape "$(product_config bundle_identifier)")"
AGENT_EXECUTABLE="$(xml_escape "$(product_config agent_executable_name)")"

cat >"$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AssociatedBundleIdentifiers</key>
  <array>
    <string>$BUNDLE_ID</string>
  </array>
  <key>BundleProgram</key><string>Contents/MacOS/$AGENT_EXECUTABLE</string>
  <key>KeepAlive</key><true/>
  <key>Label</key><string>$LABEL</string>
  <key>ProcessType</key><string>Adaptive</string>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

plutil -lint "$OUT" >/dev/null
