// Non-web fallback for maps_auth_failure_web.dart (main.dart's conditional
// import picks this file on mobile/desktop) — there is no browser, no
// window.gm_authFailure, and no Google Maps JavaScript API outside web, so
// this is a safe no-op.
void installGoogleMapsAuthFailureHook(void Function() onFailure) {}
