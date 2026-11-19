// Regression test for the Live Tracking map not rendering: the root cause
// was `body: isWide ? Row(...) : mapStack` in _LiveTrackingScreenState.
// build() — swapping the WIDGET TYPE at the Scaffold.body slot (Row vs.
// Stack) between builds. Flutter's reconciliation only reuses an Element
// when the widget at a given slot keeps the same runtimeType; a type swap
// there tears down the WHOLE old subtree (including the GoogleMap buried
// inside the Row branch) and mounts a brand new one — exactly the
// "IntersectionObserver... Node cannot be found" Chrome error reported,
// which happens when the platform view is yanked out from under its own
// still-in-flight async init.
//
// The real LiveTrackingScreen can't be pumped here: it has no
// firestoreOverride/DI seam (confirmed — it calls FirebaseFirestore.instance
// and TraccarService directly throughout), and GoogleMap needs a real
// platform view that flutter test's environment doesn't provide (confirmed
// no prior test in this suite exercises GoogleMap at all). Instead, this
// file reproduces the EXACT mechanism in isolation: a tracked child widget
// embedded first in the OLD buggy pattern (proving the bug is real and
// this test methodology catches it), then in the NEW fixed pattern (always
// a Row; only the leading sidebar children are added/removed via `if
// (isWide) ...`, with the tracked child always last) — proving the fixed
// pattern survives both an isWide flip AND repeated unrelated rebuilds
// (standing in for LiveTrackingScreen's 15s poll ticks) without the
// tracked widget's Element ever being torn down and recreated.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _CreationCounter {
  int created = 0;
  int disposed = 0;
}

// Stands in for GoogleMap — any StatefulWidget works for proving Element
// identity; a real platform view isn't needed to prove the mechanism.
class _TrackedWidget extends StatefulWidget {
  final _CreationCounter counter;
  const _TrackedWidget({super.key, required this.counter});

  @override
  State<_TrackedWidget> createState() => _TrackedWidgetState();
}

class _TrackedWidgetState extends State<_TrackedWidget> {
  @override
  void initState() {
    super.initState();
    widget.counter.created++;
  }

  @override
  void dispose() {
    widget.counter.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 10, height: 10);
}

// The OLD buggy shape: body swaps between Row and the bare tracked widget.
class _OldPatternHarness extends StatefulWidget {
  final _CreationCounter counter;
  const _OldPatternHarness({super.key, required this.counter});

  @override
  State<_OldPatternHarness> createState() => _OldPatternHarnessState();
}

class _OldPatternHarnessState extends State<_OldPatternHarness> {
  bool isWide = false;

  void flip() => setState(() => isWide = !isWide);

  @override
  Widget build(BuildContext context) {
    final mapStack = _TrackedWidget(key: const ValueKey('map'), counter: widget.counter);
    return MaterialApp(
      home: Scaffold(
        body: isWide
            ? Row(children: [const SizedBox(width: 50), Expanded(child: mapStack)])
            : mapStack,
      ),
    );
  }
}

// The FIXED shape: body is always a Row; only the leading sidebar item is
// conditionally present, the tracked widget always sits last.
class _FixedPatternHarness extends StatefulWidget {
  final _CreationCounter counter;
  const _FixedPatternHarness({super.key, required this.counter});

  @override
  State<_FixedPatternHarness> createState() => _FixedPatternHarnessState();
}

class _FixedPatternHarnessState extends State<_FixedPatternHarness> {
  bool isWide = false;
  int tick = 0;

  void flip() => setState(() => isWide = !isWide);
  // Stands in for a 15s poll tick's setState (e.g. _refreshPositions
  // updating _markers) — unrelated to isWide, but still a full rebuild.
  void pollTick() => setState(() => tick++);

  @override
  Widget build(BuildContext context) {
    final mapStack = _TrackedWidget(key: const ValueKey('map'), counter: widget.counter);
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            if (isWide) const SizedBox(width: 50),
            Expanded(child: mapStack),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'OLD pattern (isWide ? Row(...) : child) reproduces the regression: '
    'flipping isWide tears down and recreates the map widget',
    (tester) async {
      final counter = _CreationCounter();
      final key = GlobalKey<_OldPatternHarnessState>();
      await tester.pumpWidget(_OldPatternHarness(key: key, counter: counter));
      expect(counter.created, 1);
      expect(counter.disposed, 0);

      key.currentState!.flip(); // isWide flips exactly like a wrong-then-
      // corrected MediaQuery size would between LiveTrackingScreen's first
      // two builds.
      await tester.pump();

      expect(counter.disposed, 1); // the old Element was torn down...
      expect(counter.created, 2); // ...and a brand new one created. The bug.
    },
  );

  testWidgets(
    'FIXED pattern (always Row, conditional leading children only): the '
    'map widget is created exactly once and never torn down across an '
    'isWide flip plus 3 poll-tick rebuilds, no exception',
    (tester) async {
      final counter = _CreationCounter();
      final key = GlobalKey<_FixedPatternHarnessState>();
      await tester.pumpWidget(_FixedPatternHarness(key: key, counter: counter));
      expect(tester.takeException(), isNull);
      expect(counter.created, 1);
      expect(counter.disposed, 0);

      key.currentState!.flip(); // isWide: false -> true
      await tester.pump();
      key.currentState!.flip(); // isWide: true -> false
      await tester.pump();

      // 3 poll-tick-style rebuilds, unrelated to isWide — exactly what
      // LiveTrackingScreen's 15s _refreshPositions timer does to the real
      // screen.
      for (var i = 0; i < 3; i++) {
        key.currentState!.pollTick();
        await tester.pump();
      }

      expect(tester.takeException(), isNull);
      expect(counter.created, 1); // still the one original Element
      expect(counter.disposed, 0); // never torn down
      expect(find.byType(_TrackedWidget), findsOneWidget); // exactly one
    },
  );
}
