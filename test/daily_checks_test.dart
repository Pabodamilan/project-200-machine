// Widget tests for the Driver Daily Vehicle Level Check feature
// (DriverTypeScreen's new "Daily Vehicle Check" card, DriverDailyCheckScreen,
// DailyChecksScreen).
//
// Run with the REAL app theme (AppTheme.light()) at both a narrow phone
// width and a wide desktop width, asserting tester.takeException() is null —
// same convention as test/vehicle_service_test.dart and
// test/repair_approval_detail_test.dart.
//
// FakeFirebaseFirestore (no real Firebase project) is injected via each
// screen's firestoreOverride/currentUidOverride test-only seams; every
// production call site leaves them null and gets the real
// FirebaseFirestore.instance/FirebaseAuth.instance unchanged.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

String _todayKey() => dailyCheckDateKey(DateTime.now());

// Simulates a live permission-denied on specific collections while every
// other collection still goes through the real FakeFirebaseFirestore
// normally — used to prove the "non-blocking" requirement: a rejected
// daily_checks read must not abort truck selection or block the daily
// check screen from opening. Only the members actually called anywhere in
// the driver flow (collection/doc/get) are overridden; everything else
// relies on Dart's "implements + noSuchMethod" allowance (same mechanism
// package:mockito's Mock relies on) since nothing else is ever invoked on
// these wrapper instances by the code under test.
class _ThrowingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final Set<String> throwingCollections;
  _ThrowingFirestore(this.inner, this.throwingCollections);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    final real = inner.collection(collectionPath);
    if (throwingCollections.contains(collectionPath)) {
      return _ThrowingCollectionReference(real);
    }
    return real;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingCollectionReference implements CollectionReference<Map<String, dynamic>> {
  final CollectionReference<Map<String, dynamic>> inner;
  _ThrowingCollectionReference(this.inner);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    return _ThrowingDocumentReference(inner.doc(path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingDocumentReference implements DocumentReference<Map<String, dynamic>> {
  final DocumentReference<Map<String, dynamic>> inner;
  _ThrowingDocumentReference(this.inner);

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    throw FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'Simulated permission-denied for testing (${inner.path})',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<FakeFirebaseFirestore> _fixture() async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidAdmin').set({
    'name': 'Admin Alice',
    'role': 'admin',
  });
  await firestore.collection('users').doc('uidDriver').set({
    'name': 'Driver Dan',
    'role': 'driver',
  });
  await firestore.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
    'testModeAllowSameUser': false,
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
      'DriverTypeScreen: active truck + daily check NOT submitted today -> '
      'auto-opens DriverDailyCheckScreen with no skip (requireDailyCheck '
      'defaults true), no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('truck_sessions').doc('sess1').set({
          'driverUid': 'uidDriver',
          'driverName': 'Driver Dan',
          'truckId': 'truck1',
          'truckNumber': 'WP-9999',
          'date': _todayKey(),
          'status': 'active',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DriverTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // Auto-prompted straight to the check — not the home screen's card.
        expect(find.textContaining('Daily Check — WP-9999'), findsOneWidget);
        expect(find.text('WATER LEVEL'), findsOneWidget);
        expect(find.text('ENGINE OIL LEVEL'), findsOneWidget);
        expect(find.text('HYDRAULIC OIL LEVEL'), findsOneWidget);
        // requireDailyCheck defaults true and this user isn't admin/owner,
        // so there is no escape hatch.
        expect(find.text('SKIP — DO LATER'), findsNothing);
        expect(find.byType(BackButton), findsNothing);
      },
    );

    testWidgets(
      'DriverTypeScreen: active truck + daily check already submitted today -> '
      'DONE TODAY card, no auto-navigation, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('truck_sessions').doc('sess1').set({
          'driverUid': 'uidDriver',
          'driverName': 'Driver Dan',
          'truckId': 'truck1',
          'truckNumber': 'WP-9999',
          'date': _todayKey(),
          'status': 'active',
        });
        await firestore.collection('daily_checks').doc('WP-9999_${_todayKey()}').set({
          'vehicleNumber': 'WP-9999',
          'date': _todayKey(),
          'driverUid': 'uidDriver',
          'driverName': 'Driver Dan',
          'checks': const [],
          'hasLow': false,
          'submittedAt': Timestamp.now(),
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DriverTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('DONE TODAY'), findsOneWidget);
        expect(find.textContaining('WP-9999'), findsOneWidget);
        // Stayed on the home screen — no auto-navigation when already done.
        expect(find.text('What are you operating today?'), findsOneWidget);
      },
    );

    testWidgets(
      'DriverTypeScreen: no Daily Vehicle Check card without an active truck '
      'session, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DriverTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Daily Vehicle Check'), findsNothing);
      },
    );

    testWidgets(
      'DriverDailyCheckScreen: 3 checks + submit, blocked without photos, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DriverDailyCheckScreen(
            vehicleNumber: 'WP-9999',
            driverName: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WATER LEVEL'), findsOneWidget);
        expect(find.text('ENGINE OIL LEVEL'), findsOneWidget);
        expect(find.text('HYDRAULIC OIL LEVEL'), findsOneWidget);
        expect(find.text('ADD PHOTO (REQUIRED)'), findsNWidgets(3));
        expect(find.text('SUBMIT'), findsOneWidget);

        await tester.tap(find.text('SUBMIT'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Please add a photo for every check.'), findsOneWidget);
      },
    );

    testWidgets(
      'TruckTypeScreen: truck list renders, tapping a truck creates the '
      'truck_sessions doc and auto-opens the daily check, submit validation '
      'still requires a photo, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('trucks').doc('truck1').set({
          'truckNumber': 'WP-9999',
          'isCompanyTruck': true,
          'assignedDriverUid': 'uidDriver',
          'assignedDriverName': 'Driver Dan',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-9999'), findsOneWidget);

        await tester.tap(find.text('WP-9999'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Auto-opened straight into the daily check instead of the truck
        // work area, since today's check for this vehicle isn't submitted.
        expect(find.textContaining('Daily Check — WP-9999'), findsOneWidget);
        expect(find.text('WATER LEVEL'), findsOneWidget);

        final sessions = await firestore
            .collection('truck_sessions')
            .where('truckId', isEqualTo: 'truck1')
            .where('status', isEqualTo: 'active')
            .get();
        expect(sessions.docs, hasLength(1));
        expect(sessions.docs.first.data()['driverUid'], equals('uidDriver'));
        expect(sessions.docs.first.data()['truckNumber'], equals('WP-9999'));

        await tester.tap(find.text('SUBMIT'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Please add a photo for every check.'), findsOneWidget);
      },
    );

    testWidgets(
      'TruckTypeScreen: another driver already has an active session on the '
      'same truck today -> current driver still gets their own session '
      '(not blocked, other driver\'s doc untouched), no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('trucks').doc('truck1').set({
          'truckNumber': 'WP-9999',
          'isCompanyTruck': true,
          'assignedDriverUid': 'uidDriver',
          'assignedDriverName': 'Driver Dan',
        });
        // Another driver's active session on this same truck, today — the
        // lookup query must never read this doc back for 'uidDriver', since
        // that would be exactly the cross-driver read the live security
        // rules (resource.data.driverUid == request.auth.uid) would reject.
        await firestore.collection('truck_sessions').doc('otherDriverSession').set({
          'driverUid': 'uidOtherDriver',
          'driverName': 'Driver Otto',
          'truckId': 'truck1',
          'truckNumber': 'WP-9999',
          'date': _todayKey(),
          'status': 'active',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: firestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        await tester.tap(find.text('WP-9999'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Not blocked — still proceeds (to the auto-prompted daily check,
        // since neither driver has submitted one today).
        expect(find.textContaining('Daily Check — WP-9999'), findsOneWidget);

        final allSessions = await firestore
            .collection('truck_sessions')
            .where('truckId', isEqualTo: 'truck1')
            .where('status', isEqualTo: 'active')
            .get();
        // The other driver's session is untouched, and the current driver
        // got their own new one — two independent sessions, not one shared
        // or blocked session.
        expect(allSessions.docs, hasLength(2));
        final driverUids = allSessions.docs.map((d) => d.data()['driverUid']).toSet();
        expect(driverUids, equals({'uidOtherDriver', 'uidDriver'}));

        final otherDoc =
            await firestore.collection('truck_sessions').doc('otherDriverSession').get();
        expect(otherDoc.data()?['driverUid'], equals('uidOtherDriver'));
      },
    );

    testWidgets(
      'TruckTypeScreen: daily_checks read throws FirebaseException '
      '(permission-denied) -> truck still selected, daily check screen still '
      'opens, no exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('trucks').doc('truck1').set({
          'truckNumber': 'WP-9999',
          'isCompanyTruck': true,
          'assignedDriverUid': 'uidDriver',
          'assignedDriverName': 'Driver Dan',
        });
        final throwingFirestore = _ThrowingFirestore(firestore, {'daily_checks'});

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckTypeScreen(
            name: 'Driver Dan',
            firestoreOverride: throwingFirestore,
            currentUidOverride: 'uidDriver',
          ),
        ));
        await settle(tester);
        await tester.tap(find.text('WP-9999'));
        await settle(tester);

        // Non-blocking: no exception, and selection still proceeds all the
        // way to the auto-opened daily check screen rather than aborting.
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Daily Check — WP-9999'), findsOneWidget);
        expect(find.text('WATER LEVEL'), findsOneWidget);

        // The truck_sessions collection isn't rejected, so the session was
        // still created normally.
        final sessions = await firestore
            .collection('truck_sessions')
            .where('truckId', isEqualTo: 'truck1')
            .where('status', isEqualTo: 'active')
            .get();
        expect(sessions.docs, hasLength(1));
        expect(sessions.docs.first.data()['driverUid'], equals('uidDriver'));

        // The non-blocking warning surfaced instead of a thrown error.
        expect(
          find.textContaining("Couldn't confirm today's check status"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'DailyChecksScreen: today tab shows a LOW record with ADD REPAIR, '
      'not-checked tab shows an unchecked active truck, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        final todayKey = _todayKey();
        await firestore.collection('daily_checks').doc('WP-9999_$todayKey').set({
          'vehicleNumber': 'WP-9999',
          'date': todayKey,
          'driverUid': 'uidDriver',
          'driverName': 'Driver Dan',
          'checks': [
            {
              'id': 'water_level',
              'label': 'Water Level',
              'status': 'LOW',
              'photoUrl': 'https://example.com/water.jpg',
              'note': 'TOPPED UP',
            },
            {
              'id': 'engine_oil_level',
              'label': 'Engine Oil Level',
              'status': 'OK',
              'photoUrl': 'https://example.com/oil.jpg',
              'note': '',
            },
            {
              'id': 'hydraulic_oil_level',
              'label': 'Hydraulic Oil Level',
              'status': 'OK',
              'photoUrl': 'https://example.com/hyd.jpg',
              'note': '',
            },
          ],
          'hasLow': true,
          'submittedBy': 'uidDriver',
          'submittedByName': 'Driver Dan',
          'submittedAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
        });
        await firestore.collection('truck_sessions').doc('sess2').set({
          'driverUid': 'uidDriver2',
          'driverName': 'Driver Dave',
          'truckId': 'truck2',
          'truckNumber': 'WP-8888',
          'date': todayKey,
          'status': 'active',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DailyChecksScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-9999'), findsOneWidget);
        expect(find.textContaining('Water Level'), findsOneWidget);
        expect(find.text('ADD REPAIR'), findsOneWidget);

        await tester.tap(find.text('NOT CHECKED TODAY'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-8888'), findsOneWidget);
        expect(find.textContaining('Driver Dave'), findsOneWidget);
      },
    );
  }
}
