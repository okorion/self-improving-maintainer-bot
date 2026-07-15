#Requires -Version 5.1
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "lib\profile-goal.ps1")

function Assert-Contains {
  param(
    [string]$Actual,
    [string]$Expected
  )
  if (-not $Actual.Contains($Expected)) {
    throw "Expected text was not found: $Expected"
  }
}

$legacy = Get-ChangeScaleGoalContext -ChangeScale "" -Kind "feat"
Assert-Contains -Actual $legacy -Expected "Change scale: legacy"
Assert-Contains -Actual $legacy -Expected "Choose a small user-visible"

$normal = Get-ChangeScaleGoalContext -ChangeScale "normal" -Kind "auto"
Assert-Contains -Actual $normal -Expected "Change scale: normal"
Assert-Contains -Actual $normal -Expected "small or medium"

$major = Get-ChangeScaleGoalContext -ChangeScale "major" -Kind "feat" -GoalDirectives @("Complete one export workflow.")
Assert-Contains -Actual $major -Expected "Change scale: major"
Assert-Contains -Actual $major -Expected "major vertical slice"
Assert-Contains -Actual $major -Expected "- Complete one export workflow."

$failed = $false
try {
  Resolve-ChangeScale -Value "large" | Out-Null
}
catch {
  $failed = $true
}
if (-not $failed) {
  throw "Unsupported changeScale should fail."
}

Write-Host "change-scale tests passed"
