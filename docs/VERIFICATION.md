# VSound verification record

Date: 2026-11-25

Environment: macOS 27.2.1 on Apple Silicon, Xcode 27.2, Swift 6.4.2. Minimum deployment target: macOS 14.

## Automated checks

- `swift test`: 18 XCTest cases passed, zero failures.
- Queue checks cover sequential playback, repeat-one versus manual skip, repeat-all, shuffle exhaustion, real playback history, play-next, and missing-track removal.
- Audio tests exercise real AVAudioEngine playback while muted, pause, seek, completion, missing-file errors, and offline PCM rendering through the same native EQ configuration used by the app.
- Offline EQ test checks that a +6 dB adjustment at 1 kHz produces +6 dB, within 0.5 dB, in rendered samples; bypass restores the baseline.
- Lyrics checks cover fractional timestamps, multiple tags, offsets, invalid timestamps, plain text, UTF-16, local-file preference, metadata URL encoding, offline cache reuse, and HTTP 404/429/503 handling.
- Library checks cover nested audio discovery, symlink exclusion, unchanged-file reuse, search across fields, JSON round-trip, atomic state writing, and preserving unreadable state.
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

## Not validated

- Physical media-key/headset input and a human pressing global shortcuts while another app has focus.
- Bluetooth, USB DAC, and unplug/replug device transitions.
- Sustained performance with tens of thousands of tracks or frame-rate profiling with Instruments.
- Runtime execution on Intel Macs or macOS versions older than the current host; both architectures compile.
- Broad listening evaluation of the independently designed sound presets across speakers and headphones.

Folder watching, gapless scheduling, crossfade, ReplayGain analysis, online music downloading, and streaming-service accounts are not implemented. Manual rescan is available through Command-R. Network lyrics are optional and default off.
