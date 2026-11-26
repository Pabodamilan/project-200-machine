// Technical home Service card: Company (default) / Private / Not set / All
// filter from trucks/{id}.isCompanyTruck (missing field = NOT SET, never
// Company), counts on
// the chips + header + VIEW ALL + Service Overview all follow the filter,
// filter is not persisted, and the home layout keeps every tile visible
// (phone: tiles first, Service card after; wide: two columns).
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

// 6 company trucks (isCompanyTruck:true) + 3 with NO field (NOT SET).
const _companyExplicit = ['CO-01', 'CO-02', 'CO-03', 'CO-04', 'CO-05', 'CO-06'];
const _companyNoField = ['OLD-01', 'OLD-02', 'OLD-03'];
const _company = _companyExplicit;
const _notSet = _companyNoField;
// 3 private (hired/external): isCompanyTruck:false.
const _private = ['PV-01', 'PV-02', 'PV-03'];
// Overdue ones (one company, one private, one company with no field).
const _overdue = {'CO-06', 'PV-03', 'OLD-03'};

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
  Future<void> truck(String n, bool? isCompany) async {
    await db.collection('trucks').doc(n).set({
      'truckNumber': n,
      'isCompanyTruck': ?isCompany,
    });
    await db.collection('service_records').doc('km-$n').set({
      'vehicleNumber': n,
      'status': 'APPROVED',
      'currentKm': _overdue.contains(n) ? 46000 : 1000,
      'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
    });
  }

  for (final n in _companyExplicit) {
    await truck(n, true);
  }
  for (final n in _companyNoField) {
    await truck(n, null);
  }
  for (final n in _private) {
    await truck(n, false);
  }
  await db.collection('users').doc('uidTech').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'canAccessGarage': true,
    'canAccessWarehouse': true,
    'repairPermissions': technicalDefaults().repairPermissions,
  });
  return db;
}

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

  void surface(WidgetTester tester, Size size) {
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

  void expectRows(List<String> shown, List<String> hidden) {
    for (final n in shown) {
      expect(row(n), findsOneWidget, reason: '$n should be listed');
    }
    for (final n in hidden) {
      expect(row(n), findsNothing, reason: '$n should be hidden');
    }
  }

  Future<void> tapFilter(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('technical-service-filter-$name')));
    await settle(tester, 10);
  }

  // The list defaults to "Needs service"; these ownership tests look at
  // every truck in the filter, so they switch the status filter to All.
  Future<void> tapStatus(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('technical-service-status-$name')));
    await settle(tester, 10);
  }

  test('truckOwnership: true company, false private, missing not set', () {
    expect(truckOwnership({'isCompanyTruck': true}), TruckOwnership.company);
    expect(truckOwnership({'isCompanyTruck': false}), TruckOwnership.private);
    expect(truckOwnership({'truckNumber': 'X'}), TruckOwnership.notSet);
    expect(truckOwnership({'isCompanyTruck': null}), TruckOwnership.notSet);
    expect(truckOwnership(null), TruckOwnership.notSet);
  });

  testWidgets('Company (default) 6 / Private 3 / Not set 3 / All 12 — chips, header and '
      'VIEW ALL counts match', (tester) async {
    surface(tester, const Size(1400, 4000));
    await pumpCard(tester, await _fleet());
    await tapStatus(tester, 'all');

    final company = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('technical-service-filter-company')),
    );
    expect(company.selected, isTrue);
    expect(find.text('Company (6)'), findsOneWidget);
    expect(find.text('Private (3)'), findsOneWidget);
    expect(find.text('Not set (3)'), findsOneWidget);
    expect(find.text('All (12)'), findsWidgets); // ownership All + status All

    expectRows(_company, [..._private, ..._notSet]);
    expect(find.text('SERVICE (6)'), findsOneWidget);
    expect(find.text('VIEW ALL (6 TRUCKS)'), findsOneWidget);
    // Overdue still sorted on top within the filter.
    expect(
      tester.getTopLeft(row('CO-06')).dy,
      lessThan(tester.getTopLeft(row('CO-01')).dy),
    );

    await tapFilter(tester, 'notSet');
    expectRows(_notSet, [..._company, ..._private]);
    expect(find.text('SERVICE (3)'), findsOneWidget);

    await tapFilter(tester, 'private');
    expectRows(_private, [..._company, ..._notSet]);
    expect(find.text('SERVICE (3)'), findsOneWidget);
    expect(find.text('VIEW ALL (3 TRUCKS)'), findsOneWidget);
    expect(
      tester.getTopLeft(row('PV-03')).dy,
      lessThan(tester.getTopLeft(row('PV-01')).dy),
    );

    await tapFilter(tester, 'all');
    expectRows([..._company, ..._private, ..._notSet], []);
    expect(find.text('SERVICE (12)'), findsOneWidget);
    expect(find.text('VIEW ALL (12 TRUCKS)'), findsOneWidget);
  });

  testWidgets('summary counts follow the filter', (tester) async {
    surface(tester, const Size(1400, 4000));
    await pumpCard(tester, await _fleet());

    Finder inSummary(String filter, String text) => find.descendant(
          of: find.byKey(ValueKey('technical-service-summary-$filter')),
          matching: find.text(text),
        );
    // Company: 1 overdue (CO-06), 5 serviced.
    expect(inSummary('company', '1'), findsOneWidget);
    expect(inSummary('company', '5'), findsOneWidget);

    await tapFilter(tester, 'private');
    // Private: 1 overdue (PV-03), 2 serviced.
    expect(inSummary('private', '1'), findsOneWidget);
    expect(inSummary('private', '2'), findsOneWidget);
  });

  testWidgets('VIEW ALL opens Service Overview with the same trucks', (
    tester,
  ) async {
    surface(tester, const Size(1400, 4000));
    await pumpCard(tester, await _fleet());
    await tapFilter(tester, 'private');
    await tester.tap(find.byKey(const ValueKey('technical-service-view-all')));
    await settle(tester, 40);
    expect(tester.takeException(), isNull);

    final overview = tester.widget<ServiceOverviewScreen>(
      find.byType(ServiceOverviewScreen),
    );
    expect(overview.vehicleScope?.vehicleNumbers, _private.toSet());
    expect(find.text('Showing: Private trucks (3)'), findsOneWidget);
    for (final n in _private) {
      expect(find.text(n), findsWidgets, reason: n);
    }
    for (final n in [..._company, ..._notSet]) {
      expect(find.text(n), findsNothing, reason: n);
    }
  });

  testWidgets('VIEW ALL with All passes no scope (overview unchanged)', (
    tester,
  ) async {
    surface(tester, const Size(1400, 4000));
    await pumpCard(tester, await _fleet());
    await tapFilter(tester, 'all');
    await tester.tap(find.byKey(const ValueKey('technical-service-view-all')));
    await settle(tester, 40);
    final overview = tester.widget<ServiceOverviewScreen>(
      find.byType(ServiceOverviewScreen),
    );
    expect(overview.vehicleScope, isNull);
    expect(find.byKey(const ValueKey('service-overview-scope')), findsNothing);
  });

  testWidgets('filter is not persisted: a fresh card starts on Company', (
    tester,
  ) async {
    surface(tester, const Size(1400, 4000));
    final db = await _fleet();
    await pumpCard(tester, db);
    await tapFilter(tester, 'private');
    expect(find.text('SERVICE (3)'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await pumpCard(tester, db);
    expect(find.text('SERVICE (6)'), findsOneWidget);
  });

  testWidgets('header collapses / expands the list', (tester) async {
    surface(tester, const Size(1400, 4000));
    await pumpCard(tester, await _fleet());
    expect(row('CO-06'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('technical-service-toggle')));
    await settle(tester, 3);
    expect(find.text('SERVICE (6)'), findsOneWidget);
    expect(row('CO-06'), findsNothing);
    expect(find.byKey(const ValueKey('technical-service-filter-company')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('technical-service-toggle')));
    await settle(tester, 3);
    expect(row('CO-06'), findsOneWidget);
  });

  const tileTitles = ['Vehicle Maintenance', 'Repairs To Do', 'Daily Checks', 'Warehouse'];

  Future<void> pumpHome(WidgetTester tester, FakeFirebaseFirestore db) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: TechnicalHomeScreen(
        name: 'Tina Technical',
        firestoreOverride: db,
        currentUidOverride: 'uidTech',
      ),
    ));
    await settle(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets('phone 360x640: every home tile on screen, Service card after '
      'them, no overflow', (tester) async {
    surface(tester, const Size(360, 640));
    await pumpHome(tester, await _fleet());

    final cardTop = tester
        .getTopLeft(find.byKey(const ValueKey('technical-home-service-card')))
        .dy;
    for (final t in tileTitles) {
      final f = find.text(t);
      expect(f, findsOneWidget, reason: t);
      expect(tester.getRect(f).top, lessThan(cardTop), reason: '$t above the Service card');
    }
    // The first tiles are on screen without scrolling; the Service card
    // (not the tiles) is what sits below the fold.
    for (final t in tileTitles.take(3)) {
      expect(tester.getRect(find.text(t)).bottom, lessThanOrEqualTo(640), reason: t);
    }
    expect(cardTop, greaterThan(tester.getRect(find.text('Warehouse')).bottom));
    // Every tile is reachable by scrolling the home page.
    await tester.ensureVisible(find.text('Warehouse'));
    await tester.pump();
    final wh = tester.getRect(find.text('Warehouse'));
    expect(wh.bottom, lessThanOrEqualTo(640));
    expect(wh.top, greaterThanOrEqualTo(0));
    // The card's list scrolls inside its phone cap.
    expect(
      tester.getSize(find.byKey(const ValueKey('technical-service-list'))).height,
      lessThanOrEqualTo(kTechnicalHomeServiceListMaxHeightPhone),
    );
  });

  testWidgets('wide 1400x900: tiles and Service card side by side', (
    tester,
  ) async {
    surface(tester, const Size(1400, 900));
    await pumpHome(tester, await _fleet());

    final tiles = tester.getRect(find.byKey(const ValueKey('technical-home-tiles')));
    final card = tester.getRect(find.byKey(const ValueKey('technical-home-service-card')));
    expect(card.left, greaterThanOrEqualTo(tiles.right));
    expect((card.top - tiles.top).abs(), lessThan(1));
    for (final t in tileTitles) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
  });
}
