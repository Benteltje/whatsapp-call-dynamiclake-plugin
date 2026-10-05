# WhatsApp Call · DynamicLake plugin

Shows an active WhatsApp call in the notch:

- **Compact** — the call glyph and elapsed time on the left, a live waveform on
  the right.
- **Sneak peek** — microphone button, red *End* button in the centre, camera
  button.

The waveform is the call itself, not decoration: **green bars on the left are
you talking, orange bars on the right are the other participant**, drawn as new
audio arrives (a frame every 120 ms). The activity is dismissed as soon as the
call ends.

Detection covers both places a WhatsApp call can live:

| Scope | How it is detected | Permissions |
| --- | --- | --- |
| WhatsApp macOS app | Accessibility tree: the call window contains an `Calling_Window` group | Accessibility |
| `web.whatsapp.com` in a browser tab | Apple Events → JavaScript in Safari / Chrome / Edge / Brave / Arc / Vivaldi | Automation + *Allow JavaScript from Apple Events* |

Desktop detection is preferred; a browser call is only used when no desktop call
is open.

---

## Install

From a clone of this repository, build first — the executable is not checked in:

```sh
swiftc -O -parse-as-library -o whatsapp-call-monitor Sources/WhatsAppCallPlugin.swift
```

Then either open `WhatsAppCall.zip` with DynamicLake (the market/install flow — this
is the path DynamicLake records with its package hashes), or copy the
`WhatsAppCall.dynamiclakeplugin` folder into:

```
~/Library/Application Support/DynamicLake/Plugins/JSON/
```

then restart DynamicLake. DynamicLake stores a SHA-256 of the package and of the
executable at install time, so rebuild → repackage → reinstall instead of
swapping files inside an installed copy.

## Permissions

**Accessibility** — required for desktop calls. Grant it when macOS asks, or in
*System Settings ▸ Privacy & Security ▸ Accessibility*. Without it the plugin
still starts, logs the problem and simply finds nothing.

**Automation (Apple Events)** — required to talk to browsers at all. macOS shows
a *Device Control and Data Access (Events)* prompt the first time; approve it.

**Microphone** — required for *your* side of the waveform. macOS asks the first
time a call is detected; if you decline, your side stays flat while the other
side keeps working. Nothing is recorded: the samples are reduced to a loudness
value in memory and never leave the plugin.

**Allow JavaScript from Apple Events** — required for the browser microphone and
camera state and for the browser controls:

- Safari: *Settings ▸ Advanced ▸ Show features for web developers*, then
  *Develop ▸ Developer Settings ▸ Allow JavaScript from Apple Events*
- Chrome and other Chromium browsers: *View ▸ Developer ▸ Allow JavaScript from
  Apple Events*

Without that switch the plugin cannot tell whether a browser call is live or
what the microphone and camera are doing. The **Fallback Without JavaScript**
setting then shows the activity for tabs sitting on an in-call URL
(`web.whatsapp.com/call/...`) with unknown microphone and camera state, so the
timer still works. Disable the fallback if you would rather see nothing than a
call with unknown state.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Refresh | 1 s | Poll interval (0.5 – 5 s) |
| WhatsApp Desktop App | on | Detect calls in the macOS app |
| WhatsApp Web In Tabs | on | Detect calls in browser tabs |
| Fallback Without JavaScript | on | Show unknown-state activity from the in-call URL |
| Diagnostic Activity | off | Show a fake call so you can preview the UI |
| Live Waveform | on | Animate green/orange voice bars in the compact strip during a call |

## Command line

```sh
./whatsapp-call-monitor --check       # permissions, label table, live detection, waveform
./whatsapp-call-monitor --demo-json   # sample create payload
```

`--check` prints the full state of the world: Accessibility trust, which
WhatsApp translations were loaded, whether a desktop call is visible, which
browsers are running, the WhatsApp Web tabs that were found, the JavaScript
result for each of them, and exactly what to enable when it fails. It also
reports microphone authorization, whether the waveform is on, and which output
device is being tapped for the other participant's side.

## Debug log

```
~/Library/Application Support/DynamicLake/PluginLogs/whatsapp-call-debug.log
```

The log is rotated once it passes 512 KB. Nothing is ever written inside the
installed package, so the plugin stays updatable.

## How the desktop detection works

WhatsApp does not localize its window titles' *identifiers*: the call window is
found through the `AXIdentifier` `Calling_Window`, so detection works in every
language. The two mirrored controls expose no value and no identifier, only an
`AXDescription`, and those descriptions are localized.

WhatsApp ships every translation in `Localizable.localite.values` files that are
parallel arrays: the string at index *n* in `en.lproj` is the same string at
index *n* in every other `.lproj`. The plugin finds the indices of `mute on`,
`mute off`, `camera on` and `camera off` in the English file at runtime and reads
the same four indices from every language WhatsApp installed (41 languages on
this machine), so it follows WhatsApp's own translations instead of a hardcoded
table. English is used as a fallback if that layout ever changes.

Two quirks are verified facts rather than guesses, both checked against the live
call UI and against the camera's CoreMediaIO streaming state:

- **The microphone description states the current state.** `mute on` means the
  microphone is muted, `mute off` means it is live.
- **The camera description states the action.** `camera off` is shown while the
  camera *is on* (pressing it turns the camera off) and `camera on` while it is
  off. WhatsApp builds that button from its `VOIP_SWITCH_TO_*` strings, which
  name the action instead of the state.

## Controls

| Control | Where | What it does |
| --- | --- | --- |
| Microphone | sneak peek, left | Presses the mute control; state comes back from the next read rather than from an assumed toggle. |
| End call | sneak peek, centre (red `phone.down.fill` button) | Presses WhatsApp's own leave button. On the web it clicks the end-call control, which needs JavaScript from Apple Events. |
| Camera | sneak peek, right | Presses the camera control. |
| Elapsed time | compact, left (`☎︎ 1:23`) | Counts from the moment the call was first detected. |
| Waveform | compact, right | Green (you) and orange (them) voice bars, redrawn every 120 ms. |

The leave button is localized too: its description (`leave call` in English) is
read from the same parallel translation arrays, 41 languages on this machine.
`--check` reports whether that button is currently visible in the call window.

## How the waveform works

Two independent meters, both only open while a call is active:

- **You (green)** — an input tap on the default microphone gives an RMS value
  per buffer. When the microphone is muted or unavailable the green history is
  forced to a flat grey line, because the meter would otherwise keep showing you
  talking while WhatsApp sends silence.
- **Them (orange)** — a CoreAudio process tap on the call app's own audio: the
  WhatsApp process for a desktop call, the browser process for a web call. A
  process tap only sees that process's stream, so what it carries is the far end
  of the call.

Each level is mapped from −50 dBFS (silent) to −10 dBFS (loud) onto 0…1, kept in
a seven-sample history per side and drawn as a 160 × 36 (@2x) PNG that travels
base64-encoded inside the frame. A frame is only sent when the bars or the
duration actually changed, so a silent call costs one frame per second instead
of eight. When the animation is off or the meters are closed, the right slot
falls back to the plugin icon.

## Payload

`create` / `update` / `dismiss` frames are 4-byte big-endian length + JSON,
≤ 64 KB:

- `compactLiveActivity` — elapsed time on the left, waveform PNG on the right
  (or the plugin icon when the waveform is off)
- `extraLiveActivity` — plugin icon
- `sneakPeek` — microphone button, red `End` button in the centre, camera button
- `priority: "high"`, `size: "large"`, `activityID: whatsapp-call.active-call`

Two kinds of frame leave the plugin:

- **Session frames** (`create`/`update`/`dismiss`) fire when the call, its title
  or the microphone/camera state changes. Their signature deliberately excludes
  the elapsed time, so the plugin does not send one frame per second just to
  keep a timer alive.
- **Waveform frames** name only `compactLiveActivity` and carry one PNG of bars
  plus the current duration, at most one every 120 ms while the call runs. The
  sneak peek is left alone, so the microphone, End and camera controls never
  flicker during the animation.

Dismissing the activity without ending the call hides it for the rest of that
call only; the next call shows again automatically.

## When it disappears

The activity has to vanish the moment the call does, and stay gone:

- **End pressed in the notch** hides it immediately instead of showing a final
  update while the call window is still closing.
- **Hanging up in WhatsApp itself** removes it as soon as detection sees no call,
  after three quiet polls (the window takes a moment to close).
- **A leftover tab cannot bring it back.** Detection used to flap: the desktop
  call ended, and a Safari tab still sitting on an in-call URL looked like a new
  call, so the activity reappeared and never went away. A tab that is only
  recognised by its URL — the fallback used when *Allow JavaScript from Apple
  Events* is off — is now treated as the leftover of the call that just ended
  and stays hidden until the tab points somewhere else, or is gone for a full
  minute. Because such a tab has no state that could prove a call is running, a
  dismissal for it is remembered by the tab's URL rather than by time.
- **A new call always shows**: a different app, tab or URL, or any call whose
  microphone and camera state is known, clears the hiding straight away.
- Swiping the activity away hides it for as long as that same call keeps being
  detected; preview sessions (Diagnostic Activity) stay hidden until the setting
  is switched off.

## Cost

The meters only exist while a call is active and the waveform setting is on, and
the microphone is released while the microphone is muted or its state is unknown
(the green side is drawn flat in that case anyway). Each loop iteration runs in
its own autorelease pool — without one, every Foundation and CoreAudio object
the process is handed would stay resident, and the plugin grew without bound.
Measured over a live call: about 22 MB resident, flat (−0.1 MB over 88 s), and
it drops back to ~19 MB once the call is hidden.

## Building

```sh
swiftc -O -parse-as-library \
  -o whatsapp-call-monitor \
  Sources/WhatsAppCallPlugin.swift
```

The package layout is `plugin.json`, `WhatsAppCallIcon.png` (512 × 512 square
PNG, no baked corners), `whatsapp-call-monitor`, `README.md` and `Sources/`.

```sh
ditto -c -k --keepParent WhatsAppCall.dynamiclakeplugin WhatsAppCall.zip
```
