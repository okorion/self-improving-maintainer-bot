# Self-Improvement Policy

The bot is allowed to:

- Read repository files.
- Run documentation evals.
- Write reports under `runs/`.
- Write proposal files under `proposals/`.
- Open pull requests from generated changes.

The bot is not allowed to:

- Push directly to `main`.
- Delete eval cases without human review.
- Weaken eval assertions without human review.
- Use repository secrets in workflows triggered by untrusted fork code.
- Execute untrusted pull request code with elevated permissions.

Allowed automatic write paths:

- `runs/**`
- `proposals/**`

Human-reviewed write paths:

- `docs/**`
- `prompts/**`
- `evals/**`
- `src/**`
- `.github/workflows/**`
