import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';
import '../services/ble_service.dart';
import '../services/identity_service.dart';

// ---------------------------------------------------------------------------
// Riverpod provider that loads all messages for a specific peer from SQLite.
// The peer's public key is passed as a parameter using the .family modifier.
// ---------------------------------------------------------------------------
final messagesProvider =
    FutureProvider.family<List<Map<String, dynamic>>, String>(
        (ref, peerKey) async {
  return DatabaseService.getMessagesForPeer(peerKey);
});

// ---------------------------------------------------------------------------
// ConversationScreen
//
// The one-on-one chat view between this device and a single peer.
//
// Responsibilities:
//   1. Load existing messages from SQLite on mount.
//   2. Listen to the BLE incoming message stream for live updates.
//   3. Send encrypted messages via BleService.
//   4. Scroll to the bottom automatically when new messages arrive.
// ---------------------------------------------------------------------------
class ConversationScreen extends ConsumerStatefulWidget {
  final String peerPublicKey;
  final String peerName;

  const ConversationScreen({
    super.key,
    required this.peerPublicKey,
    required this.peerName,
  });

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  // Controls the message input field.
  final _inputController = TextEditingController();

  // Controls auto-scrolling to the bottom of the message list.
  final _scrollController = ScrollController();

  // Subscription to the BLE incoming message stream.
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;

  // Local copy of messages rendered in the list.
  // Starts empty and is populated by the FutureProvider + live stream.
  List<Map<String, dynamic>> _messages = [];

  // Tracks whether a send operation is in progress.
  bool _isSending = false;

  // The local user's public key hex — used to determine bubble alignment.
  String? _myPublicKey;

  @override
  void initState() {
    super.initState();
    _myPublicKey = IdentityService.getPublicKeyHex();
    _subscribeToIncomingMessages();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _messageSubscription?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _subscribeToIncomingMessages()
  //
  // Listens to the BLE service's message stream. When a new message arrives
  // from this specific peer, appends it to the local list and scrolls down.
  // ---------------------------------------------------------------------------
  void _subscribeToIncomingMessages() {
    final bleService = ref.read(bleServiceProvider);

    _messageSubscription = bleService.messageStream.listen((messageMap) {
      final senderKey = messageMap['peerKey'] as String?;

      // Only process messages from the peer this screen is open for.
      if (senderKey != widget.peerPublicKey) return;

      setState(() {
        _messages.add({
          'sender_key': senderKey,
          'plaintext': messageMap['plaintext'],
          'timestamp': messageMap['timestamp'],
          'is_outbound': 0,
        });
      });

      _scrollToBottom();
    });
  }

  // ---------------------------------------------------------------------------
  // _scrollToBottom()
  //
  // Animates the scroll position to the very end of the message list.
  // Called after sending or receiving a message.
  // ---------------------------------------------------------------------------
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // _sendMessage()
  //
  // Reads the text input, calls BleService.sendMessage(), and clears the field.
  // ---------------------------------------------------------------------------
  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);

    try {
      await ref.read(bleServiceProvider).sendMessage(
            plaintext: text,
            recipientPublicKeyHex: widget.peerPublicKey,
          );

      // Add the outbound message to the local list immediately so the
      // UI updates without waiting for a database reload.
      setState(() {
        _messages.add({
          'sender_key': _myPublicKey,
          'plaintext': text,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'is_outbound': 1,
        });
      });

      _inputController.clear();
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to send: ${e.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  // ---------------------------------------------------------------------------
  // _formatTimestamp()
  //
  // Converts a Unix millisecond timestamp to HH:MM format for bubble display.
  // ---------------------------------------------------------------------------
  String _formatTimestamp(int milliseconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ---------------------------------------------------------------------------
  // build()
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Load messages from SQLite via FutureProvider.
    final messagesAsync = ref.watch(messagesProvider(widget.peerPublicKey));

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.peerName),
            Text(
              widget.peerPublicKey.length > 16
                  ? '${widget.peerPublicKey.substring(0, 16)}…'
                  : widget.peerPublicKey,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurface.withValues(alpha: 0.5),
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
        // Lock icon shows the conversation is encrypted.
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(
              Icons.lock_rounded,
              size: 18,
              color: Colors.greenAccent.shade400,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // -----------------------------------------------------------------
          // Message list — fills all available space above the input bar.
          // -----------------------------------------------------------------
          Expanded(
            child: messagesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Text(
                  'Error loading messages: $err',
                  style: TextStyle(color: colorScheme.error),
                ),
              ),
              data: (dbMessages) {
                // On first load, populate _messages from the database result.
                // We only do this if _messages is still empty to avoid
                // overwriting messages that arrived via the live stream.
                if (_messages.isEmpty && dbMessages.isNotEmpty) {
                  // Schedule the update after the current build frame.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() => _messages = List.from(dbMessages));
                      _scrollToBottom();
                    }
                  });
                }

                if (_messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 64,
                          color: colorScheme.onSurface.withValues(alpha: 0.2),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Messages are end-to-end encrypted.\n'
                          'Say hello!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final msg = _messages[index];
                    final isOutbound = (msg['is_outbound'] as int) == 1;
                    final plaintext =
                        (msg['plaintext'] as String?) ?? '[encrypted]';
                    final timestamp = msg['timestamp'] as int;

                    return _MessageBubble(
                      text: plaintext,
                      isOutbound: isOutbound,
                      timestamp: _formatTimestamp(timestamp),
                      colorScheme: colorScheme,
                    );
                  },
                );
              },
            ),
          ),

          // -----------------------------------------------------------------
          // Input bar — pinned to the bottom of the screen.
          // -----------------------------------------------------------------
          Container(
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(
                top: BorderSide(
                  color: colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              top: 8,
              bottom: MediaQuery.of(context).viewInsets.bottom + 8,
            ),
            child: Row(
              children: [
                // Text input field.
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    enabled: !_isSending,
                    maxLines: null,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Message…',
                      filled: true,
                      fillColor: colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Send button.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: _isSending
                      ? const SizedBox(
                          width: 40,
                          height: 40,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton.filled(
                          onPressed: _sendMessage,
                          icon: const Icon(Icons.send_rounded),
                          style: IconButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _MessageBubble
//
// A single chat bubble widget. Outbound messages align right with primary
// color. Inbound messages align left with surface container color.
// ---------------------------------------------------------------------------
class _MessageBubble extends StatelessWidget {
  final String text;
  final bool isOutbound;
  final String timestamp;
  final ColorScheme colorScheme;

  const _MessageBubble({
    required this.text,
    required this.isOutbound,
    required this.timestamp,
    required this.colorScheme,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleColor =
        isOutbound ? colorScheme.primary : colorScheme.surfaceContainerHighest;

    final textColor =
        isOutbound ? colorScheme.onPrimary : colorScheme.onSurface;

    final timeColor = isOutbound
        ? colorScheme.onPrimary.withValues(alpha: 0.6)
        : colorScheme.onSurface.withValues(alpha: 0.5);

    return Align(
      alignment: isOutbound ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(
                context,
              ).size.width *
              0.75,
        ),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isOutbound ? 18 : 4),
            bottomRight: Radius.circular(isOutbound ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              isOutbound ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: TextStyle(
                color: textColor,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              timestamp,
              style: TextStyle(
                color: timeColor,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
