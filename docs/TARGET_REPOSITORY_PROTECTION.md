# Target Repository Protection

중앙 maintainer bot 대상 저장소는 bot 정책과 GitHub repository 보호 설정을 함께 사용한다.

## Current State

2026-06-26 기준 overtura의 여섯 target repo는 public이며, GitHub-side branch protection, repository ruleset, merge queue가 적용되어 있다.

기본 보호 모드는 `redteam-status`다.

- required status checks: `check`, `codex-redteam`
- strict status check: enabled
- pull request rule: enabled by repository ruleset
- approving review/code owner review: disabled
- conversation resolution: required
- linear history: required
- force push/delete: disabled
- merge queue: enabled

## Required Files

각 target repo에는 `.github/CODEOWNERS`를 둔다.

```text
* @okorion

.github/workflows/** @okorion
CODEOWNERS @okorion
.github/CODEOWNERS @okorion
maintainer-bot/project.json @okorion
```

각 target repo의 CI workflow에는 `merge_group` trigger를 둔다. merge queue가 활성화되면 queue 안에서도 동일한 `check`가 실행되어야 한다.

## Apply Or Verify

전체 profile 대상 dry-run:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue -DryRun
```

현재 적용 상태 검증:

```powershell
.\scripts\apply-target-protection.ps1 -Mode verify -IncludeMergeQueue
```

기본 red-team status mode 적용:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue
```

단일 repo 또는 profile 적용:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -Profile no-js-visual-lab -IncludeMergeQueue
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -Repository overtura/no-js-visual-lab -IncludeMergeQueue
```

별도 reviewer identity를 쓰는 GitHub approval mode 복원:

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue -ReviewMode github-review -RequiredStatusChecks check
```

## Reapply Checklist

1. `.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue`를 실행한다.
2. `.\scripts\apply-target-protection.ps1 -Mode verify -IncludeMergeQueue`를 실행한다.
3. `gh api repos/overtura/<repo>/branches/main/protection`으로 required checks와 review 설정을 확인한다.
4. `gh api repos/overtura/<repo>/rulesets`으로 ruleset/merge queue 설정을 확인한다.
