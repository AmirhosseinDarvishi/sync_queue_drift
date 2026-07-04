import 'dart:io';

import 'package:drift/native.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:sync_queue_drift/sync_queue_drift.dart';

/// Queues one mutation in a durable SQLite-backed queue and drains it.
///
/// Run with `dart run example/main.dart`. In a Flutter app, place the
/// database file under `getApplicationSupportDirectory()` instead of the
/// working directory.
Future<void> main() async {
  final store = SyncQueueDriftStore(NativeDatabase(File('sync_queue.sqlite')));
  final engine = SyncEngine(store: store, transport: ConsoleSyncTransport());

  await engine.recoverInterruptedOperations(
    staleAfter: const Duration(minutes: 5),
  );

  await engine.enqueueUpdate(
    entity: const SyncEntityRef(type: 'task', id: 'task-1'),
    payload: const {'title': 'Durable offline mutation'},
  );

  final snapshot = await engine.readQueueSnapshot();
  stdout.writeln('Queued records left: ${snapshot.totalCount}');

  await engine.dispose();
  await store.close();
}

class ConsoleSyncTransport implements SyncTransport {
  @override
  Future<SyncResult> send(SyncOperation operation) async {
    stdout.writeln(
      'Sending ${operation.type.wireName} for '
      '${operation.entity.type}/${operation.entity.id}',
    );
    return const SyncResult.success();
  }
}
