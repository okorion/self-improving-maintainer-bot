# GitHub 설정 매뉴얼

이 문서는 public GitHub repository에 올린 뒤 필요한 설정입니다.

## 1. Repository secrets

Settings > Secrets and variables > Actions > Repository secrets에서 추가합니다.

필수는 아닙니다. API mode를 쓸 때만 필요합니다.

- `OPENAI_API_KEY`

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
python -m maintainer_bot.cli sync-labels --repo OWNER/REPO
```

PowerShell:

```powershell
$env:GITHUB_TOKEN="..."
python -m maintainer_bot.cli sync-labels --repo OWNER/REPO
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
3. 테스트 이슈 생성
4. 이슈에 라벨이 붙는지 확인
5. `Eval failure` 이슈 생성 후 eval 추가 PR 확인
6. `Self Improve Docs Proposal` dry-run 실행

## 8. 문제 해결

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
- 로컬에서 `python -m maintainer_bot.cli doctor --require-api-key`가 통과하는지
