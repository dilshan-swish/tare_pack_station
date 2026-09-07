import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/settings_store.dart';
import 'screens/orders_queue_screen.dart';
import 'state/settings_controller.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load persisted settings before the first frame. A failure inside the store
  // falls back to in-memory defaults rather than crashing on startup.
  final store = SettingsStore();
  final initial = await store.load();

  runApp(
    ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(store),
        initialSettingsProvider.overrideWithValue(initial),
      ],
      child: const TareApp(),
    ),
  );
}

class TareApp extends StatelessWidget {
  const TareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TARE. — Pack Station',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const OrdersQueueScreen(),
    );
  }
}
