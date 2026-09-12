#!/usr/bin/env bash
#
# Static gate on the microphone policy.
#
# These are the rules the voice stack was fixed to obey, expressed against the
# file that now owns the capture lifecycle: `AudioOwner`, formerly the audio
# half of `CompanionState`. They are static on purpose — each one failed in
# production once, and each is a property of the call flow's *shape* rather than
# of any single call's result.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER_FILE="$ROOT_DIR/Sources/FermixAppCore/Voice/AudioOwner.swift"
COORDINATOR_FILE="$ROOT_DIR/Sources/FermixAppCore/Voice/VoiceCoordinator.swift"

fail() {
  echo "runtime_policy_test: $*" >&2
  exit 1
}

for file in "$OWNER_FILE" "$COORDINATOR_FILE"; do
  [ -f "$file" ] || fail "expected $file to exist"
done

# The connect path must not warm capture: the microphone is engaged only inside
# a call the user started, after the permission gate.
if rg -n "prepareCapture\(" "$COORDINATOR_FILE" >/dev/null; then
  fail "the session path must not prepare microphone capture"
fi

# Capture is warmed exactly once, from beginCall.
prepare_count="$(rg -c "engine\.prepareCapture\(\)" "$OWNER_FILE" || true)"
if [ "${prepare_count:-0}" != "1" ]; then
  fail "prepareCapture must be referenced exactly once, from beginCall only"
fi

if ! awk '
  /public func beginCall\(\) async throws/ { in_begin_call = 1 }
  in_begin_call && /engine\.requestCapturePermission\(\)/ { permission = NR }
  in_begin_call && /engine\.prepareCapture\(\)/ { prepare = NR }
  in_begin_call && /^    public func / && !/func beginCall\(\)/ { in_begin_call = 0 }
  END { exit(permission > 0 && prepare > permission ? 0 : 1) }
' "$OWNER_FILE"; then
  fail "capture must be warmed inside beginCall, only after the permission gate"
fi

# Ending a call tears the engine all the way down, so macOS drops the microphone
# indicator instead of leaving the input unit alive.
if ! awk '
  /public func endCall\(\)/ { in_end_call = 1 }
  in_end_call && /engine\.shutdown\(\)/ { found = 1 }
  in_end_call && /^    public func / && !/func endCall\(\)/ { in_end_call = 0 }
  END { exit(found ? 0 : 1) }
' "$OWNER_FILE"; then
  fail "endCall must fully shut down audio"
fi

if rg -n "engine\.stopCapture\(\)" "$OWNER_FILE" >/dev/null; then
  fail "AudioOwner must use the full engine.shutdown() for teardown"
fi

# Every failure path through the call flow ends the call rather than leaving a
# warmed microphone attached to a call that never started: permission, warm-up,
# and the streaming handover.
failure_paths="$(rg -c "endCall\(\)" "$OWNER_FILE" || true)"
if [ "${failure_paths:-0}" -lt 3 ]; then
  fail "every capture failure path must end the call"
fi

echo "runtime_policy_test: ok"
