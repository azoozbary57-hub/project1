import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/note.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final dbPath = join(dir.path, 'notes_sync.db');

    return databaseFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE notes (
              id TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              updated_at INTEGER NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('''
            CREATE TABLE meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        },
      ),
    );
  }
}

class NotesRepository {
  Future<Database> get _db => AppDatabase.instance.database;

  Future<List<Note>> getAll({bool includeDeleted = false}) async {
    final db = await _db;
    final rows = await db.query(
      'notes',
      where: includeDeleted ? null : 'deleted = 0',
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromDbMap).toList();
  }

  Future<Note?> getById(String id) async {
    final db = await _db;
    final rows = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Note.fromDbMap(rows.first);
  }

  Future<void> put(Note note) async {
    final db = await _db;
    await db.insert(
      'notes',
      note.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> putAll(Iterable<Note> notes) async {
    final db = await _db;
    final batch = db.batch();
    for (final note in notes) {
      batch.insert(
        'notes',
        note.toDbMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Soft-delete: keeps a tombstone so the deletion propagates to peers.
  Future<void> delete(String id) async {
    final existing = await getById(id);
    if (existing == null) return;
    await put(existing.copyWith(
      deleted: true,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<List<Note>> getTrash() async {
    final db = await _db;
    final rows = await db.query(
      'notes',
      where: 'deleted = 1',
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromDbMap).toList();
  }

  Future<void> restore(String id) async {
    final existing = await getById(id);
    if (existing == null) return;
    await put(existing.copyWith(
      deleted: false,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// Removes the note from this device's local database only. Other devices
  /// keep their own tombstone until they independently purge it too.
  Future<void> purge(String id) async {
    final db = await _db;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<String?> getMeta(String key) async {
    final db = await _db;
    final rows = await db.query('meta', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> setMeta(String key, String value) async {
    final db = await _db;
    await db.insert(
      'meta',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearMeta(String key) async {
    final db = await _db;
    await db.delete('meta', where: 'key = ?', whereArgs: [key]);
  }
}
