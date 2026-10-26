Add-Type -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
"@ -Name P2 -Namespace Probe2 -PassThru | Out-Null
$edit = [IntPtr]1114618
$np = [IntPtr]1114378
$sid = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
"session = $sid"
"edit IsWindow  = " + [Probe2.P2]::IsWindow($edit)
"edit parent    = " + [Probe2.P2]::GetParent($edit)
"EM_GETMODIFY   = " + [Probe2.P2]::SendMessageW($edit, 0x00B8, [IntPtr]::Zero, [IntPtr]::Zero)
"EM_GETTEXTLEN  = " + [Probe2.P2]::SendMessageW($edit, 0x000E, [IntPtr]::Zero, [IntPtr]::Zero)
"setfg          = " + [Probe2.P2]::SetForegroundWindow($np)
Start-Sleep -m 400
"foreground     = " + [Probe2.P2]::GetForegroundWindow()
