#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet("verify", "apply", "apply-and-verify")]
  [string]$Mode = "verify",
  [string]$Profile,
  [string]$ProfilesDir = "profiles\overtura",
  [string[]]$Repository = @(),
  [string]$DefaultBranch = "",
  [string]$RequiredStatusCheck = "check",
  [string]$RulesetName = "central-maintainer-bot-main-protection",
  [switch]$IncludeMergeQueue,
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$BotRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path

function Write-Step {
  param([string]$Message)
  Write-Host $Message
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

function Get-ProfileTargets {
  $targets = @()
  if ($Repository.Count -gt 0) {
    foreach ($repo in $Repository) {
      $targets += [pscustomobject]@{
        Repository = $repo
        Branch = if ($DefaultBranch) { $DefaultBranch } else { "main" }
      }
    }
    return $targets
  }

  if ($Profile) {
    $path = Resolve-ProfilePath -Name $Profile
    $data = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json
    return @([pscustomobject]@{
      Repository = [string]$data.repository
      Branch = if ($DefaultBranch) { $DefaultBranch } elseif ($data.defaultBranch) { [string]$data.defaultBranch } else { "main" }
    })
  }

  $profilesRoot = if ([System.IO.Path]::IsPathRooted($ProfilesDir)) {
    $ProfilesDir
  }
  else {
    Join-Path $BotRoot $ProfilesDir
  }
  foreach ($file in Get-ChildItem -LiteralPath $profilesRoot -Filter "*.json") {
    $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 | ConvertFrom-Json
    if (-not $data.repository) {
      continue
    }
    $targets += [pscustomobject]@{
      Repository = [string]$data.repository
      Branch = if ($DefaultBranch) { $DefaultBranch } elseif ($data.defaultBranch) { [string]$data.defaultBranch } else { "main" }
    }
  }

  return $targets
}

function ConvertTo-DepthJson {
  param($Value)
  return ($Value | ConvertTo-Json -Depth 20)
}

function Invoke-GhJson {
  param(
    [string]$Method,
    [string]$Path,
    $Body
  )
  $json = ConvertTo-DepthJson -Value $Body
  if ($DryRun) {
    Write-Step "DRY-RUN gh api -X $Method $Path"
    Write-Step $json
    return $null
  }

  $tmp = New-TemporaryFile
  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
    $output = gh api -X $Method $Path --input $tmp 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw ($output -join [Environment]::NewLine)
    }
    return $output
  }
  finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

function New-BranchProtectionBody {
  return @{
    required_status_checks = @{
      strict = $true
      contexts = @($RequiredStatusCheck)
    }
    enforce_admins = $true
    required_pull_request_reviews = @{
      dismiss_stale_reviews = $true
      require_code_owner_reviews = $true
      required_approving_review_count = 1
      require_last_push_approval = $true
    }
    restrictions = $null
    required_linear_history = $true
    allow_force_pushes = $false
    allow_deletions = $false
    required_conversation_resolution = $true
  }
}

function New-RulesetBody {
  param(
    [string]$Branch
  )

  $rules = @(
    @{ type = "deletion" },
    @{ type = "non_fast_forward" },
    @{ type = "required_linear_history" },
    @{
      type = "pull_request"
      parameters = @{
        dismiss_stale_reviews_on_push = $true
        require_code_owner_review = $true
        require_last_push_approval = $true
        required_approving_review_count = 1
        required_review_thread_resolution = $true
        allowed_merge_methods = @("squash")
      }
    },
    @{
      type = "required_status_checks"
      parameters = @{
        strict_required_status_checks_policy = $true
        do_not_enforce_on_create = $false
        required_status_checks = @(
          @{
            context = $RequiredStatusCheck
          }
        )
      }
    }
  )

  if ($IncludeMergeQueue) {
    $rules += @{
      type = "merge_queue"
      parameters = @{
        check_response_timeout_minutes = 60
        grouping_strategy = "ALLGREEN"
        max_entries_to_build = 5
        max_entries_to_merge = 5
        merge_method = "SQUASH"
        min_entries_to_merge = 1
        min_entries_to_merge_wait_minutes = 0
      }
    }
  }

  return @{
    name = $RulesetName
    target = "branch"
    enforcement = "active"
    conditions = @{
      ref_name = @{
        include = @("refs/heads/$Branch")
        exclude = @()
      }
    }
    rules = $rules
  }
}

function Get-ExistingRulesetId {
  param([string]$Repo)
  if ($DryRun) {
    return $null
  }
  $output = gh api "repos/$Repo/rulesets" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }
  $rulesets = $output | ConvertFrom-Json
  $match = @($rulesets | Where-Object { $_.name -eq $RulesetName } | Select-Object -First 1)
  if ($match.Count -eq 0) {
    return $null
  }
  return [string]$match[0].id
}

function Apply-RepositoryProtection {
  param(
    [string]$Repo,
    [string]$Branch
  )
  Write-Step "--- apply $Repo@$Branch ---"
  Invoke-GhJson -Method "PUT" -Path "repos/$Repo/branches/$Branch/protection" -Body (New-BranchProtectionBody) | Out-Null

  $rulesetBody = New-RulesetBody -Branch $Branch
  $existingRulesetId = Get-ExistingRulesetId -Repo $Repo
  if ($existingRulesetId) {
    Invoke-GhJson -Method "PUT" -Path "repos/$Repo/rulesets/$existingRulesetId" -Body $rulesetBody | Out-Null
  }
  else {
    Invoke-GhJson -Method "POST" -Path "repos/$Repo/rulesets" -Body $rulesetBody | Out-Null
  }
}

function Test-BranchProtection {
  param(
    [string]$Repo,
    [string]$Branch
  )
  $output = gh api "repos/$Repo/branches/$Branch/protection" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }
  $data = $output | ConvertFrom-Json
  $contexts = @($data.required_status_checks.contexts)
  $reviews = $data.required_pull_request_reviews
  $failures = @()
  if ($contexts -notcontains $RequiredStatusCheck) { $failures += "missing required status check '$RequiredStatusCheck'" }
  if (-not $reviews.require_code_owner_reviews) { $failures += "code owner review is not required" }
  if (-not $reviews.dismiss_stale_reviews) { $failures += "stale review dismissal is not enabled" }
  if (-not $reviews.require_last_push_approval) { $failures += "last push approval is not required" }
  if ($reviews.required_approving_review_count -lt 1) { $failures += "required approving review count is below 1" }
  if (-not $data.enforce_admins.enabled) { $failures += "admin enforcement is not enabled" }
  if (-not $data.required_linear_history.enabled) { $failures += "linear history is not required" }
  if (-not $data.required_conversation_resolution.enabled) { $failures += "conversation resolution is not required" }
  if ($data.allow_force_pushes.enabled) { $failures += "force pushes are allowed" }
  if ($data.allow_deletions.enabled) { $failures += "branch deletion is allowed" }
  if ($failures.Count -gt 0) {
    throw ($failures -join "; ")
  }
}

function Test-Ruleset {
  param(
    [string]$Repo
  )
  $existingRulesetId = Get-ExistingRulesetId -Repo $Repo
  if (-not $existingRulesetId) {
    throw "ruleset '$RulesetName' not found"
  }
  if (-not $IncludeMergeQueue) {
    return
  }
  $output = gh api "repos/$Repo/rulesets/$existingRulesetId" 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ($output -join [Environment]::NewLine)
  }
  $data = $output | ConvertFrom-Json
  $ruleTypes = @($data.rules | ForEach-Object { $_.type })
  foreach ($requiredRule in @("deletion", "non_fast_forward", "required_linear_history", "pull_request", "required_status_checks")) {
    if ($ruleTypes -notcontains $requiredRule) {
      throw "ruleset '$RulesetName' is missing rule '$requiredRule'"
    }
  }
  if ($ruleTypes -notcontains "merge_queue") {
    throw "merge_queue rule is not enabled"
  }
}

function Verify-RepositoryProtection {
  param(
    [string]$Repo,
    [string]$Branch
  )
  Write-Step "--- verify $Repo@$Branch ---"
  Test-BranchProtection -Repo $Repo -Branch $Branch
  Test-Ruleset -Repo $Repo
}

$targets = @(Get-ProfileTargets)
if ($targets.Count -eq 0) {
  throw "No target repositories resolved."
}

$failures = @()
foreach ($target in $targets) {
  try {
    if ($Mode -eq "apply" -or $Mode -eq "apply-and-verify") {
      Apply-RepositoryProtection -Repo $target.Repository -Branch $target.Branch
    }
    if ($Mode -eq "verify" -or $Mode -eq "apply-and-verify") {
      if ($DryRun) {
        Write-Step "DRY-RUN verify $($target.Repository)@$($target.Branch)"
      }
      else {
        Verify-RepositoryProtection -Repo $target.Repository -Branch $target.Branch
      }
    }
    Write-Step "PASS $($target.Repository)"
  }
  catch {
    $message = $_.Exception.Message
    Write-Step "FAIL $($target.Repository): $message"
    $failures += "$($target.Repository): $message"
  }
}

if ($failures.Count -gt 0) {
  Write-Step ""
  Write-Step "Protection setup incomplete:"
  foreach ($failure in $failures) {
    Write-Step "- $failure"
  }
  exit 1
}
