import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';

// ---------------------------------------------------------------------------
// IdentityService
//
// Responsible for exactly three things:
//   1. Generating a fresh Ed25519 keypair on first launch.
//   2. Persisting the private key safely in the OS hardware enclave.
//   3. Persisting the public key (the user's mesh address) in Hive so the
//      router redirect guard can read it instantly without async calls.
// ---------------------------------------------------------------------------
class IdentityService {
  // The secure storage instance talks directly to:
  //   Android → EncryptedSharedPreferences backed by Android Keystore
  //   iOS     → Keychain Services
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Storage keys — never change these after first launch or the user
  // loses their identity permanently.
  static const _privateKeyStorageKey = 'ed25519_private_key';
  static const _publicKeyStorageKey  = 'ed25519_public_key';

  // The Ed25519 algorithm instance from the cryptography package.
  static final _algorithm = Ed25519();

  // ---------------------------------------------------------------------------
  // generateAndSaveIdentity()
  //
  // Called once on first launch from the IdentityGateScreen.
  // Generates a fresh keypair, seals the private key in the hardware enclave,
  // and writes the public key to Hive so the router guard can see it.
  // Returns the public key as a hex string (the user's mesh address).
  // ---------------------------------------------------------------------------
  static Future<String> generateAndSaveIdentity() async {
    // Step 1 — Generate a brand new Ed25519 keypair completely offline.
    final keyPair = await _algorithm.newKeyPair();

    // Step 2 — Extract the raw private key bytes and encode to base64
    // so it can be stored as a string in secure storage.
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    final privateKeyBase64 = base64Encode(privateKeyBytes);

    // Step 3 — Extract the public key bytes and encode to hex.
    // This hex string IS the user's anonymous mesh address.
    final publicKey      = await keyPair.extractPublicKey();
    final publicKeyHex   = _bytesToHex(publicKey.bytes);

    // Step 4 — Seal the private key inside the hardware enclave.
    await _storage.write(
      key:   _privateKeyStorageKey,
      value: privateKeyBase64,
    );

    // Step 5 — Write the public key to secure storage as well for
    // reconstruction later.
    await _storage.write(
      key:   _publicKeyStorageKey,
      value: publicKeyHex,
    );

    // Step 6 — Also write the public key to Hive so the GoRouter
    // redirect guard can read it synchronously without awaiting.
    final profileBox = Hive.box('profile');
    await profileBox.put('publicKey', publicKeyHex);

    return publicKeyHex;
  }

  // ---------------------------------------------------------------------------
  // loadExistingIdentity()
  //
  // Called on subsequent launches to reconstruct the full keypair from
  // the hardware enclave. Returns null if no identity exists yet.
  // ---------------------------------------------------------------------------
  static Future<SimpleKeyPair?> loadExistingIdentity() async {
    final privateKeyBase64 = await _storage.read(key: _privateKeyStorageKey);
    final publicKeyHex     = await _storage.read(key: _publicKeyStorageKey);

    // No keys found — this is a first launch.
    if (privateKeyBase64 == null || publicKeyHex == null) return null;

    // Decode the stored strings back to raw bytes.
    final privateKeyBytes = base64Decode(privateKeyBase64);

    // Reconstruct the full Ed25519 keypair from raw bytes.
    final keyPair = await _algorithm.newKeyPairFromSeed(privateKeyBytes);
    // Verify the reconstructed public key matches what we stored.
    // This catches hardware enclave corruption early.
    final reconstructedPublicKey = await keyPair.extractPublicKey();
    if (_bytesToHex(reconstructedPublicKey.bytes) != publicKeyHex) {
      throw StateError(
        'Identity integrity check failed: '
        'reconstructed public key does not match stored public key. '
        'The hardware enclave may be corrupted.',
      );
    }

    return keyPair;
  }

  // ---------------------------------------------------------------------------
  // getPublicKeyHex()
  //
  // Quick helper — returns just the public key hex string from Hive.
  // Used by BLE service and message builders that need the local address.
  // ---------------------------------------------------------------------------
  static String? getPublicKeyHex() {
    final profileBox = Hive.box('profile');
    return profileBox.get('publicKey') as String?;
  }

  // ---------------------------------------------------------------------------
  // wipeIdentity()
  //
  // Called by the panic button on the settings screen.
  // Deletes the keypair from the hardware enclave and clears Hive profile.
  // After this the router redirect guard will send the user back to the gate.
  // ---------------------------------------------------------------------------
  static Future<void> wipeIdentity() async {
    await _storage.delete(key: _privateKeyStorageKey);
    await _storage.delete(key: _publicKeyStorageKey);

    final profileBox = Hive.box('profile');
    await profileBox.clear();
  }

  // ---------------------------------------------------------------------------
  // Private helpers — byte conversion utilities.
  // ---------------------------------------------------------------------------

  // Converts a list of bytes to a lowercase hex string.
  // e.g. [0x4a, 0x2f] → '4a2f'
  static String _bytesToHex(List<int> bytes) {
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  // Converts a hex string back to a list of bytes.
  // e.g. '4a2f' → [0x4a, 0x2f]
  /*static List<int> _hexToBytes(String hex) {
    final result = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      result.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return result;
  }*/
}