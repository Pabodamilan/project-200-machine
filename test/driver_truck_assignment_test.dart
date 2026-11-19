// Driver → truck assignment (trucks/{id}.assignedDriverUid):
//  - TruckTypeScreen shows ONLY the signed-in driver's assigned truck(s);
//    the free "pick any truck" list is gone.
//  - No assignment → "No truck assigned, contact admin." and no session.
//  - driverTruckStartBlockReason rejects any truck not assigned to the
//    driver ("This truck is not assigned to you.") — the single gate every
//    session start goes through.
//  - An open session on a truck that is no longer assigned is kept and
//    offered as CONTINUE next to the new assignment, never ended silently.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

String _todayKey() => dailyCheckDateKey(DateTime.now());

Future<FakeFirebaseFirestore> _fixture() async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidDriver').set({
    'name': 'Driver Dan',
    'role': 'driver',
  });
  await firestore.collection('settings').doc('repair_workflow').set({
    'simpleMode': true,
  });
  return firestore;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(() {
    ReferenceCollectionCache.reset();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> setSurface(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget host(FakeFirebaseFirestore db) => MaterialApp(
        theme: AppTheme.light(),
        home: TruckTypeScreen(
          name: 'Driver Dan',
          firestoreOverride: db,
          currentUidOverride: 'uidDriver',
        ),
      );

  group('driverTruckStartBlockReason / trucksAssignedTo', () {
    test('assigned truck is allowed', () {
      expect(
        driverTruckStartBlockReason(
          uid: 'uidDriver',
          truckData: {'truckNumber': 'WP-1', 'assignedDriverUid': 'uidDriver'},
        ),
        isNull,
      );
    });

    test('another driver\'s truck (e.g. its QR) is rejected', () {
      expect(
        driverTruckStartBlockReason(
          uid: 'uidDriver',
          truckData: {'truckNumber': 'WP-2', 'assignedDriverUid': 'uidOther'},
        ),
        kTruckNotAssignedMessage,
      );
    });

    test('unassigned truck and manual-name-only assignment are rejected', () {
      expect(
        driverTruckStartBlockReason(
            uid: 'uidDriver', truckData: {'truckNumber': 'WP-3'}),
        kTruckNotAssignedMessage,
      );
      expect(
        driverTruckStartBlockReason(uid: 'uidDriver', truckData: {
          'truckNumber': 'WP-4',
          'assignedDriverUid': null,
          'assignedDriverName': 'Driver Dan',
        }),
        kTruckNotAssignedMessage,
      );
      expect(driverTruckStartBlockReason(uid: 'uidDriver', truckData: null),
          kTruckNotAssignedMessage);
    });

    test('signed-out user is rejected', () {
      expect(
        driverTruckStartBlockReason(
          uid: null,
          truckData: {'assignedDriverUid': 'uidDriver'},
        ),
        isNotNull,
      );
    });
  });

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
        'assigned truck is auto-selected, other trucks are hidden, tap '
        'starts the session on it ($label)', (tester) async {
      await setSurface(tester, size);
      final db = await _fixture();
      await db.collection('trucks').doc('mine').set({
        'truckNumber': 'WP-1111',
        'assignedDriverUid': 'uidDriver',
        'assignedDriverName': 'Driver Dan',
      });
      await db.collection('trucks').doc('other').set({
        'truckNumber': 'WP-2222',
        'assignedDriverUid': 'uidOther',
      });
      await db.collection('trucks').doc('free').set({'truckNumber': 'WP-3333'});

      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('Your assigned truck'), findsOneWidget);
      expect(find.text('WP-1111'), findsOneWidget);
      // No picker: trucks of other drivers / unassigned trucks never show.
      expect(find.text('WP-2222'), findsNothing);
      expect(find.text('WP-3333'), findsNothing);
      expect(find.text(kNoTruckAssignedMessage), findsNothing);

      await tester.tap(find.text('WP-1111'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Daily Check — WP-1111'), findsOneWidget);

      final sessions = await db.collection('truck_sessions').get();
      expect(sessions.docs, hasLength(1));
      expect(sessions.docs.single.data()['truckId'], 'mine');
      expect(sessions.docs.single.data()['driverUid'], 'uidDriver');
    });

    testWidgets(
        'no assigned truck -> "No truck assigned, contact admin." and no '
        'picker ($label)', (tester) async {
      await setSurface(tester, size);
      final db = await _fixture();
      await db.collection('trucks').doc('other').set({
        'truckNumber': 'WP-2222',
        'assignedDriverUid': 'uidOther',
      });
      // Manually typed name only (assignedDriverUid null) is NOT a match.
      await db.collection('trucks').doc('typed').set({
        'truckNumber': 'WP-4444',
        'assignedDriverUid': null,
        'assignedDriverName': 'Driver Dan',
      });

      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text(kNoTruckAssignedMessage), findsOneWidget);
      expect(find.text('WP-2222'), findsNothing);
      expect(find.text('WP-4444'), findsNothing);
      expect((await db.collection('truck_sessions').get()).docs, isEmpty);
    });

    testWidgets(
        'assignment changed while a session is open -> session kept, '
        'CONTINUE offered, new truck shown ($label)', (tester) async {
      await setSurface(tester, size);
      final db = await _fixture();
      await db.collection('trucks').doc('old').set({
        'truckNumber': 'WP-OLD1',
        'assignedDriverUid': 'uidOther',
      });
      await db.collection('trucks').doc('new').set({
        'truckNumber': 'WP-NEW1',
        'assignedDriverUid': 'uidDriver',
      });
      await db.collection('truck_sessions').doc('s1').set({
        'driverUid': 'uidDriver',
        'driverName': 'Driver Dan',
        'truckId': 'old',
        'truckNumber': 'WP-OLD1',
        'date': _todayKey(),
        'status': 'active',
      });

      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.byKey(const ValueKey('driver-stale-session')), findsOneWidget);
      expect(find.text('Your truck assignment has changed.'), findsOneWidget);
      expect(find.textContaining('Now assigned: WP-NEW1'), findsOneWidget);
      expect(find.text('CONTINUE WP-OLD1'), findsOneWidget);
      expect(find.text('WP-NEW1'), findsOneWidget);

      final s1 = await db.collection('truck_sessions').doc('s1').get();
      expect(s1.data()?['status'], 'active');
    });

    testWidgets(
        'list goes stale (truck re-assigned to someone else after the list '
        'loaded) -> start is rejected with "not assigned" ($label)',
        (tester) async {
      await setSurface(tester, size);
      final db = await _fixture();
      await db.collection('trucks').doc('mine').set({
        'truckNumber': 'WP-1111',
        'assignedDriverUid': 'uidDriver',
      });

      await tester.pumpWidget(host(db));
      await settle(tester);
      expect(find.text('WP-1111'), findsOneWidget);

      // Re-assign without the live stream reaching the screen yet: the
      // fresh doc read inside the start gate must catch it.
      await db
          .collection('trucks')
          .doc('mine')
          .update({'assignedDriverUid': 'uidOther'});
      // No frame pumped since the update, so the old card is still the
      // one on screen — tapping it must be blocked by the gate.
      await tester.tap(find.text('WP-1111'));
      await settle(tester);
      expect(find.text(kTruckNotAssignedMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect((await db.collection('truck_sessions').get()).docs, isEmpty);
    });
  }
}
