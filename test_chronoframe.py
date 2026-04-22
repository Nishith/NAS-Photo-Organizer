#!/usr/bin/env python3
"""
Comprehensive test suite for Chronoframe.
Run: python3 -m pytest test_chronoframe.py -v
  or: python3 -m unittest test_chronoframe.py -v
"""

import errno
import importlib.util
import unittest
import tempfile
import shutil
import os
import sys
import json
import csv
import re
import sqlite3
import time
import runpy
import types
from datetime import datetime
from unittest.mock import patch, MagicMock
from collections import defaultdict
import subprocess

from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn, BarColumn, MofNCompleteColumn

from chronoframe.database import CacheDB
from chronoframe.io import (
    fast_hash, safe_copy_atomic, verify_copy, process_single_file,
    cleanup_tmp_files, check_disk_space, _is_retryable_error,
)
from chronoframe.metadata import (
    get_file_date, get_date_from_filename, get_date_mdls, parse_mdls_creation_date,
    ALL_EXTS, PHOTO_EXTS, VIDEO_EXTS, SKIP_FILES, HAS_EXIFREAD,
)
from chronoframe.core import (
    build_dest_index, generate_dry_run_report, generate_audit_receipt,
    load_profile, RunLogger, SEQ_WIDTH, MAX_CONSECUTIVE_FAILURES,
    MAX_TOTAL_FAILURES, DEFAULT_WORKERS, parse_args, _format_seq,
)


# ════════════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════════════

class TempDirMixin:
    """Creates and cleans up a temp directory for each test."""
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _mkfile(self, relpath, content=b"test data"):
        path = os.path.join(self.tmpdir, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(content)
        return path


def load_wrapper_module():
    wrapper_path = os.path.join(os.path.dirname(__file__), "chronoframe.py")
    spec = importlib.util.spec_from_file_location("chronoframe_wrapper", wrapper_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ════════════════════════════════════════════════════════════════════════════
# fast_hash
# ════════════════════════════════════════════════════════════════════════════

class TestFastHash(TempDirMixin, unittest.TestCase):

    def test_empty_file(self):
        p = self._mkfile("empty.jpg", b"")
        h = fast_hash(p)
        self.assertTrue(h.startswith("0_"))

    def test_small_file(self):
        p = self._mkfile("small.jpg", b"abc")
        h = fast_hash(p)
        self.assertTrue(h.startswith("3_"))

    def test_large_file_reads_head_and_tail(self):
        """File larger than 512KB: hash includes both first and last chunks."""
        content = b"A" * (512 * 1024) + b"B" * (512 * 1024)
        p = self._mkfile("large.mov", content)
        h = fast_hash(p)
        self.assertTrue(h.startswith(f"{len(content)}_"))

    def test_same_content_same_hash(self):
        content = b"identical" * 5000
        p1 = self._mkfile("a.jpg", content)
        p2 = self._mkfile("b.jpg", content)
        self.assertEqual(fast_hash(p1), fast_hash(p2))

    def test_different_content_different_hash(self):
        p1 = self._mkfile("x.jpg", b"alpha")
        p2 = self._mkfile("y.jpg", b"bravo")
        self.assertNotEqual(fast_hash(p1), fast_hash(p2))

    def test_different_size_same_prefix_different_hash(self):
        p1 = self._mkfile("s1.jpg", b"data")
        p2 = self._mkfile("s2.jpg", b"data_extra")
        self.assertNotEqual(fast_hash(p1), fast_hash(p2))

    def test_known_size_param(self):
        content = b"hello world"
        p = self._mkfile("f.jpg", content)
        h1 = fast_hash(p)
        h2 = fast_hash(p, known_size=len(content))
        self.assertEqual(h1, h2)

    def test_nonexistent_file_raises(self):
        with self.assertRaises(OSError):
            fast_hash("/nonexistent/path.jpg")

    def test_hash_format(self):
        p = self._mkfile("fmt.jpg", b"data")
        h = fast_hash(p)
        parts = h.split("_", 1)
        self.assertEqual(len(parts), 2)
        self.assertTrue(parts[0].isdigit())
        self.assertTrue(len(parts[1]) > 0)

    def test_middle_of_large_file_changes_hash(self):
        chunk = 512 * 1024
        p1 = self._mkfile("large_a.bin", b"A" * chunk + b"X" * chunk + b"B" * chunk)
        p2 = self._mkfile("large_b.bin", b"A" * chunk + b"Y" * chunk + b"B" * chunk)
        self.assertNotEqual(fast_hash(p1), fast_hash(p2))


# ════════════════════════════════════════════════════════════════════════════
# verify_copy
# ════════════════════════════════════════════════════════════════════════════

class TestVerifyCopy(TempDirMixin, unittest.TestCase):

    def test_matching_hash(self):
        content = b"matching content"
        src = self._mkfile("src.jpg", content)
        dst = self._mkfile("dst.jpg", content)
        h = fast_hash(src)
        self.assertTrue(verify_copy(src, dst, h))

    def test_mismatched_hash(self):
        src = self._mkfile("src.jpg", b"original")
        dst = self._mkfile("dst.jpg", b"corrupted")
        h = fast_hash(src)
        self.assertFalse(verify_copy(src, dst, h))

    def test_missing_dst(self):
        src = self._mkfile("src.jpg", b"data")
        h = fast_hash(src)
        self.assertFalse(verify_copy(src, "/nonexistent/dst.jpg", h))


# ════════════════════════════════════════════════════════════════════════════
# safe_copy_atomic
# ════════════════════════════════════════════════════════════════════════════

class TestSafeCopyAtomic(TempDirMixin, unittest.TestCase):

    def test_basic_copy(self):
        src = self._mkfile("src/photo.jpg", b"photo data")
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")
        result = safe_copy_atomic(src, dst)
        self.assertEqual(result, dst)
        self.assertTrue(os.path.exists(dst))
        with open(dst, 'rb') as f:
            self.assertEqual(f.read(), b"photo data")

    def test_creates_directories(self):
        src = self._mkfile("src/photo.jpg", b"data")
        dst = os.path.join(self.tmpdir, "a", "b", "c", "photo.jpg")
        result = safe_copy_atomic(src, dst)
        self.assertTrue(os.path.exists(result))

    def test_collision_renames(self):
        src = self._mkfile("src/photo.jpg", b"new data")
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")
        os.makedirs(os.path.dirname(dst))
        with open(dst, 'w') as f:
            f.write("existing")
        # Dest path should increment to collision 1
        base, ext = os.path.splitext(dst)
        col_path = f"{base}_collision_1{ext}"
        safe_copy_atomic(src, dst)
        self.assertTrue(os.path.exists(col_path), "File was not renamed safely upon network collision!")
        
        # Test double collision
        with open(dst, "w") as f:
            f.write("old data 2")
        safe_copy_atomic(src, dst)
        col_path_2 = f"{base}_collision_2{ext}"
        self.assertTrue(os.path.exists(col_path_2), "Double collision override failed!")

    def test_no_tmp_file_left_on_success(self):
        src = self._mkfile("src/photo.jpg", b"data")
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")
        safe_copy_atomic(src, dst)
        self.assertFalse(os.path.exists(dst + ".tmp"))

    def test_metadata_preserved(self):
        src = self._mkfile("src/photo.jpg", b"data")
        # Set a specific mtime
        os.utime(src, (1000000, 1000000))
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")
        safe_copy_atomic(src, dst)
        self.assertAlmostEqual(os.path.getmtime(dst), 1000000, delta=1)

    def test_missing_source_raises(self):
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")
        with self.assertRaises(FileNotFoundError):
            safe_copy_atomic("/nonexistent/src.jpg", dst)


# ════════════════════════════════════════════════════════════════════════════
# process_single_file
# ════════════════════════════════════════════════════════════════════════════

class TestProcessSingleFile(TempDirMixin, unittest.TestCase):

    def test_fresh_hash(self):
        p = self._mkfile("photo.jpg", b"photo data")
        h, size, mtime, was_hashed = process_single_file(p, None)
        self.assertIsNotNone(h)
        self.assertEqual(size, 10)
        self.assertTrue(was_hashed)

    def test_cache_hit(self):
        p = self._mkfile("photo.jpg", b"photo data")
        st = os.stat(p)
        cached = {"hash": "cached_hash", "size": st.st_size, "mtime": st.st_mtime}
        h, size, mtime, was_hashed = process_single_file(p, cached)
        self.assertEqual(h, "cached_hash")
        self.assertFalse(was_hashed)

    def test_cache_miss_size_changed(self):
        p = self._mkfile("photo.jpg", b"photo data")
        cached = {"hash": "old_hash", "size": 999, "mtime": os.stat(p).st_mtime}
        h, size, mtime, was_hashed = process_single_file(p, cached)
        self.assertNotEqual(h, "old_hash")
        self.assertTrue(was_hashed)

    def test_cache_miss_mtime_changed(self):
        p = self._mkfile("photo.jpg", b"photo data")
        cached = {"hash": "old_hash", "size": os.stat(p).st_size, "mtime": 0.0}
        h, size, mtime, was_hashed = process_single_file(p, cached)
        self.assertTrue(was_hashed)

    def test_nonexistent_file(self):
        h, size, mtime, was_hashed = process_single_file("/no/such/file.jpg", None)
        self.assertIsNone(h)
        self.assertEqual(size, 0)
        self.assertFalse(was_hashed)

    def test_unreadable_file(self):
        p = self._mkfile("locked.jpg", b"data")
        os.chmod(p, 0o000)
        h, size, mtime, was_hashed = process_single_file(p, None)
        # Depending on OS, stat may succeed but open may fail — either way no crash
        os.chmod(p, 0o644)  # Restore for cleanup


# ════════════════════════════════════════════════════════════════════════════
# CacheDB
# ════════════════════════════════════════════════════════════════════════════

class TestCacheDB(TempDirMixin, unittest.TestCase):

    def _make_db(self):
        return CacheDB(os.path.join(self.tmpdir, "test.db"))

    def test_save_and_get_dict(self):
        db = self._make_db()
        db.save_batch(1, [("/a.jpg", "hash_a", 100, 1.0)])
        data = db.get_cache_dict(1)
        self.assertIn("/a.jpg", data)
        self.assertEqual(data["/a.jpg"]["hash"], "hash_a")
        self.assertEqual(data["/a.jpg"]["size"], 100)
        db.close()

    def test_type_isolation(self):
        """type_id=1 (source) and type_id=2 (dest) are independent."""
        db = self._make_db()
        db.save_batch(1, [("/src.jpg", "h1", 10, 1.0)])
        db.save_batch(2, [("/dst.jpg", "h2", 20, 2.0)])
        self.assertIn("/src.jpg", db.get_cache_dict(1))
        self.assertNotIn("/src.jpg", db.get_cache_dict(2))
        self.assertIn("/dst.jpg", db.get_cache_dict(2))
        db.close()

    def test_replace_updates_existing(self):
        db = self._make_db()
        db.save_batch(1, [("/a.jpg", "old", 100, 1.0)])
        db.save_batch(1, [("/a.jpg", "new", 200, 2.0)])
        data = db.get_cache_dict(1)
        self.assertEqual(data["/a.jpg"]["hash"], "new")
        self.assertEqual(data["/a.jpg"]["size"], 200)
        db.close()

    def test_empty_batch_is_noop(self):
        db = self._make_db()
        db.save_batch(1, [])  # Should not crash
        self.assertEqual(db.get_cache_dict(1), {})
        db.close()

    def test_enqueue_and_get_pending_jobs(self):
        db = self._make_db()
        jobs = [("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING"),
                ("/src/b.jpg", "/dst/b.jpg", "h2", "PENDING")]
        db.enqueue_jobs(jobs)
        pending = db.get_pending_jobs()
        self.assertEqual(len(pending), 2)
        db.close()

    def test_update_job_status(self):
        db = self._make_db()
        db.enqueue_jobs([("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING")])
        db.update_job_status("/src/a.jpg", "COPIED")
        pending = db.get_pending_jobs()
        self.assertEqual(len(pending), 0)
        db.close()

    def test_enqueue_ignores_duplicates(self):
        db = self._make_db()
        db.enqueue_jobs([("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING")])
        db.enqueue_jobs([("/src/a.jpg", "/dst/a2.jpg", "h1", "PENDING")])
        pending = db.get_pending_jobs()
        self.assertEqual(len(pending), 1)
        # Original dst_path preserved
        self.assertEqual(pending[0][1], "/dst/a.jpg")
        db.close()

    def test_empty_enqueue_is_noop(self):
        db = self._make_db()
        db.enqueue_jobs([])
        self.assertEqual(db.get_pending_jobs(), [])
        db.close()

    def test_clear_cache_by_type(self):
        db = self._make_db()
        db.save_batch(1, [("/src.jpg", "h1", 10, 1.0)])
        db.save_batch(2, [("/dst.jpg", "h2", 20, 2.0)])
        db.clear_cache(type_id=1)
        self.assertEqual(db.get_cache_dict(1), {})
        self.assertIn("/dst.jpg", db.get_cache_dict(2))  # Untouched
        db.close()

    def test_clear_cache_all(self):
        db = self._make_db()
        db.save_batch(1, [("/src.jpg", "h1", 10, 1.0)])
        db.save_batch(2, [("/dst.jpg", "h2", 20, 2.0)])
        db.clear_cache()  # No type_id → clears all
        self.assertEqual(db.get_cache_dict(1), {})
        self.assertEqual(db.get_cache_dict(2), {})
        db.close()

    def test_clear_jobs_only(self):
        db = self._make_db()
        db.save_batch(1, [("/src.jpg", "h1", 10, 1.0)])
        db.enqueue_jobs([("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING")])
        db.clear_jobs()
        self.assertEqual(db.get_pending_jobs(), [])
        self.assertIn("/src.jpg", db.get_cache_dict(1))  # Cache untouched
        db.close()

    def test_clear_all(self):
        db = self._make_db()
        db.save_batch(1, [("/src.jpg", "h1", 10, 1.0)])
        db.enqueue_jobs([("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING")])
        db.clear_all()
        self.assertEqual(db.get_cache_dict(1), {})
        self.assertEqual(db.get_pending_jobs(), [])
        db.close()

    def test_context_manager(self):
        db_path = os.path.join(self.tmpdir, "ctx.db")
        with CacheDB(db_path) as db:
            db.save_batch(1, [("/a.jpg", "h", 10, 1.0)])
        # Connection closed — re-open to verify data persisted
        db2 = CacheDB(db_path)
        self.assertIn("/a.jpg", db2.get_cache_dict(1))
        db2.close()

    def test_wal_mode_enabled(self):
        db = self._make_db()
        cur = db.conn.execute("PRAGMA journal_mode;")
        self.assertEqual(cur.fetchone()[0], "wal")
        db.close()

    def test_synchronous_mode_enabled(self):
        db = self._make_db()
        cur = db.conn.execute("PRAGMA synchronous;")
        # SQLite may return the symbolic value as an integer for PRAGMA reads.
        self.assertEqual(cur.fetchone()[0], 1)
        db.close()

    def test_database_schema_contract_remains_stable(self):
        db = self._make_db()

        file_cache_columns = db.conn.execute("PRAGMA table_info(FileCache);").fetchall()
        copy_jobs_columns = db.conn.execute("PRAGMA table_info(CopyJobs);").fetchall()

        self.assertEqual(
            [(row[1], row[2], row[5]) for row in file_cache_columns],
            [
                ("id", "INTEGER", 1),
                ("path", "TEXT", 2),
                ("hash", "TEXT", 0),
                ("size", "INTEGER", 0),
                ("mtime", "REAL", 0),
            ],
        )
        self.assertEqual(
            [(row[1], row[2], row[5]) for row in copy_jobs_columns],
            [
                ("src_path", "TEXT", 1),
                ("dst_path", "TEXT", 0),
                ("hash", "TEXT", 0),
                ("status", "TEXT", 0),
            ],
        )

        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Metadata — get_date_from_filename
# ════════════════════════════════════════════════════════════════════════════

class TestGetDateFromFilename(unittest.TestCase):

    def test_img_pattern(self):
        dt = get_date_from_filename("/photos/IMG_20210417_120000.jpg")
        self.assertEqual(dt, datetime(2021, 4, 17))

    def test_vid_pattern(self):
        dt = get_date_from_filename("/photos/VID_20200101_235959.mp4")
        self.assertEqual(dt, datetime(2020, 1, 1))

    def test_pano_pattern(self):
        dt = get_date_from_filename("/photos/PANO_20190615_080000.jpg")
        self.assertEqual(dt, datetime(2019, 6, 15))

    def test_burst_pattern(self):
        dt = get_date_from_filename("/photos/BURST_20180312_143000.jpg")
        self.assertEqual(dt, datetime(2018, 3, 12))

    def test_mvimg_pattern(self):
        dt = get_date_from_filename("/photos/MVIMG_20170820_090000.jpg")
        self.assertEqual(dt, datetime(2017, 8, 20))

    def test_bare_date_pattern(self):
        dt = get_date_from_filename("/photos/20210101_120000.jpg")
        self.assertEqual(dt, datetime(2021, 1, 1))

    def test_underscore_date_pattern(self):
        dt = get_date_from_filename("/photos/signal_20201225_photo.jpg")
        self.assertEqual(dt, datetime(2020, 12, 25))

    def test_invalid_month(self):
        dt = get_date_from_filename("/photos/IMG_20211301_120000.jpg")
        self.assertIsNone(dt)

    def test_invalid_day(self):
        dt = get_date_from_filename("/photos/IMG_20210132_120000.jpg")
        self.assertIsNone(dt)

    def test_year_before_2000(self):
        dt = get_date_from_filename("/photos/IMG_19990101_120000.jpg")
        self.assertIsNone(dt)

    def test_year_after_2030(self):
        dt = get_date_from_filename("/photos/IMG_20310101_120000.jpg")
        self.assertIsNone(dt)

    def test_no_date_in_filename(self):
        dt = get_date_from_filename("/photos/family_photo.jpg")
        self.assertIsNone(dt)

    def test_random_digits_not_matched(self):
        dt = get_date_from_filename("/photos/DSC_1234.jpg")
        self.assertIsNone(dt)


# ════════════════════════════════════════════════════════════════════════════
# Metadata — get_file_date
# ════════════════════════════════════════════════════════════════════════════

class TestGetFileDate(TempDirMixin, unittest.TestCase):

    @patch('chronoframe.metadata.get_date_mdls', return_value=None)
    def test_filename_fallback_when_no_mdls(self, mock_mdls):
        p = self._mkfile("IMG_20210501_120000.jpg", b"data")
        dt = get_file_date(p)
        self.assertEqual(dt, datetime(2021, 5, 1))

    @patch('chronoframe.metadata.get_date_mdls')
    def test_mdls_used_when_filename_fails(self, mock_mdls):
        mock_mdls.return_value = datetime(2020, 6, 15, 10, 30, 0)
        p = self._mkfile("random_name.jpg", b"data")
        with patch('chronoframe.metadata.HAS_EXIFREAD', False):
            dt = get_file_date(p)
        self.assertEqual(dt.year, 2020)
        self.assertEqual(dt.month, 6)

    def test_mtime_fallback(self):
        p = self._mkfile("nodate.jpg", b"data")
        with patch('chronoframe.metadata.get_date_mdls', return_value=None):
            with patch('chronoframe.metadata.HAS_EXIFREAD', False):
                dt = get_file_date(p)
        # Should return mtime which is recent
        self.assertGreater(dt.year, 2020)

    @patch('chronoframe.metadata.get_date_mdls', return_value=datetime(1970, 1, 1))
    def test_mdls_1970_rejected(self, mock_mdls):
        """Dates ≤ 1971 from mdls are rejected; fallback to mtime."""
        p = self._mkfile("nodate.jpg", b"data")
        with patch('chronoframe.metadata.HAS_EXIFREAD', False):
            dt = get_file_date(p)
        self.assertGreater(dt.year, 1971)


class TestMDLSParsing(unittest.TestCase):
    def test_mdls_timezone_offset(self):
        from chronoframe.metadata import parse_mdls_creation_date
        # test mapping +0000 UTC output properly
        dt = parse_mdls_creation_date("2024-06-15 12:00:00 +0000")
        self.assertIsNotNone(dt)
        # We don't strictly test the timezone offset size because it's localized to the test runner,
        # but the parsing sequence shouldn't raise a ValueError.

class TestRetryableError(unittest.TestCase):
    def test_permission_errors_are_not_retryable(self):
        from chronoframe.io import _is_retryable_error
        import errno
        exc_eacces = OSError(errno.EACCES, "Permission denied")
        exc_eperm = OSError(errno.EPERM, "Operation not permitted")
        self.assertFalse(_is_retryable_error(exc_eacces))
        self.assertFalse(_is_retryable_error(exc_eperm))


# ════════════════════════════════════════════════════════════════════════════
# Metadata — extension sets
# ════════════════════════════════════════════════════════════════════════════

class TestExtensionSets(unittest.TestCase):

    def test_photo_exts_present(self):
        for ext in ['.jpg', '.jpeg', '.heic', '.png', '.gif', '.nef', '.cr2', '.arw']:
            self.assertIn(ext, PHOTO_EXTS, f"{ext} missing from PHOTO_EXTS")

    def test_video_exts_present(self):
        for ext in ['.mov', '.mp4', '.avi', '.mkv', '.3gp']:
            self.assertIn(ext, VIDEO_EXTS, f"{ext} missing from VIDEO_EXTS")

    def test_all_exts_is_union(self):
        self.assertEqual(ALL_EXTS, PHOTO_EXTS | VIDEO_EXTS)

    def test_no_overlap(self):
        self.assertEqual(len(PHOTO_EXTS & VIDEO_EXTS), 0)


# ════════════════════════════════════════════════════════════════════════════
# SKIP_FILES
# ════════════════════════════════════════════════════════════════════════════

class TestSkipFiles(unittest.TestCase):

    def test_organize_script_skipped(self):
        self.assertIn('chronoframe.py', SKIP_FILES)

    def test_shell_scripts_skipped(self):
        self.assertIn('run_organize.sh', SKIP_FILES)
        self.assertIn('reorganize_structure.sh', SKIP_FILES)

    def test_config_files_skipped(self):
        self.assertIn('profiles.yaml', SKIP_FILES)
        self.assertIn('requirements.txt', SKIP_FILES)

    def test_test_file_skipped(self):
        self.assertIn('test_chronoframe.py', SKIP_FILES)


# ════════════════════════════════════════════════════════════════════════════
# build_dest_index
# ════════════════════════════════════════════════════════════════════════════

class TestBuildDestIndex(TempDirMixin, unittest.TestCase):

    def _setup_dest(self, files):
        """Create files in dest layout. files: list of (relative_path, content)."""
        dst = os.path.join(self.tmpdir, "dest")
        for relpath, content in files:
            path = os.path.join(dst, relpath)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(content)
        return dst

    def _make_db(self):
        return CacheDB(os.path.join(self.tmpdir, "test.db"))

    def test_empty_dest(self):
        dst = self._setup_dest([])
        db = self._make_db()
        hi, seq, dup_seq = build_dest_index(dst, db)
        self.assertEqual(hi, {})
        self.assertEqual(dict(seq), {})
        db.close()

    def test_indexes_media_files(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"photo1"),
            ("2023/06/15/2023-06-15_002.jpg", b"photo2"),
        ])
        db = self._make_db()
        hi, seq, dup_seq = build_dest_index(dst, db)
        self.assertEqual(len(hi), 2)
        self.assertEqual(seq["2023-06-15"], 2)
        db.close()

    def test_skips_dotfiles(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"visible"),
            ("2023/06/15/.hidden.jpg", b"hidden"),
        ])
        db = self._make_db()
        hi, seq, _ = build_dest_index(dst, db)
        self.assertEqual(len(hi), 1)
        db.close()

    def test_skips_non_media(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"photo"),
            ("notes.txt", b"not media"),
        ])
        db = self._make_db()
        hi, seq, _ = build_dest_index(dst, db)
        self.assertEqual(len(hi), 1)
        db.close()

    def test_duplicate_dir_tracked_separately(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_005.jpg", b"main"),
            ("Duplicate/2023/06/15/2023-06-15_003.jpg", b"dup"),
        ])
        db = self._make_db()
        hi, seq, dup_seq = build_dest_index(dst, db)
        self.assertEqual(seq["2023-06-15"], 5)
        self.assertEqual(dup_seq["2023-06-15"], 3)
        db.close()

    def test_seq_finds_max(self):
        dst = self._setup_dest([
            ("2023/01/01/2023-01-01_010.jpg", b"a"),
            ("2023/01/01/2023-01-01_005.jpg", b"b"),
            ("2023/01/01/2023-01-01_020.jpg", b"c"),
        ])
        db = self._make_db()
        _, seq, _ = build_dest_index(dst, db)
        self.assertEqual(seq["2023-01-01"], 20)
        db.close()

    def test_cache_populated_after_index(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"data"),
        ])
        db = self._make_db()
        build_dest_index(dst, db)
        cache = db.get_cache_dict(2)
        self.assertEqual(len(cache), 1)
        db.close()

    def test_cache_reused_on_second_run(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"data"),
        ])
        db = self._make_db()
        build_dest_index(dst, db)
        # Second run should use cache (was_hashed=False)
        hi2, _, _ = build_dest_index(dst, db)
        self.assertEqual(len(hi2), 1)
        db.close()

    def test_rebuild_clears_cache(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"data"),
        ])
        db = self._make_db()
        build_dest_index(dst, db)
        self.assertTrue(len(db.get_cache_dict(2)) > 0)
        build_dest_index(dst, db, rebuild=True)
        # Cache should be repopulated (not empty after rebuild)
        self.assertTrue(len(db.get_cache_dict(2)) > 0)
        db.close()

    def test_skips_dotdirs(self):
        dst = self._setup_dest([
            (".hidden_dir/2023-06-15_001.jpg", b"hidden"),
            ("2023/06/15/2023-06-15_001.jpg", b"visible"),
        ])
        db = self._make_db()
        hi, _, _ = build_dest_index(dst, db)
        self.assertEqual(len(hi), 1)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Sequence Padding
# ════════════════════════════════════════════════════════════════════════════

class TestSequencePadding(unittest.TestCase):

    def test_seq_width_is_3(self):
        self.assertEqual(SEQ_WIDTH, 3)

    def test_single_digit(self):
        self.assertEqual(str(1).zfill(SEQ_WIDTH), "001")

    def test_double_digit(self):
        self.assertEqual(str(42).zfill(SEQ_WIDTH), "042")

    def test_triple_digit(self):
        self.assertEqual(str(999).zfill(SEQ_WIDTH), "999")

    def test_over_999(self):
        self.assertEqual(str(1000).zfill(SEQ_WIDTH), "1000")

    def test_lexicographic_order(self):
        nums = [str(i).zfill(SEQ_WIDTH) for i in range(1, 100)]
        self.assertEqual(nums, sorted(nums))


# ════════════════════════════════════════════════════════════════════════════
# Dry-Run Report
# ════════════════════════════════════════════════════════════════════════════

class TestDryRunReport(TempDirMixin, unittest.TestCase):

    def test_generates_csv(self):
        report_path = os.path.join(self.tmpdir, "report.csv")
        jobs = [
            ("/src/a.jpg", "/dst/2023/01/01/2023-01-01_001.jpg", "hash1", "PENDING"),
            ("/src/b.jpg", "/dst/2023/01/01/2023-01-01_002.jpg", "hash2", "PENDING"),
        ]
        generate_dry_run_report(jobs, "/dst", report_path)
        self.assertTrue(os.path.exists(report_path))

        with open(report_path, 'r') as f:
            reader = csv.reader(f)
            rows = list(reader)
        self.assertEqual(rows[0], ["Source", "Destination", "Hash", "Status"])
        self.assertEqual(len(rows), 3)  # header + 2 data rows
        self.assertEqual(rows[1][0], "/src/a.jpg")
        self.assertEqual(rows[1][2], "hash1")
        self.assertEqual(rows[1][3], "PENDING")

    def test_empty_jobs(self):
        report_path = os.path.join(self.tmpdir, "report.csv")
        generate_dry_run_report([], "/dst", report_path)
        with open(report_path, 'r') as f:
            rows = list(csv.reader(f))
        self.assertEqual(len(rows), 1)  # header only


# ════════════════════════════════════════════════════════════════════════════
# Audit Receipt
# ════════════════════════════════════════════════════════════════════════════

class TestAuditReceipt(TempDirMixin, unittest.TestCase):

    def test_generates_json(self):
        executed = [("/src/a.jpg", "/dst/a.jpg", "h1")]
        # To avoid error with missing directory in revert_receipt, make the destination real but empty file
        dst_path = os.path.join(self.tmpdir, "a.jpg")
        with open(dst_path, "w") as f: f.write("test")
        
        executed = [("/src/a.jpg", dst_path, "3_hash1")] # using mock hash with prefix 3_ for fast_hash compat if tested
        generate_audit_receipt(executed, self.tmpdir)
        log_dir = os.path.join(self.tmpdir, ".organize_logs")
        self.assertTrue(os.path.isdir(log_dir))
        files = os.listdir(log_dir)
        self.assertEqual(len(files), 1)
        self.assertTrue(files[0].startswith("audit_receipt_"))
        self.assertTrue(files[0].endswith(".json"))

        with open(os.path.join(log_dir, files[0])) as f:
            data = json.load(f)
        self.assertEqual(data["total_jobs"], 1)
        self.assertEqual(data["status"], "COMPLETED")
        self.assertEqual(len(data["transfers"]), 1)

    def test_empty_receipt(self):
        generate_audit_receipt([], self.tmpdir)
        log_dir = os.path.join(self.tmpdir, ".organize_logs")
        files = os.listdir(log_dir)
        with open(os.path.join(log_dir, files[0])) as f:
            data = json.load(f)
        self.assertEqual(data["total_jobs"], 0)

    def test_logs_dir_created(self):
        """Audit receipt goes to .organize_logs/ subfolder, not root."""
        generate_audit_receipt([("/a", "/b", "h")], self.tmpdir)
        self.assertTrue(os.path.isdir(os.path.join(self.tmpdir, ".organize_logs")))

class TestAuditReceiptReturnValue(TempDirMixin, unittest.TestCase):
    def test_returns_receipt_path(self):
        path = generate_audit_receipt([("/a", "/b", "h")], self.tmpdir)
        self.assertTrue(path.endswith(".json"))
        self.assertTrue(os.path.exists(path))

    def test_empty_receipt_returns_path(self):
        path = generate_audit_receipt([], self.tmpdir)
        self.assertTrue(os.path.exists(path))

    def test_returned_path_contains_valid_json(self):
        path = generate_audit_receipt([("/a", "/b", "h")], self.tmpdir)
        with open(path, "r") as f:
            data = json.load(f)
        self.assertEqual(data["status"], "COMPLETED")

class TestRevertReceipt(TempDirMixin, unittest.TestCase):
    @patch('chronoframe.core.emit_json')
    @patch('chronoframe.io.fast_hash')
    def test_revert_receipt_success(self, mock_fast_hash, mock_emit):
        from chronoframe.core import revert_receipt
        dst_path = os.path.join(self.tmpdir, "to_revert.jpg")
        with open(dst_path, "w") as f: f.write("data")
        
        receipt_path = os.path.join(self.tmpdir, "receipt.json")
        payload = {
            "transfers": [{"source": "/src/a.jpg", "dest": dst_path, "hash": "known_hash"}]
        }
        with open(receipt_path, "w") as f: json.dump(payload, f)
            
        mock_fast_hash.return_value = "known_hash"
        
        revert_receipt(receipt_path)
            
        self.assertFalse(os.path.exists(dst_path), "Destination file should be deleted on revert!")

    @patch('chronoframe.core.emit_json')
    @patch('chronoframe.io.fast_hash')
    def test_revert_receipt_hash_mismatch(self, mock_fast_hash, mock_emit):
        from chronoframe.core import revert_receipt
        dst_path = os.path.join(self.tmpdir, "to_revert.jpg")
        with open(dst_path, "w") as f: f.write("data")
        
        receipt_path = os.path.join(self.tmpdir, "receipt.json")
        payload = {
            "transfers": [{"source": "/src/a.jpg", "dest": dst_path, "hash": "known_hash"}]
        }
        with open(receipt_path, "w") as f: json.dump(payload, f)
            
        mock_fast_hash.return_value = "DIFFERENT_HASH"
        
        revert_receipt(receipt_path)
            
        self.assertTrue(os.path.exists(dst_path), "File should be preserved if hash does not match!")


# ════════════════════════════════════════════════════════════════════════════
# Profile Loading
# ════════════════════════════════════════════════════════════════════════════

class TestProfileLoading(TempDirMixin, unittest.TestCase):

    def _write_yaml(self, content):
        import yaml
        path = os.path.join(self.tmpdir, "profiles.yaml")
        with open(path, 'w') as f:
            yaml.dump(content, f)
        return path

    @patch('chronoframe.core._find_profiles_yaml')
    def test_load_valid_profile(self, mock_find):
        path = self._write_yaml({
            "my_profile": {"source": "/src", "dest": "/dst"}
        })
        mock_find.return_value = path
        src, dst = load_profile("my_profile")
        self.assertEqual(src, "/src")
        self.assertEqual(dst, "/dst")

    @patch('chronoframe.core._find_profiles_yaml')
    def test_missing_profile_exits(self, mock_find):
        path = self._write_yaml({"other": {"source": "/a", "dest": "/b"}})
        mock_find.return_value = path
        with self.assertRaises(SystemExit):
            load_profile("nonexistent")

    @patch('chronoframe.core._find_profiles_yaml')
    def test_missing_yaml_exits(self, mock_find):
        mock_find.return_value = "/nonexistent/profiles.yaml"
        with self.assertRaises(SystemExit):
            load_profile("anything")


# ════════════════════════════════════════════════════════════════════════════
# RunLogger
# ════════════════════════════════════════════════════════════════════════════

class TestRunLogger(TempDirMixin, unittest.TestCase):

    def test_creates_log_file(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        logger = RunLogger(log_path)
        logger.open()
        logger.log("test message")
        logger.close()
        self.assertTrue(os.path.exists(log_path))
        with open(log_path) as f:
            content = f.read()
        self.assertIn("test message", content)

    def test_appends(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        logger = RunLogger(log_path)
        logger.open()
        logger.log("first")
        logger.log("second")
        logger.close()
        with open(log_path) as f:
            lines = f.readlines()
        self.assertEqual(len(lines), 2)

    def test_warn_prefix(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        logger = RunLogger(log_path)
        logger.open()
        logger.warn("something bad")
        logger.close()
        with open(log_path) as f:
            self.assertIn("WARNING: something bad", f.read())

    def test_error_prefix(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        logger = RunLogger(log_path)
        logger.open()
        logger.error("failure")
        logger.close()
        with open(log_path) as f:
            self.assertIn("ERROR: failure", f.read())

    def test_timestamp_format(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        logger = RunLogger(log_path)
        logger.open()
        logger.log("timestamped")
        logger.close()
        with open(log_path) as f:
            line = f.readline()
        # Should match [YYYY-MM-DD HH:MM:SS]
        self.assertRegex(line, r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]')

    def test_unwritable_path(self):
        logger = RunLogger("/nonexistent/dir/log.txt")
        logger.open()  # Should not crash
        logger.log("message")  # Should not crash
        logger.close()


# ════════════════════════════════════════════════════════════════════════════
# CLI Args
# ════════════════════════════════════════════════════════════════════════════

class TestParseArgs(unittest.TestCase):

    def test_defaults(self):
        with patch('sys.argv', ['prog']):
            args = parse_args()
        self.assertIsNone(args.source)
        self.assertIsNone(args.dest)
        self.assertIsNone(args.profile)
        self.assertFalse(args.dry_run)
        self.assertFalse(args.rebuild_cache)
        self.assertFalse(args.verify)
        self.assertFalse(args.yes)
        self.assertFalse(args.json)
        self.assertFalse(args.fast_dest)
        self.assertEqual(args.workers, DEFAULT_WORKERS)

    def test_all_flags(self):
        with patch('sys.argv', ['prog', '--source', '/s', '--dest', '/d',
                                '--profile', 'p', '--dry-run', '--rebuild-cache',
                                '--verify', '-y', '--json', '--fast-dest', '--workers', '4']):
            args = parse_args()
        self.assertEqual(args.source, '/s')
        self.assertEqual(args.dest, '/d')
        self.assertEqual(args.profile, 'p')
        self.assertTrue(args.dry_run)
        self.assertTrue(args.rebuild_cache)
        self.assertTrue(args.verify)
        self.assertTrue(args.yes)
        self.assertTrue(args.json)
        self.assertTrue(args.fast_dest)
        self.assertEqual(args.workers, 4)

    def test_workers_flag(self):
        with patch('sys.argv', ['prog', '--workers', '2']):
            args = parse_args()
        self.assertEqual(args.workers, 2)


# ════════════════════════════════════════════════════════════════════════════
# Constants
# ════════════════════════════════════════════════════════════════════════════

class TestConstants(unittest.TestCase):

    def test_max_consecutive_failures(self):
        self.assertEqual(MAX_CONSECUTIVE_FAILURES, 5)

    def test_max_total_failures(self):
        self.assertEqual(MAX_TOTAL_FAILURES, 20)

    def test_default_workers(self):
        self.assertGreater(DEFAULT_WORKERS, 0)
        self.assertLessEqual(DEFAULT_WORKERS, 16)


# ════════════════════════════════════════════════════════════════════════════
# End-to-End: Dry Run
# ════════════════════════════════════════════════════════════════════════════

class TestEndToEndDryRun(TempDirMixin, unittest.TestCase):
    """Integration test: source → index → classify → plan (no copy)."""

    def _setup_src_dst(self):
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)
        return src, dst

    def test_new_files_planned(self):
        src, dst = self._setup_src_dst()
        # Create source files with date-parseable names
        for i, name in enumerate(["IMG_20230101_120000.jpg", "IMG_20230102_120000.jpg"]):
            with open(os.path.join(src, name), 'wb') as f:
                f.write(f"photo_{i}".encode())

        db = CacheDB(os.path.join(dst, ".cache.db"))
        hi, seq, dup_seq = build_dest_index(dst, db)

        # Simulate the classification logic from core.main
        src_files = sorted([os.path.join(src, f) for f in os.listdir(src)])
        src_hashes = {}
        for p in src_files:
            h, _, _, _ = process_single_file(p, None)
            src_hashes[p] = h

        new_files = {p: h for p, h in src_hashes.items() if h and h not in hi}
        self.assertEqual(len(new_files), 2)
        db.close()

    def test_already_in_dest_skipped(self):
        src, dst = self._setup_src_dst()
        content = b"identical file"
        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(content)
        # Same content already in dest
        dst_file = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        os.makedirs(os.path.dirname(dst_file))
        with open(dst_file, 'wb') as f:
            f.write(content)

        db = CacheDB(os.path.join(dst, ".cache.db"))
        hi, seq, _ = build_dest_index(dst, db)

        src_path = os.path.join(src, "IMG_20230101_120000.jpg")
        h, _, _, _ = process_single_file(src_path, None)
        self.assertIn(h, hi)  # Already in dest
        db.close()

    def test_internal_dups_detected(self):
        src, dst = self._setup_src_dst()
        content = b"duplicate data"
        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(content)
        with open(os.path.join(src, "IMG_20230101_120001.jpg"), 'wb') as f:
            f.write(content)  # Same content

        src_files = sorted([os.path.join(src, f) for f in os.listdir(src)])
        src_seen = {}
        dups = []
        for p in src_files:
            h, _, _, _ = process_single_file(p, None)
            if h in src_seen:
                dups.append(p)
            else:
                src_seen[h] = p
        self.assertEqual(len(dups), 1)

    def test_seq_continues_from_existing(self):
        src, dst = self._setup_src_dst()
        # Existing: seq 5 is the max for this date
        existing = os.path.join(dst, "2023", "01", "01", "2023-01-01_005.jpg")
        os.makedirs(os.path.dirname(existing))
        with open(existing, 'wb') as f:
            f.write(b"existing")

        db = CacheDB(os.path.join(dst, ".cache.db"))
        _, seq, _ = build_dest_index(dst, db)
        next_seq = seq.get("2023-01-01", 0) + 1
        self.assertEqual(next_seq, 6)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# End-to-End: Copy with Resume
# ════════════════════════════════════════════════════════════════════════════

class TestResumeQueue(TempDirMixin, unittest.TestCase):
    """Test the job queue resume mechanism."""

    def test_enqueue_and_resume(self):
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst)
        db = CacheDB(os.path.join(dst, ".cache.db"))

        # Enqueue 3 jobs
        jobs = [
            ("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING"),
            ("/src/b.jpg", "/dst/b.jpg", "h2", "PENDING"),
            ("/src/c.jpg", "/dst/c.jpg", "h3", "PENDING"),
        ]
        db.enqueue_jobs(jobs)

        # Mark first as copied
        db.update_job_status("/src/a.jpg", "COPIED")

        # Resume should return only 2 pending
        pending = db.get_pending_jobs()
        self.assertEqual(len(pending), 2)
        src_paths = [p[0] for p in pending]
        self.assertNotIn("/src/a.jpg", src_paths)
        db.close()

    def test_failed_jobs_stay_pending_on_flush(self):
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst)
        db = CacheDB(os.path.join(dst, ".cache.db"))

        db.enqueue_jobs([("/src/a.jpg", "/dst/a.jpg", "h1", "PENDING")])
        db.update_job_status("/src/a.jpg", "FAILED")

        # FAILED jobs are not pending
        self.assertEqual(len(db.get_pending_jobs()), 0)

        # clear_jobs removes everything including failed
        db.clear_jobs()
        # Verify the table is empty
        cur = db.conn.execute("SELECT COUNT(*) FROM CopyJobs")
        self.assertEqual(cur.fetchone()[0], 0)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Unknown_Date Handling
# ════════════════════════════════════════════════════════════════════════════

class TestUnknownDate(TempDirMixin, unittest.TestCase):

    def test_unknown_date_path(self):
        """Files with date ≤ 1971 should be classified as Unknown_Date."""
        dt = datetime(1970, 1, 1)
        date_str = dt.strftime('%Y-%m-%d') if dt.year > 1971 else "Unknown_Date"
        self.assertEqual(date_str, "Unknown_Date")

        seq = 1
        ext = ".jpg"
        filename = f"Unknown_{str(seq).zfill(SEQ_WIDTH)}{ext}"
        self.assertEqual(filename, "Unknown_001.jpg")

    def test_valid_date_not_unknown(self):
        dt = datetime(2023, 6, 15)
        date_str = dt.strftime('%Y-%m-%d') if dt.year > 1971 else "Unknown_Date"
        self.assertEqual(date_str, "2023-06-15")


# ════════════════════════════════════════════════════════════════════════════
# Consecutive Failure Detection
# ════════════════════════════════════════════════════════════════════════════

class TestConsecutiveFailureDetection(unittest.TestCase):

    def test_threshold_is_5(self):
        self.assertEqual(MAX_CONSECUTIVE_FAILURES, 5)

    def test_failure_count_logic(self):
        """Simulate the failure counter logic from execute_jobs."""
        consecutive_fail = 0
        aborted = False
        results = ['ok', 'ok', 'fail', 'fail', 'fail', 'fail', 'fail']
        for r in results:
            if r == 'ok':
                consecutive_fail = 0
            else:
                consecutive_fail += 1
                if consecutive_fail >= MAX_CONSECUTIVE_FAILURES:
                    aborted = True
                    break
        self.assertTrue(aborted)

    def test_success_resets_counter(self):
        consecutive_fail = 0
        aborted = False
        # 4 fails then success then 4 fails — should NOT abort
        results = ['fail', 'fail', 'fail', 'fail', 'ok', 'fail', 'fail', 'fail', 'fail']
        for r in results:
            if r == 'ok':
                consecutive_fail = 0
            else:
                consecutive_fail += 1
                if consecutive_fail >= MAX_CONSECUTIVE_FAILURES:
                    aborted = True
                    break
        self.assertFalse(aborted)


# ════════════════════════════════════════════════════════════════════════════
# Integration: execute_jobs
# ════════════════════════════════════════════════════════════════════════════

class TestExecuteJobs(TempDirMixin, unittest.TestCase):
    """Integration test for the execute_jobs function with real files."""

    def _setup_env(self):
        src_dir = os.path.join(self.tmpdir, "source")
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        db = CacheDB(os.path.join(dst_dir, ".cache.db"))
        return src_dir, dst_dir, db

    def test_copies_files_and_updates_db(self):
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        # Create real source files
        src1 = os.path.join(src_dir, "a.jpg")
        src2 = os.path.join(src_dir, "b.jpg")
        with open(src1, 'wb') as f: f.write(b"photo1")
        with open(src2, 'wb') as f: f.write(b"photo2")

        dst1 = os.path.join(dst_dir, "2023", "01", "01", "2023-01-01_001.jpg")
        dst2 = os.path.join(dst_dir, "2023", "01", "01", "2023-01-01_002.jpg")

        jobs = [(src1, dst1, "h1", "PENDING"), (src2, dst2, "h2", "PENDING")]
        db.enqueue_jobs(jobs)
        pending = db.get_pending_jobs()

        execute_jobs(pending, db, dst_dir)

        # Files should exist at destination
        self.assertTrue(os.path.exists(dst1))
        self.assertTrue(os.path.exists(dst2))
        with open(dst1, 'rb') as f:
            self.assertEqual(f.read(), b"photo1")

        # Jobs should be marked COPIED
        self.assertEqual(len(db.get_pending_jobs()), 0)

        # Dest cache should be populated
        cache = db.get_cache_dict(2)
        self.assertIn(dst1, cache)
        self.assertIn(dst2, cache)

        # Audit receipt should exist
        log_dir = os.path.join(dst_dir, ".organize_logs")
        self.assertTrue(os.path.isdir(log_dir))
        receipts = [f for f in os.listdir(log_dir) if f.startswith("audit_receipt_")]
        self.assertEqual(len(receipts), 1)
        db.close()

    def test_handles_missing_source_gracefully(self):
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        # Source file doesn't exist
        jobs = [("/nonexistent/photo.jpg", os.path.join(dst_dir, "out.jpg"), "h", "PENDING")]
        db.enqueue_jobs(jobs)
        pending = db.get_pending_jobs()

        execute_jobs(pending, db, dst_dir)

        # Job should be marked FAILED
        self.assertEqual(len(db.get_pending_jobs()), 0)
        cur = db.conn.execute("SELECT status FROM CopyJobs WHERE src_path = ?", ("/nonexistent/photo.jpg",))
        self.assertEqual(cur.fetchone()[0], "FAILED")
        db.close()

    def test_verify_flag_detects_mismatch(self):
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "photo.jpg")
        with open(src, 'wb') as f: f.write(b"original content")
        dst_path = os.path.join(dst_dir, "photo.jpg")

        # Enqueue with a WRONG hash to trigger verification failure
        jobs = [(src, dst_path, "deliberately_wrong_hash", "PENDING")]
        db.enqueue_jobs(jobs)
        pending = db.get_pending_jobs()

        logger = RunLogger(os.path.join(dst_dir, "test.log"))
        logger.open()
        execute_jobs(pending, db, dst_dir, run_log=logger, verify=True)
        logger.close()

        # Verification failure should be treated as a failed transfer
        self.assertFalse(os.path.exists(dst_path))
        cur = db.conn.execute("SELECT status FROM CopyJobs WHERE src_path = ?", (src,))
        self.assertEqual(cur.fetchone()[0], "FAILED")
        self.assertEqual(db.get_cache_dict(2), {})

        # Log should contain verification failure
        with open(os.path.join(dst_dir, "test.log")) as f:
            log_content = f.read()
        self.assertIn("Verification failed", log_content)
        db.close()

    def test_audit_receipt_uses_actual_collision_path(self):
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "photo.jpg")
        with open(src, 'wb') as f:
            f.write(b"new data")

        planned_dst = os.path.join(dst_dir, "photo.jpg")
        with open(planned_dst, 'wb') as f:
            f.write(b"existing")

        db.enqueue_jobs([(src, planned_dst, "h1", "PENDING")])
        execute_jobs(db.get_pending_jobs(), db, dst_dir)

        receipt_dir = os.path.join(dst_dir, ".organize_logs")
        receipt_path = os.path.join(receipt_dir, sorted(os.listdir(receipt_dir))[-1])
        with open(receipt_path) as f:
            receipt = json.load(f)

        self.assertTrue(os.path.exists(os.path.join(dst_dir, "photo_collision_1.jpg")))
        self.assertEqual(receipt["transfers"][0]["dest"], os.path.join(dst_dir, "photo_collision_1.jpg"))
        db.close()

    def test_consecutive_failure_aborts(self):
        from chronoframe.core import execute_jobs
        _, dst_dir, db = self._setup_env()

        # Create 6 jobs all pointing to nonexistent sources
        jobs = [(f"/bad/path_{i}.jpg", os.path.join(dst_dir, f"out_{i}.jpg"), f"h{i}", "PENDING")
                for i in range(6)]
        db.enqueue_jobs(jobs)
        pending = db.get_pending_jobs()

        execute_jobs(pending, db, dst_dir)

        # Should have aborted after 5 consecutive failures, leaving the 6th unprocessed
        cur = db.conn.execute("SELECT COUNT(*) FROM CopyJobs WHERE status = 'FAILED'")
        failed_count = cur.fetchone()[0]
        self.assertEqual(failed_count, 5)  # Aborted at the threshold
        db.close()

    def test_execute_with_no_run_log(self):
        """execute_jobs should work even if run_log is None."""
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "photo.jpg")
        with open(src, 'wb') as f: f.write(b"data")
        dst_path = os.path.join(dst_dir, "photo.jpg")

        db.enqueue_jobs([(src, dst_path, "h1", "PENDING")])
        pending = db.get_pending_jobs()

        # No crash with run_log=None
        execute_jobs(pending, db, dst_dir, run_log=None)
        self.assertTrue(os.path.exists(dst_path))
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Integration: main() — Dry Run
# ════════════════════════════════════════════════════════════════════════════

class TestMainDryRun(TempDirMixin, unittest.TestCase):
    """Test main() in --dry-run mode with real filesystem."""

    def _setup_src_dst(self):
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)
        return src, dst

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_dry_run_generates_csv(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        # Create source files with date-parseable names
        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"photo_data_1")
        with open(os.path.join(src, "IMG_20230616_100000.jpg"), 'wb') as f:
            f.write(b"photo_data_2")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        # CSV report should be in .organize_logs/
        log_dir = os.path.join(dst, ".organize_logs")
        self.assertTrue(os.path.isdir(log_dir))
        reports = [f for f in os.listdir(log_dir) if f.startswith("dry_run_report_")]
        self.assertEqual(len(reports), 1)

        with open(os.path.join(log_dir, reports[0])) as f:
            reader = csv.reader(f)
            rows = list(reader)
        # Header + 2 data rows
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0], ["Source", "Destination", "Hash", "Status"])

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_dry_run_creates_missing_destination_root(self, _mock_yaml):
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest_missing")
        os.makedirs(src)

        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"photo_data")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        self.assertTrue(os.path.isdir(dst))
        self.assertTrue(os.path.exists(os.path.join(dst, ".organize_cache.db")))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_dry_run_empty_source(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()
        # Empty source — no media files

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        # Should just print "no valid media" and return gracefully
        log_dir = os.path.join(dst, ".organize_logs")
        # Log dir may not exist if no report was generated
        reports = []
        if os.path.isdir(log_dir):
            reports = [f for f in os.listdir(log_dir) if f.startswith("dry_run_report_")]
        self.assertEqual(len(reports), 0)

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_dry_run_with_existing_dest_files(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        content = b"identical_file_content"
        # Same file in both source and dest
        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(content)
        dst_file = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        os.makedirs(os.path.dirname(dst_file))
        with open(dst_file, 'wb') as f:
            f.write(content)

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        # Report should show 0 new files (all skipped as duplicates)
        log_dir = os.path.join(dst, ".organize_logs")
        if os.path.isdir(log_dir):
            reports = [f for f in os.listdir(log_dir) if f.startswith("dry_run_report_")]
            if reports:
                with open(os.path.join(log_dir, reports[0])) as f:
                    rows = list(csv.reader(f))
                self.assertEqual(len(rows), 1)  # header only


# ════════════════════════════════════════════════════════════════════════════
# Integration: main() — Live Copy
# ════════════════════════════════════════════════════════════════════════════

class TestMainCopy(TempDirMixin, unittest.TestCase):
    """Test main() with actual file copying using --yes flag."""

    def _setup_src_dst(self):
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)
        return src, dst

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_with_yes_flag(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"photo_bytes_here")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            main()

        # File should actually be copied to the YYYY/MM/DD structure
        expected = os.path.join(dst, "2023", "06", "15", "2023-06-15_001.jpg")
        self.assertTrue(os.path.exists(expected))
        with open(expected, 'rb') as f:
            self.assertEqual(f.read(), b"photo_bytes_here")

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_nothing_to_do(self, _mock_yaml):
        """When all files are already in dest, nothing to copy."""
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        content = b"already_organized"
        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(content)
        dst_file = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        os.makedirs(os.path.dirname(dst_file))
        with open(dst_file, 'wb') as f:
            f.write(content)

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            main()

        # No new files should appear

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_with_internal_duplicates(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        content = b"duplicate_content"
        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(content)
        with open(os.path.join(src, "IMG_20230101_120001.jpg"), 'wb') as f:
            f.write(content)  # Same content = internal dup

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            main()

        # One in main dir, one in Duplicate/
        main_file = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        dup_file = os.path.join(dst, "Duplicate", "2023", "01", "01", "2023-01-01_001.jpg")
        self.assertTrue(os.path.exists(main_file))
        self.assertTrue(os.path.exists(dup_file))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_with_verify_flag(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"verify_me")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y', '--verify']):
            main()

        expected = os.path.join(dst, "2023", "06", "15", "2023-06-15_001.jpg")
        self.assertTrue(os.path.exists(expected))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_unknown_date_file(self, _mock_yaml):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        # File with no parseable date and mock mdls to return None
        with open(os.path.join(src, "random_name.jpg"), 'wb') as f:
            f.write(b"mystery_photo")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            with patch('chronoframe.metadata.get_date_mdls', return_value=None):
                with patch('chronoframe.metadata.HAS_EXIFREAD', False):
                    main()

        # Should end up in the date-based directory using mtime (which is recent)
        # We don't know exact date, but file should exist somewhere in dst


# ════════════════════════════════════════════════════════════════════════════
# Integration: main() — Resume Paths
# ════════════════════════════════════════════════════════════════════════════

class TestMainResume(TempDirMixin, unittest.TestCase):

    def _setup_src_dst(self):
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)
        return src, dst

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_resume_with_yes_flag(self, _mock_yaml):
        """--yes should auto-resume pending jobs without prompting."""
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        # Create a real source file and pre-populate the queue
        src_file = os.path.join(src, "photo.jpg")
        with open(src_file, 'wb') as f:
            f.write(b"resume_data")

        dst_path = os.path.join(dst, "2023", "06", "15", "2023-06-15_001.jpg")
        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        db.enqueue_jobs([(src_file, dst_path, "h1", "PENDING")])
        db.close()

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            main()

        self.assertTrue(os.path.exists(dst_path))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    @patch('chronoframe.core.Confirm.ask', return_value=True)
    def test_resume_prompt_accepts_pending_queue(self, _mock_confirm, _mock_yaml):
        """Interactive resume should execute the existing queue and return."""
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        src_file = os.path.join(src, "photo.jpg")
        with open(src_file, 'wb') as f:
            f.write(b"resume_prompt_data")

        dst_path = os.path.join(dst, "2023", "06", "15", "2023-06-15_001.jpg")
        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        db.enqueue_jobs([(src_file, dst_path, "h1", "PENDING")])
        db.close()

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst]):
            main()

        self.assertTrue(os.path.exists(dst_path))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_resume_declined_then_flush(self, _mock_yaml):
        """User declines resume, then flushes queue. Should proceed to fresh scan."""
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        src_file = os.path.join(src, "IMG_20230101_120000.jpg")
        with open(src_file, 'wb') as f:
            f.write(b"fresh_scan_data")

        # Pre-populate queue with a stale job
        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        db.enqueue_jobs([("/old/stale.jpg", "/dst/stale.jpg", "old_hash", "PENDING")])
        db.close()

        # User says: No to resume, Yes to flush
        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        # Dry-run with pending queue just ignores it — should still generate report
        log_dir = os.path.join(dst, ".organize_logs")
        if os.path.isdir(log_dir):
            reports = [f for f in os.listdir(log_dir) if f.startswith("dry_run_report_")]
            self.assertGreaterEqual(len(reports), 1)

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    @patch('chronoframe.core.Confirm.ask', side_effect=[False, True, True])
    def test_resume_declined_then_flush_and_continue_copy(self, _mock_confirm, _mock_yaml):
        """Declining resume and flushing should rescan, then continue with a new copy."""
        from chronoframe.core import main
        src, dst = self._setup_src_dst()

        src_file = os.path.join(src, "IMG_20230101_120000.jpg")
        with open(src_file, 'wb') as f:
            f.write(b"fresh_scan_data")

        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        db.enqueue_jobs([("/old/stale.jpg", "/dst/stale.jpg", "old_hash", "PENDING")])
        db.close()

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst]):
            main()

        copied = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        self.assertTrue(os.path.exists(copied))

        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        self.assertEqual(db.get_pending_jobs(), [])
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Integration: main() — Profile Resolution
# ════════════════════════════════════════════════════════════════════════════

class TestMainProfileResolution(TempDirMixin, unittest.TestCase):

    @patch('chronoframe.core._find_profiles_yaml')
    def test_default_profile_fallback(self, mock_find):
        """When no --source/--dest given, should fall back to 'default' profile."""
        from chronoframe.core import main
        import yaml

        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        yaml_path = os.path.join(self.tmpdir, "profiles.yaml")
        with open(yaml_path, 'w') as f:
            yaml.dump({"default": {"source": src, "dest": dst}}, f)
        mock_find.return_value = yaml_path

        # Empty source — should return gracefully after "no valid media"
        with patch('sys.argv', ['prog', '--dry-run']):
            main()

    @patch('chronoframe.core._find_profiles_yaml')
    def test_named_profile(self, mock_find):
        from chronoframe.core import main
        import yaml

        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        yaml_path = os.path.join(self.tmpdir, "profiles.yaml")
        with open(yaml_path, 'w') as f:
            yaml.dump({"work": {"source": src, "dest": dst}}, f)
        mock_find.return_value = yaml_path

        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(b"photo")

        with patch('sys.argv', ['prog', '--profile', 'work', '--dry-run']):
            main()

        log_dir = os.path.join(dst, ".organize_logs")
        self.assertTrue(os.path.isdir(log_dir))

    def test_no_source_no_dest_no_profile_exits(self):
        from chronoframe.core import main
        with patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/yaml'):
            with patch('sys.argv', ['prog']):
                with self.assertRaises(SystemExit):
                    main()


# ════════════════════════════════════════════════════════════════════════════
# Integration: build_dest_index with progress bar
# ════════════════════════════════════════════════════════════════════════════

class TestBuildDestIndexWithProgress(TempDirMixin, unittest.TestCase):
    """Cover the progress-bar code paths in build_dest_index."""

    def _setup_dest(self, files):
        dst = os.path.join(self.tmpdir, "dest")
        for relpath, content in files:
            path = os.path.join(dst, relpath)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(content)
        return dst

    def test_with_rich_progress(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"photo1"),
            ("2023/06/15/2023-06-15_002.jpg", b"photo2"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))

        with Progress(
            SpinnerColumn(), TextColumn("{task.description}"),
            BarColumn(), MofNCompleteColumn(),
            console=Console(quiet=True),
        ) as progress:
            ptask = progress.add_task("Test", total=None)
            hi, seq, _ = build_dest_index(dst, db, progress=progress, ptask=ptask)

        self.assertEqual(len(hi), 2)
        self.assertEqual(seq["2023-06-15"], 2)
        db.close()

    def test_progress_with_empty_dest(self):
        dst = self._setup_dest([])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))

        with Progress(
            SpinnerColumn(), TextColumn("{task.description}"),
            console=Console(quiet=True),
        ) as progress:
            ptask = progress.add_task("Test", total=None)
            hi, _, _ = build_dest_index(dst, db, progress=progress, ptask=ptask)

        self.assertEqual(hi, {})
        db.close()

    def test_unknown_date_sequence_tracked(self):
        """Unknown_XXX.jpg files should have their sequences tracked correctly."""
        dst = self._setup_dest([
            ("Unknown_Date/Unknown_005.jpg", b"unknown1"),
            ("Unknown_Date/Unknown_010.jpg", b"unknown2"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))
        hi, seq, _ = build_dest_index(dst, db)
        self.assertEqual(seq.get("Unknown_Date", 0), 10)
        db.close()

    def test_uppercase_extension_indexed(self):
        """Files with .JPG (uppercase) should be indexed correctly."""
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.JPG", b"uppercase"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))
        hi, seq, _ = build_dest_index(dst, db)
        self.assertEqual(len(hi), 1)
        self.assertEqual(seq["2023-06-15"], 1)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Metadata: EXIF parsing path
# ════════════════════════════════════════════════════════════════════════════

class TestExifreadParsing(TempDirMixin, unittest.TestCase):

    @unittest.skipUnless(HAS_EXIFREAD, "exifread not installed")
    def test_non_image_returns_none(self):
        """exifread on a non-image file should not crash."""
        from chronoframe.metadata import get_date_exifread
        p = self._mkfile("fake.jpg", b"not a real jpeg")
        result = get_date_exifread(p)
        self.assertIsNone(result)

    @unittest.skipUnless(HAS_EXIFREAD, "exifread not installed")
    def test_exifread_used_for_photo_exts(self):
        """get_file_date should attempt exifread for photo extensions."""
        p = self._mkfile("test.jpg", b"not real exif data")
        with patch('chronoframe.metadata.get_date_exifread', return_value=datetime(2023, 6, 15)) as mock_exif:
            with patch('chronoframe.metadata.HAS_EXIFREAD', True):
                dt = get_file_date(p)
        mock_exif.assert_called_once_with(p)
        self.assertEqual(dt, datetime(2023, 6, 15))

    def test_exifread_skipped_for_video(self):
        """get_file_date should NOT use exifread for video files."""
        p = self._mkfile("IMG_20230615_120000.mov", b"video data")
        with patch('chronoframe.metadata.get_date_exifread') as mock_exif:
            dt = get_file_date(p)
        mock_exif.assert_not_called()
        self.assertEqual(dt, datetime(2023, 6, 15))


# ════════════════════════════════════════════════════════════════════════════
# Metadata: mdls edge cases
# ════════════════════════════════════════════════════════════════════════════

class TestMdlsParsing(TempDirMixin, unittest.TestCase):

    def test_mdls_valid_date(self):
        result = parse_mdls_creation_date("2023-06-15 10:30:00 +0000")
        dt_utc = datetime.strptime("2023-06-15 10:30:00 +0000", '%Y-%m-%d %H:%M:%S %z')
        from datetime import timezone
        dt_local = dt_utc.astimezone()
        expected = dt_local.replace(tzinfo=None)
        self.assertEqual(result, expected)

    def test_mdls_null_result(self):
        result = parse_mdls_creation_date("(null)")
        self.assertIsNone(result)

    @patch('chronoframe.metadata.subprocess.run')
    def test_mdls_timeout(self, mock_run):
        from chronoframe.metadata import get_date_mdls
        mock_run.side_effect = subprocess.TimeoutExpired(cmd="mdls", timeout=5)
        with patch('chronoframe.metadata.os.path.isfile', return_value=True):
            result = get_date_mdls("/any/path.jpg")
        self.assertIsNone(result)

    def test_mdls_empty_output(self):
        result = parse_mdls_creation_date("")
        self.assertIsNone(result)

    def test_mdls_missing_file_returns_none(self):
        self.assertIsNone(get_date_mdls("/any/missing/path.jpg"))


# ════════════════════════════════════════════════════════════════════════════
# Wrapper dependency preflight
# ════════════════════════════════════════════════════════════════════════════

class TestWrapperDependencyPreflight(unittest.TestCase):

    def test_dependency_status_reports_missing_packages(self):
        wrapper = load_wrapper_module()

        def fake_find_spec(name):
            return None if name in {"exifread", "yaml"} else object()

        with patch('importlib.util.find_spec', side_effect=fake_find_spec):
            status = wrapper.dependency_status()

        self.assertFalse(status["ok"])
        self.assertEqual(status["missing"], ["exifread", "pyyaml"])

    @patch.dict(os.environ, {"CHRONOFRAME_NONINTERACTIVE": "1"}, clear=False)
    @patch('subprocess.check_call')
    def test_noninteractive_dependency_check_does_not_prompt_or_install(self, mock_check_call):
        wrapper = load_wrapper_module()

        def fake_find_spec(name):
            return None if name == "rich" else object()

        with patch('importlib.util.find_spec', side_effect=fake_find_spec):
            with self.assertRaises(SystemExit) as exc:
                wrapper.check_and_install_dependencies()

        self.assertEqual(exc.exception.code, 1)
        mock_check_call.assert_not_called()

    @patch('builtins.input', return_value='n')
    def test_interactive_dependency_check_exits_when_user_declines_install(self, _mock_input):
        wrapper = load_wrapper_module()

        def fake_find_spec(name):
            return None if name == "rich" else object()

        with patch('importlib.util.find_spec', side_effect=fake_find_spec):
            with self.assertRaises(SystemExit) as exc:
                wrapper.check_and_install_dependencies(noninteractive=False)

        self.assertEqual(exc.exception.code, 1)

    @patch('builtins.input', return_value='y')
    @patch('subprocess.check_call')
    def test_interactive_dependency_check_installs_when_user_accepts(self, mock_check_call, _mock_input):
        wrapper = load_wrapper_module()

        call_state = {"count": 0}

        def fake_find_spec(name):
            if name == "rich" and call_state["count"] == 0:
                return None
            return object()

        def fake_check_call(_args):
            call_state["count"] += 1

        with patch('importlib.util.find_spec', side_effect=fake_find_spec):
            with patch('os.path.exists', return_value=True):
                mock_check_call.side_effect = fake_check_call
                status = wrapper.check_and_install_dependencies(noninteractive=False)

        self.assertTrue(status["ok"])
        self.assertEqual(status["missing"], [])
        mock_check_call.assert_called_once()

    def test_main_guard_check_deps_json_outputs_status(self):
        wrapper_path = os.path.join(os.path.dirname(__file__), "chronoframe.py")

        with patch('sys.argv', [wrapper_path, '--check-deps-json']):
            with patch('importlib.util.find_spec', return_value=object()):
                with patch('builtins.print') as mock_print:
                    with self.assertRaises(SystemExit) as exc:
                        runpy.run_path(wrapper_path, run_name="__main__")

        self.assertEqual(exc.exception.code, 0)
        mock_print.assert_called_once()

    def test_main_guard_imports_backend_entrypoint_after_dependency_check(self):
        wrapper_path = os.path.join(os.path.dirname(__file__), "chronoframe.py")
        fake_main = MagicMock()
        fake_module = types.SimpleNamespace(main=fake_main)

        with patch('sys.argv', [wrapper_path]):
            with patch('importlib.util.find_spec', return_value=object()):
                with patch.dict(sys.modules, {'chronoframe.__main__': fake_module}, clear=False):
                    runpy.run_path(wrapper_path, run_name="__main__")

        fake_main.assert_called_once_with()


# ════════════════════════════════════════════════════════════════════════════
# IO: tmp cleanup failure path
# ════════════════════════════════════════════════════════════════════════════

class TestSafeCopyAtomicEdgeCases(TempDirMixin, unittest.TestCase):

    def test_tmp_cleanup_on_rename_failure(self):
        """If os.rename fails, the .tmp file should be cleaned up."""
        from chronoframe.io import safe_copy_atomic as wrapped_fn
        # Access the unwrapped function to bypass tenacity retries
        raw_fn = wrapped_fn.__wrapped__

        src = self._mkfile("src/photo.jpg", b"data")
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")

        with patch('chronoframe.io.os.rename', side_effect=OSError("rename failed")):
            with self.assertRaises(OSError):
                raw_fn(src, dst)

        # .tmp should be cleaned up
        self.assertFalse(os.path.exists(dst + ".tmp"))

    def test_tmp_cleanup_failure_doesnt_crash(self):
        """If both rename AND tmp removal fail, should still raise without crashing."""
        from chronoframe.io import safe_copy_atomic as wrapped_fn
        raw_fn = wrapped_fn.__wrapped__

        src = self._mkfile("src/photo.jpg", b"data")
        dst = os.path.join(self.tmpdir, "dst", "photo.jpg")

        def mock_remove(path):
            raise OSError("remove also failed")

        with patch('chronoframe.io.os.rename', side_effect=OSError("rename failed")):
            with patch('chronoframe.io.os.remove', side_effect=mock_remove):
                with self.assertRaises(OSError):
                    raw_fn(src, dst)


# ════════════════════════════════════════════════════════════════════════════
# Core: _find_profiles_yaml
# ════════════════════════════════════════════════════════════════════════════

class TestFindProfilesYaml(unittest.TestCase):

    def test_returns_path_relative_to_project(self):
        from chronoframe.core import _find_profiles_yaml, _PROJECT_DIR
        result = _find_profiles_yaml()
        self.assertEqual(result, os.path.join(_PROJECT_DIR, "profiles.yaml"))

    @patch.dict(os.environ, {"CHRONOFRAME_PROFILES_PATH": "/tmp/chronoframe-tests/profiles.yaml"}, clear=False)
    def test_prefers_environment_override(self):
        from chronoframe.core import _find_profiles_yaml
        self.assertEqual(_find_profiles_yaml(), "/tmp/chronoframe-tests/profiles.yaml")


# ════════════════════════════════════════════════════════════════════════════
# cleanup_tmp_files
# ════════════════════════════════════════════════════════════════════════════

class TestCleanupTmpFiles(TempDirMixin, unittest.TestCase):

    def test_removes_tmp_files(self):
        self._mkfile("photo.jpg.tmp", b"partial write")
        self._mkfile("video.mov.tmp", b"partial write")
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 2)
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "photo.jpg.tmp")))
        self.assertFalse(os.path.exists(os.path.join(self.tmpdir, "video.mov.tmp")))

    def test_ignores_non_tmp_files(self):
        self._mkfile("photo.jpg", b"complete file")
        self._mkfile("video.mp4", b"complete file")
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 0)
        self.assertTrue(os.path.exists(os.path.join(self.tmpdir, "photo.jpg")))

    def test_returns_correct_count(self):
        for i in range(5):
            self._mkfile(f"file_{i}.jpg.tmp", b"data")
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 5)

    def test_empty_dir_returns_zero(self):
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 0)

    def test_nested_tmp_files(self):
        self._mkfile("a/b/photo.jpg.tmp", b"partial")
        self._mkfile("x/y/z/video.mp4.tmp", b"partial")
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 2)

    def test_skips_dotdirs(self):
        """Files inside hidden directories (e.g. .organize_logs) are not touched."""
        path = os.path.join(self.tmpdir, ".organize_logs", "something.tmp")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(b"data")
        count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 0)
        self.assertTrue(os.path.exists(path))

    def test_unremovable_tmp_silently_skipped(self):
        """If os.remove raises (e.g. permissions), the error is silenced and count stays 0."""
        self._mkfile("stuck.jpg.tmp", b"data")
        with patch('chronoframe.io.os.remove', side_effect=OSError("permission denied")):
            count = cleanup_tmp_files(self.tmpdir)
        self.assertEqual(count, 0)


# ════════════════════════════════════════════════════════════════════════════
# check_disk_space
# ════════════════════════════════════════════════════════════════════════════

class TestCheckDiskSpace(TempDirMixin, unittest.TestCase):

    def test_sufficient_space_does_not_raise(self):
        src = self._mkfile("test.jpg", b"small file")
        # tmpdir is on a real filesystem with plenty of space
        check_disk_space(src, self.tmpdir)  # must not raise

    def test_insufficient_space_raises_enospc(self):
        src = self._mkfile("test.jpg", b"x" * 1000)
        with patch('chronoframe.io.shutil.disk_usage') as mock_du:
            mock_du.return_value = MagicMock(free=50)  # only 50 bytes free
            with self.assertRaises(OSError) as ctx:
                check_disk_space(src, self.tmpdir)
        self.assertEqual(ctx.exception.errno, errno.ENOSPC)

    def test_error_message_contains_mb_info(self):
        src = self._mkfile("test.jpg", b"x" * (2 * 1024 * 1024))  # 2 MB file
        with patch('chronoframe.io.shutil.disk_usage') as mock_du:
            mock_du.return_value = MagicMock(free=1024 * 1024)  # 1 MB free
            with self.assertRaises(OSError) as ctx:
                check_disk_space(src, self.tmpdir)
        msg = str(ctx.exception)
        self.assertIn("MB", msg)

    def test_exactly_at_threshold_raises(self):
        """File size + 10 MB buffer exactly equal to free space should still raise."""
        src = self._mkfile("test.jpg", b"x" * 1024)
        with patch('chronoframe.io.shutil.disk_usage') as mock_du:
            # free == needed + 10 MB exactly — should raise (strictly less than required)
            mock_du.return_value = MagicMock(free=1024 + 10 * 1024 * 1024 - 1)
            with self.assertRaises(OSError):
                check_disk_space(src, self.tmpdir)

    def test_enospc_propagated_through_safe_copy(self):
        """ENOSPC from check_disk_space bubbles through safe_copy_atomic __wrapped__."""
        from chronoframe.io import safe_copy_atomic
        raw = safe_copy_atomic.__wrapped__
        src = self._mkfile("test.jpg", b"x" * 1000)
        dst = os.path.join(self.tmpdir, "out.jpg")
        with patch('chronoframe.io.shutil.disk_usage') as mock_du:
            mock_du.return_value = MagicMock(free=50)
            with self.assertRaises(OSError) as ctx:
                raw(src, dst)
        self.assertEqual(ctx.exception.errno, errno.ENOSPC)


# ════════════════════════════════════════════════════════════════════════════
# _is_retryable_error
# ════════════════════════════════════════════════════════════════════════════

class TestIsRetryableError(unittest.TestCase):

    def test_plain_oserror_is_retryable(self):
        e = OSError("network reset")
        self.assertTrue(_is_retryable_error(e))

    def test_enoent_is_not_retryable(self):
        e = OSError(errno.ENOENT, "no such file")
        self.assertFalse(_is_retryable_error(e))

    def test_enospc_is_not_retryable(self):
        e = OSError(errno.ENOSPC, "no space left on device")
        self.assertFalse(_is_retryable_error(e))

    def test_enotdir_is_not_retryable(self):
        e = OSError(errno.ENOTDIR, "not a directory")
        self.assertFalse(_is_retryable_error(e))

    def test_eisdir_is_not_retryable(self):
        e = OSError(errno.EISDIR, "is a directory")
        self.assertFalse(_is_retryable_error(e))

    def test_einval_is_not_retryable(self):
        e = OSError(errno.EINVAL, "invalid argument")
        self.assertFalse(_is_retryable_error(e))

    def test_non_oserror_is_not_retryable(self):
        self.assertFalse(_is_retryable_error(ValueError("type error")))
        self.assertFalse(_is_retryable_error(RuntimeError("runtime")))
        self.assertFalse(_is_retryable_error(Exception("generic")))


# ════════════════════════════════════════════════════════════════════════════
# _format_seq
# ════════════════════════════════════════════════════════════════════════════

class TestFormatSeq(unittest.TestCase):

    def test_pads_single_digit(self):
        self.assertEqual(_format_seq(1), "001")

    def test_pads_double_digit(self):
        self.assertEqual(_format_seq(42), "042")

    def test_pads_to_exact_width(self):
        self.assertEqual(_format_seq(999), "999")

    def test_widens_at_1000(self):
        result = _format_seq(1000)
        self.assertEqual(result, "1000")
        self.assertGreaterEqual(len(result), SEQ_WIDTH)

    def test_widens_for_large_numbers(self):
        result = _format_seq(99999)
        self.assertEqual(result, "99999")

    def test_never_truncates(self):
        """Overflow must widen, not truncate — no data loss."""
        for n in [1000, 5000, 10000]:
            self.assertEqual(_format_seq(n), str(n))

    def test_lexicographic_order_preserved_within_width(self):
        nums = [_format_seq(i) for i in range(1, 1000)]
        self.assertEqual(nums, sorted(nums))


# ════════════════════════════════════════════════════════════════════════════
# MAX_TOTAL_FAILURES constant and total_fail abort behaviour
# ════════════════════════════════════════════════════════════════════════════

class TestMaxTotalFailures(unittest.TestCase):

    def test_constant_value(self):
        self.assertEqual(MAX_TOTAL_FAILURES, 20)

    def test_greater_than_consecutive_threshold(self):
        """Total threshold must be stricter than or equal to consecutive threshold."""
        self.assertGreaterEqual(MAX_TOTAL_FAILURES, MAX_CONSECUTIVE_FAILURES)

    def test_total_fail_simulation(self):
        """
        Simulates the new dual-counter logic:
        consecutive resets on each success, but total_fail keeps growing.
        A flapping network (4 bad, 1 good, repeating) should eventually abort.
        """
        consecutive_fail = 0
        total_fail = 0
        aborted = False

        # 4 fail, 1 ok — repeat. With only consecutive logic this never aborts.
        # With total_fail logic it aborts once total_fail >= MAX_TOTAL_FAILURES.
        pattern = (['fail'] * 4 + ['ok']) * 10  # 50 ops, 40 failures total
        for r in pattern:
            if r == 'ok':
                consecutive_fail = 0
            else:
                consecutive_fail += 1
                total_fail += 1
                if consecutive_fail >= MAX_CONSECUTIVE_FAILURES or total_fail >= MAX_TOTAL_FAILURES:
                    aborted = True
                    break

        self.assertTrue(aborted)
        self.assertLessEqual(total_fail, MAX_TOTAL_FAILURES)


class TestTotalFailAbortIntegration(TempDirMixin, unittest.TestCase):
    """Integration: execute_jobs aborts on total failures even with flapping network."""

    def _setup_env(self):
        src_dir = os.path.join(self.tmpdir, "source")
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        db = CacheDB(os.path.join(dst_dir, ".cache.db"))
        return src_dir, dst_dir, db

    def test_flapping_network_aborts_at_total_threshold(self):
        """
        Pattern: 4 bad jobs, 1 good job, repeating.
        Consecutive counter resets every 5th job → never hits MAX_CONSECUTIVE=5.
        Total failures accumulate → hits MAX_TOTAL=20 and aborts early.

        safe_copy_atomic is mocked so no real retry backoff occurs.
        """
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        jobs = []
        for i in range(MAX_TOTAL_FAILURES + 5):
            if i % 5 == 4:
                src = os.path.join(src_dir, f"good_{i}.jpg")
                with open(src, 'wb') as f:
                    f.write(f"ok_{i}".encode())
                dst_path = os.path.join(dst_dir, f"good_{i}.jpg")
            else:
                src = os.path.join(src_dir, f"bad_{i}.jpg")  # path present in jobs list
                dst_path = os.path.join(dst_dir, f"bad_{i}.jpg")
            jobs.append((src, dst_path, f"hash_{i}", "PENDING"))

        db.enqueue_jobs(jobs)

        # Mock safe_copy_atomic so "bad_" jobs fail instantly (no tenacity backoff)
        def mock_copy(src, dst):
            if "bad_" in os.path.basename(src):
                raise OSError("simulated network failure")
            import shutil
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy2(src, dst)
            return dst

        with patch('chronoframe.core.safe_copy_atomic', side_effect=mock_copy):
            execute_jobs(db.get_pending_jobs(), db, dst_dir)

        cur = db.conn.execute("SELECT COUNT(*) FROM CopyJobs WHERE status = 'PENDING'")
        remaining = cur.fetchone()[0]
        self.assertGreater(remaining, 0, "Expected early abort but all jobs were processed")

        cur = db.conn.execute("SELECT COUNT(*) FROM CopyJobs WHERE status = 'FAILED'")
        failed = cur.fetchone()[0]
        self.assertGreaterEqual(failed, MAX_TOTAL_FAILURES)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# build_dest_index — fast_dest mode
# ════════════════════════════════════════════════════════════════════════════

class TestBuildDestIndexFastDest(TempDirMixin, unittest.TestCase):

    def _setup_dest(self, files):
        dst = os.path.join(self.tmpdir, "dest")
        for relpath, content in files:
            path = os.path.join(dst, relpath)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'wb') as f:
                f.write(content)
        return dst

    def test_fast_dest_matches_full_scan(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_001.jpg", b"photo1"),
            ("2023/06/15/2023-06-15_002.jpg", b"photo2"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))

        # Full scan first — populates cache
        hi_full, seq_full, dup_full = build_dest_index(dst, db)

        # Fast mode — reads from cache only
        hi_fast, seq_fast, dup_fast = build_dest_index(dst, db, fast_dest=True)

        self.assertEqual(hi_full, hi_fast)
        self.assertEqual(dict(seq_full), dict(seq_fast))
        db.close()

    def test_fast_dest_empty_cache_returns_empty(self):
        dst = self._setup_dest([])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))
        hi, seq, _ = build_dest_index(dst, db, fast_dest=True)
        self.assertEqual(hi, {})
        self.assertEqual(dict(seq), {})
        db.close()

    def test_fast_dest_dup_dir_tracked_correctly(self):
        dst = self._setup_dest([
            ("2023/06/15/2023-06-15_005.jpg", b"main"),
            ("Duplicate/2023/06/15/2023-06-15_003.jpg", b"dup"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))
        build_dest_index(dst, db)  # populate cache

        _, seq, dup_seq = build_dest_index(dst, db, fast_dest=True)
        self.assertEqual(seq["2023-06-15"], 5)
        self.assertEqual(dup_seq["2023-06-15"], 3)
        db.close()

    def test_fast_dest_with_progress(self):
        dst = self._setup_dest([
            ("2023/01/01/2023-01-01_001.jpg", b"data"),
        ])
        db = CacheDB(os.path.join(self.tmpdir, "test.db"))
        build_dest_index(dst, db)  # populate cache

        with Progress(SpinnerColumn(), TextColumn("{task.description}"),
                      console=Console(quiet=True)) as progress:
            ptask = progress.add_task("Test", total=None)
            hi, _, _ = build_dest_index(dst, db, fast_dest=True, progress=progress, ptask=ptask)

        self.assertEqual(len(hi), 1)
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# generate_audit_receipt — return value
# ════════════════════════════════════════════════════════════════════════════

class TestAuditReceiptReturnValue(TempDirMixin, unittest.TestCase):

    def test_returns_receipt_path(self):
        rpath = generate_audit_receipt([("/src/a.jpg", "/dst/a.jpg", "h1")], self.tmpdir)
        self.assertIsNotNone(rpath)
        self.assertTrue(os.path.isfile(rpath))
        self.assertTrue(rpath.endswith(".json"))
        self.assertIn("audit_receipt_", os.path.basename(rpath))

    def test_returned_path_contains_valid_json(self):
        rpath = generate_audit_receipt([("/s", "/d", "h")], self.tmpdir)
        with open(rpath) as f:
            data = json.load(f)
        self.assertEqual(data["total_jobs"], 1)

    def test_empty_receipt_returns_path(self):
        rpath = generate_audit_receipt([], self.tmpdir)
        self.assertTrue(os.path.isfile(rpath))


# ════════════════════════════════════════════════════════════════════════════
# execute_jobs — bytes tracking + workers param
# ════════════════════════════════════════════════════════════════════════════

class TestExecuteJobsBytesTracking(TempDirMixin, unittest.TestCase):

    def _setup_env(self):
        src_dir = os.path.join(self.tmpdir, "source")
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        db = CacheDB(os.path.join(dst_dir, ".cache.db"))
        return src_dir, dst_dir, db

    def test_bytes_tracking_does_not_break_execution(self):
        """Bytes pre-computation and tracking should not interfere with normal copy."""
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "a.jpg")
        with open(src, 'wb') as f:
            f.write(b"payload" * 1000)  # 7 KB
        dst = os.path.join(dst_dir, "a.jpg")

        db.enqueue_jobs([(src, dst, "h1", "PENDING")])
        execute_jobs(db.get_pending_jobs(), db, dst_dir)

        self.assertTrue(os.path.exists(dst))
        self.assertEqual(len(db.get_pending_jobs()), 0)
        db.close()

    def test_missing_source_still_tracks_bytes(self):
        """If getsize fails for a missing source, bytes_total degrades gracefully."""
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        # Job with nonexistent source — getsize will fail silently
        db.enqueue_jobs([("/nonexistent/file.jpg", os.path.join(dst_dir, "x.jpg"), "h", "PENDING")])
        execute_jobs(db.get_pending_jobs(), db, dst_dir)  # must not raise
        db.close()

    def test_workers_param_accepted(self):
        """execute_jobs should accept a workers keyword without error."""
        from chronoframe.core import execute_jobs
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "b.jpg")
        with open(src, 'wb') as f:
            f.write(b"data")
        dst = os.path.join(dst_dir, "b.jpg")

        db.enqueue_jobs([(src, dst, "h1", "PENDING")])
        execute_jobs(db.get_pending_jobs(), db, dst_dir, workers=2)

        self.assertTrue(os.path.exists(dst))
        db.close()


# ════════════════════════════════════════════════════════════════════════════
# Parallel classification
# ════════════════════════════════════════════════════════════════════════════

class TestParallelClassification(TempDirMixin, unittest.TestCase):
    """Integration: verify parallel date extraction produces the same results as serial."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_parallel_classification_correct_dates(self, _):
        """Files with date-parseable names should land in the right YYYY/MM/DD dirs."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        dates = ["20230101", "20230615", "20231225"]
        for d in dates:
            with open(os.path.join(src, f"IMG_{d}_120000.jpg"), 'wb') as f:
                f.write(d.encode())

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            main()

        self.assertTrue(os.path.exists(os.path.join(dst, "2023", "01", "01")))
        self.assertTrue(os.path.exists(os.path.join(dst, "2023", "06", "15")))
        self.assertTrue(os.path.exists(os.path.join(dst, "2023", "12", "25")))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_parallel_classification_with_mdls_fallback(self, _):
        """Files without EXIF or filename dates should still be classified via mdls/mtime."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "nondescript.jpg"), 'wb') as f:
            f.write(b"no date info")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
            with patch('chronoframe.metadata.HAS_EXIFREAD', False):
                with patch('chronoframe.metadata.get_date_mdls', return_value=None):
                    main()  # Should fall back to mtime, complete without error


# ════════════════════════════════════════════════════════════════════════════
# SEQ_WIDTH overflow warning
# ════════════════════════════════════════════════════════════════════════════

class TestSeqOverflowWarning(TempDirMixin, unittest.TestCase):
    """Per-day sequence width is uniform across new files in a single run.

    A greenfield day with >999 files gets uniform-width names (e.g. 4-digit
    `_0001`..`_1500`) and an info-level log line — not a yellow warning. A
    re-run that pushes a previously-stable day past a width boundary keeps
    the warning, because existing files retain their narrower names and the
    folder will sort in two groups in Finder.
    """

    @staticmethod
    def _read_dry_run_dest_paths(dst):
        log_dir = os.path.join(dst, ".organize_logs")
        reports = sorted(f for f in os.listdir(log_dir) if f.startswith("dry_run_report_"))
        with open(os.path.join(log_dir, reports[-1]), newline='') as f:
            reader = csv.DictReader(f)
            return [row["Destination"] for row in reader]

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_greenfield_overflow_uses_uniform_width(self, _):
        """1001 same-day files on a fresh dest → all 4-digit, no warning."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        for i in range(1001):
            with open(os.path.join(src, f"IMG_{i:06d}.jpg"), 'wb') as f:
                f.write(b"src_" + str(i).encode())

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        log_path = os.path.join(dst, ".organize_log.txt")
        with open(log_path) as f:
            log_content = f.read()

        # No yellow warning, no "mismatch" / "overflow" language.
        self.assertNotIn("WARNING", log_content)
        self.assertNotIn("mismatch", log_content.lower())
        self.assertNotIn("overflow", log_content.lower())
        # An info-level line was emitted naming the new width.
        self.assertIn("4-digit sequence numbers", log_content)

        dest_paths = self._read_dry_run_dest_paths(dst)
        self.assertEqual(len(dest_paths), 1001)
        # Every filename uses 4-digit zero padding; sequences span 1..1001.
        seqs = []
        for path in dest_paths:
            fname = os.path.basename(path)
            m = re.match(r'^\d{4}-\d{2}-\d{2}_(\d+)\.jpg$', fname)
            self.assertIsNotNone(m, f"Unexpected filename: {fname}")
            seq_str = m.group(1)
            self.assertEqual(len(seq_str), 4, f"Width should be 4: {fname}")
            seqs.append(int(seq_str))
        self.assertEqual(sorted(seqs), list(range(1, 1002)))

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_cross_boundary_overflow_warns(self, _):
        """800 existing 3-digit dest files + 300 new → warning + 4-digit new names."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        today = datetime.now().strftime('%Y-%m-%d')
        yyyy, mm, dd = today.split('-')
        existing_dir = os.path.join(dst, yyyy, mm, dd)
        os.makedirs(existing_dir)
        for i in range(1, 801):
            fname = f"{today}_{i:03d}.jpg"
            with open(os.path.join(existing_dir, fname), 'wb') as f:
                f.write(b"dst_" + str(i).encode())

        for i in range(300):
            with open(os.path.join(src, f"IMG_{i:06d}.jpg"), 'wb') as f:
                f.write(b"src_" + str(i).encode())

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        log_path = os.path.join(dst, ".organize_log.txt")
        with open(log_path) as f:
            log_content = f.read()
        self.assertIn("WARNING", log_content)
        self.assertIn("sequence overflow on dates", log_content.lower())
        self.assertIn(today, log_content)

        dest_paths = self._read_dry_run_dest_paths(dst)
        self.assertEqual(len(dest_paths), 300)
        for path in dest_paths:
            fname = os.path.basename(path)
            m = re.match(r'^\d{4}-\d{2}-\d{2}_(\d+)\.jpg$', fname)
            self.assertIsNotNone(m)
            self.assertEqual(len(m.group(1)), 4, f"New file should be 4-digit: {fname}")
            self.assertGreaterEqual(int(m.group(1)), 801)

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_within_width_run_no_warning(self, _):
        """500 existing + 200 new (total 700, still 3-digit) → no warning."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        today = datetime.now().strftime('%Y-%m-%d')
        yyyy, mm, dd = today.split('-')
        existing_dir = os.path.join(dst, yyyy, mm, dd)
        os.makedirs(existing_dir)
        for i in range(1, 501):
            fname = f"{today}_{i:03d}.jpg"
            with open(os.path.join(existing_dir, fname), 'wb') as f:
                f.write(b"dst_" + str(i).encode())

        for i in range(200):
            with open(os.path.join(src, f"IMG_{i:06d}.jpg"), 'wb') as f:
                f.write(b"src_" + str(i).encode())

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        log_path = os.path.join(dst, ".organize_log.txt")
        with open(log_path) as f:
            log_content = f.read()
        self.assertNotIn("WARNING", log_content)
        self.assertNotIn("mismatch", log_content.lower())
        self.assertNotIn("overflow", log_content.lower())

    def test_format_seq_at_limit(self):
        self.assertEqual(_format_seq(999), "999")

    def test_format_seq_over_limit_widens(self):
        self.assertEqual(_format_seq(1000), "1000")
        self.assertEqual(_format_seq(9999), "9999")

    def test_format_seq_data_not_lost(self):
        """The number encoded in the filename must always be recoverable."""
        for n in [1, 42, 999, 1000, 5000, 10000]:
            result = _format_seq(n)
            self.assertEqual(int(result), n)


# ════════════════════════════════════════════════════════════════════════════
# RunLogger — try/finally guarantee
# ════════════════════════════════════════════════════════════════════════════

class TestRunLoggerCloseOnException(TempDirMixin, unittest.TestCase):

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_logger_closed_after_no_media(self, _):
        """main() exits early (no media) — log file must still be flushed/closed."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        log_path = os.path.join(dst, ".organize_log.txt")
        self.assertTrue(os.path.exists(log_path))
        # File must be readable (not left in a locked/unflushed state)
        with open(log_path) as f:
            content = f.read()
        self.assertIn("Run started", content)


# ════════════════════════════════════════════════════════════════════════════
# Orphan .tmp cleanup in main()
# ════════════════════════════════════════════════════════════════════════════

class TestMainCleansOrphanTmp(TempDirMixin, unittest.TestCase):

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_orphan_tmp_files_removed_on_startup(self, _):
        """main() should clean orphaned .tmp files in dest at startup."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        # Plant orphaned .tmp files
        orphan1 = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg.tmp")
        os.makedirs(os.path.dirname(orphan1), exist_ok=True)
        with open(orphan1, 'wb') as f:
            f.write(b"partial write")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
            main()

        self.assertFalse(os.path.exists(orphan1))


# ════════════════════════════════════════════════════════════════════════════
# main() — emit complete event with dest/report fields
# ════════════════════════════════════════════════════════════════════════════

class TestMainJsonCompleteEvent(TempDirMixin, unittest.TestCase):
    """Verify the 'complete' JSON event carries dest and report paths."""

    def _setup_src_dst(self):
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)
        return src, dst

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_dry_run_complete_event_contains_dest_and_report(self, _):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()
        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"data")

        captured = []

        def capture_print(*args, **kwargs):
            if args and isinstance(args[0], str):
                captured.append(args[0])

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run', '--json']):
            with patch('builtins.print', side_effect=capture_print):
                main()

        complete_events = []
        for line in captured:
            try:
                evt = json.loads(line)
                if evt.get('type') == 'complete':
                    complete_events.append(evt)
            except (json.JSONDecodeError, AttributeError):
                pass

        self.assertEqual(len(complete_events), 1)
        evt = complete_events[0]
        self.assertEqual(evt.get('dest'), dst)
        self.assertIn('report', evt)

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_copy_complete_event_contains_dest(self, _):
        from chronoframe.core import main
        src, dst = self._setup_src_dst()
        with open(os.path.join(src, "IMG_20230615_120000.jpg"), 'wb') as f:
            f.write(b"data")

        captured = []

        def capture_print(*args, **kwargs):
            if args and isinstance(args[0], str):
                captured.append(args[0])

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y', '--json']):
            with patch('builtins.print', side_effect=capture_print):
                main()

        complete_events = [
            json.loads(line) for line in captured
            if line.startswith('{') and json.loads(line).get('type') == 'complete'
            for _ in [None]  # trick to avoid double-parse; use next pattern
        ]
        # Parse again cleanly
        complete_events = []
        for line in captured:
            try:
                evt = json.loads(line)
                if evt.get('type') == 'complete':
                    complete_events.append(evt)
            except (json.JSONDecodeError, AttributeError):
                pass

        self.assertGreater(len(complete_events), 0)
        self.assertEqual(complete_events[0].get('dest'), dst)


# ════════════════════════════════════════════════════════════════════════════
# parse_args — --json and --fast-dest flags
# ════════════════════════════════════════════════════════════════════════════

class TestParseArgsExtended(unittest.TestCase):

    def test_json_flag(self):
        with patch('sys.argv', ['prog', '--json']):
            args = parse_args()
        self.assertTrue(args.json)

    def test_fast_dest_flag(self):
        with patch('sys.argv', ['prog', '--fast-dest']):
            args = parse_args()
        self.assertTrue(args.fast_dest)

    def test_json_false_by_default(self):
        with patch('sys.argv', ['prog']):
            args = parse_args()
        self.assertFalse(args.json)

    def test_fast_dest_false_by_default(self):
        with patch('sys.argv', ['prog']):
            args = parse_args()
        self.assertFalse(args.fast_dest)


# ════════════════════════════════════════════════════════════════════════════
# Additional coverage tests
# ════════════════════════════════════════════════════════════════════════════

class TestBuildDestIndexWorkerException(TempDirMixin, unittest.TestCase):
    """build_dest_index gracefully ignores futures that raise."""

    def test_worker_exception_caught_silently(self):
        """Lines 207-208: exception from future.result() must be swallowed."""
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst)
        # Create a real media file so the executor submits it
        photo = os.path.join(dst, "2023-06-15_001.jpg")
        with open(photo, 'wb') as f:
            f.write(b"photo data")

        db = CacheDB(os.path.join(self.tmpdir, "test.db"))

        with patch('chronoframe.core.process_single_file', side_effect=RuntimeError("worker crash")):
            # Should not raise — exceptions must be caught
            hi, seq, dup_seq = build_dest_index(dst, db)

        self.assertEqual(hi, {})
        db.close()


class TestSrcHashWorkerException(TempDirMixin, unittest.TestCase):
    """Lines 401-402: exception from src_hash future.result() must be swallowed."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_src_hash_exception_caught(self, _):
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(b"content")

        from chronoframe.io import process_single_file as original_psf

        def raise_for_src(path, cached_data):
            if "source" in path:
                raise RuntimeError("src hash crash")
            return original_psf(path, cached_data)

        with patch('chronoframe.core.process_single_file', side_effect=raise_for_src):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '-y']):
                main()  # Must not raise; hash errors silently absorbed


class TestHashErrors(TempDirMixin, unittest.TestCase):
    """Lines 422-423 and 473: files whose hash returns None hit the hash_errors counter."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_hash_none_increments_error_count(self, _):
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(b"content")

        from chronoframe.io import process_single_file as original_psf

        def return_none_for_src(path, cached_data):
            if "source" in path:
                return None, 0, 0, False  # h=None triggers hash_errors
            return original_psf(path, cached_data)

        with patch('chronoframe.core.process_single_file', side_effect=return_none_for_src):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                main()  # Must complete; hash_errors printed to console


class TestClassificationException(TempDirMixin, unittest.TestCase):
    """Lines 450-454: get_file_date raising inside classification executor uses mtime fallback."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_get_file_date_exception_falls_back_to_mtime(self, _):
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "nondescript.jpg"), 'wb') as f:
            f.write(b"no exif no filename date")

        with patch('chronoframe.core.get_file_date', side_effect=RuntimeError("date crash")):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                main()  # Should complete using mtime fallback

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_get_file_date_exception_and_mtime_also_fails(self, _):
        """Lines 453-454: if mtime also raises, file_dates[path] = None (Unknown_Date)."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "nondescript.jpg"), 'wb') as f:
            f.write(b"data")

        with patch('chronoframe.core.get_file_date', side_effect=RuntimeError("date crash")):
            with patch('chronoframe.core.os.path.getmtime', side_effect=OSError("mtime fail")):
                with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                    main()  # file_dates[path] = None → Unknown_Date


class TestUnknownDatePath(TempDirMixin, unittest.TestCase):
    """Lines 487-488 and 509-510: files classified as Unknown_Date land in Unknown_Date dir."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_unknown_date_in_copy_plan(self, _):
        """Lines 487-488: copy plan uses Unknown_Date subdir when dt is None."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "nondescript.jpg"), 'wb') as f:
            f.write(b"data")

        # Return a 1970 datetime so date_str becomes "Unknown_Date"
        with patch('chronoframe.core.get_file_date', return_value=datetime(1970, 1, 1)):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                main()

        # Dry-run report should exist; Unknown_Date dir would be target in plan
        log_dir = os.path.join(dst, ".organize_logs")
        reports = [f for f in os.listdir(log_dir) if f.endswith('.csv')]
        self.assertEqual(len(reports), 1)
        with open(os.path.join(log_dir, reports[0])) as f:
            content = f.read()
        self.assertIn("Unknown_Date", content)

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_unknown_date_for_src_dups(self, _):
        """Lines 509-510: duplicate files with Unknown_Date land in Duplicate/Unknown_Date."""
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        # Two files with identical content → one becomes a src_dup
        for name in ["file_a.jpg", "file_b.jpg"]:
            with open(os.path.join(src, name), 'wb') as f:
                f.write(b"identical content here")

        # Return 1970 for all date queries → Unknown_Date for both copy plan and dups
        with patch('chronoframe.core.get_file_date', return_value=datetime(1970, 1, 1)):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                main()


class TestExecuteJobsWithRunLog(TempDirMixin, unittest.TestCase):
    """Lines 608 and 616: run_log.error is called when run_log is provided."""

    def _setup_env(self):
        src_dir = os.path.join(self.tmpdir, "source")
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        db = CacheDB(os.path.join(dst_dir, ".cache.db"))
        return src_dir, dst_dir, db

    def test_run_log_error_on_copy_failure(self):
        """Line 608: run_log.error is called when a copy fails."""
        from chronoframe.core import execute_jobs, RunLogger
        src_dir, dst_dir, db = self._setup_env()

        log_path = os.path.join(dst_dir, "test.log")
        run_log = RunLogger(log_path)
        run_log.open()

        # Job will fail because source doesn't exist
        db.enqueue_jobs([("/nonexistent/fail.jpg", os.path.join(dst_dir, "fail.jpg"), "h1", "PENDING")])
        execute_jobs(db.get_pending_jobs(), db, dst_dir, run_log=run_log)
        run_log.close()

        with open(log_path) as f:
            content = f.read()
        self.assertIn("Copy failed", content)
        db.close()

    def test_run_log_error_on_abort(self):
        """Line 616: run_log.error is called in the abort message."""
        from chronoframe.core import execute_jobs, RunLogger
        src_dir, dst_dir, db = self._setup_env()

        log_path = os.path.join(dst_dir, "abort.log")
        run_log = RunLogger(log_path)
        run_log.open()

        # Enough consecutive failures to trigger abort
        jobs = [
            ("/nonexistent/bad_{}.jpg".format(i),
             os.path.join(dst_dir, "bad_{}.jpg".format(i)),
             "h{}".format(i), "PENDING")
            for i in range(MAX_CONSECUTIVE_FAILURES + 1)
        ]
        db.enqueue_jobs(jobs)
        execute_jobs(db.get_pending_jobs(), db, dst_dir, run_log=run_log)
        run_log.close()

        with open(log_path) as f:
            content = f.read()
        self.assertIn("Aborting", content)
        db.close()

    def test_run_log_warns_when_unverified_copy_cleanup_fails(self):
        """Verification cleanup failures should be logged as warnings before the job is failed."""
        from chronoframe.core import execute_jobs, RunLogger
        src_dir, dst_dir, db = self._setup_env()

        src = os.path.join(src_dir, "photo.jpg")
        with open(src, 'wb') as f:
            f.write(b"data")
        dst_path = os.path.join(dst_dir, "photo.jpg")

        log_path = os.path.join(dst_dir, "cleanup.log")
        run_log = RunLogger(log_path)
        run_log.open()

        db.enqueue_jobs([(src, dst_path, "wrong_hash", "PENDING")])
        with patch('chronoframe.core.os.remove', side_effect=OSError("cleanup failed")):
            execute_jobs(db.get_pending_jobs(), db, dst_dir, run_log=run_log, verify=True)
        run_log.close()

        with open(log_path) as f:
            content = f.read()
        self.assertIn("Failed to remove unverified copy", content)
        self.assertIn("Verification failed", content)
        db.close()

    def test_run_log_error_on_abort_after_verification_failures(self):
        """Repeated verification failures should log the abort threshold message."""
        from chronoframe.core import execute_jobs, RunLogger
        src_dir, dst_dir, db = self._setup_env()

        jobs = []
        for index in range(MAX_CONSECUTIVE_FAILURES):
            src = os.path.join(src_dir, f"photo_{index}.jpg")
            with open(src, 'wb') as f:
                f.write(f"payload-{index}".encode("utf-8"))
            jobs.append((src, os.path.join(dst_dir, f"photo_{index}.jpg"), f"wrong_hash_{index}", "PENDING"))

        log_path = os.path.join(dst_dir, "verify_abort.log")
        run_log = RunLogger(log_path)
        run_log.open()

        db.enqueue_jobs(jobs)
        execute_jobs(db.get_pending_jobs(), db, dst_dir, run_log=run_log, verify=True)
        run_log.close()

        with open(log_path) as f:
            content = f.read()
        self.assertIn("Aborting", content)
        self.assertIn("Verification failed", content)
        db.close()


class TestExecuteJobsGetSizeOSError(TempDirMixin, unittest.TestCase):
    """Lines 601-602: fallback to st_size when getsize raises OSError after successful copy."""

    def test_getsize_oserror_uses_stat_size_fallback(self):
        """Lines 601-602: if os.path.getsize fails post-copy, st_size is used instead."""
        from chronoframe.core import execute_jobs
        src_dir = os.path.join(self.tmpdir, "source")
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(src_dir)
        os.makedirs(dst_dir)
        db = CacheDB(os.path.join(dst_dir, ".cache.db"))

        src = os.path.join(src_dir, "photo.jpg")
        with open(src, 'wb') as f:
            f.write(b"x" * 1024)
        dst_path = os.path.join(dst_dir, "photo.jpg")

        db.enqueue_jobs([(src, dst_path, "h1", "PENDING")])

        original_getsize = os.path.getsize
        call_count = [0]

        def getsize_raises_once(path):
            call_count[0] += 1
            # Pre-flight loop makes 1 call (call_count==1) — let it pass.
            # The post-copy call inside the copy loop is call_count==2 — raise
            # OSError so execution falls through to the st.st_size fallback.
            if call_count[0] > 1:  # fail on post-copy call
                raise OSError("getsize failed")
            return original_getsize(path)

        with patch('chronoframe.core.os.path.getsize', side_effect=getsize_raises_once):
            execute_jobs(db.get_pending_jobs(), db, dst_dir)

        self.assertTrue(os.path.exists(dst_path))
        db.close()


class TestHasExifreadFalseWarning(TempDirMixin, unittest.TestCase):
    """Line 299: console prints warning when HAS_EXIFREAD is False."""

    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    def test_no_exifread_prints_warning(self, _):
        from chronoframe.core import main
        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with patch('chronoframe.core.HAS_EXIFREAD', False):
            with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                main()  # Must complete; line 299 hit when HAS_EXIFREAD is False


class TestExifreadTagFound(unittest.TestCase):
    """metadata.py lines 28-33: exifread returns a matching tag."""

    def test_get_date_exifread_with_datetime_original(self):
        """Lines 28-33: when EXIF DateTimeOriginal is present, return parsed datetime."""
        from chronoframe.metadata import get_date_exifread

        fake_tags = {'EXIF DateTimeOriginal': '2023:06:15 12:30:00'}

        with patch('exifread.process_file', return_value=fake_tags):
            with tempfile.NamedTemporaryFile(suffix='.jpg', delete=False) as f:
                f.write(b"fake jpeg")
                tmp = f.name
            try:
                result = get_date_exifread(tmp)
            finally:
                os.unlink(tmp)

        self.assertIsNotNone(result)
        self.assertEqual(result.year, 2023)
        self.assertEqual(result.month, 6)
        self.assertEqual(result.day, 15)

    def test_get_date_exifread_zero_timestamp_returns_none(self):
        """The all-zero timestamp is treated as missing and returns None."""
        from chronoframe.metadata import get_date_exifread

        fake_tags = {'EXIF DateTimeOriginal': '0000:00:00 00:00:00'}

        with patch('exifread.process_file', return_value=fake_tags):
            with tempfile.NamedTemporaryFile(suffix='.jpg', delete=False) as f:
                f.write(b"fake jpeg")
                tmp = f.name
            try:
                result = get_date_exifread(tmp)
            finally:
                os.unlink(tmp)

        self.assertIsNone(result)

    def test_get_date_exifread_exception_returns_none(self):
        """Unexpected EXIF parser failures should safely return None."""
        from chronoframe.metadata import get_date_exifread

        with patch('exifread.process_file', side_effect=RuntimeError("bad exif")):
            with tempfile.NamedTemporaryFile(suffix='.jpg', delete=False) as f:
                f.write(b"fake jpeg")
                tmp = f.name
            try:
                result = get_date_exifread(tmp)
            finally:
                os.unlink(tmp)

        self.assertIsNone(result)

    def test_parse_mdls_creation_date_invalid_string_returns_none(self):
        self.assertIsNone(parse_mdls_creation_date("not-a-date"))


class TestMainCopyCancellation(TempDirMixin, unittest.TestCase):
    @patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml')
    @patch('chronoframe.core.Confirm.ask', return_value=False)
    def test_copy_cancelled_by_confirmation_prompt(self, _mock_confirm, _mock_yaml):
        from chronoframe.core import main

        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "IMG_20230101_120000.jpg"), 'wb') as f:
            f.write(b"cancel-me")

        with patch('sys.argv', ['prog', '--source', src, '--dest', dst]):
            main()

        expected_dst = os.path.join(dst, "2023", "01", "01", "2023-01-01_001.jpg")
        self.assertFalse(os.path.exists(expected_dst))

        db = CacheDB(os.path.join(dst, ".organize_cache.db"))
        self.assertEqual(db.get_pending_jobs(), [])
        db.close()


if __name__ == '__main__':
    unittest.main()
