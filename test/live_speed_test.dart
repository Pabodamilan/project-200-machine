// Live speed: knots -> km/h conversion, speed -> color band mapping
// (0 / 1 / 40 / 41 / 60 / 61 / null / stale), labels, and the sidebar chip.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  final now = DateTime(2026, 11, 19, 10, 30);
  final fresh = now.subtract(const Duration(seconds: 30));

  group('knotsToKmh', () {
    test('converts knots x 1.852 and rounds to an integer', () {
      expect(knotsToKmh(0), 0);
      expect(knotsToKmh(1), 2); // 1.852
      expect(knotsToKmh(10), 19); // 18.52
      expect(knotsToKmh(21.6), 40); // 40.0032
      expect(knotsToKmh(32.4), 60); // 60.0048
      expect(knotsToKmh(54), 100); // 100.008
      expect(knotsToKmh(27.0), 50);
    });

    test('missing / non-numeric speed is null, never a fake 0', () {
      expect(knotsToKmh(null), isNull);
      expect(knotsToKmh('12'), isNull);
    });

    test('Traccar position -> reading', () {
      final r = LiveSpeedReading.fromTraccarPosition({
        'speed': 24.84, // knots
        'fixTime': fresh.toUtc().toIso8601String(),
      });
      expect(r.kmh, 46);
      expect(r.band(now: now), LiveSpeedBand.moderate);

      final noSpeed = LiveSpeedReading.fromTraccarPosition({
        'fixTime': fresh.toUtc().toIso8601String(),
      });
      expect(noSpeed.kmh, isNull);
      expect(noSpeed.band(now: now), LiveSpeedBand.offline);
    });
  });

  group('liveSpeedBand', () {
    LiveSpeedBand b(int? kmh, [DateTime? fix]) =>
        liveSpeedBand(kmh, fix ?? fresh, now: now);

    test('thresholds', () {
      expect(b(0), LiveSpeedBand.parked);
      expect(b(1), LiveSpeedBand.normal);
      expect(b(40), LiveSpeedBand.normal);
      expect(b(41), LiveSpeedBand.moderate);
      expect(b(60), LiveSpeedBand.moderate);
      expect(b(61), LiveSpeedBand.fast);
      expect(b(null), LiveSpeedBand.offline);
    });

    test('stale (> 5 min) or no fix time -> offline', () {
      expect(
        b(50, now.subtract(const Duration(minutes: 5, seconds: 1))),
        LiveSpeedBand.offline,
      );
      expect(b(50, now.subtract(const Duration(minutes: 5))),
          LiveSpeedBand.moderate);
      expect(liveSpeedBand(50, null, now: now), LiveSpeedBand.offline);
    });

    test('colors', () {
      expect(liveSpeedBandColor(LiveSpeedBand.offline), Colors.grey.shade600);
      expect(liveSpeedBandColor(LiveSpeedBand.parked),
          Colors.blueGrey.shade600);
      expect(liveSpeedBandColor(LiveSpeedBand.normal), Colors.green.shade700);
      expect(liveSpeedBandColor(LiveSpeedBand.moderate),
          Colors.amber.shade800);
      expect(liveSpeedBandColor(LiveSpeedBand.fast), Colors.red.shade700);
      // All five distinct.
      expect(
        LiveSpeedBand.values.map(liveSpeedBandColor).toSet().length,
        LiveSpeedBand.values.length,
      );
    });

    test('every band has a text label (not color only)', () {
      expect(liveSpeedLabel(null, LiveSpeedBand.offline),
          'Offline / no recent data');
      expect(liveSpeedLabel(0, LiveSpeedBand.parked), '0 km/h · Parked');
      expect(liveSpeedLabel(35, LiveSpeedBand.normal), '35 km/h · Normal');
      expect(liveSpeedLabel(55, LiveSpeedBand.moderate), '55 km/h · Moderate');
      expect(liveSpeedLabel(72, LiveSpeedBand.fast), '72 km/h · Fast');
    });
  });

  test('marker snippet includes label and last updated time', () {
    final r = LiveSpeedReading(kmh: 45, fixTime: fresh);
    expect(r.snippet(now: now), 'Speed: 45 km/h · Moderate · Updated 10:29');
    final stale = LiveSpeedReading(
      kmh: 45,
      fixTime: DateTime(2026, 11, 18, 22, 5),
    );
    expect(stale.snippet(now: now),
        'Speed: Offline / no recent data · Updated 18/11 22:05');
    expect(const LiveSpeedReading().snippet(now: now),
        'Speed: Offline / no recent data · Updated: -');
  });

  testWidgets('sidebar chip shows text + band color', (tester) async {
    Future<Container> pumpChip(LiveSpeedReading? r) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: LiveSpeedChip(reading: r))),
      );
      return tester.widget<Container>(
        find.descendant(
          of: find.byType(LiveSpeedChip),
          matching: find.byType(Container),
        ),
      );
    }

    Color colorOf(Container c) => (c.decoration as BoxDecoration).color!;

    var c = await pumpChip(
      LiveSpeedReading(kmh: 72, fixTime: DateTime.now()),
    );
    expect(find.text('72 km/h · Fast'), findsOneWidget);
    expect(colorOf(c), Colors.red.shade700);

    c = await pumpChip(LiveSpeedReading(kmh: 0, fixTime: DateTime.now()));
    expect(find.text('0 km/h · Parked'), findsOneWidget);
    expect(colorOf(c), Colors.blueGrey.shade600);

    c = await pumpChip(null);
    expect(find.text('Offline'), findsOneWidget);
    expect(colorOf(c), Colors.grey.shade600);
  });
}
