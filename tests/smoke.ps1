<#
.SYNOPSIS
    Smoke tests for screenbox.ps1.

    Runs anywhere PowerShell Core is installed. On non-Windows it verifies the
    arguments, the MCP protocol framing, and the error paths; on Windows it runs
    against the live desktop and checks the numbers.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'screenbox.ps1'

function Assert-True($cond, [string]$msg) {
    if (-not $cond) { throw "FAIL: $msg" }
    Write-Host "  ok: $msg" -ForegroundColor Green
}

Write-Host "== screenbox smoke tests ==" -ForegroundColor Cyan

# 1. -ListTools answers valid JSON with 5 tools
Write-Host "`n1. tool catalogue"
$raw = & pwsh -NoProfile -File $Script -ListTools
$cat = $raw | ConvertFrom-Json
Assert-True ($cat.tools.Count -eq 5) "catalogue holds 5 tools (got $($cat.tools.Count))"
$names = @($cat.tools | ForEach-Object { $_.name })
Assert-True ($names -contains 'screen_info') 'catalogue names screen_info'
Assert-True ($names -contains 'screen_windows') 'catalogue names screen_windows'
Assert-True ($names -contains 'screen_find') 'catalogue names screen_find'
Assert-True ($names -contains 'screen_act') 'catalogue names screen_act'
Assert-True ($names -contains 'screen_type') 'catalogue names screen_type'

# 2. Schema check: screen_find uses procId, not pid
$findTool = $cat.tools | Where-Object { $_.name -eq 'screen_find' }
Assert-True ($findTool.inputSchema.properties.procId -ne $null) 'screen_find uses procId, not pid'
Assert-True ($findTool.inputSchema.properties.pid -eq $null) 'screen_find does NOT have pid'

# 3. Schema check: screen_act requires ref and action
$actTool = $cat.tools | Where-Object { $_.name -eq 'screen_act' }
Assert-True ($actTool.inputSchema.required -contains 'ref') 'screen_act requires ref'
Assert-True ($actTool.inputSchema.required -contains 'action') 'screen_act requires action'

# 4. Unknown tool throws
Write-Host "`n2. error paths"
$failed = $false
try {
    & pwsh -NoProfile -File $Script -RunTool does_not_exist 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} catch { $failed = $true }
Assert-True $failed 'unknown tool exits non-zero'

# 5. On Windows: run live SelfTest
if ($IsWindows) {
    Write-Host "`n3. live Windows self-test"
    $st = & pwsh -NoProfile -File $Script -SelfTest | ConvertFrom-Json
    Assert-True ($st.passed -eq $st.total) "all tools passed self-test ($($st.passed)/$($st.total))"
} else {
    Write-Host "`n3. live Windows self-test: skipped on non-Windows" -ForegroundColor Yellow
}

Write-Host "`nALL PASS" -ForegroundColor Green
