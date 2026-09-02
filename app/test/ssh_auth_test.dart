// Regression test for the SSH auth method the in-app terminal relies on.
//
// tailcat's SSH server (and our own file-share server) authenticate with
// SSH's "none" method, because the WireGuard tunnel already identified the
// peer. dartssh2 skips "none" whenever it has any other credential to try,
// so passing a password callback silently broke every terminal session with
// "Connection closed before authentication".
//
// Needs the helper server:  make ssh-auth-test
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

const _binEnv = 'TAILCAT_SSHPROBE_BIN';

void main() {
  final bin = Platform.environment[_binEnv];

  test('dartssh2 authenticates against a no-auth SSH server', () async {
    final proc = await Process.start(bin!, ['--listen', '127.0.0.1:0']);
    addTearDown(proc.kill);

    final portLine = await proc.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('PORT='))
        .timeout(const Duration(seconds: 30));
    final port = int.parse(RegExp(r'PORT=(\d+)').firstMatch(portLine)!.group(1)!);

    final socket = await SSHSocket.connect('127.0.0.1', port, timeout: const Duration(seconds: 15));
    // Exactly what TerminalScreen does: no password callback, so "none" is used.
    final client = SSHClient(socket, username: 'tailcat');
    await client.authenticated.timeout(const Duration(seconds: 20));
    client.close();
  }, skip: bin == null || bin.isEmpty ? 'set $_binEnv to the sshprobe binary' : false);
}
