## What this changes

<!-- The behaviour change, in a sentence or two. Link the issue if there is one. -->

## Why

<!-- What was wrong, or what job this serves (README §3 / requirements.md §3). -->

## What I ran

- [ ] `flutter analyze` — clean
- [ ] `flutter test` — green
- [ ] `dart run build_runner build`, and `lib/data/database.g.dart` is committed *(only if the schema changed)*

**On hardware:** <!-- device and OS, and which integration tests you ran. "Untested on device"
is a fine answer and more useful than a claim that didn't happen. Required if this touches
capture, compression, or playback. -->

## Checklist

- [ ] **No new network access.** Nothing here — including any added dependency — makes a request at runtime.
- [ ] No hard-coded colour, gap, or radius; all three come from `lib/ui/theme/tokens.dart`.
- [ ] Any persisted media path is relative, not absolute.
- [ ] New text tokens are covered by `test/theme_test.dart`; new list/card components by `test/dynamic_type_test.dart`.
- [ ] If this closes a gap in the README's *What is unverified*, that item is moved or removed in this PR.

## Anything reviewers should look at closely

<!-- Known risk, a judgement call you'd like a second opinion on, or something you couldn't test. -->
