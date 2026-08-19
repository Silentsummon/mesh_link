import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/identity_service.dart';
import '../services/database_service.dart';
import '../core/routing/app_router.dart';

// ---------------------------------------------------------------------------
// SettingsScreen
//
// Displays the local identity info and provides the atomic panic button wipe.
//
// Responsibilities:
//   1. Show the user's display name and public key (mesh address).
//   2. Allow the user to toggle dark/light theme preference.
//   3. Provide the panic button that wipes all local data atomically.
// ---------------------------------------------------------------------------
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Tracks whether the wipe operation is running.
  bool _isWiping = false;

  // ---------------------------------------------------------------------------
  // _confirmAndWipe()
  //
  // Shows a confirmation dialog before executing the panic wipe.
  // The wipe itself is wrapped in try/catch so a partial failure
  // still navigates the user back to the gate screen.
  // ---------------------------------------------------------------------------
  Future<void> _confirmAndWipe() async {
    // Show a strongly worded confirmation dialog first.
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          size:  48,
          color: Colors.redAccent,
        ),
        title: const Text(
          'Wipe All Data?',
          textAlign: TextAlign.center,
        ),
        content: const Text(
          'This will permanently delete:\n\n'
          '• Your identity keypair\n'
          '• All messages\n'
          '• All peer records\n\n'
          'This action cannot be undone.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.redAccent,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Wipe Everything'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isWiping = true);

    try {
      // Step 1 — Wipe SQLite: delete all messages and seen_packets rows
      // inside a single ACID transaction.
      await DatabaseService.nukeAllData();

      // Step 2 — Wipe the Ed25519 keypair from the hardware enclave
      // and clear the Hive profile box.
      await IdentityService.wipeIdentity();

      // Step 3 — Navigate back to the identity gate.
      // The GoRouter redirect guard will see no publicKey in Hive
      // and lock the app to the gate screen automatically.
      if (mounted) {
        context.go(AppRoutes.identityGate);
      }
    } catch (e) {
      // Even if something throws, attempt to navigate to the gate
      // so the user is not stuck on a broken settings screen.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Wipe error: ${e.toString()}'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        context.go(AppRoutes.identityGate);
      }
    } finally {
      if (mounted) setState(() => _isWiping = false);
    }
  }

  // ---------------------------------------------------------------------------
  // build()
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme       = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Read identity info directly from Hive — synchronous, no FutureBuilder.
    final profileBox   = Hive.box('profile');
    final displayName  = profileBox.get('displayName', defaultValue: 'Unknown') as String;
    final publicKeyHex = profileBox.get('publicKey',   defaultValue: '')        as String;

    return Scaffold(
      appBar: AppBar(
        title:       const Text('Settings'),
        centerTitle: false,
      ),

      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [

          // -----------------------------------------------------------------
          // Section — Identity
          // -----------------------------------------------------------------
          _SectionHeader(label: 'Identity', colorScheme: colorScheme),

          // Display name tile.
          ListTile(
            leading: CircleAvatar(
              backgroundColor: colorScheme.primaryContainer,
              child: Text(
                displayName.isNotEmpty
                    ? displayName[0].toUpperCase()
                    : '?',
                style: TextStyle(
                  color:      colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title:    const Text('Display Name'),
            subtitle: Text(displayName),
          ),

          const Divider(indent: 72, endIndent: 16),

          // Public key (mesh address) tile.
          ListTile(
            leading: Icon(
              Icons.key_rounded,
              color: colorScheme.primary,
            ),
            title:    const Text('Mesh Address (Public Key)'),
            subtitle: Text(
              publicKeyHex.isNotEmpty ? publicKeyHex : 'Not generated yet',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize:   11,
              ),
            ),
            // Tap to copy the public key to clipboard.
            trailing: IconButton(
              icon:    const Icon(Icons.copy_rounded),
              tooltip: 'Copy public key',
              onPressed: publicKeyHex.isEmpty
                  ? null
                  : () async {
                      await _copyToClipboard(context, publicKeyHex);
                    },
            ),
          ),

          const SizedBox(height: 8),

          // -----------------------------------------------------------------
          // Section — About
          // -----------------------------------------------------------------
          _SectionHeader(label: 'About', colorScheme: colorScheme),

          ListTile(
            leading: Icon(
              Icons.hub_rounded,
              color: colorScheme.primary,
            ),
            title:    const Text('MeshChat'),
            subtitle: const Text('Anonymous offline encrypted mesh chat'),
          ),

          const Divider(indent: 72, endIndent: 16),

          ListTile(
            leading: Icon(
              Icons.shield_outlined,
              color: colorScheme.primary,
            ),
            title:    const Text('Encryption'),
            subtitle: const Text(
              'Ed25519 identity · ChaCha20-Poly1305 messages',
            ),
          ),

          const Divider(indent: 72, endIndent: 16),

          ListTile(
            leading: Icon(
              Icons.bluetooth_rounded,
              color: colorScheme.primary,
            ),
            title:    const Text('Transport'),
            subtitle: const Text(
              'Bluetooth Low Energy mesh · TTL flood routing',
            ),
          ),

          const SizedBox(height: 8),

          // -----------------------------------------------------------------
          // Section — Danger Zone
          // -----------------------------------------------------------------
          _SectionHeader(
            label:       'Danger Zone',
            colorScheme: colorScheme,
            color:       Colors.redAccent,
          ),

          // Panic button wipe tile.
          ListTile(
            leading: const Icon(
              Icons.delete_forever_rounded,
              color: Colors.redAccent,
            ),
            title: const Text(
              'Wipe All Local Data',
              style: TextStyle(
                color:      Colors.redAccent,
                fontWeight: FontWeight.bold,
              ),
            ),
            subtitle: const Text(
              'Permanently deletes your identity, all messages, '
              'and all peer records. Cannot be undone.',
            ),
            trailing: _isWiping
                ? const SizedBox(
                    width:  24,
                    height: 24,
                    child:  CircularProgressIndicator(
                      strokeWidth: 2,
                      color:       Colors.redAccent,
                    ),
                  )
                : null,
            onTap: _isWiping ? null : _confirmAndWipe,
          ),

          const SizedBox(height: 48),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // _copyToClipboard()
  //
  // Copies a string to the system clipboard and shows a snackbar confirmation.
  // ---------------------------------------------------------------------------
  Future<void> _copyToClipboard(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:  Text('Public key copied to clipboard.'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// _SectionHeader
//
// A small labelled section divider used throughout the settings list.
// ---------------------------------------------------------------------------
class _SectionHeader extends StatelessWidget {
  final String      label;
  final ColorScheme colorScheme;
  final Color?      color;

  const _SectionHeader({
    required this.label,
    required this.colorScheme,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize:   11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: color ?? colorScheme.primary,
        ),
      ),
    );
  }
}