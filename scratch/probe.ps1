Add-Type -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
"@ -Name P -Namespace Probe -PassThru | Out-Null

$edit = [IntPtr]1114618
$np   = [IntPtr]1114378

"EM_GETMODIFY = " + [Probe.P]::SendMessageW($edit, 0x00B8, [IntPtr]::Zero, [IntPtr]::Zero)
"EM_GETTEXTLEN = " + [Probe.P]::SendMessageW($edit, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
"setfg returned = " + [Probe.P]::SetForegroundWindow($np)
Start-Sleep -m 300
$fg = [Probe.P]::GetForegroundWindow()
$sb = New-Object System.Text.StringBuilder 256
[Probe.P]::GetWindowTextW($fg, $sb, 256) | Out-Null
"foreground hwnd = $fg  title = " + $sb.ToString()
"parent of edit = " + [Probe.P]::GetParent($edit)
