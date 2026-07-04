import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:sync_queue/sync_queue.dart';

/// A durable [SyncStore] backed by Drift/SQLite.
///
/// The store owns a small internal Drift database with one
/// `sync_queue_records` table. The full [SyncRecord] JSON is the source of
/// truth; indexed `status`, `created_at`, and `next_attempt_at` columns keep
/// pending queries efficient for large queues.
///
/// Create one store per database file and pass the executor for your
/// platform, for example `NativeDatabase.createInBackground(file)` on mobile
/// and desktop or `WasmDatabase` on the web:
///
/// ```dart
/// final store = SyncQueueDriftStore(NativeDatabase.createInBackground(file));
/// final engine = SyncEngine(store: store, transport: MyApiTransport());
/// ```
///
/// The store follows the single-owner model documented by `sync_queue`: give
/// each database file one store and one engine. Call [close] after the owning
/// engine is disposed.
class SyncQueueDriftStore implements SyncStore {
  /// Creates a Drift-backed sync store on top of [executor].
  ///
  /// The store takes ownership of [executor] and closes it in [close].
  SyncQueueDriftStore(QueryExecutor executor)
    : _database = _SyncQueueDriftDatabase(executor);

  final _SyncQueueDriftDatabase _database;

  static const _table = 'sync_queue_records';

  @override
  Future<void> put(SyncRecord record) async {
    await _database.customStatement(
      'INSERT OR REPLACE INTO $_table '
      '(operation_id, status, created_at, next_attempt_at, record_json) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[
        record.operation.id,
        record.status.wireName,
        _encodeTime(record.operation.createdAt),
        switch (record.nextAttemptAt) {
          null => null,
          final nextAttemptAt => _encodeTime(nextAttemptAt),
        },
        jsonEncode(record.toJson()),
      ],
    );
  }

  @override
  Future<SyncRecord?> read(String operationId) async {
    final rows = await _database
        .customSelect(
          'SELECT record_json FROM $_table WHERE operation_id = ?',
          variables: [Variable<String>(operationId)],
        )
        .get();

    return rows.isEmpty ? null : _decodeRow(rows.single);
  }

  @override
  Future<List<SyncRecord>> readPending({DateTime? dueAt}) async {
    final rows = await _database
        .customSelect(
          'SELECT record_json FROM $_table '
          'WHERE status = ? '
          'AND (next_attempt_at IS NULL OR next_attempt_at <= ?) '
          'ORDER BY created_at, operation_id',
          variables: [
            Variable<String>(SyncStatus.pending.wireName),
            Variable<int>(_encodeTime(dueAt ?? DateTime.now())),
          ],
        )
        .get();

    return rows.map(_decodeRow).toList(growable: false);
  }

  @override
  Future<void> delete(String operationId) async {
    await _database.customStatement(
      'DELETE FROM $_table WHERE operation_id = ?',
      <Object?>[operationId],
    );
  }

  @override
  Future<List<SyncRecord>> readAll() async {
    final rows = await _database
        .customSelect(
          'SELECT record_json FROM $_table ORDER BY created_at, operation_id',
        )
        .get();

    return rows.map(_decodeRow).toList(growable: false);
  }

  /// Releases the underlying database connection.
  Future<void> close() {
    return _database.close();
  }

  int _encodeTime(DateTime value) {
    return value.toUtc().millisecondsSinceEpoch;
  }

  SyncRecord _decodeRow(QueryRow row) {
    final decoded = jsonDecode(row.read<String>('record_json'));
    return SyncRecord.fromJson(decoded as Map<String, Object?>);
  }
}

class _SyncQueueDriftDatabase extends GeneratedDatabase {
  _SyncQueueDriftDatabase(super.executor);

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables =>
      const <TableInfo<Table, dynamic>>[];

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (m) async {
        await customStatement(
          'CREATE TABLE IF NOT EXISTS ${SyncQueueDriftStore._table} ('
          'operation_id TEXT NOT NULL PRIMARY KEY, '
          'status TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, '
          'next_attempt_at INTEGER, '
          'record_json TEXT NOT NULL'
          ')',
        );
        await customStatement(
          'CREATE INDEX IF NOT EXISTS sync_queue_records_pending_idx '
          'ON ${SyncQueueDriftStore._table} '
          '(status, next_attempt_at, created_at)',
        );
      },
    );
  }
}
