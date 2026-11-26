// (1) One ownership definition (truckOwnership): true = Company, false =
//     Private, missing = Not set — Technical card chips Company | Private
//     | Not set | All, not-set trucks never in the Company list; admin-only
//     Truck Ownership screen (toggle / filter / bulk, saves only
//     isCompanyTruck); Add Truck needs an explicit Company / Private.
// (2) "Submitted" mark: snackbar after submit, ServiceSubmittedBadge on
//     Awaiting approval rows (date + name), "Submitted: <schedule>" on a
//     partially-submitted Needs service row, gone once approved; Service
//     Overview rows carry the same badge.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

const _company = ['C-1', 'C-2', 'C-3', 'C-4', 'C-5'];
const _private = ['P-1', 'P-2', 'P-3'];
const _notSet = ['N-1', 'N-2', 'N-3', 'N-4'];

Future<void> _baseSettings(FakeFirebaseFirestore db) async {
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
  await db.collection('users').doc('uidTech').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'canAccessGarage': true,
    'canAccessWarehouse': true,
    'repairPermissions': technicalDefaults().repairPermissions,
  });
  await db.collection('users').doc('uidAdmin').set({'name': 'Admin', 'role': 'admin'});
}

Future<void> _km(FakeFirebaseFirestore db, String n, double km) =>
    db.collection('service_records').doc('km-$n').set({
      'vehicleNumber': n,
      'status': 'APPROVED',
      'currentKm': km,
      'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
    });

Future<void> _submitted(
  FakeFirebaseFirestore db,
  String id,
  String n, {
  required String scheduleId,
  required String scheduleName,
  required DateTime at,
  double km = 46000,
}) =>
    db.collection('service_records').doc(id).set({
      'vehicleNumber': n,
      'status': 'SUBMITTED',
      'scheduleId': scheduleId,
      'scheduleName': scheduleName,
      'milestoneKm': 45000,
      'currentKm': km,
      'doneKm': km,
      'serviceDate': Timestamp.fromDate(at),
      'submittedAt': Timestamp.fromDate(at),
      'submittedBy': 'uidTech',
      'submittedByName': 'Tina Technical',
    });

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

  void surface(WidgetTester tester, [Size size = const Size(1400, 4000)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpCard(WidgetTester tester, FakeFirebaseFirestore db) async {
    await tester.pumpWidget(MaterialApp(
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
    ));
    await settle(tester);
    expect(tester.takeException(), isNull);
  }

  Finder row(String n) => find.byKey(ValueKey('technical-service-row-$n'));

  Future<void> tapKey(WidgetTester tester, String key, [int n = 10]) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester, n);
  }

  group('ownership definition', () {
    test('truckOwnership: true -> Company, false -> Private, missing -> Not set', () {
      expect(truckOwnership({'isCompanyTruck': true}), TruckOwnership.company);
      expect(truckOwnership({'isCompanyTruck': false}), TruckOwnership.private);
      expect(truckOwnership({'truckNumber': 'X'}), TruckOwnership.notSet);
      expect(truckOwnership({'isCompanyTruck': 'yes'}), TruckOwnership.notSet);
      expect(truckOwnership(null), TruckOwnership.notSet);
      expect(truckOwnershipChoiceValue({'truckNumber': 'X'}), isNull);
    });

    testWidgets('Technical card: Company (5) / Private (3) / Not set (4) / '
        'All (12); not-set trucks never in Company', (tester) async {
      surface(tester);
      final db = FakeFirebaseFirestore();
      await _baseSettings(db);
      Future<void> truck(String n, bool? c) async {
        await db.collection('trucks').doc(n).set({'truckNumber': n, 'isCompanyTruck': ?c});
        await _km(db, n, 1000);
      }

      for (final n in _company) {
        await truck(n, true);
      }
      for (final n in _private) {
        await truck(n, false);
      }
      for (final n in _notSet) {
        await truck(n, null);
      }
      await pumpCard(tester, db);
      await tapKey(tester, 'technical-service-status-all');

      expect(find.text('Company (5)'), findsOneWidget);
      expect(find.text('Private (3)'), findsOneWidget);
      expect(find.text('Not set (4)'), findsOneWidget);
      expect(find.text('All (12)'), findsOneWidget); // ownership All
      expect(find.text('SERVICE (5)'), findsOneWidget);
      for (final n in _company) {
        expect(row(n), findsOneWidget, reason: n);
      }
      for (final n in [..._notSet, ..._private]) {
        expect(row(n), findsNothing, reason: '$n must not be in Company');
      }

      await tapKey(tester, 'technical-service-filter-notSet');
      expect(find.text('SERVICE (4)'), findsOneWidget);
      for (final n in _notSet) {
        expect(row(n), findsOneWidget, reason: n);
      }
      for (final n in [..._company, ..._private]) {
        expect(row(n), findsNothing, reason: n);
      }
    });
  });

  group('Truck Ownership screen', () {
    Future<FakeFirebaseFirestore> fleet() async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc('uidAdmin').set({'role': 'admin'});
      await db.collection('users').doc('uidOwner').set({'role': 'owner'});
      await db.collection('users').doc('uidTech').set({
        'role': 'technical',
        'canAccessGarage': true,
      });
      await db.collection('trucks').doc('t1').set({'truckNumber': 'AA-1', 'isCompanyTruck': true});
      await db.collection('trucks').doc('t2').set({'truckNumber': 'AB-2', 'isCompanyTruck': false});
      await db.collection('trucks').doc('t3').set({'truckNumber': 'ZZ-3'});
      await db.collection('trucks').doc('t4').set({
        'truckNumber': 'ZZ-4',
        'gpsDeviceId': 'GPS-4',
        'assignedDriverName': 'Dan',
      });
      return db;
    }

    Future<void> pump(WidgetTester tester, FakeFirebaseFirestore db, String uid) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: TruckOwnershipScreen(
          key: ValueKey(uid),
          firestoreOverride: db,
          currentUidOverride: uid,
        ),
      ));
      await settle(tester, 10);
      expect(tester.takeException(), isNull);
    }

    Future<Map<String, dynamic>> doc(FakeFirebaseFirestore db, String id) async =>
        (await db.collection('trucks').doc(id).get()).data()!;

    testWidgets('admin: counts, Not set first, filter, one-tap save touches '
        'only isCompanyTruck, bulk set', (tester) async {
      surface(tester, const Size(1200, 1600));
      final db = await fleet();
      await pump(tester, db, 'uidAdmin');

      expect(find.text('Company 1 · Private 1 · Not set 2'), findsOneWidget);
      // Not set (ZZ-*) rows sort above the rest despite their numbers.
      final y3 = tester.getTopLeft(find.byKey(const ValueKey('truck-ownership-row-t3'))).dy;
      final y1 = tester.getTopLeft(find.byKey(const ValueKey('truck-ownership-row-t1'))).dy;
      expect(y3, lessThan(y1));

      await tapKey(tester, 'truck-ownership-filter-notSet');
      expect(find.byKey(const ValueKey('truck-ownership-row-t3')), findsOneWidget);
      expect(find.byKey(const ValueKey('truck-ownership-row-t4')), findsOneWidget);
      expect(find.byKey(const ValueKey('truck-ownership-row-t1')), findsNothing);
      expect(find.byKey(const ValueKey('truck-ownership-row-t2')), findsNothing);

      // One tap -> saved.
      await tapKey(tester, 'truck-ownership-t3-company');
      expect((await doc(db, 't3'))['isCompanyTruck'], isTrue);
      expect(find.byKey(const ValueKey('truck-ownership-row-t3')), findsNothing); // left Not set

      // Bulk: select t4 -> Set Private; other fields untouched.
      await tapKey(tester, 'truck-ownership-select-t4');
      await tapKey(tester, 'truck-ownership-bulk-private');
      final t4 = await doc(db, 't4');
      expect(t4['isCompanyTruck'], isFalse);
      expect(t4['gpsDeviceId'], 'GPS-4');
      expect(t4['assignedDriverName'], 'Dan');
      expect(t4['truckNumber'], 'ZZ-4');

      await tapKey(tester, 'truck-ownership-filter-all');
      expect(find.text('Company 2 · Private 2 · Not set 0'), findsOneWidget);

      // Search.
      await tester.enterText(find.byKey(const ValueKey('truck-ownership-search')), 'AB');
      await settle(tester, 5);
      expect(find.byKey(const ValueKey('truck-ownership-row-t2')), findsOneWidget);
      expect(find.byKey(const ValueKey('truck-ownership-row-t1')), findsNothing);
    });

    testWidgets('admin / owner only', (tester) async {
      surface(tester, const Size(1200, 1600));
      final db = await fleet();
      await pump(tester, db, 'uidTech');
      expect(find.byKey(const ValueKey('truck-ownership-no-access')), findsOneWidget);
      expect(find.byKey(const ValueKey('truck-ownership-row-t1')), findsNothing);

      await pump(tester, db, 'uidOwner');
      expect(find.byKey(const ValueKey('truck-ownership-no-access')), findsNothing);
      expect(find.byKey(const ValueKey('truck-ownership-row-t1')), findsOneWidget);
    });
  });

  testWidgets('Add Truck: not saved until Company / Private is chosen', (tester) async {
    surface(tester, const Size(1200, 2400));
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: TruckManagementScreen(firestoreOverride: db),
    ));
    await settle(tester, 5);
    expect(tester.takeException(), isNull);
    expect(find.text('Is Company Truck?'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, 'Truck Number / Plate'),
      'NEW-1',
    );
    await tester.tap(find.text('ADD TRUCK'));
    await settle(tester, 5);
    expect(find.text('Please choose Company or Private.'), findsOneWidget);
    expect((await db.collection('trucks').get()).docs, isEmpty);

    await tester.tap(find.byKey(const ValueKey('add-truck-ownership-private')));
    await settle(tester, 2);
    await tester.tap(find.text('ADD TRUCK'));
    await settle(tester, 10);
    final docs = (await db.collection('trucks').get()).docs;
    expect(docs, hasLength(1));
    expect(docs.single.data()['truckNumber'], 'NEW-1');
    expect(docs.single.data()['isCompanyTruck'], isFalse);
  });

  group('Submitted mark', () {
    test('badge / snackbar text', () {
      final at = DateTime(2026, 11, 26, 11, 40);
      expect(formatSubmittedAt(at), '26 Nov 11:40');
      expect(
        serviceSubmittedBadgeText(submittedAt: at, submittedByName: 'Tina'),
        'Submitted 26 Nov 11:40 · Tina',
      );
      expect(serviceSubmittedBadgeText(), 'Submitted');
      expect(
        serviceSubmittedBadgeText(scheduleName: '45,000 km Service'),
        'Submitted: 45,000 km Service',
      );
      expect(
        serviceSubmittedSnackText(vehicleNumber: 'WP-1', scheduleName: '45,000 km Service'),
        'Service submitted - awaiting approval: WP-1 · 45,000 km Service',
      );
    });

    testWidgets('snackbar after submit shows truck + schedule', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showServiceSubmittedSnackBar(
                ScaffoldMessenger.of(ctx),
                serviceSubmittedSnackText(
                  vehicleNumber: 'WP-1',
                  scheduleName: '45,000 km Service',
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const ValueKey('service-submitted-snackbar')), findsOneWidget);
      expect(
        find.text('Service submitted - awaiting approval: WP-1 · 45,000 km Service'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    // T-FULL: its only due service is submitted -> Awaiting approval with
    // the full badge. T-PART: 45,000 km submitted but its Brake Check is
    // still due soon -> stays in Needs service with "Submitted: 45,000 km
    // Service" next to the due chip.
    Future<FakeFirebaseFirestore> fleet() async {
      final db = FakeFirebaseFirestore();
      await _baseSettings(db);
      await db.collection('service_items').doc('sched2').set({
        'name': 'Brake Check',
        'intervalKm': 50000,
        'intervalDays': null,
        'warnBeforeKm': 1000,
        'appliesTo': 'SELECTED',
        'vehicleNumbers': ['T-PART'],
        'active': true,
        'sortOrder': 2,
      });
      for (final n in ['T-FULL', 'T-PART']) {
        await db.collection('trucks').doc(n).set({'truckNumber': n, 'isCompanyTruck': true});
      }
      await _km(db, 'T-FULL', 46000);
      await _km(db, 'T-PART', 49500);
      await _submitted(db, 'sub-full', 'T-FULL',
          scheduleId: 'sched1',
          scheduleName: '45,000 km Service',
          at: DateTime(2026, 11, 26, 11, 40));
      await _submitted(db, 'sub-part', 'T-PART',
          scheduleId: 'sched1',
          scheduleName: '45,000 km Service',
          at: DateTime(2026, 11, 25, 9, 5),
          km: 49500);
      return db;
    }

    testWidgets('Awaiting approval row: Submitted badge with date + name; '
        'partial: Needs service row keeps its due chip + "Submitted: <schedule>"; '
        'approved -> badge gone, Up to date', (tester) async {
      surface(tester);
      final db = await fleet();
      await pumpCard(tester, db);

      // Needs service (default): T-PART only, due chip + small badge.
      expect(row('T-PART'), findsOneWidget);
      expect(row('T-FULL'), findsNothing);
      expect(
        find.descendant(of: row('T-PART'), matching: find.text('DUE IN 500 km')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: row('T-PART'),
          matching: find.text('Submitted: 45,000 km Service'),
        ),
        findsOneWidget,
      );

      await tapKey(tester, 'technical-service-status-awaitingApproval');
      expect(row('T-FULL'), findsOneWidget);
      final badge = find.byKey(const ValueKey('technical-service-submitted-T-FULL'));
      expect(badge, findsOneWidget);
      expect(
        find.descendant(of: badge, matching: find.text('Submitted 26 Nov 11:40 · Tina Technical')),
        findsOneWidget,
      );
      expect(find.descendant(of: badge, matching: find.byIcon(Icons.check_circle)), findsOneWidget);

      // Approved -> no badge anywhere, T-FULL up to date.
      await db.collection('service_records').doc('sub-full').update({'status': 'APPROVED'});
      ServiceAlertsCache.reset();
      await pumpCard(tester, db);
      await tapKey(tester, 'technical-service-status-upToDate');
      expect(row('T-FULL'), findsOneWidget);
      expect(find.byKey(const ValueKey('technical-service-submitted-T-FULL')), findsNothing);
      expect(find.textContaining('Submitted 26 Nov'), findsNothing);
    });

    testWidgets('Service Overview: awaiting-approval row has the Submitted tag, '
        'status chips unchanged', (tester) async {
      surface(tester);
      final db = await fleet();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceOverviewScreen(firestoreOverride: db, currentUidOverride: 'uidTech'),
      ));
      await settle(tester, 40);
      expect(tester.takeException(), isNull);
      expect(find.byType(ServiceSubmittedBadge), findsWidgets);
      expect(
        find.byKey(const ValueKey('service-overview-submitted-T-FULL-45,000 km Service')),
        findsOneWidget,
      );
      // Existing provisional chip still there.
      expect(find.text('AWAITING APPROVAL'), findsWidgets);
    });
  });
}
