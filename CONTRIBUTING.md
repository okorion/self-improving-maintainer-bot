# Contributing

Thanks for helping improve this project.

## Preferred Contribution Flow

1. Open an issue first for behavior changes.
2. Add or update eval coverage for bot behavior changes.
3. Keep pull requests small.
4. Run local checks before opening a PR.

```bash
python -m maintainer_bot.cli smoke-check
python -m maintainer_bot.cli validate-evals
```

## Eval-first Changes

When the bot gives a bad answer, prefer this flow:

1. Open an `Eval failure` issue.
2. Let the `Eval From Issue` workflow create an eval PR.
3. Review and merge the eval PR.
4. Improve docs, prompts, or code in a follow-up PR.

This keeps the project from improving by weakening or skipping failures.

## Generated Changes

Generated proposals and documentation patch candidates must be reviewed by a human before merge.

Do not merge generated text blindly.

## Security

Do not post sensitive security details in public issues. See `SECURITY.md`.
