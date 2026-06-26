#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Profile,
  [string]$Scope = "",
  [string]$TargetRepo = "",
  [string]$BaseBranch = "",
  [string]$BranchPrefix = "codex/auto-improve",
  [ValidateSet("squash", "merge", "rebase")]
  [string]$MergeMethod = "squash",
  [switch]$AutoMerge,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$env:Path = @(
  [Environment]::GetEnvironmentVariable("Path", "User"),
  [Environment]::GetEnvironmentVariable("Path", "Machine"),
  $env:Path
) -join ";"

$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$RunId = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir = Join-Path $BotRoot "runs\scheduler"
$LockDir = Join-Path $LogDir "auto-improve.lock"
$LogPath = Join-Path $LogDir "$RunId.log"
$CommitTemplate = Join-Path $BotRoot "templates\target-auto-commit-message.md"
$PrTemplate = Join-Path $BotRoot "templates\target-auto-pr-body.md"

function Write-Log {
  param([string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  Write-Host $line
  Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
}

function Resolve-ProfilePath {
  param([string]$Name)
  if (-not $Name) {
    return $null
  }

  $candidates = @(
    $Name,
    "$Name.json",
    (Join-Path "profiles" $Name),
    (Join-Path "profiles" "$Name.json"),
    (Join-Path "profiles\overtura" "$Name.json")
  )

  foreach ($candidate in $candidates) {
    $path = if ([System.IO.Path]::IsPathRooted($candidate)) {
      $candidate
    }
    else {
      Join-Path $BotRoot $candidate
    }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }

  throw "Target profile not found: $Name"
}

function Get-StringArray {
  param($Value)
  if ($null -eq $Value) {
    return @()
  }
  if ($Value -is [string]) {
    return @([string]$Value)
  }
  return @($Value | ForEach-Object { [string]$_ })
}

function Set-ProcessEnv {
  param(
    [string]$Name,
    [string]$Value
  )
  if ($Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  }
}

function Set-ProcessEnvList {
  param(
    [string]$Name,
    [string[]]$Values
  )
  if ($Values.Count -gt 0) {
    [Environment]::SetEnvironmentVariable($Name, ($Values -join ","), "Process")
  }
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

function Test-PathPattern {
  param(
    [string]$Path,
    [string]$Pattern
  )
  $normalizedPath = $Path.Replace("\", "/")
  $normalizedPattern = $Pattern.Replace("\", "/").Trim()
  if (-not $normalizedPattern) {
    return $false
  }
  if ($normalizedPattern.EndsWith("/**")) {
    $prefix = $normalizedPattern.Substring(0, $normalizedPattern.Length - 3).TrimEnd("/")
    return $normalizedPath -eq $prefix -or $normalizedPath.StartsWith("$prefix/")
  }
  if ($normalizedPattern.EndsWith("/")) {
    return $normalizedPath.StartsWith($normalizedPattern)
  }
  if ($normalizedPattern.Contains("*") -or $normalizedPattern.Contains("?") -or $normalizedPattern.Contains("[")) {
    return $normalizedPath -like $normalizedPattern
  }
  return $normalizedPath -eq $normalizedPattern -or $normalizedPath.StartsWith("$($normalizedPattern.TrimEnd('/'))/")
}

function Test-AnyPathPattern {
  param(
    [string]$Path,
    [string[]]$Patterns
  )
  foreach ($pattern in $Patterns) {
    if (Test-PathPattern -Path $Path -Pattern $pattern) {
      return $true
    }
  }
  return $false
}

function Get-DiffLineCount {
  param(
    [string]$TargetRoot,
    [string[]]$ChangedFiles
  )
  if ($ChangedFiles.Count -eq 0) {
    return 0
  }
  Push-Location $TargetRoot
  try {
    $lines = git diff --numstat -- $ChangedFiles
    $total = 0
    foreach ($line in $lines) {
      $parts = $line -split "`t"
      if ($parts.Count -lt 3) { continue }
      if ($parts[0] -match "^\d+$") { $total += [int]$parts[0] }
      if ($parts[1] -match "^\d+$") { $total += [int]$parts[1] }
    }
    return $total
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
  param(
    [string]$TargetRoot,
    [string[]]$ChangedFiles,
    [string[]]$AllowedPathPatterns,
    [string[]]$DeniedPathPatterns,
    [int]$MaxFiles,
    [int]$MaxLines
  )
  $blocked = @()
  $denied = @()
  foreach ($path in $ChangedFiles) {
    if (Test-AnyPathPattern -Path $path -Patterns $DeniedPathPatterns) {
      $denied += $path
      continue
    }
    if (-not (Test-AnyPathPattern -Path $path -Patterns $AllowedPathPatterns)) {
      $blocked += $path
    }
  }
  if ($denied.Count -gt 0) {
    throw "Refusing to publish denied files: $($denied -join ', ')"
  }
  if ($blocked.Count -gt 0) {
    throw "Refusing to publish files outside allowed scope: $($blocked -join ', ')"
  }
  if ($MaxFiles -gt 0 -and $ChangedFiles.Count -gt $MaxFiles) {
    throw "Refusing to publish too many files: $($ChangedFiles.Count) > $MaxFiles"
  }
  if ($MaxLines -gt 0) {
    $lineCount = Get-DiffLineCount -TargetRoot $TargetRoot -ChangedFiles $ChangedFiles
    if ($lineCount -gt $MaxLines) {
      throw "Refusing to publish too many changed lines: $lineCount > $MaxLines"
    }
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

$ProfilePath = Resolve-ProfilePath -Name $Profile
$ProfileData = $null
if ($ProfilePath) {
  $ProfileData = Get-Content -LiteralPath $ProfilePath -Raw -Encoding utf8 | ConvertFrom-Json
}

if (-not $TargetRepo -and $ProfileData) { $TargetRepo = [string]$ProfileData.repository }
if (-not $TargetRepo) { $TargetRepo = $env:TARGET_REPOSITORY }
if (-not $TargetRepo) { throw "Target repository is required. Pass -Profile or -TargetRepo." }

if (-not $BaseBranch -and $ProfileData) { $BaseBranch = [string]$ProfileData.defaultBranch }
if (-not $BaseBranch) { $BaseBranch = "main" }

if (-not $Scope -and $ProfileData) { $Scope = [string]$ProfileData.scope }
if (-not $Scope) { $Scope = "docs" }

$TargetWorktree = if ($ProfileData -and $ProfileData.worktree) {
  [string]$ProfileData.worktree
}
else {
  "targets/$($TargetRepo.Replace('/', '/'))"
}
$TargetDocPaths = if ($ProfileData -and $ProfileData.docPaths) {
  Get-StringArray $ProfileData.docPaths
}
else {
  @("README.md", "DESIGN.md", "docs", "maintainer-bot")
}
$TargetEvalsPath = if ($ProfileData -and $ProfileData.evalsPath) {
  [string]$ProfileData.evalsPath
}
else {
  "maintainer-bot/evals/docs_qa.jsonl"
}
$AllowedPathPatterns = if ($ProfileData -and $ProfileData.allowPaths) {
  Get-StringArray $ProfileData.allowPaths
}
else {
  @("README.md", "CONTRIBUTING.md", "docs/**", "maintainer-bot/**")
}
$DeniedPathPatterns = if ($ProfileData -and $ProfileData.denyPaths) {
  Get-StringArray $ProfileData.denyPaths
}
else {
  @(".github/workflows/**", "CODEOWNERS", ".env*", ".npmrc", "infra/**", "terraform/**", "k8s/**", "migrations/**", "**/auth/**", "**/security/**", "*.pem", "*.key")
}
$TargetVerifyCommands = if ($ProfileData -and $ProfileData.verifyCommands) {
  Get-StringArray $ProfileData.verifyCommands
}
else {
  @("pnpm install --frozen-lockfile || pnpm install", "pnpm check")
}
$MaxFiles = if ($ProfileData -and $ProfileData.maxFiles) { [int]$ProfileData.maxFiles } else { 20 }
$MaxLines = if ($ProfileData -and $ProfileData.maxLines) { [int]$ProfileData.maxLines } else { 500 }
$ProfileAutoMerge = if ($ProfileData -and $null -ne $ProfileData.autoMerge) { [bool]$ProfileData.autoMerge } else { $false }
$ResolvedAutoMerge = $AutoMerge.IsPresent -or $ProfileAutoMerge

Set-ProcessEnv -Name "TARGET_REPOSITORY" -Value $TargetRepo
Set-ProcessEnv -Name "TARGET_DEFAULT_BRANCH" -Value $BaseBranch
Set-ProcessEnv -Name "TARGET_WORKTREE" -Value $TargetWorktree
Set-ProcessEnv -Name "TARGET_EVALS_PATH" -Value $TargetEvalsPath
Set-ProcessEnvList -Name "TARGET_DOC_PATHS" -Values $TargetDocPaths
Set-ProcessEnvList -Name "TARGET_ALLOWED_PATHS" -Values $AllowedPathPatterns
Set-ProcessEnvList -Name "TARGET_DENY_PATHS" -Values $DeniedPathPatterns
Set-ProcessEnv -Name "TARGET_MAX_FILES" -Value ([string]$MaxFiles)
Set-ProcessEnv -Name "TARGET_MAX_LINES" -Value ([string]$MaxLines)

if ($DryRun) {
  $profileLabel = if ($ProfilePath) { $ProfilePath } else { "(none)" }
  Write-Log "Dry run only. No Codex execution, commit, PR, or merge will run."
  Write-Log "Bot root: $BotRoot"
  Write-Log "Profile: $profileLabel"
  Write-Log "Target repo: $TargetRepo"
  Write-Log "Scope: $Scope"
  Write-Log "Base branch: $BaseBranch"
  Write-Log "Allowed paths: $($AllowedPathPatterns -join ', ')"
  Write-Log "Denied paths: $($DeniedPathPatterns -join ', ')"
  Write-Log "Max files: $MaxFiles"
  Write-Log "Max lines: $MaxLines"
  Write-Log "Auto merge: $ResolvedAutoMerge"
  exit 0
}

New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
try {
  Write-Log "Auto improve run started. run_id=$RunId profile=$Profile target=$TargetRepo scope=$Scope auto_merge=$ResolvedAutoMerge"
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
  Assert-AllowedChanges `
    -TargetRoot $TargetRoot `
    -ChangedFiles $changed `
    -AllowedPathPatterns $AllowedPathPatterns `
    -DeniedPathPatterns $DeniedPathPatterns `
    -MaxFiles $MaxFiles `
    -MaxLines $MaxLines

  foreach ($command in $TargetVerifyCommands) {
    Invoke-CommandLine -Command $command -WorkingDirectory $TargetRoot
  }
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli eval-docs --fail-under 1" -WorkingDirectory $BotRoot
  Invoke-CommandLine -Command "git diff --check" -WorkingDirectory $TargetRoot

  $safeTarget = $TargetRepo.Replace("/", "-")
  $branchName = "$BranchPrefix-$safeTarget-$RunId"
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
    PROFILE = if ($Profile) { $Profile } else { "(none)" }
    TARGET_REPOSITORY = $TargetRepo
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

  if ($ResolvedAutoMerge) {
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
catch {
  Write-Log "ERROR $($_.Exception.Message)"
  if ($_.ScriptStackTrace) {
    Write-Log $_.ScriptStackTrace
  }
  throw
}
finally {
  Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}
