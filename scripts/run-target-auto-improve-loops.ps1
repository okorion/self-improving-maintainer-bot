#Requires -Version 5.1
[CmdletBinding()]
param(
  [string[]]$Profile = @(),
  [int]$Iterations = 3,
  [string]$Scope = "",
  [string]$ImprovementKind = "",
  [int]$MaxConsecutiveDocs = 3,
  [string[]]$NonDocsSequence = @("feat", "style", "refactor"),
  [switch]$AutoMerge,
  [switch]$AllowLocalPublisherAuth,
  [int]$MaxReviewResponses = 6,
  [int]$MaxClosedPrReplacements = 3,
  [int]$ReviewFailureExitCode = 20,
  [int]$MergeWaitTimeoutSeconds = 900,
  [int]$MergePollSeconds = 15,
  [switch]$ParallelProfiles,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$OnceScript = Join-Path $BotRoot "scripts\auto-improve-target-once.ps1"
$ScopeStateDir = Join-Path $BotRoot "runs\scheduler\scope-state"

if ($Iterations -lt 1) {
  throw "Iterations must be 1 or greater."
}
if ($MaxClosedPrReplacements -lt 0) {
  throw "MaxClosedPrReplacements must be 0 or greater."
}
if ($MaxConsecutiveDocs -lt 1) {
  throw "MaxConsecutiveDocs must be 1 or greater."
}
if ($ImprovementKind -and @("auto", "docs", "feat", "style", "refactor") -notcontains $ImprovementKind) {
  throw "Unsupported improvement kind: $ImprovementKind"
}
if ($NonDocsSequence.Count -eq 1 -and $NonDocsSequence[0] -match ",") {
  $NonDocsSequence = @($NonDocsSequence[0].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($NonDocsSequence.Count -lt 1) {
  throw "NonDocsSequence must contain at least one non-docs kind."
}
foreach ($kind in $NonDocsSequence) {
  if (@("feat", "style", "refactor") -notcontains $kind) {
    throw "Unsupported non-docs kind in sequence: $kind"
  }
}

if ($Profile.Count -eq 0) {
  $Profile = Get-ChildItem -LiteralPath (Join-Path $BotRoot "profiles\overtura") -Filter "*.json" |
    Sort-Object BaseName |
    ForEach-Object { $_.BaseName }
}

function Resolve-ProfilePath {
  param([string]$Name)
  $candidates = @(
    $Name,
    "$Name.json",
    (Join-Path "profiles" $Name),
    (Join-Path "profiles" "$Name.json"),
    (Join-Path "profiles\overtura" "$Name.json")
  )
  foreach ($candidate in $candidates) {
    $path = if ([System.IO.Path]::IsPathRooted($candidate)) { $candidate } else { Join-Path $BotRoot $candidate }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }
  throw "Target profile not found: $Name"
}

function Get-ProfileData {
  param([string]$ProfileName)
  $path = Resolve-ProfilePath -Name $ProfileName
  return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Get-StatePath {
  param([string]$ProfileName)
  return (Join-Path $ScopeStateDir "$ProfileName.json")
}

function Get-RecentMergedDocsStreak {
  param(
    [string]$Repo
  )
  if (-not $Repo) {
    return 0
  }
  try {
    $titles = @(gh pr list --repo $Repo --state merged --limit $MaxConsecutiveDocs --json title --jq ".[].title")
  }
  catch {
    return 0
  }
  $count = 0
  foreach ($title in $titles) {
    if ($title -match "^\[docs\]") {
      $count += 1
    }
    else {
      break
    }
  }
  return $count
}

function Get-ImprovementState {
  param([string]$ProfileName)
  New-Item -ItemType Directory -Force -Path $ScopeStateDir | Out-Null
  $statePath = Get-StatePath -ProfileName $ProfileName
  if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not ($state.PSObject.Properties.Name -contains "sequenceOffsetVersion")) {
      $offset = Get-ProfileSequenceOffset -ProfileName $ProfileName
      $state.nonDocsIndex = (([int]$state.nonDocsIndex + $offset) % $NonDocsSequence.Count)
      $state | Add-Member -NotePropertyName "sequenceOffsetVersion" -NotePropertyValue 1 -Force
      Save-ImprovementState -ProfileName $ProfileName -State $state
    }
    return $state
  }
  $profileData = Get-ProfileData -ProfileName $ProfileName
  $docsStreak = Get-RecentMergedDocsStreak -Repo ([string]$profileData.repository)
  $offset = Get-ProfileSequenceOffset -ProfileName $ProfileName
  return [pscustomobject]@{
    profile = $ProfileName
    repository = [string]$profileData.repository
    docsStreak = $docsStreak
    nonDocsIndex = $offset
    lastKind = ""
    sequenceOffsetVersion = 1
    updatedAt = ""
  }
}

function Get-ProfileSequenceOffset {
  param([string]$ProfileName)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($ProfileName)
    $hash = $sha.ComputeHash($bytes)
    return ([int]$hash[0] % $NonDocsSequence.Count)
  }
  finally {
    $sha.Dispose()
  }
}

function Save-ImprovementState {
  param(
    [string]$ProfileName,
    [object]$State
  )
  New-Item -ItemType Directory -Force -Path $ScopeStateDir | Out-Null
  $State.updatedAt = (Get-Date -Format o)
  $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-StatePath -ProfileName $ProfileName) -Encoding utf8
}

function Get-ScopeForKind {
  param([string]$Kind)
  if ($Kind -eq "docs") {
    return "docs"
  }
  return "mixed"
}

function Resolve-ImprovementPlan {
  param([string]$ProfileName)
  if ($ImprovementKind -and $ImprovementKind -ne "auto") {
    $kind = $ImprovementKind
  }
  elseif ($Scope) {
    $kind = if ($Scope -eq "docs") { "docs" } else { Get-NextNonDocsKind -ProfileName $ProfileName }
  }
  else {
    $kind = Get-NextNonDocsKind -ProfileName $ProfileName
  }
  if ($kind -eq "docs" -and $ImprovementKind -ne "docs") {
    $state = Get-ImprovementState -ProfileName $ProfileName
    if ([int]$state.docsStreak -ge $MaxConsecutiveDocs) {
      $kind = Get-NextNonDocsKind -ProfileName $ProfileName
    }
  }
  $resolvedScope = if ($Scope) { $Scope } else { Get-ScopeForKind -Kind $kind }
  if ($kind -ne "docs") {
    $resolvedScope = Get-ScopeForKind -Kind $kind
  }
  return [pscustomobject]@{
    Kind = $kind
    Scope = $resolvedScope
  }
}

function Get-NextNonDocsKind {
  param([string]$ProfileName)
  $state = Get-ImprovementState -ProfileName $ProfileName
  $index = [int]$state.nonDocsIndex
  return $NonDocsSequence[$index % $NonDocsSequence.Count]
}

function Update-ImprovementState {
  param(
    [string]$ProfileName,
    [string]$Kind
  )
  $state = Get-ImprovementState -ProfileName $ProfileName
  if ($Kind -eq "docs") {
    $state.docsStreak = [Math]::Min($MaxConsecutiveDocs, ([int]$state.docsStreak + 1))
  }
  elseif ($Kind -in @("feat", "style", "refactor")) {
    $next = ([int]$state.nonDocsIndex + 1) % $NonDocsSequence.Count
    $state.nonDocsIndex = $next
    $state.docsStreak = 0
  }
  $state.lastKind = $Kind
  Save-ImprovementState -ProfileName $ProfileName -State $state
}

function New-ChildArguments {
  param(
    [string]$ProfileName,
    [string]$ResolvedScope,
    [string]$ResolvedImprovementKind
  )
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
  if ($ResolvedScope) {
    $arguments += @("-Scope", $ResolvedScope)
  }
  if ($ResolvedImprovementKind) {
    $arguments += @("-ImprovementKind", $ResolvedImprovementKind)
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
      [string]$MergePollSeconds,
      "-MaxConsecutiveDocs",
      [string]$MaxConsecutiveDocs
    )
    if ($Scope) {
      $arguments += @("-Scope", $Scope)
    }
    if ($ImprovementKind) {
      $arguments += @("-ImprovementKind", $ImprovementKind)
    }
    if ($NonDocsSequence.Count -gt 0) {
      $arguments += "-NonDocsSequence"
      $arguments += ($NonDocsSequence -join ",")
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
      $plan = Resolve-ImprovementPlan -ProfileName $profileName
      Write-Host "=== profile=$profileName iteration=$iteration/$Iterations replacement-attempt=$attemptLabel/$maxAttemptLabel kind=$($plan.Kind) scope=$($plan.Scope) ==="
      $arguments = New-ChildArguments -ProfileName $profileName -ResolvedScope $plan.Scope -ResolvedImprovementKind $plan.Kind

      & powershell @arguments
      $exitCode = $LASTEXITCODE
      if ($exitCode -eq 0) {
        if (-not $DryRun) {
          Update-ImprovementState -ProfileName $profileName -Kind $plan.Kind
        }
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
