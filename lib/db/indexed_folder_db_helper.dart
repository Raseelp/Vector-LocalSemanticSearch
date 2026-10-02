import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:twentyonevision/models/collection_model.dart';
import 'package:twentyonevision/models/indexed_folder_model.dart';

class IndexedFolderDbHelper {
  IndexedFolderDbHelper._();

  static final IndexedFolderDbHelper instance = IndexedFolderDbHelper._();

  static const _dbName = 'twentyonevision.db';
  // onUpgrade just drops and recreates this table - it's disposable UI
  // bookkeeping, the actual embeddings live in the native store untouched.
  static const _dbVersion = 5;

  // User-created collections, plus a bare row (hidden = 1) for a built-in
  // the user has hidden - built-ins themselves live in code, see
  // default_collections.dart. Unlike the folders table this is real user
  // data, so it's created by an additive migration, never dropped.
  static const collectionsTable = 'collections';

  static const id = 'id';
  static const table = 'indexed_folders';
  static const colPath = 'path';
  static const colTotal = 'total';
  static const colEmbedded = 'embedded';
  static const colSkipped = 'skipped';
  static const colElapsedMs = 'elapsedMs';
  static const colProcessed = 'processed';
  static const colUpdatedAt = 'updatedAt';

  Database? _db;

  Future<Database> get database async {
    final existing = _db;
    if (existing != null) return existing;
    _db = await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createFoldersTable(Database db) async {
    await db.execute('''
      CREATE TABLE $table (
        $id TEXT PRIMARY KEY,
        $colPath TEXT,
        $colTotal INTEGER,
        $colEmbedded INTEGER,
        $colSkipped INTEGER,
        $colElapsedMs INTEGER,
        $colProcessed INTEGER,
        $colUpdatedAt INTEGER
      )
    ''');
  }

  Future<void> _createCollectionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE $collectionsTable (
        id TEXT PRIMARY KEY,
        name TEXT,
        emoji TEXT,
        prompts TEXT,
        contentMode TEXT,
        sensitivity REAL,
        isBuiltIn INTEGER,
        hidden INTEGER,
        createdAt INTEGER,
        kind TEXT,
        seed TEXT,
        personIds TEXT
      )
    ''');
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createFoldersTable(db);
    await _createCollectionsTable(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS $table');
      await _createFoldersTable(db);
    }
    if (oldVersion < 3) {
      // Freshly created, so it already has every column below - the two
      // branches underneath only apply to a table that already existed.
      await _createCollectionsTable(db);
    } else {
      if (oldVersion < 4) {
        // Photo-seeded collections - additive, existing rows keep working
        // (a null kind reads as 'text').
        await db.execute("ALTER TABLE $collectionsTable ADD COLUMN kind TEXT");
        await db.execute("ALTER TABLE $collectionsTable ADD COLUMN seed TEXT");
      }
      if (oldVersion < 5) {
        // Person-mention collections - additive, existing rows keep working
        // (a null personIds reads as "no person filter").
        await db.execute("ALTER TABLE $collectionsTable ADD COLUMN personIds TEXT");
      }
    }
  }

  // ---- Collections ----
  //
  // One table for both kinds. A user collection is a full row. A built-in
  // has a row only once the user has changed something about it: `hidden`
  // is 0 visible, 1 hidden, 2 deleted (a built-in can't truly be deleted -
  // it lives in code - so deleted just means "off the list until restored
  // from Settings"), and a non-empty `prompts` means the user edited it.

  Future<List<Map<String, Object?>>> getCollectionRows() async {
    final db = await database;
    return db.query(collectionsTable, orderBy: 'createdAt ASC');
  }

  Future<void> upsertCollection(SmartCollection collection, {int hiddenState = 0}) async {
    final db = await database;
    await db.insert(
      collectionsTable,
      collection.toRow(hiddenState: hiddenState),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteCollection(String collectionId) async {
    final db = await database;
    await db.delete(collectionsTable, where: 'id = ?', whereArgs: [collectionId]);
  }

  /// Sets hidden (1) / deleted (2) / visible (0). A built-in with no row yet
  /// gets a bare one (empty prompts = no edits, just the state).
  Future<void> setCollectionState(String collectionId, int state, {required bool isBuiltIn}) async {
    final db = await database;
    final updated = await db.update(
      collectionsTable,
      {'hidden': state},
      where: 'id = ?',
      whereArgs: [collectionId],
    );
    if (updated == 0 && isBuiltIn && state != 0) {
      await db.insert(collectionsTable, {
        'id': collectionId,
        'name': '',
        'emoji': '',
        'prompts': '[]',
        'contentMode': 'both',
        'sensitivity': 0.0,
        'isBuiltIn': 1,
        'hidden': state,
        'createdAt': 0,
      });
    }
  }

  /// Every built-in back to how it ships: undeleted, unhidden, unedited.
  Future<void> resetBuiltIns() async {
    final db = await database;
    await db.delete(collectionsTable, where: 'isBuiltIn = 1');
  }

  Future<int> upsertFolder({required IndexedFolder folder}) async {
    final db = await database;
    return db.insert(
      table,
      folder.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<IndexedFolder?> getFolderById({required String folderid}) async {
    final db = await database;
    final rows = await db.query(
      table,
      where: '$id = ?',
      whereArgs: [folderid],
      limit: 1,
    );

    if (rows.isEmpty) return null;
    return IndexedFolder.fromMap(rows.first);
  }

  Future<List<IndexedFolder>> getAllFolders() async {
    final db = await database;
    final rows = await db.query(table, orderBy: '$colUpdatedAt DESC');
    return rows.map(IndexedFolder.fromMap).toList();
  }

  Future<int> deleteById(String folderid) async {
    final db = await database;
    return db.delete(table, where: '$id = ?', whereArgs: [folderid]);
  }

  Future<int> clearFolderList() async {
    final db = await database;
    return db.delete(table);
  }

  Future<void> close() async {
    final db = _db;
    if (db == null) return;
    await db.close();
    _db = null;
  }
}
