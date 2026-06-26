#Requires -Version 5.1
[CmdletBinding()]
param(
  [string[]]$Profile = @(),
  [int]$Iterations = 3,
  [string]$Scope = "",
  [switch]$AutoMerge,
  [switch]$AllowLocalPublisherAuth,
  [int]$MaxReviewResponses = 2,
  [int]$MaxClosedPrReplacements = 2,
  [int]$ReviewFailureExitCode = 20,
  [int]$MergeWaitTimeoutSeconds = 900,
  [int]$MergePollSeconds = 15,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$OnceScript = Join-Path $BotRoot "scripts\auto-improve-target-once.ps1"

if ($Iterations -lt 1) {
  throw "Iterations must be 1 or greater."
}
if ($MaxClosedPrReplacements -lt 0) {
  throw "MaxClosedPrReplacements must be 0 or greater."
}

if ($Profile.Count -eq 0) {
  $Profile = Get-ChildItem -LiteralPath (Join-Path $BotRoot "profiles\overtura") -Filter "*.json" |
    Sort-Object BaseName |
    ForEach-Object { $_.BaseName }
}

foreach ($profileName in $Profile) {
  for ($iteration = 1; $iteration -le $Iterations; $iteration += 1) {
    $replacement = 0
    while ($true) {
      $attemptLabel = $replacement + 1
      $maxAttemptLabel = $MaxClosedPrReplacements + 1
      Write-Host "=== profile=$profileName iteration=$iteration/$Iterations replacement-attempt=$attemptLabel/$maxAttemptLabel ==="
      $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $OnceScript,
        "-Profile",
        $profileName,
        "-MaxReviewResponses",
        [string]$MaxReviewResponses,
        "-ReviewFailureExitCode",
        [string]$ReviewFailureExitCode,
        "-MergeWaitTimeoutSeconds",
        [string]$MergeWaitTimeoutSeconds,
        "-MergePollSeconds",
        [string]$MergePollSeconds
      )
      if ($Scope) {
        $arguments += @("-Scope", $Scope)
      }
      if ($AutoMerge) {
        $arguments += "-AutoMerge"
      }
      if ($AllowLocalPublisherAuth) {
        $arguments += "-AllowLocalPublisherAuth"
      }
      if ($DryRun) {
        $arguments += "-DryRun"
      }

      & powershell @arguments
      $exitCode = $LASTEXITCODE
      if ($exitCode -eq 0) {
        break
      }
      if ($exitCode -eq $ReviewFailureExitCode -and $replacement -lt $MaxClosedPrReplacements) {
        $replacement += 1
        Write-Host "Closed review-failed PR for profile=$profileName iteration=$iteration. Searching for a new improvement candidate."
        continue
      }
      if ($exitCode -eq $ReviewFailureExitCode) {
        throw "Auto improve loop closed too many review-failed PRs for profile=$profileName iteration=$iteration."
      }
      throw "Auto improve loop failed for profile=$profileName iteration=$iteration with exit code $exitCode."
    }
  }
}
