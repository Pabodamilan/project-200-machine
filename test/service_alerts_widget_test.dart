// Widget tests for the RED ALERTS feature's UI: the bell badge
// (ServiceAlertsBell), the banner (ServiceAlertsBanner) and the full
// ALERTS screen (ServiceAlertsScreen). Run with the real AppTheme.light()
// at both a narrow phone width and a wide desktop width, asserting
// tester.takeException() is null — same convention as the rest of this
// feature set's tests.
//
// ServiceAlertsCache is a process-global cache (so the bell/banner/hub
// badges all share one fetch) — every test resets it first so widths and
// test cases never see each other's cached data.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

Future<FakeFirebaseFirestore> _fixtureWithOverdueVehicle() async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidAdmin').set({
    'name': 'Admin Alice',
    'role': 'admin',
  });
  await firestore.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
  });
  await firestore.collection('trucks').doc('t1').set({'truckNumber': 'WP-1111'});
  await firestore.collection('service_items').doc('sched1').set({
    'name': '45,000 km Service',
    'intervalKm': 45000,
    'intervalDays': null,
    'warnBeforeKm': 1000,
    'appliesTo': 'ALL',
    'vehicleNumbers': <String>[],
    'active': true,
    'sortOrder': 1,
  });
  // Gives fetchKmByVehicleForAlerts' manual-km fallback a real reading for
  // WP-1111 (GPS always fails fast in this sandbox — no Traccar channel —
  // so every vehicle falls back to this path in these tests).
  await firestore.collection('service_records').doc('km_hint').set({
    'vehicleNumber': 'WP-1111',
    'status': 'APPROVED',
    'currentKm': 46000,
    'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
  });
  return firestore;
}

// Simulates a live permission-denied on specific collections (both plain
// `.collection(x).get()` and `.collection(x).where(...).get()`) while
// every other collection goes through the real FakeFirebaseFirestore
// normally — used to prove fetchServiceAlertsData's per-source isolation.
// Relies on Dart's "implements + noSuchMethod" allowance (same mechanism
// package:mockito's Mock relies on): `where` isn't explicitly overridden,
// so calling it falls through to noSuchMethod, which hands back `this` so
// the following `.get()` throws too.
class _ThrowingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final Set<String> throwingCollections;
  _ThrowingFirestore(this.inner, this.throwingCollections);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (throwingCollections.contains(collectionPath)) {
      return _ThrowingCollectionReference(collectionPath);
    }
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingCollectionReference implements CollectionReference<Map<String, dynamic>> {
  final String path;
  _ThrowingCollectionReference(this.path);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    throw FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'Simulated permission-denied for testing ($path)',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where) {
      return this; // chain back to self so .where(...).get() also throws
    }
    return super.noSuchMethod(invocation);
  }
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

  // Longer than the other test files' settle() — fetchKmByVehicleForAlerts'
  // GPS batch has a 2s timeout (see its doc comment: an unmocked Firestore
  // platform channel call hangs under TestWidgetsFlutterBinding instead of
  // failing fast), so this needs enough simulated time to clear that plus
  // the manual-km fallback query that follows it.
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

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'ServiceAlertsBell: shows a red count badge for an overdue vehicle, '
      'tap opens the ALERTS screen, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Truck Repairs'),
              actions: [
                ServiceAlertsBell(
                  firestoreOverride: firestore,
                  currentUidOverride: 'uidAdmin',
                ),
              ],
            ),
            body: const SizedBox.shrink(),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
        expect(find.text('1'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.notifications_outlined));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Alerts'), findsOneWidget);
        expect(find.textContaining('WP-1111'), findsWidgets);
      },
    );

    testWidgets(
      'ServiceAlertsBell: no badge and nothing for a user with no qualifying '
      'permission, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        await firestore.collection('users').doc('uidNobody').set({
          'name': 'Nobody',
          'role': 'driver',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            appBar: AppBar(
              actions: [
                ServiceAlertsBell(
                  firestoreOverride: firestore,
                  currentUidOverride: 'uidNobody',
                ),
              ],
            ),
            body: const SizedBox.shrink(),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.notifications_outlined), findsNothing);
      },
    );

    testWidgets(
      'ServiceAlertsBanner: red "vehicle(s) overdue" banner for an admin, '
      'tap opens the ALERTS screen, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ServiceAlertsBanner(
                firestoreOverride: firestore,
                currentUidOverride: 'uidAdmin',
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('vehicle(s) overdue for service'), findsOneWidget);

        await tester.tap(find.textContaining('vehicle(s) overdue for service'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Alerts'), findsOneWidget);
      },
    );

    testWidgets(
      'ServiceAlertsBanner: nothing shown when there are no overdue/missed '
      'vehicles, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ServiceAlertsBanner(
              firestoreOverride: firestore,
              currentUidOverride: 'uidAdmin',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('overdue for service'), findsNothing);
      },
    );

    testWidgets(
      'ServiceAlertsScreen: grouped OVERDUE/OTHER alerts render with a DO '
      'SERVICE button and the others\' VIEW/APPROVE buttons, search filters '
      'by vehicle, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        final now = DateTime.now();
        await firestore.collection('service_records').doc('returned1').set({
          'vehicleNumber': 'WP-2222',
          'status': 'RETURNED',
          'returnReason': 'MISSING PHOTOS',
          'returnedAt': Timestamp.fromDate(now),
        });
        await firestore.collection('service_records').doc('pending1').set({
          'vehicleNumber': 'WP-3333',
          'status': 'SUBMITTED',
          'submittedAt': Timestamp.fromDate(now.subtract(const Duration(hours: 30))),
          'submittedByName': 'Mechanic Joe',
        });
        await firestore.collection('defect_reports').doc('def1').set({
          'vehicleNumber': 'WP-4444',
          'status': 'OPEN',
          'repairJobId': null,
          'reportedAt': Timestamp.fromDate(now.subtract(const Duration(hours: 48))),
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceAlertsScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.textContaining('OVERDUE'), findsWidgets);
        expect(find.textContaining('OTHER'), findsWidgets);
        expect(find.text('WP-1111'), findsOneWidget);
        expect(find.text('WP-2222'), findsOneWidget);
        expect(find.text('WP-3333'), findsOneWidget);
        expect(find.text('WP-4444'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'DO SERVICE'), findsWidgets);
        expect(find.widgetWithText(OutlinedButton, 'APPROVE'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'VIEW'), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'WP-1111');
        await settle(tester);
        expect(tester.takeException(), isNull);
        // One match is the search field's own entered text, the other is
        // the surviving alert card.
        expect(find.text('WP-1111'), findsNWidgets(2));
        expect(find.text('WP-2222'), findsNothing);
      },
    );

    testWidgets(
      'ServiceAlertsScreen: empty state when there are no alerts for this '
      'user, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceAlertsScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ALERTS'), findsOneWidget);
      },
    );
  }

  group('fetchServiceAlertsData: per-source resilience', () {
    test('defect_reports throwing permission-denied only drops defect '
        'alerts — service_due/returned/daily_check_low still come through, '
        'and failedSources/hasPartialData record it', () async {
      final firestore = await _fixtureWithOverdueVehicle();
      await firestore.collection('service_records').doc('returned1').set({
        'vehicleNumber': 'WP-2222',
        'status': 'RETURNED',
        'returnReason': 'MISSING PHOTOS',
        'returnedAt': Timestamp.now(),
      });
      await firestore.collection('daily_checks').doc('dc1').set({
        'vehicleNumber': 'WP-3333',
        'date': dailyCheckDateKey(DateTime.now()),
        'hasLow': true,
      });
      final throwing = _ThrowingFirestore(firestore, {'defect_reports'});

      final data = await fetchServiceAlertsData(
        db: throwing,
        canSeeMechanic: true,
        canSeeManagement: true,
      );

      // gps_km also legitimately fails in this sandbox (no real Traccar
      // channel), independent of the defect_reports break under test.
      expect(data.failedSources, contains('defect_reports'));
      expect(data.hasPartialData, isTrue);
      expect(
        data.alerts.any((a) => a.kind == ServiceAlertKind.serviceDue && a.vehicleNumber == 'WP-1111'),
        isTrue,
      );
      expect(
        data.alerts.any((a) => a.kind == ServiceAlertKind.serviceReturned),
        isTrue,
      );
      expect(
        data.alerts.any((a) => a.kind == ServiceAlertKind.dailyCheckLow),
        isTrue,
      );
      expect(
        data.alerts.any((a) => a.kind == ServiceAlertKind.defectPending),
        isFalse,
      );
    });

    test('service_records throwing suppresses SERVICE_DUE entirely (no '
        'false OVERDUE fabricated from an empty substitute list) but other '
        'independent sources still come through', () async {
      final firestore = await _fixtureWithOverdueVehicle();
      await firestore.collection('defect_reports').doc('def1').set({
        'vehicleNumber': 'WP-4444',
        'status': 'OPEN',
        'repairJobId': null,
        'reportedAt': Timestamp.fromDate(DateTime.now().subtract(const Duration(hours: 48))),
      });
      final throwing = _ThrowingFirestore(firestore, {'service_records'});

      final data = await fetchServiceAlertsData(
        db: throwing,
        canSeeMechanic: true,
        canSeeManagement: true,
      );

      expect(data.failedSources, contains('service_records'));
      expect(data.alerts.any((a) => a.kind == ServiceAlertKind.serviceDue), isFalse);
      expect(data.alerts.any((a) => a.kind == ServiceAlertKind.defectPending), isTrue);
    });

    test('a mechanic-only fetch never touches daily_checks/truck_sessions, '
        'so those collections "throwing" has no effect at all (proves '
        'scoping, not just error handling)', () async {
      final firestore = await _fixtureWithOverdueVehicle();
      final throwing = _ThrowingFirestore(firestore, {'daily_checks', 'truck_sessions'});

      final data = await fetchServiceAlertsData(
        db: throwing,
        canSeeMechanic: true,
        canSeeManagement: false,
      );

      // daily_checks/truck_sessions never attempted for a mechanic-only
      // viewer, so their "throwing" never surfaces — only gps_km (always
      // unavailable in this sandbox, unrelated to the collections under
      // test here) is expected.
      expect(data.failedSources, equals(['gps_km']));
      expect(data.alerts.any((a) => a.kind == ServiceAlertKind.serviceDue), isTrue);
    });

    test('a management-only fetch never touches defect_reports', () async {
      final firestore = await _fixtureWithOverdueVehicle();
      final throwing = _ThrowingFirestore(firestore, {'defect_reports'});

      final data = await fetchServiceAlertsData(
        db: throwing,
        canSeeMechanic: false,
        canSeeManagement: true,
      );

      expect(data.failedSources, equals(['gps_km']));
      expect(data.alerts.any((a) => a.kind == ServiceAlertKind.serviceDue), isTrue);
    });
  });

  testWidgets(
    'ServiceAlertsScreen: shows "some alerts unavailable" when a source '
    'failed, while the still-available alerts keep rendering, no layout '
    'exception',
    (tester) async {
      final firestore = await _fixtureWithOverdueVehicle();
      final throwing = _ThrowingFirestore(firestore, {'defect_reports'});
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceAlertsScreen(
          firestoreOverride: throwing,
          currentUidOverride: 'uidAdmin',
        ),
      ));
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Some alerts unavailable'), findsOneWidget);
      expect(find.text('WP-1111'), findsOneWidget);
    },
  );
}
