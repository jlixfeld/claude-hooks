#!/usr/bin/env bash
# Pre-PR test gate — blocks `gh pr create` unless all tests pass.
# Called by Claude Code PreToolUse hook on Bash commands.
#
# Auto-detects project type from the git root and runs appropriate tests.
# Outputs hook JSON to allow or block the command.
#
# Optional per-project config: .claude/test-gate.json
#   { "xcuitests": true, "skip": ["Target Name"], "extra": ["make lint"] }

set -uo pipefail

# --- Parse hook input ---

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null || echo "")

# Only gate `gh pr create` commands
if [[ "$COMMAND" != *"gh pr create"* ]]; then
  exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
FAILURES=""
PASSED=""

# --- Load optional config ---

CONFIG_FILE="$ROOT/.claude/test-gate.json"
XCUITESTS=false
SKIP_JSON="[]"
EXTRA_JSON="[]"

if [[ -f "$CONFIG_FILE" ]]; then
  XCUITESTS=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(str(c.get('xcuitests', False)).lower())" 2>/dev/null || echo "false")
  SKIP_JSON=$(python3 -c "import json; print(json.dumps(json.load(open('$CONFIG_FILE')).get('skip', [])))" 2>/dev/null || echo "[]")
  EXTRA_JSON=$(python3 -c "import json; print(json.dumps(json.load(open('$CONFIG_FILE')).get('extra', [])))" 2>/dev/null || echo "[]")
fi

# Helper: check if a target name is in the skip list
is_skipped() {
  local target="$1"
  python3 -c "import json,sys; sys.exit(0 if '$target' in json.loads('$SKIP_JSON') else 1)" 2>/dev/null
}

# --- Xcode projects ---

# Find .xcodeproj at root or one level deep
XCODE_PROJECTS=$(find "$ROOT" -maxdepth 2 -name "*.xcodeproj" -not -path "*/.*" 2>/dev/null)

for PROJ in $XCODE_PROJECTS; do
  PROJ_DIR=$(dirname "$PROJ")
  PROJ_NAME=$(basename "$PROJ")
  cd "$PROJ_DIR" || continue

  # Discover schemes
  SCHEMES=$(xcodebuild -list -project "$PROJ_NAME" 2>/dev/null | sed -n '/Schemes:/,/^$/p' | grep -v "Schemes:" | sed 's/^[[:space:]]*//' | grep -v '^$')

  for SCHEME in $SCHEMES; do
    # Only process app schemes that have test targets, or test-only schemes
    if [[ "$SCHEME" != *"Tests"* && "$SCHEME" != *"Test"* ]]; then
      # This is an app scheme — check if it has test targets by trying -showTestPlans
      HAS_TESTS=$(xcodebuild -showTestPlans -scheme "$SCHEME" -project "$PROJ_NAME" 2>&1 | grep -c "Test plans" || true)
      if [[ "$HAS_TESTS" -eq 0 ]]; then
        continue
      fi
    fi

    # Skip XCUITest targets unless opted in
    if [[ "$SCHEME" == *"UI Tests"* || "$SCHEME" == *"UITests"* ]]; then
      if [[ "$XCUITESTS" != "true" ]]; then
        continue
      fi
    fi

    # Check skip list
    if is_skipped "$SCHEME"; then
      continue
    fi

    # Determine platform from build settings
    PLATFORMS=$(xcodebuild -showBuildSettings -scheme "$SCHEME" -project "$PROJ_NAME" 2>/dev/null \
      | grep "SUPPORTED_PLATFORMS" | head -1 | awk '{print $3}')

    DESTINATION=""
    if [[ "$PLATFORMS" == *"macos"* ]]; then
      DESTINATION="platform=macOS"
    elif [[ "$PLATFORMS" == *"iphone"* ]]; then
      # Pick first available iPhone simulator
      SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d.get('name', ''):
            print(d['udid'])
            sys.exit(0)
" 2>/dev/null || echo "")
      if [[ -z "$SIM_ID" ]]; then
        FAILURES="${FAILURES}Could not find iOS simulator for $SCHEME. "
        continue
      fi
      DESTINATION="platform=iOS Simulator,id=$SIM_ID"
    else
      # Unknown platform, try macOS as fallback
      DESTINATION="platform=macOS"
    fi

    # Determine which test bundle to run
    # For app schemes (e.g. "Seneca macOS"), restrict to unit tests only
    ONLY_TESTING=""
    if [[ "$SCHEME" != *"Tests"* && "$SCHEME" != *"Test"* ]]; then
      # App scheme — find the unit test target name (not UI tests)
      UNIT_TARGET=$(xcodebuild -list -project "$PROJ_NAME" 2>/dev/null \
        | sed -n '/Targets:/,/^$/p' | grep -i "test" | grep -vi "ui test" \
        | sed 's/^[[:space:]]*//' | head -1)
      if [[ -n "$UNIT_TARGET" ]]; then
        ONLY_TESTING="-only-testing:$UNIT_TARGET"
      fi
    fi

    # Run tests
    RESULT=$(xcodebuild test \
      -project "$PROJ_NAME" \
      -scheme "$SCHEME" \
      -destination "$DESTINATION" \
      $ONLY_TESTING \
      2>&1 | grep "Executed" | tail -1)

    LABEL="$SCHEME tests ($PROJ_NAME)"
    if echo "$RESULT" | grep -q "with 0 failures"; then
      PASSED="${PASSED}${LABEL} passed. "
    else
      FAILURES="${FAILURES}${LABEL} failed. "
    fi
  done

  cd "$ROOT" || true
done

# --- Python projects ---

if [[ -f "$ROOT/pyproject.toml" ]]; then
  cd "$ROOT"
  RESULT=$(uv run pytest --tb=short -q 2>&1 | tail -5)
  if echo "$RESULT" | grep -qE "passed|no tests ran" && ! echo "$RESULT" | grep -q "failed"; then
    PASSED="${PASSED}pytest passed. "
  else
    FAILURES="${FAILURES}pytest failed. "
  fi
fi

# --- Extra commands from config ---

EXTRA_COUNT=$(echo "$EXTRA_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
for i in $(seq 0 $((EXTRA_COUNT - 1))); do
  CMD=$(echo "$EXTRA_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i])" 2>/dev/null || echo "")
  if [[ -n "$CMD" ]]; then
    cd "$ROOT"
    if eval "$CMD" >/dev/null 2>&1; then
      PASSED="${PASSED}$CMD passed. "
    else
      FAILURES="${FAILURES}$CMD failed. "
    fi
  fi
done

# --- Output hook JSON ---

if [[ -z "$FAILURES" && -z "$PASSED" ]]; then
  # No tests detected — allow
  exit 0
fi

if [[ -n "$FAILURES" ]]; then
  cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PR blocked — ${FAILURES}${PASSED}"}}
ENDJSON
else
  cat <<ENDJSON
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"All tests passed: ${PASSED}"}}
ENDJSON
fi
