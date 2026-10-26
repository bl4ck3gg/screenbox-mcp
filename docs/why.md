# Why this exists, and what it cost to learn

This is the reasoning log, not a specification. The code says what it does; this
says why it does that and not the other thing. Every number here was measured,
and every rule here was paid for by getting it wrong first.

## The measurement that started it

An agent driving a Windows desktop had one option: `uia-mcp`. It works. It is
also unusable for looking around, and the reason is a single number.

```
one accessibility element, as uia-mcp reports it   ~1200 bytes
of which: providerDescription                        ~450 bytes
of which: legacyAccessiblePattern                    ~400 bytes
of which: fields an agent actually decides on        ~150 bytes
```

`providerDescription` is byte-for-byte identical for every element served by the
same provider. `legacyAccessiblePattern` is almost always a row of empty strings.
Together they are 70% of the payload and 0% of the decision.

Ten controls came to ~12 KB, which did not fit one reply, so a caller paged
through them. Looking around - the thing an agent does most - was the most
expensive thing it could do.

So the first rule:

> **PROJECTION.** Answer with the fields a decision uses. Not a summary of the
> element, not a curated view - exactly the eight fields a caller selects on,
> and nothing that is the same for every sibling.

Ten controls became 1.3 KB. One frame. 133 bytes per element.

## The second measurement, which was worse

The original tool reported `success: true` for an action. I clicked "New Tab" in
Windows Terminal and it said it worked.

Then I looked at the window and there were three tabs where there had been two.

That is not a formatting problem. A caller reads `success`, concludes the work is
done, and moves on with a false belief. So:

> **VERIFICATION.** Answer what can be proven: the target's observable state, its
> subtree size, the containing window's subtree size, and the top-level window
> count - before and after.

The first version of *this* rule was also wrong, and in an instructive way. It
compared only the target's own properties:

```json
{"did": "InvokePattern", "verified": false,
 "interpretation": "...NOTHING observable changed. treat the action as not done."}
```

The button's own state genuinely had not changed - a `SplitButton` that spawns a
tab stays a `SplitButton` - while the window's subtree went from 116 elements to
121. **An action's effect usually lands somewhere other than its target.** The
fingerprint has three readings because there are three places an effect can land:
the element, its window, and the desktop.

## The ref mistake

The first version kept refs in a hash table inside the server process:

```powershell
$script:refs["e8"] = $el     # a .NET object, alive only here
```

That is a handle into a process, and it breaks the moment anything moves: a
restart, a fork-per-call runner, a reply quoted into another conversation. It
also cannot be written down and reused, which is what a ref is for.

So refs became self-describing:

```
h262352              an HWND       -> AutomationElement.FromHandle
r42.983818.4.12      a runtime id  -> FindFirst
```

Resolved on every call. They survive a restart. A stale one fails by name
instead of silently acting on whatever is at that index now.

## Four things dogfooding found in one night

I used the server to drive Notepad - open it, find the edit control, write text,
try to save - and it broke four times. Each break was a real boundary of Windows
GUI automation, not a typo.

**1. "What is inside this window" had no tool.**
`screen_find` demanded a selector. But `under <ref>` alone is a bounded,
legitimate question, and it is the commonest one an agent asks. The rule was
right in spirit - an unbounded search walks the whole desktop - and wrong in
where it drew the line. A search with no bound is refused; a search bounded by a
container the caller named is not.

**2. A classic Win32 Edit implements no pattern at all.**
Notepad's edit control has an empty pattern list:

```json
{"ref":"h1114618","cls":"Edit","aid":"15","patterns":[],"children":0}
```

`ValuePattern.SetValue` throws *Unsupported Pattern*. The control speaks
`WM_SETTEXT`. So `setvalue:` falls back to that when the element has an HWND -
and says which path it took in `did`, because a caller debugging a failed write
needs to know whether the pattern or the message was used.

**3. `WM_SETTEXT` does not mark the document dirty.**
This one cost the most, because everything looked right. The text was in the
control, `screen_inspect` read it back, the reply said `verified: true` - and
`Ctrl+S` did nothing, no dialog appeared, and the title stayed "Untitled".

Notepad keeps its own modified flag. Typing sets it; `WM_SETTEXT` does not. With
no modified flag the Save menu item is greyed out and the accelerator is dead.
The fix is `EM_SETMODIFY` right after the write, because that is the part of
"typing" the application actually reacts to.

**4. A disconnected RDP session has no foreground window.**
`SendKeys.SendWait` failed with *Access is denied* - it installs a journal hook,
which an unattended console session refuses. Replacing it with `keybd_event`
made the call succeed, and the keys still went nowhere, because:

```
setfg      = False
foreground = 0
```

`GetForegroundWindow` returns zero when the session has no active viewer. There
is no window to receive input; `keybd_event` writes into a queue nothing reads.
**The call succeeds and nothing happens** - the exact failure mode this server
exists to eliminate, arriving through a door I had not checked.

So `screen_keys` now reads the foreground window and says so:

```json
{"sent":"^s","foreground":false,
 "note":"NO FOREGROUND WINDOW: this desktop has no active viewer ... treat the
         action as NOT done. Connect to the desktop, or drive the app through
         patterns instead of keys."}
```

The rule that generalises: **an action whose effect is unobservable must say it
is unobservable, not report success.**

## Five things the second dogfood run found

Running the whole Notepad lifecycle - open, write, close, dismiss, exit - end to end
surfaced five more boundaries. All five are the same shape: **the call succeeds and
the effect does not happen.**

**1. A classic Win32 dialog button has no `InvokePattern` either.**
The Save button in the Save-As dialog reports `type: Pane`, not `Button`, and its
pattern list is empty. `invoke` therefore falls through a chain:
`InvokePattern` -> `WM_COMMAND(IDOK)` -> `BM_CLICK` -> coordinate click. The reply
says which rung it used, because "the button was pressed" and "WM_COMMAND was
posted" are different facts.

**2. A DirectUI dialog button has no control id.**
The "Don't Save" button in the "Save changes?" box has `aid: CommandButton_7`,
which is a DirectUI name, not a Win32 control id - so `WM_COMMAND` cannot address
it. That is what `click` exists for.

**3. `SetCursorPos` succeeds in session 0 and moves nothing.**
Measured, in the same shell:

```
session 0:  before=0,0  after=0,0
session 2:  before=787,462  after=600,400
```

A cursor is a property of an interactive session, not of a process. The same is
true of every input API: they do not error from the wrong session, they simply do
nothing.

**4. A mouse click needs the window in the foreground.**
`mouse_event` at the right coordinates did nothing while another window was
active - Windows eats the activation click. `click` now calls
`SetForegroundWindow` on the element's top-level window first, exactly as
`screen_keys` does.

**5. Keys go to whatever has focus, which may not be what you are looking at.**
`%n` was meant for the "Don't Save" button and landed in the PowerShell window,
because the dialog had not been brought forward. The reply said so - `FOCUSED` was
on the wrong window - which is why `screen_keys` returns the whole top-level list
with its flags instead of a bare "sent".

The rule these five share, and the one worth carrying out of this project:

> **An input call cannot fail loudly. Nothing in Windows refuses a keystroke or a
> click from the wrong session, the wrong foreground, or the wrong focus - it
> accepts the call and discards the input.** So every input tool must report where
> the input was aimed, and the caller must check that the world moved.

## Two PowerShell traps worth writing down

**`$args` and `$pid` are automatic variables.** A tool parameter named `pid` is
silently shadowed by the process id; a function parameter named `$args` is
silently shadowed by PowerShell's own argument array. Both failures look like
"the argument did not arrive". This server uses `procId` and `$ta`.

**A bounding rectangle can be infinite.** A window that reports no bounds returns
`Infinity`, and casting that to `int` throws. Clamp it; the `off` flag already
carries the meaning.

## What is deliberately not here

- **No full property bag.** Nothing in this server's job needs
  `providerDescription`. If a caller ever does, that is a new tool with a new
  reason, not a flag on this one.
- **No OCR, no screenshots.** Pixels are the fallback when accessibility fails,
  and accessibility fails less often than it is blamed for. Adding an image
  pipeline before exhausting the tree would be reaching for the expensive tool
  first.
- **No caching of elements across calls.** See the ref section: a cached handle
  is a stale handle, and a stale handle that still resolves is worse than one
  that fails.
