#Requires -Version 5.1
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\scripts\profile-change-scale.ps1")

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

Assert-Equal "" (Get-ProfileChangeScale -ProfileObject ([pscustomobject]@{})) "Legacy profile must remain unchanged."
Assert-Equal "normal" (Get-ProfileChangeScale -ProfileObject ([pscustomobject]@{ changeScale = "normal" })) "Normal scale parsing failed."
Assert-Equal "major" (Get-ProfileChangeScale -ProfileObject ([pscustomobject]@{ changeScale = "MAJOR" })) "Major scale parsing failed."

$context = Get-ChangeScaleGoalContext -ChangeScale "major" -GoalDirectives @("Ship one complete flow.")
if ($context -notmatch "coherent, user-visible vertical slice") {
  throw "Major goal context is missing the vertical-slice rule."
}
if ($context -notmatch "Ship one complete flow") {
  throw "Goal directives were not included."
}

$invalidFailed = $false
try {
  Get-ProfileChangeScale -ProfileObject ([pscustomobject]@{ changeScale = "huge" }) | Out-Null
}
catch {
  $invalidFailed = $true
}
if (-not $invalidFailed) {
  throw "Invalid changeScale must fail."
}

Write-Host "PASS profile change scale tests"
