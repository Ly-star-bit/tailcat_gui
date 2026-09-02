/// Dart mirrors of the JSON API in core/engine (commands.go, events.go).
library;

enum SessionKind {
  server,
  forward,
  socks,
  send,
  recv,
  ssh,
  unknown;

  static SessionKind parse(String? s) => SessionKind.values.firstWhere(
        (k) => k.name == s,
        orElse: () => SessionKind.unknown,
      );

  String get label => switch (this) {
        SessionKind.server => '服务端',
        SessionKind.forward => '端口映射',
        SessionKind.socks => 'SOCKS5',
        SessionKind.send => '发送',
        SessionKind.recv => '接收',
        SessionKind.ssh => 'SSH',
        SessionKind.unknown => '会话',
      };
}

enum SessionState {
  starting,
  running,
  done,
  stopped,
  failed;

  static SessionState parse(String? s) => SessionState.values.firstWhere(
        (k) => k.name == s,
        orElse: () => SessionState.starting,
      );

  bool get isActive => this == starting || this == running;

  String get label => switch (this) {
        SessionState.starting => '启动中',
        SessionState.running => '运行中',
        SessionState.done => '已完成',
        SessionState.stopped => '已停止',
        SessionState.failed => '失败',
      };
}

class PathInfo {
  const PathInfo({required this.via, required this.detail, this.latencyMs});
  final String via; // "derp" | "direct" | ""
  final String detail;
  final double? latencyMs;

  bool get isDirect => via == 'direct';
  bool get isKnown => via.isNotEmpty;
}

class Session {
  const Session({
    required this.id,
    required this.kind,
    required this.state,
    this.detail = '',
    this.token,
    this.info = const {},
    this.path,
    this.createdMs = 0,
    this.lastError,
  });

  final String id;
  final SessionKind kind;
  final SessionState state;
  final String detail;
  final String? token;
  final Map<String, dynamic> info;
  final PathInfo? path;
  final int createdMs;
  final String? lastError;

  int? get localPort => (info['local_port'] as num?)?.toInt();
  int? get remotePort => (info['remote_port'] as num?)?.toInt();
  String? get listen => info['listen'] as String?;
  int get peers => (info['peers'] as num?)?.toInt() ?? 0;

  /// One-line description of what this session serves / connects.
  String get summary {
    switch (kind) {
      case SessionKind.server:
        final parts = <String>[];
        final ports = (info['ports'] as List?)?.cast<num>() ?? const [];
        if (info['all'] == true) parts.add('所有端口');
        if (ports.isNotEmpty) parts.add('端口 ${ports.join(', ')}');
        if (info['exit_node'] == true) parts.add('出口节点');
        if (info['files_dir'] != null) {
          parts.add('文件 ${info['files_dir']} (${info['files_mode']})');
        }
        if (info['ssh'] == true) parts.add('SSH');
        return parts.join(' · ');
      case SessionKind.forward:
        return '本地 ${info['listen'] ?? localPort} → 远端 $remotePort';
      case SessionKind.ssh:
        return 'ssh 经本地端口 $localPort';
      case SessionKind.socks:
        return 'SOCKS5 于 ${listen ?? ''}';
      case SessionKind.send:
        final paths = (info['paths'] as List?)?.length ?? 0;
        return '上传 $paths 项到 ${info['remote_dir'] ?? '.'}';
      case SessionKind.recv:
        final paths = (info['remote_paths'] as List?)?.length ?? 0;
        return '下载 $paths 项到 ${info['local_dir'] ?? ''}';
      case SessionKind.unknown:
        return detail;
    }
  }

  Session copyWith({
    SessionState? state,
    String? detail,
    String? token,
    Map<String, dynamic>? info,
    PathInfo? path,
    String? lastError,
  }) =>
      Session(
        id: id,
        kind: kind,
        state: state ?? this.state,
        detail: detail ?? this.detail,
        token: token ?? this.token,
        info: info ?? this.info,
        path: path ?? this.path,
        createdMs: createdMs,
        lastError: lastError ?? this.lastError,
      );

  static const _known = {
    'session_id', 'kind', 'state', 'detail', 'token', 'created_ms', 'type', 'ts'
  };

  /// Builds from a list_sessions row or a session_state event.
  factory Session.fromJson(Map<String, dynamic> j, {Session? previous}) {
    final info = Map<String, dynamic>.from(previous?.info ?? const {});
    for (final e in j.entries) {
      if (!_known.contains(e.key)) info[e.key] = e.value;
    }
    return Session(
      id: j['session_id'] as String,
      kind: SessionKind.parse(j['kind'] as String?),
      state: SessionState.parse(j['state'] as String?),
      detail: (j['detail'] as String?) ?? previous?.detail ?? '',
      token: (j['token'] as String?) ?? previous?.token,
      info: info,
      path: previous?.path,
      createdMs: (j['created_ms'] as num?)?.toInt() ??
          previous?.createdMs ??
          DateTime.now().millisecondsSinceEpoch,
      lastError: previous?.lastError,
    );
  }
}

class Transfer {
  const Transfer({
    required this.sessionId,
    required this.file,
    required this.bytes,
    required this.total,
    required this.direction,
    required this.done,
    this.rateBps = 0,
  });

  final String sessionId;
  final String file;
  final int bytes;
  final int total; // -1 unknown
  final String direction; // up | down
  final bool done;
  final double rateBps;

  String get key => '$sessionId|$file';
  double? get fraction => total > 0 ? (bytes / total).clamp(0, 1) : null;
}

class LogLine {
  const LogLine({
    required this.ts,
    required this.level,
    required this.msg,
    this.sessionId,
  });
  final int ts;
  final String level;
  final String msg;
  final String? sessionId;
}

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.size,
    required this.isDir,
    required this.dir,
    this.mtimeMs = 0,
  });
  final String name;
  final int size;
  final bool isDir;
  final String dir;
  final int mtimeMs;

  String get path => dir == '.' || dir.isEmpty ? name : '$dir/$name';

  factory RemoteEntry.fromJson(Map<String, dynamic> j) => RemoteEntry(
        name: j['name'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        isDir: j['is_dir'] == true,
        dir: (j['dir'] as String?) ?? '.',
        mtimeMs: (j['mtime_ms'] as num?)?.toInt() ?? 0,
      );
}

class Caps {
  const Caps({
    required this.platform,
    required this.arch,
    required this.version,
    required this.tailcat,
    required this.sshServer,
  });
  final String platform;
  final String arch;
  final String version;
  final String tailcat;
  final bool sshServer;

  factory Caps.fromJson(Map<String, dynamic> j) => Caps(
        platform: (j['platform'] as String?) ?? '',
        arch: (j['arch'] as String?) ?? '',
        version: (j['version'] as String?) ?? '',
        tailcat: (j['tailcat'] as String?) ?? '',
        sshServer: j['ssh_server'] == true,
      );
}

class EngineException implements Exception {
  const EngineException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

// ---- events ----

sealed class EngineEvent {
  const EngineEvent(this.raw);
  final Map<String, dynamic> raw;
  String? get sessionId => raw['session_id'] as String?;
  int get ts => (raw['ts'] as num?)?.toInt() ?? 0;

  static EngineEvent fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'session_state':
        return SessionStateEvent(j);
      case 'token_ready':
        return TokenReadyEvent(j);
      case 'log':
        return LogEvent(j);
      case 'progress':
        return ProgressEvent(j);
      case 'path':
        return PathEvent(j);
      case 'error':
        return ErrorEvent(j);
      default:
        return UnknownEvent(j);
    }
  }
}

class SessionStateEvent extends EngineEvent {
  const SessionStateEvent(super.raw);
  SessionState get state => SessionState.parse(raw['state'] as String?);
}

class TokenReadyEvent extends EngineEvent {
  const TokenReadyEvent(super.raw);
  String get token => raw['token'] as String;
}

class LogEvent extends EngineEvent {
  const LogEvent(super.raw);
  String get level => (raw['level'] as String?) ?? 'info';
  String get msg => (raw['msg'] as String?) ?? '';
}

class ProgressEvent extends EngineEvent {
  const ProgressEvent(super.raw);
  Transfer get transfer => Transfer(
        sessionId: sessionId ?? '',
        file: (raw['file'] as String?) ?? '',
        bytes: (raw['bytes'] as num?)?.toInt() ?? 0,
        total: (raw['total'] as num?)?.toInt() ?? -1,
        direction: (raw['direction'] as String?) ?? '',
        done: raw['done'] == true,
        rateBps: (raw['rate_bps'] as num?)?.toDouble() ?? 0,
      );
}

class PathEvent extends EngineEvent {
  const PathEvent(super.raw);
  PathInfo get path => PathInfo(
        via: (raw['via'] as String?) ?? '',
        detail: (raw['detail'] as String?) ?? '',
        latencyMs: (raw['latency_ms'] as num?)?.toDouble(),
      );
  int? get peers => (raw['peers'] as num?)?.toInt();
}

class ErrorEvent extends EngineEvent {
  const ErrorEvent(super.raw);
  String get code => (raw['code'] as String?) ?? 'internal';
  String get message => (raw['message'] as String?) ?? '';
}

class UnknownEvent extends EngineEvent {
  const UnknownEvent(super.raw);
}
