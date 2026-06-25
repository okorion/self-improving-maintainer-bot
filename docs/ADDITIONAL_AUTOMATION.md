# Additional Automation

This template now includes these maintainer-support workflows.

Workflows that open pull requests require the `BOT_GITHUB_TOKEN` repository secret. This is separate from `OPENAI_API_KEY`: the OpenAI key is for model calls, while `BOT_GITHUB_TOKEN` is for GitHub PR creation. Without it, PR-generating workflows leave a notice and skip PR creation so they do not create blocked `github-actions[bot]` PRs.

## PR Summary

Workflow:

```text
.github/workflows/pr-summary.yml
```

Purpose:

- Runs on pull requests.
- Writes a concise summary of changed files.
- Creates or updates one bot comment on the PR.
- Uses a static summary by default, so it does not need `OPENAI_API_KEY`.

Local command:

```bash
python -m self_maintainer_bot.cli summarize-pr \
  --base-ref origin/main \
  --head-ref HEAD \
  --output runs/pr-summary.md
```

## Docs Patch Candidate

Workflow:

```text
.github/workflows/docs-patch-candidate.yml
```

Purpose:

- Runs documentation evals.
- Reads failed eval cases.
- Appends a `Candidate Additions From Failed Evals` section to `docs/knowledge.md`.
- Opens a PR for human review.
- Requires `BOT_GITHUB_TOKEN` to open the PR.

This is intentionally conservative. Treat generated text as a draft, not as final documentation.

Local command:

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run --fail-under 0
python -m self_maintainer_bot.cli propose-docs-patch
```

## Status Dashboard

Workflow:

```text
.github/workflows/status-dashboard.yml
```

Purpose:

- Runs weekly or manually.
- Refreshes `docs/PROJECT_STATUS.md`.
- Shows eval count, latest eval result, and configured workflows.
- Requires `BOT_GITHUB_TOKEN` to open the PR.

Local command:

```bash
python -m self_maintainer_bot.cli update-status
```

## Recommended Activation Order

1. Run `Sync Labels`.
2. Confirm `Issue Triage` works with a test issue.
3. Confirm `Eval From Issue` creates an eval PR.
4. Enable `PR Summary` by opening or updating a PR.
5. Run `Docs Patch Candidate` only after there is a failing eval.
6. Run `Status Dashboard` manually once, then keep the weekly schedule.
