// Tests for ManageAccessScreen (the restricted 'Manage Access' surface for
// role 'management', also reachable by admin/owner) and the supporting
// RepairPermissionsEditor.allowedKeys restriction.
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

Future<FakeFirebaseFirestore> _fixture() async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidAdmin').set({
    'name': 'Admin Alice',
    'role': 'admin',
  });
  await firestore.collection('users').doc('uidOwner').set({
    'name': 'Owner Oscar',
    'role': 'owner',
  });
  await firestore.collection('users').doc('uidManager').set({
    'name': 'Manager Mary',
    'role': 'management',
    'repairPermissions': [kPermApprove, kPermHistoryView],
  });
  await firestore.collection('users').doc('uidTech').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'canAccessGarage': false,
    'canAccessWarehouse': false,
    'repairPermissions': [kPermHistoryView],
  });
  await firestore.collection('users').doc('uidSupervisor').set({
    'name': 'Sam Supervisor',
    'role': 'supervisor',
    // Already granted, so this row shows REVOKE GARAGE — keeps "GRANT
    // GARAGE" unambiguous (Tina Technical's row only) for the write test.
    'canAccessGarage': true,
  });
  return firestore;
}

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

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'ManageAccessScreen: list excludes admin, owner and the signed-in '
      'management user themselves, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ManageAccessScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManager',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // Shown: technical + supervisor.
        expect(find.text('Tina Technical'), findsOneWidget);
        expect(find.text('Sam Supervisor'), findsOneWidget);
        // Never shown: admin, owner, or the signed-in manager themselves.
        expect(find.text('Admin Alice'), findsNothing);
        expect(find.text('Owner Oscar'), findsNothing);
        expect(find.text('Manager Mary'), findsNothing);
      },
    );

    testWidgets(
      'ManageAccessScreen: a non-management, non-admin/owner user sees '
      'NO ACCESS, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ManageAccessScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidSupervisor',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ACCESS'), findsOneWidget);
      },
    );

    testWidgets(
      'ManageAccessScreen: GRANT GARAGE writes only canAccessGarage, no '
      'other field, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ManageAccessScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManager',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('GRANT GARAGE'), findsWidgets);
        await tester.tap(find.text('GRANT GARAGE').first);
        await settle(tester);
        expect(tester.takeException(), isNull);
        // Confirm dialog — tap the confirm action.
        await tester.tap(find.widgetWithText(ElevatedButton, 'Grant'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final techDoc = await firestore.collection('users').doc('uidTech').get();
        final data = techDoc.data()!;
        expect(data['canAccessGarage'], isTrue);
        // Untouched by this write — proves only the one field was sent.
        expect(data['canAccessWarehouse'], isFalse);
        expect(data['repairPermissions'], [kPermHistoryView]);
        expect(data.containsKey('updatedAt'), isFalse);
      },
    );

    testWidgets(
      'RepairPermissionsEditor: allowedKeys restricts which keys a '
      "management granter can toggle, and never drops a key the target "
      'already has that the granter lacks (shown locked), no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final editorKey = GlobalKey<RepairPermissionsEditorState>();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepairPermissionsEditor(
                key: editorKey,
                // Target already has REPAIR_WORK (not held by the granter
                // below) plus HISTORY_VIEW (held by the granter).
                initialPermissions: const {kPermRepairWork, kPermHistoryView},
                // Granter (a 'management' user) only holds APPROVE and
                // HISTORY_VIEW themselves.
                allowedKeys: const {kPermApprove, kPermHistoryView},
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        // REPAIR_WORK is locked: still selected (not silently dropped)...
        expect(editorKey.currentState!.selected, contains(kPermRepairWork));
        // ...and its checkbox cannot be unticked (onChanged is null).
        final repairWorkTile = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'REPAIR WORK'),
        );
        expect(repairWorkTile.value, isTrue);
        expect(repairWorkTile.onChanged, isNull);

        // APPROVE is grantable (in allowedKeys) but not yet selected —
        // toggling it on must work normally.
        final approveTileBefore = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'APPROVE'),
        );
        expect(approveTileBefore.onChanged, isNotNull);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'APPROVE'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(editorKey.currentState!.selected, contains(kPermApprove));

        // A key outside allowedKeys that the target never had (e.g.
        // REPORT_DEFECT) stays disabled and unchecked throughout.
        final reportDefectTile = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'REPORT DEFECT'),
        );
        expect(reportDefectTile.value, isFalse);
        expect(reportDefectTile.onChanged, isNull);

        // CLEAR ALL must still keep the locked key.
        await tester.tap(find.text('CLEAR ALL'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(editorKey.currentState!.selected, {kPermRepairWork});
      },
    );

    testWidgets(
      'ManageUsersScreen: Apply Technical Defaults dialog describes the '
      'CURRENT technicalDefaults() keys, not the old 8-key set, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'repairPermissions': <String>[],
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: ManageUsersScreen(firestoreOverride: firestore),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        await tester.tap(find.byTooltip('Apply Technical Defaults'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(
          find.textContaining(
            'Repair Work, History View, Do Service, Service View',
          ),
          findsOneWidget,
        );
        // The stale old-flow wording must be gone.
        expect(find.textContaining('Defect Queue'), findsNothing);
        expect(find.textContaining('Diagnose'), findsNothing);
        expect(find.textContaining('Repair Jobs'), findsNothing);
        expect(find.textContaining('Garages'), findsNothing);
      },
    );
  }
}
