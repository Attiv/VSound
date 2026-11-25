# VSound 1.1 implementation scope

Baseline: `926c877`, native macOS 14+ SwiftUI / AVAudioEngine, no runtime dependencies. The user approved all features proposed after 1.0. Preserve existing library state, security-scoped folder access, music files, EQ, shortcuts, and optional network access. Existing dark graphite/amber tokens and native controls remain authoritative.

| ID | Deliverable | Acceptance |
| --- | --- | --- |
| FR-01 | Multi-source lyrics | LRCLIB, NetEase, QQ Music, Kugou adapters; source selection, lazy lyric retrieval, visible per-source errors, persistent chosen result, cancellable missing-lyrics matching. Live availability reported separately from fixture tests. |
| FR-02 | Playlists | Create, rename, remove, add songs, reorder, persist, import/export local M3U/M3U8; importing never grants itself file access or changes source music. |
| FR-03 | Automatic library updates | Native filesystem observation with debounce, incremental scanner reuse, cancellation and offline-folder protection. |
| FR-04 | Loudness normalization | Track/album/off modes, gated K-weighted analysis, bounded playback gain with peak protection, cached measurements, reference-tone tests; music files remain unchanged. |
| FR-05 | Desktop lyrics | Floating panel, drag, lock/click-through, font size/opacity, original/translation display, menu command and settings access, reduced-motion support. |
| FR-06 | Continuous playback | Prebuffered next track, configurable crossfade, correct queue history/shuffle/repeat, pause/seek/skip cancellation, mixed-rate decoding and audio tests. |
| FR-07 | Output profiles | Enumerate/select output devices, restore per-device EQ/volume, default-device and unplug handling. |
| FR-08 | Update check | Read GitHub latest release, compare semantic versions, show result and open a validated project release page; no automatic installer or remote code execution. |
| FR-09 | Cloud management | Download-task status/history/retry/cancel, managed-cache size and selected cleanup with confirmation and library-index consistency. |
| FR-10 | Delivery | Tests, universal Release build, visual/native UI checks, graphify update, documentation and installed-app upgrade with backup. |

Implementation order: persistence/playlists and update client; lyrics adapters; filesystem watcher and device controller; loudness/continuous audio; desktop and settings surfaces; cloud management; review, checks and local installation.

Network OAuth application IDs and account approval must come from the maintainer. They cannot be invented or obtained from someone else's app. Account-level acceptance remains pending until configured credentials and user-controlled sign-in are available; all independent work proceeds. Third-party lyric endpoints are isolated adapters with explicit failures and no embedded credentials. Native audio and filesystem APIs are used directly.

Release publication and Git writes follow the user's existing repository instructions; this development request does not silently replace the published 1.0.0 artifact. Completion evidence will be recorded in `docs/VERIFICATION.md`.
