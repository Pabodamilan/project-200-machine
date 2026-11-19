// Task A: km-source resilience (vehicle_km_cache permission-denied, live km
// from /api/positions totalDistance first, /api/reports/summary only as a
// 3-at-a-time fallback).
// Task B: table export (all filtered rows across pages, in the on-screen
// sort, header content), uid -> name resolution with "-" fallback, and the
// new Date / "who" columns on the real screens.
import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:project_200_machine/main.dart';
import 'package:project_200_machine/widgets/data_table_view.dart';
import 'package:project_200_machine/widgets/table_export.dart';

FirebaseException _denied(String what) => FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'Simulated permission-denied ($what)',
    );

// Every read/write on the listed collections fails with permission-denied
// (collection get, where().get(), doc().get()/set(), snapshots()); every
// other collection is the real FakeFirebaseFirestore.
class _DenyingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final Set<String> denied;
  int deniedCalls = 0;
  _DenyingFirestore(this.inner, this.denied);

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) =>
      denied.contains(path) ? _DeniedCollection(path, this) : inner.collection(path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DeniedCollection implements CollectionReference<Map<String, dynamic>> {
  @override
  final String path;
  final _DenyingFirestore owner;
  _DeniedCollection(this.path, this.owner);

  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    owner.deniedCalls++;
    return Future.error(_denied(path));
  }

  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    owner.deniedCalls++;
    return Stream.error(_denied(path));
  }

  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) => _DeniedDoc(path, owner);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #where || invocation.memberName == #limit) return this;
    return super.noSuchMethod(invocation);
  }
}

class _DeniedDoc implements DocumentReference<Map<String, dynamic>> {
  @override
  final String path;
  final _DenyingFirestore owner;
  _DeniedDoc(this.path, this.owner);

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    owner.deniedCalls++;
    return Future.error(_denied(path));
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) {
    owner.deniedCalls++;
    return Future.error(_denied(path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _R = ({String name, int n, String date});

List<DataTableColumn<_R>> _cols() => [
      DataTableColumn<_R>(
        label: 'Name',
        width: 120,
        cellBuilder: (_, r) => Text(r.name),
        compare: (a, b) => a.name.compareTo(b.name),
        exportValue: (r) => r.name,
      ),
      DataTableColumn<_R>(
        label: 'Date',
        width: 110,
        isDate: true,
        cellBuilder: (_, r) => Text(r.date),
        compare: (a, b) => a.date.compareTo(b.date),
        exportValue: (r) => r.date,
      ),
      DataTableColumn<_R>(
        label: 'Num',
        width: 90,
        cellBuilder: (_, r) => Text('n=${r.n}'),
        compare: (a, b) => a.n.compareTo(b.n),
        exportValue: (r) => '${r.n}',
      ),
      DataTableColumn<_R>(
        label: 'Actions',
        width: 90,
        cellBuilder: (_, r) => const Icon(Icons.edit),
      ),
    ];

Future<void> _surface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(() {
    VehicleKmCache.reset();
    ServiceAlertsCache.reset();
    UserDirectory.reset();
    ReferenceCollectionCache.reset();
  });

  // ---------------- Task A ----------------
  group('live km: /api/positions first, summary fallback', () {
    test('totalDistanceKmFromPositions: metres -> km; missing/zero/non-number = unknown', () {
      final positions = [
        {'deviceId': 7, 'attributes': {'totalDistance': 123456.0}},
        {'deviceId': 8, 'attributes': <String, dynamic>{}},
        {'deviceId': 9, 'attributes': {'totalDistance': 0}},
        {'deviceId': 10, 'attributes': {'totalDistance': 'x'}},
        {'deviceId': 11},
      ];
      expect(totalDistanceKmFromPositions(positions, 7), closeTo(123.456, 1e-9));
      expect(totalDistanceKmFromPositions(positions, 8), isNull);
      expect(totalDistanceKmFromPositions(positions, 9), isNull);
      expect(totalDistanceKmFromPositions(positions, 10), isNull);
      expect(totalDistanceKmFromPositions(positions, 11), isNull);
      expect(totalDistanceKmFromPositions(positions, 99), isNull);
    });

    test('uses positions totalDistance and never calls /api/reports/summary', () async {
      var summaryCalls = 0;
      TraccarService.fetchPositionsOverride = () async => [
            {'deviceId': 7, 'attributes': {'totalDistance': 50000.0}},
          ];
      TraccarService.fetchDistanceSummaryOverride =
          ({required int deviceId, required DateTime from, required DateTime to}) async {
        summaryCalls++;
        return 1.0;
      };
      expect(await VehicleKmCache.currentTotalKm(7), 50.0);
      expect(summaryCalls, 0);
    });

    test('falls back to summary only when the device has no totalDistance', () async {
      var summaryCalls = 0;
      TraccarService.fetchPositionsOverride = () async => [
            {'deviceId': 7, 'attributes': <String, dynamic>{}},
          ];
      TraccarService.fetchDistanceSummaryOverride =
          ({required int deviceId, required DateTime from, required DateTime to}) async {
        summaryCalls++;
        return 5000.0;
      };
      expect(await VehicleKmCache.currentTotalKm(7), 5.0);
      expect(summaryCalls, 1);
    });

    test('allowSummaryFallback:false -> unknown (throws), no summary call, nothing faked', () async {
      var summaryCalls = 0;
      TraccarService.fetchPositionsOverride = () async => const <Map<String, dynamic>>[];
      TraccarService.fetchDistanceSummaryOverride =
          ({required int deviceId, required DateTime from, required DateTime to}) async {
        summaryCalls++;
        return 1.0;
      };
      await expectLater(
        VehicleKmCache.currentTotalKm(7, allowSummaryFallback: false),
        throwsA(isA<StateError>()),
      );
      expect(summaryCalls, 0);
    });

    test('positions fetched by another caller are reused (no second /api/positions)', () async {
      var positionsCalls = 0;
      TraccarService.fetchPositionsOverride = () async {
        positionsCalls++;
        return [
          {'deviceId': 1, 'attributes': {'totalDistance': 1000.0}},
          {'deviceId': 2, 'attributes': {'totalDistance': 2000.0}},
        ];
      };
      await TraccarService.fetchPositions(username: 'u', password: 'p'); // e.g. Live Tracking
      expect(await VehicleKmCache.currentTotalKm(1), 1.0);
      expect(await VehicleKmCache.currentTotalKm(2), 2.0);
      expect(positionsCalls, 1);
    });

    test('withSummarySlot: at most 3 summary calls in flight, all complete', () async {
      final gates = List.generate(10, (_) => Completer<double>());
      var running = 0;
      var peak = 0;
      final futures = [
        for (final g in gates)
          VehicleKmCache.withSummarySlot(() async {
            running++;
            if (running > peak) peak = running;
            final v = await g.future;
            running--;
            return v;
          }),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(running, 3);
      for (var i = 0; i < gates.length; i++) {
        gates[i].complete(i.toDouble());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
      }
      expect(await Future.wait(futures), [for (var i = 0; i < 10; i++) i.toDouble()]);
      expect(peak, 3);
      expect(VehicleKmCache.peakConcurrentSummaryCalls, 3);
    });
  });

  group('vehicle_km_cache permission-denied', () {
    test('bulk read returns an empty cache (no throw) and is not retried per call', () async {
      final db = _DenyingFirestore(FakeFirebaseFirestore(), {'vehicle_km_cache'});
      expect(await VehicleKmCache.allCached(db: db), isEmpty);
      final callsAfterFirst = db.deniedCalls;
      expect(await VehicleKmCache.allCached(db: db, forceRefresh: true), isEmpty);
      expect(await readVehicleKmCache('WP-1', db: db), isNull);
      expect(await readVehicleKmCache('WP-2', db: db), isNull);
      // Backed off: no further doomed reads after the first denial.
      expect(db.deniedCalls, callsAfterFirst);
      expect(VehicleKmCache.readDenied, isTrue);
    });

    test('per-vehicle read denied -> null, then skipped', () async {
      final db = _DenyingFirestore(FakeFirebaseFirestore(), {'vehicle_km_cache'});
      expect(await readVehicleKmCache('WP-1', db: db), isNull);
      expect(db.deniedCalls, 1);
      expect(await readVehicleKmCache('WP-2', db: db), isNull);
      expect(db.deniedCalls, 1);
    });

    testWidgets('Service Overview still renders (no "Failed to load") when the cache is denied',
        (tester) async {
      await _surface(tester, const Size(1200, 900));
      final fake = FakeFirebaseFirestore();
      await fake.collection('users').doc('uidAdmin').set({'name': 'Admin', 'role': 'admin'});
      await fake.collection('service_items').doc('s1').set({
        'name': 'Oil',
        'intervalKm': 5000,
        'warnBeforeKm': 500,
        'appliesTo': 'ALL',
        'active': true,
        'sortOrder': 1,
      });
      await fake.collection('trucks').doc('t1').set({'truckNumber': 'WP-7777'});
      final db = _DenyingFirestore(fake, {'vehicle_km_cache'});
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: ServiceOverviewScreen(firestoreOverride: db, currentUidOverride: 'uidAdmin'),
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Failed to load'), findsNothing);
      expect(find.text('WP-7777'), findsOneWidget);
      expect(find.text('unknown'), findsOneWidget); // km unknown, not faked
    });
  });

  // ---------------- Task B ----------------
  group('export row builder', () {
    test('header content, excluded action column, date range, every row', () {
      final rows = [for (var i = 0; i < 60; i++) (name: 'r$i', n: i, date: '2026-01-${(i % 28 + 1).toString().padLeft(2, '0')}')];
      final e = buildTableExport<_R>(
        title: 'Service Status',
        columns: _cols(),
        rows: rows,
        generatedBy: 'Mary (management)',
        filters: describeTableFilters(statusLabel: 'OVERDUE', search: 'WP', extra: {'Vehicle': ''}),
        sortDescription: 'Num (descending)',
        now: DateTime(2026, 11, 11, 9, 5),
      );
      expect(e.headers, ['Name', 'Date', 'Num']); // Actions has no exportValue
      expect(e.rows.length, 60); // not just one page of 25
      expect(e.rows.first, ['r0', '2026-01-01', '0']);
      expect(e.dateRange, '2026-01-01 to 2026-01-28');
      expect(e.landscape, isFalse);
      expect(e.headerLines, [
        'Service Status',
        'Generated: 2026-11-11 09:05',
        'Generated by: Mary (management)',
        'Filters: Status: OVERDUE | Search: "WP"',
        'Sorted by: Num (descending)',
        'Date range: 2026-01-01 to 2026-01-28',
        'Rows: 60',
      ]);
      expect(e.fileName('pdf'), 'Service_Status_202611110905.pdf');
    });

    test('no filters / no dates are stated honestly', () {
      final e = buildTableExport<_R>(
        title: 'T',
        columns: _cols(),
        rows: const [],
        generatedBy: '-',
        now: DateTime(2026, 1, 2, 3, 4),
      );
      expect(e.headerLines, contains('Filters: none (all rows)'));
      expect(e.headerLines, contains('Date range: -'));
      expect(e.headerLines, contains('Rows: 0'));
    });

    testWidgets('controller exports ALL filtered rows (every page) in the on-screen sort',
        (tester) async {
      await _surface(tester, const Size(900, 2200));
      final all = [for (var i = 0; i < 70; i++) (name: 'r$i', n: i, date: '2026-02-01')];
      // The caller's filter: even numbers only -> 35 rows, 2 pages.
      final filtered = all.where((r) => r.n.isEven).toList();
      final controller = DataTableController<_R>();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: DataTableView<_R>(
            columns: _cols(),
            rows: filtered,
            initialSortColumn: 2,
            controller: controller,
          ),
        ),
      ));
      expect(find.text('1–25 of 35'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dtv-header-2'))); // -> descending
      await tester.pump();
      expect(controller.sortDescription, 'Num (descending)');
      final e = buildTableExport<_R>(
        title: 'x',
        columns: controller.columns,
        rows: controller.sortedRows,
        generatedBy: '-',
      );
      expect(e.rows.length, 35);
      expect(e.rows.first[2], '68');
      expect(e.rows.last[2], '0');
      expect(e.rows.any((r) => int.parse(r[2]).isOdd), isFalse);
    });

    test('PDF renders (landscape for wide tables); PNG includes every row', () async {
      final wideCols = [
        ..._cols(),
        for (var i = 0; i < 4; i++)
          DataTableColumn<_R>(
            label: 'Extra $i — wide',
            width: 100,
            cellBuilder: (_, r) => const SizedBox(),
            exportValue: (r) => 'x$i…',
          ),
      ];
      final rows = [for (var i = 0; i < 120; i++) (name: 'Row $i', n: i, date: '2026-03-01')];
      final e = buildTableExport<_R>(
        title: 'Wide',
        columns: wideCols,
        rows: rows,
        generatedBy: 'A',
        now: DateTime(2026, 3, 1),
      );
      expect(e.landscape, isTrue);
      final pdf = await renderTableExportPdf(e);
      expect(String.fromCharCodes(pdf.sublist(0, 4)), '%PDF');

      final png = renderTableExportPng(e);
      final decoded = img.decodePng(Uint8List.fromList(png))!;
      final small = renderTableExportPng(buildTableExport<_R>(
        title: 'Wide',
        columns: wideCols,
        rows: rows.take(10).toList(),
        generatedBy: 'A',
        now: DateTime(2026, 3, 1),
      ));
      // 110 more rows -> 110 more row heights: proves all rows are drawn.
      expect(decoded.height - img.decodePng(Uint8List.fromList(small))!.height, 110 * 22);
    });

    test('latin1Safe / asciiSafe never pass through unsupported characters', () {
      expect(latin1Safe('A — B – C …'), 'A - B - C ...');
      expect(latin1Safe('ශ'), '?');
      expect(asciiSafe('é'), '?');
    });
  });

  group('who-did-it names', () {
    test('resolvePersonName: stored name, then directory, else "-"', () {
      const dir = {'u1': 'Tina'};
      expect(resolvePersonName(storedName: 'Ian', uid: 'u1', namesByUid: dir), 'Ian');
      expect(resolvePersonName(uid: 'u1', namesByUid: dir), 'Tina');
      expect(resolvePersonName(uid: 'u2', namesByUid: dir), '-');
      expect(resolvePersonName(storedName: '  ', uid: null), '-');
      expect(resolvePersonName(), '-');
    });

    testWidgets('UserDirectory resolves from ONE users listener; denied -> "-"', (tester) async {
      final fake = FakeFirebaseFirestore();
      await fake.collection('users').doc('u1').set({'name': 'Tina', 'role': 'technical'});
      final dir = UserDirectory.of(db: fake);
      expect(identical(dir, UserDirectory.of(db: fake)), isTrue);
      await tester.pump(const Duration(milliseconds: 50));
      expect(dir.nameOf('u1'), 'Tina');
      expect(dir.nameOf('nobody'), '-');

      final denied = UserDirectory.of(db: _DenyingFirestore(FakeFirebaseFirestore(), {'users'}));
      await tester.pump(const Duration(milliseconds: 50));
      expect(denied.denied, isTrue);
      expect(denied.nameOf('u1'), '-');
      expect(denied.nameOf('u1', storedName: 'Stored'), 'Stored');
    });

    for (final size in [const Size(390, 844), const Size(1400, 900)]) {
      testWidgets('RepairHistoryScreen: Date first, Reported/Worked/Approved by names, export menu '
          '(${size.width.toInt()}w)', (tester) async {
        await _surface(tester, size);
        final db = FakeFirebaseFirestore();
        await db.collection('users').doc('uidMgmt').set({
          'name': 'Mary',
          'role': 'management',
          'repairPermissions': [kPermHistoryView],
        });
        await db.collection('users').doc('uidTech').set({'name': 'Tina', 'role': 'technical'});
        await db.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Noise',
          'status': RepairItemStatus.completed,
          'reportedBy': 'uidMgmt', // no reportedByName stored -> directory
          'reportedAt': Timestamp.fromDate(DateTime(2026, 4, 5, 10, 30)),
          'startedBy': 'uidTech',
          'doneBy': 'uidTech',
          'completedBy': 'uidMgmt',
          'completedAt': Timestamp.fromDate(DateTime(2026, 4, 7)),
        });
        await db.collection('repairs').doc('r2').set({
          'code': 'NOD/BRK/260002',
          'vehicleNumber': 'WP-1',
          'categoryCode': 'BRK',
          'categoryName': 'Brakes',
          'description': 'Pads',
          'status': RepairItemStatus.inProgress,
          'reportedByName': 'Ian',
          'reportedAt': Timestamp.fromDate(DateTime(2026, 4, 6)),
          'startedBy': 'uidGone', // not in users -> "-"
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairHistoryScreen(
            prefillVehicleNumber: 'WP-1',
            firestoreOverride: db,
            currentUidOverride: 'uidMgmt',
          ),
        ));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        // Date column is the first after the pinned code column.
        expect(find.byKey(const ValueKey('dtv-header-1')), findsOneWidget);
        expect(
          find.descendant(of: find.byKey(const ValueKey('dtv-header-1')), matching: find.text('DATE')),
          findsOneWidget,
        );
        expect(find.text('2026-04-05'), findsOneWidget);
        expect(find.text('Mary'), findsNWidgets(2)); // reported by + approved by (r1)
        expect(find.text('Tina'), findsOneWidget); // worked by (r1)
        expect(find.text('Ian'), findsOneWidget); // stored reportedByName (r2)
        expect(find.byKey(const ValueKey('dtv-export')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('dtv-export')));
        await tester.pumpAndSettle();
        expect(find.text('PDF'), findsOneWidget);
        expect(find.text('Image (PNG)'), findsOneWidget);
      });
    }
  });
}
