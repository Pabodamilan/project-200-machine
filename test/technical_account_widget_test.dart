// Widget tests for the TECHNICAL account type's UI: AddUserScreen's
// account-type radio + pre-filled-but-editable defaults, and
// TechnicalHomeScreen's permission-driven tiles. Run with the real
// AppTheme.light() at both a narrow phone width and a wide desktop width,
// asserting tester.takeException() is null — same convention as the rest
// of this app's widget tests.
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

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'AddUserScreen: admin sees the Technical option; selecting it '
      'pre-fills Garage/Warehouse Access and the repair permission '
      'defaults, still editable, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: AddUserScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Technical (mechanic / engineer)'), findsOneWidget);

        await tester.tap(find.text('Technical (mechanic / engineer)'));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Garage Access'),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Warehouse Access'),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'REPAIR WORK'),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'SERVICE VIEW'),
              )
              .value,
          isTrue,
        );
        // No default for approval/payments/settings.
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'SERVICE APPROVE'),
              )
              .value,
          isFalse,
        );

        // Still editable — untick Garage Access.
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Garage Access'));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.widgetWithText(CheckboxListTile, 'Garage Access'),
              )
              .value,
          isFalse,
        );
      },
    );

    testWidgets(
      'AddUserScreen: a non-admin/owner creator never sees the Technical '
      'option, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidSupervisor').set({
          'name': 'Sam Supervisor',
          'role': 'supervisor',
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: AddUserScreen(
            firestoreOverride: firestore,
            currentUidOverride: 'uidSupervisor',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Technical (mechanic / engineer)'), findsNothing);
      },
    );

    testWidgets(
      'TechnicalHomeScreen: full permissions show all 4 tiles, no layout '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'canAccessGarage': true,
          'canAccessWarehouse': true,
          'repairPermissions': technicalDefaults().repairPermissions,
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TechnicalHomeScreen(
            name: 'Tina Technical',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Vehicle Maintenance'), findsOneWidget);
        expect(find.text('Repairs To Do'), findsOneWidget);
        expect(find.text('Daily Checks'), findsOneWidget);
        expect(find.text('Warehouse'), findsOneWidget);
      },
    );

    testWidgets(
      'TechnicalHomeScreen: narrower permissions only show the matching '
      'tiles, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'canAccessGarage': true,
          'canAccessWarehouse': false,
          'repairPermissions': <String>[],
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TechnicalHomeScreen(
            name: 'Tina Technical',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('Vehicle Maintenance'), findsOneWidget);
        expect(find.text('Repairs To Do'), findsNothing);
        expect(find.text('Daily Checks'), findsNothing);
        expect(find.text('Warehouse'), findsNothing);
      },
    );

    testWidgets(
      'TechnicalHomeScreen: no permissions at all -> empty state, no '
      'layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidTech').set({
          'name': 'Tina Technical',
          'role': 'technical',
          'canAccessGarage': false,
          'canAccessWarehouse': false,
          'repairPermissions': <String>[],
        });

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TechnicalHomeScreen(
            name: 'Tina Technical',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ACCESS GRANTED YET'), findsOneWidget);
      },
    );
  }
}
