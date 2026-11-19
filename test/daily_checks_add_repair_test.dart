// Widget test for Step 2 of the Truck Repair v2 rewire: DailyChecksScreen's
// LOW-row "REPORT DEFECT" button is now "ADD REPAIR", opening AddRepairScreen
// prefilled with the matching repair category (water -> COL, engine oil ->
// ENG, hydraulic oil -> HYD) and a 'LOW <component> level (daily check)'
// description. Run with the real AppTheme.light() at both a narrow phone
// width and a wide desktop width, asserting tester.takeException() is null
// — same convention as the rest of this app's widget tests.
//
// Note: the Vehicle Inspection tabs' own ADD REPAIR entry point and
// TruckProfileScreen's Repair History navigation are NOT covered here —
// neither screen has a firestoreOverride/currentUidOverride test seam (a
// pre-existing condition, not something this step added), so exercising
// them in a widget test would hit the real FirebaseFirestore.instance with
// no fake backing it and risk hanging rather than failing cleanly. Verified
// those two by code review plus flutter analyze/test/build instead — see
// this step's report.
import 'package:cloud_firestore/cloud_firestore.dart';
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

  Future<FakeFirebaseFirestore> fixtureWithLowCheck() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('users').doc('uidAdmin').set({
      'name': 'Admin Alice',
      'role': 'admin',
    });
    final todayKey = dailyCheckDateKey(DateTime.now());
    await firestore.collection('daily_checks').doc('check1').set({
      'date': todayKey,
      'vehicleNumber': 'WP-1234',
      'driverName': 'Driver Dan',
      'hasLow': true,
      'submittedAt': Timestamp.now(),
      'checks': [
        {'id': 'water_level', 'label': 'Water Level', 'status': 'LOW', 'note': ''},
      ],
    });
    await firestore.collection('repair_categories').doc('COL').set({
      'code': 'COL',
      'name': 'Cooling system and radiator',
      'sortOrder': 0,
      'active': true,
    });
    return firestore;
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'DailyChecksScreen: a LOW water level row shows ADD REPAIR, opening '
      'AddRepairScreen prefilled with category COL, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureWithLowCheck();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DailyChecksScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('ADD REPAIR'), findsOneWidget);

        await tester.tap(find.text('ADD REPAIR'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // AddRepairScreen opened with the category pre-selected and the
        // description pre-filled — both still editable, nothing auto-saved.
        expect(find.textContaining('COL — Cooling system and radiator'), findsOneWidget);
        expect(find.text('LOW water level (daily check)'), findsOneWidget);
      },
    );

    testWidgets(
      'DailyChecksScreen: no LOW checks today -> no ADD REPAIR button, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: DailyChecksScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('ADD REPAIR'), findsNothing);
      },
    );
  }
}
