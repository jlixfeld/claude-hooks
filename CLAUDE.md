# Claude Code Instructions — Hooks Repo

## Hook Changes Require a PR

**Never commit hook changes directly to `main`.** All modifications — including edits to existing hooks, new hooks, and deletions — must go through a pull request.

**Workflow:**

1. Create a branch: `git checkout -b fix/short-description` or `feature/short-description`
2. Make your changes
3. Commit and push
4. Open a PR: `gh pr create --repo jlixfeld/claude-hooks`
5. Tell the user the PR URL and wait for approval before merging

Hooks run automatically during Claude Code sessions. Unreviewed changes take effect immediately on merge — treat this repo with the same discipline as application code.
