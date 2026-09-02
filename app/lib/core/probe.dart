/// Dart mirror of engine.ProbeResult / engine.Manifest (core/engine/probe.go,
/// manifest.go): what the other side of a token offers.
library;

class ShareItem {
  const ShareItem({required this.name, required this.size, required this.isDir});
  final String name;
  final int size;
  final bool isDir;

  factory ShareItem.fromJson(Map<String, dynamic> j) => ShareItem(
        name: j['name'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        isDir: j['is_dir'] == true,
      );
}

class ManifestFiles {
  const ManifestFiles({required this.mode, this.items = const [], this.dir = ''});
  final String mode; // ro | rw | wo
  final List<ShareItem> items;
  final String dir;

  bool get listable => mode != 'wo';
  bool get writable => mode != 'ro';

  factory ManifestFiles.fromJson(Map<String, dynamic> j) => ManifestFiles(
        mode: (j['mode'] as String?) ?? 'ro',
        items: [for (final i in (j['items'] as List?) ?? const []) ShareItem.fromJson((i as Map).cast())],
        dir: (j['dir'] as String?) ?? '',
      );
}

class Manifest {
  const Manifest({
    required this.name,
    required this.platform,
    required this.version,
    this.ports = const [],
    this.all = false,
    this.exitNode = false,
    this.ssh = false,
    this.files,
  });
  final String name;
  final String platform;
  final String version;
  final List<int> ports;
  final bool all;
  final bool exitNode;
  final bool ssh;
  final ManifestFiles? files;

  factory Manifest.fromJson(Map<String, dynamic> j) => Manifest(
        name: (j['name'] as String?) ?? '',
        platform: (j['platform'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        ports: [for (final p in (j['ports'] as List?) ?? const []) (p as num).toInt()],
        all: j['all'] == true,
        exitNode: j['exit_node'] == true,
        ssh: j['ssh'] == true,
        files: j['files'] is Map ? ManifestFiles.fromJson((j['files'] as Map).cast()) : null,
      );
}

class ProbeResult {
  const ProbeResult({
    required this.reachable,
    required this.via,
    required this.detail,
    required this.latencyMs,
    this.manifest,
    this.sftp = false,
    this.sftpList = false,
    this.sshShell = false,
    this.cliFallback = false,
  });
  final bool reachable;
  final String via;
  final String detail;
  final double latencyMs;
  final Manifest? manifest;
  final bool sftp;
  final bool sftpList;
  final bool sshShell;
  final bool cliFallback;

  factory ProbeResult.fromJson(Map<String, dynamic> j) => ProbeResult(
        reachable: j['reachable'] == true,
        via: (j['via'] as String?) ?? '',
        detail: (j['detail'] as String?) ?? '',
        latencyMs: (j['latency_ms'] as num?)?.toDouble() ?? 0,
        manifest: j['manifest'] is Map ? Manifest.fromJson((j['manifest'] as Map).cast()) : null,
        sftp: j['sftp'] == true,
        sftpList: j['sftp_list'] == true,
        sshShell: j['ssh_shell'] == true,
        cliFallback: j['cli_fallback'] == true,
      );

  // ---- what the UI can offer ----

  String get displayName {
    final m = manifest;
    if (m != null && m.name.isNotEmpty) return m.name;
    return cliFallback ? '命令行 tailcat' : '对方设备';
  }

  bool get isDirect => via == 'direct';

  /// Files the other side is handing us ("send these files" share).
  List<ShareItem> get offeredItems => manifest?.files?.items ?? const [];

  /// We can list and download from the other side.
  bool get canBrowse => sftp && sftpList;

  /// We can upload to the other side (rw/wo share, or unknown CLI share).
  bool get canSendFiles {
    final f = manifest?.files;
    if (f != null) return f.writable;
    return cliFallback && sftp && !sftpList; // drop box (tailcat recv)
  }

  /// Ports explicitly listed by the other side.
  List<int> get knownPorts => manifest?.ports ?? const [];

  bool get allPorts => manifest?.all ?? false;

  /// SOCKS5 makes sense when the other side relays to other hosts, or
  /// exposes every port (then `server.tailcat:<port>` works).
  bool get canSocks => (manifest?.exitNode ?? false) || allPorts;

  bool get canSsh => sshShell;

  /// Anything at all besides raw port forwarding.
  bool get hasKnownServices =>
      offeredItems.isNotEmpty || canBrowse || canSendFiles || knownPorts.isNotEmpty || allPorts || canSocks || canSsh;
}
