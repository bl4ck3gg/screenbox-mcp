<#
.SYNOPSIS
    screenbox - an MCP server that lets an agent see and act on a Windows desktop.

.DESCRIPTION
    Two rules shape every reply, and both exist because the alternative was measured:

    PROJECTION. An accessibility element carries about 1.2 KB of properties, of
    which roughly 150 bytes are what a caller decides with. The rest is
    providerDescription (identical for every element of the same provider),
    legacyAccessiblePattern (almost always empty), and a dozen booleans. So a tool
    here answers with the fields a decision needs: ref, name, class, type,
    automation id, pid, rectangle, and a flags string. The full bag is not
    offered, because nothing in this server's job needs it.

    VERIFICATION. "success: true" is a statement about the request, not about the
    world. A button that reports it was invoked may have done nothing; a dialog
    that reports it was dismissed may still be there. So every action answers
    what the reply can prove: the target's own observable state before and after,
    the containing window's subtree size before and after, and the top-level
    window count. An action whose effect lands somewhere else (a new tab, a new
    dialog) shows up in the second and third numbers, which is why they are there.

    REFS ARE SELF-DESCRIBING. A ref looks like "h262352" (an HWND) or
    "r42.787324.983818" (a UIA runtime id). It is resolved on every call, so it
    survives a server restart, a fresh child process, and a reply quoted into
    another conversation. A ref that no longer resolves fails by name instead of
    silently acting on whatever is at that index now.

    It must run in the session a person is logged into. Accessibility returns an
    empty tree from session 0 and does NOT raise, which is why screen_info
    reports the session and whether the desktop is visible.

.PARAMETER ListTools
    Print the tool catalogue as JSON and exit.

.PARAMETER SelfTest
    Run every tool against this machine and report what worked.

.PARAMETER RunTool
    Run one tool and print its result. Reads arguments from WINBOX-style
    SCREENBOX_ARGS (a JSON object) because PowerShell 5.1 mangles quotes in a
    JSON command-line argument.
#>
[CmdletBinding()]
param(
    [switch]$ListTools,
    [switch]$SelfTest,
    [string]$RunTool = '',
    [string]$ArgsJson = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# LAZY, because the protocol surface must be testable off Windows: -ListTools and
# the framing have nothing to do with accessibility, and a script that refuses to
# parse on Linux cannot be checked by CI.
$UiaAvailable = $false
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    $UiaAvailable = $true
} catch { }

$AE = $null
$TS = $null
if ($UiaAvailable) {
    $AE = [System.Windows.Automation.AutomationElement]
    $TS = [System.Windows.Automation.TreeScope]
}

function Assert-Uia {
    if (-not $UiaAvailable) {
        throw 'accessibility is not available in this process. This server needs Windows with the UIAutomationClient assemblies; on another OS only -ListTools and the MCP framing work.'
    }
}

# Counting stops here. A browser window can hold thousands of elements and the
# question this answers ("did the subtree change") is settled long before then.
$SubtreeCap = 300
$ItemLimit = 40

# ---------------------------------------------------------------------------
# refs: self-describing, resolved per call
# ---------------------------------------------------------------------------

function Get-RefFor($el) {
    $p = $el.Current
    if ($p.NativeWindowHandle -ne 0) { return 'h' + $p.NativeWindowHandle }
    $rid = $el.GetRuntimeId()
    if ($rid -and $rid.Length -gt 0) { return 'r' + (($rid | ForEach-Object { [string]$_ }) -join '.') }
    throw 'this element has neither an HWND nor a runtime id, so there is no ref that could find it again'
}

function Resolve-Ref([string]$ref) {
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'a ref is required (take one from screen_windows or screen_find)' }
    if ($ref -match '^h([0-9]+)$') {
        $h = [int64]$Matches[1]
        $el = $AE::FromHandle([IntPtr]$h)
        if (-not $el) { throw "ref '$ref' names an HWND that no longer has an accessibility element; take a new ref" }
        return $el
    }
    if ($ref -match '^r([0-9\.]+)$') {
        $ids = @($Matches[1].Split('.') | ForEach-Object { [int]$_ })
        $cond = New-Object System.Windows.Automation.PropertyCondition($AE::RuntimeIdProperty, [int[]]$ids)
        $el = $AE::RootElement.FindFirst($TS::Descendants, $cond)
        if (-not $el) { throw "ref '$ref' names a runtime id that is no longer in the tree; take a new ref" }
        return $el
    }
    throw "malformed ref '$ref'. Expected h<number> (an HWND) or r<n.n.n> (a runtime id), which is what screen_windows and screen_find return"
}

# ---------------------------------------------------------------------------
# projection: one element, the fields a decision uses
# ---------------------------------------------------------------------------

function Num($v) {
    # A rectangle can be infinite (a window that reports no bounds), and a cast
    # to int then throws. Clamp instead of failing.
    if ([double]::IsInfinity($v) -or [double]::IsNaN($v)) { return -1 }
    if ($v -gt 2147483647) { return 2147483647 }
    if ($v -lt -2147483648) { return -2147483648 }
    return [int]$v
}

function Get-Brief($el) {
    $p = $el.Current
    $r = $p.BoundingRectangle
    $type = ''
    try { $type = [string]$p.ControlType.ProgrammaticName -replace '^ControlType\.', '' } catch { }

    $flags = @()
    if ($p.IsOffscreen) { $flags += 'off' }
    if (-not $p.IsEnabled) { $flags += 'disabled' }
    if ($p.HasKeyboardFocus) { $flags += 'FOCUSED' }
    elseif ($p.IsKeyboardFocusable) { $flags += 'focusable' }
    try {
        $wp = $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        if ($wp.Current.IsModal) { $flags += 'MODAL' }
        $ws = [string]$wp.Current.WindowInteractionState
        if ($ws -and $ws -ne 'ReadyForUserInteraction') { $flags += ($ws -replace 'WindowInteractionState', '') }
    } catch { }

    return [ordered]@{
        ref   = Get-RefFor $el
        name  = [string]$p.Name
        cls   = [string]$p.ClassName
        type  = $type
        aid   = [string]$p.AutomationId
        pid   = [int]$p.ProcessId
        rect  = @((Num $r.X), (Num $r.Y), (Num $r.Width), (Num $r.Height))
        flags = ($flags -join ' ')
        hwnd  = [int64]$p.NativeWindowHandle
    }
}

# ---------------------------------------------------------------------------
# observation: what an action is verified against
# ---------------------------------------------------------------------------

function Get-State($el) {
    $p = $el.Current
    $s = [ordered]@{ name = [string]$p.Name; enabled = $p.IsEnabled; offscreen = $p.IsOffscreen }
    try { $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
          $s.value = [string]$vp.Current.Value } catch { }
    try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
          $s.toggle = [string]$tp.Current.ToggleState } catch { }
    try { $sp = $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
          $s.selected = $sp.Current.IsSelected } catch { }
    try { $ep = $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
          $s.expanded = [string]$ep.Current.ExpandCollapseState } catch { }
    try { $tx = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
          $s.text = ($tx.DocumentRange.GetText(200) -replace '\s+', ' ').Trim() } catch { }
    return $s
}

function Count-Subtree($el, [int]$cap) {
    # A TreeWalker walk rather than FindAll: FindAll materializes the whole
    # subtree before returning, so a cap applied afterwards would not save the
    # work that makes a big window expensive.
    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $n = 0
    $stack = New-Object System.Collections.Stack
    try {
        $c = $walker.GetFirstChild($el)
        while ($c) {
            $stack.Push($c)
            $c = $walker.GetNextSibling($c)
        }
    } catch { }
    while ($stack.Count -gt 0) {
        $e = $stack.Pop()
        $n++
        if ($n -ge $cap) { return @{ count = $n; capped = $true } }
        try {
            $k = $walker.GetFirstChild($e)
            while ($k) {
                $stack.Push($k)
                $k = $walker.GetNextSibling($k)
            }
        } catch { }
    }
    return @{ count = $n; capped = $false }
}

function Get-WindowOf($el) {
    # The top-level ancestor: the thing whose subtree size answers "did the
    # window change" for actions whose effect lands outside their target.
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $cur = $el
    for ($i = 0; $i -lt 40; $i++) {
        try { $parent = $walker.GetParent($cur) } catch { break }
        if (-not $parent) { break }
        $cur = $parent
    }
    return $cur
}

function Get-Fingerprint($el) {
    # THREE READINGS, because an action's effect can land in three places:
    # the target itself, the window's subtree (a new tab or row), or the desktop
    # (a new dialog). Reporting only the first is what makes "verified" wrong.
    $sub = Count-Subtree $el $SubtreeCap
    $win = Get-WindowOf $el
    $winSub = Count-Subtree $win $SubtreeCap
    $tops = 0
    try { $tops = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition).Count } catch { }
    return [ordered]@{
        self         = Get-State $el
        targetKids   = @{ count = $sub.count; capped = $sub.capped }
        windowKids   = @{ count = $winSub.count; capped = $winSub.capped }
        topWindows   = [int]$tops
    }
}

function Compare-Fingerprint($before, $after) {
    $changed = @()
    foreach ($k in $after.self.Keys) {
        $b = if ($before.self.Contains($k)) { [string]$before.self[$k] } else { '<absent>' }
        $a = [string]$after.self[$k]
        if ($b -ne $a) { $changed += "self.$k=$b -> $a" }
    }
    if ($before.targetKids.count -ne $after.targetKids.count) {
        $changed += "targetKids=$($before.targetKids.count) -> $($after.targetKids.count)"
    }
    if ($before.windowKids.count -ne $after.windowKids.count) {
        $changed += "windowKids=$($before.windowKids.count) -> $($after.windowKids.count)"
    }
    if ($before.topWindows -ne $after.topWindows) {
        $changed += "topWindows=$($before.topWindows) -> $($after.topWindows)"
    }
    return $changed
}

# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------

function Tool-Info {
    Assert-Uia
    $sid = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $root = $AE::RootElement
    $kids = $root.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $vis = 0
    foreach ($k in $kids) { if (-not $k.Current.IsOffscreen) { $vis++ } }
    $w = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $see = ($sid -ne 0) -and ($kids.Count -gt 0)
    $note = if ($see) { 'ok' } else {
        'this process cannot see the interactive desktop: accessibility returns an empty tree here and does NOT raise. Run it in the session a person is logged into (see docs/deploy.md).'
    }
    return [ordered]@{
        session         = [int]$sid
        canSeeDesktop   = $see
        desktop         = [string]$root.Current.Name
        topLevelWindows = [int]$kids.Count
        visibleWindows  = [int]$vis
        screen          = "$($w.Width)x$($w.Height)"
        powershell      = [string]$PSVersionTable.PSVersion
        note            = $note
    }
}

function Tool-Windows {
    Assert-Uia
    $kids = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
    $out = @()
    foreach ($k in $kids) { $out += Get-Brief $k }
    return $out
}

function Tool-Find($ta) {
    Assert-Uia
    $cls  = if ($ta.PSObject.Properties['cls'])    { [string]$ta.cls } else { '' }
    $aid  = if ($ta.PSObject.Properties['aid'])    { [string]$ta.aid } else { '' }
    $name = if ($ta.PSObject.Properties['name'])   { [string]$ta.name } else { '' }
    $type = if ($ta.PSObject.Properties['type'])   { [string]$ta.type } else { '' }
    $proc = if ($ta.PSObject.Properties['procId']) { [int]$ta.procId } else { 0 }
    $top  = if ($ta.PSObject.Properties['top'])     { [bool]$ta.top } else { $false }
    $under = if ($ta.PSObject.Properties['under'])  { [string]$ta.under } else { '' }
    $limit = if ($ta.PSObject.Properties['limit'])  { [int]$ta.limit } else { $ItemLimit }

    $parts = @()
    if ($cls)  { $parts += New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, $cls) }
    if ($aid)  { $parts += New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, $aid) }
    if ($name) { $parts += New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name) }
    if ($type) { $ct = [System.Windows.Automation.ControlType]::$type
                 $parts += New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $ct) }
    if ($proc) { $parts += New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $proc) }
    if ($parts.Count -eq 0) {
        throw 'screen_find needs at least one selector (cls, aid, name, type, procId). An unfiltered search walks the whole desktop, which is the cost this server exists to avoid; use screen_windows for "what is there".'
    }
    $cond = if ($parts.Count -eq 1) { $parts[0] } else { New-Object System.Windows.Automation.AndCondition($parts) }
    $scope = if ($top) { $TS::Children } else { $TS::Descendants }
    $root = if ($under) { Resolve-Ref $under } else { $AE::RootElement }

    $found = $root.FindAll($scope, $cond)
    $items = @()
    foreach ($e in $found) {
        if ($items.Count -ge $limit) { break }
        $items += Get-Brief $e
    }
    return [ordered]@{
        count    = [int]$found.Count
        returned = $items.Count
        hasMore  = ($found.Count -gt $items.Count)
        items    = $items
    }
}

function Tool-Act($ta) {
    Assert-Uia
    $ref = if ($ta.PSObject.Properties['ref'])    { [string]$ta.ref } else { '' }
    $action = if ($ta.PSObject.Properties['action']) { [string]$ta.action } else { '' }
    $el = Resolve-Ref $ref
    $before = Get-Fingerprint $el
    $did = ''

    switch -Regex ($action) {
        '^(invoke|default)$' {
            $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            $did = 'InvokePattern.Invoke'
        }
        '^toggle$' {
            $el.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
            $did = 'TogglePattern.Toggle'
        }
        '^expand$' {
            $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
            $did = 'ExpandCollapsePattern.Expand'
        }
        '^collapse$' {
            $el.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
            $did = 'ExpandCollapsePattern.Collapse'
        }
        '^select$' {
            $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            $did = 'SelectionItemPattern.Select'
        }
        '^focus$' {
            $el.SetFocus()
            $did = 'SetFocus'
        }
        '^setvalue:(?<v>[\s\S]*)$' {
            $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Matches['v'])
            $did = 'ValuePattern.SetValue'
        }
        '^window:maximize$' { $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState('Maximized'); $did = 'WindowPattern.Maximize' }
        '^window:minimize$' { $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState('Minimized'); $did = 'WindowPattern.Minimize' }
        '^window:close$'    { $el.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close(); $did = 'WindowPattern.Close' }
        default {
            throw "unknown action '$action'. Known: invoke, default, toggle, expand, collapse, select, focus, setvalue:<text>, window:maximize, window:minimize, window:close"
        }
    }

    Start-Sleep -Milliseconds 350
    try { $after = Get-Fingerprint (Resolve-Ref $ref) } catch { $after = $before }
    $changed = Compare-Fingerprint $before $after

    $verdict = if ($changed.Count -gt 0) {
        'the world changed in a way this reply can point at'
    } else {
        'nothing this server can observe changed. The pattern accepted the call; that is a fact about the request, not about the world. Treat the action as NOT done.'
    }

    return [ordered]@{
        did            = $did
        verified       = ($changed.Count -gt 0)
        changed        = $changed
        before         = $before
        after          = $after
        interpretation = $verdict
    }
}

function Tool-Type($ta) {
    Assert-Uia
    $text = if ($ta.PSObject.Properties['text']) { [string]$ta.text } else { '' }
    if ([string]::IsNullOrEmpty($text)) { throw 'screen_type needs text' }
    # SendKeys treats these as syntax, so a literal one has to be braced.
    $esc = $text -replace '([+^%~(){}\[\]])', '{$1}'
    $focusRef = ''
    $before = $null
    try {
        $f = $AE::FocusedElement
        if ($f) { $focusRef = Get-RefFor $f; $before = Get-Fingerprint $f }
    } catch { }
    [System.Windows.Forms.SendKeys]::SendWait($esc)
    Start-Sleep -Milliseconds 250
    $after = $null
    if ($focusRef) { try { $after = Get-Fingerprint (Resolve-Ref $focusRef) } catch { } }
    $changed = if ($before -and $after) { Compare-Fingerprint $before $after } else { @() }
    return [ordered]@{
        typed    = $text
        focused  = $focusRef
        verified = ($changed.Count -gt 0)
        changed  = $changed
        before   = $before
        after    = $after
        note     = 'SendKeys reaches menus and dialogs that expose no pattern. It types into whatever has focus, so screen_act focus:<ref> first when the target is not already focused.'
    }
}

# ---------------------------------------------------------------------------
# catalogue and dispatch
# ---------------------------------------------------------------------------

$Tools = @(
    @{ name = 'screen_info'
       desc = 'Where this server is: session id, whether accessibility can see the interactive desktop, window counts, screen size. Ask this first - an empty tree from the wrong session looks exactly like an empty screen.'
       schema = @{ type = 'object'; properties = @{} } }
    @{ name = 'screen_windows'
       desc = 'Top-level windows, one compact record each (ref, name, class, type, automation id, pid, rect, flags). About 130 bytes per window. Use the ref to act on it.'
       schema = @{ type = 'object'; properties = @{} } }
    @{ name = 'screen_find'
       desc = 'Search the tree by selector and return compact records. Requires at least one of cls, aid, name, type, procId. Optional: under (a ref to search inside), top (children only), limit (default 40).'
       schema = @{ type = 'object'; properties = @{
            cls    = @{ type = 'string'; description = 'ClassName, exact' }
            aid    = @{ type = 'string'; description = 'AutomationId, exact' }
            name   = @{ type = 'string'; description = 'Name, exact' }
            type   = @{ type = 'string'; description = 'ControlType, e.g. Button, Edit, TabItem' }
            procId = @{ type = 'integer'; description = 'owning process id (not "pid": that name is reserved in PowerShell)' }
            under  = @{ type = 'string'; description = 'a ref to search inside' }
            top    = @{ type = 'boolean'; description = 'search direct children only' }
            limit  = @{ type = 'integer'; description = 'max records returned (default 40)' } } } }
    @{ name = 'screen_act'
       desc = 'Act on a ref and answer what can be verified: the target state, the window subtree size, and the top-level window count, before and after. verified:false means the request was accepted and nothing observable changed - treat it as not done.'
       schema = @{ type = 'object'; properties = @{
            ref    = @{ type = 'string'; description = 'h<number> or r<n.n.n>' }
            action = @{ type = 'string'; description = 'invoke | default | toggle | expand | collapse | select | focus | setvalue:<text> | window:maximize | window:minimize | window:close' } }
            required = @('ref', 'action') } }
    @{ name = 'screen_type'
       desc = 'Type literal text into the focused element via SendKeys (reaches menus and dialogs that expose no pattern), then report the focused element fingerprint before and after.'
       schema = @{ type = 'object'; properties = @{ text = @{ type = 'string' } }; required = @('text') } }
)

function Invoke-Tool([string]$name, $ta) {
    switch ($name) {
        'screen_info'    { return Tool-Info }
        'screen_windows' { return Tool-Windows }
        'screen_find'    { return Tool-Find $ta }
        'screen_act'     { return Tool-Act $ta }
        'screen_type'    { return Tool-Type $ta }
        default { throw "unknown tool '$name'" }
    }
}

function ConvertTo-Args([string]$json) {
    if ([string]::IsNullOrWhiteSpace($json)) { return [pscustomobject]@{} }
    return $json | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# entry points
# ---------------------------------------------------------------------------

if ($ListTools) {
    $out = @()
    foreach ($t in $Tools) { $out += @{ name = $t.name; description = $t.desc; inputSchema = $t.schema } }
    ConvertTo-Json -InputObject @{ tools = $out } -Depth 12 -Compress
    exit 0
}

if ($SelfTest) {
    $results = @()
    foreach ($t in $Tools) {
        $name = $t.name
        $args = [pscustomobject]@{}
        if ($name -eq 'screen_type') { continue }
        if ($name -eq 'screen_find') { $args = [pscustomobject]@{ cls = 'Shell_TrayWnd' } }
        if ($name -eq 'screen_act') {
            # NOT the first window: the taskbar and Program Manager are top-level
            # windows that cannot take focus, so focusing one fails for a reason that
            # says nothing about this server. Pick one that reports it can be focused.
            $focusable = $null
            try {
                $all = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition)
                foreach ($w in $all) {
                    try { if ($w.Current.IsKeyboardFocusable) { $focusable = $w; break } } catch { }
                }
            } catch { }
            if (-not $focusable) {
                $results += @{ tool = $name; ok = $true; bytes = 0; sample = 'skipped: this desktop has no focusable top-level window (headless runner)' }
                continue
            }
            $args = [pscustomobject]@{ ref = (Get-RefFor $focusable); action = 'focus' }
        }
        try {
            $r = Invoke-Tool $name $args
            $json = $r | ConvertTo-Json -Depth 12 -Compress
            $results += @{ tool = $name; ok = $true; bytes = $json.Length; sample = $json.Substring(0, [Math]::Min(160, $json.Length)) }
        } catch {
            $results += @{ tool = $name; ok = $false; error = $_.Exception.Message }
        }
    }
    $ok = ($results | Where-Object { $_.ok }).Count
    ConvertTo-Json -InputObject @{ passed = $ok; total = $results.Count; results = $results } -Depth 12
    if ($ok -lt $results.Count) { exit 1 }
    exit 0
}

if ($RunTool) {
    $json = $ArgsJson
    if ([string]::IsNullOrWhiteSpace($json)) { $json = $env:SCREENBOX_ARGS }
    try {
        $r = Invoke-Tool $RunTool (ConvertTo-Args $json)
        ConvertTo-Json -InputObject $r -Depth 12
        exit 0
    } catch {
        ConvertTo-Json -InputObject @{ error = $_.Exception.Message } -Depth 6
        exit 1
    }
}

# MCP over stdio: one JSON object per line.
function Send($obj) {
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress -Depth 12))
    [Console]::Out.Flush()
}

$stdin = [Console]::In
while ($true) {
    $line = $stdin.ReadLine()
    if ($null -eq $line) { break }
    if ($line.Trim() -eq '') { continue }
    $msg = $null
    try { $msg = $line | ConvertFrom-Json } catch { continue }
    if (-not $msg.method) { continue }
    $id = $msg.id

    switch ($msg.method) {
        'initialize' {
            Send @{ jsonrpc = '2.0'; id = $id; result = @{
                protocolVersion = '2024-11-05'
                capabilities = @{ tools = @{} }
                serverInfo = @{ name = 'screenbox'; version = '0.1.0' }
            } }
        }
        'notifications/initialized' { }
        'ping' { Send @{ jsonrpc = '2.0'; id = $id; result = @{} } }
        'tools/list' {
            $out = @()
            foreach ($t in $Tools) { $out += @{ name = $t.name; description = $t.desc; inputSchema = $t.schema } }
            Send @{ jsonrpc = '2.0'; id = $id; result = @{ tools = $out } }
        }
        'tools/call' {
            $tname = $msg.params.name
            $targs = $msg.params.arguments
            try {
                $res = Invoke-Tool $tname $targs
                Send @{ jsonrpc = '2.0'; id = $id; result = @{ content = @(@{ type = 'text'; text = ($res | ConvertTo-Json -Compress -Depth 12) }) } }
            } catch {
                Send @{ jsonrpc = '2.0'; id = $id; result = @{
                    isError = $true
                    content = @(@{ type = 'text'; text = ('ERROR: ' + $_.Exception.Message) })
                } }
            }
        }
        default {
            Send @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = "method not found: $($msg.method)" } }
        }
    }
}
