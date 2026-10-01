# ScreenBar

A small macOS menu bar app that opens and closes Apple's Screenshot palette
(the Cmd-Shift-5 capture bar) from one click.

- **Left-click the camera icon** — toggles the Screenshot palette open/closed.
- **Right-click (or Control-click)** — menu: Open/Close Screenshot, Open at Login, Quit.
- The icon shows state: plain camera when closed, viewfinder camera when open.
- No Accessibility or Screen Recording permission needed.

Runs as an agent app (`LSUIElement`) — no Dock icon, no menu bar menus of its own.

## Build and install

```sh
scripts/build.sh      # builds, ad-hoc signs, installs to ~/Applications
open ~/Applications/ScreenBar.app
```

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
- **Close** → `SIGTERM` that process. Same result as pressing Escape, without needing
  Accessibility permission to synthesize a keystroke.

Because the palette is also spawned by the system hotkeys, the toggle closes a palette the
user opened from the keyboard too.

### The outside-click trap

Clicking the menu bar icon is a click *outside* the palette, so macOS dismisses the palette
**before** the status item's action method runs. A naive `if open { close } else { open }`
therefore always reads "closed" at click time and **reopens** the palette the user was
trying to close. Caught in testing; fixed by remembering when the palette was last seen open
(1 s poll, 1.5 s memory window) and treating a very recent sighting as still-open.

## Verified

Driven with synthetic CGEvents against the real menu bar:

- click → palette opens; click → palette closes (no respawn); click → opens again
- icon art changes between the two states
- right-click menu renders; "Open at Login" registers and unregisters via `SMAppService`
  (left **off** after testing)

## Layout

```
Sources/main.swift      the whole app
Resources/Info.plist    bundle metadata (LSUIElement)
scripts/build.sh        build + ad-hoc sign + install
```
