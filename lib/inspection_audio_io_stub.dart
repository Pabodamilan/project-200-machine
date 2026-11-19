// Non-web fallback for main.dart's conditional import
// (inspection_audio_io_stub.dart if (dart.library.html)
// inspection_audio_io_web.dart) — dart:io has no meaningful web
// implementation (and dart:io doesn't compile at all for the web target),
// so this is what mobile/desktop builds actually link against. On native
// platforms, record's AudioRecorder.stop() returns a real file path, which
// this reads back into bytes for upload.
import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readRecordedAudioBytes(String path) =>
    File(path).readAsBytes();
