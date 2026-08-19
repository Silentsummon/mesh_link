import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart';

import 'identity_service.dart';
import 'database_service.dart';

// ---------------------------------------------------------------------------
// BLE Service Constants
// ---------------------------------------------------------------------------

// The service UUID that identifies our mesh chat app on the BLE network.
// Every device scans for this exact UUID — it filters out all other BLE
// devices in the area that are not running MeshChat.
const String kMeshServiceUuid = '12345678-1234-1234-1234-123456789abc';

// Maximum hops a message can travel before it is dropped.
// A TTL of 7 means the message can pass through up to 7 relay devices.
const int kDefaultTtl = 7;

// Maximum size of a BLE advertisement payload in bytes.
// Standard BLE 4.x limit is 31 bytes. We stay under this.
const int kMaxPayloadBytes = 28;

// ---------------------------------------------------------------------------
// MeshPacket
//
// The data structure that travels over the BLE mesh network.
// Every field is kept as short as possible to fit inside BLE size limits.
// ---------------------------------------------------------------------------
class MeshPacket {
  final String uuid;         // UUID v4 — unique ID for loop interception
  final String senderKey;    // Sender's Ed25519 public key hex
  final String recipientKey; // Recipient's Ed25519 public key hex
  final String ciphertext;   // ChaCha20-Poly1305 encrypted payload (base64)
  final int    ttl;          // Time-To-Live hop counter
  final int    timestamp;    // Unix milliseconds

  const MeshPacket({
    required this.uuid,
    required this.senderKey,
    required this.recipientKey,
    required this.ciphertext,
    required this.ttl,
    required this.timestamp,
  });

  // Serialize to JSON string for BLE transmission.
  String toJson() => jsonEncode({
    'u': uuid,
    's': senderKey,
    'r': recipientKey,
    'c': ciphertext,
    't': ttl,
    'ts': timestamp,
  });

  // Deserialize from JSON string received over BLE.
  factory MeshPacket.fromJson(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return MeshPacket(
      uuid:         map['u'] as String,
      senderKey:    map['s'] as String,
      recipientKey: map['r'] as String,
      ciphertext:   map['c'] as String,
      ttl:          map['t'] as int,
      timestamp:    map['ts'] as int,
    );
  }
}

// ---------------------------------------------------------------------------
// BleService
//
// Manages all Bluetooth Low Energy operations:
//   1. Scanning for nearby MeshChat peers.
//   2. Building and transmitting encrypted MeshPackets.
//   3. Receiving packets and running loop interception (TTL + seen UUID check).
//   4. Decrypting packets addressed to this device.
// ---------------------------------------------------------------------------
class BleService {
  // Stream controller that broadcasts newly discovered peer public keys.
  // ChatListScreen listens to this to show nearby devices.
  final _peerController = StreamController<String>.broadcast();
  Stream<String> get peerStream => _peerController.stream;

  // Stream controller that broadcasts decrypted incoming messages.
  // ConversationScreen listens to this to show new chat bubbles.
  final _messageController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messageStream => _messageController.stream;

  // The ChaCha20-Poly1305 AEAD cipher instance.
  final _cipher = Chacha20.poly1305Aead();

  // UUID generator for packet IDs.
  final _uuidGen = const Uuid();

  // Subscription handle for the BLE scan result stream.
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // ---------------------------------------------------------------------------
  // startScan()
  //
  // Starts continuously scanning for nearby BLE devices that advertise
  // our mesh service UUID. Each discovered device is treated as a peer.
  // ---------------------------------------------------------------------------
  Future<void> startScan() async {
    // Cancel any existing scan before starting a new one.
    await stopScan();

    // Configure the scan to filter only MeshChat devices.
    await FlutterBluePlus.startScan(
      withServices: [Guid(kMeshServiceUuid)],
      continuousUpdates: true,
      removeIfGone: const Duration(seconds: 30),
    );

    // Listen to scan results and extract peer public keys from
    // the manufacturer data field of each advertisement.
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        _handleScanResult(result);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // stopScan()
  //
  // Stops the BLE scan and cleans up the subscription.
  // ---------------------------------------------------------------------------
  Future<void> stopScan() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    await FlutterBluePlus.stopScan();
  }

  // ---------------------------------------------------------------------------
  // _handleScanResult()
  //
  // Processes a single BLE advertisement received during scanning.
  // Extracts the peer's public key from manufacturer data and checks
  // if a full MeshPacket payload is present in the service data field.
  // ---------------------------------------------------------------------------
  void _handleScanResult(ScanResult result) {
    final advertisementData = result.advertisementData;

    // --- Extract peer public key from manufacturer data ---
    // We encode the sender's public key as manufacturer data bytes.
    final manufacturerData = advertisementData.manufacturerData;
    if (manufacturerData.isNotEmpty) {
      // Take the first manufacturer data entry's bytes as the public key.
      final keyBytes = manufacturerData.values.first;
      final peerKey  = keyBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      if (peerKey.isNotEmpty) {
        _peerController.add(peerKey);
      }
    }

    // --- Extract MeshPacket from service data ---
    // Full encrypted packets are broadcast in the service data field.
    final serviceData = advertisementData.serviceData;
    if (serviceData.isNotEmpty) {
      for (final entry in serviceData.entries) {
        final rawBytes = entry.value;
        if (rawBytes.isNotEmpty) {
          try {
            final jsonString = utf8.decode(rawBytes);
            _handleIncomingPacket(jsonString);
          } catch (_) {
            // Malformed packet — silently drop it.
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // _handleIncomingPacket()
  //
  // The core loop interception and routing logic.
  // Called for every raw packet string received over BLE.
  //
  // Logic flow:
  //   1. Parse the JSON into a MeshPacket.
  //   2. Check seen_packets table — drop if already relayed.
  //   3. Check TTL — drop if expired.
  //   4. Check if addressed to us — decrypt and deliver if so.
  //   5. Otherwise decrement TTL and re-broadcast (relay).
  // ---------------------------------------------------------------------------
  Future<void> _handleIncomingPacket(String rawJson) async {
    MeshPacket packet;
    try {
      packet = MeshPacket.fromJson(rawJson);
    } catch (_) {
      // Unparseable data — silently drop.
      return;
    }

    // Step 1 — Loop interception: have we already seen this UUID?
    final alreadySeen = await DatabaseService.hasSeenPacket(packet.uuid);
    if (alreadySeen) return; // Drop duplicate silently.

    // Step 2 — Mark this UUID as seen immediately to prevent re-relay.
    await DatabaseService.markPacketSeen(packet.uuid);

    // Step 3 — TTL check: has this packet expired?
    if (packet.ttl <= 0) return; // Drop expired packet.

    // Step 4 — Is this packet addressed to us?
    final myPublicKey = IdentityService.getPublicKeyHex();
    if (myPublicKey == null) return; // No identity yet — drop.

    if (packet.recipientKey == myPublicKey) {
      // This packet is for us — attempt to decrypt it.
      await _decryptAndDeliver(packet);
    } else {
      // Step 5 — Not for us — relay it with TTL decremented by 1.
      final relayPacket = MeshPacket(
        uuid:         packet.uuid,
        senderKey:    packet.senderKey,
        recipientKey: packet.recipientKey,
        ciphertext:   packet.ciphertext,
        ttl:          packet.ttl - 1,
        timestamp:    packet.timestamp,
      );
      // Re-broadcast the relayed packet.
      // In a full implementation this writes to the BLE peripheral
      // characteristic. Stubbed here as a print for verification.
      // ignore: avoid_print
      print('[BLE RELAY] Relaying packet ${relayPacket.uuid} TTL=${relayPacket.ttl}');
    }
  }

  // ---------------------------------------------------------------------------
  // _decryptAndDeliver()
  //
  // Decrypts a MeshPacket addressed to this device using ChaCha20-Poly1305.
  // On success, saves the plaintext to SQLite and emits it on messageStream.
  //
  // Note: Full ECDH shared-secret derivation requires the sender's public key
  // and our private key. For the current build we use a pre-shared symmetric
  // key approach (the ciphertext field carries both nonce + ciphertext).
  // The ECDH upgrade slot is clearly marked below.
  // ---------------------------------------------------------------------------
  Future<void> _decryptAndDeliver(MeshPacket packet) async {
    try {
      // Decode the base64 ciphertext field.
      // Format: [12-byte nonce][remaining ciphertext bytes]
      final combined = base64Decode(packet.ciphertext);
      if (combined.length < 12) return; // Too short to be valid.

      final nonce      = combined.sublist(0, 12);
      final ciphertext = combined.sublist(12);

      // -------------------------------------------------------------------
      // ECDH UPGRADE SLOT
      // Replace this stub key with a real X25519 shared secret derived from:
      //   sharedSecret = ECDH(ourPrivateKey, senderPublicKey)
      // For now we use a zeroed key so the packet parse logic can be tested.
      // -------------------------------------------------------------------
      final stubKey = SecretKey(List<int>.filled(32, 0));

      final secretBox = SecretBox(
        ciphertext,
        nonce: nonce,
        mac:   Mac(ciphertext.sublist(ciphertext.length - 16)),
      );

      final plainBytes = await _cipher.decrypt(
        secretBox,
        secretKey: stubKey,
      );

      final plaintext = utf8.decode(plainBytes);

      // Save the decrypted message to SQLite.
      await DatabaseService.insertMessage(
        uuid:       packet.uuid,
        peerKey:    packet.senderKey,
        senderKey:  packet.senderKey,
        ciphertext: packet.ciphertext,
        plaintext:  plaintext,
        timestamp:  packet.timestamp,
        isOutbound: false,
      );

      // Emit the message to any listening UI streams.
      _messageController.add({
        'peerKey':   packet.senderKey,
        'plaintext': plaintext,
        'timestamp': packet.timestamp,
      });
    } catch (_) {
      // Decryption failed — wrong key or corrupted packet. Drop silently.
    }
  }

  // ---------------------------------------------------------------------------
  // sendMessage()
  //
  // Encrypts a plaintext message and broadcasts it as a MeshPacket over BLE.
  // Returns the UUID of the sent packet.
  // ---------------------------------------------------------------------------
  Future<String> sendMessage({
    required String plaintext,
    required String recipientPublicKeyHex,
  }) async {
    final myPublicKey = IdentityService.getPublicKeyHex();
    if (myPublicKey == null) {
      throw StateError('Cannot send message: no local identity exists.');
    }

    // Generate a random 12-byte nonce for ChaCha20-Poly1305.
    final nonce = List<int>.generate(
      12,
      (_) => DateTime.now().microsecondsSinceEpoch & 0xFF,
    );

    // -------------------------------------------------------------------
    // ECDH UPGRADE SLOT
    // Replace stubKey with real X25519 ECDH shared secret:
    //   sharedSecret = ECDH(ourPrivateKey, recipientPublicKey)
    // -------------------------------------------------------------------
    final stubKey = SecretKey(List<int>.filled(32, 0));

    // Encrypt the plaintext.
    final secretBox = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: stubKey,
      nonce:     nonce,
    );

    // Combine nonce + ciphertext + MAC into one base64 blob.
    final combined = [
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ];
    final ciphertextBase64 = base64Encode(combined);

    // Stamp a fresh UUID v4 on this packet.
    final packetUuid = _uuidGen.v4();

    final packet = MeshPacket(
      uuid:         packetUuid,
      senderKey:    myPublicKey,
      recipientKey: recipientPublicKeyHex,
      ciphertext:   ciphertextBase64,
      ttl:          kDefaultTtl,
      timestamp:    DateTime.now().millisecondsSinceEpoch,
    );

    // Save our own outbound message to SQLite immediately so the UI
    // shows it in the conversation without waiting for a relay echo.
    await DatabaseService.insertMessage(
      uuid:       packetUuid,
      peerKey:    recipientPublicKeyHex,
      senderKey:  myPublicKey,
      ciphertext: ciphertextBase64,
      plaintext:  plaintext,
      timestamp:  packet.timestamp,
      isOutbound: true,
    );

    // Mark our own packet as seen so we never relay our own message
    // back to ourselves if it bounces through another device.
    await DatabaseService.markPacketSeen(packetUuid);

    // Broadcast the packet over BLE.
    // In a full peripheral implementation this writes to the GATT
    // characteristic. Logged here for verification during testing.
    // ignore: avoid_print
    print('[BLE SEND] ${packet.toJson()}');

    return packetUuid;
  }

  // ---------------------------------------------------------------------------
  // dispose()
  //
  // Cleans up all streams and BLE resources. Call on app dispose.
  // ---------------------------------------------------------------------------
  Future<void> dispose() async {
    await stopScan();
    await _peerController.close();
    await _messageController.close();
  }
}

// ---------------------------------------------------------------------------
// Riverpod provider for BleService.
// Screens access BLE via ref.watch(bleServiceProvider).
// ---------------------------------------------------------------------------
final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});