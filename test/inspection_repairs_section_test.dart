// Tests for InspectionRepairsSection (lib/main.dart) — the "REPAIRS FOUND"
// section that sits at the bottom of all 4 Vehicle Inspection tabs (daily
// new/records, weekly new/records), just above the SAVE/SUBMIT button (or,
// for the read-only Records dialogs, just above the "Submitted by" footer).
// Pumped directly (it's public specifically so tests can do this) rather
// than through a full tab, since the real vehicle-number picker bottom
// sheet has no test seam.
//
// Covers the section's 4 states: no vehicle picked yet, a vehicle picked
// but the user lacks REPORT_DEFECT, a vehicle picked with repairs already
// logged against this inspection, and AddRepairScreen's "no repair
// categories yet" message (opened via the section's ADD REPAIR button).
//
// Run with the real AppTheme.light() at both a narrow phone width and a
// wide desktop width, asserting tester.takeException() is null — same
// convention as the rest of this app's widget tests.
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

  Future<FakeFirebaseFirestore> fixtureWithCategory() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('users').doc('uidInspector').set({
      'name': 'Ian Inspector',
      'role': 'technical',
      'repairPermissions': [kPermReportDefect],
    });
    await firestore.collection('users').doc('uidNoPerm').set({
      'name': 'Nora NoPerm',
      'role': 'technical',
      'repairPermissions': <String>[],
    });
    await firestore.collection('repair_categories').doc('ENG').set({
      'code': 'ENG',
      'name': 'Engine',
      'sortOrder': 0,
      'active': true,
    });
    return firestore;
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'InspectionRepairsSection: no vehicle picked yet shows a disabled '
      "'Select a vehicle first' button and no ADD REPAIR, no layout "
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureWithCategory();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: InspectionRepairsSection(
              userName: 'Ian Inspector',
              vehicleNumber: null,
              inspectionId: null,
              firestoreOverride: firestore,
              currentUidOverride: 'uidInspector',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('REPAIRS FOUND'), findsOneWidget);
        expect(find.text('Select a vehicle first'), findsOneWidget);
        expect(find.text('ADD REPAIR'), findsNothing);

        final button = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('Select a vehicle first'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(button.onPressed, isNull);
      },
    );

    testWidgets(
      'InspectionRepairsSection: a vehicle is picked but the user lacks '
      'REPORT_DEFECT -> "No permission to add repairs" text, no ADD REPAIR '
      'button, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureWithCategory();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: InspectionRepairsSection(
              userName: 'Nora NoPerm',
              vehicleNumber: 'WP-1234',
              inspectionId: 'WP-1234_2026-10-30',
              firestoreOverride: firestore,
              currentUidOverride: 'uidNoPerm',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(
          find.text('No permission to add repairs - ask admin'),
          findsOneWidget,
        );
        expect(find.text('ADD REPAIR'), findsNothing);
        expect(find.text('Select a vehicle first'), findsNothing);
      },
    );

    testWidgets(
      'InspectionRepairsSection: a REPORT_DEFECT holder sees a full-width '
      'ADD REPAIR button (opening AddRepairScreen) plus the list of repairs '
      'already logged for this inspection, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixtureWithCategory();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD-ENG-0001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'inspectionId': 'WP-1234_2026-10-30',
          'description': 'Oil leak near the sump',
          'status': 'REPORTED',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: InspectionRepairsSection(
              userName: 'Ian Inspector',
              vehicleNumber: 'WP-1234',
              inspectionId: 'WP-1234_2026-10-30',
              firestoreOverride: firestore,
              currentUidOverride: 'uidInspector',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('ADD REPAIR'), findsOneWidget);
        expect(find.textContaining('NOD-ENG-0001'), findsOneWidget);
        expect(find.textContaining('Oil leak near the sump'), findsOneWidget);

        final addRepairButton = tester.widget<OutlinedButton>(
          find.ancestor(
            of: find.text('ADD REPAIR'),
            matching: find.byType(OutlinedButton),
          ),
        );
        expect(addRepairButton.onPressed, isNotNull);

        await tester.tap(find.text('ADD REPAIR'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Add Repair — WP-1234'), findsOneWidget);
      },
    );

    testWidgets(
      'AddRepairScreen: empty repair_categories shows the seed-defaults '
      'message instead of an empty category picker, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidInspector').set({
          'name': 'Ian Inspector',
          'role': 'technical',
          'repairPermissions': [kPermReportDefect],
        });
        // repair_categories deliberately left empty.
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: AddRepairScreen(
            userName: 'Ian Inspector',
            vehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidInspector',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('NO REPAIR CATEGORIES YET'), findsOneWidget);
        expect(
          find.textContaining(
            'ASK ADMIN TO OPEN REPAIR CATEGORIES AND TAP SEED DEFAULT '
            'CATEGORIES',
          ),
          findsOneWidget,
        );
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      },
    );
  }
}
