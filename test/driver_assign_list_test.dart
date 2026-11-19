// Driver assignment follow-up:
//  - "Assign Driver" / "Change Assigned Driver" lists include every
//    role=='driver' user + field_workers with canDriveTruck, sorted by name,
//    and exclude other roles.
//  - Add User saves canDriveTruck:true by default for role=='driver'.
//  - "Driver not linked - re-assign" shows only when a truck has a driver
//    name but no assignedDriverUid.
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

Future<FakeFirebaseFirestore> _users() async {
  final db = FakeFirebaseFirestore();
  final users = <String, Map<String, dynamic>>{
    'uZoe': {'name': 'Zoe Driver', 'role': 'driver', 'canDriveTruck': false},
    'uAmal': {'name': 'amal driver', 'role': 'driver'},
    'uFw': {'name': 'Kamal Field', 'role': 'field_worker', 'canDriveTruck': true},
    'uOp': {'name': 'Oscar Operator', 'role': 'field_worker', 'canDriveTruck': false},
    'uSup': {'name': 'Sam Supervisor', 'role': 'supervisor', 'canDriveTruck': true},
    'uAdm': {'name': 'Ada Admin', 'role': 'admin'},
  };
  for (final e in users.entries) {
    await db.collection('users').doc(e.key).set(e.value);
  }
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  group('assignable driver list', () {
    test('isAssignableTruckDriver: role driver always, field_worker only with '
        'canDriveTruck, other roles never', () {
      expect(isAssignableTruckDriver({'role': 'driver'}), isTrue);
      expect(isAssignableTruckDriver({'role': 'driver', 'canDriveTruck': false}),
          isTrue);
      expect(isAssignableTruckDriver({'role': 'field_worker', 'canDriveTruck': true}),
          isTrue);
      expect(isAssignableTruckDriver({'role': 'field_worker'}), isFalse);
      expect(isAssignableTruckDriver({'role': 'supervisor', 'canDriveTruck': true}),
          isFalse);
      expect(isAssignableTruckDriver({'role': 'admin'}), isFalse);
      expect(isAssignableTruckDriver(null), isFalse);
    });

    test('stream + filter returns drivers and truck field_workers sorted by name',
        () async {
      final db = await _users();
      final snap = await assignableTruckDriversStream(db: db).first;
      final names = assignableTruckDrivers(snap.docs)
          .map((d) => d.data()['name'])
          .toList();
      expect(names, ['amal driver', 'Kamal Field', 'Zoe Driver']);
    });

    testWidgets('Truck Profile "Change Assigned Driver" lists role driver users',
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _users();
      await db.collection('trucks').doc('t1').set({'truckNumber': 'WP-1'});

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: TruckProfileScreen(truckId: 't1', truckNumber: 'WP-1', firestoreOverride: db),
      ));
      await settle(tester);
      await tester.tap(find.text('Change').first);
      await settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.text('Change Assigned Driver'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      for (final n in ['Zoe Driver', 'amal driver', 'Kamal Field']) {
        expect(find.descendant(of: dialog, matching: find.text(n)), findsOneWidget);
      }
      for (final n in ['Oscar Operator', 'Sam Supervisor', 'Ada Admin']) {
        expect(find.descendant(of: dialog, matching: find.text(n)), findsNothing);
      }
      // Sorted by name.
      final y = [
        for (final n in ['amal driver', 'Kamal Field', 'Zoe Driver'])
          tester.getTopLeft(find.descendant(of: dialog, matching: find.text(n))).dy
      ];
      expect(y[0] < y[1] && y[1] < y[2], isTrue);
    });
  });

  group('showDriverNamePicker (Weekly Inspection driver sheet)', () {
    Future<void> openPicker(WidgetTester tester, FakeFirebaseFirestore db) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDriverNamePicker(context, db: db),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('OPEN'));
      await settle(tester);
    }

    testWidgets('lists the same drivers as the assign lists, sorted by name',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _users();
      await openPicker(tester, db);
      expect(tester.takeException(), isNull);

      for (final n in ['Zoe Driver', 'amal driver', 'Kamal Field']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
      for (final n in ['Oscar Operator', 'Sam Supervisor', 'Ada Admin']) {
        expect(find.text(n), findsNothing, reason: n);
      }
      final y = [
        for (final n in ['amal driver', 'Kamal Field', 'Zoe Driver'])
          tester.getTopLeft(find.text(n)).dy
      ];
      expect(y[0] < y[1] && y[1] < y[2], isTrue);
      // No free-text "Other" entry: only registered users can be picked.
      expect(find.textContaining('Other'), findsNothing);
    });

    testWidgets('picking returns BOTH uid and name; search filters',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = await _users();
      PickedDriver? picked;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showDriverNamePicker(context, db: db);
                },
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('OPEN'));
      await settle(tester);

      await tester.enterText(find.byType(TextField), 'ZOE');
      await settle(tester);
      expect(find.text('Zoe Driver'), findsOneWidget);
      expect(find.text('Kamal Field'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('driver-pick-uZoe')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(picked, isNotNull);
      expect(picked!.uid, 'uZoe');
      expect(picked!.name, 'Zoe Driver');
    });
  });

  group('Add User canDriveTruck default', () {
    test('role driver -> true', () {
      expect(newUserCanDriveTruck('driver', false), isTrue);
    });
    test('field_worker unchanged (follows the checkbox)', () {
      expect(newUserCanDriveTruck('field_worker', true), isTrue);
      expect(newUserCanDriveTruck('field_worker', false), isFalse);
    });
    test('other roles -> false', () {
      for (final r in ['admin', 'owner', 'supervisor', 'management', 'technical']) {
        expect(newUserCanDriveTruck(r, true), isFalse, reason: r);
      }
    });
  });

  group('Driver not linked warning', () {
    test('truckDriverNotLinked only when name present and uid empty', () {
      expect(truckDriverNotLinked({'assignedDriverName': 'DAN'}), isTrue);
      expect(truckDriverNotLinked({'assignedDriverName': 'DAN', 'assignedDriverUid': null}),
          isTrue);
      expect(truckDriverNotLinked({'assignedDriverName': 'DAN', 'assignedDriverUid': ''}),
          isTrue);
      expect(truckDriverNotLinked({'assignedDriverName': 'DAN', 'assignedDriverUid': 'u1'}),
          isFalse);
      expect(truckDriverNotLinked({'assignedDriverName': '', 'assignedDriverUid': null}),
          isFalse);
      expect(truckDriverNotLinked({'truckNumber': 'WP-1'}), isFalse);
      expect(truckDriverNotLinked(null), isFalse);
    });

    for (final c in [
      (name: 'TYPED NAME', uid: null, shows: true),
      (name: 'Linked Dan', uid: 'uDan', shows: false),
      (name: null, uid: null, shows: false),
    ]) {
      testWidgets('Truck Profile warning name=${c.name} uid=${c.uid} -> '
          '${c.shows ? 'shown' : 'hidden'}', (tester) async {
        final db = FakeFirebaseFirestore();
        await db.collection('trucks').doc('t1').set({
          'truckNumber': 'WP-1',
          'assignedDriverName': c.name,
          'assignedDriverUid': c.uid,
        });
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(truckId: 't1', truckNumber: 'WP-1', firestoreOverride: db),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text(kDriverNotLinkedMessage), c.shows ? findsOneWidget : findsNothing);
      });
    }
  });
}
