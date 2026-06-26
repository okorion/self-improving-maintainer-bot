# Codex Red-Team Gate

별도 reviewer 계정 없이 자동 루프를 돌릴 때는 GitHub approval 대신 `codex-redteam` required status check를 merge gate로 사용한다.

## Flow

```text
worker generates patch
publisher pushes branch
publisher creates PR with a title/body based on the actual changed files
publisher sets codex-redteam=pending on the current head
Codex CLI reviews the PR diff in read-only mode
publisher comments the red-team report
publisher marks the red-team comment as handled with a reaction/comment
if review fails, Codex responds with a scoped fix commit
publisher pushes the response commit
publisher comments how the review was handled
Codex CLI re-reviews the updated PR
if the response limit is reached, publisher closes the PR
batch runner starts a replacement improvement candidate
publisher sets codex-redteam=success or failure on the current head
CI check + codex-redteam pass
auto merge
runner waits until PR state is MERGED
```

## Policy

- Codex red-team review runs with `--sandbox read-only`.
- Publisher token environment variables are cleared while Codex red-team review runs.
- The review must end with `REDTEAM_DECISION: PASS` or `REDTEAM_DECISION: FAIL`.
- Missing or malformed decision is treated as `FAIL`.
- A failed red-team review can be handled by a bounded review-response loop.
- Review response runs with `--sandbox workspace-write --full-auto`, but publisher token environment variables are still cleared.
- Review response must stay within target `allowPaths` and is reclassified before it can be committed.
- Every red-team report comment gets a handling trace: PASS gets a short handled comment and `+1`; FAIL gets `eyes`, then a response-handled comment and `+1` after the fix commit is pushed.
- If the bounded review-response loop still fails, the PR is closed and does not count as a completed iteration.
- The batch runner retries the same iteration with a fresh improvement candidate up to `MaxClosedPrReplacements`.
- R3/proposal-only changes must not reach PR publish.
- R2 draft PRs can receive a red-team report, but auto-merge remains disabled.
- R1 PRs can auto-merge only after `check` and `codex-redteam` are both green.
- Auto-merge mode waits for the PR to reach `MERGED` before the next loop starts.
- PR title and body must describe the actual diff, not merely that the PR was created by the self-improvement loop.

## Branch Protection Mode

Use red-team status mode:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify
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

Run three serial loops for every overtura target profile:

```powershell
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -AllowLocalPublisherAuth
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -ParallelProfiles -AutoMerge -AllowLocalPublisherAuth
```

Dry-run the same batch before running it:

```powershell
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -AllowLocalPublisherAuth -DryRun
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -ParallelProfiles -AutoMerge -AllowLocalPublisherAuth -DryRun
```

Tune review response and merge waiting:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -AutoMerge -MaxReviewResponses 6 -MergeWaitTimeoutSeconds 900 -MergePollSeconds 15
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -MaxReviewResponses 6 -MaxClosedPrReplacements 3
```

Skip red-team only for emergency diagnostics:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -SkipRedteam
```
