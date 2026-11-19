// Tests for the reusable DataTableView (lib/widgets/data_table_view.dart)
// and the Service module tables built on it: sort order + header toggle,
// status filter chips, empty state, and 25-row pagination.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';
import 'package:project_200_machine/widgets/data_table_view.dart';

typedef _Row = ({String name, int n});

List<DataTableColumn<_Row>> _cols() => [
      DataTableColumn<_Row>(
        label: 'Name',
        width: 120,
        cellBuilder: (_, r) => Text(r.name),
        compare: (a, b) => a.name.compareTo(b.name),
      ),
      DataTableColumn<_Row>(
        label: 'Num',
        width: 100,
        numeric: true,
        cellBuilder: (_, r) => Text('n=${r.n}'),
        compare: (a, b) => a.n.compareTo(b.n),
      ),
    ];

Widget _host(Widget child, {double width = 800}) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SizedBox(width: width, height: 2000, child: child)),
    );

double _y(WidgetTester tester, String text) => tester.getTopLeft(find.text(text)).dy;

Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(() {
    ServiceAlertsCache.reset();
    VehicleKmCache.reset();
  });

  group('DataTableView', () {
    testWidgets('initialSortColumn sorts; tapping the header toggles direction', (tester) async {
      await _setSurface(tester, const Size(900, 2200));
      final rows = <_Row>[(name: 'b', n: 2), (name: 'c', n: 3), (name: 'a', n: 1)];
      await tester.pumpWidget(_host(DataTableView<_Row>(
        columns: _cols(),
        rows: rows,
        initialSortColumn: 1,
      )));
      expect(_y(tester, 'n=1') < _y(tester, 'n=2'), isTrue);
      expect(_y(tester, 'n=2') < _y(tester, 'n=3'), isTrue);

      // Same column again -> descending.
      await tester.tap(find.byKey(const ValueKey('dtv-header-1')));
      await tester.pump();
      expect(_y(tester, 'n=3') < _y(tester, 'n=2'), isTrue);
      expect(_y(tester, 'n=2') < _y(tester, 'n=1'), isTrue);

      // Different column -> ascending on that one.
      await tester.tap(find.byKey(const ValueKey('dtv-header-0')));
      await tester.pump();
      expect(_y(tester, 'a') < _y(tester, 'b'), isTrue);
      expect(_y(tester, 'b') < _y(tester, 'c'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no initialSortColumn keeps the caller order', (tester) async {
      await _setSurface(tester, const Size(900, 2200));
      final rows = <_Row>[(name: 'z', n: 9), (name: 'a', n: 1)];
      await tester.pumpWidget(_host(DataTableView<_Row>(columns: _cols(), rows: rows)));
      expect(_y(tester, 'z') < _y(tester, 'a'), isTrue);
    });

    testWidgets('empty rows show the empty state', (tester) async {
      await tester.pumpWidget(_host(DataTableView<_Row>(
        columns: _cols(),
        rows: const [],
        emptyState: const Text('NOTHING HERE'),
      )));
      expect(find.text('NOTHING HERE'), findsOneWidget);
      expect(find.byKey(const ValueKey('dtv-header-0')), findsNothing);
    });

    testWidgets('paginates 25 rows per page with prev/next', (tester) async {
      await _setSurface(tester, const Size(900, 2200));
      final rows = [for (var i = 0; i < 60; i++) (name: 'r${i.toString().padLeft(2, '0')}', n: i)];
      await tester.pumpWidget(_host(DataTableView<_Row>(
        columns: _cols(),
        rows: rows,
        initialSortColumn: 1,
      )));
      expect(find.text('1–25 of 60'), findsOneWidget);
      expect(find.text('n=0'), findsOneWidget);
      expect(find.text('n=24'), findsOneWidget);
      expect(find.text('n=25'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('dtv-next')));
      await tester.pump();
      expect(find.text('26–50 of 60'), findsOneWidget);
      expect(find.text('n=24'), findsNothing);
      expect(find.text('n=25'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dtv-next')));
      await tester.pump();
      expect(find.text('51–60 of 60'), findsOneWidget);
      expect(find.text('n=59'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dtv-prev')));
      await tester.pump();
      expect(find.text('26–50 of 60'), findsOneWidget);

      // Re-sorting returns to page 1.
      await tester.tap(find.byKey(const ValueKey('dtv-header-1')));
      await tester.pump();
      expect(find.text('1–25 of 60'), findsOneWidget);
      expect(find.text('n=59'), findsOneWidget);
    });

    testWidgets('narrow width: scrolls sideways without overflow, first column stays pinned',
        (tester) async {
      await _setSurface(tester, const Size(390, 844));
      final cols = [
        ..._cols(),
        for (var i = 0; i < 5; i++)
          DataTableColumn<_Row>(label: 'C$i', width: 150, cellBuilder: (_, r) => Text('c$i-${r.n}')),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: DataTableView<_Row>(columns: cols, rows: const [(name: 'a', n: 1)])),
      ));
      expect(tester.takeException(), isNull);
      final pinnedX = tester.getTopLeft(find.text('a')).dx;
      final c0Before = tester.getTopLeft(find.text('c0-1')).dx;
      await tester.drag(find.text('c0-1'), const Offset(-300, 0));
      await tester.pump();
      expect(tester.getTopLeft(find.text('a')).dx, pinnedX);
      expect(tester.getTopLeft(find.text('c0-1')).dx < c0Before, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('Service table: pure helpers', () {
    const rows = [
      ServiceTableRow(vehicleNumber: 'WP-0003', serviceType: 'Oil', status: ServiceItemDueStatus.ok),
      ServiceTableRow(vehicleNumber: 'WP-0002', serviceType: 'Oil', status: ServiceItemDueStatus.dueSoon),
      ServiceTableRow(vehicleNumber: 'WP-0004', serviceType: 'Oil', status: ServiceItemDueStatus.missed),
      ServiceTableRow(vehicleNumber: 'WP-0001', serviceType: 'Oil', status: ServiceItemDueStatus.overdue),
      ServiceTableRow(vehicleNumber: 'WP-0005', serviceType: 'Oil', status: ServiceItemDueStatus.kmUnknown),
      ServiceTableRow(vehicleNumber: 'WP-0006', serviceType: 'Oil', status: ServiceItemDueStatus.neverServiced),
    ];

    test('buckets: MISSED/NEVER_SERVICED fold into OVERDUE, KM_UNKNOWN into DUE SOON', () {
      expect(serviceTableBucket(ServiceItemDueStatus.missed), ServiceItemDueStatus.overdue);
      expect(serviceTableBucket(ServiceItemDueStatus.neverServiced), ServiceItemDueStatus.overdue);
      expect(serviceTableBucket(ServiceItemDueStatus.kmUnknown), ServiceItemDueStatus.dueSoon);
      expect(serviceTableBucket(ServiceItemDueStatus.ok), ServiceItemDueStatus.ok);
    });

    test('default sort: Overdue, then Due soon, then OK; secondary by vehicle no.', () {
      final sorted = [...rows]..sort(compareServiceTableRowsByStatus);
      expect(sorted.map((r) => r.vehicleNumber).toList(),
          ['WP-0001', 'WP-0004', 'WP-0006', 'WP-0002', 'WP-0005', 'WP-0003']);
    });

    test('filter by bucket and by vehicle search', () {
      expect(
        filterServiceTableRows(rows, bucket: ServiceItemDueStatus.overdue)
            .map((r) => r.vehicleNumber)
            .toSet(),
        {'WP-0001', 'WP-0004', 'WP-0006'},
      );
      expect(filterServiceTableRows(rows, bucket: ServiceItemDueStatus.ok).single.vehicleNumber,
          'WP-0003');
      expect(filterServiceTableRows(rows, search: 'wp-0002').single.vehicleNumber, 'WP-0002');
      expect(filterServiceTableRows(rows, search: 'nope'), isEmpty);
      expect(filterServiceTableRows(rows).length, rows.length);
    });

    test('buildServiceTableRows: one row per schedule; a vehicle with none keeps one row', () {
      final built = buildServiceTableRows([
        (
          vehicleNumber: 'WP-1',
          currentKm: null,
          kmSource: 'unknown',
          worstStatus: ServiceItemDueStatus.ok,
          due: const <ServiceItemDue>[],
        ),
        (
          vehicleNumber: 'WP-2',
          currentKm: 1000,
          kmSource: 'gps',
          worstStatus: ServiceItemDueStatus.overdue,
          due: const [
            ServiceItemDue(itemId: 'a', itemName: 'A', status: ServiceItemDueStatus.overdue, milestoneKm: 900),
            ServiceItemDue(itemId: 'b', itemName: 'B', status: ServiceItemDueStatus.ok, milestoneKm: 5000),
          ],
        ),
      ]);
      expect(built.length, 3);
      expect(built.first.serviceType, isNull);
      expect(built.first.currentKm, isNull);
      expect(built[1].nextDueKm, 900);
      expect(built[2].currentKm, 1000);
    });

    test('garage rows: overdue first, current km looked up from the vehicle status', () {
      const v = GarageVehicleStatus(
        vehicleId: 't1',
        vehicleNumber: 'WP-9',
        isBike: false,
        currentTotalKm: 12345,
        kmSinceLastService: 4990,
        serviceIntervalKm: 5000,
        deviceId: 1,
      );
      final built = buildGarageServiceDueRows(
        vehicleStatuses: const [v],
        typeAlerts: const [
          GarageServiceTypeAlert(vehicleNumber: 'WP-9', isBike: false, typeName: 'Brakes', kmRemaining: -20),
          GarageServiceTypeAlert(vehicleNumber: 'BK-1', isBike: true, typeName: 'Chain', kmRemaining: 10),
        ],
      )..sort(compareGarageServiceDueRows);
      expect(built.map((r) => r.serviceType).toList(), ['Brakes', 'Chain', 'General service']);
      expect(built.first.currentKm, 12345);
      expect(built[1].currentKm, isNull); // bike not in vehicleStatuses -> unknown
    });
  });

  group('ServiceScheduleTable widget', () {
    testWidgets('default order + "unknown" km + Status header toggles', (tester) async {
      await _setSurface(tester, const Size(1200, 2200));
      await tester.pumpWidget(_host(const ServiceScheduleTable(rows: [
        ServiceTableRow(vehicleNumber: 'WP-OK', serviceType: 'Oil', status: ServiceItemDueStatus.ok, currentKm: 100),
        ServiceTableRow(vehicleNumber: 'WP-SOON', serviceType: 'Oil', status: ServiceItemDueStatus.dueSoon, currentKm: 200),
        ServiceTableRow(vehicleNumber: 'WP-LATE', serviceType: 'Oil', status: ServiceItemDueStatus.overdue),
      ]), width: 1150));
      expect(_y(tester, 'WP-LATE') < _y(tester, 'WP-SOON'), isTrue);
      expect(_y(tester, 'WP-SOON') < _y(tester, 'WP-OK'), isTrue);
      expect(find.text('unknown'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('dtv-header-${ServiceScheduleTable.statusColumnIndex}')));
      await tester.pump();
      expect(_y(tester, 'WP-OK') < _y(tester, 'WP-SOON'), isTrue);
      expect(_y(tester, 'WP-SOON') < _y(tester, 'WP-LATE'), isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('paginates a large fleet at 25 rows/page', (tester) async {
      await _setSurface(tester, const Size(1200, 2200));
      final rows = [
        for (var i = 0; i < 30; i++)
          ServiceTableRow(
            vehicleNumber: 'WP-${i.toString().padLeft(3, '0')}',
            serviceType: 'Oil',
            status: ServiceItemDueStatus.ok,
          ),
      ];
      await tester.pumpWidget(_host(ServiceScheduleTable(rows: rows)));
      expect(find.text('1–25 of 30'), findsOneWidget);
      expect(find.text('WP-024'), findsOneWidget);
      expect(find.text('WP-025'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('dtv-next')));
      await tester.pump();
      expect(find.text('WP-025'), findsOneWidget);
    });
  });

  group('ServiceOverviewScreen SERVICE STATUS table (FakeFirestore)', () {
    Future<FakeFirebaseFirestore> fixture() async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc('uidAdmin').set({'name': 'Admin', 'role': 'admin'});
      await db.collection('settings').doc('repair_workflow').set({'lateToleranceKm': 500});
      await db.collection('service_items').doc('s1').set({
        'name': '45,000 km Service',
        'intervalKm': 45000,
        'warnBeforeKm': 1000,
        'appliesTo': 'ALL',
        'active': true,
        'sortOrder': 1,
      });
      // Fresh vehicle_km_cache entries -> no background Traccar refresh.
      final kms = {'WP-A': 50000, 'WP-B': 44500, 'WP-C': 10000};
      for (final e in {...kms, 'WP-D': null}.entries) {
        await db.collection('trucks').doc(e.key).set({'truckNumber': e.key});
        if (e.value != null) {
          await db.collection('vehicle_km_cache').doc(e.key).set({
            'vehicleNumber': e.key,
            'km': e.value,
            'updatedAt': Timestamp.now(),
          });
        }
      }
      return db;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    for (final size in [const Size(390, 844), const Size(1200, 900)]) {
      testWidgets('filter chips narrow the rows (${size.width.toInt()}w)', (tester) async {
        await _setSurface(tester, size);
        final db = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ServiceOverviewScreen(firestoreOverride: db, currentUidOverride: 'uidAdmin'),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // ALL: overdue (A) first, then due soon (B, D=km unknown), then OK (C).
        for (final v in ['WP-A', 'WP-B', 'WP-C', 'WP-D']) {
          expect(find.text(v), findsOneWidget, reason: v);
        }
        expect(_y(tester, 'WP-A') < _y(tester, 'WP-B'), isTrue);
        expect(_y(tester, 'WP-B') < _y(tester, 'WP-D'), isTrue);
        expect(_y(tester, 'WP-D') < _y(tester, 'WP-C'), isTrue);
        expect(find.text('unknown'), findsOneWidget); // WP-D's current km

        await tester.tap(find.byKey(const ValueKey('dtv-filter-OVERDUE')));
        await settle(tester);
        expect(find.text('WP-A'), findsOneWidget);
        expect(find.text('WP-B'), findsNothing);
        expect(find.text('WP-C'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('dtv-filter-DUE_SOON')));
        await settle(tester);
        expect(find.text('WP-B'), findsOneWidget);
        expect(find.text('WP-D'), findsOneWidget);
        expect(find.text('WP-A'), findsNothing);

        await tester.tap(find.byKey(const ValueKey('dtv-filter-OK')));
        await settle(tester);
        expect(find.text('WP-C'), findsOneWidget);
        expect(find.text('WP-A'), findsNothing);

        // Search + filter combine; a no-match shows the empty state.
        await tester.enterText(find.byType(TextField).first, 'WP-A');
        await settle(tester);
        expect(find.text('NO VEHICLES MATCH THIS FILTER'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('dtv-filter-ALL')));
        await settle(tester);
        expect(find.text('WP-A'), findsNWidgets(2)); // search field + row
        expect(find.text('WP-C'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
