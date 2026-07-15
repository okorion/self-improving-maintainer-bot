$ErrorActionPreference = "Stop"

powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "test-change-scale.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "change-scale tests failed"
}

python -m self_maintainer_bot.cli summarize-pr --base-ref HEAD --head-ref HEAD --output runs/smoke-pr-summary.md
if ($LASTEXITCODE -ne 0) {
  throw "PR summary smoke failed"
}

python -m self_maintainer_bot.cli smoke-check
