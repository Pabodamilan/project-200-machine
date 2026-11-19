// Widget tests for this task's TechnicalHomeScreen additions: the shared
// ServiceAlertsBell/ServiceAlertsBanner widgets (already built for
// TruckRepairHubScreen/ManagementDashboard, reused here rather than
// duplicated) and the Truck Repairs tile's red overdue-count badge. Also
// covers ManagementDashboard's new ServiceFleetSummaryCounts row. Run with
// the real AppTheme.light() at both a narrow phone width and a wide desktop
// width, asserting tester.takeException() is null — same convention as the
// rest of this feature set's tests.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

Future<FakeFirebaseFirestore> _fixtureWithOverdueVehicle() async {
  final firestore = FakeFirebaseFirestore();
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
  await firestore.collection('service_records').doc('km_hint').set({
    'vehicleNumber': 'WP-1111',
    'status': 'APPROVED',
    'currentKm': 46000,
    'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
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
    ServiceAlertsCache.reset();
  });

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
      'TechnicalHomeScreen: an overdue vehicle shows the alerts bell badge, '
      'the red banner and the Truck Repairs tile badge, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'canAccessGarage': true,
          'canAccessWarehouse': true,
          'repairPermissions': technicalDefaults().repairPermissions,
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TechnicalHomeScreen(
            name: 'Tina Technical',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Bell badge in the app bar.
        expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
        expect(find.text('1'), findsWidgets);

        // Red "N vehicle(s) overdue" banner in the body.
        expect(find.textContaining('vehicle(s) overdue for service'), findsOneWidget);

        // Repairs To Do tile still renders alongside its badge.
        expect(find.text('Repairs To Do'), findsOneWidget);
      },
    );

    testWidgets(
      'TechnicalHomeScreen: no outstanding alerts -> bell with no badge, no '
      'banner, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('settings').doc('repair_workflow').set({
          'managerApprovalLimit': 100000,
          'multiQuotationThreshold': 50000,
          'multiQuotationMinCount': 2,
        });
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'canAccessGarage': true,
          'canAccessWarehouse': true,
          'repairPermissions': technicalDefaults().repairPermissions,
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TechnicalHomeScreen(
            name: 'Tina Technical',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.notifications_outlined), findsOneWidget);
        expect(find.textContaining('vehicle(s) overdue for service'), findsNothing);
      },
    );

    testWidgets(
      'ServiceFleetSummaryCounts: SERVICED/DUE SOON/OVERDUE counts for the '
      'Management Dashboard, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixtureWithOverdueVehicle();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        // A second, fully up-to-date vehicle so SERVICED > 0 too.
        await firestore.collection('trucks').doc('t2').set({'truckNumber': 'WP-2222'});
        await firestore.collection('service_records').doc('km_hint2').set({
          'vehicleNumber': 'WP-2222',
          'status': 'APPROVED',
          'currentKm': 1000,
          'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ServiceFleetSummaryCounts(
                firestoreOverride: firestore,
                currentUidOverride: 'uidAdmin',
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('SERVICED'), findsOneWidget);
        expect(find.text('DUE SOON'), findsOneWidget);
        expect(find.text('OVERDUE'), findsOneWidget);
        // WP-1111 is overdue, WP-2222 is fully serviced.
        expect(find.text('1'), findsWidgets);
      },
    );
  }
}
