// Regression test for the "Sorry/Oops, something went wrong" Live
// Tracking/Garage map failure investigated in this task: confirmed (via a
// scripted headless-browser reproduction against Google's live Maps API
// with this app's real key, both with and without v=quarterly — see the
// task report) to be Google Maps JavaScript API's own injected overlay,
// fired through window.gm_authFailure when the current origin isn't on
// the API key's allowed HTTP referrers (e.g. local `flutter run -d
// chrome` on http://localhost:PORT vs. the published app's real domain).
// It is never a Dart exception, so it can't be reproduced inside
// `flutter test`'s VM — there is no browser, no window, no Google Maps
// JS to fail. What IS testable here, on the VM/non-web platform
// `flutter test` actually runs on, is maps_auth_failure_stub.dart's
// contract: main.dart's `import 'maps_auth_failure_stub.dart' if
// (dart.library.html) 'maps_auth_failure_web.dart'` resolves to this stub
// under `flutter test` (dart.library.html is false on the VM), so this is
// exactly the code path main()'s _installGoogleMapsAuthFailureLogging
// exercises in every non-web test run and on every non-web platform.
import 'package:flutter_test/flutter_test.dart';
import 'package:project_200_machine/maps_auth_failure_stub.dart';

void main() {
  test(
    'installGoogleMapsAuthFailureHook is a safe no-op off the web: it '
    'neither throws nor ever invokes the callback itself (there is no '
    'window.gm_authFailure to hook on this platform)',
    () {
      var called = false;
      expect(
        () => installGoogleMapsAuthFailureHook(() => called = true),
        returnsNormally,
      );
      expect(called, isFalse);
    },
  );
}
