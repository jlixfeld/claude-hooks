# claude-hooks

Reusable Claude Code hooks — harness-invoked scripts that run automatically during sessions.

## Setup

```bash
git clone https://github.com/jlixfeld/claude-hooks.git ~/.claude/hooks
```

Configure hooks in `~/.claude/settings.json`. See each hook's README for its specific settings entry.

## Hooks

| Hook | Trigger | Purpose |
|------|---------|---------|
| [pre-pr-test-gate](pre-pr-test-gate/) | `PreToolUse` on `gh pr create` | Blocks PR creation unless all detected tests pass |
