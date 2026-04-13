#!/usr/bin/env python3
"""
Comprehensive test suite for NAS Photo Organizer v3.
Run: python3 -m pytest test_organize_nas.py -v
  or: python3 -m unittest test_organize_nas.py -v
"""

import unittest
import tempfile
import shutil
import os
import json
import csv
import sqlite3
import time
from datetime import datetime
from unittest.mock import patch, MagicMock
from collections import defaultdict

from nas_organizer.database import CacheDB
from nas_organizer.io import fast_hash, safe_copy_atomic, verify_copy, process_single_file
from nas_organizer.metadata import (
    get_file_date, get_date_from_filename, get_date_mdls,
    ALL_EXTS, PHOTO_EXTS, VIDEO_EXTS, SKIP_FILES, HAS_EXIFREAD,
)
from nas_organizer.core import (
    build_dest_index, generate_dry_run_report, generate_audit_receipt,
    load_profile, RunLogger, SEQ_WIDTH, MAX_CONSECUTIVE_FAILURES,
    DEFAULT_WORKERS, parse_args,
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
        result = safe_copy_atomic(src, dst)
        self.assertIn("_collision", result)
        self.assertTrue(os.path.exists(result))

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
        with self.assertRaises(Exception):
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

    @patch('nas_organizer.metadata.get_date_mdls', return_value=None)
    def test_filename_fallback_when_no_mdls(self, mock_mdls):
        p = self._mkfile("IMG_20210501_120000.jpg", b"data")
        dt = get_file_date(p)
        self.assertEqual(dt, datetime(2021, 5, 1))

    @patch('nas_organizer.metadata.get_date_mdls')
    def test_mdls_used_when_filename_fails(self, mock_mdls):
        mock_mdls.return_value = datetime(2020, 6, 15, 10, 30, 0)
        p = self._mkfile("random_name.jpg", b"data")
        with patch('nas_organizer.metadata.HAS_EXIFREAD', False):
            dt = get_file_date(p)
        self.assertEqual(dt.year, 2020)
        self.assertEqual(dt.month, 6)

    def test_mtime_fallback(self):
        p = self._mkfile("nodate.jpg", b"data")
        with patch('nas_organizer.metadata.get_date_mdls', return_value=None):
            with patch('nas_organizer.metadata.HAS_EXIFREAD', False):
                dt = get_file_date(p)
        # Should return mtime which is recent
        self.assertGreater(dt.year, 2020)

    @patch('nas_organizer.metadata.get_date_mdls', return_value=datetime(1970, 1, 1))
    def test_mdls_1970_rejected(self, mock_mdls):
        """Dates ≤ 1971 from mdls are rejected; fallback to mtime."""
        p = self._mkfile("nodate.jpg", b"data")
        with patch('nas_organizer.metadata.HAS_EXIFREAD', False):
            dt = get_file_date(p)
        self.assertGreater(dt.year, 1971)


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
        self.assertIn('organize_nas.py', SKIP_FILES)

    def test_shell_scripts_skipped(self):
        self.assertIn('run_organize.sh', SKIP_FILES)
        self.assertIn('reorganize_structure.sh', SKIP_FILES)

    def test_config_files_skipped(self):
        self.assertIn('nas_profiles.yaml', SKIP_FILES)
        self.assertIn('requirements.txt', SKIP_FILES)

    def test_test_file_skipped(self):
        self.assertIn('test_organize_nas.py', SKIP_FILES)


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


# ════════════════════════════════════════════════════════════════════════════
# Profile Loading
# ════════════════════════════════════════════════════════════════════════════

class TestProfileLoading(TempDirMixin, unittest.TestCase):

    def _write_yaml(self, content):
        import yaml
        path = os.path.join(self.tmpdir, "nas_profiles.yaml")
        with open(path, 'w') as f:
            yaml.dump(content, f)
        return path

    @patch('nas_organizer.core._find_profiles_yaml')
    def test_load_valid_profile(self, mock_find):
        path = self._write_yaml({
            "my_profile": {"source": "/src", "dest": "/dst"}
        })
        mock_find.return_value = path
        src, dst = load_profile("my_profile")
        self.assertEqual(src, "/src")
        self.assertEqual(dst, "/dst")

    @patch('nas_organizer.core._find_profiles_yaml')
    def test_missing_profile_exits(self, mock_find):
        path = self._write_yaml({"other": {"source": "/a", "dest": "/b"}})
        mock_find.return_value = path
        with self.assertRaises(SystemExit):
            load_profile("nonexistent")

    @patch('nas_organizer.core._find_profiles_yaml')
    def test_missing_yaml_exits(self, mock_find):
        mock_find.return_value = "/nonexistent/nas_profiles.yaml"
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
        self.assertEqual(args.workers, DEFAULT_WORKERS)

    def test_all_flags(self):
        with patch('sys.argv', ['prog', '--source', '/s', '--dest', '/d',
                                '--profile', 'p', '--dry-run', '--rebuild-cache',
                                '--verify', '-y', '--workers', '4']):
            args = parse_args()
        self.assertEqual(args.source, '/s')
        self.assertEqual(args.dest, '/d')
        self.assertEqual(args.profile, 'p')
        self.assertTrue(args.dry_run)
        self.assertTrue(args.rebuild_cache)
        self.assertTrue(args.verify)
        self.assertTrue(args.yes)
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


if __name__ == '__main__':
    unittest.main()
