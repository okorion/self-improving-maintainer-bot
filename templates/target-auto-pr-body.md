## 목적

{{PR_INTENT}}

{{CHANGE_SUMMARY}}

## 시각 변경 확인

- 변경 전 캡처: `{{BEFORE_CAPTURE}}`
- 변경 후 캡처: `{{AFTER_CAPTURE}}`

캡처 파일은 로컬 Codex capture-artifacts 보존소의 manifest에 등록했습니다. PR 본문에는 로컬 절대경로를 남기지 않습니다.

## 자동 검토 요약

- 대상 레포: `{{TARGET_REPOSITORY}}`
- 개선 유형: `{{IMPROVEMENT_KIND}}`
- 변경 규모: 파일 `{{CHANGED_FILE_COUNT}}`개, 라인 `{{CHANGED_LINE_COUNT}}`줄
- 위험 등급: `{{MAX_RISK}}`
- 게시 방식: `{{PUBLISH_MODE}}`
- red-team 상태 컨텍스트: `{{REDTEAM_STATUS_CONTEXT}}`

## 후속 확인

- 자동 red-team 리뷰가 통과한 뒤 병합합니다.
- 검증 또는 리뷰 대응에서 차단 사유가 남으면 최대 8회까지 보정 커밋 또는 무변경 사유를 남기고 재검토합니다.
