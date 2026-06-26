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
  [switch]$ParallelProfiles,
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

function New-ChildArguments {
  param([string]$ProfileName)
  $arguments = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $OnceScript,
    "-Profile",
    $ProfileName,
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
  return $arguments
}

if ($ParallelProfiles -and $Profile.Count -gt 1) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
  $runDir = Join-Path $BotRoot "runs\scheduler\parallel-$stamp"
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  $children = @()
  foreach ($profileName in $Profile) {
    $outPath = Join-Path $runDir "$profileName.out.log"
    $errPath = Join-Path $runDir "$profileName.err.log"
    $arguments = @(
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      $PSCommandPath,
      "-Profile",
      $profileName,
      "-Iterations",
      [string]$Iterations,
      "-MaxReviewResponses",
      [string]$MaxReviewResponses,
      "-MaxClosedPrReplacements",
      [string]$MaxClosedPrReplacements,
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
    Write-Host "=== launching profile=$profileName iterations=$Iterations log=$outPath ==="
    $job = Start-Job -ScriptBlock {
      param(
        [string]$WorkingDirectory,
        [string[]]$ChildArguments,
        [string]$OutFile,
        [string]$ErrFile
      )
      Set-Location $WorkingDirectory
      & powershell @ChildArguments > $OutFile 2> $ErrFile
      return $LASTEXITCODE
    } -ArgumentList $BotRoot, $arguments, $outPath, $errPath
    $children += [pscustomobject]@{
      Profile = $profileName
      Job = $job
      Out = $outPath
      Err = $errPath
    }
  }

  $failed = @()
  foreach ($child in $children) {
    Wait-Job -Job $child.Job | Out-Null
    $received = @(Receive-Job -Job $child.Job)
    $exitCode = if ($received.Count -gt 0) { [int]$received[-1] } else { 1 }
    Remove-Job -Job $child.Job -Force
    if ($exitCode -ne 0) {
      $failed += [pscustomobject]@{
        Profile = $child.Profile
        ExitCode = $exitCode
        Out = $child.Out
        Err = $child.Err
      }
    }
    Write-Host "=== completed profile=$($child.Profile) exit=$exitCode out=$($child.Out) err=$($child.Err) ==="
  }
  if ($failed.Count -gt 0) {
    $labels = ($failed | ForEach-Object { "$($_.Profile):$($_.ExitCode)" }) -join ", "
    throw "Parallel profile loops failed: $labels"
  }
  exit 0
}

foreach ($profileName in $Profile) {
  for ($iteration = 1; $iteration -le $Iterations; $iteration += 1) {
    $replacement = 0
    while ($true) {
      $attemptLabel = $replacement + 1
      $maxAttemptLabel = $MaxClosedPrReplacements + 1
      Write-Host "=== profile=$profileName iteration=$iteration/$Iterations replacement-attempt=$attemptLabel/$maxAttemptLabel ==="
      $arguments = New-ChildArguments -ProfileName $profileName

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
