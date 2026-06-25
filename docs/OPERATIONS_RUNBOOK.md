# 운영 Runbook

## 매일

- 새 이슈의 라벨이 맞는지 확인합니다.
- 잘못 붙은 라벨은 사람이 수정합니다.
- 반복적으로 틀린 라벨은 `src/self_maintainer_bot/triage.py`의 키워드 규칙 후보로 기록합니다.

## 매주

1. 최근 이슈/PR/질문에서 문서 QA 실패 사례를 고릅니다.
2. GitHub에서 `Eval failure` 이슈를 생성합니다.
3. 생성된 eval 추가 PR을 리뷰하고 merge합니다.
4. `python -m self_maintainer_bot.cli smoke-check`를 실행합니다.
5. `python -m self_maintainer_bot.cli eval-docs`를 실행합니다.
6. 실패가 있으면 `python -m self_maintainer_bot.cli propose-improvement`를 실행합니다.
7. proposal을 읽고 사람이 실제 변경 PR을 작성합니다.

## 릴리즈 전

```bash
python -m self_maintainer_bot.cli smoke-check
python -m self_maintainer_bot.cli eval-docs --dry-run
python -m self_maintainer_bot.cli doctor
```

API mode를 릴리즈 게이트로 쓰는 경우:

```bash
python -m self_maintainer_bot.cli doctor --require-api-key
python -m self_maintainer_bot.cli eval-docs
```

## 실패 대응

### 문서 eval 실패

1. `runs/docs-eval-*.md`를 엽니다.
2. `Missing`과 `Forbidden`을 확인합니다.
3. 문서가 부족한지, 프롬프트가 부족한지, eval이 부정확한지 분류합니다.
4. 분류 결과를 PR 본문에 씁니다.

### 이슈 라벨 실패

1. 실제 이슈 제목과 본문을 로컬 명령에 넣습니다.
2. `triage.py`의 키워드 규칙을 조정합니다.
3. `smoke-check`를 실행합니다.
4. 필요하면 새 eval 성격의 수동 확인 케이스를 문서화합니다.

### Self-improve proposal이 부정확함

1. proposal을 그대로 merge하지 않습니다.
2. 실패 eval이 충분히 구체적인지 확인합니다.
3. `prompts/improvement_planner.md`를 더 명확히 합니다.
4. 같은 실패가 반복되면 proposal 생성 로직을 개선합니다.

## 자동화 확장 승인 기준

새 자동화를 추가할 때는 아래 질문에 모두 답해야 합니다.

- main에 직접 push하지 않는가?
- 외부 PR 코드에 secret을 넘기지 않는가?
- 변경 경로가 allowlist로 제한되는가?
- 실패해도 사람이 복구할 수 있는가?
- eval before/after가 남는가?
