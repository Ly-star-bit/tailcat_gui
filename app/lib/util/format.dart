String formatBytes(num bytes) {
  if (bytes < 0) return '?';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '${v.toInt()} ${units[i]}' : '${v.toStringAsFixed(1)} ${units[i]}';
}

String formatRate(double bps) => bps <= 0 ? '' : '${formatBytes(bps)}/s';

String formatLatency(double? ms) => ms == null ? '' : '${ms.toStringAsFixed(ms < 10 ? 1 : 0)} ms';

/// Parses "80, 443 8080" style input into unique ports.
List<int> parsePorts(String s) {
  final out = <int>{};
  for (final part in s.split(RegExp(r'[,\s]+'))) {
    if (part.isEmpty) continue;
    final range = part.split('-');
    final a = int.tryParse(range.first);
    final b = range.length > 1 ? int.tryParse(range.last) : a;
    if (a == null || b == null || a < 1 || b > 65535 || b < a || b - a > 1024) {
      throw FormatException('无效端口: $part');
    }
    for (var p = a; p <= b; p++) {
      out.add(p);
    }
  }
  return out.toList()..sort();
}
