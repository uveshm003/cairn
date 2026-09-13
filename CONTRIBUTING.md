# Contributing to Cairn

Thanks for looking. Cairn is a private, offline recorder — that constraint is
the product, not a feature, so it shapes what changes can be accepted. Read
*The one rule* before opening a PR.

## The one rule

**Cairn makes no network requests, ever.** No account, no sync, no analytics,
no crash reporting, no remote config, no ads, no font CDN, no "just this one
telemetry ping". A change that adds a network dependency — directly, or through
a package that phones home — will be closed regardless of how good the feature
is.

This is why the fonts are bundled assets rather than fetched, and why
`flutter_compress` (native MediaCodec / VideoToolbox) was chosen over anything
that downloads a codec. If you add a dependency, say in the PR what it does at
runtime and why it cannot reach the network.

## Getting set up

```sh
flutter pub get
dart run build_runner build      # Drift codegen -> lib/data/database.g.dart
flutter run
```

Built against **Flutter 3.44.9 / Dart 3.12.2**; the pubspec floor is Dart
`^3.12.2`. Android `minSdk` is **24**, pinned explicitly in
`android/app/build.gradle.kts` because `flutter_compress` needs Media3
Transformer — please don't let it drift below that.

`lib/data/database.g.dart` is generated *and committed*, so a clean checkout
runs without codegen. Re-run `build_runner` after any change to the schema in
`lib/data/database.dart`, and commit the regenerated file with your change.

To review UI work against realistic content instead of an empty library:

```sh
flutter run --dart-define=CAIRN_SEED_DEMO=true
```

The seeder is debug-only and flag-gated.

## Before you open a PR

```sh
flutter analyze        # must be clean, no new warnings
flutter test           # must be green
```

Both are also run by CI on every push and PR. Device integration tests are
**not** run by CI — they need real hardware:

```sh
flutter test integration_test/capture_flow_test.dart
flutter test integration_test/real_capture_test.dart   # makes real recordings
```

If your change touches capture, compression, or playback, run
`real_capture_test.dart` on a device and say so in the PR, including which
device. The README's *What is unverified* section is an honest list of what has
never been exercised on hardware — if you close one of those gaps, move the item
out of that section in the same PR. That list is the project's memory; keeping
it truthful matters more than keeping it short.

## House style

- `flutter_lints` via `analysis_options.yaml` is the baseline. Match the
  surrounding code rather than introducing a new idiom.
- **Screens never invent a colour, a gap, or a radius.** `lib/ui/theme/tokens.dart`
  owns all three, and `context.palette` reaches the tokens Material's
  `ColorScheme` has no slot for. A hard-coded `Color(0x...)` or a bare `16.0`
  padding in a screen is a review comment.
- Contrast is computed, not eyeballed — `test/theme_test.dart` checks real WCAG
  ratios for every text token. New tokens go in that test.
- Dynamic type is tested, not hoped for — `test/dynamic_type_test.dart` pumps
  components at 1×–2× scale on narrow screens. New list/card components go there.
- Media paths are stored **relative**, always (see the README on why). Anything
  that persists an absolute path is a bug.
- Prefer a pure function with a unit test over logic buried in a `State`. Most
  of the tricky rules in this repo (marker clamping, the encoding ladder, seek
  resolution, the quick-capture gate) live in `lib/domain/` for exactly that
  reason.

## Commits and PRs

- Present tense, imperative subject, describing the behaviour change: *"Guard
  the camera flip mid-take"*, not *"fixes"*.
- One logical change per PR. A refactor and a feature in the same diff is two
  PRs.
- In the PR body, say what you ran — analyzer, unit tests, and whether anything
  touched hardware. "Untested on device" is a fine and useful thing to write;
  claiming a device pass that did not happen is not.

## Scope

`requirements.md` is the original spec, and the README's *Corrections to
requirements.md* section records where the build knowingly departs from it.
Deliberately **not** built for v1: custom entry types, collections/folders,
in-app trim, and on-device transcription (§15). If you want to take one on —
especially transcription, where the open question is APK packaging rather than
architecture — please open an issue to discuss the approach before writing it.

## Trademark

The MIT license covers the code, including the painted mark and icon source.
It is not permission to ship a fork under the name **Cairn** or its mark in a
way that suggests it is this project. Rename your fork if you distribute it.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). By
participating, you agree to uphold it.
