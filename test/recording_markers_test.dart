import 'package:cairn/domain/recording_markers.dart';
import 'package:flutter_test/flutter_test.dart';

/// The trap these exist for: markers are timed against the stopwatch, but they
/// are stored against the *compressed output*, whose duration is measured
/// separately because it can diverge. An unclamped marker seeks past the end of
/// the file and silently does nothing.
void main() {
  test('offsets are sorted', () {
    expect(
      normalizeMarkers([9000, 1000, 5000], durationMs: 20000),
      [1000, 5000, 9000],
    );
  });

  test('an offset past the end is pulled inside the file', () {
    // The exact bug: the stopwatch ran to 20.3s, the encode came out at 20.0s.
    final out = normalizeMarkers([20300], durationMs: 20000);
    expect(out.single, lessThan(20000));
  });

  test('a marker never lands on the final moment', () {
    // Seeking to the last frame is indistinguishable from the entry ending, so
    // it reads as a dead tap.
    final out = normalizeMarkers([19999, 20000], durationMs: 20000);
    expect(out.every((ms) => ms <= 20000 - 250), isTrue);
  });

  test('a negative offset is clamped to zero', () {
    expect(normalizeMarkers([-500], durationMs: 10000), [0]);
  });

  test('a double-tap is one marker, not two', () {
    expect(normalizeMarkers([5000, 5150], durationMs: 20000), [5000]);
  });

  test('deliberate taps a second apart are both kept', () {
    expect(
      normalizeMarkers([5000, 6000], durationMs: 20000),
      [5000, 6000],
    );
  });

  test('a short entry keeps its markers instead of losing them to the guard',
      () {
    // 600ms is above the 400ms mis-tap floor, so it is a real entry -- and the
    // full end-guard would exceed its whole duration.
    final out = normalizeMarkers([300], durationMs: 600);
    expect(out, isNotEmpty);
    expect(out.single, lessThan(600));
  });

  test('a zero-duration file yields no markers', () {
    // Nowhere to seek to; storing an offset would guarantee a broken tick.
    expect(normalizeMarkers([0, 100], durationMs: 0), isEmpty);
  });

  test('no input, no markers', () {
    expect(normalizeMarkers(const [], durationMs: 20000), isEmpty);
  });

  test('every clamped offset is strictly inside the file', () {
    final out = normalizeMarkers(
      [0, 1, 5000, 19999, 25000, -1],
      durationMs: 20000,
    );
    expect(out.every((ms) => ms >= 0 && ms < 20000), isTrue);
  });
}
