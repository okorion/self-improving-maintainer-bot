# R0-R3 Risk Model

중앙 maintainer bot은 target repo 변경을 publish하기 전에 모든 변경 파일을 R0-R3로 분류한다.

## 등급

| 등급 | 의미 | publish 정책 |
| ---- | ---- | ------------ |
| R0 | target 파일 변경 없음, 분석/리포트만 존재 | report only |
| R1 | docs, copy, 작은 UI/CSS, profile allowPaths 안의 낮은 위험 변경 | normal PR 가능 |
| R2 | dependency, package, build config, validation script, `maintainer-bot/project.json` 변경 | draft PR only, auto-merge 금지 |
| R3 | workflow, CODEOWNERS, credential, auth/security, infra, migration, denyPaths 또는 allowPaths 밖 변경 | proposal only, 자동 publish 차단 |

`denyPaths`가 `allowPaths`보다 우선한다. 한 PR에 R3 파일이 하나라도 있으면 전체 변경은 R3이며 patch artifact와 risk report만 남긴다.

## 기본 R2 경로

```text
package.json
pnpm-lock.yaml
package-lock.json
yarn.lock
bun.lockb
maintainer-bot/project.json
vite.config.*
tsconfig*.json
eslint.config.*
scripts/**
```

## 기본 R3 경로

```text
.github/workflows/**
.github/CODEOWNERS
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

## 검증 명령

```powershell
python -m self_maintainer_bot.cli classify-target-changes --scope docs --path README.md
python -m self_maintainer_bot.cli classify-target-changes --scope docs --path package.json
python -m self_maintainer_bot.cli classify-target-changes --scope docs --path .github/workflows/ci.yml
```

## 자동 merge

자동 merge는 R1 `publish_mode=pull_request`에서만 허용된다. R2는 draft PR로만 생성하고, R3는 PR publish 자체를 차단한다.
