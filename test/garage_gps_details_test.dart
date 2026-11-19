// Garage GPS details: GarageService.fetchStatus() is what
// _GarageVehicleDetailScreenState/_GarageTrucksTabState/_GarageBikesTabState
// drive through a FutureBuilder — its null/success/error outcomes map
// directly onto that FutureBuilder's "No GPS data available" + RETRY,
// normal GPS-details body, and "GPS unavailable" + RETRY branches
// respectively (see lib/main.dart around _GarageVehicleDetailScreenState.
// build(), ~line 30918). The Garage screens themselves have no
// firestoreOverride/DI seam (they're private classes reached only by
// pushing GarageScreen, which calls FirebaseFirestore.instance/
// FirebaseAuth.instance directly) and GarageScreen itself isn't exported
// from this library, so they can't be pumped against fake data in this
// test. Instead, this file drives GarageService.fetchStatus directly
// against a FakeFirebaseFirestore vehicle doc and a fake Traccar
// (VehicleKmCache's test overrides) — proving the two outcomes Garage's
// task asked for: GPS details resolve correctly end-to-end with a fake
// Traccar, and a genuine Traccar failure propagates as a REJECTED future
// (not swallowed into a null), which is exactly the condition the
// "GPS unavailable" + RETRY branch depends on.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  tearDown(() => VehicleKmCache.reset());

  Future<QueryDocumentSnapshot<Map<String, dynamic>>> seedTruck(
    FakeFirebaseFirestore firestore, {
    String id = 't1',
    String truckNumber = 'WP-1111',
    String? gpsDeviceId = 'DEV1',
    double gpsKmBaselineAtLastService = 1000,
  }) async {
    await firestore.collection('trucks').doc(id).set({
      'truckNumber': truckNumber,
      'isCompanyTruck': true,
      'gpsDeviceId': gpsDeviceId,
      'gpsKmBaselineAtLastService': gpsKmBaselineAtLastService,
    });
    final snap = await firestore.collection('trucks').where('truckNumber', isEqualTo: truckNumber).get();
    return snap.docs.single;
  }

  group('GarageService.fetchStatus: GPS details resolve with a fake Traccar', () {
    test('a healthy fake Traccar resolves devices + summary into a correct GarageVehicleStatus', () async {
      final firestore = FakeFirebaseFirestore();
      final truck = await seedTruck(firestore);

      VehicleKmCache.devicesFetcherOverride = () => Future.value([
            {'id': 11, 'uniqueId': 'DEV1'},
          ]);
      VehicleKmCache.kmFetcherOverride = (deviceId) => Future.value(45000.0);

      final status =
          await GarageService.fetchStatus(truck, db: firestore, uidOverride: 'test-uid');

      expect(status, isNotNull);
      expect(status!.vehicleNumber, 'WP-1111');
      expect(status.isBike, isFalse);
      expect(status.deviceId, 11);
      expect(status.currentTotalKm, 45000.0);
      expect(status.kmSinceLastService, 44000.0); // 45000 - 1000 baseline
    });

    test('a bike resolves the same way, keyed off bikeNumber/isBike', () async {
      final firestore = FakeFirebaseFirestore();
      await firestore.collection(kBikesCollection).doc('b1').set({
        'bikeNumber': 'BIKE-9',
        'isCompanyBike': true,
        'gpsDeviceId': 'DEV9',
        'gpsKmBaselineAtLastService': 200.0,
      });
      final bikeSnap =
          await firestore.collection(kBikesCollection).where('bikeNumber', isEqualTo: 'BIKE-9').get();
      final bike = bikeSnap.docs.single;

      VehicleKmCache.devicesFetcherOverride = () => Future.value([
            {'id': 22, 'uniqueId': 'DEV9'},
          ]);
      VehicleKmCache.kmFetcherOverride = (deviceId) => Future.value(1200.0);

      final status = await GarageService.fetchStatus(
        bike,
        isBike: true,
        db: firestore,
        uidOverride: 'test-uid',
      );

      expect(status, isNotNull);
      expect(status!.vehicleNumber, 'BIKE-9');
      expect(status.isBike, isTrue);
      expect(status.kmSinceLastService, 1000.0);
    });
  });

  group('GarageService.fetchStatus: "No GPS data available" (null, not an error)', () {
    test('returns null without calling Traccar at all when gpsDeviceId is not configured', () async {
      final firestore = FakeFirebaseFirestore();
      final truck = await seedTruck(firestore, gpsDeviceId: null);

      var devicesCalled = false;
      VehicleKmCache.devicesFetcherOverride = () {
        devicesCalled = true;
        return Future.value(const []);
      };

      final status = await GarageService.fetchStatus(truck, db: firestore);

      expect(status, isNull);
      expect(devicesCalled, isFalse);
    });

    test('returns null (not an error) when gpsDeviceId does not match any Traccar device', () async {
      final firestore = FakeFirebaseFirestore();
      final truck = await seedTruck(firestore, gpsDeviceId: 'DEV-UNREGISTERED');

      VehicleKmCache.devicesFetcherOverride = () => Future.value([
            {'id': 11, 'uniqueId': 'DEV1'},
          ]);

      final status = await GarageService.fetchStatus(truck, db: firestore);

      expect(status, isNull);
    });
  });

  group('GarageService.fetchStatus: "GPS unavailable" + RETRY (a genuine Traccar failure)', () {
    test(
      'a failing devices() fetch propagates as a rejected future, not a swallowed null — '
      'this is exactly what drives the Garage "GPS unavailable" + RETRY branch',
      () async {
        final firestore = FakeFirebaseFirestore();
        final truck = await seedTruck(firestore);

        VehicleKmCache.devicesFetcherOverride =
            () => Future.error(Exception('Traccar devices endpoint down'));

        await expectLater(
          GarageService.fetchStatus(truck, db: firestore),
          throwsA(isException),
        );
      },
    );

    test(
      'a failing summary (currentTotalKm) fetch propagates as a rejected future once '
      'devices() has already resolved the deviceId',
      () async {
        final firestore = FakeFirebaseFirestore();
        final truck = await seedTruck(firestore);

        VehicleKmCache.devicesFetcherOverride = () => Future.value([
              {'id': 11, 'uniqueId': 'DEV1'},
            ]);
        VehicleKmCache.kmFetcherOverride =
            (deviceId) => Future.error(Exception('Traccar summary endpoint down'));

        await expectLater(
          GarageService.fetchStatus(truck, db: firestore),
          throwsA(isException),
        );
      },
    );
  });
}
