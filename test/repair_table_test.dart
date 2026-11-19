// Tests for the Repair v2 tables (RepairsTable on DataTableView): default
// status-group sort (newest first inside each group), header toggle,
// filter chips, search by code / vehicle, empty state and 25-row pages —
// both on the pure helpers and on the real screens (FakeFirestore).
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

RepairRow _row(String id, String status, {String? vehicle, String? code, int? dayOffset}) =>
    RepairRow(id, {
      'code': code ?? 'NOD/ENG/$id',
      'vehicleNumber': vehicle ?? 'WP-$id',
      'categoryCode': 'ENG',
      'categoryName': 'Engine',
      'description': 'desc $id',
      'status': status,
      if (dayOffset != null)
        'reportedAt': Timestamp.fromDate(DateTime(2026, 1, 1).add(Duration(days: dayOffset))),
    });

double _y(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

Future<void> _surface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<FakeFirebaseFirestore> _fixture() async {
  final db = FakeFirebaseFirestore();
  await db.collection('users').doc('uidAdmin').set({'name': 'Admin', 'role': 'admin'});
  await db.collection('users').doc('uidTechnical').set({
    'name': 'Tina',
    'role': 'technical',
    'repairPermissions': [kPermRepairWork],
  });
  await db.collection('users').doc('uidManagement').set({
    'name': 'Mary',
    'role': 'management',
    'repairPermissions': [kPermApprove, kPermHistoryView],
  });
  return db;
}

Future<void> _addRepair(
  FakeFirebaseFirestore db,
  String id, {
  required String code,
  required String vehicle,
  required String status,
  required int day,
}) =>
    db.collection('repairs').doc(id).set({
      'code': code,
      'vehicleNumber': vehicle,
      'categoryCode': 'ENG',
      'categoryName': 'Engine',
      'description': 'Problem $id',
      'severity': 'NORMAL',
      'status': status,
      'reportedByName': 'Ian',
      'reportedAt': Timestamp.fromDate(DateTime(2026, 3, 1).add(Duration(days: day))),
      'listId': 'list1',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  group('Repair table: pure helpers', () {
    test('real statuses map to the filter buckets', () {
      expect(repairFilterBucket(RepairItemStatus.reported), RepairFilter.pending);
      expect(repairFilterBucket(RepairItemStatus.listed), RepairFilter.pending);
      expect(repairFilterBucket(RepairItemStatus.inProgress), RepairFilter.inProgress);
      expect(repairFilterBucket(RepairItemStatus.returned), RepairFilter.inProgress);
      expect(repairFilterBucket(RepairItemStatus.donePendingApproval),
          RepairFilter.awaitingApproval);
      expect(repairFilterBucket(RepairItemStatus.completed), RepairFilter.completed);
      expect(repairFilterBucket(RepairItemStatus.rejected), RepairFilter.rejected);
    });

    test('default sort: awaiting approval, pending, in progress, done; newest first inside', () {
      final rows = [
        _row('c1', RepairItemStatus.completed, dayOffset: 5),
        _row('p_old', RepairItemStatus.reported, dayOffset: 1),
        _row('i1', RepairItemStatus.inProgress, dayOffset: 3),
        _row('a1', RepairItemStatus.donePendingApproval, dayOffset: 2),
        _row('p_new', RepairItemStatus.listed, dayOffset: 9),
        _row('x1', RepairItemStatus.rejected, dayOffset: 7),
        _row('r1', RepairItemStatus.returned, dayOffset: 4),
        _row('p_nodate', RepairItemStatus.reported),
      ]..sort(compareRepairRowsByStatus);
      expect(rows.map((r) => r.id).toList(),
          ['a1', 'p_new', 'p_old', 'p_nodate', 'r1', 'i1', 'c1', 'x1']);
    });

    test('filter by bucket, search by code or vehicle (case-insensitive)', () {
      final rows = [
        _row('1', RepairItemStatus.reported, vehicle: 'WP-AAA', code: 'NOD/ENG/260001'),
        _row('2', RepairItemStatus.inProgress, vehicle: 'WP-BBB', code: 'NOD/BRK/260002'),
        _row('3', RepairItemStatus.completed, vehicle: 'WP-AAA', code: 'NOD/TYR/260003'),
      ];
      expect(filterRepairRows(rows, bucket: RepairFilter.completed).single.id, '3');
      expect(filterRepairRows(rows, search: 'brk').single.id, '2');
      expect(filterRepairRows(rows, search: 'wp-aaa').map((r) => r.id), ['1', '3']);
      expect(
        filterRepairRows(rows, search: 'WP-AAA', bucket: RepairFilter.pending).single.id,
        '1',
      );
      expect(filterRepairRows(rows, search: 'nothing'), isEmpty);
    });
  });

  group('RepairsTable widget', () {
    Widget host(Widget child) => MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: SizedBox(width: 1400, height: 2400, child: child)),
        );

    testWidgets('default order, Status header toggles, empty state', (tester) async {
      await _surface(tester, const Size(1500, 2500));
      final rows = [
        _row('done', RepairItemStatus.completed, code: 'C-DONE', dayOffset: 1),
        _row('wait', RepairItemStatus.donePendingApproval, code: 'C-WAIT', dayOffset: 1),
        _row('work', RepairItemStatus.inProgress, code: 'C-WORK', dayOffset: 1),
      ];
      await tester.pumpWidget(host(RepairsTable(
        rows: rows,
        columns: const [RepairCol.code, RepairCol.vehicle, RepairCol.status],
      )));
      expect(_y(tester, 'C-WAIT') < _y(tester, 'C-WORK'), isTrue);
      expect(_y(tester, 'C-WORK') < _y(tester, 'C-DONE'), isTrue);

      await tester.tap(find.byKey(const ValueKey('dtv-header-2')));
      await tester.pump();
      expect(_y(tester, 'C-DONE') < _y(tester, 'C-WORK'), isTrue);
      expect(_y(tester, 'C-WORK') < _y(tester, 'C-WAIT'), isTrue);

      await tester.pumpWidget(host(const RepairsTable(
        rows: [],
        columns: [RepairCol.code],
        emptyState: Text('NOTHING'),
      )));
      expect(find.text('NOTHING'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('paginates 25 rows per page', (tester) async {
      await _surface(tester, const Size(1500, 2500));
      final rows = [
        for (var i = 0; i < 40; i++)
          _row('$i', RepairItemStatus.reported, code: 'C${i.toString().padLeft(2, '0')}', dayOffset: 40 - i),
      ];
      await tester.pumpWidget(host(RepairsTable(
        rows: rows,
        columns: const [RepairCol.code, RepairCol.status],
      )));
      // Newest first: C00 (day 40) .. C24 on page 1.
      expect(find.text('1–25 of 40'), findsOneWidget);
      expect(find.text('C00'), findsOneWidget);
      expect(find.text('C24'), findsOneWidget);
      expect(find.text('C25'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('dtv-next')));
      await tester.pump();
      expect(find.text('26–40 of 40'), findsOneWidget);
      expect(find.text('C39'), findsOneWidget);
      expect(find.text('C00'), findsNothing);
    });
  });

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}w';

    testWidgets('RepairsToDoScreen: filter chips + search by code ($label)', (tester) async {
      await _surface(tester, size);
      final db = await _fixture();
      await _addRepair(db, 'a', code: 'NOD/ENG/260001', vehicle: 'WP-1111', status: RepairItemStatus.listed, day: 1);
      await _addRepair(db, 'b', code: 'NOD/BRK/260002', vehicle: 'WP-2222', status: RepairItemStatus.inProgress, day: 2);
      await _addRepair(db, 'c', code: 'NOD/TYR/260003', vehicle: 'WP-3333', status: RepairItemStatus.returned, day: 3);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairsToDoScreen(firestoreOverride: db, currentUidOverride: 'uidTechnical'),
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      for (final c in ['NOD/ENG/260001', 'NOD/BRK/260002', 'NOD/TYR/260003']) {
        expect(find.text(c), findsOneWidget);
      }
      // Pending (LISTED) before in progress (IN_PROGRESS / RETURNED); newest first inside.
      expect(_y(tester, 'NOD/ENG/260001') < _y(tester, 'NOD/TYR/260003'), isTrue);
      expect(_y(tester, 'NOD/TYR/260003') < _y(tester, 'NOD/BRK/260002'), isTrue);

      await tester.tap(find.byKey(const ValueKey('dtv-filter-PENDING')));
      await _settle(tester);
      expect(find.text('NOD/ENG/260001'), findsOneWidget);
      expect(find.text('NOD/BRK/260002'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('dtv-filter-IN_PROGRESS')));
      await _settle(tester);
      expect(find.text('NOD/BRK/260002'), findsOneWidget);
      expect(find.text('NOD/TYR/260003'), findsOneWidget);
      expect(find.text('NOD/ENG/260001'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('dtv-filter-ALL')));
      await tester.enterText(find.byType(TextField), 'tyr');
      await _settle(tester);
      expect(find.text('NOD/TYR/260003'), findsOneWidget);
      expect(find.text('NOD/ENG/260001'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzz');
      await _settle(tester);
      expect(find.text('NO REPAIRS MATCH THIS FILTER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('RepairHistoryScreen: one vehicle, status chips, search by vehicle via prefill ($label)',
        (tester) async {
      await _surface(tester, size);
      final db = await _fixture();
      await _addRepair(db, 'h1', code: 'NOD/ENG/260011', vehicle: 'WP-9999', status: RepairItemStatus.completed, day: 5);
      await _addRepair(db, 'h2', code: 'NOD/ENG/260012', vehicle: 'WP-9999', status: RepairItemStatus.donePendingApproval, day: 1);
      await _addRepair(db, 'h3', code: 'NOD/ENG/260013', vehicle: 'WP-9999', status: RepairItemStatus.reported, day: 3);
      await _addRepair(db, 'other', code: 'NOD/ENG/269999', vehicle: 'WP-0000', status: RepairItemStatus.completed, day: 1);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairHistoryScreen(
          prefillVehicleNumber: 'WP-9999',
          firestoreOverride: db,
          currentUidOverride: 'uidManagement',
        ),
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('NOD/ENG/269999'), findsNothing); // other vehicle
      // Awaiting approval, then pending, then completed.
      expect(_y(tester, 'NOD/ENG/260012') < _y(tester, 'NOD/ENG/260013'), isTrue);
      expect(_y(tester, 'NOD/ENG/260013') < _y(tester, 'NOD/ENG/260011'), isTrue);

      await tester.tap(find.byKey(const ValueKey('dtv-filter-COMPLETED')));
      await _settle(tester);
      expect(find.text('NOD/ENG/260011'), findsOneWidget);
      expect(find.text('NOD/ENG/260012'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('dtv-filter-REJECTED')));
      await _settle(tester);
      expect(find.text('NO REPAIRS MATCH THIS FILTER'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('NewRepairsInboxScreen: per-repair rows with the vehicle queue count ($label)',
        (tester) async {
      await _surface(tester, size);
      final db = await _fixture();
      await _addRepair(db, 'n1', code: 'NOD/ENG/260021', vehicle: 'WP-5555', status: RepairItemStatus.reported, day: 1);
      await _addRepair(db, 'n2', code: 'NOD/BRK/260022', vehicle: 'WP-5555', status: RepairItemStatus.reported, day: 2);
      await _addRepair(db, 'n3', code: 'NOD/TYR/260023', vehicle: 'WP-6666', status: RepairItemStatus.reported, day: 3);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: NewRepairsInboxScreen(firestoreOverride: db, currentUidOverride: 'uidManagement'),
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('2 NEW'), findsNWidgets(2));
      expect(find.text('1 NEW'), findsOneWidget);
      // Newest first.
      expect(_y(tester, 'NOD/TYR/260023') < _y(tester, 'NOD/BRK/260022'), isTrue);
      expect(_y(tester, 'NOD/BRK/260022') < _y(tester, 'NOD/ENG/260021'), isTrue);

      await tester.enterText(find.byType(TextField), 'WP-6666');
      await _settle(tester);
      expect(find.text('NOD/TYR/260023'), findsOneWidget);
      expect(find.text('NOD/ENG/260021'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
