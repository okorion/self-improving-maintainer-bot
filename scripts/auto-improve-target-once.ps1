#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Profile,
  [string]$Scope = "",
  [string]$TargetRepo = "",
  [string]$BaseBranch = "",
  [string]$BranchPrefix = "codex/auto-improve",
  [ValidateSet("all", "worker", "publisher")]
  [string]$Phase = "all",
  [string]$PatchArtifact = "",
  [string]$PublisherTokenEnv = "PUBLISH_GITHUB_TOKEN",
  [string]$PublisherFallbackTokenEnv = "BOT_GITHUB_TOKEN",
  [switch]$AllowLocalPublisherAuth,
  [string]$RedteamStatusContext = "codex-redteam",
  [switch]$SkipRedteam,
  [int]$MaxReviewResponses = 2,
  [bool]$ClosePrOnReviewFailure = $true,
  [int]$ReviewFailureExitCode = 20,
  [int]$MergeWaitTimeoutSeconds = 900,
  [int]$MergePollSeconds = 15,
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
$RunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$LogDir = Join-Path $BotRoot "runs\scheduler"
$LockDir = Join-Path $LogDir "auto-improve.lock"
$LogPath = Join-Path $LogDir "$RunId.log"
$PatchPath = Join-Path $LogDir "$RunId.patch"
$RiskJsonPath = Join-Path $LogDir "$RunId-risk.json"
$RiskMarkdownPath = Join-Path $LogDir "$RunId-risk.md"
$RedteamPromptPath = Join-Path $LogDir "$RunId-redteam-prompt.md"
$RedteamReportPath = Join-Path $LogDir "$RunId-redteam-report.md"
$RedteamLastMessagePath = Join-Path $LogDir "$RunId-redteam-last-message.md"
$ReviewResponseSummaryPath = Join-Path $LogDir "$RunId-review-response-summary.md"
$CommitTemplate = Join-Path $BotRoot "templates\target-auto-commit-message.md"
$PrTemplate = Join-Path $BotRoot "templates\target-auto-pr-body.md"
$ReviewResponseCommitTemplate = Join-Path $BotRoot "templates\review-response-commit-message.md"
$RedteamPassHandlingTemplate = Join-Path $BotRoot "templates\redteam-pass-handling-comment.md"
$RedteamResponseHandlingTemplate = Join-Path $BotRoot "templates\redteam-response-handling-comment.md"

function New-UnicodeString {
  param([int[]]$CodePoints)
  return -join ($CodePoints | ForEach-Object { [string][char]$_ })
}

function Get-NoneListItem {
  return "- $(New-UnicodeString @(0xC5C6, 0xC74C))"
}

function Get-MergeBodyText {
  return New-UnicodeString @(
    0xC790, 0xB3D9, 0x20, 0xC790, 0xAC00, 0x20,
    0xAC1C, 0xC120, 0x20, 0xACB0, 0xACFC, 0xB97C, 0x20,
    0xBCD1, 0xD569, 0xD569, 0xB2C8, 0xB2E4, 0x002E
  )
}

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
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $env:ComSpec /c $Command *>> $LogPath
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
      throw "Command failed with exit code ${exitCode}: $Command"
    }
  }
  finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
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
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $FilePath @Arguments *>> $LogPath
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
      throw "Command failed with exit code ${exitCode}: $FilePath $renderedArgs"
    }
  }
  finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }
}

function Invoke-GitPush {
  param(
    [string]$BranchName,
    [string]$WorkingDirectory,
    [string]$Token
  )
  Write-Log "RUN [$WorkingDirectory] git push --set-upstream origin $BranchName"
  Push-Location $WorkingDirectory
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if ($Token) {
      $encoded = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
      git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $encoded" push --set-upstream origin $BranchName *>> $LogPath
    }
    else {
      git push --set-upstream origin $BranchName *>> $LogPath
    }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
      throw "git push failed with exit code ${exitCode}: $BranchName"
    }
  }
  finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }
}

function Invoke-GhNative {
  param([string[]]$Arguments)
  Invoke-NativeCommand -FilePath "gh" -Arguments $Arguments -WorkingDirectory $BotRoot
}

function Invoke-GhOutput {
  param(
    [string[]]$Arguments,
    [string]$WorkingDirectory = $BotRoot
  )
  $renderedArgs = ($Arguments | ForEach-Object {
    if ($_ -match "\s") { "`"$_`"" } else { $_ }
  }) -join " "
  Write-Log "RUN [$WorkingDirectory] gh $renderedArgs"
  Push-Location $WorkingDirectory
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = gh @Arguments 2>> $LogPath
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($exitCode -ne 0) {
      throw "gh failed with exit code ${exitCode}: $renderedArgs"
    }
    return ($output -join [Environment]::NewLine)
  }
  finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }
}

function Get-PublisherToken {
  $token = [Environment]::GetEnvironmentVariable($PublisherTokenEnv, "Process")
  if (-not $token) {
    $token = [Environment]::GetEnvironmentVariable($PublisherTokenEnv, "User")
  }
  if (-not $token) {
    $token = [Environment]::GetEnvironmentVariable($PublisherFallbackTokenEnv, "Process")
  }
  if (-not $token) {
    $token = [Environment]::GetEnvironmentVariable($PublisherFallbackTokenEnv, "User")
  }
  return $token
}

function Set-PublisherIdentity {
  $token = Get-PublisherToken
  if ($token) {
    [Environment]::SetEnvironmentVariable("GH_TOKEN", $token, "Process")
    Write-Log "Publisher identity: $PublisherTokenEnv/$PublisherFallbackTokenEnv token loaded for publish phase."
  }
  elseif (-not $AllowLocalPublisherAuth) {
    throw "Publisher token not found. Set $PublisherTokenEnv or $PublisherFallbackTokenEnv, or pass -AllowLocalPublisherAuth for local gh/git fallback."
  }
  else {
    Write-Log "WARNING Publisher token not found. Falling back to explicit local gh/git authentication."
  }
  return $token
}

function Invoke-WithPublisherEnvCleared {
  param([scriptblock]$Script)
  $names = @($PublisherTokenEnv, $PublisherFallbackTokenEnv, "GH_TOKEN") | Select-Object -Unique
  $saved = @{}
  foreach ($name in $names) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    [Environment]::SetEnvironmentVariable($name, $null, "Process")
  }
  try {
    & $Script
  }
  finally {
    foreach ($name in $names) {
      [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process")
    }
  }
}

function Set-CommitStatus {
  param(
    [string]$Repo,
    [string]$Sha,
    [ValidateSet("error", "failure", "pending", "success")]
    [string]$State,
    [string]$Context,
    [string]$Description
  )
  $arguments = @(
    "api", "-X", "POST", "repos/$Repo/statuses/$Sha",
    "-f", "state=$State",
    "-f", "context=$Context",
    "-f", "description=$Description"
  )
  try {
    Invoke-GhNative -Arguments $arguments
    return
  }
  catch {
    $publisherError = $_.Exception.Message
    $processGhToken = [Environment]::GetEnvironmentVariable("GH_TOKEN", "Process")
    if ($processGhToken -and $AllowLocalPublisherAuth) {
      Write-Log "WARNING Commit status update failed with publisher token; retrying with local gh auth. $publisherError"
      [Environment]::SetEnvironmentVariable("GH_TOKEN", $null, "Process")
      try {
        Invoke-GhNative -Arguments $arguments
        return
      }
      catch {
        Write-Log "WARNING Commit status update failed with local gh auth too; continuing without status context. $($_.Exception.Message)"
        return
      }
      finally {
        [Environment]::SetEnvironmentVariable("GH_TOKEN", $processGhToken, "Process")
      }
    }

    Write-Log "WARNING Commit status update failed; continuing without status context. $publisherError"
    return
  }
}

function Get-CodexExecutable {
  $configured = [Environment]::GetEnvironmentVariable("CODEX_CLI", "Process")
  if (-not $configured) {
    $configured = [Environment]::GetEnvironmentVariable("CODEX_CLI", "User")
  }
  if ($configured) {
    return $configured
  }
  $command = Get-Command codex -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }
  return "codex"
}

function Get-AttemptArtifactPath {
  param(
    [string]$Name,
    [int]$Attempt,
    [string]$Extension = "md"
  )
  return (Join-Path $LogDir "$RunId-$Name-attempt-$Attempt.$Extension")
}

function Get-RedteamDecision {
  param([string]$ReportPath)
  if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    return "FAIL"
  }
  $matches = Select-String -LiteralPath $ReportPath -Pattern "REDTEAM_DECISION:\s*(PASS|FAIL)" -AllMatches
  if (-not $matches) {
    return "FAIL"
  }
  $last = @($matches)[-1]
  $value = $last.Matches[$last.Matches.Count - 1].Groups[1].Value
  if ($value -eq "PASS") {
    return "PASS"
  }
  return "FAIL"
}

function Invoke-CodexRedteamReview {
  param(
    [string]$TargetRoot,
    [string]$Repo,
    [string]$PrNumber,
    [string]$CommitSha,
    [object]$Risk,
    [string]$DiffStat,
    [string]$DiffNumstat,
    [string[]]$ChangedFiles,
    [int]$Attempt
  )

  $attemptPromptPath = Get-AttemptArtifactPath -Name "redteam-prompt" -Attempt $Attempt
  $attemptReportPath = Get-AttemptArtifactPath -Name "redteam-report" -Attempt $Attempt
  $attemptLastMessagePath = Get-AttemptArtifactPath -Name "redteam-last-message" -Attempt $Attempt
  $changedText = ($ChangedFiles | ForEach-Object { "- $_" }) -join [Environment]::NewLine
  $deniedText = if ($Risk.denied_files.Count -gt 0) { ($Risk.denied_files | ForEach-Object { "- $_" }) -join [Environment]::NewLine } else { "- none" }
  $outsideText = if ($Risk.disallowed_files.Count -gt 0) { ($Risk.disallowed_files | ForEach-Object { "- $_" }) -join [Environment]::NewLine } else { "- none" }
  $prompt = @"
# Codex Red-Team Review

You are the red-team reviewer for an automated self-improvement pull request.
Run in read-only mode. Do not edit files, create commits, push, merge, or print secrets.
Write the review in Korean.

## Target

- repository: $Repo
- pull request: #$PrNumber
- commit: $CommitSha
- attempt: $Attempt
- max risk: $($Risk.max_risk)
- publish mode: $($Risk.publish_mode)
- changed files: $($Risk.changed_file_count)
- changed lines: $($Risk.changed_line_count)

## Changed Files

$changedText

## Denied Files

$deniedText

## Outside allowPaths

$outsideText

## Diff Stat

````text
$DiffStat
````

## Diff Numstat

````text
$DiffNumstat
````

## Review Checklist

Check for:

1. R3-sensitive edits that escaped policy.
2. secret, credential, token, auth, workflow, infra, or migration risk.
3. dependency/build/script changes that should not auto-merge as R1.
4. accidental broad rewrites or unrelated files.
5. broken Korean documentation, obvious UI copy regressions, or invalid project instructions.
6. mismatch between the PR body, risk report, and actual diff.

Decision rules:

- PASS only when the diff is safe to merge automatically under the current publish mode.
- FAIL if you are unsure, if a protected path is present, if required evidence is missing, or if the change needs human judgment.
- R2 draft PRs may pass review, but they must not auto-merge.
- R3/proposal-only changes must fail if they reach this review.

Return a concise Markdown report with sections:

- Korean conclusion
- Key findings
- Risk/blocking reasons
- Recommended follow-up

The final line must be exactly one of:

REDTEAM_DECISION: PASS
REDTEAM_DECISION: FAIL
"@
  [System.IO.File]::WriteAllText($attemptPromptPath, $prompt, [System.Text.UTF8Encoding]::new($false))
  Copy-Item -LiteralPath $attemptPromptPath -Destination $RedteamPromptPath -Force

  $codex = Get-CodexExecutable
  Write-Log "RUN [$TargetRoot] codex red-team review attempt=$Attempt"
  Push-Location $TargetRoot
  try {
    $inputText = Get-Content -LiteralPath $attemptPromptPath -Raw -Encoding utf8
    $script:CodexRedteamExitCode = 0
    Invoke-WithPublisherEnvCleared {
      $previousErrorActionPreference = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      $inputText | & $codex exec --cd $TargetRoot --sandbox read-only --output-last-message $attemptLastMessagePath - *>> $LogPath
      $script:CodexRedteamExitCode = $LASTEXITCODE
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($script:CodexRedteamExitCode -ne 0) {
      "Codex red-team review failed with exit code $($script:CodexRedteamExitCode)." | Set-Content -LiteralPath $attemptReportPath -Encoding utf8
      Copy-Item -LiteralPath $attemptReportPath -Destination $RedteamReportPath -Force
      return [pscustomobject]@{
        Decision = "FAIL"
        ReportPath = $attemptReportPath
      }
    }
  }
  finally {
    Pop-Location
  }

  if (Test-Path -LiteralPath $attemptLastMessagePath -PathType Leaf) {
    Copy-Item -LiteralPath $attemptLastMessagePath -Destination $attemptReportPath -Force
  }
  else {
    "Codex red-team review did not produce a last-message report." | Set-Content -LiteralPath $attemptReportPath -Encoding utf8
  }
  Copy-Item -LiteralPath $attemptReportPath -Destination $RedteamReportPath -Force
  return [pscustomobject]@{
    Decision = Get-RedteamDecision -ReportPath $attemptReportPath
    ReportPath = $attemptReportPath
  }
}

function Add-RedteamPrComment {
  param(
    [string]$Repo,
    [string]$PrNumber,
    [string]$Decision,
    [string]$ReportPath,
    [int]$Attempt
  )
  $report = if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
    Get-Content -LiteralPath $ReportPath -Raw -Encoding utf8
  }
  else {
    "No red-team report was generated."
  }
  if ($report.Length -gt 6000) {
    $report = $report.Substring(0, 6000) + "`n`n...(truncated)"
  }

  $body = @"
## Codex Red-Team Review

- decision: `$Decision`
- attempt: `$Attempt`
- status context: `$RedteamStatusContext`
- local report: `$ReportPath`

$report
"@
  $bodyFile = New-TemporaryFile
  try {
    [System.IO.File]::WriteAllText($bodyFile.FullName, $body, [System.Text.UTF8Encoding]::new($false))
    $commentId = Invoke-GhOutput -Arguments @(
      "api", "-X", "POST", "repos/$Repo/issues/$PrNumber/comments",
      "-H", "Accept: application/vnd.github+json",
      "-F", "body=@$($bodyFile.FullName)",
      "--jq", ".id"
    )
    return ($commentId.Trim())
  }
  finally {
    Remove-Item -LiteralPath $bodyFile.FullName -Force -ErrorAction SilentlyContinue
  }
}

function Add-IssueCommentReaction {
  param(
    [string]$Repo,
    [string]$CommentId,
    [string]$Content
  )
  if (-not $CommentId) {
    return
  }
  try {
    Invoke-GhNative -Arguments @(
      "api", "-X", "POST", "repos/$Repo/issues/comments/$CommentId/reactions",
      "-H", "Accept: application/vnd.github+json",
      "-f", "content=$Content"
    )
  }
  catch {
    Write-Log "WARNING Failed to add reaction '$Content' to comment $CommentId. $($_.Exception.Message)"
  }
}

function Add-RedteamHandlingComment {
  param(
    [string]$Repo,
    [string]$PrNumber,
    [string]$RedteamCommentId,
    [ValidateSet("pass", "response")]
    [string]$Outcome,
    [int]$Attempt,
    [string]$CommitSha = "",
    [string]$SummaryPath = ""
  )
  $templatePath = if ($Outcome -eq "pass") { $RedteamPassHandlingTemplate } else { $RedteamResponseHandlingTemplate }
  $bodyFile = New-TemplateFile -TemplatePath $templatePath -Values @{
    REDTEAM_COMMENT_ID = if ($RedteamCommentId) { $RedteamCommentId } else { "n/a" }
    ATTEMPT = $Attempt
    COMMIT_SHA = if ($CommitSha) { $CommitSha } else { "n/a" }
    SUMMARY_PATH = if ($SummaryPath) { $SummaryPath } else { "n/a" }
  }
  try {
    Invoke-GhNative -Arguments @("pr", "comment", $PrNumber, "--repo", $Repo, "--body-file", $bodyFile)
  }
  finally {
    Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-CodexReviewResponse {
  param(
    [string]$TargetRoot,
    [string]$Repo,
    [string]$PrNumber,
    [string]$CommitSha,
    [string]$ReportPath,
    [string]$DiffStat,
    [string]$DiffNumstat,
    [string[]]$ChangedFiles,
    [string[]]$AllowedPathPatterns,
    [string[]]$DeniedPathPatterns,
    [int]$Attempt
  )

  $attemptPromptPath = Get-AttemptArtifactPath -Name "review-response-prompt" -Attempt $Attempt
  $attemptSummaryPath = Get-AttemptArtifactPath -Name "review-response-summary" -Attempt $Attempt
  $attemptLastMessagePath = Get-AttemptArtifactPath -Name "review-response-last-message" -Attempt $Attempt
  $changedText = ($ChangedFiles | ForEach-Object { "- $_" }) -join [Environment]::NewLine
  $allowedText = ($AllowedPathPatterns | ForEach-Object { "- $_" }) -join [Environment]::NewLine
  $deniedText = ($DeniedPathPatterns | ForEach-Object { "- $_" }) -join [Environment]::NewLine
  $report = if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
    Get-Content -LiteralPath $ReportPath -Raw -Encoding utf8
  }
  else {
    "No red-team report file was found."
  }

  $prompt = @"
# Codex Review Response

You are responding to a red-team review on an automated self-improvement pull request.
Write the response summary in Korean.
You may edit files in the target repository, but you must not commit, push, merge, create pull requests, change remotes, or print secrets.
Do not read or use publisher tokens. Stay within the allowed paths.

## Target

- repository: $Repo
- pull request: #$PrNumber
- current commit: $CommitSha
- response attempt: $Attempt

## Allowed Paths

$allowedText

## Denied Paths

$deniedText

## Pull Request Changed Files

$changedText

## Current PR Diff Stat

````text
$DiffStat
````

## Current PR Diff Numstat

````text
$DiffNumstat
````

## Red-Team Report To Address

````markdown
$report
````

## Required Workflow

1. Inspect only the files needed to address the red-team findings.
2. Make the smallest safe correction within the allowed paths.
3. Do not broaden the PR scope.
4. If the finding requires a denied path, secret, workflow, auth, infra, migration, or dependency change, leave the worktree unchanged and explain that it requires human handling.
5. Do not commit, push, merge, or create/update pull requests.
6. Finish with a concise Korean summary of changed files and remaining risk.
"@

  [System.IO.File]::WriteAllText($attemptPromptPath, $prompt, [System.Text.UTF8Encoding]::new($false))

  $codex = Get-CodexExecutable
  Write-Log "RUN [$TargetRoot] codex review-response attempt=$Attempt"
  Push-Location $TargetRoot
  try {
    $inputText = Get-Content -LiteralPath $attemptPromptPath -Raw -Encoding utf8
    $script:CodexReviewResponseExitCode = 0
    Invoke-WithPublisherEnvCleared {
      $previousErrorActionPreference = $ErrorActionPreference
      $ErrorActionPreference = "Continue"
      $inputText | & $codex exec --cd $TargetRoot --sandbox workspace-write --full-auto --output-last-message $attemptLastMessagePath - *>> $LogPath
      $script:CodexReviewResponseExitCode = $LASTEXITCODE
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($script:CodexReviewResponseExitCode -ne 0) {
      "Codex review response failed with exit code $($script:CodexReviewResponseExitCode)." | Set-Content -LiteralPath $attemptSummaryPath -Encoding utf8
      Copy-Item -LiteralPath $attemptSummaryPath -Destination $ReviewResponseSummaryPath -Force
      throw "Codex review response failed. See $attemptSummaryPath"
    }
  }
  finally {
    Pop-Location
  }

  if (Test-Path -LiteralPath $attemptLastMessagePath -PathType Leaf) {
    Copy-Item -LiteralPath $attemptLastMessagePath -Destination $attemptSummaryPath -Force
  }
  else {
    "Codex review response did not produce a last-message summary." | Set-Content -LiteralPath $attemptSummaryPath -Encoding utf8
  }
  Copy-Item -LiteralPath $attemptSummaryPath -Destination $ReviewResponseSummaryPath -Force
  return $attemptSummaryPath
}

function Add-ReviewResponsePrComment {
  param(
    [string]$Repo,
    [string]$PrNumber,
    [string]$SummaryPath,
    [string[]]$ChangedFiles,
    [int]$Attempt
  )
  $summary = if (Test-Path -LiteralPath $SummaryPath -PathType Leaf) {
    Get-Content -LiteralPath $SummaryPath -Raw -Encoding utf8
  }
  else {
    "No review-response summary was generated."
  }
  if ($summary.Length -gt 6000) {
    $summary = $summary.Substring(0, 6000) + "`n`n...(truncated)"
  }
  $changedText = if ($ChangedFiles.Count -gt 0) {
    ($ChangedFiles | ForEach-Object { "- $_" }) -join [Environment]::NewLine
  }
  else {
    "- none"
  }

  $body = @"
## Codex Review Response

- attempt: `$Attempt`
- local summary: `$SummaryPath`

Changed files:

$changedText

$summary
"@
  $bodyFile = New-TemporaryFile
  try {
    [System.IO.File]::WriteAllText($bodyFile, $body, [System.Text.UTF8Encoding]::new($false))
    Invoke-GhNative -Arguments @("pr", "comment", $PrNumber, "--repo", $Repo, "--body-file", $bodyFile)
  }
  finally {
    Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
  }
}

function Get-PullRequestChangedFiles {
  param(
    [string]$TargetRoot,
    [string]$BaseBranch
  )
  $output = Get-GitOutput -Arguments @("diff", "--name-only", "$BaseBranch...HEAD") -WorkingDirectory $TargetRoot
  if (-not $output) {
    return @()
  }
  return @($output -split "\r?\n" | Where-Object { $_ } | ForEach-Object { $_.Replace("\", "/") })
}

function Get-PullRequestDiffStat {
  param(
    [string]$TargetRoot,
    [string]$BaseBranch
  )
  return Get-GitOutput -Arguments @("diff", "$BaseBranch...HEAD", "--stat") -WorkingDirectory $TargetRoot
}

function Get-PullRequestDiffNumstat {
  param(
    [string]$TargetRoot,
    [string]$BaseBranch
  )
  return Get-GitOutput -Arguments @("diff", "$BaseBranch...HEAD", "--numstat") -WorkingDirectory $TargetRoot
}

function Wait-ForPullRequestMerged {
  param(
    [string]$Repo,
    [string]$PrNumber,
    [int]$TimeoutSeconds,
    [int]$PollSeconds
  )
  if ($TimeoutSeconds -le 0) {
    Write-Log "Merge wait disabled. Not polling PR #$PrNumber."
    return
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ($true) {
    $jsonText = Invoke-GhOutput -Arguments @("pr", "view", $PrNumber, "--repo", $Repo, "--json", "state,mergeStateStatus,url")
    $data = $jsonText | ConvertFrom-Json
    Write-Log "PR #$PrNumber state=$($data.state) mergeStateStatus=$($data.mergeStateStatus)"
    if ($data.state -eq "MERGED") {
      Write-Log "PR #$PrNumber merged."
      return
    }
    if ($data.state -eq "CLOSED") {
      throw "PR #$PrNumber closed before merge."
    }
    if ((Get-Date) -ge $deadline) {
      throw "Timed out waiting for PR #$PrNumber to merge after $TimeoutSeconds seconds."
    }
    Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
  }
}

function Switch-TargetToBaseForReplacement {
  param(
    [string]$TargetRoot,
    [string]$BaseBranch,
    [string]$BranchName
  )
  Write-Log "Preparing target worktree for replacement attempt."
  Push-Location $TargetRoot
  try {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    git switch $BaseBranch *>> $LogPath
    if ($LASTEXITCODE -ne 0) {
      Write-Log "Clean switch to $BaseBranch failed; forcing switch because the current branch only contains generated failed-review changes."
      git switch -f $BaseBranch *>> $LogPath
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to switch target worktree to $BaseBranch."
      }
    }

    git pull --ff-only origin $BaseBranch *>> $LogPath
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to fast-forward target worktree base branch."
    }

    git branch -D $BranchName *>> $LogPath
    if ($LASTEXITCODE -ne 0) {
      Write-Log "Local branch cleanup skipped or failed for $BranchName."
    }

    $remaining = git status --porcelain
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to inspect target worktree after replacement cleanup."
    }
    if ($remaining) {
      Write-Log "Cleaning generated untracked leftovers before replacement attempt."
      git clean -fd *>> $LogPath
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to clean generated target leftovers."
      }
    }
  }
  finally {
    if ($null -ne $previousErrorActionPreference) {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    Pop-Location
  }
  Assert-CleanTarget -TargetRoot $TargetRoot
}

function Close-ReviewFailedPullRequest {
  param(
    [string]$Repo,
    [string]$PrNumber,
    [string]$BranchName,
    [string]$TargetRoot,
    [string]$BaseBranch,
    [string]$Reason,
    [string]$ReportPath
  )
  if (-not $ClosePrOnReviewFailure) {
    throw $Reason
  }

  $comment = "Codex red-team review response limit was reached. Closing this PR and allowing the scheduler to search for a new improvement candidate. Reason: $Reason"
  if ($ReportPath) {
    $comment = "$comment Report: $ReportPath"
  }
  Write-Log "Closing PR #$PrNumber after review failure: $Reason"
  Invoke-GhNative -Arguments @("pr", "close", $PrNumber, "--repo", $Repo, "--comment", $comment, "--delete-branch")
  Switch-TargetToBaseForReplacement -TargetRoot $TargetRoot -BaseBranch $BaseBranch -BranchName $BranchName
  Write-Log "Closed PR #$PrNumber. Exiting with review failure code $ReviewFailureExitCode so the batch runner can open a replacement PR."
  exit $ReviewFailureExitCode
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

function Get-GitOutput {
  param(
    [string[]]$Arguments,
    [string]$WorkingDirectory
  )
  Push-Location $WorkingDirectory
  try {
    $output = git @Arguments
    if ($LASTEXITCODE -ne 0) {
      throw "git $($Arguments -join ' ') failed."
    }
    return ($output -join [Environment]::NewLine)
  }
  finally {
    Pop-Location
  }
}

function Save-PatchArtifact {
  param(
    [string]$TargetRoot,
    [string]$OutputPath
  )
  Push-Location $TargetRoot
  try {
    & $env:ComSpec /c "git diff --binary > `"$OutputPath`""
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to write patch artifact: $OutputPath"
    }
  }
  finally {
    Pop-Location
  }
}

function Apply-PatchArtifact {
  param(
    [string]$TargetRoot,
    [string]$InputPath
  )
  if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Patch artifact not found: $InputPath"
  }
  Invoke-NativeCommand -FilePath "git" -Arguments @("apply", "--check", $InputPath) -WorkingDirectory $TargetRoot
  Invoke-NativeCommand -FilePath "git" -Arguments @("apply", $InputPath) -WorkingDirectory $TargetRoot
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

function Invoke-RiskClassifier {
  param(
    [string]$Scope
  )
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli classify-target-changes --scope $Scope --output-json `"$RiskJsonPath`" --output-md `"$RiskMarkdownPath`"" -WorkingDirectory $BotRoot
  return Get-Content -LiteralPath $RiskJsonPath -Raw -Encoding utf8 | ConvertFrom-Json
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
  [System.IO.File]::WriteAllText([string]$temp, $text, [System.Text.UTF8Encoding]::new($false))
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
  @(".github/workflows/**", ".github/CODEOWNERS", "CODEOWNERS", ".env*", ".npmrc", "infra/**", "terraform/**", "k8s/**", "migrations/**", "**/auth/**", "**/security/**", "*.pem", "*.key")
}
$TargetVerifyCommands = if ($ProfileData -and $ProfileData.verifyCommands) {
  Get-StringArray $ProfileData.verifyCommands
}
else {
  @("pnpm install --frozen-lockfile || pnpm install", "pnpm check")
}
$LockDir = Join-Path $LogDir ("auto-improve-$($TargetRepo.Replace('/', '-')).lock")
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
  Write-Log "Phase: $Phase"
  Write-Log "Allow local publisher auth: $($AllowLocalPublisherAuth.IsPresent)"
  Write-Log "Red-team status context: $RedteamStatusContext"
  Write-Log "Skip red-team: $($SkipRedteam.IsPresent)"
  Write-Log "Max review responses: $MaxReviewResponses"
  Write-Log "Close PR on review failure: $ClosePrOnReviewFailure"
  Write-Log "Review failure exit code: $ReviewFailureExitCode"
  Write-Log "Merge wait timeout seconds: $MergeWaitTimeoutSeconds"
  Write-Log "Merge poll seconds: $MergePollSeconds"
  exit 0
}

New-Item -ItemType Directory -Path $LockDir -ErrorAction Stop | Out-Null
try {
  Write-Log "Auto improve run started. run_id=$RunId profile=$Profile target=$TargetRepo scope=$Scope auto_merge=$ResolvedAutoMerge"
  Invoke-CommandLine -Command "python -m self_maintainer_bot.cli prepare-target" -WorkingDirectory $BotRoot
  $TargetRoot = Get-TargetRoot
  Assert-CleanTarget -TargetRoot $TargetRoot
  $InputCommit = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $TargetRoot
  $ProfileVersion = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $BotRoot

  if ($Phase -eq "publisher") {
    if (-not $PatchArtifact) {
      throw "-Phase publisher requires -PatchArtifact."
    }
    Apply-PatchArtifact -TargetRoot $TargetRoot -InputPath $PatchArtifact
  }
  else {
    Invoke-WithPublisherEnvCleared {
      Invoke-CommandLine -Command "python -m self_maintainer_bot.cli eval-docs --fail-under 0" -WorkingDirectory $BotRoot
      Invoke-CommandLine -Command "python -m self_maintainer_bot.cli codex-local-loop --scope $Scope --execute" -WorkingDirectory $BotRoot
    }
  }

  $changed = Get-ChangedFiles -TargetRoot $TargetRoot
  if ($changed.Count -eq 0) {
    Write-Log "No target changes detected. Nothing to publish."
    exit 0
  }
  Save-PatchArtifact -TargetRoot $TargetRoot -OutputPath $PatchPath
  $Risk = Invoke-RiskClassifier -Scope $Scope
  Write-Log "Risk classification: max_risk=$($Risk.max_risk) publish_mode=$($Risk.publish_mode)"

  if ($Phase -eq "worker") {
    Write-Log "Worker phase completed. Patch artifact: $PatchPath"
    Write-Log "Risk report: $RiskMarkdownPath"
    exit 0
  }

  if ($Risk.publish_mode -eq "proposal_only") {
    Write-Log "Risk policy selected proposal_only. Refusing automatic publish. Patch artifact: $PatchPath"
    Write-Log "Risk report: $RiskMarkdownPath"
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
  $DiffStat = Get-GitOutput -Arguments @("diff", "--stat") -WorkingDirectory $TargetRoot
  $DiffNumstat = Get-GitOutput -Arguments @("diff", "--numstat") -WorkingDirectory $TargetRoot

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

  $PublisherToken = Set-PublisherIdentity
  Invoke-GitPush -BranchName $branchName -WorkingDirectory $TargetRoot -Token $PublisherToken
  $headSha = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $TargetRoot

  $changedList = ($changed | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine
  $verifyList = ($TargetVerifyCommands + @(
    "python -m self_maintainer_bot.cli eval-docs --fail-under 1",
    "git diff --check"
  ) | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine
  $prBodyFile = New-TemplateFile -TemplatePath $PrTemplate -Values @{
    RUN_ID = $RunId
    PROFILE = if ($Profile) { $Profile } else { "(none)" }
    TARGET_REPOSITORY = $TargetRepo
    INPUT_COMMIT = $InputCommit
    PROFILE_VERSION = $ProfileVersion
    SCOPE = $Scope
    MAX_RISK = $Risk.max_risk
    PUBLISH_MODE = $Risk.publish_mode
    CHANGED_FILE_COUNT = $Risk.changed_file_count
    CHANGED_LINE_COUNT = $Risk.changed_line_count
    DENIED_FILES = if ($Risk.denied_files.Count -gt 0) { ($Risk.denied_files | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine } else { Get-NoneListItem }
    DISALLOWED_FILES = if ($Risk.disallowed_files.Count -gt 0) { ($Risk.disallowed_files | ForEach-Object { "- ``$_``" }) -join [Environment]::NewLine } else { Get-NoneListItem }
    DIFF_STAT = if ($DiffStat) { $DiffStat } else { "(empty)" }
    DIFF_NUMSTAT = if ($DiffNumstat) { $DiffNumstat } else { "(empty)" }
    PATCH_ARTIFACT = $PatchPath
    RISK_REPORT = $RiskMarkdownPath
    REDTEAM_REPORT = $RedteamReportPath
    REDTEAM_STATUS_CONTEXT = $RedteamStatusContext
    LOG_PATH = $LogPath
    CHANGED_FILES = $changedList
    VERIFY_COMMANDS = $verifyList
  }
  $title = (Get-Content -LiteralPath $CommitTemplate -Encoding utf8 | Select-Object -First 1)
  try {
    $prArgs = @("pr", "create", "--repo", $TargetRepo, "--base", $BaseBranch, "--head", $branchName, "--title", $title, "--body-file", $prBodyFile)
    if ($Risk.publish_mode -eq "draft_pull_request") {
      $prArgs += "--draft"
    }
    $prUrl = Invoke-GhOutput -Arguments $prArgs -WorkingDirectory $TargetRoot
    if (-not $prUrl) {
      throw "Failed to create PR."
    }
    Write-Log "PR created: $prUrl"
  }
  finally {
    Remove-Item -LiteralPath $prBodyFile -Force -ErrorAction SilentlyContinue
  }

  $prNumber = Invoke-GhOutput -Arguments @("pr", "view", $prUrl, "--repo", $TargetRepo, "--json", "number", "--jq", ".number") -WorkingDirectory $TargetRoot
  if (-not $prNumber) {
    throw "Failed to resolve PR number."
  }

  if (-not $SkipRedteam) {
    $reviewAttempt = 1
    $maxReviewAttempts = 1 + [Math]::Max(0, $MaxReviewResponses)
    while ($true) {
      $headSha = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $TargetRoot
      $prChangedFiles = Get-PullRequestChangedFiles -TargetRoot $TargetRoot -BaseBranch $BaseBranch
      $prDiffStat = Get-PullRequestDiffStat -TargetRoot $TargetRoot -BaseBranch $BaseBranch
      $prDiffNumstat = Get-PullRequestDiffNumstat -TargetRoot $TargetRoot -BaseBranch $BaseBranch
      Set-CommitStatus -Repo $TargetRepo -Sha $headSha -State "pending" -Context $RedteamStatusContext -Description "Codex red-team review attempt $reviewAttempt is running."

      $redteamResult = Invoke-CodexRedteamReview `
        -TargetRoot $TargetRoot `
        -Repo $TargetRepo `
        -PrNumber $prNumber `
        -CommitSha $headSha `
        -Risk $Risk `
        -DiffStat $prDiffStat `
        -DiffNumstat $prDiffNumstat `
        -ChangedFiles $prChangedFiles `
        -Attempt $reviewAttempt
      $redteamCommentId = Add-RedteamPrComment -Repo $TargetRepo -PrNumber $prNumber -Decision $redteamResult.Decision -ReportPath $redteamResult.ReportPath -Attempt $reviewAttempt
      if ($redteamResult.Decision -eq "PASS") {
        Set-CommitStatus -Repo $TargetRepo -Sha $headSha -State "success" -Context $RedteamStatusContext -Description "Codex red-team review passed."
        Add-IssueCommentReaction -Repo $TargetRepo -CommentId $redteamCommentId -Content "+1"
        Add-RedteamHandlingComment -Repo $TargetRepo -PrNumber $prNumber -RedteamCommentId $redteamCommentId -Outcome "pass" -Attempt $reviewAttempt
        break
      }

      Set-CommitStatus -Repo $TargetRepo -Sha $headSha -State "failure" -Context $RedteamStatusContext -Description "Codex red-team review failed."
      Add-IssueCommentReaction -Repo $TargetRepo -CommentId $redteamCommentId -Content "eyes"
      if ($reviewAttempt -ge $maxReviewAttempts) {
        Close-ReviewFailedPullRequest `
          -Repo $TargetRepo `
          -PrNumber $prNumber `
          -BranchName $branchName `
          -TargetRoot $TargetRoot `
          -BaseBranch $BaseBranch `
          -Reason "Codex red-team review failed after $reviewAttempt attempt(s)." `
          -ReportPath $redteamResult.ReportPath
      }
      if ($Risk.publish_mode -ne "pull_request") {
        Close-ReviewFailedPullRequest `
          -Repo $TargetRepo `
          -PrNumber $prNumber `
          -BranchName $branchName `
          -TargetRoot $TargetRoot `
          -BaseBranch $BaseBranch `
          -Reason "Codex red-team review failed for publish_mode=$($Risk.publish_mode); automatic review response is disabled outside pull_request mode." `
          -ReportPath $redteamResult.ReportPath
      }

      $responseSummaryPath = Invoke-CodexReviewResponse `
        -TargetRoot $TargetRoot `
        -Repo $TargetRepo `
        -PrNumber $prNumber `
        -CommitSha $headSha `
        -ReportPath $redteamResult.ReportPath `
        -DiffStat $prDiffStat `
        -DiffNumstat $prDiffNumstat `
        -ChangedFiles $prChangedFiles `
        -AllowedPathPatterns $AllowedPathPatterns `
        -DeniedPathPatterns $DeniedPathPatterns `
        -Attempt $reviewAttempt

      $responseChanged = Get-ChangedFiles -TargetRoot $TargetRoot
      if ($responseChanged.Count -eq 0) {
        Close-ReviewFailedPullRequest `
          -Repo $TargetRepo `
          -PrNumber $prNumber `
          -BranchName $branchName `
          -TargetRoot $TargetRoot `
          -BaseBranch $BaseBranch `
          -Reason "Review response attempt $reviewAttempt produced no target changes." `
          -ReportPath $responseSummaryPath
      }
      $responsePatchPath = Get-AttemptArtifactPath -Name "review-response" -Attempt $reviewAttempt -Extension "patch"
      Save-PatchArtifact -TargetRoot $TargetRoot -OutputPath $responsePatchPath
      Assert-AllowedChanges `
        -TargetRoot $TargetRoot `
        -ChangedFiles $responseChanged `
        -AllowedPathPatterns $AllowedPathPatterns `
        -DeniedPathPatterns $DeniedPathPatterns `
        -MaxFiles $MaxFiles `
        -MaxLines $MaxLines

      foreach ($command in $TargetVerifyCommands) {
        Invoke-CommandLine -Command $command -WorkingDirectory $TargetRoot
      }
      Invoke-CommandLine -Command "python -m self_maintainer_bot.cli eval-docs --fail-under 1" -WorkingDirectory $BotRoot
      Invoke-CommandLine -Command "git diff --check" -WorkingDirectory $TargetRoot
      $Risk = Invoke-RiskClassifier -Scope $Scope
      Write-Log "Review response risk classification: max_risk=$($Risk.max_risk) publish_mode=$($Risk.publish_mode)"
      if ($Risk.publish_mode -ne "pull_request") {
        Close-ReviewFailedPullRequest `
          -Repo $TargetRepo `
          -PrNumber $prNumber `
          -BranchName $branchName `
          -TargetRoot $TargetRoot `
          -BaseBranch $BaseBranch `
          -Reason "Review response exceeded auto-merge risk budget: publish_mode=$($Risk.publish_mode)." `
          -ReportPath $RiskMarkdownPath
      }

      foreach ($path in $responseChanged) {
        Invoke-CommandLine -Command "git add -- `"$path`"" -WorkingDirectory $TargetRoot
      }
      $responseCommitFile = New-TemporaryFile
      try {
        $responseCommitMessage = Get-Content -LiteralPath $ReviewResponseCommitTemplate -Raw -Encoding utf8
        [System.IO.File]::WriteAllText($responseCommitFile, $responseCommitMessage, [System.Text.UTF8Encoding]::new($false))
        Invoke-CommandLine -Command "git commit --trailer `"Co-authored-by: Codex`" -F `"$responseCommitFile`"" -WorkingDirectory $TargetRoot
      }
      finally {
        Remove-Item -LiteralPath $responseCommitFile -Force -ErrorAction SilentlyContinue
      }
      $responseCommitSha = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $TargetRoot
      Invoke-GitPush -BranchName $branchName -WorkingDirectory $TargetRoot -Token $PublisherToken
      Add-ReviewResponsePrComment -Repo $TargetRepo -PrNumber $prNumber -SummaryPath $responseSummaryPath -ChangedFiles $responseChanged -Attempt $reviewAttempt
      Add-IssueCommentReaction -Repo $TargetRepo -CommentId $redteamCommentId -Content "+1"
      Add-RedteamHandlingComment -Repo $TargetRepo -PrNumber $prNumber -RedteamCommentId $redteamCommentId -Outcome "response" -Attempt $reviewAttempt -CommitSha $responseCommitSha -SummaryPath $responseSummaryPath
      $reviewAttempt += 1
    }
  }

  if ($ResolvedAutoMerge -and $Risk.publish_mode -eq "pull_request") {
    Invoke-CommandLine -Command "gh pr checks $prNumber --repo $TargetRepo --watch" -WorkingDirectory $TargetRoot

    $headSha = Get-GitOutput -Arguments @("rev-parse", "HEAD") -WorkingDirectory $TargetRoot
    $mergeArgs = @("pr", "merge", $prNumber, "--repo", $TargetRepo, "--match-head-commit", $headSha)
    $mergeBody = Get-MergeBodyText
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
    Wait-ForPullRequestMerged -Repo $TargetRepo -PrNumber $prNumber -TimeoutSeconds $MergeWaitTimeoutSeconds -PollSeconds $MergePollSeconds
    Invoke-CommandLine -Command "git switch $BaseBranch" -WorkingDirectory $TargetRoot
    Invoke-CommandLine -Command "git pull --ff-only origin $BaseBranch" -WorkingDirectory $TargetRoot
  }
  elseif ($ResolvedAutoMerge) {
    Write-Log "Auto merge skipped because publish_mode=$($Risk.publish_mode)."
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
