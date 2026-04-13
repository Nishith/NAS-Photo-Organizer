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

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()

    def close(self):
        if self.conn:
            self.conn.close()
            self.conn = None

    def _init_pragmas(self):
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.execute("PRAGMA synchronous=NORMAL;")

    def _init_tables(self):
        with self._lock:
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
            self.conn.commit()

    def get_cache_dict(self, type_id):
        cur = self.conn.execute("SELECT path, hash, size, mtime FROM FileCache WHERE id = ?", (type_id,))
        return {row[0]: {"hash": row[1], "size": row[2], "mtime": row[3]} for row in cur}

    def save_batch(self, type_id, updates):
        if not updates:
            return
        with self._lock:
            self.conn.executemany("REPLACE INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)",
                                  [(type_id, p, h, s, m) for p, h, s, m in updates])
            self.conn.commit()

    def enqueue_jobs(self, jobs):
        """jobs: list of (src, dst, hash, status)"""
        if not jobs:
            return
        with self._lock:
            self.conn.executemany("INSERT OR IGNORE INTO CopyJobs (src_path, dst_path, hash, status) VALUES (?, ?, ?, ?)", jobs)
            self.conn.commit()

    def get_pending_jobs(self):
        cur = self.conn.execute("SELECT src_path, dst_path, hash FROM CopyJobs WHERE status = 'PENDING'")
        return cur.fetchall()

    def update_job_status(self, src_path, status):
        with self._lock:
            self.conn.execute("UPDATE CopyJobs SET status = ? WHERE src_path = ?", (status, src_path))
            self.conn.commit()

    def clear_cache(self, type_id=None):
        """Clear hash cache. If type_id given, clear only that type (1=source, 2=dest)."""
        with self._lock:
            if type_id is not None:
                self.conn.execute("DELETE FROM FileCache WHERE id = ?", (type_id,))
            else:
                self.conn.execute("DELETE FROM FileCache")
            self.conn.commit()

    def clear_jobs(self):
        """Clear only the copy job queue."""
        with self._lock:
            self.conn.execute("DELETE FROM CopyJobs")
            self.conn.commit()

    def clear_all(self):
        """Nuclear option: clear everything."""
        with self._lock:
            self.conn.execute("DELETE FROM FileCache")
            self.conn.execute("DELETE FROM CopyJobs")
            self.conn.commit()
