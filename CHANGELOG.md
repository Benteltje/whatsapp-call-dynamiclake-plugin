# Changelog

## 1.2.8

- Focus detection and call controls exclusively on the native WhatsApp macOS app.
- Simplify session identity and dismissal tracking around native call windows.
- Reduce settings and test dependencies to the native integration.

## 1.2.7

- Slightly reduce waveform gain from 1.25 to 1.15 (8% lower for bars below the height limit), keeping quiet speech visible.

## 1.2.6

- Reduce idle socket checks from four to one per second, slow absent-app observer retries to 15 seconds and coalesce idle AX events over 0.75 seconds.
- Disable continuous audio diagnostics by default and omit unchanged waveform updates when only elapsed time changes.
- Make quiet speech more visible with a compressed gain curve, a lower silence gate and faster peak recovery. Reset calibration between calls.
- Draw your microphone in orange and remote app output in green. Muted input remains gray; remote audio capture stays optional.
- Refresh stale integration expectations to cover the current compact waveform layout.

## 1.2.5

- Fix the waveform freezing when the call connects while you are already talking: the microphone engine used to be interrupted by the call app taking the input, hold its last level forever, and the unchanged-frame guard then suppressed every update. The meter now detects a stalled input (no buffer for 0.5 s), draws flat instead of a stale value, and restarts the engine automatically (at most once per 3 s).
- Failed microphone starts retry after 2 s instead of 55 s.
- The per-second waveform log line now includes a `stale` flag, and engine restarts are logged.

## 1.2.4

- Compact activity requests the middle size (`normal`) instead of the widest (`large`).

## 1.2.3

- The compact left slot shows only the tilted green `phone.fill` symbol, drawn by the host as a native SF Symbol; the elapsed time is removed from the compact surface.
- Without the per-second icon/time bitmap, frames now go out only when the waveform actually changes.

## 1.2.2

- Lower the waveform's silence floor from −45 to −60 dBFS: raw microphone RMS for quiet speech can sit below −45 dB, which made normal talking draw as silence and only screams register.
- Smooth the microphone reading with a median of the last three buffers, so single-buffer device clicks cannot pin the peak reference above a real voice.
- Cap how much one tick may raise the peak reference (~12 dB), and log mic level, peak, bar height and input device to the plugin debug log once per second during calls.

## 1.2.1

- Waveform height is now calibrated against the loudest recent moment instead of a fixed −50…−10 dBFS ramp, so normal talking fills to about half the bar height regardless of microphone gain.
- Peak reference attacks instantly on a new loud moment and releases slowly, so pauses between sentences do not collapse the bars.
- Stop sending the `extraLiveActivity` surface: the JSON plugin schema only allows `compactLiveActivity` and `sneakPeek`.

## 1.2.0

- Compact activity shows the green `phone.fill` symbol with the elapsed time beside it in the left slot, and the live waveform in the right slot — both at once instead of a mutually exclusive appearance setting.
- Request the large compact size (351 x 33 pt with 77 pt side slots) so the icon, the time and the waveform fit side by side.
- Draw the icon and duration into a single bitmap, since the host allows one component per slot and gives the left slot a symbol-sized frame.
- Restore the meter colours: your microphone is green on the left half of the waveform, the other participant is orange on the right half.
- Remove the `Compact Appearance` setting; `Live Waveform` now switches the right-hand waveform itself.

## 1.1.4

- Every build refreshes the complete `WhatsAppCall.dynamiclakeplugin` package, stable ZIP and checksum in the repository root.
- Commit ready-to-install root artifacts for direct downloads without a local build.
- Successful main-branch CI refreshes the root artifacts automatically, with a source-head check before pushing.
- Release assets include the stable ZIP name as well as the versioned archive.
- Add tests that verify root/build package equality and stable/versioned ZIP and checksum consistency.

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
- Unchanged waveform PNGs are cached.
- Settings cached for 5 seconds; waveform setting changes republish the full surface.
- Accessibility reads bounded by node count and elapsed time.
- Disconnect, oversized incoming frames, SIGPIPE and stalled socket writes handled explicitly.
- Dismissal identity remains stable across microphone/camera changes.
- Preview/test sessions never open real microphones or process audio taps.
- Replace macOS 27-only microphone API with the compatible AVAudioEngine tap API.
- Safe self-tests and local socket integration tests without real calls.

## 1.0.0

- Initial native call detection, controls and audio waveform.
