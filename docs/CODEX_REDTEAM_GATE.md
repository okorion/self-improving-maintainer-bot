# Codex Red-Team Gate

별도 reviewer 계정 없이 자동 루프를 돌릴 때는 GitHub approval 대신 `codex-redteam` required status check를 merge gate로 사용한다.

## Flow

```text
worker generates patch
publisher pushes branch
publisher sets codex-redteam=pending
publisher creates PR
Codex CLI reviews the PR diff in read-only mode
publisher comments the red-team report
publisher sets codex-redteam=success or failure
CI check + codex-redteam pass
merge queue / auto merge
```

## Policy

- Codex red-team review runs with `--sandbox read-only`.
- Publisher token environment variables are cleared while Codex red-team review runs.
- The review must end with `REDTEAM_DECISION: PASS` or `REDTEAM_DECISION: FAIL`.
- Missing or malformed decision is treated as `FAIL`.
- R3/proposal-only changes must not reach PR publish.
- R2 draft PRs can receive a red-team report, but auto-merge remains disabled.
- R1 PRs can auto-merge only after `check` and `codex-redteam` are both green.

## Branch Protection Mode

Use red-team status mode:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue
```

This requires:

- `check`
- `codex-redteam`

It disables GitHub approving review requirements for the automated loop, while still requiring pull requests through the repository ruleset.

To restore GitHub approval based operation:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue -ReviewMode github-review -RequiredStatusChecks check
```

## Runner Options

Default red-team gate:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -AutoMerge
```

Local publisher auth experiment:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -AutoMerge -AllowLocalPublisherAuth
```

Skip red-team only for emergency diagnostics:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -SkipRedteam
```
