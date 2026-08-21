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
| `flutter test` | 113 passing |
| `flutter test integration_test/ -d <device>` | 6 passing, on a Pixel 7 Pro |
| `flutter build apk --release` | builds (65.2 MB) |
| `flutter build ios --release --no-codesign` | builds (23.0 MB) |

**Not yet exercised on hardware: recording itself.** See *What is unverified*.

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

### Kept originals go somewhere durable

`keepOriginals` (§8's opt-in, off by default) moves the uncompressed source into
an `originals/` directory rather than leaving it at the camera plugin's cache
path, which the OS reclaims. Nothing in the database references those files, so
`originals/` is deliberately excluded from the orphan sweep — a sweep that saw
them would delete exactly the files the setting exists to preserve.

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
- **The capture screen's design** has been built but not seen with a live camera
  preview behind it — the scrims, the type pill, and the record button are
  verified only against the audio stage and widget tests.
- **Location capture** is wired (opt-in, off by default, coarse accuracy, 6s
  timeout, saves without coordinates on any failure) but has not been exercised
  on hardware.

## Not built (deliberately)

Per §4, these are v1.x or later: custom entry types, collections/folders,
in-app trim, quick-record widget, and on-device transcription (§15).
Favourites, trash, export/import, and opt-in location *are* in.
