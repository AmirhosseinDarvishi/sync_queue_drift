# sync_queue_drift

A durable Drift/SQLite store for
[`sync_queue`](https://pub.dev/packages/sync_queue), the offline-first
mutation queue and sync engine core for Flutter apps.

`sync_queue` keeps storage abstract behind its `SyncStore` interface. This
package is the production-ready answer to `final store = ???`: a
`SyncStore` backed by [Drift](https://pub.dev/packages/drift), so queued
mutations survive app restarts without writing a persistence layer yourself.

## Features

- Durable `SyncStore` implementation on top of Drift/SQLite.
- Full queue records persisted as JSON, so new `sync_queue` record fields do
  not require schema migrations.
- Indexed status and retry-time columns for efficient due-pending queries on
  large queues.
- Creation-time ordering preserved for queue reads, matching the engine's
  per-entity ordering rules.
- Works with any Drift executor: native databases on mobile and desktop,
  `WasmDatabase` on the web.

## Getting Started

Add the dependencies:

```yaml
dependencies:
  sync_queue: ^1.2.0
  sync_queue_drift: ^0.1.0
  drift: ^2.20.0
  sqlite3_flutter_libs: ^0.5.0 # bundles SQLite on Android/iOS/macOS
```

Create the store with an executor for your platform and hand it to the
engine:

```dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:sync_queue_drift/sync_queue_drift.dart';

Future<SyncEngine> createEngine(SyncTransport transport) async {
  final directory = await getApplicationSupportDirectory();
  final file = File('${directory.path}/sync_queue.sqlite');

  final store = SyncQueueDriftStore(NativeDatabase.createInBackground(file));
  final engine = SyncEngine(store: store, transport: transport);

  await engine.recoverInterruptedOperations(
    staleAfter: const Duration(minutes: 5),
  );

  return engine;
}
```

Everything else works exactly like the `sync_queue` documentation describes:
enqueue mutations, drain, resolve conflicts, and watch sync state.

## Ownership Model

Follow the single-owner model from the
[`sync_queue` concurrency guide](https://github.com/AmirhosseinDarvishi/sync_queue/blob/main/doc/concurrency.md):

- Create one `SyncQueueDriftStore` per database file.
- Give that store to one `SyncEngine`, owned by one isolate.
- Call `store.close()` after the engine is disposed.

The store takes ownership of the executor you pass in and closes it in
`close()`.

## Storage Schema

The store manages a single table and keeps its schema internal:

```sql
CREATE TABLE sync_queue_records (
  operation_id    TEXT NOT NULL PRIMARY KEY,
  status          TEXT NOT NULL,
  created_at      INTEGER NOT NULL, -- UTC milliseconds since epoch
  next_attempt_at INTEGER,          -- UTC milliseconds since epoch
  record_json     TEXT NOT NULL     -- full SyncRecord JSON, source of truth
);
```

The JSON column is the source of truth; the other columns exist only for
indexed queries and ordering. Treat the table as owned by this package rather
than joining application queries against it.

## Roadmap

- Transactional queue rewrites once `sync_queue` exposes a transactional
  store boundary for compaction and replacement APIs.
- Claim/lease support for background workers, following the core package's
  multi-writer storage story.

## License

Apache 2.0 — see [LICENSE](LICENSE).
