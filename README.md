# ScreenBar

A small macOS menu bar app that opens and closes Apple's Screenshot palette
(the Cmd-Shift-5 capture bar) from one click.

- **Left-click the camera icon** — toggles the Screenshot palette open/closed.
- **Right-click (or Control-click)** — menu: Open/Close Screenshot, Open at Login, Quit.
- The icon shows state: plain camera when closed, viewfinder camera when open.
- Clicking the icon **while a screen recording is running stops it and saves it** to your
  screenshot save folder (default: Desktop) — see [Recording hand-off](#recording-hand-off).
- No Accessibility or Screen Recording permission needed. **Full Disk Access is needed only
  for the recording hand-off** (see [Permissions](#permissions)).

Runs as an agent app (`LSUIElement`) — no Dock icon, no menu bar menus of its own.

## Build and install

```sh
scripts/build.sh      # builds, ad-hoc signs, installs to ~/Applications
open ~/Applications/ScreenBar.app
```

To also write a drag-to-Applications disk image:

```sh
scripts/build.sh --dmg ~/Desktop     # writes ~/Desktop/ScreenBar.dmg (and installs, as above)
```

The DMG is ad-hoc signed, **not notarized**: on another Mac, Gatekeeper will block the first
launch — right-click the app → Open (or allow it in System Settings → Privacy & Security).

Builds in `/private/tmp` on purpose: files created under `$HOME` pick up a
`com.apple.provenance` xattr that makes `codesign` fail on a Swift binary.

## How it works

`Screenshot.app` is only a launcher. It spawns `/usr/sbin/screencapture` (the process that
owns the palette) plus the resident `screencaptureui` service, then exits immediately — so
it never shows up as a running application you could quit.

So:

- **Is the palette open?** → is there a live *interactive* `/usr/sbin/screencapture` process?
  Only interactive invocations carry an `i` flag (`-zsuis_msg-… -uUpi`), which is how a
  scripted `screencapture -x out.png` is excluded from counting.
- **Open** → `NSWorkspace.openApplication` on `Screenshot.app`.
- **Close** → `SIGINT` that process. Same result as pressing Escape, without needing
  Accessibility permission to synthesize a keystroke. **Never `SIGTERM`:** it discards an
  in-progress recording without writing a file; `SIGINT` finalizes it.

Because the palette is also spawned by the system hotkeys, the toggle closes a palette the
user opened from the keyboard too.

### The outside-click trap

Clicking the menu bar icon is a click *outside* the palette, so macOS dismisses the palette
**before** the status item's action method runs. A naive `if open { close } else { open }`
therefore always reads "closed" at click time and **reopens** the palette the user was
trying to close. Caught in testing; fixed by remembering when the palette was last seen open
(1 s poll, 1.5 s memory window) and treating a very recent sighting as still-open.

### Recording hand-off

The palette process doesn't go away when you press Record — the same `screencapture` process
becomes the recorder, so it looks identical to an open palette. And the stop button in the
menu bar sits right beside this app's icon, so a click meant as "stop" often lands here.

macOS writes an in-progress recording to a hidden staging folder as `<UUID>.mov`:

    ~/Library/Group Containers/group.com.apple.screencapture/ScreenRecordings/

and moves it to the save location only when **Apple's own Stop button** is used. Killing the
recorder any other way leaves the finished movie stranded there — no error, nothing on the
Desktop. (Found 2026-11-23: recordings "weren't saving"; they were all in that folder.)

So on a click, if a staged `.mov` was modified in the last 3 s (= a recording is live), this
app stops the recorder with `SIGINT`, waits for the process to exit and the file to stop
growing, then moves it to the save folder (`defaults read com.apple.screencapture location`,
else `~/Desktop`) as `Screen Recording yyyy-MM-dd at h.mm.ss a.mov`. Starting and stopping with
Apple's own controls (Cmd-Shift-5, Stop button, Cmd-Ctrl-Esc) is untouched.

Not an `Accessibility` approach (posting Cmd-Ctrl-Esc so macOS does the save itself) because
that needs a different permission and was not tried.

## Permissions

The hand-off needs to read the staging folder, which macOS blocks for any app without
**Full Disk Access** (`Operation not permitted`, no prompt). Without it, opening and closing
the palette still work, but a recording stopped from this icon is **not** moved to the Desktop.

1. System Settings → Privacy & Security → Full Disk Access → **+** → `~/Applications/ScreenBar.app` → on.
2. ⛔ **Every rebuild drops the grant** — the app is ad-hoc signed, so the permission is bound to
   the code hash. Re-add (or toggle off/on) after running `scripts/build.sh`.

Check whether the grant is live (prints `ok: N entries` or `ERROR: …`):

```sh
open -n -W ~/Applications/ScreenBar.app --args --selftest /private/tmp/sb_self.txt; cat /private/tmp/sb_self.txt
```

## Verified

Driven with synthetic CGEvents against the real menu bar:

- click → palette opens; click → palette closes (no respawn); click → opens again
- icon art changes between the two states
- recording started from the icon, stopped by clicking the icon → file lands on the Desktop
  (2026-11-23, with Full Disk Access granted); stopped with Apple's Stop button → also fine
- right-click menu renders; "Open at Login" registers and unregisters via `SMAppService`
  (left **off** after testing)

## Layout

```
Sources/main.swift      the whole app (incl. the `--selftest <file>` permission check)
Resources/Info.plist    bundle metadata (LSUIElement)
Resources/AppIcon.icns  app icon (generated — see scripts/make-icon.swift)
scripts/build.sh        build + ad-hoc sign + install (+ optional --dmg <folder>)
scripts/make-icon.swift the icon generator: SF Symbol camera.viewfinder on a dark tile
LICENSE                 MIT
```

## License

MIT — see [LICENSE](LICENSE).
