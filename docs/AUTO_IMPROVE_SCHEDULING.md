# 자동 자가 개선 스케줄링

이 문서는 target repo에 대해 1시간에 한 번, 24시간 동안 다음 흐름을 자동 실행하는
방법입니다.

```text
prepare-target
  -> eval-docs
  -> codex-local-loop --execute
  -> target 검증
  -> branch 생성
  -> 한국어 commit
  -> PR 생성
  -> CI 통과 확인
  -> merge
```

## 기본 전제

- target repo는 `.env`에 설정되어 있어야 합니다.
- `BOT_GITHUB_TOKEN` 또는 `gh auth`가 PR 생성과 merge 권한을 가져야 합니다.
- target worktree는 스케줄 시작 시 clean 상태여야 합니다.
- 기존 open PR이 있으면 먼저 merge 또는 close 여부를 결정해야 합니다.

현재 권장 기본값:

- interval: 1시간
- duration: 24시간
- scope: `docs`
- merge method: squash
- overlap policy: 이전 실행이 끝나지 않았으면 다음 실행은 건너뜀
- allowed publish paths: `README.md`, `CONTRIBUTING.md`, `docs/`

## 1회 실행 테스트

자동 merge 없이 1회 실행하려면:

```powershell
cd "E:\Project Archieve\self-improving-maintainer-bot"
.\scripts\auto-improve-target-once.ps1 -Scope docs
```

자동 merge까지 포함하려면:

```powershell
.\scripts\auto-improve-target-once.ps1 -Scope docs -AutoMerge
```

## 24시간 스케줄 등록

기본 등록은 10분 뒤 시작하고, 1시간마다 24시간 동안 실행합니다.

```powershell
cd "E:\Project Archieve\self-improving-maintainer-bot"
.\scripts\register-target-auto-improve-schedule.ps1 -AutoMerge
```

즉시 첫 실행도 시작하려면:

```powershell
.\scripts\register-target-auto-improve-schedule.ps1 -AutoMerge -StartNow
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
- scope: `docs`만 돌릴지, `code` 또는 `mixed`까지 허용할지
- 실패 처리: 한 회차 실패 후 다음 시간에 계속 시도할지, 작업 자체를 중지할지
- 변경 한도: 한 회차에서 허용할 파일 수나 라인 수 제한을 둘지
- 실행 환경: PC 절전 방지, Codex 로그인 유지, GitHub CLI 인증 유지

권장 시작값:

```text
기존 open PR: 먼저 merge 또는 close
AutoMerge: true
MergeMethod: squash
Scope: docs
Failure policy: 해당 회차만 실패, 다음 시간에 재시도
```
