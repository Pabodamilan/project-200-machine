// Route distances from one loading site, daily check date (Asia/Colombo,
// kept across offline retry) and daily check photos (thumbnails,
// "Photo not available" + Retry, "No photos", upload failure message).
import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';
import 'package:project_200_machine/widgets/table_export.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46]);
final _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Future<void> _pumps(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void _surface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Map<String, dynamic> _site(
  String name, {
  double? lat,
  double? lng,
  bool loading = true,
  bool unloading = true,
}) => {
  'name': name,
  'canBeLoadingSite': loading,
  'canBeUnloadingSite': unloading,
  'latitude': ?lat,
  'longitude': ?lng,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  tearDown(() {
    DailyCheckPhoto.debugImageProviderBuilder = null;
    DailyCheckPhoto.debugUrlResolver = null;
  });

  // ---------------- A. Route distances ----------------
  group('route distances from a loading site', () {
    final sites = <String, Map<String, dynamic>>{
      'L1': _site('COLOMBO YARD', lat: 6.9271, lng: 79.8612, unloading: false),
      'L2': _site('GALLE QUARRY', lat: 6.0535, lng: 80.2210, unloading: false),
      'U_NEAR': _site(
        'WELLAWATTE SITE',
        lat: 6.9500,
        lng: 79.8612,
        loading: false,
      ),
      'U_FAR': _site('KANDY SITE', lat: 7.2906, lng: 80.6337, loading: false),
      'U_ROAD': _site('KELANIYA SITE', loading: false),
      'U_NOLOC': _site('ANURADHAPURA SITE', loading: false),
    };

    test(
      'road distance wins, else straight line, else No location; nearest first',
      () {
        final rows = buildSiteDistanceRows(
          loadingSiteId: 'L1',
          sitesById: sites,
          roadKmByUnloadingSiteId: {'U_ROAD': 12.0},
        );
        expect(rows.map((r) => r.siteId), [
          'U_NEAR',
          'U_ROAD',
          'U_FAR',
          'U_NOLOC',
        ]);
        expect(rows[0].source, SiteDistanceSource.straightLine);
        expect(rows[0].km, closeTo(2.5, 0.2));
        expect(rows[1].source, SiteDistanceSource.road);
        expect(rows[1].km, 12.0);
        expect(rows[2].km, closeTo(94, 5));
        expect(rows[3].source, SiteDistanceSource.noLocation);
        expect(rows[3].km, isNull);
        expect(rows[3].kmText, 'No location');
        expect(
          siteDistanceSourceLabel(SiteDistanceSource.straightLine),
          'approx (straight line)',
        );
        expect(siteDistanceSourceLabel(SiteDistanceSource.road), 'by road');
        // Farthest first still keeps No location at the bottom.
        final far = buildSiteDistanceRows(
          loadingSiteId: 'L1',
          sitesById: sites,
          roadKmByUnloadingSiteId: {'U_ROAD': 12.0},
          sort: SiteDistanceSort.farthest,
        );
        expect(far.map((r) => r.siteId), [
          'U_FAR',
          'U_ROAD',
          'U_NEAR',
          'U_NOLOC',
        ]);
      },
    );

    test('export rows carry km, type and "No location"', () {
      final rows = buildSiteDistanceRows(
        loadingSiteId: 'L1',
        sitesById: sites,
        roadKmByUnloadingSiteId: {'U_ROAD': 12.0},
      );
      final e = buildTableExport<SiteDistanceRow>(
        title: 'Distances from COLOMBO YARD',
        columns: siteDistanceTableColumns(),
        rows: rows,
        generatedBy: 'Admin',
      );
      expect(e.headers, ['Unloading Site', 'Distance (km)', 'Type']);
      expect(e.rows[1], ['KELANIYA SITE', '12.0', 'by road']);
      expect(e.rows[0][2], 'approx (straight line)');
      expect(e.rows.last, ['ANURADHAPURA SITE', 'No location', 'No location']);
    });

    for (final size in [const Size(390, 844), const Size(1200, 900)]) {
      testWidgets(
        'screen: pick loading site (search) -> table nearest first, No location, search, filter, '
        'export menu (${size.width.toInt()}px)',
        (tester) async {
          _surface(tester, size);
          final db = FakeFirebaseFirestore();
          await db.collection('users').doc('uidAdmin').set({
            'name': 'Ann Admin',
            'role': 'admin',
          });
          for (final e in sites.entries) {
            await db.collection('sites').doc(e.key).set(e.value);
          }
          await db.collection('route_distances').doc('L1_U_ROAD').set({
            'loadingSiteId': 'L1',
            'unloadingSiteId': 'U_ROAD',
            'distanceKm': 12.0,
          });
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light(),
              home: RouteDistanceManagementScreen(
                firestoreOverride: db,
                currentUidOverride: 'uidAdmin',
              ),
            ),
          );
          await _pumps(tester);
          // Saved-routes tab is unchanged.
          expect(find.text('COLOMBO YARD → KELANIYA SITE'), findsOneWidget);

          await tester.tap(find.byKey(const ValueKey('route-tab-from-site')));
          await _pumps(tester);
          expect(find.text('Select loading site'), findsOneWidget);

          await tester.tap(
            find.byKey(const ValueKey('route-from-site-picker')),
          );
          await _pumps(tester);
          // Only loading sites are offered; search narrows them.
          expect(
            find.byKey(const ValueKey('route-from-site-option-L1')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('route-from-site-option-L2')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('route-from-site-option-U_FAR')),
            findsNothing,
          );
          await tester.enterText(
            find.byKey(const ValueKey('route-from-site-picker-search')),
            'colo',
          );
          await _pumps(tester, 2);
          expect(
            find.byKey(const ValueKey('route-from-site-option-L2')),
            findsNothing,
          );
          await tester.tap(
            find.byKey(const ValueKey('route-from-site-option-L1')),
          );
          await _pumps(tester);
          expect(tester.takeException(), isNull);

          expect(find.text('Loading site: COLOMBO YARD'), findsOneWidget);
          expect(find.text('12.0 km'), findsOneWidget);
          expect(find.text('by road'), findsOneWidget);
          expect(find.text('approx (straight line)'), findsNWidgets(2));
          expect(
            find.byKey(const ValueKey('route-from-site-km-U_NOLOC')),
            findsOneWidget,
          );
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('route-from-site-km-U_NOLOC')),
                )
                .data,
            'No location',
          );
          // Nearest on top, No location at the bottom.
          double y(String name) => tester.getTopLeft(find.text(name)).dy;
          expect(y('WELLAWATTE SITE'), lessThan(y('KELANIYA SITE')));
          expect(y('KELANIYA SITE'), lessThan(y('KANDY SITE')));
          expect(y('KANDY SITE'), lessThan(y('ANURADHAPURA SITE')));

          // Sort toggle.
          await tester.tap(
            find.byKey(const ValueKey('route-from-site-sort-farthest')),
          );
          await _pumps(tester, 2);
          expect(y('KANDY SITE'), lessThan(y('WELLAWATTE SITE')));

          // Filter: No location only.
          await tester.tap(find.byKey(const ValueKey('dtv-filter-noLocation')));
          await _pumps(tester, 2);
          expect(find.text('ANURADHAPURA SITE'), findsOneWidget);
          expect(find.text('KANDY SITE'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('dtv-filter-all')));
          await _pumps(tester, 2);

          // Search.
          await tester.enterText(
            find.widgetWithText(TextField, 'Search unloading site'),
            'kan',
          );
          await _pumps(tester, 2);
          expect(find.text('KANDY SITE'), findsOneWidget);
          expect(find.text('WELLAWATTE SITE'), findsNothing);

          // Standard table export menu (PDF / PNG).
          await tester.tap(find.byKey(const ValueKey('dtv-export')));
          await _pumps(tester, 3);
          expect(find.byKey(const ValueKey('dtv-export-pdf')), findsOneWidget);
          expect(find.byKey(const ValueKey('dtv-export-png')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  });

  // ---------------- B. Daily check date ----------------
  group('daily check date = Asia/Colombo day', () {
    test('23:50 Colombo (18:20 UTC) and 02:00 Colombo (previous UTC day)', () {
      final lateNight = DateTime.utc(2026, 11, 26, 18, 20); // 23:50 Colombo
      expect(colomboDateKey(lateNight), '2026-11-26');
      final earlyMorning = DateTime.utc(2026, 11, 25, 20, 30); // 02:00 Colombo
      expect(dailyCheckDateKey(earlyMorning), '2026-11-25'); // UTC day — wrong
      expect(colomboDateKey(earlyMorning), '2026-11-26');
      expect(colomboDailyCheckDocId('wp-1 ', earlyMorning), 'WP-1_2026-11-26');
      expect(
        formatColomboDateTime(Timestamp.fromDate(lateNight)),
        '2026-11-26 11:50 PM',
      );
    });

    test('date issue diagnostics', () {
      final ok = {
        'date': '2026-11-26',
        'deviceSubmittedAt': Timestamp.fromDate(
          DateTime.utc(2026, 11, 26, 18, 20),
        ),
        // Synced after midnight — fine, the device time is what counts.
        'submittedAt': Timestamp.fromDate(DateTime.utc(2026, 11, 27, 2, 0)),
      };
      expect(dailyCheckDateIssues('WP-1_2026-11-26', ok), isEmpty);
      final old = {
        'date': '2026-11-27',
        'submittedAt': Timestamp.fromDate(DateTime.utc(2026, 11, 26, 18, 20)),
      };
      expect(dailyCheckDateIssues('WP-1_2026-11-27', old), [
        'saved on server 2026-11-26 ≠ date 2026-11-27',
      ]);
      expect(dailyCheckDateIssues('WP-1_2026-11-25', {'date': '2026-11-26'}), [
        'doc id date 2026-11-25 ≠ date 2026-11-26',
      ]);
      expect(dailyCheckDateIssues('WP-1_2026-11-25', <String, dynamic>{}), [
        'date field missing',
      ]);
    });

    Future<FakeFirebaseFirestore> driverDb() async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc('uidDriver').set({
        'name': 'Driver Dan',
        'role': 'driver',
      });
      return db;
    }

    Widget form(
      FakeFirebaseFirestore db,
      DateTime Function() clock,
      DailyCheckPhotoUploader up,
    ) => MaterialApp(
      theme: AppTheme.light(),
      home: DriverDailyCheckScreen(
        vehicleNumber: 'WP-1',
        driverName: 'Driver Dan',
        firestoreOverride: db,
        currentUidOverride: 'uidDriver',
        photoUploaderOverride: up,
        clockOverride: clock,
        debugInitialPhotos: {
          'water_level': _jpeg,
          'engine_oil_level': _jpeg,
          'hydraulic_oil_level': _jpeg,
        },
      ),
    );

    testWidgets(
      '02:00 Colombo submit (UTC previous day) -> Colombo day; doc id = date field',
      (tester) async {
        _surface(tester, const Size(390, 1600));
        final db = await driverDb();
        final paths = <String>[];
        final at = DateTime.utc(2026, 11, 25, 20, 30);
        await tester.pumpWidget(
          form(db, () => at, (p, b, m) async {
            paths.add(p);
            return 'https://example.test/$p';
          }),
        );
        await _pumps(tester, 5);
        await tester.ensureVisible(find.text('SUBMIT'));
        await tester.tap(find.text('SUBMIT'));
        await _pumps(tester, 10);
        expect(tester.takeException(), isNull);

        final docs = (await db.collection('daily_checks').get()).docs;
        expect(docs.map((d) => d.id), ['WP-1_2026-11-26']);
        final data = docs.single.data();
        expect(data['date'], '2026-11-26');
        expect(data['dateTimezone'], 'Asia/Colombo');
        expect((data['deviceSubmittedAt'] as Timestamp).toDate().toUtc(), at);
        expect(paths.every((p) => p.contains('/2026-11-26/')), isTrue);
        expect(dailyCheckDateIssues(docs.single.id, data), isEmpty);
      },
    );

    testWidgets(
      '23:50 Colombo submit, upload fails, RETRY after midnight -> still saved on the original day',
      (tester) async {
        _surface(tester, const Size(390, 1600));
        final db = await driverDb();
        var clock = DateTime.utc(2026, 11, 26, 18, 20); // 23:50 Colombo
        var offline = true;
        await tester.pumpWidget(
          form(db, () => clock, (p, b, m) async {
            if (offline) {
              throw FirebaseException(
                plugin: 'firebase_storage',
                code: 'retry-limit-exceeded',
              );
            }
            return 'https://example.test/$p';
          }),
        );
        await _pumps(tester, 5);
        await tester.ensureVisible(find.text('SUBMIT'));
        await tester.tap(find.text('SUBMIT'));
        await _pumps(tester, 5);
        // Not silent: the driver is told the photo didn't upload, nothing saved.
        expect(
          find.byKey(const ValueKey('daily-check-submit-error')),
          findsOneWidget,
        );
        expect(find.textContaining('could not be uploaded'), findsOneWidget);
        expect((await db.collection('daily_checks').get()).docs, isEmpty);

        // Back online at 00:30 Colombo the next day.
        clock = DateTime.utc(2026, 11, 26, 19, 0);
        offline = false;
        await tester.tap(find.text('RETRY'));
        await _pumps(tester, 10);
        expect(tester.takeException(), isNull);

        final docs = (await db.collection('daily_checks').get()).docs;
        expect(docs.map((d) => d.id), ['WP-1_2026-11-26']);
        expect(docs.single.data()['date'], '2026-11-26');
        expect(
          (docs.single.data()['deviceSubmittedAt'] as Timestamp)
              .toDate()
              .toUtc(),
          DateTime.utc(2026, 11, 26, 18, 20),
        );
        final checks = (docs.single.data()['checks'] as List)
            .cast<Map<String, dynamic>>();
        expect(
          checks.every(
            (c) => (c['photoPath'] as String).contains('/2026-11-26/'),
          ),
          isTrue,
        );
      },
    );

    testWidgets('admin list shows the date field and flags a date mismatch', (
      tester,
    ) async {
      _surface(tester, const Size(1200, 1400));
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc('uidAdmin').set({
        'name': 'Ann Admin',
        'role': 'admin',
      });
      final today = colomboDateKey(DateTime.now());
      final yesterdayInstant = DateTime.now().subtract(const Duration(days: 1));
      await db.collection('daily_checks').doc('WP-2_$today').set({
        'vehicleNumber': 'WP-2',
        'date': today,
        'driverName': 'Old Phone',
        'checks': const [],
        'hasLow': false,
        'deviceSubmittedAt': Timestamp.fromDate(yesterdayInstant),
      });
      await db.collection('daily_checks').doc('WP-3_$today').set({
        'vehicleNumber': 'WP-3',
        'date': today,
        'driverName': 'Good Phone',
        'checks': const [],
        'hasLow': false,
        'deviceSubmittedAt': Timestamp.now(),
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DailyChecksScreen(
            firestoreOverride: db,
            currentUidOverride: 'uidAdmin',
          ),
        ),
      );
      await _pumps(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Good Phone • $today • submitted'),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('daily-check-date-issue-WP-2_$today')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('daily-check-date-issue-WP-3_$today')),
        findsNothing,
      );
      expect(
        find.textContaining(
          'submitted on device ${colomboDateKey(yesterdayInstant)}',
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('daily-checks-only-date-issues')),
      );
      await _pumps(tester, 2);
      expect(find.text('WP-2'), findsOneWidget);
      expect(find.text('WP-3'), findsNothing);
    });
  });

  // ---------------- C. Daily check photos ----------------
  group('daily check photos', () {
    final checks = [
      {
        'id': 'water_level',
        'label': 'Water Level',
        'status': 'OK',
        'photoUrl': 'https://example.test/w.jpg',
      },
      {
        'id': 'engine_oil_level',
        'label': 'Engine Oil Level',
        'status': 'LOW',
        'photoUrl': 'https://example.test/e.jpg',
      },
      // Older shape: path only, no URL -> resolved via getDownloadURL.
      {
        'id': 'hydraulic_oil_level',
        'label': 'Hydraulic Oil Level',
        'status': 'OK',
        'photoPath': 'repairs/daily_checks/WP-1/2026-11-26/h.jpg',
      },
    ];

    testWidgets(
      'read-only screen: thumbnails from photoUrl and photoPath, tap opens zoom viewer',
      (tester) async {
        _surface(tester, const Size(390, 900));
        final resolved = <String>[];
        DailyCheckPhoto.debugUrlResolver = (path) async {
          resolved.add(path);
          return 'https://example.test/resolved.jpg';
        };
        DailyCheckPhoto.debugImageProviderBuilder = (_) => MemoryImage(_png1x1);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: DailyCheckReadOnlyScreen(
              truckNumber: 'WP-1',
              data: {
                'date': '2026-11-26',
                'driverName': 'Driver Dan',
                'checks': checks,
              },
            ),
          ),
        );
        await _pumps(tester, 5);
        expect(tester.takeException(), isNull);
        for (var i = 0; i < 3; i++) {
          expect(find.byKey(ValueKey('daily-check-thumb-$i')), findsOneWidget);
        }
        expect(resolved, ['repairs/daily_checks/WP-1/2026-11-26/h.jpg']);
        expect(find.text('Photo not available'), findsNothing);
        expect(
          find.byKey(const ValueKey('daily-check-no-photos')),
          findsNothing,
        );

        await tester.tap(find.byKey(const ValueKey('daily-check-thumb-1')));
        await _pumps(tester, 5);
        expect(
          find.byKey(const ValueKey('daily-check-photo-viewer')),
          findsOneWidget,
        );
        expect(find.text('ENGINE OIL LEVEL · 2 / 3'), findsOneWidget);
        expect(find.byType(InteractiveViewer), findsWidgets);
      },
    );

    testWidgets('URL fails -> "Photo not available" + Retry; Retry loads it', (
      tester,
    ) async {
      _surface(tester, const Size(390, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DailyCheckReadOnlyScreen(
            truckNumber: 'WP-1',
            data: {
              'date': '2026-11-26',
              'checks': [checks.first],
            },
          ),
        ),
      );
      // The test HTTP client answers 400 -> load error.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await _pumps(tester, 5);
      expect(find.text('Photo not available'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('daily-check-photo-retry')),
        findsOneWidget,
      );

      DailyCheckPhoto.debugImageProviderBuilder = (_) => MemoryImage(_png1x1);
      await tester.tap(find.byKey(const ValueKey('daily-check-photo-retry')));
      await _pumps(tester, 5);
      expect(find.text('Photo not available'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'check without photos -> "No photos"; submitted screen shows thumbnails',
      (tester) async {
        _surface(tester, const Size(390, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: DailyCheckReadOnlyScreen(
              truckNumber: 'WP-1',
              data: {
                'date': '2026-11-26',
                'checks': [
                  {'id': 'water_level', 'label': 'Water Level', 'status': 'OK'},
                ],
              },
            ),
          ),
        );
        await _pumps(tester, 3);
        expect(
          find.byKey(const ValueKey('daily-check-no-photos')),
          findsOneWidget,
        );
        expect(find.text('No photos'), findsOneWidget);

        DailyCheckPhoto.debugImageProviderBuilder = (_) => MemoryImage(_png1x1);
        DailyCheckPhoto.debugUrlResolver = (_) async =>
            'https://example.test/r.jpg';
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: DailyCheckSubmittedScreen(
              truckNumber: 'WP-1',
              dateKey: '2026-11-26',
              checks: checks,
            ),
          ),
        );
        await _pumps(tester, 3);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('daily-check-thumb-0')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('daily-check-thumb-2')),
          findsOneWidget,
        );
      },
    );
  });
}
