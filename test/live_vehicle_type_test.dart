// Live Tracking vehicle type: the app's own trucks/bikes data decides the
// icon; Traccar category only as a fallback; unknown -> neutral pin, never
// the bike icon. A device/number registered on a truck stays a truck even
// when it was also entered on a bike or Traccar calls it a motorcycle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  final trucks = [
    {'truckNumber': 'LM-6435', 'gpsDeviceId': '9210220452'},
    {'truckNumber': 'HT-04', 'gpsDeviceId': ' 9210205624 '},
    {'truckNumber': 'LN-3219'}, // no GPS device yet
  ];
  final bikes = [
    {'bikeNumber': 'BLE-1771', 'gpsDeviceId': '9210188280'},
    // Mistake: a truck's device entered on a bike too.
    {'bikeNumber': 'BLO-8390', 'gpsDeviceId': '9210220452'},
    // Mistake: a truck number entered as a bike.
    {'bikeNumber': 'ht-04', 'gpsDeviceId': '1111'},
  ];
  final index = LiveVehicleIndex.fromData(trucks: trucks, bikes: bikes);

  group('LiveVehicleIndex.resolve', () {
    test('truck by GPS id or by number (trimmed / case-insensitive)', () {
      expect(index.resolve(gpsDeviceId: '9210220452'), LiveVehicleType.truck);
      expect(index.resolve(gpsDeviceId: '9210205624'), LiveVehicleType.truck);
      expect(index.resolve(vehicleNumber: 'ln-3219 '), LiveVehicleType.truck);
    });

    test('bike only when not a truck', () {
      expect(index.resolve(gpsDeviceId: '9210188280'), LiveVehicleType.bike);
      expect(index.resolve(vehicleNumber: 'BLE-1771'), LiveVehicleType.bike);
    });

    test('unknown -> Traccar category, else unknown (never bike)', () {
      expect(index.resolve(gpsDeviceId: 'x', vehicleNumber: 'ZZ-1'),
          LiveVehicleType.unknown);
      expect(index.resolve(gpsDeviceId: 'x', traccarCategory: 'default'),
          LiveVehicleType.unknown);
      expect(index.resolve(gpsDeviceId: 'x', traccarCategory: 'Truck'),
          LiveVehicleType.truck);
      expect(index.resolve(gpsDeviceId: 'x', traccarCategory: 'motorcycle'),
          LiveVehicleType.bike);
    });

    test('Traccar category conflicting with trucks collection -> truck', () {
      expect(
        index.resolve(gpsDeviceId: '9210220452', traccarCategory: 'motorcycle'),
        LiveVehicleType.truck,
      );
      expect(
        index.resolve(vehicleNumber: 'LM-6435', traccarCategory: 'bicycle'),
        LiveVehicleType.truck,
      );
    });

    test('bike doc carrying a truck GPS id / number is really that truck', () {
      expect(index.bikeDocIsReallyTruck(bikes[0]), isFalse);
      expect(index.bikeDocIsReallyTruck(bikes[1]), isTrue);
      expect(index.bikeDocIsReallyTruck(bikes[2]), isTrue);
    });
  });

  test('resolveLiveTrackedVehicles: one marker type per device', () {
    final devices = [
      {'id': 3, 'name': 'LM-6435', 'uniqueId': '9210220452', 'category': 'motorcycle'},
      {'id': 36, 'name': 'HT-04', 'uniqueId': '9210205624', 'category': null},
      {'id': 8, 'name': 'BLE-1771', 'uniqueId': '9210188280', 'category': null},
      {'id': 99, 'name': 'UNREGISTERED', 'uniqueId': '5555', 'category': 'truck'},
    ];
    final r = resolveLiveTrackedVehicles(devices: devices, trucks: trucks, bikes: bikes);
    // Truck device also on bike BLO-8390 + Traccar "motorcycle" -> truck only.
    expect(r['9210220452'], (type: LiveVehicleType.truck, number: 'LM-6435'));
    expect(r['9210205624'], (type: LiveVehicleType.truck, number: 'HT-04'));
    expect(r['9210188280'], (type: LiveVehicleType.bike, number: 'BLE-1771'));
    // Not registered in the app -> no marker (unchanged behaviour).
    expect(r.containsKey('5555'), isFalse);
    expect(r.values.where((v) => v.type == LiveVehicleType.bike), hasLength(1));
  });

  testWidgets('LiveVehicleIcon draws the canvas truck/bike; unknown is a pin',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          LiveVehicleIcon(key: ValueKey('t'), type: LiveVehicleType.truck),
          LiveVehicleIcon(key: ValueKey('b'), type: LiveVehicleType.bike),
          LiveVehicleIcon(key: ValueKey('u'), type: LiveVehicleType.unknown),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    for (final k in ['t', 'b']) {
      expect(
        find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(CustomPaint)),
        findsWidgets,
      );
    }
    expect(find.descendant(of: find.byKey(const ValueKey('u')), matching: find.byIcon(Icons.place)),
        findsOneWidget);
    expect(find.byIcon(Icons.two_wheeler), findsNothing);
    expect(find.byIcon(Icons.local_shipping), findsNothing);
  });
}
