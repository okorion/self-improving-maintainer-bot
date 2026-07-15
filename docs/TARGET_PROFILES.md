# Target Profiles

이 문서는 중앙 control plane이 여러 target repo를 다룰 때 사용하는 profile 규칙이다.

## 기본 실행

```powershell
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery -DryRun
.\scripts\auto-improve-target-once.ps1 -Profile living-shader-gallery
```

profile 이름은 다음 두 형식을 지원한다.

- `living-shader-gallery`
- `profiles/overtura/living-shader-gallery.json`

## Profile 필드

- `repository`: target repo의 `owner/name`
- `defaultBranch`: 기본 브랜치
- `worktree`: 중앙 봇이 clone/update할 로컬 target worktree
- `scope`: 기본 Codex 작업 scope
- `improvementKind`: 선택 값. `docs`, `feat`, `style`, `refactor`, `auto` 중 하나이며 없으면 scheduler가 자동 선택한다.
- `docPaths`: eval과 task context에 포함할 target 문서 경로
- `evalsPath`: target repo 안의 eval JSONL 경로
- `verifyCommands`: publish 전에 target worktree에서 실행할 검증 명령
- `allowPaths`: 자동 PR로 게시할 수 있는 경로
- `denyPaths`: R3 proposal-only로 분류하고 자동 PR 게시를 차단할 경로
- `maxFiles`, `maxLines`: 한 PR 변경량 제한
- `autoMerge`: profile 기본 자동 merge 여부
- `changeScale`: 선택 값. `normal`은 가치 있는 작거나 중간 규모 개선, `major`는 하나의 완결된 vertical slice를 지시한다. 필드가 없으면 기존 small 동작을 유지한다.
- `goalDirectives`: 선택 문자열 배열. 제품별 목표와 non-goal을 Codex 목표에 추가한다.

`changeScale`은 변경량 상한이나 위험 등급을 우회하지 않는다. `major`도 동일한 allow/deny path, R0-R3 분류, red-team, CI, review-response, merge wait 정책을 모두 통과해야 한다. `-DryRun`은 해석된 scale과 directives가 포함된 goal preview를 출력한다.

`run-target-auto-improve-loops.ps1`의 기본 자동 선택은 `feat`, `style`, `refactor` 순서로 작고 검증 가능한 non-doc 개선을 우선한다. docs PR은 별도 운용 정책에서 제한적으로 선택할 수 있지만, 반복 방지를 위해 최대 3회 연속까지만 허용하는 상한선으로 다룬다. `-ImprovementKind docs`는 수동 override다.

## R3 기본 정책

다음 변경은 자동 publish 대상이 아니라 draft/proposal only로 다룬다.

```text
.github/workflows/**
CODEOWNERS
.env*
.npmrc
infra/**
terraform/**
k8s/**
migrations/**
**/auth/**
**/security/**
*.pem
*.key
```

R3 변경이 필요하면 중앙 봇은 코드 변경 대신 계획서나 draft PR을 만들고, 별도 리뷰/승인 절차를 거친다.

R2/R3 판정 규칙은 `docs/RISK_MODEL.md`를 따른다.

## Overtura profiles

현재 등록된 profile:

- `living-shader-gallery`
- `github-activity-galaxy`
- `no-js-visual-lab`
- `css-scroll-odyssey`
- `native-html-ui-kit`
- `css-only-escape-room`
