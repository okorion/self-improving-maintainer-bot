# GitHub 설정 매뉴얼

이 문서는 public GitHub repository에 올린 뒤 필요한 설정입니다.

## 1. Repository secrets

Settings > Secrets and variables > Actions > Repository secrets에서 추가합니다.

API mode와 자동 PR 생성을 얼마나 쓸지에 따라 필요한 secret이 다릅니다.

- `OPENAI_API_KEY`: OpenAI API mode를 쓸 때만 필요합니다.
- `BOT_GITHUB_TOKEN`: 자동화가 PR을 만들 때 권장됩니다.

`BOT_GITHUB_TOKEN`은 GitHub fine-grained personal access token 또는 GitHub App token을 넣습니다. 최소 권한은 이 저장소의 `Contents: Read and write`, `Pull requests: Read and write`, `Issues: Read and write`입니다.

중요: `GITHUB_TOKEN`으로 만든 PR은 GitHub의 재귀 실행 방지 때문에 후속 PR 체크가 `action_required`로 멈출 수 있습니다. 이 템플릿의 PR 생성 workflow는 `BOT_GITHUB_TOKEN`이 있을 때만 PR을 만들고, 없으면 notice만 남깁니다.

## 2. Repository variables

Settings > Secrets and variables > Actions > Variables에서 추가할 수 있습니다.

- `OPENAI_MODEL`: 기본값은 `gpt-5.5`

설정하지 않으면 workflow가 `gpt-5.5`를 사용합니다.

## 3. Actions 권한

Settings > Actions > General에서 확인합니다.

추천:

- Actions permissions: Allow all actions and reusable workflows
- Workflow permissions: Read repository contents and packages permissions
- Allow GitHub Actions to create and approve pull requests: 켜기

기본 권한은 read-only로 두고, 필요한 workflow에서만 `contents: write`, `pull-requests: write`, `issues: write`를 선언합니다.

자동 PR을 운영하려면 위 Actions 설정과 별도로 `BOT_GITHUB_TOKEN` secret을 추가하세요. 이 secret은 OpenAI API 호출과 무관하며, GitHub에서 PR branch와 PR을 만들기 위한 권한입니다.

## 4. Branch protection

Settings > Branches > Branch protection rule을 추가합니다.

대상:

```text
main
```

추천 설정:

- Require a pull request before merging
- Require approvals: 1
- Require status checks to pass before merging
- Require branches to be up to date before merging
- Do not allow bypassing the above settings

자동화 봇도 main에 직접 push하지 않는 구조가 좋습니다.

## 5. Labels 동기화

Actions 탭에서 `Sync Labels` workflow를 수동 실행합니다.

또는 로컬에서 GitHub token을 설정한 뒤 실행합니다.

```bash
export GITHUB_TOKEN=...
python -m self_maintainer_bot.cli sync-labels --repo OWNER/REPO
```

PowerShell:

```powershell
$env:GITHUB_TOKEN="..."
python -m self_maintainer_bot.cli sync-labels --repo OWNER/REPO
```

생성되는 라벨:

- `bug`
- `docs`
- `enhancement`
- `question`
- `security`

## 6. Workflow 목록

### Docs Bot Eval

목적:

- PR에서 dry-run eval 실행
- 수동 실행 시 API eval 선택 가능

외부 PR에서는 API secret을 쓰지 않습니다.

### Self Improve Docs Proposal

목적:

- 수동 실행으로 eval 실패 기반 proposal 생성
- proposal 파일만 PR로 올림

처음에는 이 workflow가 직접 문서/프롬프트/코드를 수정하지 않게 유지하세요.

### Issue Triage

목적:

- 새 이슈에 자동 라벨 부여

필요 권한:

- `issues: write`
- `contents: read`

### Sync Labels

목적:

- 표준 라벨 생성/수정

수동 실행 전용입니다.

### Eval From Issue

목적:

- `Eval failure` 이슈를 `evals/docs_qa.jsonl` 추가 PR로 변환

필요 권한:

- `contents: write`
- `pull-requests: write`
- `issues: read`

이 workflow는 이슈 본문을 실행하지 않고 JSONL eval case로만 변환합니다.

## 7. 첫 실행 순서

1. `Sync Labels` 실행
2. `Docs Bot Eval` dry-run 실행
3. 자동 PR을 쓸 예정이면 `BOT_GITHUB_TOKEN` secret 추가
4. 테스트 이슈 생성
5. 이슈에 라벨이 붙는지 확인
6. `Eval failure` 이슈 생성 후 eval 추가 PR 확인
7. `Self Improve Docs Proposal` dry-run 실행

## 8. 자주 헷갈리는 token 구분

- `OPENAI_API_KEY`: 답변 생성, eval 응답 생성, 개선안 작성 등 AI 모델 호출에 사용합니다.
- `GITHUB_TOKEN`: GitHub Actions가 기본 제공하는 토큰입니다. 이슈 라벨링처럼 단순한 작업에는 충분합니다.
- `BOT_GITHUB_TOKEN`: 자동화가 만든 PR에도 일반 PR 체크가 돌게 하려면 필요합니다.

## 9. 문제 해결

### 자동 PR의 체크가 `action_required`로 멈춤

가능한 원인:

- PR이 기본 `GITHUB_TOKEN` 또는 `github-actions[bot]`으로 만들어졌습니다.
- `BOT_GITHUB_TOKEN` secret이 없거나 권한이 부족합니다.

해결:

1. `BOT_GITHUB_TOKEN` secret을 추가합니다.
2. 기존 bot PR은 닫습니다.
3. 해당 workflow를 다시 실행해 새 PR을 만듭니다.

### Issue Triage가 라벨을 못 붙임

확인할 것:

- workflow permissions에 `issues: write`가 있는지
- Actions가 비활성화되어 있지 않은지
- 이슈 이벤트가 `opened`, `edited`, `reopened`인지

### Self Improve Docs Proposal이 PR을 만들지 않음

가능한 정상 동작:

- eval이 모두 통과하면 proposal 파일이 생성되지 않습니다.
- 변경 파일이 없으면 PR도 생성되지 않습니다.

확인할 것:

- 일부러 실패 eval을 하나 추가한 뒤 다시 실행
- `proposals/docs-improvement-plan.md`가 생성되는지 확인

### API mode가 실패함

확인할 것:

- `OPENAI_API_KEY` secret이 있는지
- `OPENAI_MODEL` variable 값이 올바른지
- 로컬에서 `python -m self_maintainer_bot.cli doctor --require-api-key`가 통과하는지
