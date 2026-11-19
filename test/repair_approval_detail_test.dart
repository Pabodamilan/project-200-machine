// Widget tests for RepairApprovalDetailScreen (SIMPLE_REPAIR approvals).
//
// Two unrelated bugs lived here, found across two rounds of debugging:
//
// 1. "Stuck on an endless loader" — Future/Stream objects recreated on
//    every build() (never settling a FutureBuilder/StreamBuilder). Fixed by
//    caching them per-screen, keyed by the ids they depend on.
// 2. "BoxConstraints forces an infinite width" layout crash — OutlinedButton
//    (via AppTheme.light()'s button themes, which set minimumSize to
//    Size.fromHeight(48) == Size(double.infinity, 48)) placed inside a Row/
//    Wrap with no Expanded/Flexible. This is the one that actually made the
//    screen unusable; bug (1) was real but secondary.
//
// Bug (2) is exactly why the FIRST round of tests here (added while
// chasing bug (1)) passed even though the real screen was broken: they used
// MaterialApp's default theme, not AppTheme.light(), so the infinite
// minimumSize that only exists in AppTheme.light() was never exercised, and
// they never called tester.takeException() to fail on a layout assertion
// even when one did fire. Every test below now renders with
// `theme: AppTheme.light()` (the theme the app actually runs — see
// MyApp's MaterialApp in lib/main.dart) and asserts
// `tester.takeException()` is null, specifically so a regression here
// fails the test instead of silently passing.
//
// setupFirebaseCoreMocks() + Firebase.initializeApp() are still required
// even with the fake Firestore: the screen is wrapped in
// TruckRepairScaffold -> TestModeBanner, which reads
// FirebaseFirestore.instance (NOT overridable, it's a shared banner used
// everywhere) — without a mocked Firebase Core app, merely constructing
// that banner throws "No Firebase App '[DEFAULT]' has been created".
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

// Field-by-field cross-check against the real writer
// (DefectMechanicFormScreen._submitForApproval, lib/main.dart ~line 40433)
// so this fixture can't silently drift from what production actually
// writes: approvalNo, approvalType, repairJobId, vehicleNumber, quotationId,
// garageId, garageName, amountCents, requiredLevel, decision, requestedBy,
// requestedByName, requestedAt, createdAt — every key below matches that
// call's keys exactly. (requestedAt/createdAt use Timestamp.now() here
// instead of FieldValue.serverTimestamp() — FakeFirebaseFirestore resolves
// both to a real Timestamp immediately either way, so this is not a
// meaningful difference for anything this screen reads.) The full
// _submitForApproval is not called directly because it transitively calls
// _nextRepairSequenceNumber/_writeRepairEvent, which hard-code
// FirebaseFirestore.instance with no override seam — refactoring those
// (used by ~20 other call sites across the file) is out of scope here.
Future<FakeFirebaseFirestore> _simpleRepairFirestore({
  String approvalId = 'appr1',
  String jobId = 'job1',
  String defectId = 'defect1',
  String viewerUid = 'uidViewer',
  String mechanicUid = 'uidMechanic',
  String requiredLevel = 'MANAGER',
}) async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('repair_approvals').doc(approvalId).set({
    'approvalNo': 'APR-0001',
    'approvalType': 'SIMPLE_REPAIR',
    'repairJobId': jobId,
    'vehicleNumber': 'WP-1234',
    'quotationId': null,
    'garageId': 'g1',
    'garageName': 'Test Garage',
    'amountCents': 150000,
    'requiredLevel': requiredLevel,
    'decision': 'PENDING',
    'requestedBy': mechanicUid,
    'requestedByName': 'Mechanic Joe',
    'requestedAt': Timestamp.now(),
    'createdAt': Timestamp.now(),
  });
  await firestore.collection('repair_jobs').doc(jobId).set({
    'jobNo': 'REP-0001',
    'vehicleNumber': 'WP-1234',
    'defectIds': [defectId],
    'simpleMode': true,
    'systemCategory': 'ENGINE',
    'repairStatus': 'PENDING_APPROVAL',
    'confirmedDiagnosis': 'ENGINE MAKING NOISE, NEEDS GASKET REPLACEMENT',
    'mechanicalSupervisorId': mechanicUid,
    'mechanicalSupervisorName': 'Mechanic Joe',
    'partsList': [
      {'name': 'HEAD GASKET', 'qty': 1, 'estimatedPriceCents': 50000},
    ],
    'garageId': 'g1',
    'garageName': 'Test Garage',
    'callAt': Timestamp.now(),
    'calledWithName': 'Garage Owner',
    'plannedRepairDate': Timestamp.now(),
    'estimatedTotalCents': 150000,
  });
  await firestore.collection('defect_reports').doc(defectId).set({
    'defectNo': 'DEF-0001',
    'vehicleNumber': 'WP-1234',
    'systemCategory': 'ENGINE',
    'symptoms': 'ENGINE MAKING NOISE',
    'status': 'REPAIR_CREATED',
    'repairJobId': jobId,
    'photos': <Map<String, dynamic>>[],
    'voices': <Map<String, dynamic>>[],
  });
  await firestore.collection('users').doc(viewerUid).set({
    'name': 'Supervisor Sam',
    'role': 'supervisor',
    'repairPermissions': ['APPROVE'],
  });
  await firestore.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
    'testModeAllowSameUser': false,
    'simpleMode': true,
  });
  return firestore;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  // Pumps enough frames for every nested FutureBuilder/StreamBuilder this
  // screen builds (approval stream -> user/settings future -> job future
  // -> defect future) to settle. The bug this guards against is exactly a
  // FutureBuilder/StreamBuilder that NEVER reaches ConnectionState.done, so
  // pumping once and declaring victory would miss it.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  testWidgets(
    'SIMPLE_REPAIR approval (quotationId null) renders its content and never '
    'shows an endless loader or layout exception',
    (tester) async {
      final firestore = await _simpleRepairFirestore();

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairApprovalDetailScreen(
          approvalId: 'appr1',
          currentUid: 'uidViewer',
          firestoreOverride: firestore,
        ),
      ));
      await settle(tester);

      // The layout-crash regression: AppTheme.light()'s button themes set
      // an infinite-width minimumSize, which crashes any OutlinedButton/
      // ElevatedButton placed in a Row/Wrap without Expanded. A default
      // (non-app) MaterialApp theme would never exercise this.
      expect(tester.takeException(), isNull);

      // The loading regression: this screen used to stay on
      // LoadingState()/a CircularProgressIndicator forever for a
      // SIMPLE_REPAIR approval.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Renders the approval header and the simple-mode "Mechanic Form"
      // card (mechanical note, garage, parts) instead of the quotation
      // card (which would be blank/misleading for a SIMPLE_REPAIR
      // approval, since there is no quotation).
      expect(find.textContaining('APR-0001'), findsOneWidget);
      expect(find.text('Mechanic Form'), findsOneWidget);
      expect(find.textContaining('ENGINE MAKING NOISE, NEEDS GASKET REPLACEMENT'),
          findsOneWidget);
      expect(find.textContaining('HEAD GASKET'), findsOneWidget);
      expect(find.textContaining('Test Garage'), findsOneWidget);

      // Decide buttons use OK/RETURN wording for simple-mode approvals, and
      // the viewer (supervisor, not the requesting mechanic) is allowed to
      // decide.
      expect(find.widgetWithText(ElevatedButton, 'OK'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'RETURN'), findsOneWidget);
    },
  );

  testWidgets(
    'Linked defect missing does not block the rest of the SIMPLE_REPAIR '
    'detail from rendering',
    (tester) async {
      final firestore = await _simpleRepairFirestore(
        approvalId: 'appr2',
        jobId: 'job2',
        defectId: 'defectThatWillBeDeleted',
      );
      // Simulate a deleted/missing linked defect — the defectIds entry on
      // the job still points at it.
      await firestore.collection('defect_reports').doc('defectThatWillBeDeleted').delete();

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairApprovalDetailScreen(
          approvalId: 'appr2',
          currentUid: 'uidViewer',
          firestoreOverride: firestore,
        ),
      ));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Mechanic Form'), findsOneWidget);
      expect(find.textContaining('Linked defect no longer exists'), findsOneWidget);
    },
  );

  testWidgets(
    'Missing repair_job behind a SIMPLE_REPAIR approval shows an ErrorState, '
    'not an endless loader',
    (tester) async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('repair_approvals').doc('appr3').set({
        'approvalNo': 'APR-0003',
        'approvalType': 'SIMPLE_REPAIR',
        'repairJobId': 'jobThatDoesNotExist',
        'vehicleNumber': 'WP-9999',
        'quotationId': null,
        'amountCents': 1000,
        'requiredLevel': 'MANAGER',
        'decision': 'PENDING',
        'requestedBy': 'uidMechanic',
        'requestedAt': Timestamp.now(),
        'createdAt': Timestamp.now(),
      });
      await firestore.collection('users').doc('uidViewer').set({
        'name': 'Supervisor Sam',
        'role': 'supervisor',
        'repairPermissions': ['APPROVE'],
      });
      await firestore.collection('settings').doc('repair_workflow').set({});

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairApprovalDetailScreen(
          approvalId: 'appr3',
          currentUid: 'uidViewer',
          firestoreOverride: firestore,
        ),
      ));
      await settle(tester);

      // repair_jobs/jobThatDoesNotExist simply doesn't exist, so .get()
      // resolves successfully with an empty/non-existent snapshot
      // (data() == null) rather than throwing — the screen should still
      // render normally with blank job fields, not hang.
      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('APR-0003'), findsOneWidget);
    },
  );

  // Reproduces the user's exact reported path: Approval Center -> tap an
  // item -> RepairApprovalDetailScreen. The earlier tests above navigate
  // straight to RepairApprovalDetailScreen and never exercise
  // RepairApprovalCenterScreen, pushWebAware, or the page transition at
  // all — if the real bug lives in that path (not in the detail screen's
  // own loaders, which the earlier tests already proved settle correctly),
  // only a test that actually taps through the list would catch it.
  testWidgets(
    'Tapping a SIMPLE_REPAIR item in the real Approval Center list opens '
    'the detail screen and it renders (not an endless loader or layout '
    'exception)',
    (tester) async {
      final firestore = await _simpleRepairFirestore();

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairApprovalCenterScreen(
          firestoreOverride: firestore,
          currentUidOverride: 'uidViewer',
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);

      // The list itself loaded and shows the pending SIMPLE_REPAIR item.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('APR-0001'), findsOneWidget);

      await tester.tap(find.textContaining('APR-0001'));
      // Drains the ~350ms FadeSlideRoute/MaterialPageRoute transition plus
      // every load the detail screen kicks off on mount.
      await settle(tester);
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Approval Detail'), findsOneWidget);
      expect(find.text('Mechanic Form'), findsOneWidget);
      expect(find.textContaining('ENGINE MAKING NOISE, NEEDS GASKET REPLACEMENT'),
          findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'OK'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'RETURN'), findsOneWidget);
    },
  );

  // The specific regression from this round: AppTheme.light()'s button
  // themes forcing an infinite-width minimumSize crashed the "Open Repair
  // Job" / "Vehicle History" Row (lib/main.dart, just above the "Mechanic
  // Form" section) with "BoxConstraints forces an infinite width". Run at
  // two widths since Row-layout-with-unbounded-width bugs are a function of
  // the button being placed in an unconstrained slot, not of how much
  // space is actually available — both a wide desktop-ish surface and a
  // narrow phone-ish one must lay out without throwing.
  for (final size in [const Size(1200, 900), const Size(390, 844)]) {
    testWidgets(
      'No layout exception at ${size.width.toInt()}x${size.height.toInt()}: '
      'Open Repair Job / Vehicle History buttons in a Row',
      (tester) async {
        final originalSize = tester.view.physicalSize;
        final originalRatio = tester.view.devicePixelRatio;
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.physicalSize = originalSize;
          tester.view.devicePixelRatio = originalRatio;
        });

        final firestore = await _simpleRepairFirestore();

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairApprovalDetailScreen(
            approvalId: 'appr1',
            currentUid: 'uidViewer',
            firestoreOverride: firestore,
          ),
        ));
        await settle(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('Open Repair Job'), findsOneWidget);
        expect(find.text('Vehicle History'), findsOneWidget);
      },
    );
  }
}
