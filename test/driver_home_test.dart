// Drivers only do the Daily Check:
//  - DriverHomeScreen shows only the assigned truck's Daily Check (no
//    Trucks/Machines choice, no other trucks, no work entry).
//  - Submit -> "Daily check submitted for <truck> - <date>" -> DONE -> home
//    shows the done state; never the truck work (trips/bill/cube) screen.
//  - Already submitted today -> done state with time + read-only VIEW.
//  - No assigned truck -> "No truck assigned, contact admin."
//  - The shared screens other roles use (DriverTypeScreen for field_workers
//    who also operate machines) are unchanged.
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46]);
String _today() => dailyCheckDateKey(DateTime.now());

Future<FakeFirebaseFirestore> _fixture({bool assigned = true}) async {
  final db = FakeFirebaseFirestore();
  await db.collection('users').doc('uidDriver').set({'name': 'Driver Dan', 'role': 'driver'});
  await db.collection('trucks').doc('mine').set({
    'truckNumber': 'LM-6435',
    if (assigned) 'assignedDriverUid': 'uidDriver',
    'assignedDriverName': 'Driver Dan',
  });
  await db.collection('trucks').doc('other').set({
    'truckNumber': 'WP-2222',
    'assignedDriverUid': 'uidOther',
  });
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(ReferenceCollectionCache.reset);

  Future<void> settle(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget host(FakeFirebaseFirestore db, {DailyCheckPhotoUploader? uploader}) => MaterialApp(
        theme: AppTheme.light(),
        home: DriverHomeScreen(
          name: 'Driver Dan',
          firestoreOverride: db,
          currentUidOverride: 'uidDriver',
          photoUploaderOverride: uploader,
          debugInitialPhotos: {
            for (final d in kDefaultDailyChecks) d.id: _jpeg,
          },
        ),
      );

  for (final size in [const Size(390, 1400), const Size(1200, 1400)]) {
    final label = '${size.width.toInt()}w';

    testWidgets('driver home shows only the assigned truck daily check ($label)',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _fixture();
      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('Your assigned truck'), findsOneWidget);
      expect(find.text('LM-6435'), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-check-start')), findsOneWidget);
      // No other trucks, no Trucks/Machines choice, no work entry.
      expect(find.text('WP-2222'), findsNothing);
      expect(find.text('1. Trucks'), findsNothing);
      expect(find.text('2. Machines'), findsNothing);
      expect(find.textContaining('Trip'), findsNothing);
      expect(find.textContaining('Bill'), findsNothing);
    });

    testWidgets(
        'submit -> success screen -> DONE -> home done state; no work screen, '
        'session closed, no trips ($label)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _fixture();
      Future<String> uploader(String path, Uint8List b, SettableMetadata m) async =>
          'https://example.test/$path';
      await tester.pumpWidget(host(db, uploader: uploader));
      await settle(tester);

      await tester.tap(find.byKey(const ValueKey('driver-check-start')));
      await settle(tester);
      expect(find.textContaining('Daily Check — LM-6435'), findsOneWidget);

      await tester.ensureVisible(find.text('SUBMIT'));
      await tester.tap(find.text('SUBMIT'));
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.byType(TruckWorkAreaScreen), findsNothing);
      expect(find.text('Daily check submitted for LM-6435 - ${_today()}'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('daily-check-done-button')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(DriverHomeScreen), findsOneWidget);
      expect(find.byType(TruckWorkAreaScreen), findsNothing);
      expect(find.byKey(const ValueKey('driver-check-done')), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-check-start')), findsNothing);

      final checks = await db.collection('daily_checks').get();
      expect(checks.docs.single.id, 'LM-6435_${_today()}');

      final sessions = await db.collection('truck_sessions').get();
      expect(sessions.docs, hasLength(1));
      final s = sessions.docs.single.data();
      expect(s['driverUid'], 'uidDriver');
      expect(s['truckNumber'], 'LM-6435');
      expect(s['mode'], 'daily_check_only');
      expect(s['status'], 'completed');
      expect(s['dailyCheckSubmitted'], isTrue);
      final trips = await sessions.docs.single.reference.collection('trips').get();
      expect(trips.docs, isEmpty);
      expect((await db.collection('work_records').get()).docs, isEmpty);
    });

    testWidgets('already done today -> done state with time and read-only VIEW ($label)',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _fixture();
      final now = DateTime.now();
      final at = DateTime(now.year, now.month, now.day, 7, 5);
      await db.collection('daily_checks').doc('LM-6435_${_today()}').set({
        'vehicleNumber': 'LM-6435',
        'date': _today(),
        'submittedByName': 'Driver Dan',
        'submittedAt': Timestamp.fromDate(at),
        'checks': [
          {'id': 'water_level', 'label': 'Water Level', 'status': 'LOW', 'note': 'TOPPED UP'},
        ],
      });

      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(find.text("Today's daily check is done (07:05)"), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-check-start')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('driver-check-view')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(DailyCheckReadOnlyScreen), findsOneWidget);
      expect(find.text('WATER LEVEL'), findsOneWidget);
      expect(find.text('LOW'), findsOneWidget);
      expect(find.text('Note: TOPPED UP'), findsOneWidget);
      // Read-only: no inputs, no submit.
      expect(find.byType(TextField), findsNothing);
      expect(find.text('SUBMIT'), findsNothing);
    });

    testWidgets('no assigned truck -> message, no check ($label)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _fixture(assigned: false);
      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text(kNoTruckAssignedMessage), findsOneWidget);
      expect(find.byKey(const ValueKey('driver-check-start')), findsNothing);
      expect(find.text('LM-6435'), findsNothing);
    });
  }

  testWidgets('field_worker who also operates machines keeps DriverTypeScreen '
      '(Trucks + Machines) unchanged', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: DriverTypeScreen(
        name: 'Field Fred',
        firestoreOverride: db,
        currentUidOverride: 'uidFw',
      ),
    ));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('1. Trucks'), findsOneWidget);
    expect(find.text('2. Machines'), findsOneWidget);
  });
}
