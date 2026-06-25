param(
  [switch]$Execute,
  [switch]$ApiEval,
  [ValidateSet("docs", "prompts", "evals", "code", "mixed")]
  [string]$Scope = "docs",
  [string]$Goal = "Improve the repository based on the latest documentation eval signal.",
  [string]$Model = "",
  [ValidateSet("read-only", "workspace-write")]
  [string]$Sandbox = "workspace-write",
  [switch]$SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$argsList = @(
  "-m", "self_maintainer_bot.cli",
  "codex-local-loop",
  "--scope", $Scope,
  "--goal", $Goal,
  "--sandbox", $Sandbox
)

if ($Execute) {
  $argsList += "--execute"
}

if ($ApiEval) {
  $argsList += "--api-eval"
}

if ($Model) {
  $argsList += @("--model", $Model)
}

if ($SkipVerify) {
  $argsList += "--skip-verify"
}

python @argsList
exit $LASTEXITCODE
