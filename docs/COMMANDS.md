# CLI 명령어

## 로컬 점검

```bash
python -m self_maintainer_bot.cli doctor
python -m self_maintainer_bot.cli smoke-check
```

API 키까지 강제:

```bash
python -m self_maintainer_bot.cli doctor --require-api-key
```

## 로컬 Codex 루프

내 PC의 Codex CLI와 로그인 상태 확인:

```bash
python -m self_maintainer_bot.cli codex-status
```

dry-run eval을 실행하고 Codex task만 생성:

```bash
python -m self_maintainer_bot.cli codex-local-loop
```

eval, task 생성, 로컬 Codex 실행까지 한 번에 진행:

```bash
python -m self_maintainer_bot.cli codex-local-loop --execute
```

PowerShell wrapper:

```powershell
.\scripts\codex-local-loop.ps1 -Execute
```

OpenAI API eval 결과를 먼저 사용:

```powershell
.\scripts\codex-local-loop.ps1 -ApiEval -Execute
```

이미 생성된 task 실행:

```bash
python -m self_maintainer_bot.cli run-codex-task --task-file runs/codex-tasks/YOUR_TASK.md
```

## 문서 eval

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run
python -m self_maintainer_bot.cli eval-docs
```

통과 기준을 낮춰 리포트만 남기기:

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run --fail-under 0
```

## 개선 제안

```bash
python -m self_maintainer_bot.cli propose-improvement --dry-run
python -m self_maintainer_bot.cli propose-improvement
```

eval이 모두 통과하면 proposal은 생성되지 않습니다.

## eval 추가

```bash
python -m self_maintainer_bot.cli add-eval \
  --id install-002 \
  --question "What Python version is required?" \
  --must-include "Python 3.10 or newer"
```

GitHub issue form 본문에서 eval 추가:

```bash
python -m self_maintainer_bot.cli add-eval-from-issue \
  --body-file work/issue-body.md \
  --issue-number 12
```

eval 파일 검증:

```bash
python -m self_maintainer_bot.cli validate-evals
```

## 이슈 라벨 추천

```bash
python -m self_maintainer_bot.cli triage-issue \
  --title "Docs typo in README" \
  --body "The installation guide has a typo"
```

## GitHub labels 동기화

```bash
GITHUB_TOKEN=... python -m self_maintainer_bot.cli sync-labels --repo OWNER/REPO
```

PowerShell:

```powershell
$env:GITHUB_TOKEN="..."
python -m self_maintainer_bot.cli sync-labels --repo OWNER/REPO
```

## GitHub issue에 라벨 적용

```bash
GITHUB_TOKEN=... python -m self_maintainer_bot.cli apply-issue-labels \
  --repo OWNER/REPO \
  --issue-number 1 \
  --title "Docs typo in README" \
  --body "The installation guide has a typo"
```

## PR 요약 생성

```bash
python -m self_maintainer_bot.cli summarize-pr \
  --base-ref origin/main \
  --head-ref HEAD \
  --output runs/pr-summary.md
```

GitHub PR에 코멘트로 반영:

```bash
GITHUB_TOKEN=... python -m self_maintainer_bot.cli comment-pr-summary \
  --repo OWNER/REPO \
  --pr-number 12 \
  --summary-file runs/pr-summary.md
```

## Docs patch candidate

Create candidate documentation additions from the latest failed eval report:

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run --fail-under 0
python -m self_maintainer_bot.cli propose-docs-patch
```

This command edits `docs/knowledge.md`. Review and rewrite the generated candidate section before merge.

## Status dashboard

```bash
python -m self_maintainer_bot.cli update-status
```

This writes `docs/PROJECT_STATUS.md`.
