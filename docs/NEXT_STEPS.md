# 이후 진행 매뉴얼

이 문서는 템플릿을 만든 뒤 실제 공개 GitHub 프로젝트로 키우는 순서입니다.

목표는 단순합니다.

1. 먼저 안전한 공개 레포 운영 체계를 만든다.
2. 실패 사례를 eval로 쌓는다.
3. 문서와 프롬프트 개선을 PR로 반복한다.
4. 충분히 안정화된 뒤 코드 수정 자동화로 확장한다.

## Phase 0. 로컬 기준선 만들기

먼저 로컬에서 템플릿이 정상인지 확인합니다.

```powershell
cd C:\path\to\self-improving-maintainer-bot
python -m pip install -e .
python -m maintainer_bot.cli doctor
python -m maintainer_bot.cli smoke-check
```

`doctor`는 필수 파일과 환경을 확인합니다.

`smoke-check`는 다음을 한 번에 확인합니다.

- Python source compile
- dry-run 문서 eval
- 이슈 라벨 추천

`OPENAI_API_KEY` 없이도 `smoke-check`는 통과해야 합니다.

API 키까지 강제 확인하려면:

```bash
python -m maintainer_bot.cli doctor --require-api-key
```

## Phase 1. GitHub 공개 레포 만들기

1. GitHub에서 새 public repository를 만듭니다.
2. 로컬 폴더에서 다음을 실행합니다.

```bash
git init
git add .
git commit -m "Initial self-improving maintainer bot"
git branch -M main
git remote add origin https://github.com/YOUR_NAME/self-improving-maintainer-bot.git
git push -u origin main
```

3. GitHub Actions가 켜져 있는지 확인합니다.
4. 수동으로 `Sync Labels` workflow를 한 번 실행합니다.
5. `Docs Bot Eval` workflow를 수동으로 dry-run 실행합니다.

자세한 설정은 `docs/GITHUB_SETUP.md`를 따르세요.

## Phase 2. 기준 문서와 eval 확장

처음 일주일은 기능을 늘리지 말고 eval 품질을 올립니다.

목표:

- `docs/knowledge.md`에 실제 프로젝트 정책 5-10개 정리
- `evals/docs_qa.jsonl`에 문서 QA 20개 작성
- dry-run eval 통과율 확인
- OpenAI API eval 통과율 확인

추천 eval 작성 기준:

- 질문은 실제 사용자가 물을 만한 문장으로 작성합니다.
- `must_include`는 정확한 명령, 정책 문구, 파일명 위주로 둡니다.
- `must_not_include`는 위험한 오답만 넣습니다.
- 하나의 eval에 너무 많은 조건을 넣지 않습니다.

## Phase 3. 자동 이슈 라벨링 켜기

이 템플릿에는 `Issue Triage` workflow가 들어 있습니다.

이슈가 열리거나 수정되면 다음 라벨 중 하나 이상을 자동으로 붙입니다.

- `bug`
- `docs`
- `enhancement`
- `question`
- `security`

라벨 규칙은 `src/maintainer_bot/triage.py`에 있습니다.

로컬에서 확인:

```bash
python -m maintainer_bot.cli triage-issue --title "Docs typo in README" --body "Installation guide has a typo"
```

GitHub label 생성/수정은 다음 명령으로도 수동 실행할 수 있습니다.

```bash
python -m maintainer_bot.cli sync-labels --repo OWNER/REPO
```

이 명령은 `GITHUB_TOKEN` 환경 변수가 필요합니다.

## Phase 4. Self-improve proposal 운영

그 전에 `Eval failure` issue template을 사용해 실패 사례를 eval PR로 바꾸는 루프를 먼저 확인하세요.

1. GitHub에서 `Eval failure` 이슈를 만듭니다.
2. `Eval From Issue` workflow가 eval 추가 PR을 만드는지 확인합니다.
3. PR의 `evals/docs_qa.jsonl` 변경을 리뷰하고 merge합니다.
4. `Docs Bot Eval`을 다시 실행합니다.

`Self Improve Docs Proposal` workflow는 수동 실행 전용입니다.

권장 사용 순서:

1. `Docs Bot Eval`을 실행합니다.
2. 실패가 있으면 `Self Improve Docs Proposal`을 실행합니다.
3. 생성된 PR의 `proposals/docs-improvement-plan.md`를 읽습니다.
4. 사람이 실제 문서/프롬프트/eval 변경을 별도 PR로 반영합니다.

처음에는 proposal PR이 직접 문서나 코드를 고치지 않게 유지하세요.

이유:

- eval이 아직 빈약하면 자동 개선이 과적합될 수 있습니다.
- 문서가 부족한지, 프롬프트가 부족한지 사람이 먼저 분류해야 합니다.
- 공개 레포에서는 작은 자동화도 신뢰를 천천히 쌓는 것이 좋습니다.

## Phase 5. 첫 공개 운영 루틴

매주 한 번 다음 루틴을 반복합니다.

```bash
python -m maintainer_bot.cli smoke-check
python -m maintainer_bot.cli eval-docs --dry-run
python -m maintainer_bot.cli eval-docs
python -m maintainer_bot.cli propose-improvement
```

실패 케이스가 나오면 다음 순서로 처리합니다.

1. 문서가 부족하면 `docs/knowledge.md`를 고칩니다.
2. 문서는 충분한데 답변이 틀리면 `prompts/docs_qa_system.md`를 고칩니다.
3. 반복 실패하면 eval case를 더 작게 쪼갭니다.
4. 그래도 어렵다면 코드 개선 후보로 올립니다.

## Phase 6. 확장 순서

권장 확장 순서는 다음입니다.

1. `/add-eval` 이슈 댓글을 eval 추가 PR로 바꾸기
2. PR diff 요약 기능 추가
3. CI 실패 로그 요약 기능 추가
4. 문서 수정 PR 자동 생성
5. 프롬프트 수정 PR 자동 생성
6. 제한된 코드 수정 PR 자동 생성

코드 수정 자동화는 마지막입니다.

## 성공 기준

첫 번째 공개 버전의 성공 기준은 다음 정도면 충분합니다.

- GitHub Actions가 초록색으로 돈다.
- 새 이슈에 라벨이 자동으로 붙는다.
- 문서 QA eval이 20개 이상 있다.
- 실패 사례를 eval로 추가하는 절차가 명확하다.
- self-improve workflow가 main에 직접 push하지 않는다.
