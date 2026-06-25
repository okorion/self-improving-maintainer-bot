#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Scope = "docs",
  [string]$TargetRepo = "okorion/action-ledger",
  [string]$BaseBranch = "main",
  [string]$BranchPrefix = "codex/auto-improve",
  [ValidateSet("squash", "merge", "rebase")]
  [string]$MergeMethod = "squash",
  [switch]$AutoMerge,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir = Join-Path $BotRoot "runs\scheduler"
$LockDir = Join-Path $LogDir "auto-improve.lock"
$LogPath = Join-Path $LogDir "$RunId.log"
$CommitTemplate = Join-Path $BotRoot "templates\target-auto-commit-message.md"
$PrTemplate = Join-Path $BotRoot "templates\target-auto-pr-body.md"
$AllowedPathPrefixes = @("README.md", "CONTRIBUTING.md", "docs/")
$TargetVerifyCommands = @(
  "python -m pytest",
  "action-ledger scan README.md docs --format markdown --max-open 30"
)

function Write-Log {
  param([string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  Write-Host $line
  Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
}

function Invoke-CommandLine {
  param(
    [string]$Command,
    [string]$WorkingDirectory
  )
  Write-Log "RUN [$WorkingDirectory] $Command"
  Push-Location $WorkingDirectory
  try {
    & $env:ComSpec /c $Command *>> $LogPath
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
  }
  finally {
    Pop-Location
  }
}

function Invoke-NativeCommand {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )
  $renderedArgs = ($Arguments | ForEach-Object {
    if ($_ -match "\s") { "`"$_`"" } else { $_ }
  }) -join " "
  Write-Log "RUN [$WorkingDirectory] $FilePath $renderedArgs"
  Push-Location $WorkingDirectory
  try {
    & $FilePath @Arguments *>> $LogPath
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $renderedArgs"
    }
  }
  finally {
    Pop-Location
  }
}

function Get-TargetRoot {
  $code = "from self_maintainer_bot.config import load_settings; from self_maintainer_bot.target_repo import target_root; print(target_root(load_settings()))"
  Push-Location $BotRoot
  try {
    $value = python -c $code
    if ($LASTEXITCODE -ne 0 -or -not $value) {
      throw "Failed to resolve target root."
    }
    return (Resolve-Path -LiteralPath $value.Trim()).Path
  }
  finally {
    Pop-Location
  }
}

function Get-ChangedFiles {
  param([string]$TargetRoot)
  Push-Location $TargetRoot
  try {
    $lines = git status --porcelain
    if ($LASTEXITCODE -ne 0) {
      throw "git status failed."
    }
    $paths = @()
    foreach ($line in $lines) {
      if (-not $line) { continue }
      $path = $line.Substring(3)
      if ($path.Contains(" -> ")) {
        $path = ($path -split " -> ")[-1]
      }
      $paths += $path.Replace("\", "/")
    }
    return $paths
  }
  finally {
    Pop-Location
  }
}

function Assert-CleanTarget {
  param([string]$TargetRoot)
  $changed = Get-ChangedFiles -TargetRoot $TargetRoot
  if ($changed.Count -gt 0) {
    throw "Target worktree is not clean. Commit, merge, or discard changes before auto scheduling: $($changed -join ', ')"
  }
}

function Assert-AllowedChanges {
  param([string[]]$ChangedFiles)
  $blocked = @()
  foreach ($path in $ChangedFiles) {
    $ok = $false
    foreach ($prefix in $AllowedPathPrefixes) {
      if ($path -eq $prefix.TrimEnd("/") -or $path.StartsWith($prefix)) {
        $ok = $true
        break
      }
    }
    if (-not $ok) {
      $blocked += $path
    }
  }
  if ($blocked.Count -gt 0) {
    throw "Refusing to publish files outside allowed docs scope: $($blocked -join ', ')"
  }
}

function New-TemplateFile {
  param(
    [string]$TemplatePath,
    [hashtable]$Values
  )
  $text = Get-Content -LiteralPath $TemplatePath -Raw -Encoding utf8
  foreach ($key in $Values.Keys) {
    $text = $text.Replace("{{$key}}", [string]$Values[$key])
  }
  $temp = New-TemporaryFile
  Set-Content -LiteralPath $temp -Value $text -Encoding utf8
  return $temp
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if ($DryRun) {
  Write-Log "Dry run only. No Codex execution, commit, PR, or merge will run."
  Write-Log "Bot root: $BotRoot"
  Write-Log "Target repo: $TargetRepo"
  Write-Log "Scope: $Scope"
  Write-Log "Auto merge: $AutoMerge"
  exit 0
}

New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
try {
  Write-Log "Auto improve run started. run_id=$RunId scope=$Scope auto_merge=$AutoMerge"
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli prepare-target" -WorkingDirectory $BotRoot
  $TargetRoot = Get-TargetRoot
  Assert-CleanTarget -TargetRoot $TargetRoot

  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli eval-docs --fail-under 0" -WorkingDirectory $BotRoot
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli codex-local-loop --scope $Scope --execute" -WorkingDirectory $BotRoot

  $changed = Get-ChangedFiles -TargetRoot $TargetRoot
  if ($changed.Count -eq 0) {
    Write-Log "No target changes detected. Nothing to publish."
    exit 0
  }
  Assert-AllowedChanges -ChangedFiles $changed

  foreach ($command in $TargetVerifyCommands) {
    Invoke-CommandLine -Command $command -WorkingDirectory $TargetRoot
  }
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli eval-docs --fail-under 1" -WorkingDirectory $BotRoot
  Invoke-CommandLine -Command "git diff --check" -WorkingDirectory $TargetRoot

  $branchName = "$BranchPrefix-$RunId"
  Invoke-CommandLine -Command "git switch -c $branchName" -WorkingDirectory $TargetRoot
  foreach ($path in $changed) {
    Invoke-CommandLine -Command "git add -- `"$path`"" -WorkingDirectory $TargetRoot
  }

  $commitFile = New-TemplateFile -TemplatePath $CommitTemplate -Values @{}
  try {
    Invoke-CommandLine -Command "git commit --trailer `"Co-authored-by: Codex`" -F `"$commitFile`"" -WorkingDirectory $TargetRoot
  }
  finally {
    Remove-Item -LiteralPath $commitFile -Force -ErrorAction SilentlyContinue
  }

  Invoke-CommandLine -Command "git push -u origin $branchName" -WorkingDirectory $TargetRoot

  $changedList = ($changed | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine
  $verifyList = ($TargetVerifyCommands + @(
    "python -m self_maintainer_bot.cli eval-docs --fail-under 1",
    "git diff --check"
  ) | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine
  $prBodyFile = New-TemplateFile -TemplatePath $PrTemplate -Values @{
    RUN_ID = $RunId
    SCOPE = $Scope
    CHANGED_FILES = $changedList
    VERIFY_COMMANDS = $verifyList
  }
  $title = (Get-Content -LiteralPath $CommitTemplate -Encoding utf8 | Select-Object -First 1)
  try {
    $prUrl = gh pr create --repo $TargetRepo --base $BaseBranch --head $branchName --title $title --body-file $prBodyFile
    if ($LASTEXITCODE -ne 0 -or -not $prUrl) {
      throw "Failed to create PR."
    }
    Write-Log "PR created: $prUrl"
  }
  finally {
    Remove-Item -LiteralPath $prBodyFile -Force -ErrorAction SilentlyContinue
  }

  if ($AutoMerge) {
    $prNumber = gh pr view $prUrl --repo $TargetRepo --json number --jq ".number"
    if ($LASTEXITCODE -ne 0 -or -not $prNumber) {
      throw "Failed to resolve PR number."
    }
    Invoke-CommandLine -Command "gh pr checks $prNumber --repo $TargetRepo --watch" -WorkingDirectory $TargetRoot

    $mergeArgs = @("pr", "merge", $prNumber, "--repo", $TargetRepo, "--delete-branch")
    $mergeBody = "자동 자가 개선 결과를 병합합니다."
    if ($MergeMethod -eq "squash") {
      $mergeArgs += @("--squash", "--subject", $title, "--body", $mergeBody)
    }
    elseif ($MergeMethod -eq "rebase") {
      $mergeArgs += "--rebase"
    }
    else {
      $mergeArgs += @("--merge", "--subject", $title, "--body", $mergeBody)
    }
    Invoke-NativeCommand -FilePath "gh" -Arguments $mergeArgs -WorkingDirectory $TargetRoot
    Invoke-CommandLine -Command "git switch $BaseBranch" -WorkingDirectory $TargetRoot
    Invoke-CommandLine -Command "git pull --ff-only origin $BaseBranch" -WorkingDirectory $TargetRoot
  }

  Write-Log "Auto improve run completed."
}
finally {
  Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}
