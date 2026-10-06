# WhatsApp Call · DynamicLake plugin

Shows a detected WhatsApp call in the macOS notch: a green `phone.fill` SF Symbol on the left and compact elapsed time on the right in the compact activity, with microphone, camera and End controls in the sneak peek.

An independent community integration. WhatsApp's Accessibility and web interfaces can change; detection and control availability depend on the installed app/browser and permissions.

## Requirements

- macOS 14.2 or later, Apple Silicon or Intel
- DynamicLake Pro with JSON plugin support
- WhatsApp macOS (`net.whatsapp.WhatsApp`), or a supported browser with WhatsApp Web
- For building: Xcode Command Line Tools; Python 3 and Node.js 18+ for tests

## Build and test

```sh
./scripts/build.sh
./tests/run.sh
```

Following the [CleanMyMac plugin's structure](https://github.com/Benteltje/cleanmymac-dynamiclake-plugin), source lives in `Sources/`, build tooling in `scripts/` and checks in `tests/`.

Outputs:

- `build/WhatsAppCall.dynamiclakeplugin/` — installable package with universal executable
- `dist/WhatsAppCall-1.1.3.dynamiclakeplugin.zip` — versioned release archive
- Matching `.sha256` checksum

Generated output is ignored by Git. The package contains only runtime files and documentation. Older release archives are preserved when rebuilding.

The official light/default WhatsApp icon is extracted from the installed WhatsApp app; attribution and hashes are in `Assets/provenance.json`.

Tests use a local mock DynamicLake socket and synthetic sessions. They never start a WhatsApp call, click real controls, or open audio capture. They cover framing, fragmented actions, settings changes, dismissal/restart, disconnects, payload/image limits and package contents. `--demo-json` also works entirely offline.

## Install

Download a GitHub release ZIP or build locally. Install the ZIP/package through DynamicLake Settings → Plugins → Install Local, then reload the plugin using its OK button. Rebuild and reinstall through the host instead of replacing an installed executable: DynamicLake may track package hashes.

Building and testing do not install the plugin or restart DynamicLake.

## Permissions

Desktop detection needs Accessibility permission for the plugin's host in System Settings → Privacy & Security → Accessibility. It reads the `Calling_Window` group and localized control descriptions. English labels are the fallback if WhatsApp's bundled localization layout changes.

Web detection uses Apple Events in Safari, Safari Technology Preview, Chrome, Edge, Brave, Arc, Vivaldi and Chromium. It needs Automation permission and **Allow JavaScript from Apple Events** in the browser's developer settings. Calls are primarily recognized by visible end/mic/camera controls; current web matching uses English control labels and is not guaranteed for every web language.

Real audio levels require the applicable macOS microphone/system-audio authorization. Samples become loudness values in memory; nothing is recorded or sent to a remote service. Orange measures the default microphone, which may differ from WhatsApp's selected input. Green measures the app process, so browser audio may include other tabs. By default only an already-authorized microphone is opened: no microphone permission is requested, and system-audio capture is off. The optional Other Participant Audio setting enables app output capture and may request system-audio permission. Preview sessions never access real audio and use explicitly simulated levels.

## Settings

| Setting | Default | Behavior |
| --- | --- | --- |
| Compact Appearance | Phone + time | Small phone/time layout; optional phone/waveform layout |
| Refresh | 1 s | Active-call fallback, 0.5–5 s |
| WhatsApp Desktop App | on | Native Accessibility detection |
| WhatsApp Web In Tabs | on | Apple Events browser detection |
| Fallback Without JavaScript | on | In-call URL fallback with unknown state; an URL alone cannot prove a live call |
| Diagnostic Activity | off | Synthetic preview without a call or audio capture |
| Live Waveform | on | Your microphone levels using existing permission |
| Other Participant Audio | off | Optional app output levels; may need system-audio permission |

## Efficiency and reliability

Workspace launch, quit and wake notifications trigger detection; native Accessibility window/value/layout notifications provide additional refreshes when WhatsApp supports them. Event bursts are coalesced. Fallback detection runs every 3 seconds while a relevant app is idle and every 15 seconds when closed; an active call uses the selected refresh rate. Browser-only calls rely on these fallback checks.

Settings are read at most once every 5 seconds. The run loop services events between checks, with a slower idle action cadence. AX tree reads have a node budget, an overall traversal deadline and per-message timeouts. Each browser scan has a 4-second budget, prioritizes the active browser and rotates other browsers to avoid starvation. Unsupported observer notifications fall back to polling.

Meters close when hidden, disabled or ended. The microphone is released when mute state is unknown or muted, or its permission is unavailable. Waveform updates affect only the compact surface and skip unchanged frames, reusing unchanged waveform images. A setting change also updates the full activity.

A dismissal stays attached to the same detected session despite mic/camera changes. A quiet gap clears it for a subsequent call; URL-only leftovers need a longer quiet period. Very rapid consecutive calls in the same app may be indistinguishable if no quiet gap is observed. The phone and elapsed time use separate native slots and the activity requests small size. Time mode updates once per second and never opens audio capture. Waveform mode replaces the right-hand time with green far-end bars followed by orange microphone bars. When app-output capture is disabled, the green bars remain flat; they never mirror the microphone. Socket disconnects and malformed frame lengths terminate the monitor clearly; DynamicLake is responsible for restarting it.

## Diagnostics

```sh
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --self-test
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --demo-json
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --check
```

`--audio-check` measures the default microphone for 3 seconds only when permission is already granted, reporting buffer count and RMS without recording. It never opens app-output capture or requests permission.

`--check` reads live permissions, desktop state and browser tabs. It never presses controls or starts audio, but may trigger browser Automation prompts. Its terminal output can contain window titles/tab URLs; inspect it privately.

Debug log: `~/Library/Application Support/DynamicLake/PluginLogs/whatsapp-call-debug.log`, rotated at 512 KiB. Routine browser diagnostics omit tab titles, URLs and control text.

## CI and releases

`.github/workflows/ci.yml` builds and tests on macOS for main pushes, pull requests and manual runs, retaining ZIP/checksum artifacts. `.github/workflows/release.yml` validates that a `vX.Y.Z` tag matches `plugin.json`, builds/tests, then publishes a GitHub release with the package and checksum.

To release, update the manifest and changelog, commit, then push the matching version tag. These workflows run only once committed/pushed to GitHub; local validation does not establish that remote CI has run.

See [third-party notices](THIRD_PARTY_NOTICES.md) for asset attribution and audio limitations.
