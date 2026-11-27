// "Require Daily Vehicle Check Before Trips" switch (RepairSettingsScreen ->
// settings/repair_workflow.requireDailyCheck) and the driver-side gating it
// controls (fetchDailyCheckAllowSkip / DriverTypeScreen auto-prompt).
//
// FakeFirebaseFirestore enforces no rules, so live rejections are simulated
// with a thin wrapper that throws FirebaseException(permission-denied) on
// chosen writes / reads while everything else goes to the fake normally.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

FirebaseException _denied(String path) => FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
      message: 'Simulated permission-denied ($path)',
    );

class _RejectingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final bool rejectSettingsWrite;
  final bool rejectEventsWrite;
  final bool rejectUsersRead;
  _RejectingFirestore(
    this.inner, {
    this.rejectSettingsWrite = false,
    this.rejectEventsWrite = false,
    this.rejectUsersRead = false,
  });

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    final real = inner.collection(path);
    if (path == 'settings') return _Coll(real, this);
    if (path == 'users' && rejectUsersRead) return _Coll(real, this);
    return real;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Test-only wrapper; the sealed Firestore types are never subclassed in lib/.
// ignore: subtype_of_sealed_class
class _Coll implements CollectionReference<Map<String, dynamic>> {
  final CollectionReference<Map<String, dynamic>> inner;
  final _RejectingFirestore owner;
  _Coll(this.inner, this.owner);

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) => _Doc(inner.doc(path), owner);

  @override
  Future<DocumentReference<Map<String, dynamic>>> add(Map<String, dynamic> data) {
    if (inner.id == 'events' && owner.rejectEventsWrite) {
      return Future.error(_denied(inner.path));
    }
    return inner.add(data);
  }

  @override
  String get id => inner.id;

  @override
  String get path => inner.path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Test-only wrapper; the sealed Firestore types are never subclassed in lib/.
// ignore: subtype_of_sealed_class
class _Doc implements DocumentReference<Map<String, dynamic>> {
  final DocumentReference<Map<String, dynamic>> inner;
  final _RejectingFirestore owner;
  _Doc(this.inner, this.owner);

  bool get _isUsers => inner.parent.id == 'users';

  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) {
    if (_isUsers && owner.rejectUsersRead) return Future.error(_denied(inner.path));
    return inner.get(options);
  }

  @override
  Stream<DocumentSnapshot<Map<String, dynamic>>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) =>
      inner.snapshots(includeMetadataChanges: includeMetadataChanges);

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) {
    if (!_isUsers && owner.rejectSettingsWrite) return Future.error(_denied(inner.path));
    return inner.set(data, options);
  }

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) =>
      _Coll(inner.collection(collectionPath), owner);

  @override
  String get id => inner.id;

  @override
  String get path => inner.path;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<FakeFirebaseFirestore> _fixture({bool requireDailyCheck = true}) async {
  final firestore = FakeFirebaseFirestore();
  await firestore.collection('users').doc('uidAdmin').set({'name': 'Admin Alice', 'role': 'admin'});
  await firestore.collection('users').doc('uidDriver').set({'name': 'Driver Dan', 'role': 'driver'});
  await firestore.collection('settings').doc('repair_workflow').set({
    'managerApprovalLimit': 100000,
    'multiQuotationThreshold': 50000,
    'multiQuotationMinCount': 2,
    'testModeAllowSameUser': false,
    'simpleMode': true,
    'requireDailyCheck': requireDailyCheck,
  });
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
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  bool switchValue(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const ValueKey('require-daily-check-switch')))
      .value;

  Future<void> tapSwitch(WidgetTester tester) async {
    // A SnackBar from the previous tap can sit over the switch on a phone.
    tester.state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger)).removeCurrentSnackBar();
    await tester.pump();
    final f = find.byKey(const ValueKey('require-daily-check-switch'));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> pumpSettings(WidgetTester tester, FirebaseFirestore db) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: RepairSettingsScreen(firestoreOverride: db, currentUidOverride: 'uidAdmin'),
    ));
    await settle(tester);
  }

  for (final size in [const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('admin turns the switch OFF then ON: saved + audit events ($label)',
        (tester) async {
      await setSurface(tester, size);
      final firestore = await _fixture();
      await pumpSettings(tester, firestore);
      expect(switchValue(tester), isTrue);

      await tapSwitch(tester);
      expect(tester.takeException(), isNull);
      var doc = await firestore.collection('settings').doc('repair_workflow').get();
      expect(doc.data()!['requireDailyCheck'], isFalse);
      // Other settings untouched (merge).
      expect(doc.data()!['managerApprovalLimit'], 100000);
      expect(switchValue(tester), isFalse);
      expect(find.text('Daily Vehicle Check is now OPTIONAL.'), findsOneWidget);
      expect(find.byKey(const ValueKey('require-daily-check-error')), findsNothing);

      await tapSwitch(tester);
      doc = await firestore.collection('settings').doc('repair_workflow').get();
      expect(doc.data()!['requireDailyCheck'], isTrue);
      expect(switchValue(tester), isTrue);

      final events = await firestore
          .collection('settings')
          .doc('repair_workflow')
          .collection('events')
          .get();
      final actions = events.docs.map((d) => d['action']).toList();
      expect(actions, containsAll(['REQUIRE_DAILY_CHECK_OFF', 'REQUIRE_DAILY_CHECK_ON']));
      expect(events.docs.first['actorName'], 'Admin Alice');
    });
  }

  testWidgets('settings write rejected: switch stays ON, exact reason shown', (tester) async {
    await setSurface(tester, const Size(390, 844));
    final fake = await _fixture();
    await pumpSettings(tester, _RejectingFirestore(fake, rejectSettingsWrite: true));

    await tapSwitch(tester);
    expect(tester.takeException(), isNull);
    expect(switchValue(tester), isTrue);
    final doc = await fake.collection('settings').doc('repair_workflow').get();
    expect(doc.data()!['requireDailyCheck'], isTrue);
    final error = find.byKey(const ValueKey('require-daily-check-error'));
    expect(error, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(of: error, matching: find.byType(Text))).data!;
    expect(text, startsWith('Not saved:'));
    expect(text, contains('permission-denied'));
    expect(text, contains('settings/repair_workflow'));
    expect(text, contains('requireDailyCheck'));
    // Also surfaced as a SnackBar, not silent.
    expect(find.descendant(of: find.byType(SnackBar), matching: find.textContaining('permission-denied')),
        findsOneWidget);
  });

  testWidgets('audit event write rejected: setting still saved, switch OFF, warning shown',
      (tester) async {
    await setSurface(tester, const Size(390, 844));
    final fake = await _fixture();
    await pumpSettings(tester, _RejectingFirestore(fake, rejectEventsWrite: true));

    await tapSwitch(tester);
    expect(tester.takeException(), isNull);
    final doc = await fake.collection('settings').doc('repair_workflow').get();
    expect(doc.data()!['requireDailyCheck'], isFalse);
    expect(switchValue(tester), isFalse);
    final error = find.byKey(const ValueKey('require-daily-check-error'));
    expect(error, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(of: error, matching: find.byType(Text))).data!;
    expect(text, contains('Saved, but the audit log entry failed'));
    expect(text, contains('settings/repair_workflow/events'));
  });

  group('setRequireDailyCheck / gating', () {
    test('no signed-in uid -> unauthenticated error, nothing written', () async {
      final fake = await _fixture();
      await expectLater(
        setRequireDailyCheck(on: false, db: fake, uid: ''),
        throwsA(isA<SettingsWriteException>().having((e) => e.code, 'code', 'unauthenticated')),
      );
      final doc = await fake.collection('settings').doc('repair_workflow').get();
      expect(doc.data()!['requireDailyCheck'], isTrue);
    });

    test('OFF -> driver may skip even when the users/{uid} read fails', () async {
      final fake = await _fixture(requireDailyCheck: false);
      expect(await fetchDailyCheckAllowSkip(db: fake, uid: 'uidDriver'), isTrue);
      expect(
        await fetchDailyCheckAllowSkip(
            db: _RejectingFirestore(fake, rejectUsersRead: true), uid: 'uidDriver'),
        isTrue,
      );
    });

    test('ON -> driver may not skip; admin may', () async {
      final fake = await _fixture();
      expect(await fetchDailyCheckAllowSkip(db: fake, uid: 'uidDriver'), isFalse);
      expect(await fetchDailyCheckAllowSkip(db: fake, uid: 'uidAdmin'), isTrue);
    });

    testWidgets('OFF -> DriverTypeScreen prompt has SKIP and the driver gets past it',
        (tester) async {
      await setSurface(tester, const Size(390, 844));
      final firestore = await _fixture(requireDailyCheck: false);
      await firestore.collection('truck_sessions').doc('sess1').set({
        'driverUid': 'uidDriver',
        'driverName': 'Driver Dan',
        'truckId': 'truck1',
        'truckNumber': 'WP-9999',
        'date': dailyCheckDateKey(DateTime.now()),
        'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: DriverTypeScreen(
          name: 'Driver Dan',
          firestoreOverride: firestore,
          currentUidOverride: 'uidDriver',
        ),
      ));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Daily Check — WP-9999'), findsOneWidget);
      final skip = find.text('SKIP — DO LATER');
      expect(skip, findsOneWidget);
      await tester.ensureVisible(skip);
      await tester.tap(skip);
      await settle(tester);
      expect(find.textContaining('Daily Check — WP-9999'), findsNothing);
      // No daily_checks doc was required to get here.
      expect((await firestore.collection('daily_checks').get()).docs, isEmpty);
    });
  });
}
