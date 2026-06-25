# Local Codex Policy

This policy applies only when a maintainer runs the local Codex loop on their own machine.

## Default Boundaries

- Keep the OpenAI API based GitHub automation path working.
- Use local Codex only as an optional human-approved backend.
- Do not read, print, commit, or upload secrets from `.env`, shell history, browser profiles, or Codex auth files.
- Do not commit, push, create pull requests, or change repository settings unless the maintainer explicitly asks.
- Preserve unrelated working tree changes.
- Prefer docs, prompts, and eval updates before code changes.

## Allowed Local Artifacts

Local run artifacts may be written under:

- `runs/codex-tasks/`
- `runs/codex-logs/`
- `runs/codex-last-message.md`

These paths are ignored by git.

## Required Verification

After local Codex makes a change, run:

```bash
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli validate-evals
```

Use API eval only when the maintainer intentionally wants to spend API quota:

```bash
python -m self_maintainer_bot.cli eval-docs
```
