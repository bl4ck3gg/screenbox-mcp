# sw.ps1 - start / stop / restart the screenbox bridge in the interactive session
param([ValidateSet('start','stop','restart','status')][string]$Action = 'status')

$TaskName = 'screenws'
$Principal = (Get-ScheduledTask -TaskName 'uiaws' -ErrorAction SilentlyContinue).Principal
if (-not $Principal) { $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest }

function Stop-Bridge {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return }
    if ($t.State -ne 'Disabled') {
        try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { }
    }
    # Stop-ScheduledTask does not always kill the child node process; the scheduled
    # task wrapper dies and node survives holding port 9400, so the next start fails
    # with EADDRINUSE. Kill by listening port, which is the thing that actually matters.
    Start-Sleep -Milliseconds 300
    $conn = Get-NetTCPConnection -LocalPort 9400 -State Listen -ErrorAction SilentlyContinue
    foreach ($c in $conn) { try { Stop-Process -Id $c.OwningProcess -Force -ErrorAction Stop } catch { } }
}

switch ($Action) {
    'stop' { Stop-Bridge; 'stopped' }
    'start' {
        $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c node C:/tc/screenbox/screenws.js > C:/tc/screenbox/out.txt 2>&1'
        Register-ScheduledTask -TaskName $TaskName -Action $a -Principal $Principal -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        # POLL for the port instead of sleeping a guess: node needs 1-3 s to come up and
        # a fixed sleep is either too short (false alarm) or too long (wasted time).
        $listen = $false
        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Milliseconds 250
            if (Get-NetTCPConnection -LocalPort 9400 -State Listen -ErrorAction SilentlyContinue) { $listen = $true; break }
        }
        $state = (Get-ScheduledTask -TaskName $TaskName).State
        if (-not $listen) { "state=$state listening=False  (see C:/tc/screenbox/out.txt and s.log)" }
        else { "state=$state listening=True pid=$((Get-NetTCPConnection -LocalPort 9400 -State Listen).OwningProcess)" }
    }
    'restart' { Stop-Bridge; Start-Sleep -Milliseconds 400; & $PSCommandPath start }
    'status' {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $listen = (Get-NetTCPConnection -LocalPort 9400 -State Listen -ErrorAction SilentlyContinue) -ne $null
        "task=$(if ($t) { $t.State } else { 'absent' }) listening=$listen pid=$((Get-NetTCPConnection -LocalPort 9400 -State Listen -ErrorAction SilentlyContinue).OwningProcess)"
    }
}
