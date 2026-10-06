# Changelog

## 1.1.3

- Default to a small activity with native green phone.fill on the left and plain elapsed text on the right.
- Remove the combined icon/time bitmap, which was clipped by the host's image slot.
- Use small activity size on both full and compact updates.
- Keep the waveform as an optional alternate compact appearance; time mode does not open audio meters or render waveform images.
- Verify default slot types, time ticks and switching between time and waveform layouts.

## 1.1.2

- Compact left slot shows the green phone.fill SF Symbol beside green elapsed time.
- Green far-end bars come first, orange local microphone bars last, matching the supplied reference.
- Preserve both sides of the waveform; unavailable far-end audio stays flat.
- Cache the phone/time image per second and keep elapsed time updating even in silence.
- Color sampling self-tests and socket tests verify channel order and changing elapsed images.

## 1.1.1

- Use the official default/light WhatsApp app icon with source and hashes recorded.
- Replace the compact left text glyph with the green `phone.fill` SF Symbol.
- Reuse already-granted microphone permission only; never request it automatically.
- App-output capture is optional and off by default to avoid new system-audio prompts.
- A single green microphone waveform fills the right slot by default; optional app output adds orange levels.
- Synthetic preview animates without audio capture; socket tests verify changing image frames.
- Add a short microphone diagnostic that runs only with existing permission.
- Include a small explicit inline icon instead of relying on the executable's app icon.

## 1.1.0

- Universal arm64/x86_64 build, installable package, versioned ZIP and SHA-256 checksum.
- macOS CI and tested tag-based GitHub releases.
- Workspace lifecycle and Accessibility event monitoring, with 3-second idle and 15-second closed-app fallback checks.
- Browser scans bounded to 4 seconds with active-browser priority and rotating fallback order.
- Unchanged waveform PNGs are cached.
- Settings cached for 5 seconds; waveform setting changes republish the full surface.
- Accessibility reads bounded by node count and elapsed time.
- Disconnect, oversized incoming frames, SIGPIPE and stalled socket writes handled explicitly.
- Child-process output no longer fills undrained pipes.
- Dismissal identity remains stable across microphone/camera changes.
- Preview/test sessions never open real microphones or process audio taps.
- Exact WhatsApp Web host checks and tab URL revalidation before actions.
- Replace macOS 27-only microphone API with the compatible AVAudioEngine tap API.
- Safe self-tests and local socket integration tests without real calls.

## 1.0.0

- Initial desktop/web call detection, controls and audio waveform.
