import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'core/core_backend.dart';
import 'core/engine.dart';
import 'core/providers.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? dataDir;
  try {
    dataDir = (await getApplicationSupportDirectory()).path;
  } catch (_) {}
  final engine = Engine(FfiCoreBackend(dataDir: dataDir));
  Object? startError;
  try {
    await engine.start();
  } catch (e) {
    startError = e;
  }
  runApp(
    ProviderScope(
      overrides: [engineProvider.overrideWithValue(engine)],
      child: TailcatApp(startError: startError),
    ),
  );
}

class TailcatApp extends StatelessWidget {
  const TailcatApp({super.key, this.startError});

  final Object? startError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tailcat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3B6EF5), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF3B6EF5), brightness: Brightness.dark, useMaterial3: true),
      home: startError == null ? const HomeScreen() : _StartupError(error: startError!),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              const Text('无法加载 Tailcat 核心库', style: TextStyle(fontSize: 18)),
              const SizedBox(height: 8),
              SelectableText('$error', textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}
