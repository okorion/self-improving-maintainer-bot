# 자가 개선 프로젝트 구축 매뉴얼

이 문서는 GitHub에 올린 뒤부터 실제 자가 개선 루프를 운영하기 위한 단계별 가이드입니다.

## 전체 구조

이 프로젝트의 자가 개선 루프는 아래 순서로 움직입니다.

```text
사용자 질문/이슈/실패 답변
  -> Eval failure issue
  -> Eval From Issue workflow
  -> eval 추가 PR
  -> Docs Bot Eval
  -> 실패 리포트
  -> Self Improve Docs Proposal
  -> 사람이 문서/프롬프트 수정 PR 작성
  -> merge
  -> 더 강한 baseline
```

중요한 원칙:

- 봇은 main에 직접 push하지 않습니다.
- 실패 사례는 먼저 eval로 남깁니다.
- 개선안은 PR로만 올라옵니다.
- 사람이 리뷰한 변경만 merge합니다.

## 1. GitHub 설정

GitHub repository에서 다음을 설정합니다.

### 1.1. Actions 권한

Settings > Actions > General:

- Actions permissions: Allow all actions and reusable workflows
- Workflow permissions: Read repository contents and packages permissions
- Allow GitHub Actions to create and approve pull requests: 켜기

workflow 파일이 필요한 권한을 개별 선언하므로 기본 권한은 보수적으로 유지합니다.

### 1.2. Branch protection

Settings > Branches에서 `main` 보호 규칙을 추가합니다.

추천:

- Require a pull request before merging
- Require approvals: 1
- Require status checks to pass before merging
- Do not allow bypassing the above settings

### 1.3. OpenAI API 사용 시

Settings > Secrets and variables > Actions:

Repository secrets:

- `OPENAI_API_KEY`

Repository variables:

- `OPENAI_MODEL`: 예시 `gpt-5.5`

API 키가 없어도 dry-run 루프는 동작합니다.

## 2. 첫 실행 순서

GitHub Actions 탭에서 순서대로 실행합니다.

1. `Sync Labels`
2. `Weekly Health`
3. `Docs Bot Eval` with `use_openai=false`

이후 테스트 이슈를 하나 만듭니다.

제목:

```text
Docs typo in README
```

본문:

```text
The installation guide has a typo.
```

기대 결과:

- `docs` 라벨이 자동으로 붙습니다.

## 3. 첫 eval 추가 루프

GitHub에서 새 issue를 만듭니다.

템플릿:

```text
Eval failure
```

예시 입력:

```text
Suggested eval id: install-python-version-001
User question: What Python version is required?
Required answer content:
- Python 3.10 or newer
Forbidden answer content:
- Python 2
```

이슈가 생성되면 `Eval From Issue` workflow가 실행됩니다.

기대 결과:

- `bot/add-eval-ISSUE_NUMBER` 브랜치 생성
- `evals/docs_qa.jsonl`에 eval case 추가
- eval 추가 PR 생성

PR에서 확인할 것:

- eval id가 중복되지 않는가?
- `must_include`가 너무 느슨하지 않은가?
- `must_not_include`가 과도하지 않은가?
- 질문이 실제 사용자 질문처럼 쓰였는가?

## 4. eval PR merge 후 확인

eval 추가 PR을 merge한 뒤 `Docs Bot Eval`을 실행합니다.

```text
Actions > Docs Bot Eval > Run workflow > use_openai=false
```

새 eval이 실패할 수 있습니다. 이것은 정상입니다.

실패는 “봇이 아직 이 사례를 못 푼다”는 신호입니다.

## 5. 개선 제안 PR 만들기

Actions에서 `Self Improve Docs Proposal`을 실행합니다.

처음에는:

```text
use_openai=false
```

API 키를 설정한 뒤에는:

```text
use_openai=true
```

기대 결과:

- `proposals/docs-improvement-plan.md`가 생성됩니다.
- proposal PR이 열립니다.

이 PR은 바로 merge하지 말고, 제안 내용을 읽은 뒤 사람이 실제 변경 PR을 작성하는 용도로 사용하세요.

## 6. 사람이 실제 개선 PR 작성

실패 원인을 세 가지 중 하나로 분류합니다.

### 문서 부족

정답이 `docs/knowledge.md`에 없거나 모호합니다.

조치:

- `docs/knowledge.md` 수정
- 필요하면 `docs/START_HERE.md`나 README도 수정

### 프롬프트 부족

문서는 충분하지만 답변이 문서를 잘 따르지 못합니다.

조치:

- `prompts/docs_qa_system.md` 수정

### eval 부정확

eval이 너무 넓거나 틀린 정답을 요구합니다.

조치:

- eval을 고치되, PR 본문에 왜 완화/수정이 필요한지 명시

## 7. 매주 운영 루틴

매주 한 번 반복합니다.

1. 최근 issue/PR/토론에서 실패 사례 3개를 고릅니다.
2. `Eval failure` issue로 등록합니다.
3. 생성된 eval PR을 리뷰하고 merge합니다.
4. `Docs Bot Eval`을 실행합니다.
5. 실패가 있으면 `Self Improve Docs Proposal`을 실행합니다.
6. 사람이 실제 수정 PR을 작성합니다.

## 8. 확장 순서

지금 구현된 단계:

- L0: health/eval report
- L1: 실패 사례를 eval PR로 전환
- L2: docs improvement proposal PR
- L2: PR 변경 요약 코멘트

다음 확장 추천:

1. CI 실패 로그 요약
2. 문서 수정 PR 자동 생성
3. 프롬프트 수정 PR 자동 생성
4. 제한된 코드 수정 PR 자동 생성

코드 수정 자동화는 마지막에 추가하세요.

## 9. 로컬에서 같은 루프 재현

```bash
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli validate-evals
python -m self_maintainer_bot.cli eval-docs --dry-run
python -m self_maintainer_bot.cli propose-improvement --dry-run
```

issue form 본문을 파일로 저장했다면:

```bash
python -m self_maintainer_bot.cli add-eval-from-issue \
  --body-file work/issue-body.md \
  --issue-number 1
```

## 10. 완료 기준

자가 개선 프로젝트의 첫 구축 완료 기준:

- `Sync Labels`가 성공한다.
- 테스트 이슈에 라벨이 자동으로 붙는다.
- `Eval failure` 이슈에서 eval 추가 PR이 열린다.
- `Docs Bot Eval`이 eval report artifact를 남긴다.
- `Self Improve Docs Proposal`이 실패 기반 proposal PR을 만든다.
- main branch는 PR 없이는 변경되지 않는다.
