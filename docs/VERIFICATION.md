# VSound verification record

Date: 2026-11-25

Environment: macOS 27.2.1 on Apple Silicon, Xcode 27.2, Swift 6.4.2. Minimum deployment target: macOS 14.

## Automated checks

- `swift test`: 37 XCTest cases passed, zero failures (18 existing cases and 19 cloud-storage cases).
- Queue checks cover sequential playback, repeat-one versus manual skip, repeat-all, shuffle exhaustion, real playback history, play-next, and missing-track removal.
- Audio tests exercise real AVAudioEngine playback while muted, pause, seek, completion, missing-file errors, and offline PCM rendering through the same native EQ configuration used by the app.
- Offline EQ test checks that a +6 dB adjustment at 1 kHz produces +6 dB, within 0.5 dB, in rendered samples; bypass restores the baseline.
- Lyrics checks cover fractional timestamps, multiple tags, offsets, invalid timestamps, plain text, UTF-16, local-file preference, metadata URL encoding, offline cache reuse, and HTTP 404/429/503 handling.
- Library checks cover nested audio discovery, symlink exclusion, unchanged-file reuse, search across fields, JSON round-trip, atomic state writing, and preserving unreadable state.
- Cloud OAuth checks cover the RFC 7636 PKCE vector, read-only scopes, random state, exact callback origin/path, duplicate-parameter rejection, and redirect credential stripping/TLS downgrade rejection.
- A real loopback HTTP receiver rejects the wrong state, accepts the expected code, and releases its waiting continuation on cancellation. It uses an ephemeral test port and does not open a browser or contact either provider.
- Mock HTTP checks cover code exchange for both providers, preserving prior credentials on an invalid token response, Google Drive and Dropbox pagination, one-time refresh after HTTP 401, refresh-token persistence, HTTP 429 backoff, and provider-specific disconnection.
- A mocked Dropbox content response writes an actual temporary download and validates its byte count. Recursive import downloads generated WAV/LRC fixtures, avoids directory cycles and duplicate files, indexes playable audio, reads matching local lyrics, and reuses the finished cache on a second import.
- Cache checks cover atomic replacement, unchanged local URLs after remote renaming (including macOS `/var` aliases), same-named files with different IDs, truncated downloads, path traversal, independent lyric markers, and backward-compatible folder persistence.
- Release app built using `zsh scripts/build.sh`; the resulting executable includes arm64 and x86_64 slices.
- `codesign --verify --deep --strict build/VSound.app` passed. The app uses local ad-hoc signing, not Developer ID distribution signing or notarization.

## Live application checks

Performed through the actual macOS UI using three quiet, generated 20-second WAV files and locally authored LRC files. No personal music library was read.

- Launch the signed, sandboxed `.app` and inspect the welcome screen.
- Select a folder using NSOpenPanel, import three tracks, and inspect the resulting song table.
- Double-click a song and verify playback, duration, current-track indication, and timed local lyrics.
- Open the EQ window and select the Harman Kardon style preset; verify that the power state, all ten gains, and headroom display update.
- Open shortcut settings, confirm all three default bindings register without conflicts, record a custom next-track binding, then restore defaults.
- Run an actual LRCLIB search for public song metadata and observe returned candidates. No third-party lyrics were copied into source or fixtures.
- Quit and relaunch: verify the folder, tracks, paused playback position, volume, EQ preset, and favorite state are restored without autoplay.
- Set progress through the accessibility slider and observe the audio position update.
- Search the library and observe the filtered row count.
- Open and inspect the mini player and expanded now-playing view.
- Export an LRC through NSSavePanel and confirm that the saved UTF-8 file exists and contains the expected local timed text.

Local screenshots are stored in the ignored `artifacts/` directory. Test-only library entries are removed before handoff.

## Cloud-storage interface checks

Performed on the rebuilt, signed, sandboxed Release app. Existing user library entries and playback settings were preserved; no cloud credentials were entered and no personal cloud files were requested.

- Launch the app, open the cloud window from its toolbar, and reopen it using Shift-Command-D after a restart.
- Switch between Google Drive and Dropbox and verify the provider-specific disconnected state and disabled import button, including its dimmed appearance.
- Open account settings from the cloud window and verify that the Cloud tab is selected directly.
- Confirm that builds without application IDs show configuration instructions and disable the connect buttons, with no Keychain error displayed during provider-status loading.
- Expand developer configuration for both providers; inspect the Google Client ID/secure optional secret fields, Dropbox App key field, and exact loopback callback address. No settings values were changed.
- Scroll through cloud settings and inspect the local-sync folder entry and read-only/disconnection explanation.
- Open the system folder picker through the synced-folder entry and cancel without importing or modifying the user's library.
- Save cloud-window and settings screenshots in ignored `artifacts/cloud-browser.png` and `artifacts/cloud-settings.png`.

## Not validated

- Real Google Drive / Dropbox account authorization, provider review/production configuration, live remote-file downloading, and credential persistence/refresh through Keychain with real tokens. Maintainer-owned OAuth application IDs are not configured in this build; mock API and local callback tests do not substitute for that account-level acceptance check.
- UI layout with a real, connected cloud folder listing, long remote paths, network failures, and download cancellation against the providers. Core error handling is covered with mocks.
- Physical media-key/headset input and a human pressing global shortcuts while another app has focus.
- Bluetooth, USB DAC, and unplug/replug device transitions.
- Sustained performance with tens of thousands of tracks or frame-rate profiling with Instruments.
- Runtime execution on Intel Macs or macOS versions older than the current host; both architectures compile.
- Broad listening evaluation of the independently designed sound presets across speakers and headphones.

Folder watching, gapless scheduling, crossfade, ReplayGain analysis, music-catalog downloading, and streaming-service accounts are not implemented. Cloud storage downloads finish before playback; automatic cloud synchronization, uploads, and remote deletion are not implemented. Manual rescan through Command-R only indexes local files; re-import a cloud folder to fetch updates. Network lyrics are optional and default off.
