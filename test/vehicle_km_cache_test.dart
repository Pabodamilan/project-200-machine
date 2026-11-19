// Tests for the slow-truck-selection fix: VehicleKmCache (lib/main.dart)
// now sits between every "current km for this vehicle" lookup
// (GarageService.fetchStatus, fetchBestKnownKm, fetchVehicleServiceOverview)
// and the real Traccar calls, adding a 2-minute TTL cache, in-flight
// request de-duplication and a hard 5s timeout. These tests prove:
//   (a) a slow GPS response never blocks the rest of the screen, and the
//       km-dependent line shows a loading state before it fills in;
//   (b) a GPS timeout surfaces a visible RETRY instead of an endless spinner,
//       with no exception;
//   (c) switching vehicles quickly never lets a late response for the
//       vehicle the user has since left overwrite the newly-selected one;
//   (d) a second lookup within the TTL (or a concurrent duplicate lookup)
//       never re-invokes the underlying device/km fetchers.
// VehicleKmCache.devicesFetcherOverride/kmFetcherOverride are the test-only
// seams standing in for a real Traccar HTTP client (see that class's doc
// comment in lib/main.dart) — reset in tearDown so no test leaks state into
// the next, same convention as ServiceAlertsCache.reset().
//
// Also covers the Firestore-backed vehicle_km_cache collection layered on
// top of the above (write-through, throttling, swap-protection, instant
// read-before-Traccar, the delta-since-cache Traccar range optimization,
// and the fleet-wide one-query bulk read) — see each test's own doc
// comment below for which part of that feature it proves.
import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';
import 'package:project_200_machine/widgets/truck_parts_map.dart';

// Throws on service_items.where(...).get() specifically — same
// noSuchMethod-chaining technique as test/truck_parts_map_test.dart's
// _ThrowingRepairsFirestore, adapted to a Future-returning get() instead
// of a Stream-returning snapshots().
class _ThrowingServiceItemsFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  _ThrowingServiceItemsFirestore(this.inner);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath == 'service_items') return _ThrowingServiceItemsCollection();
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingServiceItemsCollection implements CollectionReference<Map<String, dynamic>> {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #where) return this;
    if (name == #get) {
      return Future<QuerySnapshot<Map<String, dynamic>>>.error(
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

// Counts .get() calls on the vehicle_km_cache collection specifically —
// same noSuchMethod-chaining technique as the _Throwing* classes above,
// used here to prove the fleet-wide bulk read really is one query, not one
// per vehicle.
class _VehicleKmCacheGetCounter {
  int count = 0;
}

class _CountingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final _VehicleKmCacheGetCounter counter;
  _CountingFirestore(this.inner, this.counter);

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath == kVehicleKmCacheCollection) {
      return _CountingCollection(inner.collection(collectionPath), counter);
    }
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingCollection implements CollectionReference<Map<String, dynamic>> {
  final CollectionReference<Map<String, dynamic>> inner;
  final _VehicleKmCacheGetCounter counter;
  _CountingCollection(this.inner, this.counter);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #get) {
      counter.count++;
      return inner.get();
    }
    if (invocation.memberName == #doc) {
      final args = invocation.positionalArguments;
      return args.isEmpty ? inner.doc() : inner.doc(args[0] as String);
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

  tearDown(() {
    VehicleKmCache.reset();
  });

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

  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    const step = Duration(milliseconds: 200);
    var elapsed = Duration.zero;
    while (elapsed < total) {
      await tester.pump(step);
      elapsed += step;
    }
  }

  Future<FakeFirebaseFirestore> fixture() async {
    final firestore = FakeFirebaseFirestore();
    await firestore.collection('trucks').doc('t1').set({
      'truckNumber': 'WP-1111',
      'isCompanyTruck': true,
      'gpsDeviceId': 'DEV1',
    });
    // No warnBeforeKm margin to speak of — any currentKm >= 5000 is
    // immediately OVERDUE, any currentKm == null is KM UNKNOWN, so the
    // banner/chip always has something to show regardless of whether GPS
    // has resolved yet.
    await firestore.collection('service_items').doc('sched1').set({
      'name': 'Engine Oil Service',
      'intervalKm': 5000,
      'intervalDays': null,
      'warnBeforeKm': 500,
      'appliesTo': 'ALL',
      'vehicleNumbers': <String>[],
      'active': true,
      'sortOrder': 1,
    });
    return firestore;
  }

  for (final size in [const Size(360, 800), const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'TruckProfileScreen: renders immediately while GPS is slow, km line '
      'shows loading then fills with the live reading ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        VehicleKmCache.devicesFetcherOverride = () => Future.delayed(
              const Duration(milliseconds: 800),
              () => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ],
            );
        VehicleKmCache.kmFetcherOverride =
            (deviceId) => Future.delayed(const Duration(milliseconds: 800), () => 6000.0);

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-1111',
            firestoreOverride: firestore,
          ),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull);
        // The screen shell (header) and the small inline loading state
        // render on the very first frame, well before GPS resolves.
        expect(find.text('WP-1111'), findsWidgets);
        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expect(find.textContaining('Current km'), findsNothing);

        await pumpFor(tester, const Duration(seconds: 2));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Current km: 6000'), findsOneWidget);
        expect(find.textContaining('live GPS reading'), findsOneWidget);
      },
    );

    testWidgets(
      'TruckProfileScreen: a hung GPS call shows a RETRY within 25s '
      '(the new per-endpoint timeout, not the old 5s), no exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        // Never completes — simulates a Traccar server that just hangs
        // (distinct from the merely-slow-but-eventually-successful case
        // covered below).
        VehicleKmCache.devicesFetcherOverride =
            () => Completer<List<Map<String, dynamic>>>().future;

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-1111',
            firestoreOverride: firestore,
          ),
        ));
        await tester.pump();
        expect(find.textContaining('Current km'), findsNothing);

        // A hung Traccar call degrades, within the 25s devices() timeout
        // (TraccarService.devicesTimeout / VehicleKmCache.devicesTimeout —
        // raised from the old, too-aggressive 5s that this whole task
        // fixes), to the same Traccar-live -> manual_km_logs -> last
        // service record -> unknown fallback chain a real GPS error
        // already uses (never a fake value) — here there's no fallback km
        // either, so it reads "unknown", with a small refresh icon
        // standing in for RETRY instead of an endless spinner.
        await pumpFor(tester, const Duration(seconds: 26));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('SERVICE: KM UNKNOWN'), findsOneWidget);
        expect(
          find.textContaining('Current km: — (unknown — no GPS and no service history yet)'),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.refresh), findsOneWidget);

        // Tapping the refresh icon asks again (forceRefresh) rather than
        // replaying a cached timeout — still hung here, so it settles back
        // into the same honest "unknown" state, with no exception either
        // time.
        await tester.tap(find.byIcon(Icons.refresh));
        await pumpFor(tester, const Duration(seconds: 26));
        expect(tester.takeException(), isNull);
        expect(
          find.textContaining('Current km: — (unknown — no GPS and no service history yet)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'vehicle_km_cache: a cached value shows instantly while Traccar is '
      'still pending, then the live reading replaces it ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
          'vehicleNumber': 'WP-1111',
          'km': 40123,
          'source': 'traccar',
          'gpsDeviceId': 'DEV1',
          'updatedAt': Timestamp.now(),
          'updatedBy': 'uidSeed',
        });
        VehicleKmCache.devicesFetcherOverride = () => Future.delayed(
              const Duration(seconds: 2),
              () => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ],
            );
        VehicleKmCache.kmFetcherOverride =
            (deviceId) => Future.delayed(const Duration(seconds: 2), () => 45000.0);

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-1111',
            firestoreOverride: firestore,
          ),
        ));
        await pumpFor(tester, const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Last GPS km (as of'), findsOneWidget);
        expect(find.textContaining('40123 km'), findsOneWidget);

        // GarageService.fetchStatus awaits devices() then currentTotalKm()
        // sequentially — each delayed 2s above, so ~4s total before
        // _future resolves.
        await pumpFor(tester, const Duration(seconds: 5));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Current km: 45000'), findsOneWidget);
        expect(find.textContaining('live GPS reading'), findsOneWidget);
      },
    );

    testWidgets(
      'regression: an 8s-slow (but healthy) Traccar response is no longer '
      'killed by the old 5s timeout — fallback shows at 5s, the real value '
      'fills in once the 8s response lands ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
          'vehicleNumber': 'WP-1111',
          'km': 12000,
          'source': 'traccar',
          'gpsDeviceId': 'DEV1',
          'updatedAt': Timestamp.now(),
          'updatedBy': 'uidSeed',
        });
        // devices() + currentTotalKm() are awaited sequentially by
        // GarageService.fetchStatus, so an 8s delay on EACH means ~16s
        // total — comfortably past the old 5s timeout (would have been
        // aborted entirely) and comfortably under the new 25s one.
        VehicleKmCache.devicesFetcherOverride = () => Future.delayed(
              const Duration(seconds: 8),
              () => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ],
            );
        VehicleKmCache.kmFetcherOverride =
            (deviceId) => Future.delayed(const Duration(seconds: 8), () => 60000.0);

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-1111',
            firestoreOverride: firestore,
          ),
        ));

        // At 5s: still the cached fallback, not an error, not the real value.
        await pumpFor(tester, const Duration(seconds: 5));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Last GPS km (as of'), findsOneWidget);
        expect(find.textContaining('12000 km'), findsOneWidget);
        expect(find.textContaining('Current km: 60000'), findsNothing);

        // By ~17s both 8s legs have landed — the real value replaces the
        // fallback. Under the OLD 5s-uniform timeout this would instead
        // have surfaced the "unknown" fallback forever, never 60000.
        await pumpFor(tester, const Duration(seconds: 12));
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Current km: 60000'), findsOneWidget);
        expect(find.textContaining('live GPS reading'), findsOneWidget);
      },
    );

    testWidgets(
      'vehicle_km_cache: a failed/timed-out Traccar fetch keeps the cached '
      'value with its as-of label and a refresh icon, no exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        final firestore = await fixture();
        await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
          'vehicleNumber': 'WP-1111',
          'km': 55555,
          'source': 'traccar',
          'gpsDeviceId': 'DEV1',
          'updatedAt': Timestamp.fromDate(DateTime.now().subtract(const Duration(hours: 2))),
          'updatedBy': 'uidSeed',
        });
        VehicleKmCache.devicesFetcherOverride =
            () => Completer<List<Map<String, dynamic>>>().future;

        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light(),
          home: TruckProfileScreen(
            truckId: 't1',
            truckNumber: 'WP-1111',
            firestoreOverride: firestore,
          ),
        ));
        await pumpFor(tester, const Duration(seconds: 26));

        expect(tester.takeException(), isNull);
        expect(find.textContaining('Current km: 55555'), findsOneWidget);
        expect(find.textContaining('last known GPS reading (as of'), findsOneWidget);
        expect(find.byIcon(Icons.refresh), findsOneWidget);
      },
    );
  }

  testWidgets(
    'TruckProfileScreen: a genuine fetch failure (not just GPS) shows '
    '"Service status unavailable" with a RETRY, no exception',
    (tester) async {
      final firestore = await fixture();
      // No gpsDeviceId path is reached at all here — service_items itself
      // fails, which fetchVehicleServiceOverview does not catch (unlike
      // every GPS-specific failure, which already degrades to the
      // fallback chain tested above).
      await firestore.collection('trucks').doc('t1').update({'gpsDeviceId': null});

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: TruckProfileScreen(
          truckId: 't1',
          truckNumber: 'WP-1111',
          firestoreOverride: _ThrowingServiceItemsFirestore(firestore),
        ),
      ));
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      // kDebugMode (true under flutter test) appends the real error text
      // after the label — see _TruckServiceStatusBannerState.build's
      // kDebugMode branch, part of this task's "show the real error text
      // in a debug-friendly line" requirement.
      expect(find.textContaining('Service status unavailable'), findsOneWidget);
      expect(find.text('RETRY'), findsOneWidget);
    },
  );

  testWidgets(
    'VehicleHealthScreen: switching vehicles quickly never lets the old '
    "vehicle's late GPS response overwrite the newly-selected one",
    (tester) async {
      await setSurface(tester, const Size(390, 844));
      final firestore = await fixture();
      await firestore.collection('trucks').doc('t2').set({
        'truckNumber': 'WP-2222',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV2',
      });
      await firestore.collection('users').doc('uidAdmin').set({'role': 'admin'});
      VehicleKmCache.devicesFetcherOverride = () => Future.value([
            {'id': 11, 'uniqueId': 'DEV1'},
            {'id': 22, 'uniqueId': 'DEV2'},
          ]);
      VehicleKmCache.kmFetcherOverride = (deviceId) {
        if (deviceId == 11) {
          // WP-1111 — deliberately slow and resolves to an OK reading, so
          // if it ever wrongly overwrote WP-2222's result later, the
          // "SERVICE OVERDUE" chip asserted below would have changed.
          return Future.delayed(const Duration(seconds: 3), () => 1000.0);
        }
        return Future.value(9000.0); // WP-2222 — fast, clearly overdue.
      };

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: VehicleHealthScreen(
          initialVehicleNumber: 'WP-1111',
          firestoreOverride: firestore,
          currentUidOverride: 'uidAdmin',
        ),
      ));
      await pumpFor(tester, const Duration(seconds: 2));

      Offset enginePoint() {
        final mapFinder = find.byType(TruckPartsMap);
        final topLeft = tester.getTopLeft(mapFinder);
        final renderSize = tester.getSize(mapFinder);
        final part = buildTruckPartGeometry().firstWhere((p) => p.id == 'engine');
        return topLeft +
            Offset(
              part.normalizedCentroid.dx * renderSize.width,
              part.normalizedCentroid.dy * renderSize.height,
            );
      }

      // Pin 'engine' on WP-1111 — kicks off its slow (3s) GPS lookup.
      await tester.tapAt(enginePoint());
      await tester.pump(const Duration(milliseconds: 100));

      // Switch to WP-2222 before WP-1111's lookup resolves, and re-pin
      // 'engine' there too.
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('WP-2222').last);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(enginePoint());
      await pumpFor(tester, const Duration(milliseconds: 600));

      expect(tester.takeException(), isNull);
      expect(find.text('SERVICE OVERDUE'), findsOneWidget);

      // Let WP-1111's slow response finally land in the background.
      await pumpFor(tester, const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      // Still WP-2222's result — the stale WP-1111 response never applied.
      expect(find.text('SERVICE OVERDUE'), findsOneWidget);
      expect(find.text('SERVICE OK'), findsNothing);
      expect(find.text('SERVICE KM UNKNOWN'), findsNothing);
    },
  );

  test(
    'VehicleKmCache: a second lookup within the TTL does not re-call the '
    'device/km fetchers',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      var devicesCalls = 0;
      var kmCalls = 0;
      VehicleKmCache.devicesFetcherOverride = () async {
        devicesCalls++;
        return [
          {'id': 11, 'uniqueId': 'DEV1'},
        ];
      };
      VehicleKmCache.kmFetcherOverride = (deviceId) async {
        kmCalls++;
        return 1234.0;
      };

      final first = await fetchBestKnownKm('WP-1111', db: firestore);
      final second = await fetchBestKnownKm('WP-1111', db: firestore);

      expect(first.km, 1234.0);
      expect(second.km, 1234.0);
      expect(devicesCalls, 1);
      expect(kmCalls, 1);
      VehicleKmCache.reset();
    },
  );

  test(
    'VehicleKmCache: concurrent lookups for the same vehicle share one '
    'in-flight device/km fetch instead of firing one each',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      var devicesCalls = 0;
      var kmCalls = 0;
      VehicleKmCache.devicesFetcherOverride = () async {
        devicesCalls++;
        await Future.delayed(const Duration(milliseconds: 20));
        return [
          {'id': 11, 'uniqueId': 'DEV1'},
        ];
      };
      VehicleKmCache.kmFetcherOverride = (deviceId) async {
        kmCalls++;
        await Future.delayed(const Duration(milliseconds: 20));
        return 1234.0;
      };

      final results = await Future.wait([
        fetchBestKnownKm('WP-1111', db: firestore),
        fetchBestKnownKm('WP-1111', db: firestore),
        fetchBestKnownKm('WP-1111', db: firestore),
      ]);

      expect(results.map((r) => r.km), everyElement(1234.0));
      expect(devicesCalls, 1);
      expect(kmCalls, 1);
      VehicleKmCache.reset();
    },
  );

  test(
    'mapWithConcurrencyLimit: never runs more than maxConcurrent actions at '
    'once, and preserves each result in order',
    () async {
      var active = 0;
      var maxActive = 0;
      final items = List.generate(10, (i) => i);

      final results = await mapWithConcurrencyLimit(items, 3, (i) async {
        active++;
        maxActive = max(maxActive, active);
        await Future.delayed(const Duration(milliseconds: 10));
        active--;
        return i * 2;
      });

      expect(maxActive, lessThanOrEqualTo(3));
      expect(results, items.map((i) => i * 2).toList());
    },
  );

  test(
    'vehicle_km_cache write-through: throttled — a second successful '
    'Traccar fetch within 30 minutes that changes km by less than 1 does '
    'not write again',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      VehicleKmCache.devicesFetcherOverride =
          () async => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ];
      var call = 0;
      VehicleKmCache.kmFetcherOverride = (deviceId) async {
        call++;
        return call == 1 ? 1000.0 : 1000.5;
      };

      await fetchBestKnownKm('WP-1111', db: firestore);
      var doc = await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').get();
      expect(doc.data()!['km'], 1000.0);

      // forceRefresh so this really re-asks "Traccar" instead of just
      // replaying VehicleKmCache's own 2-minute in-memory cache — the
      // throttle under test here is the FIRESTORE write, not that cache.
      await fetchBestKnownKm('WP-1111', db: firestore, forceRefresh: true);
      doc = await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').get();
      expect(call, 2);
      expect(doc.data()!['km'], 1000.0); // unchanged — throttled
      VehicleKmCache.reset();
    },
  );

  test(
    'vehicle_km_cache write-through: not throttled once the cached doc is '
    'older than 30 minutes, even for a sub-1km change',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
        'vehicleNumber': 'WP-1111',
        'km': 1000.0,
        'source': 'traccar',
        'gpsDeviceId': 'DEV1',
        'updatedAt': Timestamp.fromDate(DateTime.now().subtract(const Duration(minutes: 31))),
        'updatedBy': 'uidSeed',
      });
      VehicleKmCache.devicesFetcherOverride =
          () async => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ];
      VehicleKmCache.kmFetcherOverride = (deviceId) async => 1000.5;

      await fetchBestKnownKm('WP-1111', db: firestore, forceRefresh: true);
      final doc = await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').get();
      expect(doc.data()!['km'], 1000.5); // written — the cached doc was stale
      VehicleKmCache.reset();
    },
  );

  test(
    'vehicle_km_cache write-through: a new reading more than 5km LOWER than '
    'the cached one is treated as a possible device swap and the write is '
    'skipped',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
        'vehicleNumber': 'WP-1111',
        'km': 10000.0,
        'source': 'traccar',
        'gpsDeviceId': 'DEV1',
        'updatedAt': Timestamp.now(),
        'updatedBy': 'uidSeed',
      });
      VehicleKmCache.devicesFetcherOverride =
          () async => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ];
      // 10km lower than cached — past the 5km swap-protection threshold.
      VehicleKmCache.kmFetcherOverride = (deviceId) async => 9990.0;

      final best = await fetchBestKnownKm('WP-1111', db: firestore, forceRefresh: true);

      // The live reading is still shown honestly (never faked)...
      expect(best.km, 9990.0);
      expect(best.source, 'live GPS reading');
      // ...but the persisted cache keeps its older, higher value rather
      // than silently moving backwards.
      final doc = await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').get();
      expect(doc.data()!['km'], 10000.0);
      VehicleKmCache.reset();
    },
  );

  test(
    'fleet screens: fetchFleetServiceOverviewFromCache/VehicleKmCache.allCached '
    'read the vehicle_km_cache collection exactly once, never once per vehicle',
    () async {
      final inner = FakeFirebaseFirestore();
      await inner.collection('trucks').doc('t1').set({'truckNumber': 'WP-1111', 'isCompanyTruck': true});
      await inner.collection('trucks').doc('t2').set({'truckNumber': 'WP-2222', 'isCompanyTruck': true});
      await inner.collection('trucks').doc('t3').set({'truckNumber': 'WP-3333', 'isCompanyTruck': true});
      await inner.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
        'vehicleNumber': 'WP-1111',
        'km': 12345.0,
        'source': 'traccar',
        'gpsDeviceId': 'DEV1',
        'updatedAt': Timestamp.now(),
        'updatedBy': 'uidSeed',
      });
      final counter = _VehicleKmCacheGetCounter();
      final counting = _CountingFirestore(inner, counter);

      final overview = await fetchFleetServiceOverviewFromCache(db: counting);

      expect(overview.length, 3);
      expect(counter.count, 1);
      final wp1111 = overview.firstWhere((o) => o.vehicleNumber == 'WP-1111');
      expect(wp1111.currentKm, 12345.0);
      expect(wp1111.kmSource, contains('last known GPS reading'));
      final wp2222 = overview.firstWhere((o) => o.vehicleNumber == 'WP-2222');
      expect(wp2222.currentKm, isNull);
      expect(wp2222.kmSource, contains('unknown'));

      // A second fleet read within the 5-minute bulk TTL reuses the same
      // cached map — still exactly one collection read overall.
      await fetchFleetServiceOverviewFromCache(db: counting);
      expect(counter.count, 1);
      VehicleKmCache.reset();
    },
  );

  test(
    'GarageService._fetchCurrentTotalKm: once a vehicle_km_cache baseline '
    'exists, Traccar is asked for the DELTA since that baseline only, '
    'added on top of the cached km — not the full 2020-01-01 range',
    () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      final baselineAt = DateTime.now().subtract(const Duration(hours: 3));
      await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
        'vehicleNumber': 'WP-1111',
        'km': 50000.0,
        'source': 'traccar',
        'gpsDeviceId': 'DEV1',
        'updatedAt': Timestamp.fromDate(baselineAt),
        'updatedBy': 'uidSeed',
      });
      VehicleKmCache.devicesFetcherOverride =
          () async => [
                {'id': 11, 'uniqueId': 'DEV1'},
              ];
      // kmFetcherOverride deliberately left unset — this test exercises the
      // REAL GarageService._fetchCurrentTotalKm, intercepted one level
      // lower at TraccarService.fetchDistanceSummary instead.
      DateTime? capturedFrom;
      TraccarService.fetchDistanceSummaryOverride = ({
        required int deviceId,
        required DateTime from,
        required DateTime to,
      }) async {
        capturedFrom = from;
        expect(to.isAfter(baselineAt), isTrue);
        return 25000; // metres — a 25km delta since the cached baseline.
      };

      final best = await fetchBestKnownKm('WP-1111', db: firestore, forceRefresh: true);

      expect(best.source, 'live GPS reading');
      expect(best.km, 50025.0); // 50000 baseline + 25km delta, not a fresh 2020-01-01 total.
      expect(capturedFrom, isNotNull);
      expect(capturedFrom!.difference(baselineAt).inSeconds.abs(), lessThan(2));
      TraccarService.fetchDistanceSummaryOverride = null;
      VehicleKmCache.reset();
    },
  );

  testWidgets(
    'VehicleHealthScreen: a driver gets NO ACCESS and never sees any cached '
    'or live km data',
    (tester) async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection('trucks').doc('t1').set({
        'truckNumber': 'WP-1111',
        'isCompanyTruck': true,
        'gpsDeviceId': 'DEV1',
      });
      await firestore.collection(kVehicleKmCacheCollection).doc('WP-1111').set({
        'vehicleNumber': 'WP-1111',
        'km': 99999.0,
        'source': 'traccar',
        'gpsDeviceId': 'DEV1',
        'updatedAt': Timestamp.now(),
        'updatedBy': 'uidSeed',
      });
      await firestore.collection('users').doc('uidDriver').set({'role': 'driver'});

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: VehicleHealthScreen(
          initialVehicleNumber: 'WP-1111',
          firestoreOverride: firestore,
          currentUidOverride: 'uidDriver',
        ),
      ));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }

      expect(tester.takeException(), isNull);
      expect(find.text('NO ACCESS'), findsOneWidget);
      expect(find.textContaining('99999'), findsNothing);
      expect(find.byType(TruckPartsMap), findsNothing);
    },
  );
}
