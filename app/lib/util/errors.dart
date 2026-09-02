import '../core/models.dart';

/// Turns engine / Go error text into something a person can act on.
String friendlyError(Object e) {
  final raw = e is EngineException ? e.message : e.toString();
  final s = raw.toLowerCase();
  if (e is EngineException && e.code == 'invalid_token') {
    return '令牌格式不对。请完整复制以 tc 开头的那串字符。';
  }
  if (s.contains('not reachable') || s.contains('deadline exceeded') || s.contains('meow')) {
    return '连不上对方。请确认对方的 Tailcat 还在分享中，并且两边网络都正常。';
  }
  if (s.contains('address already in use')) {
    return '本机端口已被其他程序占用，换一个端口试试。';
  }
  if (s.contains('permission denied')) {
    return '对方不允许这个操作（可能是只读共享或仅接收模式）。';
  }
  if (s.contains('no such file')) {
    return '对方那里没有这个文件或目录。';
  }
  if (s.contains('connection refused') || s.contains('reset by peer')) {
    return '对方没有开放这个端口。';
  }
  if (s.contains('not supported on this platform')) {
    return '这个功能在当前平台不可用。';
  }
  return raw;
}
