import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as path_helper;

// ---------------------------------------------------------------------------
// DatabaseService
//
// Manages the SQLite relational database for:
//   1. Messages       — every chat message sent and received.
//   2. Seen Packets   — UUID tracking table for loop interception (TTL guard).
//
// All heavy mesh data lives here. Light profile configs live in Hive.
// ---------------------------------------------------------------------------
class DatabaseService {
  // Singleton pattern — only one database connection is ever open at a time.
  static Database? _db;

  // Current schema version. Increment this if you ever change the table
  // structure and add migration logic inside _onUpgrade.
  static const int _schemaVersion = 1;

  // ---------------------------------------------------------------------------
  // init()
  //
  // Opens (or creates) the SQLite database file on the device's local storage.
  // Must be called once before any other method is used.
  // Safe to call multiple times — returns the existing connection if open.
  // ---------------------------------------------------------------------------
  static Future<void> init() async {
    if (_db != null) return;

    // Locate the platform-correct directory for database files.
    final dbPath = await getDatabasesPath();

    // Build the full file path: e.g. /data/data/com.example.mesh_chat/databases/mesh_chat.db
    final fullPath = path_helper.join(dbPath, 'mesh_chat.db');

    _db = await openDatabase(
      fullPath,
      version: _schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  // ---------------------------------------------------------------------------
  // _onCreate — runs once when the database file is first created.
  // ---------------------------------------------------------------------------
  static Future<void> _onCreate(Database db, int version) async {
    // Use a batch so both tables are created in a single ACID transaction.
    // If either statement fails, neither table is created — no partial state.
    final batch = db.batch();

    // --- Messages table ---
    // Stores every message the user sends or receives.
    batch.execute('''
      CREATE TABLE messages (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        uuid          TEXT    NOT NULL UNIQUE,
        peer_key      TEXT    NOT NULL,
        sender_key    TEXT    NOT NULL,
        ciphertext    TEXT    NOT NULL,
        plaintext     TEXT,
        timestamp     INTEGER NOT NULL,
        is_outbound   INTEGER NOT NULL DEFAULT 0,
        ttl           INTEGER NOT NULL DEFAULT 7,
        delivered     INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // --- Seen packets table ---
    // Tracks every UUID we have already relayed to prevent broadcast loops.
    // When a packet arrives we check this table first.
    // If found → drop the packet silently.
    // If not found → relay it and insert the UUID here.
    batch.execute('''
      CREATE TABLE seen_packets (
        uuid       TEXT    NOT NULL PRIMARY KEY,
        seen_at    INTEGER NOT NULL
      )
    ''');

    // Create an index on peer_key so loading a conversation is fast
    // even with thousands of messages in the table.
    batch.execute('''
      CREATE INDEX idx_messages_peer_key
      ON messages (peer_key)
    ''');

    // Create an index on timestamp for chronological sorting.
    batch.execute('''
      CREATE INDEX idx_messages_timestamp
      ON messages (timestamp)
    ''');

    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------------------
  // _onUpgrade — runs when _schemaVersion is bumped in a future update.
  // Empty for now but structured so you can add ALTER TABLE statements later.
  // ---------------------------------------------------------------------------
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    // Future migration logic goes here.
    // Example: if (oldVersion < 2) { await db.execute('ALTER TABLE ...'); }
  }

  // ---------------------------------------------------------------------------
  // insertMessage()
  //
  // Saves a new message row inside a transaction.
  // Returns the auto-incremented row ID.
  // ---------------------------------------------------------------------------
  static Future<int> insertMessage({
    required String uuid,
    required String peerKey,
    required String senderKey,
    required String ciphertext,
    String? plaintext,
    required int timestamp,
    required bool isOutbound,
    int ttl = 7,
  }) async {
    _assertOpen();
    return await _db!.transaction((txn) async {
      return await txn.insert(
        'messages',
        {
          'uuid':        uuid,
          'peer_key':    peerKey,
          'sender_key':  senderKey,
          'ciphertext':  ciphertext,
          'plaintext':   plaintext,
          'timestamp':   timestamp,
          'is_outbound': isOutbound ? 1 : 0,
          'ttl':         ttl,
          'delivered':   0,
        },
        // If somehow the same UUID arrives twice, ignore the duplicate
        // rather than throwing an error.
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // getMessagesForPeer()
  //
  // Loads all messages exchanged with a specific peer, oldest first.
  // Used by ConversationScreen to render the chat bubble list.
  // ---------------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getMessagesForPeer(
    String peerKey,
  ) async {
    _assertOpen();
    return await _db!.query(
      'messages',
      where:   'peer_key = ?',
      whereArgs: [peerKey],
      orderBy: 'timestamp ASC',
    );
  }

  // ---------------------------------------------------------------------------
  // getAllConversations()
  //
  // Returns one row per unique peer_key, with the most recent message for
  // each peer. Used by ChatListScreen to render the conversation list.
  // ---------------------------------------------------------------------------
  static Future<List<Map<String, dynamic>>> getAllConversations() async {
    _assertOpen();
    return await _db!.rawQuery('''
      SELECT
        peer_key,
        sender_key,
        plaintext,
        ciphertext,
        MAX(timestamp) AS timestamp
      FROM messages
      GROUP BY peer_key
      ORDER BY timestamp DESC
    ''');
  }

  // ---------------------------------------------------------------------------
  // markPacketSeen()
  //
  // Inserts a UUID into the seen_packets table.
  // Called immediately after we relay a packet to prevent re-relay.
  // ---------------------------------------------------------------------------
  static Future<void> markPacketSeen(String uuid) async {
    _assertOpen();
    await _db!.insert(
      'seen_packets',
      {
        'uuid':    uuid,
        'seen_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // ---------------------------------------------------------------------------
  // hasSeenPacket()
  //
  // Returns true if this UUID has already been relayed by this device.
  // Called first when any incoming BLE packet arrives.
  // ---------------------------------------------------------------------------
  static Future<bool> hasSeenPacket(String uuid) async {
    _assertOpen();
    final rows = await _db!.query(
      'seen_packets',
      where:     'uuid = ?',
      whereArgs: [uuid],
      limit:     1,
    );
    return rows.isNotEmpty;
  }

  // ---------------------------------------------------------------------------
  // pruneSeenPackets()
  //
  // Deletes seen_packets entries older than 24 hours.
  // Call this periodically (e.g. on app resume) to prevent unbounded growth.
  // ---------------------------------------------------------------------------
  static Future<void> pruneSeenPackets() async {
    _assertOpen();
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;

    await _db!.delete(
      'seen_packets',
      where:     'seen_at < ?',
      whereArgs: [cutoff],
    );
  }

  // ---------------------------------------------------------------------------
  // nukeAllData()
  //
  // Panic button wipe — deletes every row in every table inside a single
  // ACID transaction. If the device crashes mid-wipe, SQLite rolls back
  // to the previous state rather than leaving partial data behind.
  // ---------------------------------------------------------------------------
  static Future<void> nukeAllData() async {
    _assertOpen();
    await _db!.transaction((txn) async {
      await txn.delete('messages');
      await txn.delete('seen_packets');
    });
  }

  // ---------------------------------------------------------------------------
  // close()
  //
  // Closes the database connection cleanly. Call on app dispose.
  // ---------------------------------------------------------------------------
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  // ---------------------------------------------------------------------------
  // Private guard — throws a clear error if any method is called before init().
  // ---------------------------------------------------------------------------
  static void _assertOpen() {
    if (_db == null) {
      throw StateError(
        'DatabaseService.init() must be called before using the database. '
        'Add it to your main() function.',
      );
    }
  }
}