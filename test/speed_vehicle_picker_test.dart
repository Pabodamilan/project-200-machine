// Live Tracking -> Vehicle Speed -> "Select a Vehicle":
//  - ReferenceCollectionCache replays the current snapshot to a LATE
//    subscriber (root cause: the picker joined the shared `trucks` stream
//    while the Trucks sidebar was still listening and never got data).
//  - Every truck whose GPS Device ID matches a Traccar device is listed
//    under Trucks, sorted, with or without a recent position.
//  - Trucks without a GPS device / with an unknown one are listed greyed.
//  - A bike doc duplicating a truck's device is not listed again.
//  - Loading / error states never look like "no trucks".
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

final _recent = DateTime.now().toUtc().subtract(const Duration(minutes: 2));
final _old = DateTime.utc(2026, 11, 1, 6, 30);

List<Map<String, dynamic>> _devices() => [
      {'id': 3, 'name': 'LM-6435', 'uniqueId': '9210220452', 'status': 'online',
       'lastUpdate': _recent.toIso8601String()},
      {'id': 36, 'name': 'HT-04', 'uniqueId': '9210205624', 'status': 'offline',
       'lastUpdate': _old.toIso8601String()},
      {'id': 1, 'name': 'LO-2168', 'uniqueId': '9210220508', 'status': 'unknown',
       'lastUpdate': null},
      {'id': 8, 'name': 'BLE-1771', 'uniqueId': '9210188280'},
    ];

Future<FakeFirebaseFirestore> _fixture() async {
  final db = FakeFirebaseFirestore();
  final trucks = {
    't1': {'truckNumber': 'LM-6435', 'gpsDeviceId': '9210220452'},
    't2': {'truckNumber': 'HT-04', 'gpsDeviceId': ' 9210205624 '},
    't3': {'truckNumber': 'LO-2168', 'gpsDeviceId': '9210220508'},
    't4': {'truckNumber': 'LN-3219'}, // no GPS device
    't5': {'truckNumber': 'LN-9999', 'gpsDeviceId': '0000'}, // unknown in Traccar
  };
  for (final e in trucks.entries) {
    await db.collection('trucks').doc(e.key).set(e.value);
  }
  await db.collection('bikes').doc('b1').set({'bikeNumber': 'BLE-1771', 'gpsDeviceId': '9210188280'});
  // Duplicate: a truck's device also entered on a bike.
  await db.collection('bikes').doc('b2').set({'bikeNumber': 'BLO-8390', 'gpsDeviceId': '9210220452'});
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(ReferenceCollectionCache.reset);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget host(FakeFirebaseFirestore db, Future<List<Map<String, dynamic>>> Function() devices) =>
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SpeedVehiclePicker(
            firestoreOverride: db,
            devicesLoader: devices,
            onRouteReady: (_) {},
            onVehicleChanged: ({required vehicleId, required isBike, required gpsDeviceId, required deviceId}) {},
            onDayChanged: (_, _) {},
          ),
        ),
      );

  group('ReplayLatestStream / ReferenceCollectionCache', () {
    test('root cause: a plain broadcast stream gives a late subscriber nothing',
        () async {
      final source = StreamController<int>.broadcast();
      final sub1 = source.stream.listen((_) {});
      source.add(1);
      await pumpEventQueue();
      final late = <int>[];
      final sub2 = source.stream.listen(late.add);
      await pumpEventQueue();
      expect(late, isEmpty);
      await sub1.cancel();
      await sub2.cancel();
      await source.close();
    });

    test('a late subscriber gets the current value immediately', () async {
      final source = StreamController<int>.broadcast();
      final s = ReplayLatestStream(source.stream).stream;
      final first = <int>[];
      final sub1 = s.listen(first.add);
      source.add(1);
      await pumpEventQueue();
      final late = <int>[];
      final sub2 = s.listen(late.add);
      await pumpEventQueue();
      expect(late, [1]);
      source.add(2);
      await pumpEventQueue();
      expect(first, [1, 2]);
      expect(late, [1, 2]);
      await sub1.cancel();
      await sub2.cancel();
      await source.close();
    });

    // Regression guard only: FakeFirebaseFirestore replays per listener, so
    // the real-Firestore no-replay behaviour is proven by the unit test
    // above, not here.
    testWidgets('picker lists trucks while another listener shares the cached '
        'trucks stream', (tester) async {
      final db = await _fixture();
      // The Trucks sidebar's listener, already attached and served.
      final sidebarSub = ReferenceCollectionCache.stream('trucks', db: db).listen((_) {});
      await tester.pump(const Duration(milliseconds: 100));

      await tester.pumpWidget(host(db, () async => _devices()));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('LM-6435'), findsOneWidget);
      expect(find.text('HT-04'), findsOneWidget);
      // Not awaited: inside the fake-async test zone the upstream cancel
      // future never completes on its own.
      unawaited(sidebarSub.cancel());
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('lists every Traccar-matched truck (with and without a recent '
      'position), sorted; greyed trucks without GPS; duplicate bike not listed',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = await _fixture();
    await tester.pumpWidget(host(db, () async => _devices()));
    await settle(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('Trucks'), findsOneWidget);
    // Selectable, sorted by number: HT-04, LM-6435, LO-2168; then greyed.
    final order = ['HT-04', 'LM-6435', 'LO-2168', 'LN-3219', 'LN-9999'];
    final ys = [for (final n in order) tester.getTopLeft(find.text(n)).dy];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i - 1] < ys[i], isTrue, reason: order[i]);
    }
    expect(find.textContaining('Last seen'), findsOneWidget); // LM-6435
    expect(find.textContaining('No recent position · last seen'), findsOneWidget); // HT-04
    expect(find.text('No recent position'), findsOneWidget); // LO-2168
    expect(find.text('No GPS device'), findsOneWidget);
    expect(find.text('GPS device not found in Traccar'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('speed-truck-t1'))).enabled, isTrue);
    expect(tester.widget<ListTile>(find.byKey(const ValueKey('speed-truck-t4'))).enabled, isFalse);

    // The bike carrying LM-6435's device is not listed; the real bike is.
    expect(find.text('BLE-1771'), findsOneWidget);
    expect(find.text('BLO-8390'), findsNothing);
    expect(find.text('LM-6435'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-icon-truck')), findsNWidgets(5));
    expect(find.byKey(const ValueKey('live-icon-bike')), findsOneWidget);
  });

  testWidgets('Traccar still loading -> spinner, not an empty list', (tester) async {
    final db = await _fixture();
    final pending = Completer<List<Map<String, dynamic>>>();
    await tester.pumpWidget(host(db, () => pending.future));
    await settle(tester);
    expect(find.byKey(const ValueKey('speed-picker-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('speed-picker-empty')), findsNothing);
    pending.complete(_devices());
    await settle(tester);
    expect(find.text('LM-6435'), findsOneWidget);
  });

  testWidgets('Traccar fails -> error with RETRY, which loads the list', (tester) async {
    final db = await _fixture();
    var fail = true;
    await tester.pumpWidget(host(db, () async {
      if (fail) throw Exception('Traccar unreachable');
      return _devices();
    }));
    await settle(tester);
    expect(find.byKey(const ValueKey('speed-picker-error')), findsOneWidget);
    expect(find.textContaining('Traccar unreachable'), findsOneWidget);
    fail = false;
    await tester.tap(find.byKey(const ValueKey('speed-picker-retry')));
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('LM-6435'), findsOneWidget);
  });

  testWidgets('no trucks/bikes at all -> explicit empty message', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(host(db, () async => _devices()));
    await settle(tester);
    expect(find.byKey(const ValueKey('speed-picker-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('speed-picker-loading')), findsNothing);
  });

  test('buildSpeedPickerTruckRows statuses', () {
    final rows = buildSpeedPickerTruckRows(
      trucks: [
        (id: 'a', data: {'truckNumber': 'LM-6435', 'gpsDeviceId': '9210220452'}),
        (id: 'b', data: {'truckNumber': 'X-1'}),
        (id: 'c', data: {'truckNumber': 'X-2', 'gpsDeviceId': 'nope'}),
      ],
      devices: _devices(),
    );
    expect({for (final r in rows) r.truckNumber: r.status}, {
      'LM-6435': SpeedPickerTruckStatus.tracked,
      'X-1': SpeedPickerTruckStatus.noGpsDevice,
      'X-2': SpeedPickerTruckStatus.deviceNotFound,
    });
    expect(Timestamp.now(), isNotNull);
  });
}
