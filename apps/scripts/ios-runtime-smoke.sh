#!/usr/bin/env bash
# Runs the iOS app on a simulator against a local fixture server and drives it with
# XCUITest: library and search, details, a rendered EPUB, downloads through the system
# background session, a local audiobook, and reopening everything offline.
#
# Needs macOS, Xcode 16.4+, XcodeGen and python3. Picks the newest available iPhone
# simulator unless IOS_SIMULATOR_UDID is set. Extra arguments go to xcodebuild, e.g.
#   apps/scripts/ios-runtime-smoke.sh -only-testing:ShelfarrUITests/RuntimeSmokeTests
#
# Results: apps/ios/build/runtime-smoke/ (RuntimeSmoke.xcresult, screenshots in
# attachments/, xcodebuild, fixture server and app logs) and a summary in
# apps/ios/test-results/runtime-smoke-summary.json. Fails unless at least one test ran
# and every test passed.
set -euo pipefail
cd "$(dirname "$0")/../ios"

out=build/runtime-smoke
results=test-results
rm -rf "$out"
mkdir -p "$out" "$results"
port="${SHELFARR_SMOKE_PORT:-8765}"
control_port="${SHELFARR_SMOKE_CONTROL_PORT:-8766}"

xcodegen generate

udid="${IOS_SIMULATOR_UDID:-}"
if [ -z "$udid" ]; then
  udid="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
runtimes = json.load(sys.stdin)["devices"]
def version(key):
    found = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", key)
    return tuple(int(part or 0) for part in found.groups()) if found else None
best = None
for key, devices in runtimes.items():
    v = version(key)
    if v is None:
        continue
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            rank = (v, device.get("state") == "Booted", "SE" not in device["name"])
            if best is None or rank > best[0]:
                best = (rank, device["udid"], device["name"], key)
if best is None:
    sys.exit("No available iPhone simulator")
print(best[1])
print(f"Using {best[2]} ({best[3]})", file=sys.stderr)
')"
fi
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b

python3 -B RuntimeSmoke/smoke_server.py --port "$port" --control-port "$control_port" > "$out/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$control_port/stats" > /dev/null 2>&1 && break
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$control_port/stats" > /dev/null

status=0
TEST_RUNNER_SHELFARR_SMOKE_PORT="$port" \
TEST_RUNNER_SHELFARR_SMOKE_CONTROL_PORT="$control_port" \
xcodebuild test \
  -project Shelfarr.xcodeproj \
  -scheme ShelfarrRuntimeSmoke \
  -configuration Debug \
  -destination "id=$udid" \
  -derivedDataPath build \
  -resultBundlePath "$out/RuntimeSmoke.xcresult" \
  CODE_SIGNING_ALLOWED="${SHELFARR_SMOKE_CODE_SIGNING_ALLOWED:-NO}" \
  "$@" 2>&1 | tee "$out/xcodebuild.log" || status=$?

# Diagnostics are kept whether or not the tests passed.
curl -fsS "http://127.0.0.1:$control_port/stats" > "$out/server-stats.json" 2>/dev/null || true
xcrun simctl spawn "$udid" log show --style compact --last 20m \
  --predicate 'process == "Shelfarr" OR process == "nsurlsessiond"' > "$out/device.log" 2>/dev/null || true
if [ -d "$out/RuntimeSmoke.xcresult" ]; then
  xcrun xcresulttool export attachments --path "$out/RuntimeSmoke.xcresult" --output-path "$out/attachments" \
    || echo "warning: could not export screenshots from the result bundle"
  xcrun xcresulttool get test-results summary --path "$out/RuntimeSmoke.xcresult" > "$results/runtime-smoke-summary.json" \
    || echo "warning: could not summarise the result bundle"
fi

if [ "$status" -eq 0 ]; then
  # A green build with no executed test is a failure, not a pass.
  python3 - "$results/runtime-smoke-summary.json" <<'PY' || status=1
import json, sys
try:
    summary = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit("No readable test summary")
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
print(f"Runtime smoke: {passed} passed, {failed} failed, result {summary.get('result')}")
if summary.get("result") != "Passed" or passed == 0 or failed:
    sys.exit(1)
PY
fi
exit "$status"
