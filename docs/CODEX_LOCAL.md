# Local Codex App Loop

이 문서는 OpenAI API 기반 자동화는 유지하면서, 내 PC의 Codex 앱 로그인 상태를 활용해 로컬 자가 개선 루프를 돌리는 방법입니다.

## 역할 분리

- GitHub Actions: 공개 레포에서 재현 가능한 기본 자동화입니다. OpenAI API key를 사용할 수 있습니다.
- Local Codex: 내 PC에서만 실행하는 선택적 개선 실행기입니다. Codex 앱/CLI의 `Logged in using ChatGPT` 상태를 사용합니다.

GitHub Actions는 로컬 Codex 앱에 접근할 수 없습니다. 그래서 이 기능은 원격 자동 실행이 아니라, 로컬 작업 큐와 실행기입니다.

## 빠른 확인

```powershell
python -m self_maintainer_bot.cli codex-status
```

정상 예:

```text
PASS codex-cli: ...
PASS codex-login: Logged in using ChatGPT
```

로그인이 안 되어 있으면 Codex 앱 또는 CLI에서 먼저 로그인합니다.

```powershell
codex login
```

## 1. 작업 명세만 만들기

먼저 API 호출 없이 dry-run eval을 돌리고 Codex용 작업 명세만 만듭니다.

```powershell
python -m self_maintainer_bot.cli codex-local-loop
```

생성 위치:

```text
runs/codex-tasks/
```

이 단계는 Codex를 실행하지 않습니다.

## 2. Codex로 실행하기

생성된 task 파일을 확인한 뒤 실행합니다.

```powershell
python -m self_maintainer_bot.cli run-codex-task --task-file runs/codex-tasks/YOUR_TASK.md
```

또는 한 번에 eval, task 생성, Codex 실행까지 진행합니다.

```powershell
.\scripts\codex-local-loop.ps1 -Execute
```

기본 sandbox는 `workspace-write`입니다. 이 레포 안에서만 수정하게 두는 설정입니다.

## 3. API eval과 함께 실행하기

OpenAI API 기반 eval을 먼저 돌리고 그 결과를 Codex task에 넣으려면:

```powershell
.\scripts\codex-local-loop.ps1 -ApiEval -Execute
```

이 경우 `.env` 또는 환경 변수에 `OPENAI_API_KEY`가 필요합니다.

## 4. scope 선택

```powershell
.\scripts\codex-local-loop.ps1 -Scope docs -Execute
.\scripts\codex-local-loop.ps1 -Scope prompts -Execute
.\scripts\codex-local-loop.ps1 -Scope evals -Execute
.\scripts\codex-local-loop.ps1 -Scope code -Execute
.\scripts\codex-local-loop.ps1 -Scope mixed -Execute
```

권장 순서:

1. `docs`
2. `prompts`
3. `evals`
4. `code`
5. `mixed`

코드 수정은 eval과 문서/프롬프트 개선으로 해결되지 않을 때만 사용하세요.

## 5. 결과 확인

Codex 실행 후 wrapper가 자동으로 다음 검증을 수행합니다.

```powershell
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli validate-evals
```

로그 위치:

```text
runs/codex-logs/
runs/codex-last-message.md
```

이 파일들은 git에 올라가지 않습니다.

## 6. 안전 규칙

- Codex local loop는 commit, push, PR 생성을 하지 않습니다.
- 변경 후 사람이 diff를 확인합니다.
- 필요한 경우 사람이 직접 commit/push/PR을 진행합니다.
- `.env`, Codex auth 파일, 브라우저 프로필, shell history 같은 secret source는 읽거나 출력하지 않습니다.

자세한 정책은 `policies/codex_local_policy.md`를 따릅니다.
