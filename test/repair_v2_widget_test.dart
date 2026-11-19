// Widget tests for the new Truck Repair v2 screens (Step 1 of the
// rebuild, purely additive — none of these are wired into any existing
// screen/hub/dashboard yet, so they're exercised standalone here via each
// screen's firestoreOverride/currentUidOverride test seam).
//
// Run with the REAL app theme (AppTheme.light()) at both a narrow phone
// width and a wide desktop width, asserting tester.takeException() is
// null — same convention as the rest of this app's widget tests.
import 'package:cloud_firestore/cloud_firestore.dart';
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
  await firestore.collection('users').doc('uidInspector').set({
    'name': 'Ian Inspector',
    'role': 'technical',
    'repairPermissions': [kPermReportDefect],
  });
  await firestore.collection('users').doc('uidManagement').set({
    'name': 'Mary Management',
    'role': 'management',
    'repairPermissions': [kPermApprove, kPermHistoryView],
  });
  await firestore.collection('users').doc('uidTechnical').set({
    'name': 'Tina Technical',
    'role': 'technical',
    'repairPermissions': [kPermRepairWork],
  });
  for (final c in kDefaultRepairCategories) {
    await firestore.collection('repair_categories').doc(c.code).set({
      'code': c.code,
      'name': c.name,
      'sortOrder': kDefaultRepairCategories.indexOf(c),
      'active': true,
    });
  }
  await firestore.collection('settings').doc('repair_numbering').set({'companyPrefix': 'NOD'});
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

    testWidgets('RepairCategoriesScreen: seeded categories render, no layout exception ($label)',
        (tester) async {
      await setSurface(tester, size);
      final firestore = await _fixture();
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: RepairCategoriesScreen(firestoreOverride: firestore, currentUidOverride: 'uidAdmin'),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('ENG — Engine'), findsOneWidget);
      expect(find.text('SEED DEFAULT CATEGORIES'), findsOneWidget);
    });

    testWidgets(
      'RepairCategoriesScreen: a non-admin gets NO ACCESS, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairCategoriesScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidTechnical',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ACCESS'), findsOneWidget);
      },
    );

    testWidgets(
      'AddRepairScreen: category dropdown + severity + submit button, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
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
        expect(find.text('Repair 1'), findsOneWidget);
        expect(find.text('NORMAL'), findsOneWidget);
        expect(find.text('URGENT'), findsOneWidget);
        expect(find.text('ADD ANOTHER REPAIR'), findsOneWidget);
        expect(find.textContaining('SUBMIT'), findsOneWidget);
      },
    );

    testWidgets(
      'AddRepairScreen: no REPORT_DEFECT permission -> NO ACCESS, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: AddRepairScreen(
            userName: 'Tina Technical',
            vehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTechnical',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ACCESS'), findsOneWidget);
      },
    );

    testWidgets(
      'NewRepairsInboxScreen: a reported repair groups under its vehicle, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'severity': 'NORMAL',
          'status': RepairItemStatus.reported,
          'reportedAt': Timestamp.now(),
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: NewRepairsInboxScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-1234'), findsOneWidget);
        expect(find.text('1 NEW'), findsOneWidget);
      },
    );

    testWidgets(
      'NewRepairsVehicleScreen: ADD then SUBMIT writes repair_lists and flips repairs to LISTED, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'severity': 'NORMAL',
          'status': RepairItemStatus.reported,
          'reportedAt': Timestamp.now(),
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: NewRepairsVehicleScreen(
            vehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('ADD'), findsOneWidget);

        await tester.tap(find.text('ADD'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('FINAL REPAIR LIST (1)'), findsOneWidget);

        await tester.tap(find.text('SUBMIT'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(ElevatedButton, 'Submit'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final repairDoc = await firestore.collection('repairs').doc('r1').get();
        expect(repairDoc.data()?['status'], RepairItemStatus.listed);
        final listsSnap = await firestore.collection('repair_lists').get();
        expect(listsSnap.docs.length, 1);
        expect(listsSnap.docs.first.data()['vehicleNumber'], 'WP-1234');
        expect(listsSnap.docs.first.data()['status'], RepairListStatus.submitted);
      },
    );

    testWidgets(
      'RepairsToDoScreen: a LISTED repair shows START, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'severity': 'NORMAL',
          'status': RepairItemStatus.listed,
          'listId': 'list1',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairsToDoScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidTechnical',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('WP-1234'), findsOneWidget);
        expect(find.text('Engine'), findsOneWidget);
        expect(find.text('START'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairsToDoScreen: an IN_PROGRESS repair shows the MARK DONE form, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'severity': 'NORMAL',
          'status': RepairItemStatus.inProgress,
          'listId': 'list1',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairsToDoScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidTechnical',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        // The queue is a table now: an IN_PROGRESS row shows a MARK DONE
        // button that opens the (unchanged) work form on its own page.
        expect(find.text('WP-1234'), findsOneWidget);
        final markDone = find.widgetWithText(ElevatedButton, 'MARK DONE');
        await tester.ensureVisible(markDone); // scrolls the table sideways on a phone
        await tester.pumpAndSettle();
        await tester.tap(markDone);
        await tester.pumpAndSettle();
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Technical Note (required)'), findsOneWidget);
        expect(find.text('ADD PART'), findsOneWidget);
        expect(find.text('MARK DONE'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairsToDoScreen: a RETURNED repair shows the return reason and START again, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'severity': 'NORMAL',
          'status': RepairItemStatus.returned,
          'returnReason': 'Oil leak still present',
          'listId': 'list1',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairsToDoScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidTechnical',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Oil leak still present'), findsOneWidget);
        expect(find.text('START'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairFinalApprovalScreen: a DONE_PENDING_APPROVAL repair shows APPROVE/RETURN, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'status': RepairItemStatus.donePendingApproval,
          'technicalNote': 'Replaced gasket',
          'listId': 'list1',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairFinalApprovalScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Replaced gasket'), findsOneWidget);
        expect(find.widgetWithText(OutlinedButton, 'RETURN'), findsOneWidget);
        expect(find.widgetWithText(ElevatedButton, 'APPROVE'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairFinalApprovalScreen: nothing waiting -> empty state, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairFinalApprovalScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NOTHING WAITING FOR APPROVAL'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairHistoryScreen: prefilled vehicle shows its repair history, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'code': 'NOD/ENG/260001',
          'vehicleNumber': 'WP-1234',
          'categoryCode': 'ENG',
          'categoryName': 'Engine',
          'description': 'Engine making noise',
          'status': RepairItemStatus.completed,
          'reportedByName': 'Ian Inspector',
          'reportedAt': Timestamp.now(),
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairHistoryScreen(
            prefillVehicleNumber: 'WP-1234',
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsOneWidget);
        expect(find.text('ACTIVITY'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairHistoryScreen: no vehicle entered -> prompts to search, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: RepairHistoryScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidManagement',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('ENTER A VEHICLE NUMBER'), findsOneWidget);
      },
    );

    testWidgets(
      'RepairFleetSummaryCounts: all 4 counts render for a qualifying user, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('repairs').doc('r1').set({
          'vehicleNumber': 'WP-1234',
          'status': RepairItemStatus.reported,
        });
        await firestore.collection('repairs').doc('r2').set({
          'vehicleNumber': 'WP-5555',
          'status': RepairItemStatus.donePendingApproval,
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepairFleetSummaryCounts(
                firestoreOverride: firestore,
                currentUidOverride: 'uidManagement',
              ),
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NEW REPAIRS'), findsOneWidget);
        expect(find.text('WAITING APPROVAL'), findsOneWidget);
        expect(find.text('TO DO'), findsOneWidget);
        expect(find.text('RETURNED'), findsOneWidget);
        expect(find.text('1'), findsWidgets);
      },
    );

    testWidgets(
      'RepairFleetSummaryCounts: a non-qualifying user sees nothing, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await _fixture();
        await firestore.collection('users').doc('uidNobody').set({
          'name': 'No Body',
          'role': 'driver',
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: RepairFleetSummaryCounts(
              firestoreOverride: firestore,
              currentUidOverride: 'uidNobody',
            ),
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NEW REPAIRS'), findsNothing);
      },
    );
  }
}
