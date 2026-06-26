## 목적

{{PR_INTENT}}

{{CHANGE_SUMMARY}}

## 주요 변경

- 실행 ID: `{{RUN_ID}}`
- profile: `{{PROFILE}}`
- target repo: `{{TARGET_REPOSITORY}}`
- input commit: `{{INPUT_COMMIT}}`
- profile/control-plane commit: `{{PROFILE_VERSION}}`
- scope: `{{SCOPE}}`
- improvement kind: `{{IMPROVEMENT_KIND}}`
- max risk: `{{MAX_RISK}}`
- publish mode: `{{PUBLISH_MODE}}`
- changed files: `{{CHANGED_FILE_COUNT}}`
- changed lines: `{{CHANGED_LINE_COUNT}}`
- 변경 파일:
{{CHANGED_FILES}}

## Risk Guard

Denied files:
{{DENIED_FILES}}

Outside allowPaths:
{{DISALLOWED_FILES}}

## Diff Stat

```text
{{DIFF_STAT}}
```

## Diff Numstat

```text
{{DIFF_NUMSTAT}}
```

## 검증

{{VERIFY_COMMANDS}}

## 로컬 Evidence

- patch artifact: `{{PATCH_ARTIFACT}}`
- risk report: `{{RISK_REPORT}}`
- red-team report: `{{REDTEAM_REPORT}}`
- red-team status: `{{REDTEAM_STATUS_CONTEXT}}`
- scheduler log: `{{LOG_PATH}}`

## 남은 위험

- 자동 생성 변경이므로 병합 후에도 다음 루프에서 회귀 여부를 다시 확인합니다.
- CI나 로컬 검증이 실패하면 이 PR은 자동 병합하지 않습니다.
