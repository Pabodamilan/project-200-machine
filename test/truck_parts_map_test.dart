// Tests for the "Truck Parts Map" (lib/widgets/truck_parts_map.dart) —
// VehicleHealthScreen and its interactive TruckPartsMap. Run with the
// real AppTheme.light() at 360px, 390px and 1200px, asserting
// tester.takeException() is null — same convention as the rest of this
// app's widget tests.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';
import 'package:project_200_machine/widgets/truck_parts_map.dart';

// Throws on repairs.where(...).orderBy(...).snapshots() specifically —
// same noSuchMethod-chaining technique as
// test/service_alerts_widget_test.dart's _ThrowingFirestore, adapted for
// a Stream-returning call instead of a Future-returning one.
class _ThrowingRepairsFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  _ThrowingRepairsFirestore(this.inner);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath == 'repairs') return _ThrowingRepairsCollection();
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingRepairsCollection implements CollectionReference<Map<String, dynamic>> {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #where || name == #orderBy || name == #limit) return this;
    if (name == #snapshots) {
      return Stream<QuerySnapshot<Map<String, dynamic>>>.error(
        FirebaseException(
          plugin: 'cloud_firestore',
          code: 'unavailable',
          message: 'Simulated failure for testing',
        ),
      );
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();

  setUpAll(() async {
    await Firebase.initializeApp();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
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

  Future<FakeFirebaseFirestore> fixture() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('users').doc('uidAdmin').set({
      'name': 'Admin Alice',
      'role': 'admin',
    });
    await firestore.collection('users').doc('uidTech').set({
      'name': 'Tina Technical',
      'role': 'technical',
    });
    await firestore.collection('trucks').doc('t1').set({
      'truckNumber': 'WP-1111',
      'isCompanyTruck': true,
    });
    final now = DateTime.now();
    await firestore.collection('repairs').doc('r1').set({
      'code': 'NOD/ENG/260001',
      'vehicleNumber': 'WP-1111',
      'categoryCode': 'ENG',
      'categoryName': 'Engine',
      'description': 'Engine oil leak near the sump',
      'status': RepairItemStatus.reported,
      'reportedAt': Timestamp.fromDate(now),
    });
    await firestore.collection('repairs').doc('r2').set({
      'code': 'NOD/HYD/260002',
      'vehicleNumber': 'WP-1111',
      'categoryCode': 'HYD',
      'categoryName': 'Hydraulic system',
      'description': 'Tipping ram seal replaced',
      'status': RepairItemStatus.donePendingApproval,
      'reportedAt': Timestamp.fromDate(now.subtract(const Duration(days: 1))),
    });
    await firestore.collection('repairs').doc('r3').set({
      'code': 'NOD/BRK/260003',
      'vehicleNumber': 'WP-1111',
      'categoryCode': 'BRK',
      'categoryName': 'Brakes',
      'description': 'Front brake pads replaced',
      'status': RepairItemStatus.completed,
      'reportedAt': Timestamp.fromDate(now.subtract(const Duration(days: 2))),
    });
    await firestore.collection('repairs').doc('r4').set({
      'code': 'NOD/TYR/260004',
      'vehicleNumber': 'WP-1111',
      'categoryCode': 'TYR',
      'categoryName': 'Tyres and wheels',
      'description': 'Rear tyre worn out',
      'status': RepairItemStatus.listed,
      'reportedAt': Timestamp.fromDate(now.subtract(const Duration(days: 3))),
    });
    await firestore.collection('repairs').doc('r5').set({
      'code': 'NOD/OTH/260005',
      'vehicleNumber': 'WP-1111',
      'categoryCode': 'OTH',
      'categoryName': 'Other components',
      'description': 'Mud flap replacement',
      'status': RepairItemStatus.reported,
      'reportedAt': Timestamp.fromDate(now.subtract(const Duration(days: 4))),
    });
    return firestore;
  }

  // Relies on TruckPartsMap's graceful missing-asset fallback: when
  // assets/images/tipper_truck_side.jpg can't be resolved (true in this
  // test sandbox — the real photo isn't bundled here, see this feature's
  // report), _imageSize falls back to kReferenceImageSize, which is the
  // SAME aspect ratio the widget's own outer size is built from — so
  // computeContainRect returns a rect that exactly fills the widget with
  // no letterboxing, and screen position = topLeft + normalizedCentroid *
  // widget size, exactly as asserted below.
  Offset partScreenPoint(WidgetTester tester, String partId) {
    final mapFinder = find.byType(TruckPartsMap);
    final topLeft = tester.getTopLeft(mapFinder);
    final renderSize = tester.getSize(mapFinder);
    final part = buildTruckPartGeometry().firstWhere((p) => p.id == partId);
    return topLeft +
        Offset(
          part.normalizedCentroid.dx * renderSize.width,
          part.normalizedCentroid.dy * renderSize.height,
        );
  }

  Offset emptySkyScreenPoint(WidgetTester tester) {
    final mapFinder = find.byType(TruckPartsMap);
    final topLeft = tester.getTopLeft(mapFinder);
    final renderSize = tester.getSize(mapFinder);
    // Reference pixel (20, 20): left of and above every hotspot polygon
    // (chassis/tipperBody's own leftmost edges start at x=62/92; every
    // part's topmost edge is well below y=20) — empty sky, no part.
    return topLeft +
        Offset(20 / kReferenceImageSize.width * renderSize.width,
            20 / kReferenceImageSize.height * renderSize.height);
  }

  for (final size in [const Size(360, 800), const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'VehicleHealthScreen: admin sees the truck parts map with seeded '
      'repairs, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('VEHICLE HEALTH'), findsOneWidget);
        expect(find.byType(TruckPartsMap), findsOneWidget);
        expect(find.text('NO ACCESS'), findsNothing);
      },
    );

    testWidgets(
      'VehicleHealthScreen: hovering the engine highlights it and shows '
      'its codes, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsNothing);

        final enginePoint = partScreenPoint(tester, 'engine');
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(enginePoint);
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.textContaining('NOD/ENG/260001'), findsOneWidget);
      },
    );

    testWidgets(
      'VehicleHealthScreen: tapping a part pins it (survives the pointer '
      'moving away), tapping it again clears it, no layout exception '
      '($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final enginePoint = partScreenPoint(tester, 'engine');
        final emptyPoint = emptySkyScreenPoint(tester);

        await tester.tapAt(enginePoint);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsOneWidget);

        // Pin survives the pointer moving to empty space (no tap there).
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(emptyPoint);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsOneWidget);

        // Tapping the same part again clears the pin.
        await tester.tapAt(enginePoint);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsNothing);
      },
    );

    testWidgets(
      'VehicleHealthScreen: tapping empty space clears the pinned part, '
      'no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final enginePoint = partScreenPoint(tester, 'engine');
        final emptyPoint = emptySkyScreenPoint(tester);

        await tester.tapAt(enginePoint);
        await settle(tester);
        expect(find.textContaining('NOD/ENG/260001'), findsOneWidget);

        await tester.tapAt(emptyPoint);
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('NOD/ENG/260001'), findsNothing);
      },
    );

    testWidgets(
      'VehicleHealthScreen: no repairs for this truck -> "all parts '
      'green" empty state, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = FakeFirebaseFirestore();
        await firestore.collection('users').doc('uidAdmin').set({
          'name': 'Admin Alice',
          'role': 'admin',
        });
        await firestore.collection('trucks').doc('t1').set({
          'truckNumber': 'WP-9999',
          'isCompanyTruck': true,
        });
        // repairs deliberately left empty for WP-9999.

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-9999',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO REPAIRS FOR THIS TRUCK YET'), findsOneWidget);
        expect(find.byType(TruckPartsMap), findsOneWidget);
      },
    );

    testWidgets(
      'VehicleHealthScreen: a repairs load failure shows an error with '
      'RETRY, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        final throwing = _ThrowingRepairsFirestore(firestore);

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: throwing,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Failed to load repairs'), findsOneWidget);
        expect(find.text('RETRY'), findsOneWidget);
      },
    );

    testWidgets(
      'VehicleHealthScreen: a non-admin/owner/management role never sees '
      'the truck parts map, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidTech',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.text('NO ACCESS'), findsOneWidget);
        expect(find.byType(TruckPartsMap), findsNothing);
      },
    );

    testWidgets(
      'TruckPartsMap: the real bundled truck photo loads without the '
      '"Truck image missing" fallback, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(Image), findsWidgets);
        expect(find.text('Truck image missing'), findsNothing);
      },
    );

    testWidgets(
      'VehicleHealthScreen: hovering the cab highlights it and shows its '
      'detail panel, no layout exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: VehicleHealthScreen(
            initialVehicleNumber: 'WP-1111',
            firestoreOverride: firestore,
            currentUidOverride: 'uidAdmin',
          ),
        ));
        await settle(tester);
        expect(tester.takeException(), isNull);

        final cabPoint = partScreenPoint(tester, 'cab');
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(cabPoint);
        await settle(tester);
        expect(tester.takeException(), isNull);

        expect(find.text('Cab'), findsOneWidget);
        expect(find.text('No repairs logged against this part.'), findsOneWidget);
      },
    );
  }
}
