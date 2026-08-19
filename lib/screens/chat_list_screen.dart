import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/database_service.dart';
import '../services/ble_service.dart';
import '../core/routing/app_router.dart';

// ---------------------------------------------------------------------------
// Riverpod provider that loads all conversations from SQLite.
// Returns a list of maps, one per unique peer, with their latest message.
// ---------------------------------------------------------------------------
final conversationsProvider =
    FutureProvider<List<Map<String, dynamic>>>((ref) async {
  return DatabaseService.getAllConversations();
});

// ---------------------------------------------------------------------------
// Riverpod provider that tracks all nearby peers discovered via BLE scan.
// Accumulates peer public keys into a Set to avoid duplicates.
// ---------------------------------------------------------------------------
final nearbyPeersProvider = StreamProvider<Set<String>>((ref) async* {
  final bleService = ref.watch(bleServiceProvider);
  final peers = <String>{};

  await bleService.startScan();

  await for (final peerKey in bleService.peerStream) {
    peers.add(peerKey);
    yield Set.from(peers);
  }
});

// ---------------------------------------------------------------------------
// ChatListScreen
//
// The main hub screen — shows two sections:
//   1. Nearby Peers  — live BLE scan results (devices in range right now).
//   2. Conversations — all past chats loaded from SQLite.
// ---------------------------------------------------------------------------
class ChatListScreen extends ConsumerStatefulWidget {
  const ChatListScreen({super.key});

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // Register as a lifecycle observer so we can prune old seen_packets
    // when the app comes back to the foreground.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Prune seen_packets older than 24 hours every time the app resumes.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      DatabaseService.pruneSeenPackets();
    }
  }

  // ---------------------------------------------------------------------------
  // _openConversation()
  //
  // Navigates to ConversationScreen passing peerKey and peerName as
  // query parameters so GoRouter can reconstruct the route correctly.
  // ---------------------------------------------------------------------------
  void _openConversation(String peerKey, String peerName) {
    context.go(
      '${AppRoutes.conversation}'
      '?peerKey=${Uri.encodeComponent(peerKey)}'
      '&peerName=${Uri.encodeComponent(peerName)}',
    );
  }

  // ---------------------------------------------------------------------------
  // _formatTimestamp()
  //
  // Converts a Unix millisecond timestamp to a human-readable time string.
  // Shows time only for today, date only for older messages.
  // ---------------------------------------------------------------------------
  String _formatTimestamp(int milliseconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);

    if (msgDay == today) {
      final h = dt.hour.toString().padLeft(2, '0');
      final m = dt.minute.toString().padLeft(2, '0');
      return '$h:$m';
    } else {
      return '${dt.day}/${dt.month}/${dt.year}';
    }
  }

  // ---------------------------------------------------------------------------
  // build()
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final conversationsAsync = ref.watch(conversationsProvider);
    final nearbyPeersAsync = ref.watch(nearbyPeersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshChat'),
        centerTitle: false,
        actions: [
          // Refresh button to reload conversations from SQLite manually.
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(conversationsProvider),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // -----------------------------------------------------------------
          // Section 1 — Nearby Peers (live BLE scan)
          // -----------------------------------------------------------------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.bluetooth_searching_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Nearby Peers',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          nearbyPeersAsync.when(
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text('Scanning for nearby devices…'),
                  ],
                ),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'BLE scan error: $err',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ),
            data: (peers) {
              if (peers.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'No devices found yet. Make sure Bluetooth is on.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                );
              }

              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final peerKey = peers.elementAt(index);
                    // Show a shortened version of the key as the peer name.
                    final shortKey = '${peerKey.substring(0, 8)}…';

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.primaryContainer,
                        child: Icon(
                          Icons.person_rounded,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                      title: Text(
                        shortKey,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: const Text('Tap to open conversation'),
                      trailing: Icon(
                        Icons.circle,
                        size: 10,
                        color: Colors.greenAccent.shade400,
                      ),
                      onTap: () => _openConversation(peerKey, shortKey),
                    );
                  },
                  childCount: peers.length,
                ),
              );
            },
          ),

          // Divider between sections.
          const SliverToBoxAdapter(
            child: Divider(height: 32, indent: 16, endIndent: 16),
          ),

          // -----------------------------------------------------------------
          // Section 2 — Past Conversations (from SQLite)
          // -----------------------------------------------------------------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Conversations',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),

          conversationsAsync.when(
            loading: () => const SliverToBoxAdapter(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Error loading conversations: $err',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
            ),
            data: (conversations) {
              if (conversations.isEmpty) {
                return SliverToBoxAdapter(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(48),
                      child: Column(
                        children: [
                          Icon(
                            Icons.forum_outlined,
                            size: 64,
                            color: colorScheme.onSurface.withValues(alpha: 0.2),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No conversations yet.\n'
                            'Tap a nearby peer to start chatting.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color:
                                  colorScheme.onSurface.withValues(alpha: 0.4),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final convo = conversations[index];
                    final peerKey = convo['peer_key'] as String;
                    final shortKey = '${peerKey.substring(0, 8)}…';
                    final preview = (convo['plaintext'] as String?) ??
                        '[encrypted message]';
                    final timestamp = convo['timestamp'] as int;

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.secondaryContainer,
                        child: Text(
                          shortKey.substring(0, 2).toUpperCase(),
                          style: TextStyle(
                            color: colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      title: Text(
                        shortKey,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      subtitle: Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        _formatTimestamp(timestamp),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      onTap: () => _openConversation(peerKey, shortKey),
                    );
                  },
                  childCount: conversations.length,
                ),
              );
            },
          ),

          // Bottom padding so last item is not hidden behind nav bar.
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}
