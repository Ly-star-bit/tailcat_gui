import 'dart:io';

/// Opens the system terminal running [command]. Returns false when this
/// platform has no known terminal launcher (caller falls back to copying).
Future<bool> openTerminalWith(String command) async {
  try {
    if (Platform.isMacOS) {
      final escaped = command.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
      await Process.run('osascript', [
        '-e', 'tell application "Terminal" to do script "$escaped"',
        '-e', 'tell application "Terminal" to activate',
      ]);
      return true;
    }
    if (Platform.isWindows) {
      // `start` opens a new console window; the empty string is the title.
      await Process.start('cmd', ['/c', 'start', '', ...command.split(' ')], mode: ProcessStartMode.detached);
      return true;
    }
    if (Platform.isLinux) {
      for (final term in ['x-terminal-emulator', 'gnome-terminal', 'konsole', 'xterm']) {
        try {
          await Process.start(term, ['-e', 'sh', '-c', '$command; exec \$SHELL'], mode: ProcessStartMode.detached);
          return true;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return false;
}
