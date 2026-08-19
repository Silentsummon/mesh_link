import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/identity_service.dart';
import '../services/database_service.dart';
import '../core/routing/app_router.dart';

// ---------------------------------------------------------------------------
// IdentityGateScreen
//
// The first screen a user sees on a brand new install.
// Blocked by the GoRouter redirect guard until an identity is created.
//
// Responsibilities:
//   1. Show a display name input field.
//   2. Generate an Ed25519 keypair when the user taps Create Identity.
//   3. Save the display name to Hive.
//   4. Initialize the SQLite database.
//   5. Navigate to the chat list once everything is ready.
// ---------------------------------------------------------------------------
class IdentityGateScreen extends ConsumerStatefulWidget {
  const IdentityGateScreen({super.key});

  @override
  ConsumerState<IdentityGateScreen> createState() => _IdentityGateScreenState();
}

class _IdentityGateScreenState extends ConsumerState<IdentityGateScreen> {
  // Controls the display name text field.
  final _nameController = TextEditingController();

  // Form key for validation.
  final _formKey = GlobalKey<FormState>();

  // Tracks whether the async identity generation is in progress.
  // While true, the button shows a spinner and all inputs are disabled.
  bool _isLoading = false;

  // Holds any error message to display below the button.
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // _createIdentity()
  //
  // Called when the user taps the Create Identity button.
  // Runs the full identity setup sequence in order.
  // ---------------------------------------------------------------------------
  Future<void> _createIdentity() async {
    // Validate the form first — name must not be empty.
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Step 1 — Initialize the SQLite database.
      // We do this here rather than main() so the database is only
      // created after the user confirms they want to set up an identity.
      await DatabaseService.init();

      // Step 2 — Generate the Ed25519 keypair and seal it in the
      // hardware enclave. Returns the public key hex string.
      final publicKeyHex = await IdentityService.generateAndSaveIdentity();

      // Step 3 — Save the display name to Hive profile box.
      final profileBox = Hive.box('profile');
      await profileBox.put('displayName', _nameController.text.trim());

      // Step 4 — Log the public key for verification during development.
      // Remove this line before shipping to production.
      // ignore: avoid_print
      print('[IDENTITY] Public key (mesh address): $publicKeyHex');

      // Step 5 — Navigate to the chat list.
      // The GoRouter redirect guard will now see the publicKey in Hive
      // and allow navigation past the gate permanently.
      if (mounted) {
        context.go(AppRoutes.chatList);
      }
    } catch (e) {
      // Something went wrong — show the error and let the user retry.
      setState(() {
        _errorMessage = 'Failed to create identity: ${e.toString()}';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // build()
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // --- App icon / logo area ---
                  Icon(
                    Icons.hub_rounded,
                    size: 80,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 24),

                  // --- Title ---
                  Text(
                    'MeshChat',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // --- Subtitle ---
                  Text(
                    'Anonymous. Offline. Encrypted.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // --- Display name field ---
                  TextFormField(
                    controller: _nameController,
                    enabled: !_isLoading,
                    maxLength: 32,
                    decoration: InputDecoration(
                      labelText: 'Choose a display name',
                      hintText: 'e.g. Ghost, Nomad, Alice',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _createIdentity(),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a display name.';
                      }
                      if (value.trim().length < 2) {
                        return 'Name must be at least 2 characters.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 24),

                  // --- Create Identity button ---
                  FilledButton.icon(
                    onPressed: _isLoading ? null : _createIdentity,
                    icon: _isLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.key_rounded),
                    label: Text(
                      _isLoading ? 'Generating identity…' : 'Create Identity',
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // --- Error message ---
                  if (_errorMessage != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colorScheme.onErrorContainer),
                      ),
                    ),
                  const SizedBox(height: 32),

                  // --- Privacy notice ---
                  Text(
                    'Your identity is generated entirely on this device.\n'
                    'No servers. No accounts. No phone numbers.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
