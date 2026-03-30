# pre-pr-test-gate

Blocks `gh pr create` unless all detected tests pass. Auto-detects Xcode projects (macOS/iOS) and Python projects from the git root.

## Settings

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "if": "Bash(gh pr create:*)",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/pre-pr-test-gate/pre-pr-test-gate.sh",
            "timeout": 600,
            "statusMessage": "Running test gate before PR creation..."
          }
        ]
      }
    ]
  }
}
```

## Detection

| Platform | Signal | Action |
|----------|--------|--------|
| Xcode | `*.xcodeproj` at root or one level deep | Discovers schemes, runs unit tests per platform |
| Python | `pyproject.toml` at root | `uv run pytest --tb=short -q` |

**Defaults:** Unit tests always run. XCUITests skipped unless opted in. No tests detected = allow.

## Per-Project Config (optional)

Place `.claude/test-gate.json` in the project root:

```json
{
  "xcuitests": true,
  "skip": ["Seneca iOS UI Tests"],
  "extra": ["make lint"]
}
```

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `xcuitests` | bool | `false` | Include XCUITest targets |
| `skip` | string[] | `[]` | Test target names to exclude |
| `extra` | string[] | `[]` | Additional commands to run as part of the gate |
