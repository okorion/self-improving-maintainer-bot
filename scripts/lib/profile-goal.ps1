function Resolve-ChangeScale {
  param([string]$Value)

  $normalized = if ($Value) { $Value.Trim().ToLowerInvariant() } else { "" }
  if ($normalized -and @("normal", "major") -notcontains $normalized) {
    throw "Unsupported profile changeScale: $Value"
  }
  return $normalized
}

function Get-ChangeScaleGoalContext {
  param(
    [string]$ChangeScale,
    [string]$Kind,
    [string[]]$GoalDirectives = @()
  )

  $resolvedScale = Resolve-ChangeScale -Value $ChangeScale
  $selectionRule = switch ($resolvedScale) {
    "normal" { "Choose the most valuable small or medium user-visible $Kind improvement for the current product." }
    "major" { "Choose one coherent major vertical slice: a substantial feature, workflow expansion, visual-quality step, or meaningful simplification. Do not split the slot into unrelated changes or reduce it to a small cleanup." }
    default { "Choose a small user-visible feat, style, or refactor change that fits this repository's own gaps. Do not use docs-only changes for a $Kind task unless $Kind is docs." }
  }

  $lines = @("Change scale: $(if ($resolvedScale) { $resolvedScale } else { 'legacy' })", $selectionRule)
  if ($GoalDirectives.Count -gt 0) {
    $lines += "Profile goal directives:"
    $lines += @($GoalDirectives | ForEach-Object { "- $_" })
  }
  return ($lines -join [Environment]::NewLine)
}
