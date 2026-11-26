// (A) Technical home Service card + VIEW ALL cover the whole fleet
//     (12-truck fixture): fleet summary counts over every truck, every
//     truck listed on the card, VIEW ALL -> Service Overview
//     listing all 12 trucks for a technical account (view only).
// (B) Repair/Service Test Mode: OFF by default (no settings doc -> no
//     banner), only admin/owner get the TURN OFF action / settings tile,
//     and events written after turning it OFF carry no testModeOverride.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

const _overdueCount = 7;
const _truckCount = 12;
String _truck(int i) => 'WP-${1000 + i}';

Future<FakeFirebaseFirestore> _fleetFixture() async {
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
  for (var i = 1; i <= _truckCount; i++) {
    await db.collection('trucks').doc('t$i').set({'truckNumber': _truck(i), 'isCompanyTruck': true});
    // First 7 are past the 45,000 km milestone (OVERDUE), the rest are
    // well inside it (SERVICED) — same km-hint pattern as the existing
    // technical home tests.
    await db.collection('service_records').doc('km$i').set({
      'vehicleNumber': _truck(i),
      'status': 'APPROVED',
      'currentKm': i <= _overdueCount ? 46000 : 1000,
      'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
    });
  }
  await db.collection('users').doc('uidTech').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'canAccessGarage': true,
    'canAccessWarehouse': true,
    'repairPermissions': technicalDefaults().repairPermissions,
  });
  await db.collection('users').doc('uidAdmin').set({
    'name': 'Admin Alice',
    'role': 'admin',
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

  void bigSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1400, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('(A) technical sees the whole fleet', () {
    testWidgets('home Service card: fleet counts over all 12 trucks, every '
        'truck listed, VIEW ALL -> every truck in Service Overview', (tester) async {
      bigSurface(tester);
      final db = await _fleetFixture();
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
      // List defaults to "Needs service"; All shows every truck.
      await tester.tap(find.byKey(const ValueKey('technical-service-status-all')));
      await settle(tester, 5);

      // Fleet-wide summary counts every truck: 7 overdue + 5 serviced.
      expect(find.text('SERVICED'), findsOneWidget);
      expect(find.text('$_overdueCount'), findsOneWidget);
      expect(find.text('${_truckCount - _overdueCount}'), findsOneWidget);

      // Card itself lists every truck; VIEW ALL opens the full table.
      for (var i = 1; i <= _truckCount; i++) {
        expect(
          find.byKey(ValueKey('technical-service-row-${_truck(i)}')),
          findsOneWidget,
          reason: _truck(i),
        );
      }
      expect(find.text('VIEW ALL ($_truckCount TRUCKS)'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('technical-service-view-all')));
      await settle(tester, 40);
      expect(tester.takeException(), isNull);
      expect(find.byType(ServiceOverviewScreen), findsOneWidget);
      for (var i = 1; i <= _truckCount; i++) {
        expect(find.text(_truck(i)), findsWidgets, reason: _truck(i));
      }
    });

    testWidgets('VIEW ALL is shown even when nothing is due', (tester) async {
      bigSurface(tester);
      final db = await _fleetFixture();
      for (var i = 1; i <= _overdueCount; i++) {
        await db.collection('service_records').doc('km$i').update({'currentKm': 1000});
      }
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
      expect(find.text('NO SERVICES DUE'), findsOneWidget);
      expect(find.text('$_truckCount'), findsOneWidget); // all SERVICED
      expect(find.byKey(const ValueKey('technical-service-view-all')), findsOneWidget);
    });

    test('Service Overview access: technical (view only) + SERVICE_VIEW; '
        'not driver / other roles without it', () {
      expect(canViewServiceOverview({'role': 'technical'}), isTrue);
      expect(
        canViewServiceOverview({
          'role': 'technical',
          'repairPermissions': ['SERVICE_DO'],
        }),
        isTrue,
      );
      expect(canViewServiceOverview({'role': 'admin'}), isTrue);
      expect(canViewServiceOverview({'role': 'owner'}), isTrue);
      expect(
        canViewServiceOverview({
          'role': 'management',
          'repairPermissions': ['SERVICE_VIEW'],
        }),
        isTrue,
      );
      expect(canViewServiceOverview({'role': 'management'}), isFalse);
      expect(canViewServiceOverview({'role': 'driver'}), isFalse);
      expect(canViewServiceOverview({'role': 'supervisor'}), isFalse);
      expect(canViewServiceOverview(null), isFalse);
    });
  });

  group('(B) Test Mode', () {
    Future<void> pumpBanner(
      WidgetTester tester,
      FakeFirebaseFirestore db,
      String uid,
    ) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: TestModeBanner(firestoreOverride: db, currentUidOverride: uid),
        ),
      ));
      await settle(tester, 5);
      expect(tester.takeException(), isNull);
    }

    testWidgets('default OFF: no settings doc / flag missing -> no banner', (
      tester,
    ) async {
      final db = FakeFirebaseFirestore();
      await db.collection('users').doc('uidAdmin').set({'role': 'admin'});
      await pumpBanner(tester, db, 'uidAdmin');
      expect(find.byKey(const ValueKey('test-mode-banner')), findsNothing);

      await db.collection('settings').doc('repair_workflow').set({
        'managerApprovalLimit': 100000,
      });
      await settle(tester, 5);
      expect(find.byKey(const ValueKey('test-mode-banner')), findsNothing);
    });

    testWidgets('ON: technical sees the banner but no TURN OFF', (tester) async {
      final db = await _fleetFixture();
      await db.collection('settings').doc('repair_workflow').update({
        'testModeAllowSameUser': true,
      });
      await pumpBanner(tester, db, 'uidTech');
      expect(find.byKey(const ValueKey('test-mode-banner')), findsOneWidget);
      expect(find.byKey(const ValueKey('test-mode-turn-off')), findsNothing);
    });

    testWidgets('ON: admin TURN OFF -> flag false, banner gone, OFF event has '
        'no testModeOverride', (tester) async {
      final db = await _fleetFixture();
      await db.collection('settings').doc('repair_workflow').update({
        'testModeAllowSameUser': true,
      });
      await pumpBanner(tester, db, 'uidAdmin');
      expect(find.byKey(const ValueKey('test-mode-banner')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('test-mode-turn-off')));
      await settle(tester, 3);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Turn Off'));
      await settle(tester, 5);
      expect(tester.takeException(), isNull);

      final settings =
          await db.collection('settings').doc('repair_workflow').get();
      expect(settings.data()?['testModeAllowSameUser'], isFalse);
      expect(find.byKey(const ValueKey('test-mode-banner')), findsNothing);

      final events = await db
          .collection('settings')
          .doc('repair_workflow')
          .collection('events')
          .get();
      expect(events.docs, hasLength(1));
      expect(events.docs.single.data()['action'], 'TEST_MODE_OFF');
      expect(events.docs.single.data().containsKey('testModeOverride'), isFalse);
      // Turning it off deletes nothing: the trucks/service records are intact.
      expect((await db.collection('trucks').get()).docs, hasLength(_truckCount));
      expect(
        (await db.collection('service_records').get()).docs,
        hasLength(_truckCount),
      );
    });

    testWidgets('Repair & Service Settings tile: admin only', (tester) async {
      final db = await _fleetFixture();
      Future<void> pumpHub(String uid) async {
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckRepairHubScreen(
            key: ValueKey(uid),
            name: 'x',
            firestoreOverride: db,
            currentUidOverride: uid,
          ),
        ));
        await settle(tester, 5);
      }

      bigSurface(tester);
      await pumpHub('uidAdmin');
      expect(find.text('Repair & Service Settings'), findsOneWidget);

      await pumpHub('uidTech');
      expect(find.text('Repair & Service Settings'), findsNothing);
    });
  });
}
