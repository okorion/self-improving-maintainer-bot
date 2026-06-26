# CLI 명령어

## 로컬 점검

```bash
python -m self_maintainer_bot.cli doctor
python -m self_maintainer_bot.cli smoke-check
```

이 프로젝트의 기본 운영은 `OPENAI_API_KEY` 없이 로컬 Codex 앱을 사용합니다.

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

이미 생성된 task 실행:

```bash
python -m self_maintainer_bot.cli run-codex-task --task-file runs/codex-tasks/YOUR_TASK.md
```

## 대상 레포

```bash
python -m self_maintainer_bot.cli target-status
python -m self_maintainer_bot.cli prepare-target
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

이 명령은 `docs/knowledge.md`를 수정합니다. 병합 전에 생성된 후보 문구를 사람이 검토하고 한국어 기준으로 다듬으세요.

## Status dashboard

```bash
python -m self_maintainer_bot.cli update-status
```

This writes `docs/PROJECT_STATUS.md`.

## Target repository protection

```powershell
.\scripts\apply-target-protection.ps1 -Mode verify -IncludeMergeQueue
.\scripts\apply-target-protection.ps1 -Mode apply-and-verify -IncludeMergeQueue
```

## Codex red-team gate

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -AutoMerge
.\scripts\auto-improve-target-once.ps1 -Profile no-js-visual-lab -AutoMerge -AllowLocalPublisherAuth
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -AllowLocalPublisherAuth
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -AutoMerge -AllowLocalPublisherAuth -MaxReviewResponses 2 -MaxClosedPrReplacements 2
.\scripts\run-target-auto-improve-loops.ps1 -Iterations 3 -ParallelProfiles -AutoMerge -AllowLocalPublisherAuth -MaxReviewResponses 2 -MaxClosedPrReplacements 2
```
