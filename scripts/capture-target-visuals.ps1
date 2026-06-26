#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TargetRoot,

  [Parameter(Mandatory = $true)]
  [string]$Repo,

  [Parameter(Mandatory = $true)]
  [string]$RunId,

  [ValidateSet("before", "after")]
  [string]$Phase = "after",

  [string]$Viewport = "1440x1000",
  [int]$StartupTimeoutSeconds = 75
)

$ErrorActionPreference = "Stop"

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return $listener.LocalEndpoint.Port
  }
  finally {
    $listener.Stop()
  }
}

function Resolve-BrowserPath {
  $commands = @("chrome", "chrome.exe", "msedge", "msedge.exe")
  foreach ($command in $commands) {
    $resolved = Get-Command $command -ErrorAction SilentlyContinue
    if ($resolved) {
      return $resolved.Source
    }
  }

  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
  }
  return $null
}

function Wait-ForUrl {
  param(
    [string]$Url,
    [int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
      if ([int]$response.StatusCode -lt 500) {
        return $true
      }
    }
    catch {
      Start-Sleep -Milliseconds 500
    }
  }
  return $false
}

function Start-TargetServer {
  param(
    [string]$Root,
    [int]$Port
  )
  $packageJson = Join-Path $Root "package.json"
  if (Test-Path -LiteralPath $packageJson -PathType Leaf) {
    return Start-Process -FilePath $env:ComSpec `
      -ArgumentList @("/c", "pnpm", "exec", "vite", "--host", "127.0.0.1", "--port", [string]$Port, "--strictPort") `
      -WorkingDirectory $Root `
      -PassThru `
      -WindowStyle Hidden
  }

  return Start-Process -FilePath "python" `
    -ArgumentList @("-m", "http.server", [string]$Port, "--bind", "127.0.0.1") `
    -WorkingDirectory $Root `
    -PassThru `
    -WindowStyle Hidden
}

$resolvedRoot = (Resolve-Path -LiteralPath $TargetRoot).Path
$browser = Resolve-BrowserPath
if (-not $browser) {
  Write-Output "SKIPPED browser-not-found"
  exit 0
}

$port = Get-FreePort
$url = "http://127.0.0.1:$port/"
$server = $null
$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-$RunId-$($Repo.Replace('/', '-'))-$Phase.png")

try {
  $server = Start-TargetServer -Root $resolvedRoot -Port $port
  if (-not (Wait-ForUrl -Url $url -TimeoutSeconds $StartupTimeoutSeconds)) {
    Write-Output "SKIPPED server-timeout"
    exit 0
  }

  $browserArgs = @(
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--window-size=$Viewport",
    "--screenshot=$tempPath",
    $url
  )
  & $browser @browserArgs | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tempPath -PathType Leaf)) {
    Write-Output "SKIPPED screenshot-failed"
    exit 0
  }

  $registerScript = Join-Path $env:USERPROFILE ".codex\skills\capture-artifacts\scripts\register-capture.ps1"
  if (-not (Test-Path -LiteralPath $registerScript -PathType Leaf)) {
    Write-Output "SKIPPED register-script-missing"
    exit 0
  }

  $repoSlug = $Repo.Replace("/", "-")
  $savedPath = powershell -NoProfile -ExecutionPolicy Bypass -File $registerScript `
    -SourcePath $tempPath `
    -Project $repoSlug `
    -Purpose "$RunId-$Phase" `
    -Viewport $Viewport `
    -Repo $Repo `
    -Url $url `
    -Notes "auto-improve visual evidence $Phase"

  $savedItem = Get-Item -LiteralPath ([string]$savedPath.Trim()) -ErrorAction Stop
  Write-Output "CAPTURED $($savedItem.Name)"
}
finally {
  if ($server -and -not $server.HasExited) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
}
