# Running screenbox in the interactive session

The one thing that cannot be fixed in code: **accessibility needs the session a
person is logged into.** From session 0 (a service, an SSH session, a scheduled
task running as SYSTEM) the tree is empty and nothing raises.

## Verify first

```powershell
powershell -NoProfile -File screenbox.ps1 -RunTool screen_info
```

```json
{ "session": 2, "canSeeDesktop": true, "topLevelWindows": 5, "note": "ok" }
```

`canSeeDesktop: false` means the process is in the wrong session, not that the
screen is empty.

## Getting a process into session 2

A scheduled task with `LogonType Interactive` and the logged-in user's principal:

```powershell
$principal = (Get-ScheduledTask -TaskName <any task already running there>).Principal
$a = New-ScheduledTaskAction -Execute 'node' -Argument 'C:/tools/screenws.js'
Register-ScheduledTask -TaskName 'screenws' -Action $a -Principal $principal -Force
Start-ScheduledTask -TaskName 'screenws'
```

`New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest`
also works, but copying the principal of a task that already runs where you want
to be is the form that has no surprises: it carries the right logon type, the
right run level, and the right user in one step.

## Bridging stdio to a WebSocket

An MCP client that speaks stdio cannot reach a process in another session, so a
tiny relay is needed. About 30 lines of Node:

```js
const { spawn } = require('child_process');
const { WebSocketServer } = require('ws');

new WebSocketServer({ host: '127.0.0.1', port: 9400 }).on('connection', ws => {
  const c = spawn('powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:/tools/screenbox.ps1'],
    { windowsHide: true });
  let buf = '';
  c.stdout.on('data', d => {
    buf += d;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.trim() && ws.readyState === 1) ws.send(line);
    }
  });
  ws.on('message', m => { const t = String(m).trim(); if (t) c.stdin.write(t + '\n'); });
  ws.on('close', () => { try { c.kill() } catch (e) {} });
});
```

Then from a client that tunnels through the host:

```
open <session> mcp ws://127.0.0.1:9400
call <session> mcp:1 screen_info {}
```

## Two traps found the hard way

**`$args` and `$pid` are automatic variables.** A tool parameter named `pid` is
silently shadowed by the process id, and a function parameter named `$args` is
silently shadowed by PowerShell's own argument array. This server uses `procId`
and `$ta` for that reason.

**A rectangle can be infinite.** A window that reports no bounds returns
`Infinity` for X/Y/Width/Height, and casting that to `int` throws. Clamp it and
let the `off` flag carry the meaning.
