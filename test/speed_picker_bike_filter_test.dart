// Vehicle Speed picker: All | Trucks | Bikes filter chips, number search
// combined with the filter, type label per row, bikes without a GPS
// device listed disabled (tapping does nothing), and "No bikes found".
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

final _recent = DateTime.now().toUtc().subtract(const Duration(minutes: 2));

List<Map<String, dynamic>> _devices() => [
      {'id': 3, 'uniqueId': '9210220452', 'lastUpdate': _recent.toIso8601String()},
      {'id': 5, 'uniqueId': '9210188420', 'lastUpdate': _recent.toIso8601String()},
      {'id': 8, 'uniqueId': '9210188280', 'lastUpdate': _recent.toIso8601String()},
    ];

Future<FakeFirebaseFirestore> _fixture({bool withBikes = true}) async {
  final db = FakeFirebaseFirestore();
  await db.collection('trucks').doc('t1').set(
      {'truckNumber': 'LM-6435', 'gpsDeviceId': '9210220452'});
  await db.collection('trucks').doc('t2').set(
      {'truckNumber': 'BLO-8390', 'gpsDeviceId': '9210188420'});
  if (withBikes) {
    await db.collection('bikes').doc('b1').set(
        {'bikeNumber': 'BLE-1771', 'gpsDeviceId': '9210188280'});
    await db.collection('bikes').doc('b2').set({'bikeNumber': 'BKM-2020'});
  }
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(() {
    ReferenceCollectionCache.reset();
    VehicleKmCache.reset();
    // Selecting a vehicle resolves its Traccar device id through
    // VehicleKmCache — served from the fixture, never the network.
    VehicleKmCache.devicesFetcherOverride = () async => _devices();
  });
  tearDown(() => VehicleKmCache.devicesFetcherOverride = null);

  final changes = <({String? vehicleId, bool isBike})>[];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPicker(WidgetTester tester, FakeFirebaseFirestore db) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    changes.clear();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: SpeedVehiclePicker(
          firestoreOverride: db,
          devicesLoader: () async => _devices(),
          onRouteReady: (_) {},
          onVehicleChanged: ({
            required vehicleId,
            required isBike,
            required gpsDeviceId,
            required deviceId,
          }) =>
              changes.add((vehicleId: vehicleId, isBike: isBike)),
          onDayChanged: (_, _) {},
        ),
      ),
    ));
    await settle(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> tapFilter(WidgetTester tester, String name) async {
    await tester.tap(find.byKey(ValueKey('speed-filter-$name')));
    await settle(tester);
  }

  const trucks = ['LM-6435', 'BLO-8390'];
  const bikes = ['BLE-1771', 'BKM-2020'];

  void expectShown(List<String> shown, List<String> hidden) {
    for (final n in shown) {
      expect(find.text(n), findsOneWidget, reason: '$n should be listed');
    }
    for (final n in hidden) {
      expect(find.text(n), findsNothing, reason: '$n should be hidden');
    }
  }

  testWidgets('All (default) -> trucks + bikes; Trucks / Bikes filter', (
    tester,
  ) async {
    await pumpPicker(tester, await _fixture());

    // Default is All, with counts on each chip.
    final all = tester.widget<ChoiceChip>(
      find.byKey(const ValueKey('speed-filter-all')),
    );
    expect(all.selected, isTrue);
    expect(find.text('All (4)'), findsOneWidget);
    expect(find.text('Trucks (2)'), findsOneWidget);
    expect(find.text('Bikes (2)'), findsOneWidget);
    expectShown([...trucks, ...bikes], []);
    // Type label on every row.
    expect(find.text('Truck'), findsNWidgets(2));
    expect(find.text('Bike'), findsNWidgets(2));

    await tapFilter(tester, 'trucks');
    expectShown(trucks, bikes);

    await tapFilter(tester, 'bikes');
    expectShown(bikes, trucks);

    await tapFilter(tester, 'all');
    expectShown([...trucks, ...bikes], []);
  });

  testWidgets('search works together with the filter', (tester) async {
    await pumpPicker(tester, await _fixture());

    // "BL" matches truck BLO-8390 and bike BLE-1771.
    await tester.enterText(
      find.byKey(const ValueKey('speed-picker-search')),
      'bl',
    );
    await settle(tester);
    expectShown(['BLO-8390', 'BLE-1771'], ['LM-6435', 'BKM-2020']);

    await tapFilter(tester, 'bikes');
    expectShown(['BLE-1771'], ['BLO-8390', 'LM-6435', 'BKM-2020']);

    await tapFilter(tester, 'trucks');
    expectShown(['BLO-8390'], ['BLE-1771', 'LM-6435', 'BKM-2020']);

    await tester.enterText(
      find.byKey(const ValueKey('speed-picker-search')),
      'zzz',
    );
    await settle(tester);
    expect(find.byKey(const ValueKey('speed-picker-no-match')), findsOneWidget);
  });

  testWidgets('bike without GPS device: listed, disabled, tap does nothing; '
      'bike with GPS is selectable like a truck', (tester) async {
    await pumpPicker(tester, await _fixture());
    await tapFilter(tester, 'bikes');

    final noGps = find.byKey(const ValueKey('speed-bike-b2'));
    expect(tester.widget<ListTile>(noGps).enabled, isFalse);
    expect(
      find.descendant(of: noGps, matching: find.text('No GPS device')),
      findsOneWidget,
    );
    await tester.tap(noGps, warnIfMissed: false);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(changes, isEmpty);
    expect(find.text('Last 7 Days'), findsNothing); // still on the list

    final withGps = find.byKey(const ValueKey('speed-bike-b1'));
    expect(tester.widget<ListTile>(withGps).enabled, isTrue);
    await tester.tap(withGps);
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(changes.first, (vehicleId: 'b1', isBike: true));
    // Same day/route panel as a truck.
    expect(find.text('Last 7 Days'), findsOneWidget);
    expect(find.text('BLE-1771'), findsOneWidget);
  });

  testWidgets('no bikes -> Bikes chip shows "No bikes found"', (tester) async {
    await pumpPicker(tester, await _fixture(withBikes: false));
    expect(find.text('Bikes (0)'), findsOneWidget);
    await tapFilter(tester, 'bikes');
    expect(find.byKey(const ValueKey('speed-picker-no-bikes')), findsOneWidget);
    expect(find.text('No bikes found'), findsOneWidget);
    expectShown([], trucks);

    await tapFilter(tester, 'trucks');
    expectShown(trucks, []);
  });
}
