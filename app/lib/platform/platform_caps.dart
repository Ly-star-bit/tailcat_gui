import 'dart:io';

/// Static platform facts the UI branches on.
class PlatformCaps {
  static bool get isDesktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Camera QR scanning is wired up on Android only.
  static bool get canScanQr => Platform.isAndroid;

  /// A system `ssh` client we can hand a command to.
  static bool get hasSystemSsh => isDesktop;
}
