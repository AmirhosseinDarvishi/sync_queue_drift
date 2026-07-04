import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:sync_queue_drift/sync_queue_drift.dart';

class FakeTransport implements SyncTransport {
  FakeTransport(this.handler);

  final Future<SyncResult> Function(SyncOperation operation) handler;
  final sent = <SyncOperation>[];

  @override
  Future<SyncResult> send(SyncOperation operation) async {
    sent.add(operation);
    return handler(operation);
  }
}

void main() {
  SyncOperation operation({
    String id = 'op-1',
    SyncEntityRef entity = const SyncEntityRef(type: 'task', id: 'task-1'),
    Map<String, Object?> payload = const <String, Object?>{
      'title': 'Ship package',
    },
    DateTime? createdAt,
  }) {
    return SyncOperation(
      id: id,
      entity: entity,
      type: SyncOperationType.update,
      payload: payload,
      createdAt: createdAt,
    );
  }

  SyncQueueDriftStore memoryStore() {
    final store = SyncQueueDriftStore(NativeDatabase.memory());
    addTearDown(store.close);
    return store;
  }

  test('put and read round-trip a full record', () async {
    final store = memoryStore();
    final record = SyncRecord(
      operation: operation(createdAt: DateTime.utc(2026, 7, 1, 12)),
      status: SyncStatus.failed,
      attempts: 3,
      nextAttemptAt: DateTime.utc(2026, 7, 1, 12, 5),
      lastFailure: const SyncFailure(
        message: 'Server unavailable',
        code: 'unavailable',
      ),
      updatedAt: DateTime.utc(2026, 7, 1, 12, 1),
    );

    await store.put(record);
    final loaded = await store.read('op-1');

    expect(loaded, isNotNull);
    expect(loaded!.operation.id, 'op-1');
    expect(
      loaded.operation.entity,
      const SyncEntityRef(type: 'task', id: 'task-1'),
    );
    expect(loaded.operation.type, SyncOperationType.update);
    expect(loaded.operation.payload, const {'title': 'Ship package'});
    expect(loaded.operation.createdAt, DateTime.utc(2026, 7, 1, 12));
    expect(loaded.status, SyncStatus.failed);
    expect(loaded.attempts, 3);
    expect(loaded.nextAttemptAt, DateTime.utc(2026, 7, 1, 12, 5));
    expect(loaded.lastFailure?.message, 'Server unavailable');
    expect(loaded.lastFailure?.code, 'unavailable');
    expect(loaded.updatedAt, DateTime.utc(2026, 7, 1, 12, 1));
  });

  test('put and read round-trip a conflicted record', () async {
    final store = memoryStore();
    final record = SyncRecord(
      operation: operation(createdAt: DateTime.utc(2026, 7, 1, 12)),
      status: SyncStatus.conflicted,
      conflict: const SyncConflict(
        message: 'Server version changed',
        local: {'title': 'Local title'},
        remote: {'title': 'Remote title'},
      ),
      updatedAt: DateTime.utc(2026, 7, 1, 12, 1),
    );

    await store.put(record);
    final loaded = await store.read('op-1');

    expect(loaded?.status, SyncStatus.conflicted);
    expect(loaded?.conflict?.message, 'Server version changed');
    expect(loaded?.conflict?.local, const {'title': 'Local title'});
    expect(loaded?.conflict?.remote, const {'title': 'Remote title'});
  });

  test('put replaces an existing record by operation id', () async {
    final store = memoryStore();
    final now = DateTime.utc(2026, 7, 1, 12);
    final pending = SyncRecord(operation: operation(createdAt: now));

    await store.put(pending);
    await store.put(
      pending.copyWith(
        status: SyncStatus.failed,
        attempts: 2,
        lastFailure: const SyncFailure(message: 'Rejected'),
        updatedAt: now.add(const Duration(seconds: 1)),
      ),
    );

    final records = await store.readAll();
    expect(records, hasLength(1));
    expect(records.single.status, SyncStatus.failed);
    expect(records.single.attempts, 2);
  });

  test('read returns null for a missing operation id', () async {
    final store = memoryStore();
    expect(await store.read('missing'), isNull);
  });

  test('delete removes a record and ignores missing ids', () async {
    final store = memoryStore();
    final now = DateTime.utc(2026, 7, 1, 12);

    await store.put(SyncRecord(operation: operation(createdAt: now)));
    await store.delete('op-1');
    await store.delete('missing');

    expect(await store.readAll(), isEmpty);
  });

  test('read all returns records ordered by operation creation time', () async {
    final store = memoryStore();
    final now = DateTime.utc(2026, 7, 1, 12);

    await store.put(
      SyncRecord(
        operation: operation(
          id: 'third',
          createdAt: now.add(const Duration(seconds: 2)),
        ),
      ),
    );
    await store.put(
      SyncRecord(
        operation: operation(id: 'first', createdAt: now),
      ),
    );
    await store.put(
      SyncRecord(
        operation: operation(
          id: 'second',
          createdAt: now.add(const Duration(seconds: 1)),
        ),
      ),
    );

    final records = await store.readAll();
    expect(records.map((record) => record.operation.id), <String>[
      'first',
      'second',
      'third',
    ]);
  });

  test('read pending returns only due pending records in order', () async {
    final store = memoryStore();
    final now = DateTime.utc(2026, 7, 1, 12);

    await store.put(
      SyncRecord(
        operation: operation(id: 'due-later-created-first', createdAt: now),
        nextAttemptAt: now.subtract(const Duration(minutes: 1)),
      ),
    );
    await store.put(
      SyncRecord(
        operation: operation(
          id: 'due-now',
          createdAt: now.add(const Duration(seconds: 1)),
        ),
      ),
    );
    await store.put(
      SyncRecord(
        operation: operation(
          id: 'due-future',
          createdAt: now.add(const Duration(seconds: 2)),
        ),
        nextAttemptAt: now.add(const Duration(minutes: 5)),
      ),
    );
    await store.put(
      SyncRecord(
        operation: operation(
          id: 'failed',
          createdAt: now.add(const Duration(seconds: 3)),
        ),
        status: SyncStatus.failed,
        lastFailure: const SyncFailure(message: 'Needs attention'),
      ),
    );

    final pending = await store.readPending(dueAt: now);
    expect(pending.map((record) => record.operation.id), <String>[
      'due-later-created-first',
      'due-now',
    ]);
  });

  test('records persist across store instances on the same file', () async {
    final directory = await Directory.systemTemp.createTemp('sync_queue_drift');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/queue.sqlite');
    final now = DateTime.utc(2026, 7, 1, 12);

    final writer = SyncQueueDriftStore(NativeDatabase(file));
    await writer.put(SyncRecord(operation: operation(createdAt: now)));
    await writer.close();

    final reader = SyncQueueDriftStore(NativeDatabase(file));
    addTearDown(reader.close);
    final records = await reader.readAll();

    expect(records, hasLength(1));
    expect(records.single.operation.id, 'op-1');
    expect(records.single.status, SyncStatus.pending);
  });

  test('sync engine drains queued work through the drift store', () async {
    final store = memoryStore();
    final transport = FakeTransport((_) async => const SyncResult.success());
    final engine = SyncEngine(store: store, transport: transport);
    addTearDown(engine.dispose);

    await engine.enqueueUpdate(
      entity: const SyncEntityRef(type: 'task', id: 'task-1'),
      payload: const {'title': 'Durable mutation'},
    );

    expect(transport.sent, hasLength(1));
    expect(transport.sent.single.payload, const {'title': 'Durable mutation'});
    expect(await store.readAll(), isEmpty);
  });

  test('sync engine persists failures through the drift store', () async {
    final store = memoryStore();
    final transport = FakeTransport(
      (_) async => const SyncResult.failure(
        SyncFailure(message: 'Rejected by server', isRetryable: false),
      ),
    );
    final engine = SyncEngine(
      store: store,
      transport: transport,
      retryPolicy: const RetryPolicy(maxAttempts: 1),
    );
    addTearDown(engine.dispose);

    await engine.enqueueUpdate(
      entity: const SyncEntityRef(type: 'task', id: 'task-1'),
      payload: const {'title': 'Will fail'},
    );

    final records = await store.readAll();
    expect(records, hasLength(1));
    expect(records.single.status, SyncStatus.failed);
    expect(records.single.lastFailure?.message, 'Rejected by server');
  });
}
