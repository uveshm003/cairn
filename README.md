# Cairn

A private, offline recorder for audio and video entries. Capture with intent
(typed, tagged), find it again without friction (filter + search), keep the
device lean (real compression), and never hand any of it to a cloud.

**No network requests at all.** No account, no sync, no analytics, no paywall.

## Status

The v1 MVP from `requirements.md` §4 is built and running. Verified on a Pixel 7
Pro (Android 17): boots, database and FTS5 work on-device, library renders,
onboarding persists.

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | 72 passing |
| `flutter test integration_test/ -d <device>` | 6 passing, on-device |
| `flutter build apk --release` | builds |
| `flutter build ios --no-codesign` | builds |

**Not yet exercised on hardware: recording itself.** See *What is unverified*.

## Running it

```sh
flutter pub get
dart run build_runner build      # Drift codegen -> lib/data/database.g.dart
flutter run
```

Codegen is required — `lib/data/database.g.dart` is generated and not committed
in a usable state without it.

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

### Corrections to requirements.md

1. **§2's "a 30s clip can be 300–500 MB" is arithmetically impossible.** It
   implies 80–133 Mbps. §8's own figures disagree: 4K @ 50 Mbps is ~190 MB for
   30s, 1080p30 @ 17–20 Mbps is ~65–75 MB. Only ProRes exceeds 500 MB. Do not
   put that number in store copy. §8's *profile table* is sound — the error is
   confined to §2's baseline.
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
- `READ_EXTERNAL_STORAGE` comes from `image_picker`, used only by the
  Compression Lab's gallery-pick path. Don't strip it while §2's baseline claim
  is still open — that path is the only way to measure it.

## What is unverified

Being explicit, because a green test suite is not the same as a working feature:

- **Recording has not run on hardware.** The camera and microphone paths, video
  compression, thumbnail generation, and the `skipped` branch of
  `SavePipeline.saveVideo` have never executed. They are written defensively and
  commented, but they are unexercised.
- **The compression ladder is unvalidated.** Bytes-out is arithmetic and needs
  no device, but whether HEVC hardware encode exists on a given OEM, how long it
  takes, and whether 1.75 Mbps *looks* acceptable all need a real recording.
  Settings → Maintenance → Compression Lab measures exactly this and copies out
  a markdown report.
- **HEVC decode on older devices** (§17). A device that encodes HEVC but cannot
  decode it fails in the player; the message there says so rather than showing a
  black rectangle.
- **Export's share sheet** has not been driven end to end, though the archive
  itself is round-trip tested (14 tests).

## Not built (deliberately)

Per §4, these are v1.x or later: custom entry types, favourites-as-collections,
in-app trim, quick-record widget, and on-device transcription (§15). Favourites,
trash, and export/import *are* in.
