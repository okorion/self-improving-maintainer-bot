## 목적

로컬 Codex 자가 개선 루프가 생성한 target repo 변경을 검증 후 반영합니다.

## 주요 변경

- 실행 ID: `{{RUN_ID}}`
- profile: `{{PROFILE}}`
- target repo: `{{TARGET_REPOSITORY}}`
- scope: `{{SCOPE}}`
- 변경 파일:
{{CHANGED_FILES}}

## 검증

{{VERIFY_COMMANDS}}

## 남은 위험

- 자동 생성 변경이므로 병합 후에도 다음 루프에서 회귀 여부를 다시 확인합니다.
- CI나 로컬 검증이 실패하면 이 PR은 자동 병합하지 않습니다.
