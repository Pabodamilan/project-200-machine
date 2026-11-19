// Daily check photo upload: path/contentType/metadata builders, the
// driver-facing error (uid, role, path, contentType, size) and RETRY that
// keeps the filled check and doesn't re-upload photos that already went up.
import 'dart:typed_data';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46]);
final _png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
final _webp = Uint8List.fromList(
    [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
final _heic = Uint8List.fromList(
    [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('builders', () {
    test('storage path', () {
      expect(
        dailyCheckPhotoStoragePath(
          vehicleNumber: 'lm-6435',
          dateKey: '2026-11-12',
          checkId: 'water_level',
          millis: 1794446751949,
        ),
        'repairs/daily_checks/${normalizeVehicleNumber('lm-6435')}/2026-11-12/'
        'water_level_1794446751949.jpg',
      );
      expect(
        dailyCheckPhotoStoragePath(
          vehicleNumber: 'LM-6435',
          dateKey: '2026-11-12',
          checkId: 'water_level',
          millis: 1,
          contentType: 'image/png',
        ),
        endsWith('/water_level_1.png'),
      );
    });

    test('content type from bytes, defaulting to image/jpeg', () {
      expect(dailyCheckPhotoContentType(_jpeg), 'image/jpeg');
      expect(dailyCheckPhotoContentType(_png), 'image/png');
      expect(dailyCheckPhotoContentType(_webp), 'image/webp');
      expect(dailyCheckPhotoContentType(_heic), 'image/heic');
      expect(dailyCheckPhotoContentType(Uint8List.fromList([1, 2, 3])), 'image/jpeg');
      expect(dailyCheckPhotoContentType(Uint8List(0)), 'image/jpeg');
    });

    test('metadata always carries a contentType', () {
      expect(dailyCheckPhotoMetadata('image/jpeg').contentType, 'image/jpeg');
      expect(dailyCheckPhotoMetadata('image/png').contentType, 'image/png');
    });

    test('error carries uid, role, path, contentType, size; no-auth wording', () {
      final e = DailyCheckUploadException(
        checkLabel: 'Water Level',
        code: 'unauthorized',
        uid: 'uidDriver',
        role: 'driver',
        path: 'repairs/daily_checks/LM-6435/2026-11-12/water_level_1.jpg',
        contentType: 'image/jpeg',
        sizeBytes: 245760,
        cause: 'x',
      );
      expect(e.isUnauthorized, isTrue);
      expect(e.driverMessage, contains('WATER LEVEL'));
      expect(e.driverMessage, contains('answers are kept'));
      expect(e.details, contains('uid: uidDriver'));
      expect(e.details, contains('role: driver'));
      expect(e.details, contains('path: repairs/daily_checks/LM-6435/2026-11-12/water_level_1.jpg'));
      expect(e.details, contains('contentType: image/jpeg'));
      expect(e.details, contains('240.0 KB (245760 bytes)'));
      expect(kDailyCheckMaxPhotoBytes, 12 * 1024 * 1024);
    });
  });

  testWidgets(
      'unauthorized upload -> error dialog with details, nothing saved; '
      'RETRY keeps the filled form and saves the check once',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = FakeFirebaseFirestore();
    await db.collection('users').doc('uidDriver').set({'name': 'Driver Dan', 'role': 'driver'});

    final uploads = <String>[];
    final metadataTypes = <String?>[];
    var denyWater = true;
    Future<String> uploader(String path, Uint8List bytes, SettableMetadata md) async {
      if (path.contains('/water_level_') && denyWater) {
        throw FirebaseException(
          plugin: 'firebase_storage',
          code: 'unauthorized',
          message: 'User is not authorized to perform the desired action.',
        );
      }
      uploads.add(path);
      metadataTypes.add(md.contentType);
      return 'https://example.test/$path';
    }

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: DriverDailyCheckScreen(
        vehicleNumber: 'LM-6435',
        driverName: 'Driver Dan',
        firestoreOverride: db,
        currentUidOverride: 'uidDriver',
        photoUploaderOverride: uploader,
        debugInitialPhotos: {
          'water_level': _jpeg,
          'engine_oil_level': _jpeg,
          'hydraulic_oil_level': _png,
        },
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // A filled-in note that must survive the failed submit.
    await tester.enterText(find.byType(TextField).first, 'TOPPED UP');

    await tester.ensureVisible(find.text('SUBMIT'));
    await tester.tap(find.text('SUBMIT'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    expect(find.byKey(const ValueKey('daily-check-submit-error')), findsOneWidget);
    expect(find.textContaining('WATER LEVEL photo was refused'), findsOneWidget);
    expect(find.textContaining('uid: uidDriver'), findsOneWidget);
    expect(find.textContaining('role: driver'), findsOneWidget);
    expect(find.textContaining('contentType: image/jpeg'), findsOneWidget);
    expect(find.textContaining('path: repairs/daily_checks/'), findsOneWidget);
    expect(find.textContaining('error: unauthorized'), findsOneWidget);
    // Nothing half-saved.
    expect((await db.collection('daily_checks').get()).docs, isEmpty);

    // Server rule fixed; RETRY.
    denyWater = false;
    await tester.tap(find.text('RETRY'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);

    final docs = (await db.collection('daily_checks').get()).docs;
    expect(docs, hasLength(1));
    final checks = (docs.single.data()['checks'] as List).cast<Map<String, dynamic>>();
    expect(checks.map((c) => c['id']), ['water_level', 'engine_oil_level', 'hydraulic_oil_level']);
    expect(checks.every((c) => (c['photoUrl'] as String).startsWith('https://')), isTrue);
    expect(checks.first['note'], 'TOPPED UP');
    expect(checks.last['photoPath'], endsWith('.png'));
    // Each photo uploaded exactly once (water failed first, so nothing had
    // gone up before it; all three uploaded on the retry).
    expect(uploads, hasLength(3));
    expect(metadataTypes, ['image/jpeg', 'image/jpeg', 'image/png']);
  });

  testWidgets('RETRY does not re-upload photos that already succeeded',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = FakeFirebaseFirestore();
    await db.collection('users').doc('uidDriver').set({'name': 'Driver Dan', 'role': 'driver'});

    final uploads = <String>[];
    var denyHydraulic = true;
    Future<String> uploader(String path, Uint8List bytes, SettableMetadata md) async {
      if (path.contains('/hydraulic_oil_level_') && denyHydraulic) {
        throw FirebaseException(plugin: 'firebase_storage', code: 'unauthorized');
      }
      uploads.add(path);
      return 'https://example.test/$path';
    }

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: DriverDailyCheckScreen(
        vehicleNumber: 'LM-6435',
        driverName: 'Driver Dan',
        firestoreOverride: db,
        currentUidOverride: 'uidDriver',
        photoUploaderOverride: uploader,
        debugInitialPhotos: {
          'water_level': _jpeg,
          'engine_oil_level': _jpeg,
          'hydraulic_oil_level': _jpeg,
        },
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.ensureVisible(find.text('SUBMIT'));
    await tester.tap(find.text('SUBMIT'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(uploads, hasLength(2));
    expect(find.textContaining('HYDRAULIC OIL LEVEL'), findsWidgets);

    denyHydraulic = false;
    await tester.tap(find.text('RETRY'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    expect(uploads, hasLength(3));
    expect(uploads.where((p) => p.contains('/water_level_')), hasLength(1));
    expect((await db.collection('daily_checks').get()).docs, hasLength(1));
  });
}
