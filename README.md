# Cairn

A private, offline recorder for audio and video entries. Capture with intent
(typed, tagged), find it again without friction (filter + search), keep the
device lean (real compression), and never hand any of it to a cloud.

**No network requests at all.** No account, no sync, no analytics, no paywall.

## Status

The v1 MVP from `requirements.md` §4 is built and running, and the capture
pipeline is validated against real recordings on a Pixel 7 Pro (Android 17).

Three v1.x features are in beyond that MVP, aimed at the Practice job in §3
(*"record my guitar practice every day and scan back through the last month"*):
**in-recording markers**, **waveform scrubbing with speed and an A-B loop**, and
a **home-screen widget plus quick-settings tile**. See *Beyond the MVP* below —
including what about them is still unverified on hardware.

| | |
|---|---|
| `flutter analyze` | clean |
| `flutter test` | 260 passing |
| `integration_test/capture_flow_test.dart` | 6 passing, on device |
| `integration_test/real_capture_test.dart` | 8 tests — **real recordings** (see note) |
| `flutter build apk --release` | builds (66.3 MB) |
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
               recording_markers.dart the marker clamping rule
               amplitude_envelope.dart bounded waveform capture
  media/       media_store.dart      relative-path discipline (S9)
               save_pipeline.dart    compress -> verify -> store
  backup/      backup_service.dart   zip + versioned manifest (S11)
  settings/    app_settings.dart     key-value settings
  services/    quick_capture.dart    the widget / tile bridge
  ui/          library capture detail settings trash onboarding lab
```

The Android side of quick capture is plain platform code, no plugin:

```
android/app/src/main/kotlin/com/example/cairn/
  QuickCapture.kt            the intent contract, shared by all three
  QuickRecordWidget.kt       home-screen widget (AppWidgetProvider)
  QuickRecordTileService.kt  quick-settings tile (TileService)
  MainActivity.kt            hands the pending request to Dart
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

## Beyond the MVP

Three v1.x features, all pointed at the same user: someone who records a
20-minute practice session daily and needs the archive to stay navigable.

### Markers are dropped during the take, not after

One tap on the mark button — beside the record button, so the same thumb
reaches both mid-take — writes a timestamp; the detail screen draws them as
ticks over the timeline and as chips that seek. No typing — naming a marker would
mean a keyboard over the viewfinder mid-take, which is the opposite of the point.

The subtle part is *what the offset is measured against*. Markers are timed off
the stopwatch, but they are stored against the **compressed output**, whose
duration can differ from the source — that divergence is exactly what
`SavePipeline`'s integrity check exists to catch. An unclamped marker seeks past
the end of the file and silently does nothing, so `domain/recording_markers.dart`
sorts, clamps, and merges double-taps before the row is written, against
`media.durationMs` rather than the stopwatch.

### The waveform is captured, not decoded

Nothing in the dependency tree can decode audio back into amplitudes, and the
thing that could is FFmpeg, which §8 rules out. But the recorder already streams
levels for the on-screen meter, so `domain/amplitude_envelope.dart` collects them
*while recording* — the same samples that drive the meter become the waveform,
so what the user watched is what they scrub.

Two properties are tested rather than assumed:

- **Bounded size.** Principle #5 is "small on disk", and an app that added 20 KB
  per entry to win a waveform would be arguing with itself. The recorder halves
  its buffer whenever it fills, so a 20-second note and a 30-minute session both
  cost at most 2 KB. Peaks survive the halving — an envelope that averaged away
  its transients would be a flat smear.
- **Cadence-independence.** The sample interval is never stored; readers derive
  it as `durationMs / length`. Changing the capture cadence cannot misalign an
  envelope written under the old one.

**It is blank for everything recorded before this existed, and for all video.**
That is a normal state, not a defect: the player falls back to the plain slider.
A flat waveform would read as "silent recording", which is why null and empty are
kept distinct all the way through the schema and the backup format.

### Speed, A-B loop, skip silence

A 20-minute Practice entry is not something anyone replays start to finish. Six
speeds from 0.5× to 2× — slower matters as much as faster, since 0.5× is for
learning a passage note by note. The A-B loop is one control in two states,
because "set B" is meaningless before A exists.

For audio the loop uses `just_audio`'s `setClip`, which is gapless; video has no
clip concept, so there the loop is a position watcher that seeks back.

The wrinkle worth knowing is that `setClip` makes the player's whole timeline
the clip's: **position, duration, and `seek` all become clip-relative**, because
on Android all three come off the same `ClippingMediaSource` window. So the
playhead is offset back to absolute time before anything draws, `seek` is
rebased on the way in (`resolveSeek`), and the entry's own duration is tracked
separately from `_player.duration` — otherwise the waveform rescales itself to
the loop and every marker tick stacks on the right edge.

`setClip` is also not a no-op when it is handed nothing: it reloads the source
and restarts at 0:00. Placing A therefore touches the player at all only when a
clip is already installed, and clearing one says where to put the playhead back.

**Skip silence is Android-only.** It is an ExoPlayer feature, and `just_audio`'s
own doc comment says so. The control is hidden on iOS rather than disabled: a
dead switch is worse than no switch.

### Quick capture: one tap, and no new dependency

Principle #4 asks for "cold-start to recording in ≤2 taps". The in-app path
already meets that (FAB, then record); the home-screen widget and the
quick-settings tile beat it at one tap, and the tile is reachable from the lock
screen and from inside other apps — which is the situation §3's "leave myself a
30-second spoken note" actually describes.

Implemented as a plain `AppWidgetProvider` and `TileService` rather than with a
widget plugin. The widget shows no library data, so there is nothing to render
and nothing to keep in sync — it is two buttons, and a plugin would have meant
auditing another AAR's manifest against the four-permission promise for no gain.
`updatePeriodMillis` is 0 for the same reason.

The request is **pulled** by Dart, not pushed from Kotlin. A cold start from the
widget races the Flutter engine, so a push would fire before Dart had a listener
and the tap would be lost — which is precisely the case the feature exists for.

Two things it deliberately does *not* do: it never jumps over onboarding (§10
puts the offline promise before anything else), and the tile opens on the
**remembered** medium rather than choosing one, since a tile has room for one
action and overriding the user's last choice would be a surprise. That is what
the new `preferredMedium` setting is for.

**iOS has no widget.** A WidgetKit extension means a new Xcode target and an App
Group, against a build that currently passes `--no-codesign` cleanly; that is a
separate piece of work and has not been done. On iOS, capture is still two taps.

### The manifest promise survives — verified, not assumed

A widget adds a `<receiver>` and the tile adds a `<service>`, and the tile's
`BIND_QUICK_SETTINGS_TILE` is signature-level and declared *on the service*
(constraining who may bind to it) rather than requested by the app. Checked
against the merged release manifest rather than reasoned about:

```
$ grep -o 'uses-permission android:name="[^"]*"' \
    build/app/intermediates/merged_manifests/release/.../AndroidManifest.xml
android.permission.ACCESS_COARSE_LOCATION
android.permission.CAMERA
android.permission.READ_EXTERNAL_STORAGE
android.permission.RECORD_AUDIO
com.example.cairn.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
```

Still the same four system permissions. The last entry is app-private and
signature-level — androidx declares it about the app itself, it predates this
work, and it is not something a user grants or a store listing shows.
`test/manifest_consistency_test.dart` now pins the permission set *as a set*,
because the failure worth catching is a new name appearing, which no
per-permission assertion would notice.

### Four more the suite did not see, one pass later

Same shape as the two below, and the same lesson: the pure functions were right
and their callers were not.

**The clip rebase was done for position and `seek`, but not for duration.**
`_player.duration` reports the *clip's* length while a loop is active. The UI was
drawing an absolute playhead against it, so inside a 4:12–4:28 loop on a
20-minute entry the playhead pinned to the right edge, every marker tick stacked
there with it, and a tap on the waveform resolved to a target below the loop's
start — which `resolveSeek` correctly read as "leave the loop". The flagship
feature destroyed its own loop on the first scrub. The entry's duration is now
tracked off `durationStream` and ignored while a clip is installed.

**Placing A restarted the entry.** `setClip()` with no arguments reloads the
source from zero, and the half-set-loop branch called it unconditionally.

**Video never used `resolveSeek`.** Tapping a marker past the loop let the
position watcher yank the playhead straight back in — the clamping the pure
function exists to refuse, still live on the other player.

**A quick-capture request the gate could not act on was left pending natively.**
Not harmless: it fired on the next unrelated resume and opened the viewfinder
with nobody having tapped anything. Finding that turned up a second one — the
gate was told `enabled: !showOnboarding`, a bool fixed when the process started,
while onboarding exits by `pushReplacement`. Quick capture was dead for the
whole session it was set up in. The gate reads `settings.onboarded` itself now,
and `test/quick_capture_gate_test.dart` covers both with a fake native side.

### Two bugs a passing suite did not see

Worth recording, because both are the same shape — a green test suite agreeing
with code that was wrong.

**The clip offset had to be corrected in both directions.** `setClip` makes
`just_audio`'s timeline relative to the clip: positions come back relative to the
clip start *and* `seek` expects a clip-relative offset. Correcting only the read
side is the easy half to notice, and it left every waveform tap and marker jump
inside a loop overshooting by the loop's start. The rule now lives in
`resolveSeek`, as a pure function with the seven cases pinned — including that a
target outside the loop means "leave the loop", since tapping a marker at 0:12
while looping 4:12–4:28 is plainly not a request to be clamped.

**Replacing a `Slider` quietly cost accessibility.** The waveform took over from
a real `Slider` for every entry that has an envelope, and it declared
`slider: true` with no increase/decrease actions — announcing to TalkBack a
control it could not move, which is strictly worse than the widget it replaced.
No overflow or exception check can see that. The adjust actions are now driven
through the semantics tree in the test (`tester.semantics.increase` throws if the
action is absent), and the step is proportional: a twentieth of the entry,
bounded to 1–30s, because fixed 10s steps would need 120 nudges to cross a
20-minute session.

### Schema v2, and the app's first migration

Markers needed a table and the envelope needed a column, so both went into one
migration rather than paying for two. `onUpgrade` is additive and step-wise.

The test that matters is `test/migration_test.dart`, which upgrades a **v1
database with rows already in it** — the v1 schema is frozen verbatim in that
file, dumped from `sqlite_master` at v1, and seeded before drift is allowed to
open the file. A fresh-create test would have passed while the first machine to
run the real path was a phone with a real library on it.

One trap found while writing it, worth repeating: drift issues `SELECT *` and
maps results by column name, so a **missing** column reads back as null exactly
like a present-but-empty one. `expect(entry.amplitudeEnvelope, isNull)` passed
whether or not the migration had run. The assertions are against
`PRAGMA table_info` and an actual `UPDATE` instead, both of which fail loudly
when the column is absent.

Backup went to `manifestVersion` 2 in step. A v1 archive still restores — it
simply has no markers and no envelopes — and a corrupt base64 envelope degrades
to no waveform rather than failing the import, because the waveform is a
convenience and must never cost the user a recording.

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

The v1.x features above add their own gaps, and these are the honest ones:

- **The mark button has never been tapped on a device.** Its rule is tested as
  pure functions and the review screen's half is a widget test, but the button
  only exists while recording, and a host test has no camera or microphone to
  reach that state. Untested on hardware: the haptic, the 200-marker cap, and
  whether the button is actually reachable one-handed mid-take — which is the
  entire design claim.
- **No waveform has been drawn from a real recording.** The envelope's maths is
  tested against synthetic input, and the painter is pumped in a widget test,
  but nobody has recorded audio on a device and looked at the result. Whether a
  peak envelope at 90ms sampling *looks* like the playing is a judgement, the
  same kind the compression ladder needed eyes on.
- **The widget and tile have never been tapped.** Both compile into the release
  APK and the manifest registration is pinned by a test, but a real tap needs a
  launcher. Specifically unverified: the cold-start race the pull-not-push design
  exists to solve, the Android 14+ `startActivityAndCollapse(PendingIntent)`
  branch, and whether the widget's colours read correctly against a light
  wallpaper (they are pinned to the dark palette by hand, since a RemoteViews
  layout cannot read Dart tokens).
- **Skip silence is unexercised.** Android-only by nature, and no Android test
  run has toggled it.
- **The v2 migration has not run on a real device.** It is tested against a
  frozen v1 schema with rows, which is the closest a host test gets, but the
  Pixel's own database is the first real v1 library it will meet.
- **Three of the four fixes in *Four more the suite did not see* are verified by
  reading source, not by running anything.** The clip-duration rebase, the
  `setClip` restart, and the video `resolveSeek` bypass all live inside
  `_AudioPreviewState` / `_VideoPreviewState`, which no host test can reach —
  `just_audio` never settles without a platform player. Each rule was traced
  through `just_audio`'s `setClip`/`_load` and Android's `AudioPlayer.java`
  (`getDuration()` over a `ClippingMediaSource`), and the pure parts are pinned
  (`loopNeedsPlayerCall`, `closeLoop`, `resolveSeek`), but **the loop path wants
  a device pass**: set A mid-entry, close it, scrub inside it, and tap a marker
  outside it, on both audio and video. The fourth — the quick-capture gate — is
  covered by `test/quick_capture_gate_test.dart` against a fake native side, and
  both of its cases were confirmed to fail before the fix.

## Not built (deliberately)

Per §4, these are v1.x or later: custom entry types, collections/folders,
in-app trim, and on-device transcription (§15). Favourites, trash,
export/import, opt-in location, in-recording markers, waveform scrubbing with
speed and an A-B loop, and the quick-record widget *are* in.

Two notes on what is left:

- **Custom entry types are first in §4's v1.x list and are deliberately last
  here.** The five fixed types cover every job in §3, and a type manager is a
  power-user setting — the most spec-blessed, least useful item on the list.
- **On-device transcription (§15) is the one that changes the product**, and the
  data layer is already shaped for it: Drift + FTS5 was chosen for this, and
  `entry_search.transcript` is still sitting empty and unused. The open question
  is packaging, not architecture — the APK is already 66.3 MB, and a bundled
  whisper-tiny roughly doubles that, which is a real install-conversion cost for
  a feature that also happens to be the headline one.
