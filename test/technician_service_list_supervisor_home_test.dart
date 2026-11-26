// (A) Technical home Service list: every company truck (12-truck fixture),
//     overdue -> due soon -> up to date order, tap -> the existing
//     service-do flow (ServiceRecordFormScreen).
// (B) Android-only compact UI: kMobileUiScale text scaler (system scale
//     clamped to 1.0), compact theme, touch targets >= 40dp, no overflow.
// (C) Supervisor home: chooser only when the user has more than one real
//     access, selection remembered, Switch back to the chooser.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/app_theme.dart';
import 'package:project_200_machine/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Alphabetical order (1001..1012) is deliberately the REVERSE of the
// expected status order, so the test proves sorting by status.
const _ok = ['WP-1001', 'WP-1002', 'WP-1003', 'WP-1004', 'WP-1005', 'WP-1006'];
const _dueSoon = ['WP-1007', 'WP-1008', 'WP-1009'];
const _overdue = ['WP-1010', 'WP-1011', 'WP-1012'];

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
  Future<void> truck(String n, double km) async {
    await db.collection('trucks').doc(n).set({'truckNumber': n, 'isCompanyTruck': true});
    await db.collection('service_records').doc('km-$n').set({
      'vehicleNumber': n,
      'status': 'APPROVED',
      'currentKm': km,
      'serviceDate': Timestamp.fromDate(DateTime(2026, 1, 1)),
    });
  }

  for (final n in _ok) {
    await truck(n, 1000);
  }
  for (final n in _dueSoon) {
    await truck(n, 44500); // within warnBeforeKm of 45,000
  }
  for (final n in _overdue) {
    await truck(n, 46000);
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

  Widget card(FakeFirebaseFirestore db) => SingleChildScrollView(
        child: TechnicalHomeServiceCard(
          name: 'Tina Technical',
          firestoreOverride: db,
          currentUidOverride: 'uidTech',
        ),
      );

  group('(A) Technical home Service list', () {
    test('technical default permissions include SERVICE_DO', () {
      expect(technicalDefaults().repairPermissions, contains(kPermServiceDo));
      expect(kRepairPermPresets['TECHNICAL'], contains(kPermServiceDo));
    });

    test('buildTechnicalServiceRows keeps every truck, worst first', () {
      ServiceAlert due(String v, String sev, {double? over}) => ServiceAlert(
            kind: ServiceAlertKind.serviceDue,
            severity: sev,
            audience: ServiceAlertAudience.mechanic,
            vehicleNumber: v,
            title: 's',
            detail: '',
            overByKm: over,
          );
      final rows = buildTechnicalServiceRows(
        truckNumbers: ['A', 'B', 'C', 'D', 'E', ''],
        alerts: [
          due('D', ServiceAlertSeverity.dueSoon),
          due('C', ServiceAlertSeverity.overdue, over: 100),
          due('E', ServiceAlertSeverity.overdue, over: 900),
          // A second, milder alert for E must not replace its worst one.
          due('E', ServiceAlertSeverity.dueSoon),
        ],
      );
      expect(rows.map((r) => r.vehicleNumber), ['E', 'C', 'D', 'A', 'B']);
      expect(rows.first.alert?.severity, ServiceAlertSeverity.overdue);
      expect(rows.last.alert, isNull);
    });

    testWidgets('12 trucks: all listed, overdue then due soon on top, tap -> '
        'service form', (tester) async {
      surface(tester, const Size(1400, 4000));
      final db = await _fleet();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: card(db)),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      // List defaults to "Needs service"; All shows every truck.
      await tester.tap(find.byKey(const ValueKey('technical-service-status-all')));
      await settle(tester, 5);

      final order = [..._overdue, ..._dueSoon, ..._ok];
      final tops = <double>[];
      for (final n in order) {
        final row = find.byKey(ValueKey('technical-service-row-$n'));
        expect(row, findsOneWidget, reason: n);
        tops.add(tester.getTopLeft(row).dy);
      }
      expect(tops, orderedEquals([...tops]..sort()), reason: 'worst first');
      expect(find.textContaining('OVERDUE BY'), findsNWidgets(_overdue.length));
      expect(find.textContaining('DUE IN'), findsNWidgets(_dueSoon.length));
      expect(find.text('UP TO DATE'), findsNWidgets(_ok.length));
      expect(find.text('VIEW ALL (12 TRUCKS)'), findsOneWidget);

      // Even an up-to-date truck can be serviced from the list.
      final last = find.byKey(const ValueKey('technical-service-row-WP-1006'));
      await tester.ensureVisible(last); // inside the card's scrolling list
      await tester.pump();
      await tester.tap(last);
      await settle(tester, 15);
      expect(tester.takeException(), isNull);
      final form = tester.widget<ServiceRecordFormScreen>(
        find.byType(ServiceRecordFormScreen),
      );
      expect(form.vehicleNumber, 'WP-1006');
    });

    testWidgets('tap on an overdue truck preselects its due schedule', (
      tester,
    ) async {
      surface(tester, const Size(1400, 4000));
      final db = await _fleet();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: card(db)),
      ));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('technical-service-row-WP-1010')));
      await settle(tester, 15);
      expect(tester.takeException(), isNull);
      final form = tester.widget<ServiceRecordFormScreen>(
        find.byType(ServiceRecordFormScreen),
      );
      expect(form.vehicleNumber, 'WP-1010');
      expect(form.preselectScheduleId, 'sched1');
    });
  });

  group('(B) Android compact UI', () {
    test('kMobileUiScale value and text scaler clamp', () {
      expect(kMobileUiScale, 0.9);
      double f(double system) =>
          compactMobileTextScaler(TextScaler.linear(system)).scale(100) / 100;
      expect(f(1.0), closeTo(0.9, 1e-9));
      expect(f(1.3), closeTo(0.9, 1e-9)); // large system size clamped to 1.0
      expect(f(0.8), closeTo(0.72, 1e-9)); // smaller system size respected
    });

    test('Android app only — never web, iOS or desktop', () {
      expect(isCompactMobileUi(isWeb: false, platform: TargetPlatform.android), isTrue);
      expect(isCompactMobileUi(isWeb: true, platform: TargetPlatform.android), isFalse);
      expect(isCompactMobileUi(isWeb: false, platform: TargetPlatform.iOS), isFalse);
      expect(isCompactMobileUi(isWeb: true, platform: TargetPlatform.macOS), isFalse);
      final web = AppTheme.light(compact: false);
      expect(web.visualDensity, isNot(VisualDensity.compact));
      expect(web.iconTheme.size, isNot(kMobileIconSize));
      final android = AppTheme.light(compact: true);
      expect(android.visualDensity, VisualDensity.compact);
      expect(android.iconTheme.size, kMobileIconSize);
      expect(android.materialTapTargetSize, MaterialTapTargetSize.padded);
    });

    testWidgets('MobileUiScale scales text on Android, not on web', (
      tester,
    ) async {
      Future<double> factorWith({required bool isWeb}) async {
        late double factor;
        await tester.pumpWidget(MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: MobileUiScale(
            isWebOverride: isWeb,
            platformOverride: TargetPlatform.android,
            child: Builder(builder: (context) {
              factor = MediaQuery.textScalerOf(context).scale(100) / 100;
              return const SizedBox();
            }),
          ),
        ));
        return factor;
      }

      expect(await factorWith(isWeb: false), closeTo(0.9, 1e-9));
      expect(await factorWith(isWeb: true), closeTo(1.3, 1e-9));
    });

    testWidgets('compact theme keeps touch targets >= 40dp', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(compact: true),
        home: Scaffold(
          body: Column(children: [
            ElevatedButton(onPressed: () {}, child: const Text('E')),
            OutlinedButton(onPressed: () {}, child: const Text('O')),
            TextButton(onPressed: () {}, child: const Text('T')),
            IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            ListTile(title: const Text('L'), onTap: () {}),
          ]),
        ),
      ));
      for (final type in [ElevatedButton, OutlinedButton, TextButton, IconButton, ListTile]) {
        final size = tester.getSize(find.byType(type));
        expect(size.height, greaterThanOrEqualTo(40), reason: '$type');
      }
    });

    testWidgets('Android phone (360x640, system text 1.3): Service list and '
        'TechnicalHomeScreen render with no overflow', (tester) async {
      surface(tester, const Size(360, 640));
      final db = await _fleet();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(compact: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: MobileUiScale(
            isWebOverride: false,
            platformOverride: TargetPlatform.android,
            child: child!,
          ),
        ),
        home: TechnicalHomeScreen(
          name: 'Tina Technical',
          firestoreOverride: db,
          currentUidOverride: 'uidTech',
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('SERVICE (12)'), findsOneWidget);
      expect(find.byKey(const ValueKey('technical-service-row-WP-1010')), findsOneWidget);
    });
  });

  group('(C) Supervisor home', () {
    Widget dest(String d) => Scaffold(
          appBar: AppBar(
            title: Text('DEST $d'),
            actions: const [SupervisorSwitchButton(color: Colors.black)],
          ),
        );

    Future<void> pumpHome(WidgetTester tester, Map<String, dynamic> data) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: SupervisorHome(
          name: 'Sam Supervisor',
          userData: data,
          uid: 'uidSup',
          destinationBuilderOverride: dest,
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    test('destinations are only the accesses the user already has', () {
      expect(resolveSupervisorDestinations({'role': 'supervisor'}),
          [SupervisorDestination.site]);
      expect(
        resolveSupervisorDestinations({
          'role': 'supervisor',
          'canAccessFuel': true,
          'canAccessGarage': true,
          'canAccessWarehouse': true,
        }),
        [
          SupervisorDestination.site,
          SupervisorDestination.fuel,
          SupervisorDestination.garage,
          SupervisorDestination.warehouse,
        ],
      );
      // No flag can produce an admin destination.
      expect(
        resolveSupervisorDestinations({
          'role': 'supervisor',
          'canAccessAdmin': true,
          'canEditReports': true,
        }),
        [SupervisorDestination.site],
      );
    });

    testWidgets('Site + Garage: chooser shown, selection opens that home, is '
        'remembered, Switch returns to the chooser', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await pumpHome(tester, {'role': 'supervisor', 'canAccessGarage': true});

      expect(find.byKey(const ValueKey('supervisor-choice-SITE')), findsOneWidget);
      expect(find.byKey(const ValueKey('supervisor-choice-GARAGE')), findsOneWidget);
      expect(find.byKey(const ValueKey('supervisor-choice-FUEL')), findsNothing);
      expect(find.textContaining('Admin'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('supervisor-choice-GARAGE')));
      await tester.pumpAndSettle();
      expect(find.text('DEST GARAGE'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(supervisorHomeChoicePrefKey('uidSup')),
          SupervisorDestination.garage);

      await tester.tap(find.byKey(const ValueKey('supervisor-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('supervisor-choice-SITE')), findsOneWidget);
      expect(prefs.getString(supervisorHomeChoicePrefKey('uidSup')), isNull);

      await tester.tap(find.byKey(const ValueKey('supervisor-choice-SITE')));
      await tester.pumpAndSettle();
      expect(find.text('DEST SITE'), findsOneWidget);
    });

    testWidgets('remembered choice opens directly; a choice whose access was '
        'removed is ignored', (tester) async {
      SharedPreferences.setMockInitialValues({
        supervisorHomeChoicePrefKey('uidSup'): SupervisorDestination.fuel,
      });
      await pumpHome(tester, {'role': 'supervisor', 'canAccessFuel': true});
      expect(find.text('DEST FUEL'), findsOneWidget);
      expect(find.byKey(const ValueKey('supervisor-switch')), findsOneWidget);

      SharedPreferences.setMockInitialValues({
        supervisorHomeChoicePrefKey('uidSup'): SupervisorDestination.warehouse,
      });
      await tester.pumpWidget(const SizedBox());
      await pumpHome(tester, {'role': 'supervisor', 'canAccessFuel': true});
      expect(find.text('DEST WAREHOUSE'), findsNothing);
      expect(find.byKey(const ValueKey('supervisor-choice-FUEL')), findsOneWidget);
    });

    testWidgets('only one access: no chooser, no Switch, straight to Site', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      await pumpHome(tester, {'role': 'supervisor'});
      expect(find.text('DEST SITE'), findsOneWidget);
      expect(find.byKey(const ValueKey('supervisor-choice-SITE')), findsNothing);
      expect(find.byKey(const ValueKey('supervisor-switch')), findsNothing);
    });
  });
}
