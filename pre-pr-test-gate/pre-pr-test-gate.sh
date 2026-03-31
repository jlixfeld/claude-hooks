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

# Cache simulator ID (looked up once, reused for all iOS targets)
IOS_SIM_ID=""

# Find .xcodeproj at root or one level deep (handle spaces in paths)
while IFS= read -r -d '' PROJ; do
  PROJ_DIR=$(dirname "$PROJ")
  PROJ_NAME=$(basename "$PROJ")
  cd "$PROJ_DIR" || continue

  # Discover test targets (not schemes — test targets live under app schemes)
  TARGETS=$(xcodebuild -list -project "$PROJ_NAME" 2>/dev/null \
    | sed -n '/Targets:/,/^$/p' | grep -v "Targets:" | sed 's/^[[:space:]]*//' | grep -v '^$')

  # Filter to test targets only
  TEST_TARGETS=$(echo "$TARGETS" | grep -i "test" || true)
  if [[ -z "$TEST_TARGETS" ]]; then
    continue
  fi

  # Discover available schemes
  SCHEMES=$(xcodebuild -list -project "$PROJ_NAME" 2>/dev/null \
    | sed -n '/Schemes:/,/^$/p' | grep -v "Schemes:" | sed 's/^[[:space:]]*//' | grep -v '^$')

  while IFS= read -r TARGET; do
    [[ -z "$TARGET" ]] && continue

    # Skip UI test targets unless opted in
    if [[ "$TARGET" == *"UI Tests"* || "$TARGET" == *"UITests"* ]]; then
      if [[ "$XCUITESTS" != "true" ]]; then
        continue
      fi
    fi

    # Check skip list
    if is_skipped "$TARGET"; then
      continue
    fi

    # Find the app scheme that can run this test target.
    # Convention: "Seneca macOS Tests" → scheme "Seneca macOS"
    #             "Seneca iOS UI Tests" → scheme "Seneca iOS"
    SCHEME=""
    # Strip common test suffixes to derive the app scheme name
    CANDIDATE=$(echo "$TARGET" | sed -E 's/ *(UI )?Tests$//')
    if echo "$SCHEMES" | grep -qx "$CANDIDATE"; then
      SCHEME="$CANDIDATE"
    else
      # Fallback: try each scheme and see if this target is buildable under it
      while IFS= read -r S; do
        [[ -z "$S" ]] && continue
        if xcodebuild -showBuildSettings -scheme "$S" -target "$TARGET" -project "$PROJ_NAME" >/dev/null 2>&1; then
          SCHEME="$S"
          break
        fi
      done <<< "$SCHEMES"
    fi

    if [[ -z "$SCHEME" ]]; then
      # Can't find a scheme for this test target — skip
      continue
    fi

    # Determine platform from the scheme's build settings
    PLATFORMS=$(xcodebuild -showBuildSettings -scheme "$SCHEME" -project "$PROJ_NAME" 2>/dev/null \
      | grep "SUPPORTED_PLATFORMS" | head -1 | awk '{print $3}')

    DESTINATION=""
    if [[ "$PLATFORMS" == *"macos"* ]]; then
      DESTINATION="platform=macOS"
    elif [[ "$PLATFORMS" == *"iphone"* ]]; then
      # Look up simulator once, cache for reuse
      if [[ -z "$IOS_SIM_ID" ]]; then
        IOS_SIM_ID=$(xcrun simctl list devices available -j 2>/dev/null \
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
      fi
      if [[ -z "$IOS_SIM_ID" ]]; then
        FAILURES="${FAILURES}Could not find iOS simulator for $TARGET. "
        continue
      fi
      DESTINATION="platform=iOS Simulator,id=$IOS_SIM_ID"
    else
      DESTINATION="platform=macOS"
    fi

    # Run tests for this specific test target under its app scheme
    LABEL="$TARGET ($PROJ_NAME)"
    echo "⏳ Running $LABEL ..." >&2
    RESULT=$(xcodebuild test \
      -project "$PROJ_NAME" \
      -scheme "$SCHEME" \
      -destination "$DESTINATION" \
      -only-testing:"$TARGET" \
      2>&1 | grep "Executed" | tail -1)

    if echo "$RESULT" | grep -q "with 0 failures"; then
      echo "✅ $LABEL passed" >&2
      PASSED="${PASSED}${LABEL} passed. "
    else
      echo "❌ $LABEL failed" >&2
      FAILURES="${FAILURES}${LABEL} failed. "
    fi
  done <<< "$TEST_TARGETS"

  cd "$ROOT" || true
done < <(find "$ROOT" -maxdepth 2 -name "*.xcodeproj" -not -path "*/.*" -print0 2>/dev/null)

# --- Python projects ---

if [[ -f "$ROOT/pyproject.toml" ]]; then
  cd "$ROOT"
  echo "⏳ Running pytest ..." >&2
  RESULT=$(uv run pytest --tb=short -q 2>&1 | tail -5)
  if echo "$RESULT" | grep -qE "passed|no tests ran" && ! echo "$RESULT" | grep -q "failed"; then
    echo "✅ pytest passed" >&2
    PASSED="${PASSED}pytest passed. "
  else
    echo "❌ pytest failed" >&2
    FAILURES="${FAILURES}pytest failed. "
  fi
fi

# --- Extra commands from config ---

EXTRA_COUNT=$(echo "$EXTRA_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
for i in $(seq 0 $((EXTRA_COUNT - 1))); do
  CMD=$(echo "$EXTRA_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[$i])" 2>/dev/null || echo "")
  if [[ -n "$CMD" ]]; then
    cd "$ROOT"
    echo "⏳ Running $CMD ..." >&2
    if eval "$CMD" >/dev/null 2>&1; then
      echo "✅ $CMD passed" >&2
      PASSED="${PASSED}$CMD passed. "
    else
      echo "❌ $CMD failed" >&2
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
