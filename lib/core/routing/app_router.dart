import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../widgets/identity_gate.dart';
import '../../screens/chat_list_screen.dart';
import '../../screens/conversation_screen.dart';
import '../../screens/settings_screen.dart';

// ---------------------------------------------------------------------------
// Route name constants — use these everywhere instead of raw strings so a
// typo never causes a silent navigation failure.
// ---------------------------------------------------------------------------
class AppRoutes {
  static const identityGate = '/';
  static const chatList     = '/chats';
  static const conversation = '/chats/conversation';
  static const settings     = '/settings';
}

// ---------------------------------------------------------------------------
// The shell scaffold that holds the static bottom navigation bar.
// GoRouter renders this once and swaps only the body, so BLE streams and
// state providers are never torn down when the user switches tabs.
// ---------------------------------------------------------------------------
class _AppShell extends StatelessWidget {
  const _AppShell({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The current tab's screen is rendered here.
      body: navigationShell,

      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          // goBranch keeps the navigation stack of each tab alive
          // independently — tapping Chats never resets Settings.
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Riverpod provider — main.dart watches this to get the GoRouter instance.
// ---------------------------------------------------------------------------
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.identityGate,
    debugLogDiagnostics: true, // prints route changes to terminal — remove in prod

    // -------------------------------------------------------------------
    // Global redirect guard.
    // On every navigation event this function runs first.
    // If the user has no saved identity yet, force them to the gate screen.
    // Once they have an identity, send them straight to the chat list.
    // -------------------------------------------------------------------
    redirect: (context, state) {
      final profileBox  = Hive.box('profile');
      final hasIdentity = profileBox.get('publicKey') != null;
      final onGate      = state.matchedLocation == AppRoutes.identityGate;

      // No identity yet → always show the gate, no matter what URL was requested.
      if (!hasIdentity && !onGate) return AppRoutes.identityGate;

      // Has identity but is sitting on the gate → push to chat list.
      if (hasIdentity && onGate) return AppRoutes.chatList;

      // All other cases → let the navigation proceed normally.
      return null;
    },

    routes: [
      // -----------------------------------------------------------------
      // Identity gate — shown only on first launch before a key is created.
      // -----------------------------------------------------------------
      GoRoute(
        path: AppRoutes.identityGate,
        builder: (context, state) => const IdentityGateScreen(),
      ),

      // -----------------------------------------------------------------
      // Main shell — wraps the bottom nav bar around the two tab branches.
      // -----------------------------------------------------------------
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return _AppShell(navigationShell: navigationShell);
        },
        branches: [
          // Branch 0 — Chats tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.chatList,
                builder: (context, state) => const ChatListScreen(),
                routes: [
                  // Nested under chats so the back button works correctly.
                  GoRoute(
                    path: 'conversation',
                    builder: (context, state) {
                      // The peer's public key is passed as a query parameter.
                      final peerKey = state.uri.queryParameters['peerKey'] ?? '';
                      final peerName = state.uri.queryParameters['peerName'] ?? 'Unknown';
                      return ConversationScreen(
                        peerPublicKey: peerKey,
                        peerName: peerName,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),

          // Branch 1 — Settings tab
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppRoutes.settings,
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});