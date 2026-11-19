// Tests for the slow-Traccar regression fix: TraccarService's per-endpoint
// timeouts (25s for /api/devices and /api/positions, 30s for
// /api/reports/summary — up from a uniform 5s that was aborting healthy
// but slow responses from this particular Traccar deployment), and
// SingleFlightGuard (the no-stacking guard behind LiveTrackingScreen's 15s
// poll). See test/vehicle_km_cache_test.dart for the end-to-end
// TruckProfileScreen-level proof that an 8s-slow (but healthy) response is
// no longer killed by the old 5s timeout — this file covers the same fix
// one layer down, directly against TraccarService, plus the poll-skip
// guard that file can't reach (LiveTrackingScreen has no firestoreOverride
// seam to pump a full widget test against).
//
// kDebugMode logging ("[TRACCAR] <label> <ms>ms <outcome>") is exercised
// by every test below (kDebugMode is true under `flutter test`) and is
// visible directly in this file's own console output when run verbosely —
// e.g. "[TRACCAR] GET /api/devices 1ms ok" / "... TIMEOUT (limit 25s)".
// It is not asserted on directly: Flutter's test framework treats
// reassigning the global `debugPrint` callback inside a test as a
// "foundation debug variable changed" invariant violation (even when
// restored via addTearDown), so capturing its output isn't a safe pattern
// here — the format is confirmed by eye in the test run instead.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

// Runs `action`, returning its error (if any) instead of letting it
// propagate — avoids `Future.then(onError:)`'s strict same-type-return
// requirement, which doesn't fit "just capture whatever error happened".
Future<Object?> _captureError(Future<void> Function() action) async {
  try {
    await action();
    return null;
  } catch (e) {
    return e;
  }
}

void main() {
  tearDown(() {
    TraccarService.fetchDevicesOverride = null;
    TraccarService.fetchPositionsOverride = null;
    TraccarService.fetchDistanceSummaryOverride = null;
  });

  group('SingleFlightGuard (LiveTrackingScreen poll no-stacking)', () {
    test('a tick is skipped while the previous one is still in flight', () async {
      final guard = SingleFlightGuard();
      final started = <int>[];
      final finished = <int>[];
      final gate = Completer<void>();

      // First run — deliberately held open by `gate` to simulate a slow
      // Traccar cycle still in flight when the next 15s tick would fire.
      final first = guard.run(() async {
        started.add(1);
        await gate.future;
        finished.add(1);
      });

      expect(guard.inFlight, isTrue);

      // A second "tick" while the first hasn't finished — must be skipped
      // entirely (action never even starts), not queued.
      await guard.run(() async {
        started.add(2);
        finished.add(2);
      });

      expect(started, [1]); // action 2 never ran
      expect(guard.inFlight, isTrue); // first run still pending

      gate.complete();
      await first;
      expect(finished, [1]);
      expect(guard.inFlight, isFalse);
    });

    test('a new run is allowed once the previous one has finished', () async {
      final guard = SingleFlightGuard();
      final started = <int>[];

      await guard.run(() async => started.add(1));
      expect(guard.inFlight, isFalse);

      await guard.run(() async => started.add(2));

      expect(started, [1, 2]); // both ran — no stale "still in flight" state
    });

    test('an exception in the action still clears inFlight (no permanent stuck guard)', () async {
      final guard = SingleFlightGuard();

      await expectLater(
        guard.run(() async => throw Exception('boom')),
        throwsException,
      );
      expect(guard.inFlight, isFalse);

      // Confirms the guard is usable again, not wedged by the failure above.
      var ran = false;
      await guard.run(() async => ran = true);
      expect(ran, isTrue);
    });
  });

  group('TraccarService timeouts (25s devices/positions, 30s summary)', () {
    testWidgets(
      'fetchDevices succeeds for an 8s-slow (but healthy) response — '
      'would have been aborted under the old 5s timeout',
      (tester) async {
        TraccarService.fetchDevicesOverride = () => Future.delayed(
              const Duration(seconds: 8),
              () => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ],
            );

        List<Map<String, dynamic>>? result;
        Object? error;
        unawaited(_captureError(() async {
          result = await TraccarService.fetchDevices(username: 'u', password: 'p');
        }).then((e) => error = e));

        await tester.pump(const Duration(seconds: 9));
        expect(error, isNull);
        expect(result, isNotNull);
        expect(result!.single['uniqueId'], 'DEV1');
      },
    );

    testWidgets(
      'fetchPositions times out at 25s (not 5s) for a genuinely hung call',
      (tester) async {
        TraccarService.fetchPositionsOverride =
            () => Completer<List<Map<String, dynamic>>>().future;

        Object? error;
        unawaited(_captureError(() async {
          await TraccarService.fetchPositions(username: 'u', password: 'p');
        }).then((e) => error = e));

        await tester.pump(const Duration(seconds: 20));
        expect(error, isNull); // not yet — well under the 25s limit

        await tester.pump(const Duration(seconds: 6)); // crosses 25s total
        expect(error, isA<TimeoutException>());
      },
    );

    testWidgets(
      'fetchDistanceSummary times out at 30s, not 25s — the heaviest '
      'endpoint gets the longest budget',
      (tester) async {
        TraccarService.fetchDistanceSummaryOverride = ({
          required int deviceId,
          required DateTime from,
          required DateTime to,
        }) =>
            Completer<double>().future;

        Object? error;
        unawaited(_captureError(() async {
          await TraccarService.fetchDistanceSummary(
            username: 'u',
            password: 'p',
            deviceId: 1,
            from: DateTime(2026),
            to: DateTime(2026, 1, 2),
          );
        }).then((e) => error = e));

        await tester.pump(const Duration(seconds: 26));
        expect(error, isNull); // past the devices/positions 25s, but not 30s

        await tester.pump(const Duration(seconds: 5));
        expect(error, isA<TimeoutException>());
      },
    );
  });
}
