@echo off
REM Disconnect the RDP client WITHOUT locking the desktop.
REM A plain disconnect turns the session into "Disconnected", which removes the
REM foreground window: SetForegroundWindow returns false and key injection goes
REM nowhere. Redirecting the session to the physical console keeps the desktop
REM live, so automation keeps working after you close the RDP window.
for /f "skip=1 tokens=3" %%s in ('query user %USERNAME%') do tscon %%s /dest:console
