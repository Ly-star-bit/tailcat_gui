import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A token the user connected to before.
class RecentPeer {
  const RecentPeer({required this.token, required this.name, required this.lastMs, this.alias});
  final String token;
  final String name;
  final int lastMs;
  final String? alias;

  String get label => (alias ?? '').isNotEmpty ? alias! : name;

  Map<String, dynamic> toJson() => {'token': token, 'name': name, 'last_ms': lastMs, 'alias': alias};

  factory RecentPeer.fromJson(Map<String, dynamic> j) => RecentPeer(
        token: j['token'] as String,
        name: (j['name'] as String?) ?? '',
        lastMs: (j['last_ms'] as num?)?.toInt() ?? 0,
        alias: j['alias'] as String?,
      );

  RecentPeer copyWith({String? name, int? lastMs, String? alias}) =>
      RecentPeer(token: token, name: name ?? this.name, lastMs: lastMs ?? this.lastMs, alias: alias ?? this.alias);
}

/// Most-recent-first list of peers, persisted in SharedPreferences.
class RecentPeersNotifier extends StateNotifier<List<RecentPeer>> {
  RecentPeersNotifier({this.maxItems = 20}) : super(const []) {
    _load();
  }

  static const _key = 'recent_peers_v1';
  final int maxItems;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final list = (jsonDecode(raw) as List).map((e) => RecentPeer.fromJson((e as Map).cast())).toList();
      state = list;
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final p in state) p.toJson()]));
    } catch (_) {}
  }

  /// Records a successful connection; keeps any alias already set.
  Future<void> touch(String token, String name) async {
    final existing = state.where((p) => p.token == token).firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch;
    final updated = existing?.copyWith(name: name, lastMs: now) ?? RecentPeer(token: token, name: name, lastMs: now);
    state = [updated, ...state.where((p) => p.token != token)].take(maxItems).toList();
    await _save();
  }

  Future<void> rename(String token, String alias) async {
    state = [for (final p in state) p.token == token ? p.copyWith(alias: alias) : p];
    await _save();
  }

  Future<void> remove(String token) async {
    state = state.where((p) => p.token != token).toList();
    await _save();
  }
}

final recentPeersProvider = StateNotifierProvider<RecentPeersNotifier, List<RecentPeer>>(
  (ref) => RecentPeersNotifier(),
);
