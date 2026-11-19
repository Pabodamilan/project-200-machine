// Regression test for the performance-audit image pass: login_background*
// .png and logo_final_gradient.png were replaced with re-encoded .webp
// files at the same (or, for the logo, display-appropriate) pixel
// dimensions to cut bundle size, and every Image.asset/AssetImage
// reference in LoginScreen/AuthGate was updated to match. This proves the
// new asset paths actually resolve and render with no exception — a typo
// in either the reference or pubspec.yaml's asset list would otherwise
// only surface as a silent blank image or (for a missing pubspec entry) a
// hard `flutter test`/build failure elsewhere, not a visible assertion
// failure here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  for (final size in [const Size(360, 800), const Size(390, 844), const Size(1200, 900)]) {
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets(
      'LoginScreen: renders with the re-encoded .webp background, no '
      'exception ($label)',
      (tester) async {
        await setSurface(tester, size);
        await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
        await tester.pump();
        await tester.pump();

        expect(tester.takeException(), isNull);
        final container = tester.widget<Container>(
          find.byWidgetPredicate(
            (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).image != null,
          ),
        );
        final decoration = container.decoration as BoxDecoration;
        final image = decoration.image!.image;
        expect(image, isA<AssetImage>());
        expect((image as AssetImage).assetName, 'assets/images/login_background.webp');
      },
    );
  }
}
