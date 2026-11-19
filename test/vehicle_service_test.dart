// Widget tests for the new Scheduled Vehicle Service screens
// (ServiceItemsScreen, ServiceRecordFormScreen, ServiceApprovalListScreen,
// ServiceApprovalDetailScreen, ServiceOverviewScreen,
// VehicleServiceHistoryScreen).
//
// Run with the REAL app theme (AppTheme.light()) at both a narrow phone
// width and a wide desktop width, asserting tester.takeException() is null
// — this is exactly the check that would have caught the
// "BoxConstraints forces an infinite width" bug found in
// RepairApprovalDetailScreen's Row-of-buttons (AppTheme.light()'s button
// themes use a finite minimumSize now, but any NEW button placed in a Row/
// Wrap without Expanded/Flexible would still only show up under this
// theme, at a size where the bug would actually manifest).
//
// FakeFirebaseFirestore (no real Firebase project) is injected via each
// screen's firestoreOverride/currentUidOverride — test-only seams added by
// this feature; every production call site leaves them null and gets the
// real FirebaseFirestore.instance/FirebaseAuth.instance unchanged.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

Future<FakeFirebaseFirestore> _fixture() async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidAdmin').set({
    'name': 'Admin Alice',
    'role': 'admin',
  });
  await firestore.collection('service_items').doc('item1').set({
    'name': '45,000 km Service',
    'intervalKm': 45000,
    'intervalDays': null,
    'warnBeforeKm': 1000,
    'appliesTo': 'ALL',
    'vehicleNumbers': <String>[],
    'checklist': [
      {'id': 'c1', 'name': 'Engine oil + filter', 'sortOrder': 0, 'active': true},
      {'id': 'c2', 'name': 'Tyres', 'sortOrder': 1, 'active': true},
    ],
    'active': true,
    'sortOrder': 1,
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

Future<void> _addSubmittedRecord(FakeFirebaseFirestore firestore, String id) async {
  await firestore.collection('service_records').doc(id).set({
    'recordNo': 'SVC-0001',
    'vehicleNumber': 'WP-1234',
    'status': ServiceRecordStatus.submitted,
    'serviceDate': Timestamp.now(),
    'currentKm': 12000,
    'items': [
      {'itemId': 'item1', 'itemName': 'Engine Oil + Filter'},
    ],
    'extraItems': <Map<String, dynamic>>[],
    'garageName': 'ABC Garage',
    'garageContactNumber': '0771234567',
    'totalPriceCents': 500000,
    'note': '',
    'photos': <Map<String, dynamic>>[],
    'voices': <Map<String, dynamic>>[],
    'submittedBy': 'uidMechanic',
    'submittedByName': 'Mechanic Joe',
    'submittedAt': Timestamp.now(),
  });
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

    testWidgets('ServiceItemsScreen: no layout exception ($label)', (tester) async {
      await setSurface(tester, size);
      final firestore = await _fixture();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceItemsScreen(firestoreOverride: firestore, currentUidOverride: 'uidAdmin'),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('45,000 km Service'), findsOneWidget);
    });

    testWidgets(
      'ServiceRecordFormScreen: schedule pick then checklist + submit button, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceRecordFormScreen(
            vehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // Step 1 — schedule picker.
        expect(find.text('45,000 km Service'), findsOneWidget);
        expect(find.text('LOG WITHOUT A SCHEDULE (ON-DEMAND)'), findsOneWidget);

        await tester.tap(find.text('45,000 km Service'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Step 2 — checklist pre-listed from the schedule, plus the rest of
        // the form.
        expect(find.text('Engine oil + filter'), findsOneWidget);
        expect(find.text('Tyres'), findsOneWidget);
        expect(find.text('SUBMIT FOR APPROVAL'), findsOneWidget);
        expect(find.text('ADD EXTRA ITEM'), findsOneWidget);
      },
    );

    testWidgets('ServiceApprovalListScreen: no layout exception ($label)', (tester) async {
      await setSurface(tester, size);
      final firestore = await _fixture();
      await _addSubmittedRecord(firestore, 'rec1');
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceApprovalListScreen(
          firestoreOverride: firestore,
          currentUidOverride: 'uidAdmin',
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('SVC-0001'), findsOneWidget);
    });

    testWidgets(
      'ServiceApprovalDetailScreen: APPROVE/RETURN Row, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await _addSubmittedRecord(firestore, 'rec1');
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceApprovalDetailScreen(
            recordId: 'rec1',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.widgetWithText(ElevatedButton, 'APPROVE'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'RETURN'), findsOneWidget);
      },
    );

    testWidgets('ServiceOverviewScreen: tabs render, no layout exception ($label)', (tester) async {
      await setSurface(tester, size);
      final firestore = await _fixture();
      await firestore.collection('trucks').doc('truck1').set({
        'truckNumber': 'WP-1234',
        'isCompanyTruck': false,
      });
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceOverviewScreen(firestoreOverride: firestore, currentUidOverride: 'uidAdmin'),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('OVERDUE'), findsWidgets);
      expect(find.text('MONTHLY COSTS'), findsWidgets);
    });

    testWidgets(
      'ServiceOverviewScreen: a SUBMITTED (not yet approved) record shows the '
      'PROVISIONAL "AWAITING APPROVAL" chip, not a red/overdue row, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('trucks').doc('truck1').set({
          'truckNumber': 'WP-1234',
          'isCompanyTruck': false,
        });
        await firestore.collection('service_records').doc('rec1').set({
          'recordNo': 'SVC-0001',
          'vehicleNumber': 'WP-1234',
          'scheduleId': 'item1',
          'scheduleName': '45,000 km Service',
          'status': ServiceRecordStatus.submitted,
          'serviceDate': Timestamp.now(),
          'currentKm': 46000,
          'milestoneKm': 45000,
          'totalPriceCents': 500000,
          'submittedBy': 'uidMechanic',
          'submittedByName': 'Mechanic Joe',
          'submittedAt': Timestamp.now(),
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceOverviewScreen(firestoreOverride: firestore, currentUidOverride: 'uidAdmin'),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // PROVISIONAL AWAITING_APPROVAL forces status OK, so the vehicle is
        // under the OK filter, not OVERDUE. (The old OVERDUE/DUE SOON/
        // SERVICED tabs are now one SERVICE STATUS table with filter chips.)
        await tester.tap(find.byKey(const ValueKey('dtv-filter-OK')));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-1234'), findsOneWidget);
        expect(find.textContaining('AWAITING APPROVAL'), findsOneWidget);
      },
    );

    testWidgets(
      'VehicleServiceHistoryScreen: history list renders, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await _addSubmittedRecord(firestore, 'rec1');
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleServiceHistoryScreen(
            vehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('SVC-0001'), findsOneWidget);
      },
    );
  }
}
