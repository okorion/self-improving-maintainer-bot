# 자동 자가 개선 스케줄링

이 문서는 target repo에 대해 1시간에 한 번, 24시간 동안 다음 흐름을 자동 실행하는
방법입니다.

```text
prepare-target
  -> eval-docs
  -> codex-local-loop --execute
  -> target 검증
  -> R0/R1/R2/R3 risk classification
  -> branch 생성
  -> 한국어 commit
  -> 실제 변경사항 기반 PR 제목/본문 생성 또는 proposal-only 차단
  -> Codex red-team 리뷰
  -> 필요 시 review-response 커밋 후 재리뷰
  -> 대응 한도 초과 시 PR close 후 새 개선 후보 재시도
  -> CI 통과 확인
  -> merge queue / auto merge 요청
  -> PR이 MERGED 상태가 될 때까지 대기
```

## 기본 전제

- target repo는 `.env`에 설정되어 있어야 합니다.
- publish phase에는 `PUBLISH_GITHUB_TOKEN` 또는 `BOT_GITHUB_TOKEN`이 PR 생성과 merge 권한을 가져야 합니다. 없으면 기본적으로 publish가 실패하며, 로컬 실험에서만 `-AllowLocalPublisherAuth`로 기존 `gh auth` fallback을 허용합니다.
- target worktree는 스케줄 시작 시 clean 상태여야 합니다.
- 기존 open PR이 있으면 먼저 merge 또는 close 여부를 결정해야 합니다.

현재 권장 기본값:

- interval: 1시간
- duration: 24시간
- scope/kind: 자동 선택. 기본은 `docs`지만 docs 성공은 최대 3회 연속까지만 허용
- non-docs sequence: `feat -> style -> refactor`
- non-doc guard: `feat`, `style`, `refactor` 요청에서 docs-only 변경이 나오면 PR을 만들지 않고 같은 회차에서 새 후보를 재시도
- merge method: squash
- overlap policy: 이전 실행이 끝나지 않았으면 다음 실행은 건너뜀
- review response: red-team FAIL 시 최대 2회 자동 대응
- closed PR replacement: review-response 한도 초과로 닫힌 PR은 성공 회차로 세지 않고 같은 iteration에서 새 후보를 찾음
- merge wait: auto-merge 요청 후 실제 `MERGED` 상태까지 대기
- allowed publish paths: `README.md`, `CONTRIBUTING.md`, `docs/`
- R2 publish: draft PR only
- R3 publish: proposal only, no branch push or PR creation

## 1회 실행 테스트

자동 merge 없이 1회 실행하려면:

```powershell
cd "E:\Project Archieve\self-improving-maintainer-bot"
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Scope docs
```

자동 merge까지 포함하려면:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Scope docs -AutoMerge
```

특정 개선 유형을 직접 지정하려면:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Scope mixed -ImprovementKind feat -AutoMerge
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Scope mixed -ImprovementKind style -AutoMerge
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -Scope mixed -ImprovementKind refactor -AutoMerge
```

모든 overtura target profile을 3회씩 직렬 실행하려면:

```powershell
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -AllowLocalPublisherAuth
```

repo별 루프를 병렬로 실행하고, repo 내부 3회는 직렬로 유지하려면:

```powershell
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -ParallelProfiles -AutoMerge -AllowLocalPublisherAuth
```

## 24시간 스케줄 등록

기본 등록은 10분 뒤 시작하고, 1시간마다 24시간 동안 실행합니다.

```powershell
cd "E:\Project Archieve\self-improving-maintainer-bot"
.\scripts\register-target-auto-improve-schedule.ps1 -Profile living-shader-gallery -AutoMerge
```

즉시 첫 실행도 시작하려면:

```powershell
.\scripts\register-target-auto-improve-schedule.ps1 -Profile living-shader-gallery -AutoMerge -StartNow
```

등록된 작업 확인:

```powershell
Get-ScheduledTask -TaskName ActionLedgerAutoImprove24h
Get-ScheduledTaskInfo -TaskName ActionLedgerAutoImprove24h
```

중지 또는 삭제:

```powershell
Stop-ScheduledTask -TaskName ActionLedgerAutoImprove24h
Unregister-ScheduledTask -TaskName ActionLedgerAutoImprove24h -Confirm:$false
```

## 필요한 결정 사항

스케줄을 실제로 켜기 전에 아래를 결정합니다.

- 기존 open PR 처리: merge할지, 닫을지, 그대로 둘지
- 자동 merge 허용 여부: `-AutoMerge`를 켤지
- merge 방식: `squash`, `merge`, `rebase` 중 하나
- scope/kind: 기본 자동 선택을 쓸지, `-Scope`와 `-ImprovementKind`를 명시할지
- docs 연속 제한: 기본 `-MaxConsecutiveDocs 3`
- 실패 처리: 한 회차 실패 후 다음 시간에 계속 시도할지, 작업 자체를 중지할지
- 리뷰 대응 한도: `-MaxReviewResponses` 값을 몇 회로 둘지
- 실패 PR 교체 한도: `-MaxClosedPrReplacements` 값을 몇 회로 둘지
- merge 대기 시간: `-MergeWaitTimeoutSeconds` 값을 몇 초로 둘지
- 변경 한도: 한 회차에서 허용할 파일 수나 라인 수 제한을 둘지
- 실행 환경: PC 절전 방지, Codex 로그인 유지, GitHub CLI 인증 유지

권장 시작값:

```text
기존 open PR: 먼저 merge 또는 close
AutoMerge: true
MergeMethod: squash
Scope/kind: auto, docs max 3 then feat/style/refactor
Failure policy: 해당 회차만 실패, 다음 시간에 재시도
```
