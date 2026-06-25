# 운영 매뉴얼

이 문서는 저장소 운영자가 매주 반복할 수 있는 최소 workflow입니다.

## 매주 할 일

1. 새 이슈와 PR에서 봇이 틀렸거나 부족했던 사례를 찾습니다.
2. 그 사례를 `evals/docs_qa.jsonl`에 추가합니다.
3. `python -m self_maintainer_bot.cli eval-docs`를 실행합니다.
4. 실패가 있으면 `python -m self_maintainer_bot.cli propose-improvement`를 실행합니다.
5. 생성된 `proposals/docs-improvement-plan.md`를 검토합니다.
6. 필요한 문서/프롬프트/eval 변경만 PR로 올립니다.

자동화가 직접 PR을 열게 하려면 GitHub repository secret `BOT_GITHUB_TOKEN`을 먼저 설정합니다. 이 token은 OpenAI API 호출용이 아니라 GitHub PR 생성용입니다.

내 PC에서 Codex 앱 인증 상태를 활용한 로컬 개선 루프를 쓰려면:

```powershell
python -m self_maintainer_bot.cli codex-status
.\scripts\codex-local-loop.ps1 -Execute
```

처음에는 `-Execute` 없이 task 파일만 생성해서 내용을 확인하는 것을 권장합니다.

## 좋은 eval case 기준

좋은 eval은 구체적입니다.

나쁜 예:

```json
{"id":"bad-001","question":"Tell me about this project","must_include":["good"]}
```

좋은 예:

```json
{"id":"install-001","question":"What command installs the project locally?","must_include":["python -m pip install -e ."],"must_not_include":["npm install"]}
```

## 변경 우선순위

1. 문서가 부족하면 문서를 고칩니다.
2. 문서는 충분한데 답변이 틀리면 프롬프트를 고칩니다.
3. 프롬프트로 해결하기 어렵고 반복 실패하면 코드를 고칩니다.
4. eval 자체가 부정확하면 eval을 고치되, 완화인지 보강인지 PR에 명확히 씁니다.

## PR 본문에 남길 내용

- 어떤 실패 케이스를 해결했는지
- eval before/after
- 새로 추가한 eval case
- 사람이 직접 확인해야 하는 위험
