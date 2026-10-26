Add-Type -AssemblyName System.Windows.Forms
$sid = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
$p = [System.Windows.Forms.Cursor]::Position
"session=$sid before=" + $p.X + ',' + $p.Y
[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(600,400)
Start-Sleep -m 250
$p2 = [System.Windows.Forms.Cursor]::Position
"after=" + $p2.X + ',' + $p2.Y
