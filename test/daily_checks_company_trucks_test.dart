// DailyChecksScreen NOT CHECKED TODAY tab: every company truck lands in
// exactly one of Checked / Not checked (built from the trucks collection,
// not only today's truck_sessions), vehicle numbers match across format
// differences, and ownership-not-set trucks are only mentioned in a note.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

String _today() => colomboDateKey(DateTime.now());

// 11 company trucks: LM-6435 + WP-0002 checked today (LM-6435's check was
// saved as "lm 6435"), WP-0011 has no driver; plus 2 not-set + 1 private.
Future<FakeFirebaseFirestore> _fixture() async {
  final db = FakeFirebaseFirestore();
  await db.collection('users').doc('uidAdmin').set({'name': 'Admin Alice', 'role': 'admin'});
  await db.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
  });
  Future<void> truck(String id, String number, Object? company, {String? driver}) =>
      db.collection('trucks').doc(id).set({
        'truckNumber': number,
        'isCompanyTruck': ?company,
        'assignedDriverName': ?driver,
        'assignedDriverUid': ?(driver == null ? null : 'uid-$id'),
      });
  await truck('t1', 'LM-6435', true, driver: 'Driver One');
  await truck('t2', 'WP-0002', true, driver: 'Driver Two');
  for (var i = 3; i <= 10; i++) {
    await truck('t$i', 'WP-${i.toString().padLeft(4, '0')}', true, driver: 'Driver $i');
  }
  await truck('t11', 'WP-0011', true); // no driver
  await truck('n1', 'NS-0001', null);
  await truck('n2', 'NS-0002', 'yes'); // not a bool -> not set
  await truck('p1', 'PV-0001', false, driver: 'Hired Harry');

  final key = _today();
  await db.collection('daily_checks').doc('LM 6435_$key').set({
    'vehicleNumber': 'lm 6435',
    'date': key,
    'driverName': 'Driver One',
    'hasLow': false,
    'checks': const [],
    'submittedAt': Timestamp.now(),
  });
  await db.collection('daily_checks').doc('WP-0002_$key').set({
    'vehicleNumber': 'WP-0002',
    'date': key,
    'driverName': 'Driver Two',
    'hasLow': true,
    'checks': const [],
    'submittedAt': Timestamp.now(),
  });
  // A check from yesterday must not count as today.
  await db.collection('daily_checks').doc('WP-0003_2000-01-01').set({
    'vehicleNumber': 'WP-0003',
    'date': '2000-01-01',
    'checks': const [],
  });
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async {
    await Firebase.initializeApp();
  });

  group('vehicleMatchKey / buildDailyCheckFleetStatus', () {
    test('vehicle number formats match', () {
      expect(vehicleMatchKey('LM-6435'), 'LM6435');
      expect(vehicleMatchKey(' lm 6435 '), 'LM6435');
      expect(vehicleMatchKey('LM6435'), 'LM6435');
      expect(vehicleMatchKey('WP/LM-6435'), 'WPLM6435');
      // Doc-id normalizer is unchanged.
      expect(normalizeVehicleNumber(' lm-6435 '), 'LM-6435');
    });

    test('11 company trucks -> 2 checked + 9 not checked, not-set excluded', () {
      final trucks = [
        for (var i = 1; i <= 11; i++)
          {
            'id': 't$i',
            'truckNumber': i == 1 ? 'LM-6435' : 'WP-$i',
            'isCompanyTruck': true,
            if (i != 11) 'assignedDriverName': 'Driver $i',
          },
        {'id': 'n1', 'truckNumber': 'NS-1'},
        {'id': 'n2', 'truckNumber': 'NS-2', 'isCompanyTruck': null},
        {'id': 'p1', 'truckNumber': 'PV-1', 'isCompanyTruck': false},
      ];
      final fleet = buildDailyCheckFleetStatus(
        trucks: trucks,
        todayChecks: [
          {'vehicleNumber': 'LM6435'},
          {'vehicleNumber': 'wp 2'},
          {'vehicleNumber': 'PV-1'}, // private truck checked: not counted
        ],
        activeSessions: [
          {'truckNumber': 'WP-5', 'driverName': 'Session Sam'},
          {'truckNumber': 'XX-9', 'driverName': 'Other Olly'},
        ],
      );
      expect(fleet.companyCount, 11);
      expect(fleet.checked.map((r) => r.truckId), ['t1', 't2']);
      expect(fleet.notChecked.length, 9);
      expect(fleet.checked.length + fleet.notChecked.length, fleet.companyCount);
      expect(fleet.notSetCount, 2);
      expect(fleet.privateCount, 1);
      expect(fleet.totalTrucks, 14);
      final t11 = fleet.notChecked.firstWhere((r) => r.truckId == 't11');
      expect(t11.noDriver, isTrue);
      // Assigned driver wins over the session driver.
      expect(fleet.notChecked.firstWhere((r) => r.truckId == 't5').driverName, 'Driver 5');
      // Non-company active session listed separately, not counted.
      expect(fleet.otherActive.map((e) => e.truckNumber), ['XX-9']);
    });

    test('no assigned driver but an active session -> session driver used', () {
      final fleet = buildDailyCheckFleetStatus(
        trucks: [
          {'id': 't1', 'truckNumber': 'WP-1', 'isCompanyTruck': true},
        ],
        todayChecks: const [],
        activeSessions: [
          {'truckNumber': 'wp1', 'driverName': 'Session Sam'},
        ],
      );
      expect(fleet.notChecked.single.driverName, 'Session Sam');
      expect(fleet.otherActive, isEmpty);
    });
  });

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets('DailyChecksScreen: 11 company trucks -> Checked 2, Not checked 9 ($label)',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final db = await _fixture();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: DailyChecksScreen(firestoreOverride: db, currentUidOverride: 'uidAdmin'),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.tap(find.text('NOT CHECKED TODAY'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      Text textOf(String key) => tester.widget<Text>(find.byKey(ValueKey(key)));
      expect(textOf('daily-checks-count-company').data, '11');
      expect(textOf('daily-checks-count-checked').data, '2');
      expect(textOf('daily-checks-count-not-checked').data, '9');
      expect(textOf('daily-checks-not-checked-title').data, 'NOT CHECKED TODAY (9)');
      expect(textOf('daily-checks-fleet-debug').data, contains('not set 2'));
      expect(find.textContaining('2 trucks have no ownership set'), findsOneWidget);

      final scrollable = find.byType(Scrollable).last;
      final noDriverRow = find.byKey(const ValueKey('daily-checks-not-checked-t11'));
      await tester.scrollUntilVisible(noDriverRow, 200, scrollable: scrollable);
      expect(
        find.descendant(of: noDriverRow, matching: find.text(kNoDriverAssignedLabel)),
        findsOneWidget,
      );
      // Not-set / private trucks never appear as rows.
      expect(find.text('NS-0001'), findsNothing);
      expect(find.text('PV-0001'), findsNothing);

      final checkedRow = find.byKey(const ValueKey('daily-checks-checked-t1'));
      await tester.scrollUntilVisible(checkedRow, 200, scrollable: scrollable);
      expect(find.descendant(of: checkedRow, matching: find.text('LM-6435')), findsOneWidget);
      expect(find.descendant(of: checkedRow, matching: find.text('CHECKED')), findsOneWidget);
      final lowRow = find.byKey(const ValueKey('daily-checks-checked-t2'));
      await tester.scrollUntilVisible(lowRow, 200, scrollable: scrollable);
      expect(find.descendant(of: lowRow, matching: find.text('LOW')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ownership-not-set note opens Truck Ownership', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final db = await _fixture();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: DailyChecksScreen(firestoreOverride: db, currentUidOverride: 'uidAdmin'),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.tap(find.text('NOT CHECKED TODAY'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('daily-checks-ownership-not-set')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(TruckOwnershipScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
