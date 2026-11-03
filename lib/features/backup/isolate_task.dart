import 'dart:async';
import 'dart:isolate';

/// Progress reported by long-running backup / import work.
typedef ProgressCallback = void Function(double fraction, String message);

/// Runs [task] in a background isolate, forwarding its progress reports to
/// [onProgress] on the calling isolate.
///
/// [task] must only capture sendable values (strings, numbers, lists, maps,
/// records…) – never database connections or widgets. Launch it from a
/// top-level function so the closure context stays minimal.
Future<T> runInBackground<T>(
  FutureOr<T> Function(ProgressCallback progress) task, {
  ProgressCallback? onProgress,
}) async {
  final port = ReceivePort();
  final sub = port.listen((m) {
    if (onProgress != null && m is List && m.length == 2) {
      onProgress((m[0] as num).toDouble(), m[1] as String);
    }
  });
  try {
    return await _spawn(task, port.sendPort);
  } finally {
    await sub.cancel();
    port.close();
  }
}

// Separate function: the closure sent to the isolate must not share a
// context with the listener above (which captures the UI callback).
Future<T> _spawn<T>(FutureOr<T> Function(ProgressCallback progress) task, SendPort send) =>
    Isolate.run(() => task(_throttled(send)));

/// Limits progress messages to visible changes (≥0.5 % or a new message).
ProgressCallback _throttled(SendPort send) {
  var lastF = -1.0;
  var lastM = '';
  return (f, m) {
    if (m != lastM || (f - lastF).abs() >= 0.005 || f >= 1) {
      lastF = f;
      lastM = m;
      send.send([f, m]);
    }
  };
}
