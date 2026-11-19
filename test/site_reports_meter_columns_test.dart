// Site Reports (ManagementSiteReportsScreen): Start Meter / End Meter are
// shown ON-SCREEN for management (same as admin/owner), with '-' for rows
// that have no reading and a highlighted row when End < Start. The Excel
// export's column list is untouched (meters are appended only in the
// on-screen table).
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Future<FakeFirebaseFirestore> _seed(String role) async {
  final db = FakeFirebaseFirestore();
  final today = _ymd(DateTime.now());
  await db.collection('users').doc('uidMe').set({'name': 'Me', 'role': role});
  await db.collection('sites').doc('site1').set({'name': 'SITE A'});
  final session = db.collection('daily_sessions').doc('s1');
  await session.set({'supervisorUid': 'sup1', 'date': today});
  final common = {
    'isLoadingCategory': true,
    'date': today,
    'machineName': 'EX-1',
    'siteName': 'SITE A',
    'siteId': 'site1',
    'supervisorName': 'SUP',
    'loadType': 'company',
    'isCompleted': true,
  };
  await session.collection('work_records').doc('r1').set({
    ...common,
    'truckNumber': 'TRK-NORMAL',
    'billNumber': '1',
    'startMeter': 1200,
    'endMeter': 1250.5,
  });
  await session.collection('work_records').doc('r2').set({
    ...common,
    'truckNumber': 'TRK-REVERSED',
    'billNumber': '2',
    'startMeter': 900,
    'endMeter': 850,
  });
  await db.collection('manual_site_reports').doc('m1').set({
    'date': today,
    'isManualEntry': true,
    'truckNumber': 'TRK-MANUAL',
    'billNumber': '3',
    'siteName': 'SITE A',
    'siteId': 'site1',
    'loadType': 'company',
  });
  return db;
}

Future<void> _pump(WidgetTester tester, FakeFirebaseFirestore db) async {
  await tester.binding.setSurfaceSize(const Size(2400, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: ManagementSiteReportsScreen(
        firestoreOverride: db,
        currentUidOverride: 'uidMe',
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

DataRow _rowContaining(WidgetTester tester, String truck) {
  final table = tester.widget<DataTable>(find.byType(DataTable));
  return table.rows.firstWhere(
    (r) => r.cells.any((c) {
      final w = c.child;
      return w is Text && w.data == truck;
    }),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  setUp(ReferenceCollectionCache.reset);

  group('meter helpers', () {
    test('formatMeterReading shows "-" for missing/non-numeric', () {
      expect(formatMeterReading(null), '-');
      expect(formatMeterReading(''), '-');
      expect(formatMeterReading('abc'), '-');
      expect(formatMeterReading(1200), '1200');
      expect(formatMeterReading(1200.0), '1200');
      expect(formatMeterReading(1250.5), '1250.5');
      expect(formatMeterReading(0), '0');
    });

    test('isMeterReversed only when both present and end < start', () {
      expect(isMeterReversed({'startMeter': 10, 'endMeter': 5}), isTrue);
      expect(isMeterReversed({'startMeter': 10, 'endMeter': 10}), isFalse);
      expect(isMeterReversed({'startMeter': 10, 'endMeter': 15}), isFalse);
      expect(isMeterReversed({'startMeter': 10}), isFalse);
      expect(isMeterReversed({}), isFalse);
    });

    test('only admin/owner/management roles see meters', () {
      expect(canViewReportMeters('management'), isTrue);
      expect(canViewReportMeters('admin'), isTrue);
      expect(canViewReportMeters('owner'), isTrue);
      for (final r in ['supervisor', 'driver', 'field_worker', 'technical', null]) {
        expect(canViewReportMeters(r), isFalse, reason: '$r');
      }
    });
  });

  testWidgets('management sees Start/End Meter columns with values', (
    tester,
  ) async {
    final db = await _seed('management');
    await _pump(tester, db);
    expect(tester.takeException(), isNull);

    expect(find.text('Start Meter'), findsOneWidget);
    expect(find.text('End Meter'), findsOneWidget);
    // Existing Duration (meter run) column still there.
    expect(find.text('Duration'), findsOneWidget);

    expect(find.text('1200'), findsOneWidget);
    expect(find.text('1250.5'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
    expect(find.text('850'), findsOneWidget);

    // Manual report has no meter readings -> '-' in both meter cells.
    final manualRow = _rowContaining(tester, 'TRK-MANUAL');
    final manualTexts = manualRow.cells
        .map((c) => c.child)
        .whereType<Text>()
        .map((t) => t.data)
        .toList();
    expect(manualTexts.sublist(manualTexts.length - 2), ['-', '-']);

    // End < Start -> row highlighted, value unchanged.
    final reversed = _rowContaining(tester, 'TRK-REVERSED');
    expect(reversed.color?.resolve({}), kMeterReversedRowColor);
    final normal = _rowContaining(tester, 'TRK-NORMAL');
    expect(normal.color?.resolve({}), isNot(kMeterReversedRowColor));
    expect(
      find.byTooltip('End Meter is less than Start Meter'),
      findsOneWidget,
    );
  });

  testWidgets('management with canEditReports: meters sit before Actions', (
    tester,
  ) async {
    final db = await _seed('management');
    await db.collection('users').doc('uidMe').update({'canEditReports': true});
    await _pump(tester, db);
    expect(tester.takeException(), isNull);

    final table = tester.widget<DataTable>(find.byType(DataTable));
    final labels = table.columns
        .map((c) => (c.label as Text).data)
        .toList();
    final n = labels.length;
    expect(labels.sublist(n - 4), [
      'Duration',
      'Start Meter',
      'End Meter',
      'Actions',
    ]);
  });

  // Header-click sort must use the clicked column regardless of whether
  // the Verified column (canEdit) shifts the DataTable indices.
  // Seeded order: truck asc = MANUAL, NORMAL, REVERSED; bill asc = 1
  // (NORMAL), 2 (REVERSED), 3 (MANUAL) — deliberately different.
  for (final canEdit in [true, false]) {
    testWidgets('header sort targets the clicked column (canEdit: $canEdit)', (
      tester,
    ) async {
      final db = await _seed('management');
      await db.collection('users').doc('uidMe').update({
        'canEditReports': canEdit,
      });
      await _pump(tester, db);
      expect(tester.takeException(), isNull);

      DataTable table() => tester.widget<DataTable>(find.byType(DataTable));
      List<String> truckOrder() => table().rows
          .map(
            (r) => r.cells
                .map((c) => c.child)
                .whereType<Text>()
                .map((t) => t.data ?? '')
                .firstWhere((d) => d.startsWith('TRK-')),
          )
          .toList();
      String? sortedLabel() {
        final i = table().sortColumnIndex;
        return i == null ? null : (table().columns[i].label as Text).data;
      }

      Future<void> tapHeader(String label) async {
        await tester.tap(
          find.descendant(
            of: find.byType(DataTable),
            matching: find.text(label),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      expect(
        table().columns.any((c) => (c.label as Text).data == 'Verified'),
        canEdit,
      );

      await tapHeader('Truck Number');
      expect(sortedLabel(), 'Truck Number');
      expect(truckOrder(), ['TRK-MANUAL', 'TRK-NORMAL', 'TRK-REVERSED']);

      await tapHeader('Truck Number');
      expect(sortedLabel(), 'Truck Number');
      expect(truckOrder(), ['TRK-REVERSED', 'TRK-NORMAL', 'TRK-MANUAL']);

      await tapHeader('Bill Number');
      expect(sortedLabel(), 'Bill Number');
      expect(truckOrder(), ['TRK-NORMAL', 'TRK-REVERSED', 'TRK-MANUAL']);
    });
  }

  testWidgets('a non-report role gets no meter columns', (tester) async {
    final db = await _seed('supervisor');
    await _pump(tester, db);
    expect(tester.takeException(), isNull);
    expect(find.text('TRK-NORMAL'), findsOneWidget);
    expect(find.text('Start Meter'), findsNothing);
    expect(find.text('End Meter'), findsNothing);
  });
}
