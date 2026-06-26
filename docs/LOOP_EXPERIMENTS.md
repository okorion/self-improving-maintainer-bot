# Loop Experiments

각 target repo의 실제 루프 검증은 다음 순서로 진행한다.

## 1. R0 report loop

목표: target repo clone, eval, risk/report artifact 생성만 검증한다.

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Phase worker
```

성공 기준:

- patch artifact 또는 no-op 로그가 생성된다.
- risk report가 생성된다.
- PR, push, merge가 발생하지 않는다.

## 2. R1 PR no auto-merge

목표: README, docs, copy, 작은 UI/CSS 변경을 일반 PR로 게시하되 자동 병합하지 않는다.

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery
```

성공 기준:

- `max_risk=R1`
- `publish_mode=pull_request`
- PR body에 input commit, profile version, diff stat, risk report 경로가 기록된다.
- target repo CI가 통과한다.

## 3. R1 limited auto-merge

목표: R1만 제한적으로 자동 merge한다.

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -AutoMerge
```

성공 기준:

- R1이 아닌 변경은 자동 merge되지 않는다.
- required check가 통과한 뒤에만 merge된다.
- merge 후 branch가 삭제된다.

## 4. R2 draft PR

목표: dependency, build, validation surface 변경이 draft PR로만 생성되는지 확인한다.

성공 기준:

- `max_risk=R2`
- `publish_mode=draft_pull_request`
- PR은 draft 상태다.
- 자동 merge가 요청되어도 skip된다.

## 5. R3 proposal only

목표: workflow, CODEOWNERS, credential, auth/security, infra, migration 변경이 publish되지 않는지 확인한다.

성공 기준:

- `max_risk=R3`
- `publish_mode=proposal_only`
- branch push, PR create, merge가 발생하지 않는다.
- patch artifact와 risk report만 생성된다.

## 권장 반복 수

각 repo별로 최소 4-5회 반복하되, 첫 반복은 항상 R0 또는 R1 no auto-merge로 시작한다.
## Codex Red-Team Gate

별도 reviewer identity 없이 루프를 돌릴 때는 `codex-redteam` status check가 GitHub approval을 대신한다.

- R1 PR은 `check`와 `codex-redteam`이 모두 green일 때만 merge queue로 들어간다.
- red-team report는 PR comment와 로컬 `runs/scheduler/*-redteam-report.md`에 남는다.
- R2 draft PR은 red-team review를 받을 수 있지만 auto-merge하지 않는다.
- R3/proposal-only 변경은 PR publish 전에 차단되어야 한다.
