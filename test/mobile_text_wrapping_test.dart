// Tests for:
// - TechnicalHomeServiceCard (lib/main.dart) — the SERVICE card on
//   TechnicalHomeScreen's dashboard. Covers its 5 states: RED (overdue),
//   AMBER (due soon), KM UNKNOWN, empty ("no services due") and error
//   (+ RETRY).
// - Long-text rendering without overflow on screens touched by the
//   mobile text-wrapping pass: a 60-character service name (on the
//   SERVICE card itself), a 120-character repair description
//   (InspectionRepairsSection, the "REPAIRS FOUND" section), and a long
//   driver name (TruckProfileScreen's "Assigned Driver" card).
//
// Run with the real AppTheme.light() at 360px, 390px and 1200px,
// asserting tester.takeException() is null — same convention as the rest
// of this app's widget tests, extended with the narrower 360px width
// this task specifically asks for.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

// Throws on users/{uid}.get() specifically — the one Firestore read
// _loadAlertsForCurrentUser makes with no try/catch of its own (every
// other read in the pipeline is already individually guarded inside
// fetchServiceAlertsData, which never throws) — so this is the only way
// to exercise TechnicalHomeServiceCard's real error/RETRY path.
class _ThrowingUsersFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  _ThrowingUsersFirestore(this.inner);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath == 'users') return _ThrowingUsersCollection();
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingUsersCollection implements CollectionReference<Map<String, dynamic>> {
  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => _ThrowingUsersDoc();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingUsersDoc implements DocumentReference<Map<String, dynamic>> {
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    throw FirebaseException(
      plugin: 'cloud_firestore',
      code: 'unavailable',
      message: 'Simulated failure for testing',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(() {
    ServiceAlertsCache.reset();
  });

  // Longer than most other test files' settle() — fetchKmByVehicleForAlerts'
  // GPS batch has a 2s timeout (no real Traccar channel in this sandbox),
  // so every case here needs enough simulated time to clear that plus the
  // manual-km fallback query that follows it.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 25; i++) {
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

  Future<FakeFirebaseFirestore> fixtureBase() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('users').doc('uidTech').set({
      'name': 'Tina Technical',
      'role': 'technical',
      'repairPermissions': [kPermServiceDo],
    });
    return firestore;
  }

  const sixtyCharServiceName = '123456789012345678901234567890123456789012345678901234567890';

  for (final size in [const Size(360, 800), const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'TechnicalHomeServiceCard: RED (overdue) row shows the DO SERVICE '
      'button, a 60-char service name does not overflow, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureBase();
        await firestore.collection('trucks').doc('t1').set({'truckNumber': 'WP-1111'});
        await firestore.collection('service_items').doc('sched1').set({
          'name': sixtyCharServiceName,
          'intervalKm': 10000,
          'intervalDays': null,
          'warnBeforeKm': 1000,
          'appliesTo': 'ALL',
          'vehicleNumbers': <String>[],
          'active': true,
          'sortOrder': 1,
        });
        await firestore.collection('service_records').doc('km_hint').set({
          'vehicleNumber': 'WP-1111',
          'status': 'APPROVED',
          'currentKm': 10500,
          'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TechnicalHomeServiceCard(
              name: 'Tina Technical',
              firestoreOverride: firestore,
              currentUidOverride: 'uidTech',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('SERVICE'), findsOneWidget);
        expect(find.text('WP-1111'), findsOneWidget);
        expect(find.textContaining(sixtyCharServiceName), findsOneWidget);
        expect(find.textContaining('OVERDUE'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'DO SERVICE'), findsOneWidget);
      },
    );

    testWidgets(
      'TechnicalHomeServiceCard: AMBER (due soon) row shows DUE IN / DO '
      'SERVICE, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureBase();
        await firestore.collection('trucks').doc('t1').set({'truckNumber': 'WP-2222'});
        await firestore.collection('service_items').doc('sched1').set({
          'name': 'Oil Change',
          'intervalKm': 10000,
          'intervalDays': null,
          'warnBeforeKm': 1000,
          'appliesTo': 'ALL',
          'vehicleNumbers': <String>[],
          'active': true,
          'sortOrder': 1,
        });
        await firestore.collection('service_records').doc('km_hint').set({
          'vehicleNumber': 'WP-2222',
          'status': 'APPROVED',
          'currentKm': 9500,
          'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TechnicalHomeServiceCard(
              name: 'Tina Technical',
              firestoreOverride: firestore,
              currentUidOverride: 'uidTech',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('WP-2222'), findsOneWidget);
        expect(find.textContaining('DUE IN'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'DO SERVICE'), findsOneWidget);
      },
    );

    testWidgets(
      'TechnicalHomeServiceCard: KM UNKNOWN row shows ENTER KM (not DO '
      'SERVICE), no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureBase();
        await firestore.collection('trucks').doc('t1').set({'truckNumber': 'WP-3333'});
        await firestore.collection('service_items').doc('sched1').set({
          'name': 'Oil Change',
          'intervalKm': 10000,
          'intervalDays': null,
          'warnBeforeKm': 1000,
          'appliesTo': 'ALL',
          'vehicleNumbers': <String>[],
          'active': true,
          'sortOrder': 1,
        });
        // No service_records at all for WP-3333 -> currentKm stays null.

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TechnicalHomeServiceCard(
              name: 'Tina Technical',
              firestoreOverride: firestore,
              currentUidOverride: 'uidTech',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('WP-3333'), findsOneWidget);
        expect(find.textContaining('KM UNKNOWN'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'ENTER KM'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'DO SERVICE'), findsNothing);
      },
    );

    testWidgets(
      'TechnicalHomeServiceCard: no vehicles/schedules -> NO SERVICES DUE '
      'empty state, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureBase();
        // trucks/service_items deliberately left empty.

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TechnicalHomeServiceCard(
              name: 'Tina Technical',
              firestoreOverride: firestore,
              currentUidOverride: 'uidTech',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO SERVICES DUE'), findsOneWidget);
      },
    );

    testWidgets(
      'TechnicalHomeServiceCard: a load failure shows an error with RETRY, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureBase();
        final throwing = _ThrowingUsersFirestore(firestore);

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: TechnicalHomeServiceCard(
              name: 'Tina Technical',
              firestoreOverride: throwing,
              currentUidOverride: 'uidTech',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Failed to load services'), findsOneWidget);
        expect(find.text('RETRY'), findsOneWidget);
      },
    );

    testWidgets(
      'InspectionRepairsSection: a 120-character repair description wraps '
      'without overflow, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidInspector').set({
          'name': 'Ian Inspector',
          'role': 'technical',
          'repairPermissions': [kPermReportDefect],
        });
        final longDescription = List.generate(16, (_) => 'LEAKING').join(' ');
        expect(longDescription.length, greaterThanOrEqualTo(120));
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD-ENG-0001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'inspectionId': 'WP-1234_2026-10-30',
          'description': longDescription,
          'status': 'REPORTED',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: InspectionRepairsSection(
                userName: 'Ian Inspector',
                vehicleNumber: 'WP-1234',
                inspectionId: 'WP-1234_2026-10-30',
                firestoreOverride: firestore,
                currentUidOverride: 'uidInspector',
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining(longDescription), findsOneWidget);
      },
    );

    testWidgets(
      'TruckProfileScreen: a long driver name wraps without overflow, no '
      'layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        const longDriverName = 'Mr Appuhamilage Don Sumanadasa Wickramasinghe Bandaranayake';
        expect(longDriverName.length, greaterThan(40));
        await firestore.collection('trucks').doc('t1').set({
          'truckNumber': 'WP-5555',
          'assignedDriverName': longDriverName,
          'assignedDriverUid': 'uidDriver',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-5555',
            firestoreOverride: firestore,
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining(longDriverName), findsOneWidget);
      },
    );
  }
}
