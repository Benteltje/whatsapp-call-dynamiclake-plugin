# WhatsApp Call · DynamicLake plugin

[Download the latest release ZIP](https://github.com/Benteltje/whatsapp-call-dynamiclake-plugin/releases/latest/download/WhatsAppCall.dynamiclakeplugin.zip) · [Download the current main-branch build](https://github.com/Benteltje/whatsapp-call-dynamiclake-plugin/raw/refs/heads/main/WhatsAppCall.dynamiclakeplugin.zip)

Shows a detected WhatsApp call in the macOS notch: a tilted green `phone.fill` SF Symbol on the left and the live waveform on the right in the compact activity, with microphone, camera and End controls in the sneak peek.

An independent community integration. WhatsApp's Accessibility interface can change; detection and control availability depend on the installed macOS app and permissions.

## Authors

Developed by Benteltje with contributions by **Rafael Reverberi**.

## Requirements

- macOS 14.2 or later, Apple Silicon or Intel
- DynamicLake Pro with JSON plugin support
- WhatsApp macOS (`net.whatsapp.WhatsApp`)
- For building: Xcode Command Line Tools; Python 3 for tests

## Build and test

```sh
./scripts/build.sh
./tests/run.sh
```

Following the [CleanMyMac plugin's structure](https://github.com/Benteltje/cleanmymac-dynamiclake-plugin), source lives in `Sources/`, build tooling in `scripts/` and checks in `tests/`.

Outputs:

- `build/WhatsAppCall.dynamiclakeplugin/` — installable package with universal executable
- `WhatsAppCall.dynamiclakeplugin/` — latest complete installable package in the repository root
- `WhatsAppCall.dynamiclakeplugin.zip` and `.sha256` — stable root download refreshed by every build
- `dist/WhatsAppCall-1.2.10.dynamiclakeplugin.zip` — versioned release archive
- Matching `.sha256` checksum

The root package, stable ZIP and checksum are committed so GitHub users can download without building. Intermediate `build/` and `dist/` output remains ignored. The package contains only runtime files and documentation. Older release archives are preserved when rebuilding.

The official light/default WhatsApp icon is extracted from the installed WhatsApp app; attribution and hashes are in `Assets/provenance.json`.

Tests use a local mock DynamicLake socket and synthetic sessions. They never start a WhatsApp call, click real controls, or open audio capture. They cover framing, fragmented actions, settings changes, dismissal/restart, disconnects, payload/image limits and package contents. `--demo-json` also works entirely offline.

## Install

Use the latest-release download link above, download `WhatsAppCall.dynamiclakeplugin.zip` from the repository root, or build locally. Install the ZIP/package through DynamicLake Settings → Plugins → Install Local, then reload the plugin using its OK button. Rebuild and reinstall through the host instead of replacing an installed executable: DynamicLake may track package hashes.

Building and testing do not install the plugin or restart DynamicLake.

## Permissions

Desktop detection needs Accessibility permission for the plugin's host in System Settings → Privacy & Security → Accessibility. It reads the `Calling_Window` group and localized control descriptions. English labels are the fallback if WhatsApp's bundled localization layout changes.


Real audio levels require the applicable macOS microphone/system-audio authorization. Samples become loudness values in memory; nothing is recorded or sent to a remote service. Orange is you: it measures the default microphone, which may differ from WhatsApp's selected input. Green is the other participant: it measures the WhatsApp app output. By default only an already-authorized microphone is opened: no microphone permission is requested, and system-audio capture is off. The optional Other Participant Audio setting enables app output capture and may request system-audio permission. Preview sessions never access real audio and use explicitly simulated levels.

The orange waveform uses CoreAudio’s echo-aware local speech detection when the current default input device supports it. When no local speech is detected, orange stays flat even if the raw microphone hears loudspeaker playback. Your own speech can still show while the other participant speaks. This gates the display only; it does not change WhatsApp’s microphone stream or output volume. Device changes reattach the detector; unsupported devices or failed detector setup/read fall back to microphone levels. Speaker isolation is device-dependent and is not guaranteed on every audio route. App-output capture stays optional and is not required by this detector.

## Settings

| Setting | Default | Behavior |
| --- | --- | --- |
| Refresh | 1 s | Active-call fallback, 0.5–5 s |
| WhatsApp Desktop App | on | Native Accessibility detection |
| Diagnostic Activity | off | Synthetic preview without a call or audio capture |
| Live Waveform | on | Waveform on the right: your levels, orange, using existing permission |
| Other Participant Audio | off | Optional app output levels; may need system-audio permission |
| Microphone Sensitivity | 0.9 | Orange only, 0.5–1.5: lower requires louder speech; higher responds more strongly |

## Efficiency and reliability

WhatsApp launch, quit and system wake notifications trigger detection; unrelated app launches do not. Accessibility notifications are registered on both WhatsApp and its actual windows, with event bursts coalesced. Without a call, fallback detection runs every 60 seconds if WhatsApp accepts window-created notifications, or every 15 seconds if it does not. When WhatsApp is closed, detection runs only every 5 minutes as a safety check. An active call keeps the selected refresh rate.

The plugin sleeps on native run-loop sources instead of checking the socket every second. Incoming host actions and disconnects wake it immediately. File and directory watchers reload settings on in-place writes and atomic replacement, with a 60-second recovery check. Observer maintenance runs at most once per minute, or immediately after WhatsApp launch/quit or system wake. AX tree reads retain their node budget, overall traversal deadline and per-message timeouts.

This is an event-driven macOS integration: WhatsApp does not need to connect to the plugin. The plugin subscribes to OS notifications exposed by the app. Because notification support and delivery depend on WhatsApp, occasional fallback checks remain necessary; this is not a guaranteed direct call-event API.

Meters close when hidden, disabled or ended. The microphone is released when mute state is unknown or muted, or its permission is unavailable. Quiet speech uses a compressed gain curve with a −80 dBFS silence gate and faster recovery after loud words. Calibration resets after every call. Waveform updates affect only the compact surface and skip unchanged frames even as elapsed time passes, reusing unchanged waveform images. A setting change also updates the full activity.

A dismissal stays attached to the same detected session despite mic/camera changes. A quiet gap clears it for a subsequent call. Very rapid consecutive calls in the same app may be indistinguishable if no quiet gap is observed. The tilted green phone symbol owns the left slot as a native symbol and the live waveform owns the right one; the activity requests the middle (normal) compact size. The compact surface only updates when the waveform changes, and never opens audio capture just to show state. Your microphone draws orange bars on the left half of the waveform and the far end draws green bars on the right half. When app-output capture is disabled the green bars remain flat; they never mirror the microphone. Socket disconnects and malformed frame lengths terminate the monitor clearly; DynamicLake is responsible for restarting it.

## Diagnostics

```sh
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --self-test
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --demo-json
./build/WhatsAppCall.dynamiclakeplugin/whatsapp-call-monitor --check
```

`--audio-check` measures the default microphone for 3 seconds only when permission is already granted, reporting buffer count and RMS without recording. It never opens app-output capture or requests permission.

`--check` reads live permissions and native call state. It never presses controls or starts audio. Its terminal output can contain window titles; inspect it privately.

Per-frame audio diagnostics are off by default; enable `DYNAMICLAKE_WHATSAPP_DEBUG=1` only for troubleshooting.

Debug log: `~/Library/Application Support/DynamicLake/PluginLogs/whatsapp-call-debug.log`, rotated at 512 KiB.

## CI and releases

`.github/workflows/ci.yml` builds and tests on macOS for main pushes, pull requests and manual runs, retaining ZIP/checksum artifacts. After a successful main-branch build, it commits only the refreshed root package/ZIP/checksum back to main, provided no newer source commit has arrived. `.github/workflows/release.yml` validates that a `vX.Y.Z` tag matches `plugin.json`, builds/tests, then publishes a GitHub release with the package and checksum.

To release, update the manifest and changelog, run `./tests/run.sh`, commit the source and refreshed root artifacts, then push the matching version tag. Releases include both the versioned ZIP and the stable `WhatsAppCall.dynamiclakeplugin.zip` name, so the latest-release download link continues to work. These workflows run only once committed/pushed to GitHub; local validation does not establish that remote CI has run.

See [third-party notices](THIRD_PARTY_NOTICES.md) for asset attribution and audio limitations.
