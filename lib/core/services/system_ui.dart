import 'package:flutter/services.dart';

/// Full screen hides the status and navigation bars until the user swipes
/// from an edge; otherwise the app draws edge-to-edge behind them.
Future<void> applySystemUiMode({required bool fullScreen}) => SystemChrome.setEnabledSystemUIMode(
    fullScreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
