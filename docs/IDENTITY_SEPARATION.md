## Codex Red-Team Mode

별도 GitHub reviewer 계정을 쓰지 않는 자동 루프에서는 GitHub approval 대신 `codex-redteam` required status check를 사용한다.

- worker: patch artifact 생성
- publisher: branch push, PR 생성, status/comment/reaction 게시, auto-merge 요청
- Codex red-team: read-only sandbox에서 PR diff를 검토하고 PASS/FAIL report 생성

이 모드는 GitHub의 독립 승인 identity를 제공하지 않는다. 대신 `check`와 `codex-redteam`을 required status check로 두고, red-team FAIL 또는 누락 시 merge를 차단한다.

red-team report는 PR comment로 게시되며, publisher는 각 report comment에 처리 흔적을 남긴다. PASS는 확인 comment와 `+1` reaction을 남기고, FAIL은 `eyes` reaction으로 접수한 뒤 보정 커밋을 push하면 처리 comment와 `+1` reaction을 남긴다.

# Identity Separation

중앙 maintainer bot은 최소 세 identity를 분리하는 운영을 목표로 한다.

## 권장 identity

| Identity | 권한 | 사용 위치 |
| -------- | ---- | --------- |
| read/analyze | repository read only | repo clone, issue/PR/CI read |
| worker | local filesystem write only, GitHub write token 없음 | Codex 실행, patch artifact 생성 |
| publisher | bot branch push, PR create/update, optional merge | PR 게시 단계 |

package/template release identity는 이 봇과 분리해야 하며, registry publish 권한을 target repo publisher와 공유하지 않는다.

## 환경 변수

```text
ANALYZE_GITHUB_TOKEN      # read/analyze용. 현재 profile runner는 선택 값이다.
PUBLISH_GITHUB_TOKEN      # publisher 우선 token
BOT_GITHUB_TOKEN          # publisher fallback token
```

`auto-improve-target-once.ps1`는 publish phase에서만 `PUBLISH_GITHUB_TOKEN` 또는 `BOT_GITHUB_TOKEN`을 `GH_TOKEN`으로 설정한다. worker phase에서는 process 환경의 publisher token과 `GH_TOKEN`을 지운 상태로 Codex를 실행하고, PR 생성, branch push, merge를 실행하지 않는다.

Publisher token이 없으면 publish phase는 기본적으로 실패한다. 로컬 수동 실험에서만 `-AllowLocalPublisherAuth`를 명시해 기존 `gh auth` fallback을 허용한다.

## 실행 예시

Worker only:

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -Phase worker
```

Publisher only:

```powershell
$env:PUBLISH_GITHUB_TOKEN = "<fine-grained-token-or-app-token>"
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -Phase publisher -PatchArtifact runs\scheduler\20260626-000000.patch
```

End-to-end:

```powershell
$env:PUBLISH_GITHUB_TOKEN = "<fine-grained-token-or-app-token>"
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab
```

로컬 PC에 저장된 `gh auth` 토큰은 완전한 보안 경계가 아니다. 자동 운영에서는 `-AllowLocalPublisherAuth`를 쓰지 않고, worker는 별도 OS 계정 또는 ephemeral runner에서 실행하고, publisher만 GitHub write token을 갖는 구성을 권장한다.
