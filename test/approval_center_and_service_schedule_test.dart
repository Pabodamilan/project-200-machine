// Tests for:
// - ApprovalCenterScreen (lib/main.dart) — the single management entry
//   point merging the old Final Approval / Service Approvals tiles into
//   one screen with a REPAIRS tab and a SERVICE tab, each tab title
//   showing a red count badge.
// - The Service km/milestone scheduling pure functions (computeNextMilestone,
//   computeScheduleStatus) — RED/AMBER/GREEN transitions around a
//   milestone with warnBeforeKm, the next milestone after an approval,
//   and the KM_UNKNOWN state.
// - The manual current-km fallback (logManualKm / fetchBestKnownKm /
//   showManualKmEntryDialog) added as the "km unknown — enter current km"
//   quick entry point.
//
// Widget tests run with the real AppTheme.light() at both a narrow phone
// width and a wide desktop width, asserting tester.takeException() is
// null — same convention as the rest of this app's widget tests. The
// pure-function tests need no widget pump at all.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  group('computeNextMilestone / computeScheduleStatus (pure)', () {
    const intervalKm = 10000.0;
    const warnBeforeKm = 1000.0;
    final now = DateTime(2026, 10, 30);

    ServiceItemDue statusAt(double? currentKm, {Set<int> completed = const {}}) {
      return computeScheduleStatus(
        scheduleId: 'sch1',
        scheduleName: 'Oil Change',
        intervalKm: intervalKm,
        warnBeforeKm: warnBeforeKm,
        approvedRecords: completed
            .map((k) => {'milestoneKm': (k * intervalKm), 'serviceDate': now})
            .toList(),
        currentKm: currentKm,
        now: now,
      );
    }

    test('GREEN (OK) well before the warnBeforeKm window', () {
      final d = statusAt(5000); // 5000km to the 10000km milestone
      expect(d.status, ServiceItemDueStatus.ok);
    });

    test('AMBER (DUE_SOON) once within warnBeforeKm of the milestone', () {
      final d = statusAt(9500); // 500km to go, <= warnBeforeKm(1000)
      expect(d.status, ServiceItemDueStatus.dueSoon);
    });

    test('RED (OVERDUE) at and just past the milestone', () {
      expect(statusAt(10000).status, ServiceItemDueStatus.overdue);
      expect(statusAt(10500).status, ServiceItemDueStatus.overdue);
    });

    test('RED (MISSED) once overshot by a whole extra interval', () {
      final d = statusAt(21000); // a full interval past the 10000km milestone
      expect(d.status, ServiceItemDueStatus.missed);
    });

    test(
      'next milestone after an approved record = previous milestone + '
      'intervalKm, and the vehicle is GREEN again until the next warning '
      'window',
      () {
        // Milestone 1 (10000km) already approved — next due is milestone 2.
        final d = statusAt(15000, completed: {1});
        expect(d.milestoneNumber, 2);
        expect(d.milestoneKm, 20000.0); // 10000 (previous) + 10000 (intervalKm)
        expect(d.status, ServiceItemDueStatus.ok); // green, 5000km still to go
      },
    );

    test(
      'KM_UNKNOWN when currentKm is null — never silently defaults to '
      'green or red',
      () {
        final d = statusAt(null);
        expect(d.status, ServiceItemDueStatus.kmUnknown);
      },
    );
  });

  group('manual km fallback (fetchBestKnownKm / logManualKm, pure async)', () {
    test(
      'unknown with nothing recorded for the vehicle, then picks up a '
      'manually entered km',
      () async {
        final firestore = FakeFirebaseFirestore();
        // No matching trucks doc at all -> _fetchLiveKmForVehicle returns
        // null immediately (no GPS/Traccar call attempted), and no
        // service_records/manual_km_logs exist yet either.
        final before = await fetchBestKnownKm('WP-9999', db: firestore);
        expect(before.km, isNull);
        expect(before.source, contains('unknown'));

        await logManualKm(
          db: firestore,
          vehicleNumber: 'WP-9999',
          km: 45230,
          uid: 'uidTech',
          userName: 'Tina Technical',
        );

        final after = await fetchBestKnownKm('WP-9999', db: firestore);
        expect(after.km, 45230.0);
        expect(after.source, contains('manually entered'));
      },
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<void> setSurface(WidgetTester tester, Size size) async {
    final originalSize = tester.view.physicalSize;
    final originalRatio = tester.view.devicePixelRatio;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.physicalSize = originalSize;
      tester.view.devicePixelRatio = originalRatio;
    });
  }

  Future<FakeFirebaseFirestore> fixtureForApprovalCenter() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('users').doc('uidAdmin').set({
      'name': 'Admin Alice',
      'role': 'admin',
    });
    await firestore.collection('repairs').doc('r1').set({
      'code': 'NOD-ENG-0001',
      'vehicleNumber': 'WP-1111',
      'status': RepairItemStatus.donePendingApproval,
      'description': 'Oil leak',
    });
    await firestore.collection('repairs').doc('r2').set({
      'code': 'NOD-BRK-0002',
      'vehicleNumber': 'WP-1111',
      'status': RepairItemStatus.donePendingApproval,
      'description': 'Brake pads worn',
    });
    await firestore.collection('service_records').doc('s1').set({
      'recordNo': 'SR-0001',
      'vehicleNumber': 'WP-2222',
      'status': ServiceRecordStatus.submitted,
      'garageName': 'Acme Garage',
      'totalPriceCents': 10000,
    });
    return firestore;
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'ApprovalCenterScreen: REPAIRS and SERVICE tab badges show the '
      'correct counts, and each tab shows its own body, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureForApprovalCenter();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ApprovalCenterScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('REPAIRS'), findsOneWidget);
        expect(find.text('SERVICE'), findsOneWidget);
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text('2')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: find.byType(TabBar), matching: find.text('1')),
          findsOneWidget,
        );

        // REPAIRS tab body shows by default.
        expect(find.text('Final Approval'), findsOneWidget);

        await tester.tap(find.text('SERVICE'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Service Approvals'), findsOneWidget);
      },
    );

    testWidgets(
      'showManualKmEntryDialog: SAVE writes manual_km_logs with '
      'vehicleNumber/km/enteredBy, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showManualKmEntryDialog(
                  context,
                  vehicleNumber: 'WP-9999',
                  firestoreOverride: firestore,
                  currentUidOverride: 'uidTech',
                ),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.text('OPEN'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Enter Current KM — WP-9999'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '45230');
        await settle(tester);
        await tester.tap(find.text('SAVE'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final logsSnap = await firestore.collection('manual_km_logs').get();
        expect(logsSnap.docs.length, 1);
        final data = logsSnap.docs.first.data();
        expect(data['vehicleNumber'], 'WP-9999');
        expect(data['km'], 45230.0);
        expect(data['enteredBy'], 'uidTech');
        expect(data['enteredByName'], 'Tina Technical');
      },
    );
  }
}
