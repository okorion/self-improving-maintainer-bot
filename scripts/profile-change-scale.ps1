#Requires -Version 5.1

function Get-ProfileChangeScale {
  param([object]$ProfileObject)

  if (-not $ProfileObject -or -not ($ProfileObject.PSObject.Properties.Name -contains "changeScale")) {
    return ""
  }
  $value = ([string]$ProfileObject.changeScale).Trim().ToLowerInvariant()
  if (-not $value) {
    return ""
  }
  if (@("normal", "major") -notcontains $value) {
    throw "Unsupported profile changeScale: $value"
  }
  return $value
}

function Get-ChangeScaleGoalContext {
  param(
    [string]$ChangeScale,
    [string[]]$GoalDirectives = @()
  )

  $scaleText = switch ($ChangeScale) {
    "normal" {
      "Change scale: normal. Choose the highest-value small or medium improvement. Do not repeat invisible cleanup or a recent merged PR topic."
    }
    "major" {
      "Change scale: major. Choose one coherent, user-visible vertical slice: a substantial feature, a large core-flow expansion, a meaningful output-quality step, or a complexity-reducing redesign. Do not bundle unrelated work and do not stop after planning."
    }
    default { "" }
  }
  $directiveText = if ($GoalDirectives.Count -gt 0) {
    "Project goal directives:`n" + (($GoalDirectives | ForEach-Object { "- $_" }) -join [Environment]::NewLine)
  }
  else {
    ""
  }
  return (@($scaleText, $directiveText) | Where-Object { $_ }) -join ([Environment]::NewLine + [Environment]::NewLine)
}
