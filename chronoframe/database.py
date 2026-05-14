import sqlite3
import threading


class CacheDB:
    def __init__(self, db_path):
        self.db_path = db_path
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self._lock = threading.Lock()
        self._init_pragmas()
        self._init_tables()

    def __enter__(self):
        return self

    def __exit__(self, _exc_type, _exc_val, _exc_tb):
        self.close()

    def close(self):
        if self.conn:
            self.conn.close()
            self.conn = None

    def _init_pragmas(self):
        try:
            result = self.conn.execute("PRAGMA journal_mode=WAL;").fetchone()
            if result[0].upper() != "WAL":
                import sys
                print(f"Warning: WAL mode not enabled (got {result[0]}); durability may be reduced", file=sys.stderr)
        except Exception as e:
            import sys
            print(f"Warning: Failed to enable WAL mode: {e}", file=sys.stderr)
        self.conn.execute("PRAGMA synchronous=NORMAL;")

    def _init_tables(self):
        with self._lock:
            try:
                self.conn.execute('''CREATE TABLE IF NOT EXISTS FileCache (
                                      id INTEGER,
                                      path TEXT,
                                      hash TEXT,
                                      size INTEGER,
                                      mtime REAL,
                                      PRIMARY KEY (id, path)
                                   )''')
                self.conn.execute('''CREATE TABLE IF NOT EXISTS CopyJobs (
                                      src_path TEXT PRIMARY KEY,
                                      dst_path TEXT,
                                      hash TEXT,
                                      status TEXT
                                   )''')
                self.conn.execute("CREATE INDEX IF NOT EXISTS idx_copyjobs_status ON CopyJobs(status)")
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to initialize database tables: {e}", file=sys.stderr)
                raise

    def get_cache_dict(self, type_id):
        with self._lock:
            cur = self.conn.execute(
                "SELECT path, hash, size, mtime FROM FileCache WHERE id = ?",
                (type_id,),
            )
            rows = cur.fetchall()
        return {row[0]: {"hash": row[1], "size": row[2], "mtime": row[3]} for row in rows}

    def save_batch(self, type_id, updates):
        if not updates:
            return
        with self._lock:
            try:
                self.conn.executemany("REPLACE INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)",
                                      [(type_id, p, h, s, m) for p, h, s, m in updates])
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to save cache batch: {e}", file=sys.stderr)
                raise

    def delete_cache_entry(self, type_id, path):
        with self._lock:
            try:
                self.conn.execute("DELETE FROM FileCache WHERE id = ? AND path = ?", (type_id, path))
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to delete cache entry: {e}", file=sys.stderr)
                raise

    def enqueue_jobs(self, jobs):
        """jobs: list of (src, dst, hash, status)"""
        if not jobs:
            return
        with self._lock:
            try:
                self.conn.executemany(
                    """
                    INSERT INTO CopyJobs (src_path, dst_path, hash, status)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(src_path) DO UPDATE SET
                        dst_path = excluded.dst_path,
                        hash = excluded.hash,
                        status = excluded.status
                    """,
                    jobs,
                )
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to enqueue jobs: {e}", file=sys.stderr)
                raise

    def get_pending_jobs(self):
        with self._lock:
            cur = self.conn.execute(
                "SELECT src_path, dst_path, hash FROM CopyJobs WHERE status = 'PENDING'"
            )
            return cur.fetchall()

    def update_job_status(self, src_path, status):
        with self._lock:
            try:
                self.conn.execute("UPDATE CopyJobs SET status = ? WHERE src_path = ?", (status, src_path))
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to update job status: {e}", file=sys.stderr)
                raise

    def update_job_statuses_batch(self, updates):
        """Batch-update job statuses. updates: list of (src_path, status) tuples."""
        if not updates:
            return
        with self._lock:
            try:
                self.conn.executemany(
                    "UPDATE CopyJobs SET status = ? WHERE src_path = ?",
                    [(status, src_path) for src_path, status in updates],
                )
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to update job statuses: {e}", file=sys.stderr)
                raise

    def clear_cache(self, type_id=None):
        """Clear hash cache. If type_id given, clear only that type (1=source, 2=dest)."""
        with self._lock:
            try:
                if type_id is not None:
                    self.conn.execute("DELETE FROM FileCache WHERE id = ?", (type_id,))
                else:
                    self.conn.execute("DELETE FROM FileCache")
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to clear cache: {e}", file=sys.stderr)
                raise

    def clear_jobs(self):
        """Clear only the copy job queue."""
        with self._lock:
            try:
                self.conn.execute("DELETE FROM CopyJobs")
                self.conn.commit()
            except Exception as e:
                self.conn.rollback()
                import sys
                print(f"Error: Failed to clear jobs: {e}", file=sys.stderr)
                raise
