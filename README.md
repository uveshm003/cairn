# Cairn

A private, offline recorder for audio and video entries. Capture with intent
(typed, tagged), find it again without friction (filter + search), keep the
device lean (real compression), and never hand any of it to a cloud.

**No network requests at all.** No account, no sync, no analytics, no paywall.

## Status

The v1 MVP from `requirements.md` §4 is built and running, and the capture
pipeline is validated against real recordings on a Pixel 7 Pro (Android 17).

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | 143 passing |
| `integration_test/capture_flow_test.dart` | 6 passing, on device |
| `integration_test/real_capture_test.dart` | 8 tests — **real recordings** (see note) |
| `flutter build apk --release` | builds (66.0 MB) |
| `flutter build ios --release --no-codesign` | builds (24.3 MB) |

Recording, compression, and both camera lenses are exercised on hardware. See
*Measured on real hardware* for the numbers, and *What is unverified* for what
is still open.

## Running it

```sh
flutter pub get
dart run build_runner build      # Drift codegen -> lib/data/database.g.dart
flutter run
```

`lib/data/database.g.dart` is generated but **is** committed, so a plain
`flutter run` works without codegen. Re-run `build_runner` after any change to
the schema in `lib/data/database.dart`.

## Layout

```
lib/
  data/        database.dart      Drift schema, DAO, FTS5 index
               library_queries.dart  the S12 filter query, storage breakdown
  domain/      encoding_profile.dart the S8 ladder
               entry_filter.dart     filter facets as a value type
  media/       media_store.dart      relative-path discipline (S9)
               save_pipeline.dart    compress -> verify -> store
  backup/      backup_service.dart   zip + versioned manifest (S11)
  settings/    app_settings.dart     key-value settings
  ui/          library capture detail settings trash onboarding lab
```

## Design

The visual language lives in `lib/ui/theme/`. Screens never invent a colour, a
gap, or a radius — `tokens.dart` owns all three, and `context.palette` reaches
tokens Material's `ColorScheme` has no slot for (`inkTertiary`, `hairline`,
`record`).

**Warm stone and paper, one accent.** §14 asks for "monochrome-friendly", and the
name supplies the rest: a cairn is a stack of weathered stones. Light mode is a
warm paper canvas; dark is a warm near-black. The single trail-marker ochre
carries actions and selection, and the only other saturated colours in the app
are the five per-type marks.

**Type carries the personality.** Fraunces (144pt optical cut) for display,
Inter for everything functional — both bundled as assets, because an offline app
cannot depend on a font CDN. Fraunces' smaller optical cuts read clumsy above
28pt, hence the explicit `opsz` pin.

**Contrast is computed, not eyeballed.** `test/theme_test.dart` calculates real
WCAG ratios for every text token against both surfaces, plus accent-on-accent-soft
and the type marks. It found a genuine defect during this pass: accent text on a
selected chip measured 4.27:1, so the light accent was darkened to clear 4.5:1
with margin.

**Dynamic type is tested, not hoped for.** `test/dynamic_type_test.dart` pumps the
library components at 1×–2× text scale on narrow screens. It found two real
clipping bugs (the meta line and the tag row), both now flow layouts that grow
the card rather than hide content.

**The mark is painted, not an asset.** `CairnMark` and `CairnScene` are
`CustomPainter`s, so they inherit the palette and scale to any size. The same
geometry generates the app icon (`assets/icon/`, fanned out by
`flutter_launcher_icons`), so the launcher icon, the wordmark, and the empty
state are visibly the same object.

**Journal, not file browser.** The library groups entries under day headings
("Today", "Yesterday", "Tuesday"), because that is how people actually remember a
recording. Grouping is suppressed while searching — the query orders by
relevance then, and day headers over a relevance-ordered list would repeat.

### Reviewing the UI with content

An empty app is hard to judge. A debug-only, flag-gated seeder fills the library
with a realistic set:

```sh
flutter run --dart-define=CAIRN_SEED_DEMO=true
```

Guarded three ways — the flag, `kDebugMode`, and "only if the library is empty" —
and const-false in release, so the whole path is tree-shaken away. Optional:
push placeholder frames to `/data/local/tmp/cairnthumbs` first and the seeder
copies them in as thumbnails. `adb shell pm clear com.example.cairn` undoes it.

## The decisions worth knowing

### Drift + SQLite FTS5, not ObjectBox

`requirements.md` §7 recommends ObjectBox; this goes the other way, because §12
says the choice hinges on how central content search is — and it is central.
§15's on-device transcription is the feature that makes this app worth using,
and it needs real full-text ranking. The `entry_search` table already carries a
`transcript` column, so that feature slots in without a schema rewrite.

FTS5 is confirmed present in the sqlite3 actually bundled with the app, not just
the host one — that is what `integration_test/capture_flow_test.dart` checks
first.

### Relative paths, always

Rows store `media/{uuid}.mp4`. iOS app-container paths change across reinstalls
and restores, so an absolute path in the database would break playback for every
restored entry. `MediaStore` is the only place a path is resolved or relativized.

### Compress → verify → store → commit, in that order

The media file is written and integrity-checked *before* the database row is
committed. A crash can leave an orphaned file (which the sweep in Settings →
Maintenance finds) but never a row pointing at a file that is not there.

The integrity check compares output duration against the source, because a
truncated encode produces a perfectly playable three-second file that a
size-only check would report as a spectacular compression win.

### One profile concept, two implementations

Video gets its bitrate by post-processing with `flutter_compress`. Audio gets
its at capture time from `record`. This is forced, not stylistic:
`flutter_compress` exposes `audioBitrateKbps` and `frameRate` on **iOS only** —
Android's Media3 exposes neither and ignores them silently. So §8's audio ladder
(32–48 / 96 / 128 kbps) cannot be applied after the fact on Android at all.

### Both lenses are first-class

§3 lists "keep a private video diary" next to "record my guitar practice", so the
front camera is not an afterthought. Capture opens with the remembered lens and
the flip is one tap; the choice persists, so a diary user never re-flips. The
default is back, because more of §3's jobs point away from you than at you.

Selection lives in `lib/domain/camera_choice.dart` as pure functions, because the
interesting cases are the odd devices: a tablet with only a front camera, a
desktop with only a USB webcam, a phone with three back lenses. Verified on
device — the flip closes `CameraId-0` and opens `CameraId-1`.

### Kept originals go somewhere durable

`keepOriginals` (§8's opt-in, off by default) moves the uncompressed source into
an `originals/` directory rather than leaving it at the camera plugin's cache
path, which the OS reclaims. Nothing in the database references those files, so
`originals/` is deliberately excluded from the orphan sweep — a sweep that saw
them would delete exactly the files the setting exists to preserve.

### Corrections to requirements.md

1. **§2's "a 30s clip can be 300–500 MB" is wrong — now measured, not argued.**
   In-app 1080p capture on a Pixel 7 Pro runs at **16.7 Mbps**, which is
   **60 MB per 30 seconds** — off by 5–8×. Do not put that figure in store copy.
   §8's *profile table*, by contrast, is confirmed: see the measurements above.
2. **§8's fps and audio-bitrate columns are not enforceable on Android** (see
   above). The fps column is advisory there.
3. **The offline promise leaks through transitive AARs.** Media3 (via
   `flutter_compress` *and* `video_player`) declares `ACCESS_NETWORK_STATE` and
   `WAKE_LOCK`; the foreground-service trio and `WRITE_EXTERNAL_STORAGE` also
   merged in. A Play listing showing network access beside a "no cloud" promise
   undercuts Principle #1, so `android/app/src/main/AndroidManifest.xml` strips
   them with `tools:node="remove"`. The release merged manifest now ships only
   `CAMERA`, `RECORD_AUDIO` and `READ_EXTERNAL_STORAGE`.
   (`INTERNET` was only ever in Flutter's debug/profile manifests.)

## Measured on real hardware

Pixel 7 Pro, Android 17 (API 37), in-app capture at `ResolutionPreset.veryHigh`
(~1080p). Reproduce with `flutter test integration_test/real_capture_test.dart -d
<device>`; the test prints these figures rather than only asserting on them.

| | Measured | Spec says |
|---|---|---|
| Raw capture bitrate | 16.7 Mbps → **60 MB / 30s** | §2: 300–500 MB — **wrong** |
| Balanced output | 3,773 kbps vs 3,596 requested (**105% of target**) | §8: ~3–4 Mbps ✓ |
| 10-minute Balanced entry | **270 MB** | §8: 250–300 MB ✓ |
| Compression ratio | 29.5 MB → 6.7 MB (**77% saved**) | — |
| Codec | **HEVC every time**, no H.264 fallback | §8 assumes HEVC ✓ |
| Encode speed | **0.16× realtime** (10-min clip ≈ 1.6 min) | §17's open question |
| Ladder monotonic | Small 1.00 MB < High 2.13 MB, same clip | §8's three rungs ✓ |
| Audio (Small) | 50 kbps measured vs 40 requested | §8: 32–48 kbps, close |

**The §8 ladder is validated; §2's baseline is not.** Two caveats worth keeping:
a 3-second clip overshoots its target bitrate by 25–60% because the first
keyframe dominates, so only the 15-second measurement means anything; and
`ResolutionPreset.high` is **~720p, not 1080p** — with it, the Balanced and High
profiles' 1080p caps never engaged and the pipeline was compressing 720p into
720p. Capture is `veryHigh`.

### The bug only a real recording could find

Video saves crashed the app outright, every time. The manifest strips
`FOREGROUND_SERVICE` (for the offline promise) while `EncodingProfile` set
`keepAliveInBackground: true`. `flutter_compress`'s own guide says a stripped
permission "does not crash the encode" — on Android 14+ that is false:

```
SecurityException: Permission Denial: startForeground ... requires
  android.permission.FOREGROUND_SERVICE
    at CompressionForegroundService.onStartCommand
→ Application Error, then ANR
```

Encoding is now foreground-only, and `test/manifest_consistency_test.dart` pins
the flag and the manifest together so the pair cannot drift apart again. The
cost: backgrounding mid-encode can kill it, which fails the save rather than
losing anything — §9's ordering keeps the original until the output is verified.

## Platform notes

- **Android** `minSdk 24`, pinned explicitly rather than inherited — Media3's
  floor. `flutter_compress` applies the Kotlin Gradle Plugin, which future
  Flutter versions will reject; upstream's problem, worth watching.
- **iOS** deployment target **14.0** — `file_picker` 12 requires it for
  `PHPickerViewController`. The three `NS*UsageDescription` keys belong to
  `camera` and `image_picker`; none was added on `flutter_compress`'s behalf,
  which reads files by path and needs no usage description.
- `sqlite3` 3.x fetches a prebuilt library at build time. If that download fails
  behind a TLS-inspecting proxy, `hooks: user_defines:` in `pubspec.yaml` can
  point it at a system or source build.
- The release manifest ships exactly four permissions: `CAMERA`,
  `RECORD_AUDIO`, `READ_EXTERNAL_STORAGE`, and `ACCESS_COARSE_LOCATION` (the
  last only because the opt-in location feature needs it declared; nothing
  requests it until the user turns the setting on).
- **Watch for `--` in AndroidManifest comments.** A double hyphen inside an XML
  comment is illegal and fails `processReleaseMainManifest` with an opaque
  "Error parsing" — which only shows up in a release build.
- `READ_EXTERNAL_STORAGE` comes from `image_picker`, used only by the
  Compression Lab's gallery-pick path. Don't strip it while §2's baseline claim
  is still open — that path is the only way to measure it.

## What is unverified

Being explicit, because a green test suite is not the same as a working feature:

- **Perceptual quality is still a judgement call.** The ladder hits its target
  bitrates, but whether 1.75 Mbps *looks* acceptable for a talking-head note is
  something only eyes on real footage settle. Settings → Maintenance →
  Compression Lab runs all three rungs over one clip and copies out a report.
- **Only one device.** Every figure above is a Pixel 7 Pro. HEVC encode quality
  and speed vary across OEMs (§17), so a budget Android device is the next thing
  worth measuring — the H.264 fallback path has never been taken, because this
  device never needed it.
- **HEVC decode on older devices** (§17). A device that encodes HEVC but cannot
  decode it fails in the player; the message there says so rather than showing a
  black rectangle.
- **Export's share sheet** has not been driven end to end, though the archive
  itself is round-trip tested (14 tests).
- **One test in `real_capture_test.dart` is unverified after its last edit.**
  All eight passed individually and seven passed together; the widget-level
  audio test then needed a teardown-ordering fix (unmount before closing the
  database, or a mounted StreamBuilder deadlocks the runner) and the device
  disconnected before it could be re-run. Re-run the file to confirm.
- **The review and save screen** has not been filled in and saved by hand. The
  pipeline behind it is tested, and the audio test reaches it and reads its size
  estimate back, but nobody has typed a title and tapped Save.
- **Front-camera preview mirroring** follows whatever the platform does; it has
  not been checked against text held up to the lens. (Deliberately not
  screenshotted here — that would photograph the room.)
- **Location capture** is wired (opt-in, off by default, coarse accuracy, 6s
  timeout, saves without coordinates on any failure) but has not been exercised
  on hardware.

## Not built (deliberately)

Per §4, these are v1.x or later: custom entry types, collections/folders,
in-app trim, quick-record widget, and on-device transcription (§15).
Favourites, trash, export/import, and opt-in location *are* in.
