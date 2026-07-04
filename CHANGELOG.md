## 0.1.0

* Add `SyncQueueDriftStore`, a durable Drift/SQLite `SyncStore` for
  `sync_queue`.
* Persist full queue records as JSON with indexed status and retry-time
  columns for efficient due-pending queries.
* Preserve operation creation-time ordering for queue reads and pending
  queries.
