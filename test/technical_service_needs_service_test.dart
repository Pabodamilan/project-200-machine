// Technical home Service list shows "Needs service" by default:
// - up-to-date trucks (incl. just-serviced ones) are hidden until the next
//   km/date milestone makes them due soon / overdue again,
// - a submitted service moves the truck to "Awaiting approval" at once
//   (the card re-reads when coming back from the service form),
// - status chips (Needs service | Awaiting approval | Up to date | All)
//   with counts; header, summary counts and VIEW ALL still cover every
//   truck of the ownership filter.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

Future<void> _kmRecord(
  FakeFirebaseFirestore db,
  String id,
  String n,
  double km,
  DateTime at,
) => db.collection('service_records').doc(id).set({
  'vehicleNumber': n,
  'status': 'APPROVED',
  'currentKm': km,
  'serviceDate': Timestamp.fromDate(at),
});

// T-OK up to date, T-SOON due soon, T-OVER overdue, T-UNK km unknown,
// T-AWAIT overdue km but its 45,000 km service is SUBMITTED.
Future<FakeFirebaseFirestore> _fleet() async {
  final db = FakeFirebaseFirestore();
  await db.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
  });
  await db.collection('service_items').doc('sched1').set({
    'name': '45,000 km Service',
    'intervalKm': 45000,
    'intervalDays': null,
    'warnBeforeKm': 1000,
    'appliesTo': 'ALL',
    'vehicleNumbers': <String>[],
    'active': true,
    'sortOrder': 1,
  });
  final jan = DateTime(2026, 1, 1);
  for (final n in ['T-OK', 'T-SOON', 'T-OVER', 'T-UNK', 'T-AWAIT']) {
    await db.collection('trucks').doc(n).set({'truckNumber': n, 'isCompanyTruck': true});
  }
  await _kmRecord(db, 'km-ok', 'T-OK', 1000, jan);
  await _kmRecord(db, 'km-soon', 'T-SOON', 44500, jan);
  await _kmRecord(db, 'km-over', 'T-OVER', 46000, jan);
  await _kmRecord(db, 'km-await', 'T-AWAIT', 46000, jan);
  await db.collection('service_records').doc('sub-await').set({
    'vehicleNumber': 'T-AWAIT',
    'status': 'SUBMITTED',
    'scheduleId': 'sched1',
    'milestoneKm': 45000,
    'currentKm': 46000,
    'doneKm': 46000,
    'serviceDate': Timestamp.fromDate(DateTime(2026, 2, 1)),
    'submittedAt': Timestamp.fromDate(DateTime(2026, 2, 1)),
    'submittedBy': 'uidTech',
    'submittedByName': 'Tina Technical',
  });
  await db.collection('users').doc('uidTech').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'canAccessGarage': true,
    'canAccessWarehouse': true,
    'repairPermissions': technicalDefaults().repairPermissions,
  });
  return db;
}

ServiceAlert _due(String v, String sev, {String? scheduleId = 'sched1'}) =>
    ServiceAlert(
      kind: ServiceAlertKind.serviceDue,
      severity: sev,
      audience: ServiceAlertAudience.both,
      vehicleNumber: v,
      title: 's',
      detail: '',
      scheduleId: scheduleId,
    );

ServiceAlert _awaiting(String v, {String? scheduleId}) => ServiceAlert(
  kind: ServiceAlertKind.serviceAwaitingApproval,
  severity: ServiceAlertSeverity.info,
  audience: ServiceAlertAudience.mechanic,
  vehicleNumber: v,
  title: 'Awaiting Approval',
  detail: '',
  scheduleId: scheduleId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(() {
    ServiceAlertsCache.reset();
    VehicleKmCache.reset();
    UserDirectory.reset();
    ReferenceCollectionCache.reset();
  });

  Future<void> settle(WidgetTester tester, [int n = 30]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  void surface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpCard(WidgetTester tester, FakeFirebaseFirestore db) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TechnicalHomeServiceCard(
              key: UniqueKey(),
              name: 'Tina Technical',
              firestoreOverride: db,
              currentUidOverride: 'uidTech',
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(tester.takeException(), isNull);
  }

  Finder row(String n) => find.byKey(ValueKey('technical-service-row-$n'));

  void expectRows(List<String> shown, List<String> hidden) {
    for (final n in shown) {
      expect(row(n), findsOneWidget, reason: '$n should be listed');
    }
    for (final n in hidden) {
      expect(row(n), findsNothing, reason: '$n should be hidden');
    }
  }

  Future<void> tapStatus(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('technical-service-status-$name')));
    await settle(tester, 10);
  }

  group('buildTechnicalServiceRows + status buckets', () {
    TechnicalServiceStatusFilter statusOf(
      List<TechnicalServiceRow> rows,
      String v,
    ) => technicalServiceRowStatus(
      rows.firstWhere((r) => r.vehicleNumber == v).alert,
    );

    test('submission without a schedule covers km/date dues, not KM UNKNOWN '
        'and not another schedule', () {
      final rows = buildTechnicalServiceRows(
        truckNumbers: ['A', 'B', 'C', 'D', 'E'],
        alerts: [
          // A: overdue, nothing submitted -> needs service.
          _due('A', ServiceAlertSeverity.overdue),
          // B: overdue, a no-schedule service submitted -> awaiting.
          _due('B', ServiceAlertSeverity.overdue),
          _awaiting('B'),
          // C: sched2 submitted but sched1 still overdue -> needs service.
          _due('C', ServiceAlertSeverity.overdue),
          _awaiting('C', scheduleId: 'sched2'),
          // D: km unknown is never covered by a submission.
          _due('D', ServiceAlertSeverity.kmUnknown, scheduleId: null),
          _awaiting('D'),
          // E: nothing due.
        ],
      );
      expect(statusOf(rows, 'A'), TechnicalServiceStatusFilter.needsService);
      expect(
        statusOf(rows, 'B'),
        TechnicalServiceStatusFilter.awaitingApproval,
      );
      expect(statusOf(rows, 'C'), TechnicalServiceStatusFilter.needsService);
      expect(statusOf(rows, 'D'), TechnicalServiceStatusFilter.needsService);
      expect(statusOf(rows, 'E'), TechnicalServiceStatusFilter.upToDate);
      // Worst first: needs service, then awaiting, then up to date.
      expect(rows.map((r) => r.vehicleNumber), ['A', 'C', 'D', 'B', 'E']);
    });

    test('matches: All takes every row', () {
      for (final a in [
        null,
        _awaiting('x'),
        _due('x', ServiceAlertSeverity.dueSoon),
      ]) {
        expect(
          technicalServiceRowMatchesStatus(a, TechnicalServiceStatusFilter.all),
          isTrue,
        );
      }
      expect(
        technicalServiceRowMatchesStatus(
          null,
          TechnicalServiceStatusFilter.needsService,
        ),
        isFalse,
      );
    });

    test('next due after a service: next 45,000 km milestone, and days', () {
      ServiceItemDue at(double km, {int? days, DateTime? done}) =>
          computeScheduleStatus(
            scheduleId: 'sched1',
            scheduleName: 's',
            intervalKm: 45000,
            intervalDays: days,
            warnBeforeKm: 1000,
            approvedRecords: [
              {
                'milestoneKm': 45000,
                'doneKm': 46000,
                'serviceDate': done ?? DateTime(2026, 6, 1),
              },
            ],
            currentKm: km,
            now: DateTime(2026, 11, 26),
          );
      expect(at(46000).status, ServiceItemDueStatus.ok);
      expect(at(46000).milestoneKm, 90000);
      expect(at(88999).status, ServiceItemDueStatus.ok);
      expect(at(89000).status, ServiceItemDueStatus.dueSoon); // 1,000 km before
      expect(at(90000).status, ServiceItemDueStatus.overdue);
      // Date interval: due again once intervalDays have passed since the
      // approved service date, even if km is still fine.
      expect(
        at(50000, days: 180, done: DateTime(2026, 6, 1)).status,
        ServiceItemDueStatus.ok,
      );
      expect(
        at(50000, days: 180, done: DateTime(2026, 5, 1)).status,
        ServiceItemDueStatus.overdue,
      );
    });
  });

  testWidgets('default "Needs service": overdue, km unknown, due soon on top; '
      'up to date and awaiting hidden; chips/counts; VIEW ALL covers all', (
    tester,
  ) async {
    surface(tester);
    await pumpCard(tester, await _fleet());

    final needs = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('technical-service-status-needsService')),
    );
    expect(needs.selected, isTrue);
    expect(find.text('Needs service (3)'), findsOneWidget);
    expect(find.text('Awaiting approval (1)'), findsOneWidget);
    expect(find.text('Up to date (1)'), findsOneWidget);
    expect(find.text('All (5)'), findsWidgets); // status All (+ ownership All)

    expectRows(['T-OVER', 'T-UNK', 'T-SOON'], ['T-OK', 'T-AWAIT']);
    final ys = [
      for (final n in ['T-OVER', 'T-UNK', 'T-SOON'])
        tester.getTopLeft(row(n)).dy,
    ];
    expect(
      ys,
      orderedEquals([...ys]..sort()),
      reason: 'overdue -> km unknown -> due soon',
    );

    // Header + VIEW ALL still count every truck of the ownership filter.
    expect(find.text('SERVICE (5)'), findsOneWidget);
    expect(find.text('VIEW ALL (5 TRUCKS)'), findsOneWidget);
    expect(find.text('SERVICED'), findsOneWidget);

    await tapStatus(tester, 'upToDate');
    expectRows(['T-OK'], ['T-OVER', 'T-UNK', 'T-SOON', 'T-AWAIT']);
    expect(find.text('UP TO DATE'), findsOneWidget);

    await tapStatus(tester, 'awaitingApproval');
    expectRows(['T-AWAIT'], ['T-OVER', 'T-UNK', 'T-SOON', 'T-OK']);
    expect(find.text('AWAITING APPROVAL'), findsOneWidget);

    await tapStatus(tester, 'all');
    expectRows(['T-OVER', 'T-UNK', 'T-SOON', 'T-AWAIT', 'T-OK'], []);
    expect(find.text('SERVICE (5)'), findsOneWidget);

    // VIEW ALL -> Service Overview unchanged (every truck, incl. up to date).
    await tester.tap(find.byKey(const ValueKey('technical-service-view-all')));
    await settle(tester, 40);
    expect(tester.takeException(), isNull);
    expect(find.byType(ServiceOverviewScreen), findsOneWidget);
    for (final n in ['T-OK', 'T-SOON', 'T-OVER', 'T-UNK', 'T-AWAIT']) {
      expect(find.text(n), findsWidgets, reason: n);
    }
  });

  testWidgets('overdue -> submit -> leaves the list at once (awaiting) -> '
      'approved = up to date -> back when the next 90,000 km service is due', (
    tester,
  ) async {
    surface(tester);
    final db = await _fleet();
    await pumpCard(tester, db);
    expect(row('T-OVER'), findsOneWidget);

    // Tap the truck -> service form; the technician submits (same
    // SUBMITTED record ServiceRecordFormScreen writes), then comes back.
    await tester.tap(row('T-OVER'));
    await settle(tester, 15);
    expect(find.byType(ServiceRecordFormScreen), findsOneWidget);
    await db.collection('service_records').doc('sub-over').set({
      'vehicleNumber': 'T-OVER',
      'status': 'SUBMITTED',
      'scheduleId': 'sched1',
      'milestoneKm': 45000,
      'currentKm': 46000,
      'doneKm': 46000,
      'serviceDate': Timestamp.fromDate(DateTime(2026, 3, 1)),
      'submittedAt': Timestamp.fromDate(DateTime(2026, 3, 1)),
      'submittedBy': 'uidTech',
      'submittedByName': 'Tina Technical',
    });
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(row('T-OVER'), findsNothing, reason: 'left "Needs service" at once');
    expect(find.text('Needs service (2)'), findsOneWidget);
    expect(find.text('Awaiting approval (2)'), findsOneWidget);
    await tapStatus(tester, 'awaitingApproval');
    expect(row('T-OVER'), findsOneWidget);

    // Management approves -> up to date (next milestone 90,000 km).
    await db.collection('service_records').doc('sub-over').update({
      'status': 'APPROVED',
    });
    ServiceAlertsCache.reset();
    await pumpCard(tester, db);
    expect(row('T-OVER'), findsNothing);
    expect(find.text('Awaiting approval (1)'), findsOneWidget);
    await tapStatus(tester, 'upToDate');
    expect(row('T-OVER'), findsOneWidget);

    // Odometer reaches 89,500 km -> due soon (500 km before 90,000) -> back.
    await _kmRecord(db, 'km-over-2', 'T-OVER', 89500, DateTime(2026, 9, 1));
    ServiceAlertsCache.reset();
    VehicleKmCache.reset();
    await pumpCard(tester, db);
    expect(row('T-OVER'), findsOneWidget);
    expect(
      find.descendant(of: row('T-OVER'), matching: find.text('DUE IN 500 km')),
      findsOneWidget,
    );

    // Past 90,000 km -> overdue.
    await _kmRecord(db, 'km-over-3', 'T-OVER', 90400, DateTime(2026, 10, 1));
    ServiceAlertsCache.reset();
    VehicleKmCache.reset();
    await pumpCard(tester, db);
    expect(row('T-OVER'), findsOneWidget);
    expect(
      find.descendant(
        of: row('T-OVER'),
        matching: find.text('OVERDUE BY 400 km'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('status filter is not persisted: fresh card = Needs service', (
    tester,
  ) async {
    surface(tester);
    final db = await _fleet();
    await pumpCard(tester, db);
    await tapStatus(tester, 'upToDate');
    expect(row('T-OK'), findsOneWidget);
    await pumpCard(tester, db);
    expect(row('T-OK'), findsNothing);
    expect(row('T-OVER'), findsOneWidget);
  });
}
