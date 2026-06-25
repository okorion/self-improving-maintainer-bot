# 자가 개선 프로젝트 구축 매뉴얼

이 문서는 `OPENAI_API_KEY` 없이 로컬 Codex 앱 인증 상태로 대상 레포를 개선하는 운영 가이드입니다.

## 전체 구조

```text
대상 레포 문서/이슈/PR에서 실패 사례 발견
  -> Eval failure issue
  -> eval 추가 PR
  -> local dry-run eval
  -> Codex task 생성
  -> 로컬 Codex 앱으로 수정
  -> 사람이 diff 확인
  -> 대상 레포에 PR 작성
```

중요한 원칙:

- OpenAI API key를 사용하지 않습니다.
- 모델 작업은 로컬 Codex 앱/CLI 로그인 상태로만 실행합니다.
- GitHub Actions는 dry-run check, label, summary, PR 생성만 담당합니다.
- 봇은 main에 직접 push하지 않습니다.
- 사람이 리뷰한 변경만 merge합니다.

## 1. GitHub 설정

Settings > Actions > General:

- Actions permissions: Allow all actions and reusable workflows
- Workflow permissions: Read repository contents and packages permissions
- Allow GitHub Actions to create and approve pull requests: 켜기

Settings > Branches:

- Require a pull request before merging
- Require approvals: 1
- Require status checks to pass before merging

Repository secrets:

- `BOT_GITHUB_TOKEN`

`BOT_GITHUB_TOKEN`은 자동 PR 생성을 위한 GitHub token입니다. 로컬 Codex 실행이나 모델 호출용이 아닙니다.

## 2. 로컬 설정

```powershell
python -m pip install -e .
python -m self_maintainer_bot.cli codex-status
```

정상 출력:

```text
PASS codex-cli: ...
PASS codex-login: Logged in using ChatGPT
```

## 3. 대상 레포 설정

`.env`에 대상 레포를 지정합니다.

```env
TARGET_REPOSITORY=OWNER/TARGET_REPO
TARGET_DEFAULT_BRANCH=main
TARGET_WORKTREE=targets/active
TARGET_DOC_PATHS=README.md,docs
CODEX_TIMEOUT_SECONDS=3600
```

준비:

```powershell
python -m self_maintainer_bot.cli prepare-target
python -m self_maintainer_bot.cli target-status
```

## 4. 첫 실행 순서

GitHub Actions:

1. `Sync Labels`
2. `Weekly Health`
3. `Docs Bot Eval`

로컬:

```powershell
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli eval-docs
python -m self_maintainer_bot.cli codex-local-loop --scope docs
```

## 5. Eval failure 루프

GitHub에서 `Eval failure` issue를 만듭니다.

예시:

```text
Suggested eval id: install-python-version-001
User question: What Python version is required?
Required answer content:
- Python 3.10 or newer
Forbidden answer content:
- Python 2
```

생성된 eval PR에서 확인할 것:

- eval id가 중복되지 않는가?
- `must_include`가 정확한 명령/정책/파일명을 요구하는가?
- `must_not_include`가 위험한 오답만 막는가?
- 질문이 실제 사용자 질문처럼 쓰였는가?

## 6. 로컬 Codex 개선

task만 만들기:

```powershell
python -m self_maintainer_bot.cli codex-local-loop --scope docs
```

로컬 Codex로 실행:

```powershell
.\scripts\codex-local-loop.ps1 -Scope docs -Execute
```

실행 후:

```powershell
git -C targets/active status --short
```

diff를 확인한 뒤 대상 레포에서 사람이 직접 commit/push/PR을 진행합니다.

## 7. 매주 운영 루틴

1. 최근 issue/PR/토론에서 실패 사례 3개를 고릅니다.
2. `Eval failure` issue로 등록합니다.
3. 생성된 eval PR을 리뷰하고 merge합니다.
4. `prepare-target`로 대상 레포를 최신화합니다.
5. `eval-docs`를 실행합니다.
6. `codex-local-loop --scope docs`로 task를 생성합니다.
7. 필요하면 로컬 Codex로 수정합니다.
8. 사람이 diff를 확인하고 대상 레포 PR을 작성합니다.

## 8. 완료 기준

- `Sync Labels`가 성공한다.
- 테스트 이슈에 라벨이 자동으로 붙는다.
- `Eval failure` 이슈에서 eval 추가 PR이 열린다.
- `Docs Bot Eval`이 dry-run eval artifact를 남긴다.
- `codex-status`가 `Logged in using ChatGPT`를 확인한다.
- `prepare-target`가 대상 레포를 준비한다.
- `codex-local-loop`가 task를 생성한다.
- 로컬 Codex 실행 후 scope 밖 변경이 guard에 걸린다.
