import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
//import 'package:cryptography_flutter/cryptography_flutter.dart';
import 'core/routing/app_router.dart';
import 'services/database_service.dart';
Future<void> main() async {
  // Ensures Flutter engine is fully booted before we touch any
  // native platform channels (Hive, secure storage, BLE).
  WidgetsFlutterBinding.ensureInitialized();

  // Boot Hive and open the profile box that stores the display
  // name and UI preferences (dark/light mode).
await Hive.initFlutter();
  await Hive.openBox('profile');
  await DatabaseService.init();

  // Tell cryptography_flutter to use the native hardware engine
  // on the device chip instead of the slower Dart software engine.
  //FlutterCryptography.enable();

  runApp(
    // ProviderScope is the root container for all Riverpod providers.
    // Every screen and service in the app reads state from here.
    const ProviderScope(
      child: MeshChatApp(),
    ),
  );
}

class MeshChatApp extends ConsumerWidget {
  const MeshChatApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the router so GoRouter can rebuild when auth state changes
    // (e.g. first launch identity gate vs main chat screen).
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'MeshChat',
      debugShowCheckedModeBanner: false,

      // Dark theme as the default — suits a privacy-focused app.
      themeMode: ThemeMode.dark,

      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.tealAccent,
        useMaterial3: true,
      ),

      theme: ThemeData(
        brightness: Brightness.light,
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),

      // Hand all navigation control to GoRouter.
      routerConfig: router,
    );
  }
}
