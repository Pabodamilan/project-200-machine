// Tests for performance pass 2 (N+1 queries + shared reference-collection
// cache). Each test proves two things per fix: the query COUNT dropped
// (via a counting Firestore/Query wrapper, same noSuchMethod-chaining
// technique as test/truck_parts_map_test.dart's _ThrowingRepairsFirestore),
// and the RESULT is unchanged from the old per-row/per-id loop.
//
// calculateCategoryLoadCounts/loadWorkRecordsBySessionDate/
// recomputeRepairListProgress were pulled out of their private
// State-method/file-private homes into public, db-injectable top-level
// functions specifically so they're directly testable here — their
// enclosing screens (OwnerDashboard, SiteHistoryScreen, UserProfileScreen)
// have no firestoreOverride seam of their own, and adding one would mean
// threading a db override through dozens of unrelated reads in those large
// dashboards, which is out of scope for this performance-only pass.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

// Counts .get() calls on a specific collection/collectionGroup query chain
// (matched by name), forwarding `where(field, whereIn: ...)`/`isEqualTo`
// and everything else to the real fake instance. Minimal, targeted
// member interception — same convention as this suite's existing
// _Throwing*/_Counting* helpers — not a generic reflection-based proxy.
class _CountingQuery implements Query<Map<String, dynamic>> {
  final Query<Map<String, dynamic>> inner;
  final _Counter counter;
  _CountingQuery(this.inner, this.counter);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #where) {
      final field = invocation.positionalArguments[0];
      Query<Map<String, dynamic>> q = inner;
      final whereIn = invocation.namedArguments[#whereIn] as List<Object?>?;
      final isEqualTo = invocation.namedArguments[#isEqualTo];
      if (whereIn != null) q = q.where(field, whereIn: whereIn);
      if (isEqualTo != null) q = q.where(field, isEqualTo: isEqualTo);
      return _CountingQuery(q, counter);
    }
    if (name == #get) {
      counter.count++;
      return inner.get();
    }
    if (name == #snapshots) {
      return inner.snapshots();
    }
    return super.noSuchMethod(invocation);
  }
}

class _Counter {
  int count = 0;
}

class _CountingFirestore implements FirebaseFirestore {
  final FirebaseFirestore inner;
  final String watchedCollectionGroup;
  final String watchedCollection;
  final _Counter collectionGroupGetCount;
  final _Counter collectionGetCount;
  // How many times .collection(watchedCollection) itself was called on
  // this Firestore instance — distinct from collectionGetCount, which
  // counts .get() calls on the RETURNED reference. Used to prove
  // ReferenceCollectionCache's putIfAbsent factory only runs once.
  final _Counter collectionCallCount;
  _CountingFirestore(
    this.inner, {
    this.watchedCollectionGroup = '',
    this.watchedCollection = '',
    required this.collectionGroupGetCount,
    required this.collectionGetCount,
    _Counter? collectionCallCount,
  }) : collectionCallCount = collectionCallCount ?? _Counter();

  @override
  Query<Map<String, dynamic>> collectionGroup(String collectionPath) {
    if (collectionPath == watchedCollectionGroup) {
      return _CountingQuery(inner.collectionGroup(collectionPath), collectionGroupGetCount);
    }
    return inner.collectionGroup(collectionPath);
  }

  @override
  CollectionReference<Map<String, dynamic>> collection(String collectionPath) {
    if (collectionPath == watchedCollection) {
      collectionCallCount.count++;
      return _CountingCollection(inner.collection(collectionPath), collectionGetCount);
    }
    return inner.collection(collectionPath);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CountingCollection implements CollectionReference<Map<String, dynamic>> {
  final CollectionReference<Map<String, dynamic>> inner;
  final _Counter counter;
  _CountingCollection(this.inner, this.counter);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #where) {
      final field = invocation.positionalArguments[0];
      Query<Map<String, dynamic>> q = inner;
      final whereIn = invocation.namedArguments[#whereIn] as List<Object?>?;
      if (whereIn != null) q = q.where(field, whereIn: whereIn);
      return _CountingQuery(q, counter);
    }
    if (name == #get) {
      counter.count++;
      return inner.get();
    }
    if (name == #snapshots) {
      return inner.snapshots();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  tearDown(() {
    ReferenceCollectionCache.reset();
  });

  group('calculateCategoryLoadCounts (OwnerDashboard pie chart)', () {
    test(
      'one collectionGroup query (not one work_records .get() per session) '
      'and results match the old per-session-loop semantics',
      () async {
        final inner = FakeFirebaseFirestore();
        await inner.collection('daily_sessions').doc('s1').set({'date': '2026-01-01'});
        await inner.collection('daily_sessions').doc('s2').set({'date': '2026-01-01'});
        await inner
            .collection('daily_sessions')
            .doc('s1')
            .collection('work_records')
            .doc('r1')
            .set({'date': '2026-01-01', 'isCompleted': true, 'category': 'Sand'});
        await inner
            .collection('daily_sessions')
            .doc('s1')
            .collection('work_records')
            .doc('r2')
            .set({'date': '2026-01-01', 'isCompleted': false, 'category': 'Sand'});
        await inner
            .collection('daily_sessions')
            .doc('s2')
            .collection('work_records')
            .doc('r3')
            .set({'date': '2026-01-01', 'isCompleted': true, 'category': 'Gravel'});

        final groupCount = _Counter();
        final counting = _CountingFirestore(
          inner,
          watchedCollectionGroup: 'work_records',
          collectionGroupGetCount: groupCount,
          collectionGetCount: _Counter(),
        );

        final sessionsSnap = await inner
            .collection('daily_sessions')
            .where('date', isEqualTo: '2026-01-01')
            .get();
        final sessions = sessionsSnap.docs;
        expect(sessions.length, 2); // s1, s2 — this is the old per-session loop count

        final result = await calculateCategoryLoadCounts(sessions, db: counting);

        expect(groupCount.count, 1); // was 2 (one work_records .get() per session)
        expect(result, {'Sand': 1, 'Gravel': 1}); // only isCompleted:true counted
      },
    );
  });

  group('loadWorkRecordsBySessionDate (SiteHistoryScreen/UserProfileScreen rows)', () {
    test(
      'one collectionGroup query (not 2 work_records .get() per row) and '
      'records are grouped under the correct parent session id',
      () async {
        final inner = FakeFirebaseFirestore();
        await inner.collection('daily_sessions').doc('sessionA').set({'date': '2026-02-01'});
        await inner.collection('daily_sessions').doc('sessionB').set({'date': '2026-02-01'});
        await inner
            .collection('daily_sessions')
            .doc('sessionA')
            .collection('work_records')
            .doc('a1')
            .set({'date': '2026-02-01', 'isCompleted': true, 'totalDurationSeconds': 100});
        await inner
            .collection('daily_sessions')
            .doc('sessionB')
            .collection('work_records')
            .doc('b1')
            .set({'date': '2026-02-01', 'isCompleted': true, 'totalDurationSeconds': 200});
        await inner
            .collection('daily_sessions')
            .doc('sessionB')
            .collection('work_records')
            .doc('b2')
            .set({'date': '2026-02-01', 'isCompleted': false, 'totalDurationSeconds': 50});

        final groupCount = _Counter();
        final counting = _CountingFirestore(
          inner,
          watchedCollectionGroup: 'work_records',
          collectionGroupGetCount: groupCount,
          collectionGetCount: _Counter(),
        );

        final sessionsSnap = await inner.collection('daily_sessions').get();
        final sessions = sessionsSnap.docs; // 2 sessions -> old code: 2 x 2 = 4 reads

        final result = await loadWorkRecordsBySessionDate(sessions, db: counting);

        expect(groupCount.count, 1);
        expect(result['sessionA']?.length, 1);
        expect(result['sessionA']!.first['totalDurationSeconds'], 100);
        expect(result['sessionB']?.length, 2);
        final sessionBDurations =
            result['sessionB']!.map((r) => r['totalDurationSeconds']).toSet();
        expect(sessionBDurations, {200, 50});
      },
    );

    test('returns an empty map (no query at all) for an empty session list', () async {
      final result = await loadWorkRecordsBySessionDate(const []);
      expect(result, isEmpty);
    });
  });

  group('recomputeRepairListProgress (technical MARK DONE / management RETURN)', () {
    test(
      'one whereIn batch (not one .doc(id).get() per item) and status '
      'counts match the old per-id-loop semantics, including a missing doc',
      () async {
        final inner = FakeFirebaseFirestore();
        await inner.collection('repairs').doc('r1').set({'status': 'DONE_PENDING_APPROVAL'});
        await inner.collection('repairs').doc('r2').set({'status': 'LISTED'});
        await inner.collection('repairs').doc('r3').set({'status': 'DONE_PENDING_APPROVAL'});
        // r4 deliberately missing/deleted — old code's d.data()?['status'] ?? ''
        // contributed an empty-string status for it; the new whereIn batch
        // must do the same, not just drop it.
        await inner.collection('repair_lists').doc('list1').set({
          'itemIds': ['r1', 'r2', 'r3', 'r4'],
          'status': 'SUBMITTED',
          'doneCount': 0,
        });

        final collectionCount = _Counter();
        final counting = _CountingFirestore(
          inner,
          watchedCollection: 'repairs',
          collectionGroupGetCount: _Counter(),
          collectionGetCount: collectionCount,
        );

        await recomputeRepairListProgress(counting, 'list1');

        expect(collectionCount.count, 1); // was 4 (one .doc(id).get() per itemId)
        final updated = await inner.collection('repair_lists').doc('list1').get();
        // 2 of 4 items are "technically done" (DONE_PENDING_APPROVAL) — not
        // all 4, so status stays SUBMITTED, same as the old loop would
        // compute (r4's missing doc contributes a non-done '' status).
        expect(updated.data()!['doneCount'], 2);
        expect(updated.data()!['status'], RepairListStatus.submitted);
      },
    );
  });

  group('ReferenceCollectionCache (shared sites/trucks/machines/bikes listener)', () {
    test('repeated stream() calls for the same db share one underlying .collection() call', () {
      final inner = FakeFirebaseFirestore();
      final collectionCallCount = _Counter();
      final counting = _CountingFirestore(
        inner,
        watchedCollection: 'sites',
        collectionGroupGetCount: _Counter(),
        collectionGetCount: _Counter(),
        collectionCallCount: collectionCallCount,
      );

      final a = ReferenceCollectionCache.stream('sites', db: counting);
      final b = ReferenceCollectionCache.stream('sites', db: counting);
      final c = ReferenceCollectionCache.stream('sites', db: counting);

      expect(identical(a, b), isTrue);
      expect(identical(b, c), isTrue);
      expect(collectionCallCount.count, 1); // was called once per stream() before this fix
    });

    test('different db instances (as in two separate widget tests) never share a cache entry', () async {
      final firestoreA = FakeFirebaseFirestore();
      await firestoreA.collection('sites').doc('a').set({'name': 'Site A'});
      final firestoreB = FakeFirebaseFirestore();
      await firestoreB.collection('sites').doc('b').set({'name': 'Site B'});

      final streamA = ReferenceCollectionCache.stream('sites', db: firestoreA);
      final streamB = ReferenceCollectionCache.stream('sites', db: firestoreB);

      expect(identical(streamA, streamB), isFalse);
      final snapA = await streamA.first;
      final snapB = await streamB.first;
      expect(snapA.docs.single.id, 'a');
      expect(snapB.docs.single.id, 'b');
    });

    test('forceRefresh opens a fresh stream instead of reusing a cached one', () {
      final firestore = FakeFirebaseFirestore();
      final first = ReferenceCollectionCache.stream('trucks', db: firestore);
      final refreshed =
          ReferenceCollectionCache.stream('trucks', db: firestore, forceRefresh: true);
      expect(identical(first, refreshed), isFalse);
    });

    test('a live update to the underlying collection still reaches every subscriber', () async {
      final firestore = FakeFirebaseFirestore();
      final stream = ReferenceCollectionCache.stream('machines', db: firestore);
      final emissions = <int>[];
      final sub = stream.listen((snap) => emissions.add(snap.docs.length));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await firestore.collection('machines').doc('m1').set({'name': 'Excavator'});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
      expect(emissions, contains(1)); // the new doc's emission was observed
    });
  });
}
