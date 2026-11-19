// Tests for timeoutFirstEventOnly (lib/main.dart) — the fix for the
// RepairCategoriesScreen "Taking too long" bug confirmed live: the
// console showed repair_categories DONE with 14 docs, then a timeout
// fired anyway. Root cause: Stream.timeout() resets its timer on every
// event and fires again whenever there's a gap of `duration` between any
// two consecutive events, not just before the first one. A real-time
// Firestore listener that delivers one snapshot and then goes quiet
// (nothing changed) for the timeout window was therefore incorrectly
// timed out, discarding already-loaded data.
//
// Includes both a pure unit test of the stream-transform itself (a short
// timeout override, no widget involved) and a widget test of the actual
// fixed screen (RepairCategoriesScreen, via its test-only
// categoriesTimeout seam) at both 390px and 1200px.
import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  group('timeoutFirstEventOnly (pure stream transform)', () {
    test(
      'emits once, then stays silent past the timeout window — must NOT '
      'produce a timeout error',
      () async {
        final source = StreamController<int>();
        final result = timeoutFirstEventOnly<int>(
          source.stream,
          const Duration(milliseconds: 50),
          onTimeout: () => TimeoutException('should never fire'),
        );

        final events = <int>[];
        final errors = <Object>[];
        final sub = result.listen(events.add, onError: errors.add);

        source.add(1);
        // Wait well past the 50ms timeout window — a plain Stream.timeout()
        // would fire again here because the source has gone quiet since
        // delivering its one event; timeoutFirstEventOnly must not.
        await Future.delayed(const Duration(milliseconds: 200));

        expect(events, [1]);
        expect(errors, isEmpty);

        await sub.cancel();
        await source.close();
      },
    );

    test('no event at all within the timeout -> exactly one timeout error', () async {
      final source = StreamController<int>();
      final result = timeoutFirstEventOnly<int>(
        source.stream,
        const Duration(milliseconds: 50),
        onTimeout: () => TimeoutException('expected timeout'),
      );

      final errors = <Object>[];
      final sub = result.listen((_) {}, onError: errors.add);

      await Future.delayed(const Duration(milliseconds: 150));

      expect(errors.length, 1);
      expect(errors.single, isA<TimeoutException>());

      await sub.cancel();
      await source.close();
    });

    test('a real error before the timeout passes through untouched', () async {
      final source = StreamController<int>();
      final result = timeoutFirstEventOnly<int>(
        source.stream,
        const Duration(milliseconds: 100),
        onTimeout: () => TimeoutException('should never fire'),
      );

      final errors = <Object>[];
      final sub = result.listen((_) {}, onError: errors.add);

      source.addError(Exception('permission-denied'));
      await Future.delayed(const Duration(milliseconds: 200));

      expect(errors.length, 1);
      expect(errors.single, isA<Exception>());
      expect(errors.single.toString(), contains('permission-denied'));

      await sub.cancel();
      await source.close();
    });

    test(
      'a late real error after the timeout already fired is still delivered '
      '(the timeout does not cancel the source subscription)',
      () async {
        final source = StreamController<int>();
        final result = timeoutFirstEventOnly<int>(
          source.stream,
          const Duration(milliseconds: 50),
          onTimeout: () => TimeoutException('first — expected'),
        );

        final errors = <Object>[];
        final sub = result.listen((_) {}, onError: errors.add);

        await Future.delayed(const Duration(milliseconds: 100));
        expect(errors.length, 1);
        expect(errors.single, isA<TimeoutException>());

        source.addError(Exception('late permission-denied'));
        await Future.delayed(const Duration(milliseconds: 50));

        expect(errors.length, 2);
        expect(errors.last, isA<Exception>());

        await sub.cancel();
        await source.close();
      },
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> setSurface(WidgetTester tester, Size size) async {
    final originalSize = tester.view.physicalSize;
    final originalRatio = tester.view.devicePixelRatio;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalRatio;
    });
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'RepairCategoriesScreen: a loaded category list survives well past a '
      'short timeout window with no data change — no error, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        await firestore.collection('repair_categories').doc('ENG').set({
          'code': 'ENG',
          'name': 'Engine',
          'sortOrder': 0,
          'active': true,
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairCategoriesScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
            // Short override — proves the fix without a real 15s wait.
            categoriesTimeout: const Duration(milliseconds: 100),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('ENG — Engine'), findsOneWidget);

        // Nothing in repair_categories changes from here — a plain
        // Stream.timeout() would fire again now and replace this data
        // with an error. Wait well past the 100ms override.
        await tester.pump(const Duration(milliseconds: 400));
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(find.textContaining('ENG — Engine'), findsOneWidget);
        expect(find.textContaining('Failed to load categories'), findsNothing);
      },
    );
  }
}
