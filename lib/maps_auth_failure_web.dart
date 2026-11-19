// Web implementation of the gm_authFailure hook — see
// maps_auth_failure_stub.dart for the non-web no-op this replaces there,
// and main.dart's conditional import of both. Google Maps JavaScript API
// calls window.gm_authFailure itself (see
// https://developers.google.com/maps/documentation/javascript/events#auth-errors)
// whenever the API key/referrer/quota check fails — on web that is a
// RefererNotAllowedMapError, InvalidKeyMapError, etc., and it is Google's
// own injected JS, not this app's, that then paints "Oops! Something went
// wrong. This page didn't load Google Maps correctly." directly into the
// map's DOM node. No Dart exception is ever thrown for this — it happens
// entirely outside the Flutter widget tree and ErrorWidget/try-catch/
// FutureBuilder error handling, which is why none of those previously
// showed anything for it. This hook is the only way to observe it from
// Dart at all.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void installGoogleMapsAuthFailureHook(void Function() onFailure) {
  globalContext.setProperty('gm_authFailure'.toJS, onFailure.toJS);
}
