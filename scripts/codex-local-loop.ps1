param(
  [switch]$Execute,
  [ValidateSet("docs", "prompts", "evals", "code", "mixed")]
  [string]$Scope = "docs",
  [string]$Goal = "Improve the repository based on the latest documentation eval signal.",
  [string]$Model = "",
  [ValidateSet("read-only", "workspace-write")]
  [string]$Sandbox = "workspace-write",
  [int]$TimeoutSeconds = 0,
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

if ($Model) {
  $argsList += @("--model", $Model)
}

if ($TimeoutSeconds -gt 0) {
  $argsList += @("--timeout-seconds", "$TimeoutSeconds")
}

if ($SkipVerify) {
  $argsList += "--skip-verify"
}

python @argsList
exit $LASTEXITCODE
