# Self-Improving Maintainer/Docs Bot 시작 매뉴얼

## 추가 매뉴얼

- `docs/SELF_IMPROVING_PROJECT_GUIDE.md`: 공개 GitHub 레포에서 자가 개선 루프를 구축하는 순서
- `docs/ADDITIONAL_AUTOMATION.md`: optional PR summary, docs patch, and dashboard automation
- `docs/NEXT_STEPS.md`: GitHub 공개 이후 단계별 진행 순서
- `docs/GITHUB_SETUP.md`: repository secrets, Actions, branch protection 설정
- `docs/OPERATIONS_RUNBOOK.md`: 매일/매주 운영 루틴과 실패 대응
- `docs/COMMANDS.md`: CLI 명령어 모음
- `docs/CODEX_LOCAL.md`: 내 PC의 Codex 앱 인증 상태를 활용한 로컬 자가 개선 루프
- `docs/LOCAL_CODEX_ONLY_SETUP.md`: `OPENAI_API_KEY` 없이 로컬 Codex만 쓰는 설정 매뉴얼
- `docs/AUTO_IMPROVE_SCHEDULING.md`: 1시간 단위 자동 개선/PR/merge 스케줄링 매뉴얼
- `docs/TARGET_PROFILES.md`: 여러 target repo를 중앙 control plane에서 다루는 profile 규칙
- `docs/RISK_MODEL.md`: R0/R1/R2/R3 분류와 publish 정책
- `docs/IDENTITY_SEPARATION.md`: read/analyze, worker, publisher identity 분리 규칙
- `docs/LOOP_EXPERIMENTS.md`: target repo별 루프 실험 순서
- `docs/TARGET_REPOSITORY_PROTECTION.md`: target repo CODEOWNERS, branch protection, merge queue 기준
- `docs/CODEX_REDTEAM_GATE.md`: 별도 reviewer 계정 없는 Codex red-team status gate 운영 방식

이 프로젝트는 공개 GitHub 저장소에서 바로 시작할 수 있는 **자가 개선형 Maintainer/Docs Bot** 템플릿입니다.

핵심 아이디어는 간단합니다.

1. 문서 Q&A, 이슈 분류, PR 요약 같은 유지보수 작업을 자동화합니다.
2. 틀린 답변이나 부족한 결과를 eval case로 저장합니다.
3. 변경 전후 eval 점수를 비교합니다.
4. 개선안은 main에 직접 반영하지 않고 Pull Request로만 제안합니다.

이 구조는 "스스로 main을 고치는 봇"이 아니라, **실패 사례를 평가 데이터로 축적하고 검증된 개선 PR을 여는 봇**입니다.

이 레포의 권장 운영 방식은 `OPENAI_API_KEY` 없이 로컬 Codex 앱/CLI 로그인 상태를 사용하는 것입니다. GitHub Actions는 dry-run eval, 라벨, 요약, PR 생성 같은 재현 가능한 운영 자동화만 담당하고, 모델이 필요한 실제 개선 작업은 내 PC의 Codex가 수행합니다.

## 1. 빠른 시작

### 1.1. 로컬 설치

```powershell
cd outputs\self-improving-maintainer-bot
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -U pip
python -m pip install -e .
```

macOS/Linux:

```bash
cd outputs/self-improving-maintainer-bot
python -m venv .venv
source .venv/bin/activate
python -m pip install -U pip
python -m pip install -e .
```

### 1.2. API 키 없이 먼저 실행

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run
```

`--dry-run`은 OpenAI API를 호출하지 않고, 간단한 로컬 검색 방식으로 동작합니다. 프로젝트 구조와 eval flow를 먼저 확인할 때 사용하세요.

### 1.3. 로컬 Codex 앱 상태 확인

```powershell
python -m self_maintainer_bot.cli codex-status
```

정상 출력:

```text
PASS codex-cli: ...
PASS codex-login: Logged in using ChatGPT
```

### 1.4. 대상 레포 설정

`.env.example`을 `.env`로 복사한 뒤 `TARGET_REPOSITORY`를 설정합니다.

```powershell
Copy-Item .env.example .env
python -m self_maintainer_bot.cli prepare-target
python -m self_maintainer_bot.cli target-status
```

If the target repository has its own eval cases, set `TARGET_EVALS_PATH`, for
example `TARGET_EVALS_PATH=evals/docs_qa.jsonl`.

### 1.5. GitHub 자동 PR token

자동화가 GitHub PR을 열고 그 PR에서 정상 체크를 돌리려면 `BOT_GITHUB_TOKEN` repository secret을 추가하세요.

`BOT_GITHUB_TOKEN`이 없으면 PR 생성 workflow는 PR을 만들지 않고 notice만 남깁니다. GitHub 기본 `GITHUB_TOKEN`으로 만든 PR은 재귀 실행 방지 때문에 PR 체크가 `action_required`로 멈출 수 있기 때문입니다.

### 1.6. 로컬 Codex 앱 루프

내 PC의 Codex 앱/CLI 인증 상태를 확인합니다.

```powershell
python -m self_maintainer_bot.cli codex-status
```

eval을 돌리고 Codex 작업 명세만 만들려면:

```powershell
python -m self_maintainer_bot.cli codex-local-loop
```

생성된 task를 검토한 뒤 로컬 Codex로 실행하려면:

```powershell
.\scripts\codex-local-loop.ps1 -Execute
```

자세한 내용은 `docs/CODEX_LOCAL.md`를 따르세요.

## 2. 프로젝트 구조

```text
self-improving-maintainer-bot/
  .github/workflows/
    docs-bot-eval.yml          # PR/수동 실행용 eval workflow
    self-improve-docs.yml      # 수동 실행용 개선 제안 PR workflow
  docs/
    knowledge.md               # 봇이 답변할 기준 문서
    START_HERE.md              # 운영 매뉴얼
  evals/
    docs_qa.jsonl              # 문서 QA eval cases
  prompts/
    docs_qa_system.md          # 문서 QA 프롬프트
    improvement_planner.md     # 실패 분석/개선 제안 프롬프트
  policies/
    self_improvement_policy.md # 자동 변경 안전 정책
    codex_local_policy.md      # 로컬 Codex 실행 안전 정책
  src/self_maintainer_bot/
    cli.py                     # CLI 진입점
    config.py                  # 설정 로딩
    docs_eval.py               # 문서 QA eval 실행
    codex_local.py             # 로컬 Codex task/runner
    reports.py                 # 리포트 저장
    triage.py                  # 이슈 분류 예시
  runs/
    .gitkeep                   # 실행 결과 저장 위치
    codex-tasks/               # 로컬 Codex task 파일, gitignore
    codex-logs/                # 로컬 Codex 실행 로그, gitignore
```

## 3. 첫 번째 운영 루프

### Step 1. 기준 문서 작성

`docs/knowledge.md`를 실제 프로젝트 문서로 바꿉니다.

처음에는 README 전체를 넣지 말고, 봇이 잘 답해야 하는 핵심 정책 5-10개만 넣는 것이 좋습니다.

예:

- 설치 방법
- 지원하는 런타임
- 기여 방식
- 보안 신고 방법
- 릴리즈 정책

### Step 2. eval case 작성

`evals/docs_qa.jsonl`에 한 줄당 하나의 평가 케이스를 넣습니다.

```json
{"id":"install-001","question":"How do I install this project?","must_include":["python -m pip install -e ."],"must_not_include":["npm install"]}
```

필드는 다음과 같습니다.

- `id`: 고유 ID
- `question`: 봇에게 물어볼 질문
- `must_include`: 답변에 반드시 포함되어야 하는 문자열 목록
- `must_not_include`: 답변에 포함되면 실패하는 문자열 목록

### Step 3. eval 실행

```bash
python -m self_maintainer_bot.cli eval-docs --dry-run
```

API를 연결한 뒤:

```bash
python -m self_maintainer_bot.cli eval-docs
```

결과는 `runs/` 아래에 JSONL과 Markdown으로 저장됩니다.

### Step 4. 실패를 개선 제안으로 바꾸기

```bash
python -m self_maintainer_bot.cli propose-improvement
```

이 명령은 가장 최근 eval report를 읽고 `proposals/docs-improvement-plan.md`를 생성합니다.

기본값은 안전하게 **제안 파일만 생성**합니다. 문서나 코드를 자동 수정하지 않습니다.

### Step 5. 사람이 검토하고 PR로 반영

처음에는 다음 원칙을 지키세요.

- eval case 추가는 쉽게 허용
- 문서 수정은 사람이 검토
- 프롬프트 수정은 eval before/after를 확인
- 코드 수정 자동화는 나중에 확장

## 4. GitHub에 올리기

```bash
git init
git add .
git commit -m "Initial self-improving maintainer bot"
git branch -M main
git remote add origin https://github.com/YOUR_NAME/self-improving-maintainer-bot.git
git push -u origin main
```

GitHub repository settings에서 Actions를 활성화합니다.

자동 PR workflow를 쓰려면 repository secret을 추가합니다.

- `BOT_GITHUB_TOKEN`

## 5. GitHub Actions 동작 방식

### docs-bot-eval.yml

- `pull_request`: 항상 `--dry-run`으로 실행합니다.
- `workflow_dispatch`: 수동 실행입니다. API key를 쓰지 않습니다.

외부 fork PR에서는 secret을 쓰지 않는 것이 안전합니다.

### self-improve-docs.yml

- 수동 실행 전용입니다.
- eval을 실행하고 개선 제안 파일을 생성합니다.
- 변경이 있으면 PR을 엽니다.
- main에 직접 push하지 않습니다.

## 6. 자가 개선 정책

처음부터 자동으로 코드를 고치게 만들지 마세요.

추천 성숙도는 다음 순서입니다.

1. L0: 리포트만 작성
2. L1: eval case 추가 제안
3. L2: 문서 개선 제안
4. L3: 프롬프트 개선 제안
5. L4: 제한된 코드 변경 PR 생성

이 템플릿은 L0-L2까지를 기본으로 제공합니다.

## 7. 다음 확장 아이디어

- GitHub issue 댓글 `/triage`로 라벨 추천
- PR diff 요약과 위험도 평가
- 실패한 답변을 `/add-eval` 댓글로 eval에 추가
- hidden eval set으로 과적합 방지
- 개선 전후 비용, latency, pass rate 대시보드 생성
- LangGraph 같은 durable agent runtime으로 장기 실행 루프 구성

## 8. 안전 원칙

- 봇은 main에 직접 push하지 않습니다.
- 외부 PR에서는 secret을 사용하지 않습니다.
- `pull_request_target`에서 외부 PR 코드를 실행하지 않습니다.
- eval을 삭제하거나 완화하는 변경은 사람이 검토합니다.
- 자동 변경 경로는 allowlist로 제한합니다.
- 실패한 실험도 기록합니다.

## 9. 추천 첫 목표

첫 주 목표는 작게 잡으세요.

- 문서 QA eval 20개
- dry-run pass rate 60% 이상
- API mode pass rate 80% 이상
- 실패 케이스를 매번 eval로 추가
- 개선 제안 PR을 사람이 리뷰 후 merge

이 정도면 공개 GitHub 프로젝트로 충분히 설득력 있는 출발점입니다.
