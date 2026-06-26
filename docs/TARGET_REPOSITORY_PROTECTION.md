# Target Repository Protection

중앙 maintainer bot 대상 저장소는 bot 정책만으로 보호하지 않고 GitHub repository 보호 설정도 함께 둔다.

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

## Required GitHub Protection

`main` branch에는 다음 기준을 적용한다.

- required status check: `check`
- strict status check: enabled
- code owner review: required
- stale approval dismissal: enabled
- last push approval: required
- conversation resolution: required
- linear history: required
- force push/delete: disabled
- merge queue: enabled when the repository plan supports it

## Apply Or Verify

먼저 전체 profile 대상에 dry-run을 돌린다.

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue -DryRun
```

현재 적용 상태만 읽으려면 다음을 실행한다.

```powershell
.\scripts\apply-target-protection.ps1 -Mode verify -IncludeMergeQueue
```

GitHub plan/visibility 조건이 충족된 뒤 실제 적용하려면 다음을 실행한다.

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue
```

단일 repo 또는 profile만 대상으로 삼을 수도 있다.

```powershell
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -Profile no-js-visual-lab -IncludeMergeQueue
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -Repository overtura/no-js-visual-lab -IncludeMergeQueue
```

## Current Limitation

2026-06-26 기준 overtura의 여섯 target repo는 private repo이고, GitHub API가 branch protection과 repository rulesets에 대해 다음 403을 반환한다.

```text
Upgrade to GitHub Pro or make this repository public to enable this feature.
```

따라서 현재 적용된 것은 repository 파일 기반 보호 장치인 `.github/CODEOWNERS`와 `merge_group` CI trigger까지다. GitHub-side branch protection, stale approval dismissal, merge queue는 repo를 public으로 바꾸거나 GitHub Pro/Team 이상 권한이 생긴 뒤 `scripts/apply-target-protection.ps1`로 다시 적용한다.

## Reapply Checklist

1. repo visibility 또는 plan 조건을 충족한다.
2. `.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue`를 실행한다.
3. 실패한 repo가 있으면 출력된 GitHub API 메시지를 기준으로 visibility, plan, token scope를 보정한다.
4. `gh api repos/overtura/<repo>/branches/main/protection`으로 설정을 읽어 검증한다.
5. `gh api repos/overtura/<repo>/rulesets`으로 ruleset/merge queue 설정을 읽어 검증한다.
