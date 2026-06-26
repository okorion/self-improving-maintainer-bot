#Requires -Version 5.1
[CmdletBinding()]
param(
  [string[]]$Profile = @(),
  [int]$Iterations = 3,
  [string]$Scope = "",
  [switch]$AutoMerge,
  [switch]$AllowLocalPublisherAuth,
  [int]$MaxReviewResponses = 2,
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

if ($Profile.Count -eq 0) {
  $Profile = Get-ChildItem -LiteralPath (Join-Path $BotRoot "profiles\overtura") -Filter "*.json" |
    Sort-Object BaseName |
    ForEach-Object { $_.BaseName }
}

foreach ($profileName in $Profile) {
  for ($iteration = 1; $iteration -le $Iterations; $iteration += 1) {
    Write-Host "=== profile=$profileName iteration=$iteration/$Iterations ==="
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
    if ($LASTEXITCODE -ne 0) {
      throw "Auto improve loop failed for profile=$profileName iteration=$iteration."
    }
  }
}
