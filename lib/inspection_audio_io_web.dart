// Web implementation for main.dart's conditional import — see
// inspection_audio_io_stub.dart for the non-web fallback this replaces on
// web builds. Never actually called: on web, record's AudioRecorder.stop()
// returns a blob: URL instead of a real file path, which the caller reads
// via http.get() (works on every platform, no dart:io needed) rather than
// through this function at all — this stub exists only so the conditional
// import resolves to something on web.
import 'dart:typed_data';

Future<Uint8List> readRecordedAudioBytes(String path) async {
  throw UnsupportedError(
    'readRecordedAudioBytes is not used on web — audio bytes are read '
    'from the blob: URL via http.get instead.',
  );
}
