# Local Codex Only Setup

이 문서는 `OPENAI_API_KEY` 없이 로컬 Codex 앱 인증 상태만 사용해 대상 레포를 개선하는 운영 매뉴얼입니다.

## 1. 로컬 준비

```powershell
cd C:\path\to\self-improving-maintainer-bot
python -m pip install -e .
python -m self_maintainer_bot.cli codex-status
```

정상 출력:

```text
PASS codex-cli: ...
PASS codex-login: Logged in using ChatGPT
```

로그인이 안 되어 있으면:

```powershell
codex login
```

## 2. 대상 레포 설정

`.env`를 만듭니다.

```powershell
Copy-Item .env.example .env
```

`.env`에서 아래 값을 설정합니다.

```env
TARGET_REPOSITORY=okorion/your-target-repo
TARGET_DEFAULT_BRANCH=main
TARGET_WORKTREE=targets/active
TARGET_DOC_PATHS=README.md,docs
TARGET_EVALS_PATH=evals/docs_qa.jsonl
CODEX_TIMEOUT_SECONDS=3600
```

대상 레포가 private이면 먼저 로컬 git 인증이 되어 있어야 합니다.

```powershell
gh auth status
git ls-remote https://github.com/okorion/your-target-repo.git
```

## 3. 대상 레포 준비

```powershell
python -m self_maintainer_bot.cli prepare-target
python -m self_maintainer_bot.cli target-status
```

`prepare-target`는 `TARGET_REPOSITORY`를 `TARGET_WORKTREE`에 clone 또는 fast-forward update합니다.

## 4. 기본 검증

```powershell
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli validate-evals
```

`eval-docs`는 기본적으로 로컬 dry-run입니다. API key를 요구하지 않습니다.

```powershell
python -m self_maintainer_bot.cli eval-docs
```

## 5. 로컬 Codex 개선 루프

먼저 task 파일만 만듭니다.

```powershell
python -m self_maintainer_bot.cli codex-local-loop --scope docs
```

task 파일을 확인한 뒤 실행합니다.

```powershell
.\scripts\codex-local-loop.ps1 -Scope docs -Execute
```

scope는 다음 중 하나입니다.

- `docs`
- `prompts`
- `evals`
- `code`
- `mixed`

권장 순서:

1. `docs`
2. `prompts`
3. `evals`
4. `code`
5. `mixed`

## 6. 안전장치

Codex 실행기는 다음을 수행합니다.

- 로컬 Codex 로그인 상태 확인
- `workspace-write` sandbox 사용
- `CODEX_TIMEOUT_SECONDS`로 실행 시간 제한
- 실행 후 새 변경 파일이 선택한 scope 안에 있는지 검사
- `smoke-check`, `validate-evals` 실행
- commit, push, PR 생성은 하지 않음

로그는 git에 올라가지 않는 local-only 경로에 남습니다.

```text
runs/codex-tasks/
runs/codex-logs/
runs/codex-last-message.md
```

## 7. GitHub token 설정

GitHub Actions가 자동 PR을 만들게 하려면 `BOT_GITHUB_TOKEN` repository secret이 필요합니다.

Fine-grained personal access token 권장 설정:

- Repository access: 대상 bot repo만 선택
- Contents: Read and write
- Pull requests: Read and write
- Issues: Read and write
- Metadata: Read-only

설정 위치:

```text
GitHub repo > Settings > Secrets and variables > Actions > Repository secrets
```

추가할 secret:

```text
BOT_GITHUB_TOKEN
```

CLI로 설정하려면:

```powershell
gh auth login
gh secret set BOT_GITHUB_TOKEN --repo okorion/self-improving-maintainer-bot
```

일반 CLI 명령에서 GitHub API를 호출하려면 로컬 환경 변수 `GITHUB_TOKEN`도 쓸 수 있습니다.

```powershell
$env:GITHUB_TOKEN="ghp_or_fine_grained_token"
python -m self_maintainer_bot.cli sync-labels --repo okorion/self-improving-maintainer-bot
```

## 8. 운영 루틴

```powershell
python -m self_maintainer_bot.cli prepare-target
python -m self_maintainer_bot.cli target-status
python -m self_maintainer_bot.cli eval-docs
python -m self_maintainer_bot.cli codex-local-loop --scope docs
.\scripts\codex-local-loop.ps1 -Scope docs -Execute
git -C targets/active status --short
```

Codex가 대상 레포를 수정한 뒤에는 사람이 diff를 확인하고 대상 레포에서 직접 commit/push/PR을 진행합니다.
