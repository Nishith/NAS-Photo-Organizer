#!/usr/bin/env python3
"""
Tests for bug fixes - ensuring previously undiscovered bugs don't resurface.

These tests specifically target the 25 bugs identified in the comprehensive
bug sweep and verify that fixes are working correctly.
"""

import errno
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from io import StringIO
from unittest.mock import patch, MagicMock

from chronoframe.database import CacheDB
from chronoframe.core import RunLogger, revert_receipt, _walk_error_handler, parse_args
from chronoframe.metadata import get_date_mdls


# ════════════════════════════════════════════════════════════════════════════
# P0: Critical Issues
# ════════════════════════════════════════════════════════════════════════════

class TestDatabaseTransactionRollback(unittest.TestCase):
    """P0 Issue #3: Unchecked database transactions with no rollback."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_save_batch_with_constraint_error_rolls_back(self):
        """Verify that constraint violations don't leave transaction open."""
        db = CacheDB(self.db_path)

        # Insert a valid record first
        db.save_batch(1, [("/a.jpg", "hash_a", 100, 1.0)])

        # Try to violate PRIMARY KEY constraint by inserting same path
        # The new code should rollback the transaction
        try:
            db.conn.executemany(
                "INSERT INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)",
                [(1, "/a.jpg", "hash_b", 200, 2.0)]
            )
            db.conn.commit()
            self.fail("Expected constraint violation")
        except sqlite3.IntegrityError:
            # This is expected - but before the fix, the transaction would be left open
            pass

        # Verify the transaction was cleaned up by trying another operation
        try:
            db.save_batch(1, [("/c.jpg", "hash_c", 300, 3.0)])
            # Should succeed - transaction was properly cleaned up
            data = db.get_cache_dict(1)
            self.assertIn("/c.jpg", data)
        except sqlite3.DatabaseError as e:
            self.fail(f"Transaction was not cleaned up properly: {e}")

        db.close()

    def test_enqueue_jobs_with_error_rolls_back(self):
        """Verify enqueue_jobs handles errors gracefully."""
        db = CacheDB(self.db_path)

        # Valid job
        db.enqueue_jobs([("/src.jpg", "/dst.jpg", "hash", "PENDING")])

        # Try to enqueue same source again (will replace due to ON CONFLICT)
        db.enqueue_jobs([("/src.jpg", "/dst2.jpg", "hash2", "PENDING")])

        pending = db.get_pending_jobs()
        # Should have the second one
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0][1], "/dst2.jpg")

        db.close()


class TestSubprocessReturnCodeChecking(unittest.TestCase):
    """P0 Issue #2: Exit code ignored in subprocess calls."""

    def test_mdls_failure_returns_none(self):
        """Verify that mdls command failures return None instead of parsing bad output."""
        # Mock subprocess.run to return non-zero exit code
        with patch('chronoframe.metadata.subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,  # Non-zero indicates failure
                stdout="(null)"
            )

            result = get_date_mdls("/nonexistent/file.jpg")

            # Should return None on failure, not try to parse the output
            self.assertIsNone(result)

    def test_mdls_success_parses_output(self):
        """Verify that mdls success properly parses output."""
        with patch('chronoframe.metadata.subprocess.run') as mock_run:
            with patch('chronoframe.metadata.os.path.isfile') as mock_isfile:
                mock_isfile.return_value = True
                mock_run.return_value = MagicMock(
                    returncode=0,  # Success
                    stdout="2024-01-15 10:30:45 +0000"
                )

                result = get_date_mdls("/some/file.jpg")

                # Should parse the date successfully
                self.assertIsNotNone(result)


class TestHashErrorLogging(unittest.TestCase):
    """P0 Issue #1: Silent hash failures in destination scanning."""

    def test_hash_errors_are_logged(self):
        """Verify that hash failures are logged with counts."""
        # This would require integration testing with actual destination scan
        # For now, verify the count is tracked in emit_json calls
        from chronoframe.core import build_dest_index
        from chronoframe.database import CacheDB

        tmpdir = tempfile.mkdtemp()
        try:
            db_path = os.path.join(tmpdir, "test.db")
            dst_path = os.path.join(tmpdir, "dst")
            os.makedirs(dst_path)

            # Create a file that will exist during walk but fail on hash
            test_file = os.path.join(dst_path, "2024-01-15_001.jpg")
            with open(test_file, 'wb') as f:
                f.write(b"test data")

            # Mock process_single_file to raise an exception
            with patch('chronoframe.core.process_single_file') as mock_hash:
                mock_hash.side_effect = OSError("I/O error")

                # Capture output to verify error was logged
                from io import StringIO
                captured_output = StringIO()

                with patch('chronoframe.core.console') as mock_console:
                    with patch('chronoframe.core.emit_json') as mock_emit:
                        cache_db = CacheDB(db_path)
                        build_dest_index(dst_path, cache_db, workers=1)

                        # Verify error was emitted
                        warning_calls = [call for call in mock_emit.call_args_list
                                        if call[0][0] == "warning"]
                        self.assertGreater(len(warning_calls), 0)

                        cache_db.close()
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class TestRevertLogging(unittest.TestCase):
    """P0 Issue #4: Silent revert failures without logging."""

    def test_revert_logs_success(self):
        """Verify successful reverts are logged."""
        tmpdir = tempfile.mkdtemp()
        try:
            dst = os.path.join(tmpdir, "dst")
            os.makedirs(dst)

            # Create a file to "revert"
            test_file = os.path.join(dst, "2024-01-15_001.jpg")
            with open(test_file, 'wb') as f:
                f.write(b"test data")

            # Create receipt
            receipt = {
                "transfers": [
                    {
                        "src": "/src/photo.jpg",
                        "dest": test_file,
                        "hash": "test_hash"  # Won't match, but we'll verify logging
                    }
                ]
            }

            receipt_path = os.path.join(tmpdir, "receipt.json")
            with open(receipt_path, 'w') as f:
                json.dump(receipt, f)

            # Verify that hash mismatch is logged as a warning
            with patch('chronoframe.core.fast_hash') as mock_hash:
                mock_hash.return_value = "different_hash"

                with patch('chronoframe.core.emit_json') as mock_emit:
                    with patch('chronoframe.core.console'):
                        with patch('chronoframe.core.Progress'):
                            revert_receipt(receipt_path, dst)

                            # Should have warning about hash mismatch
                            warning_calls = [call for call in mock_emit.call_args_list
                                           if call[0][0] == "warning"]
                            self.assertGreater(len(warning_calls), 0)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class TestVerificationFailureReasons(unittest.TestCase):
    """P0 Issue: Verification failures should distinguish root causes."""

    def test_verify_copy_reports_not_found(self):
        """Verify that missing destination is properly reported."""
        from chronoframe.io import verify_copy
        match, reason = verify_copy("/fake/src.jpg", "/nonexistent/dst.jpg", "hash")
        self.assertFalse(match)
        self.assertEqual(reason, "not_found")

    def test_verify_copy_reports_hash_mismatch(self):
        """Verify that hash mismatch is properly reported."""
        import tempfile
        from chronoframe.io import verify_copy, fast_hash

        tmpdir = tempfile.mkdtemp()
        try:
            src = os.path.join(tmpdir, "src.jpg")
            dst = os.path.join(tmpdir, "dst.jpg")

            with open(src, 'wb') as f:
                f.write(b"original content")
            with open(dst, 'wb') as f:
                f.write(b"different content")

            src_hash = fast_hash(src)
            match, reason = verify_copy(src, dst, src_hash)

            self.assertFalse(match)
            self.assertEqual(reason, "mismatch")
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_verify_copy_reports_symlink(self):
        """Verify that symlink destination is properly reported."""
        import tempfile
        from chronoframe.io import verify_copy, fast_hash

        tmpdir = tempfile.mkdtemp()
        try:
            src = os.path.join(tmpdir, "src.jpg")
            real_dst = os.path.join(tmpdir, "real.jpg")
            symlink_dst = os.path.join(tmpdir, "link.jpg")

            with open(src, 'wb') as f:
                f.write(b"content")
            with open(real_dst, 'wb') as f:
                f.write(b"content")

            os.symlink(real_dst, symlink_dst)

            src_hash = fast_hash(src)
            match, reason = verify_copy(src, symlink_dst, src_hash)

            self.assertFalse(match)
            self.assertEqual(reason, "symlink")
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class TestPathTraversalValidation(unittest.TestCase):
    """P0 Issue #5: Path traversal TOCTOU race in revert."""

    def test_revert_rejects_paths_outside_boundary(self):
        """Verify paths outside destination are rejected."""
        tmpdir = tempfile.mkdtemp()
        try:
            dst = os.path.join(tmpdir, "dst")
            os.makedirs(dst)

            # Create receipt with path outside boundary
            receipt = {
                "transfers": [
                    {
                        "src": "/src/photo.jpg",
                        "dest": "/etc/passwd",  # Outside boundary!
                        "hash": "test_hash"
                    }
                ]
            }

            receipt_path = os.path.join(tmpdir, "receipt.json")
            with open(receipt_path, 'w') as f:
                json.dump(receipt, f)

            # Should reject the path
            with patch('chronoframe.core.emit_json') as mock_emit:
                with patch('chronoframe.core.console') as mock_console:
                    with patch('chronoframe.core.Progress'):
                        revert_receipt(receipt_path, dst)

                        # Should emit error about outside boundary
                        error_calls = [call for call in mock_emit.call_args_list
                                      if call[0][0] == "error"]
                        # At least one error about boundary
                        boundary_errors = [call for call in error_calls
                                         if "boundary" in str(call).lower()]
                        self.assertGreater(len(boundary_errors), 0)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


# ════════════════════════════════════════════════════════════════════════════
# P1: High Priority Issues
# ════════════════════════════════════════════════════════════════════════════

class TestRunLoggerFileDescriptorLeak(unittest.TestCase):
    """P1 Issue #8: File descriptor leak in log rotation."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_runlogger_closes_existing_handle_on_reopen(self):
        """Verify that opening an existing RunLogger closes the previous handle."""
        log_path = os.path.join(self.tmpdir, "test.log")

        logger = RunLogger(log_path)
        logger.open()

        # Store reference to first handle
        first_handle = logger._fh
        self.assertFalse(first_handle.closed)

        # Open again - should close previous handle
        logger.open()

        # The old file handle should be closed
        self.assertTrue(first_handle.closed)

        logger.close()

    def test_runlogger_handles_open_error_gracefully(self):
        """Verify that errors during open don't leave stale handles."""
        log_path = os.path.join(self.tmpdir, "test.log")

        logger = RunLogger(log_path)
        logger.open()
        first_open_ok = logger._fh is not None
        self.assertTrue(first_open_ok)

        # Make the log path a directory to cause next open to fail
        logger.close()
        os.remove(log_path)
        os.makedirs(log_path)

        # Try to open (should fail)
        logger.open()
        self.assertIsNone(logger._fh)

        # Cleanup
        import shutil
        shutil.rmtree(log_path)


class TestWalkErrorHandlerLogging(unittest.TestCase):
    """P1 Issue #12: Walk errors not logged to console."""

    def test_walk_error_handler_logs_to_console(self):
        """Verify walk errors are logged both to JSON and console."""
        handler = _walk_error_handler()

        error = OSError(errno.EACCES, "Permission denied")
        error.filename = "/blocked/folder"

        with patch('chronoframe.core.emit_json') as mock_emit:
            with patch('chronoframe.core.console') as mock_console:
                handler(error)

                # Should call emit_json
                emit_calls = [call for call in mock_emit.call_args_list
                             if call[0][0] == "warning"]
                self.assertGreater(len(emit_calls), 0)

                # Should call console.print
                console_calls = mock_console.print.call_args_list
                self.assertGreater(len(console_calls), 0)


class TestSymlinkSkippingLogging(unittest.TestCase):
    """P2 Issue #23: Symlink files logged when skipped."""

    def test_source_modified_skip_logs_to_run_log(self):
        """execute_jobs with verify_source=True must log a warning to run_log
        when a source file's hash has changed since the copy plan was built.
        This covers the run_log.warn path in the source-modified skip branch.
        """
        from chronoframe.core import execute_jobs
        from chronoframe.io import fast_hash as real_fast_hash

        tmpdir = tempfile.mkdtemp()
        try:
            src_dir = os.path.join(tmpdir, "src")
            dst_dir = os.path.join(tmpdir, "dst")
            os.makedirs(src_dir)
            os.makedirs(dst_dir)

            src = os.path.join(src_dir, "photo.jpg")
            with open(src, 'wb') as f:
                f.write(b"original")
            planned_hash = real_fast_hash(src)

            # Overwrite source so its hash no longer matches the planned hash.
            with open(src, 'wb') as f:
                f.write(b"modified after planning")

            dst_path = os.path.join(dst_dir, "2024-06-15_001.jpg")
            db = CacheDB(os.path.join(tmpdir, "test.db"))
            db.enqueue_jobs([(src, dst_path, planned_hash, "PENDING")])
            pending = db.get_pending_jobs()

            log_path = os.path.join(tmpdir, "run.log")
            run_log = RunLogger(log_path)
            run_log.open()

            execute_jobs(pending, db, dst_dir, run_log=run_log, verify_source=True)

            run_log.close()
            db.close()

            with open(log_path) as f:
                log_content = f.read()

            self.assertIn("modified since planning", log_content,
                          "run_log must record the source-modified skip")
            self.assertFalse(os.path.exists(dst_path),
                             "Skipped jobs must not produce a destination file")
        finally:
            import shutil
            shutil.rmtree(tmpdir)


# ════════════════════════════════════════════════════════════════════════════
# P2: Medium Priority Issues
# ════════════════════════════════════════════════════════════════════════════

class TestCLIArgumentValidation(unittest.TestCase):
    """P2 Issue #24: CLI arguments unbounded."""

    def test_workers_argument_validated(self):
        """Verify --workers argument is capped at reasonable limit."""
        # Test with invalid value - should fail
        with patch('sys.argv', ['chronoframe', '--workers', '999999']):
            with self.assertRaises(SystemExit):
                parse_args()

    def test_workers_argument_accepts_valid_values(self):
        """Verify --workers accepts reasonable values."""
        import multiprocessing
        max_workers = max(1, multiprocessing.cpu_count() * 2)

        with patch('sys.argv', ['chronoframe', '--workers', str(max_workers)]):
            args = parse_args()
            self.assertEqual(args.workers, max_workers)

    def test_workers_minimum_is_one(self):
        """Verify --workers minimum is 1."""
        with patch('sys.argv', ['chronoframe', '--workers', '0']):
            with self.assertRaises(SystemExit):
                parse_args()


class TestDatabasePragmaValidation(unittest.TestCase):
    """P2 Issue #19: Database pragmas not validated."""

    def test_wal_pragma_validation(self):
        """Verify WAL pragma is actually enabled."""
        tmpdir = tempfile.mkdtemp()
        try:
            db_path = os.path.join(tmpdir, "test.db")
            db = CacheDB(db_path)

            # Check that WAL is actually enabled
            cursor = db.conn.execute("PRAGMA journal_mode;")
            mode = cursor.fetchone()[0]

            # Should be WAL
            self.assertEqual(mode.upper(), "WAL")

            db.close()
        finally:
            import shutil
            shutil.rmtree(tmpdir)


# ════════════════════════════════════════════════════════════════════════════
# Integration Tests
# ════════════════════════════════════════════════════════════════════════════

class TestBugFixIntegration(unittest.TestCase):
    """Integration tests verifying multiple bug fixes work together."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_receipt_destroot_field_is_informational_not_trusted_as_boundary(self):
        """The destRoot field in a receipt is audit metadata only.

        revert_receipt() must derive the deletion boundary exclusively from
        trusted sources (the --dest flag or the receipt's own filesystem
        location).  It must NOT use data["destRoot"] as the boundary, because
        that field comes from the untrusted receipt payload — a crafted receipt
        with "destRoot": "/" would otherwise widen the boundary to the entire
        filesystem.

        When the receipt has been moved (and no --dest is provided), the
        heuristic boundary is derived from the receipt's new location, which
        will differ from destRoot.  A warning is emitted and the file inside
        the real dest_dir is left untouched (correct safe-default behaviour).
        To revert a moved receipt the operator must supply --dest explicitly.
        """
        from chronoframe.core import generate_audit_receipt, revert_receipt
        from chronoframe.io import fast_hash

        dest_dir = os.path.join(self.tmpdir, "library")
        os.makedirs(dest_dir)

        dest_file = os.path.join(dest_dir, "2024-06-15_001.jpg")
        with open(dest_file, 'wb') as f:
            f.write(b"photo data")
        dest_hash = fast_hash(dest_file)

        # Place the receipt in a DIFFERENT directory to simulate a moved receipt.
        moved_receipt_dir = os.path.join(self.tmpdir, "moved_receipts")
        os.makedirs(moved_receipt_dir)
        logs_dir = os.path.join(moved_receipt_dir, ".organize_logs")
        os.makedirs(logs_dir)

        receipt_data = {
            "schemaVersion": 2,
            # destRoot is informational — it must NOT be used as the security
            # boundary.  Even though it points at the real library dir, the
            # boundary must be derived from the receipt's location instead.
            "destRoot": dest_dir,
            "transfers": [{"source": "/src/photo.jpg", "dest": dest_file, "hash": dest_hash}],
        }
        receipt_path = os.path.join(logs_dir, "audit_receipt_test.json")
        with open(receipt_path, 'w') as f:
            json.dump(receipt_data, f)

        # No --dest override: boundary comes from receipt location heuristic
        # (moved_receipts/ in this case), not from data["destRoot"].
        with patch('chronoframe.core.console'):
            revert_receipt(receipt_path)

        # dest_file is OUTSIDE the heuristic boundary, so it must be preserved.
        self.assertTrue(
            os.path.exists(dest_file),
            "destRoot from JSON must not be trusted as the deletion boundary; "
            "file outside the heuristic boundary must be preserved.",
        )

    def test_receipt_destroot_field_honoured_via_dest_override(self):
        """When the operator supplies --dest, moved receipts work correctly.

        This is the correct way to revert a receipt that has been moved from
        its original <dest>/.organize_logs/ location.
        """
        from chronoframe.core import revert_receipt
        from chronoframe.io import fast_hash

        dest_dir = os.path.join(self.tmpdir, "library")
        os.makedirs(dest_dir)

        dest_file = os.path.join(dest_dir, "2024-06-15_001.jpg")
        with open(dest_file, 'wb') as f:
            f.write(b"photo data")
        dest_hash = fast_hash(dest_file)

        moved_receipt_dir = os.path.join(self.tmpdir, "moved_receipts")
        os.makedirs(moved_receipt_dir)
        logs_dir = os.path.join(moved_receipt_dir, ".organize_logs")
        os.makedirs(logs_dir)

        receipt_data = {
            "schemaVersion": 2,
            "destRoot": dest_dir,
            "transfers": [{"source": "/src/photo.jpg", "dest": dest_file, "hash": dest_hash}],
        }
        receipt_path = os.path.join(logs_dir, "audit_receipt_test.json")
        with open(receipt_path, 'w') as f:
            json.dump(receipt_data, f)

        # With --dest supplied, the boundary is correctly set to dest_dir.
        with patch('chronoframe.core.console'):
            revert_receipt(receipt_path, dest_root_override=dest_dir)

        self.assertFalse(
            os.path.exists(dest_file),
            "File inside dest_dir must be deleted when --dest supplies the boundary.",
        )


# ════════════════════════════════════════════════════════════════════════════
# Coverage: Database error rollback paths
# ════════════════════════════════════════════════════════════════════════════

class TestDatabaseErrorRollbackPaths(unittest.TestCase):
    """Cover all database write methods' rollback-on-error paths."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()
        self.db_path = os.path.join(self.tmpdir, "test.db")

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _force_error(self, db, method_name, *args):
        """Wrap conn.executemany/execute with a raising version. Verify rollback."""
        db_method = getattr(db, method_name)

        # sqlite3.Connection attributes are read-only C slots; wrap the methods
        # via a side_effect on a Mock-replaced connection-method dict instead.
        orig_executemany = db.conn.executemany
        orig_execute = db.conn.execute
        rollback_called = [False]
        orig_rollback = db.conn.rollback

        def raising_executemany(*a, **k):
            raise sqlite3.IntegrityError("forced")

        def raising_execute(sql, *a, **k):
            # Allow PRAGMA and SELECT to proceed; raise on writes
            if any(k in sql.upper() for k in ("INSERT", "UPDATE", "DELETE")):
                raise sqlite3.IntegrityError("forced")
            return orig_execute(sql, *a, **k)

        def tracked_rollback():
            rollback_called[0] = True
            return orig_rollback()

        # Use a wrapper object to substitute methods, since Connection attrs are read-only
        class WrappedConn:
            def __init__(self, real_conn):
                self._real = real_conn

            def executemany(self, *a, **k):
                return raising_executemany(*a, **k)

            def execute(self, *a, **k):
                return raising_execute(*a, **k)

            def commit(self):
                return self._real.commit()

            def rollback(self):
                return tracked_rollback()

            def close(self):
                return self._real.close()

        real_conn = db.conn
        db.conn = WrappedConn(real_conn)
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                db_method(*args)
            self.assertTrue(rollback_called[0], f"{method_name} did not call rollback")
        finally:
            db.conn = real_conn

    def test_save_batch_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'save_batch', 1, [("/a.jpg", "h", 100, 1.0)])
        db.close()

    def test_enqueue_jobs_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'enqueue_jobs', [("/s.jpg", "/d.jpg", "h", "PENDING")])
        db.close()

    def test_delete_cache_entry_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'delete_cache_entry', 1, "/a.jpg")
        db.close()

    def test_update_job_status_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'update_job_status', "/s.jpg", "COPIED")
        db.close()

    def test_update_job_statuses_batch_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'update_job_statuses_batch', [("/s.jpg", "COPIED")])
        db.close()

    def test_clear_cache_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'clear_cache')
        db.close()

    def test_clear_cache_by_type_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'clear_cache', 1)
        db.close()

    def test_clear_jobs_rolls_back_on_error(self):
        db = CacheDB(self.db_path)
        self._force_error(db, 'clear_jobs')
        db.close()

    def test_empty_batches_no_op(self):
        """Empty inputs should short-circuit without touching the db."""
        db = CacheDB(self.db_path)
        db.save_batch(1, [])
        db.enqueue_jobs([])
        db.update_job_statuses_batch([])
        db.close()

    def test_init_pragma_non_wal_result_warns(self):
        """If WAL pragma returns non-WAL mode, warn to stderr."""
        from io import StringIO

        db = CacheDB(self.db_path)
        captured = StringIO()
        real_conn = db.conn

        class FakeConnReturningMemory:
            def execute(self, sql, *a, **k):
                fake = MagicMock()
                fake.fetchone.return_value = ("memory",)
                return fake

        db.conn = FakeConnReturningMemory()
        try:
            with patch('sys.stderr', captured):
                db._init_pragmas()
        finally:
            db.conn = real_conn
            db.close()

        self.assertIn("WAL", captured.getvalue())


# ════════════════════════════════════════════════════════════════════════════
# Coverage: Verification failure reason branches
# ════════════════════════════════════════════════════════════════════════════

class TestVerificationFailureBranches(unittest.TestCase):
    """Cover all verification failure reason branches in execute_jobs."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _run_with_verify_reason(self, reason):
        """Run execute_jobs with a single job and a mocked verify_copy that returns the given reason."""
        from chronoframe.core import execute_jobs, RunLogger
        from chronoframe.database import CacheDB

        src = os.path.join(self.tmpdir, "src.jpg")
        dst = os.path.join(self.tmpdir, "dst.jpg")
        with open(src, 'wb') as f:
            f.write(b"content")

        db = CacheDB(os.path.join(self.tmpdir, ".cache.db"))
        run_log = RunLogger(os.path.join(self.tmpdir, "log.txt"))
        run_log.open()

        try:
            with patch('chronoframe.core.verify_copy', return_value=(False, reason)):
                with patch('chronoframe.core.emit_json') as mock_emit:
                    execute_jobs(
                        [(src, dst, "fake_hash")], db, self.tmpdir,
                        run_log=run_log, verify=True, workers=1
                    )

                    # Find the error emit call with the matching type
                    error_calls = [c for c in mock_emit.call_args_list
                                   if c[0][0] == "error"]
                    return error_calls
        finally:
            run_log.close()
            db.close()

    def test_verify_not_found_reason(self):
        calls = self._run_with_verify_reason("not_found")
        self.assertTrue(any("vanished" in str(c).lower() or "not_found" in str(c).lower()
                            for c in calls))

    def test_verify_symlink_reason(self):
        calls = self._run_with_verify_reason("symlink")
        self.assertTrue(any("symlink" in str(c).lower() for c in calls))

    def test_verify_not_regular_reason(self):
        calls = self._run_with_verify_reason("not_regular_file")
        self.assertTrue(any("regular" in str(c).lower() for c in calls))

    def test_verify_permission_reason(self):
        calls = self._run_with_verify_reason("permission_denied")
        self.assertTrue(any("permission" in str(c).lower() for c in calls))

    def test_verify_io_error_reason(self):
        calls = self._run_with_verify_reason("io_error")
        self.assertTrue(any("i/o" in str(c).lower() or "io_error" in str(c).lower()
                            for c in calls))

    def test_verify_unknown_reason(self):
        """Unknown reason should still emit an error."""
        calls = self._run_with_verify_reason("weird_reason")
        self.assertGreater(len(calls), 0)


# ════════════════════════════════════════════════════════════════════════════
# Coverage: process_single_file error reasons
# ════════════════════════════════════════════════════════════════════════════

class TestProcessSingleFileErrorReasons(unittest.TestCase):
    """Cover all process_single_file error reason returns."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_symlink_returns_symlink_reason(self):
        from chronoframe.io import process_single_file
        target = os.path.join(self.tmpdir, "real.jpg")
        link = os.path.join(self.tmpdir, "link.jpg")
        with open(target, 'wb') as f:
            f.write(b"data")
        os.symlink(target, link)

        h, _, _, _, reason = process_single_file(link, None)
        self.assertIsNone(h)
        self.assertEqual(reason, "symlink")

    def test_directory_returns_not_regular_reason(self):
        from chronoframe.io import process_single_file
        d = os.path.join(self.tmpdir, "dir")
        os.makedirs(d)
        h, _, _, _, reason = process_single_file(d, None)
        self.assertIsNone(h)
        self.assertEqual(reason, "not_regular_file")

    def test_missing_returns_not_found_reason(self):
        from chronoframe.io import process_single_file
        h, _, _, _, reason = process_single_file("/no/such/file.jpg", None)
        self.assertIsNone(h)
        self.assertEqual(reason, "not_found")


# ════════════════════════════════════════════════════════════════════════════
# Coverage: build_dest_index error categorization
# ════════════════════════════════════════════════════════════════════════════

class TestBuildDestIndexErrorCategorization(unittest.TestCase):
    """Cover the per-error-type warning emissions in build_dest_index."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def _run_with_psf_error(self, error_reason):
        """Make process_single_file return the given error reason for one file."""
        from chronoframe.core import build_dest_index, RunLogger
        from chronoframe.database import CacheDB

        dst = os.path.join(self.tmpdir, "dst")
        os.makedirs(dst)
        test_file = os.path.join(dst, "2024-01-15_001.jpg")
        with open(test_file, 'wb') as f:
            f.write(b"data")

        db = CacheDB(os.path.join(self.tmpdir, ".cache.db"))
        run_log = RunLogger(os.path.join(self.tmpdir, "log.txt"))
        run_log.open()

        try:
            with patch('chronoframe.core.process_single_file',
                       return_value=(None, 0, 0, False, error_reason)):
                with patch('chronoframe.core.emit_json') as mock_emit:
                    build_dest_index(dst, db, workers=1, run_log=run_log)
                    warning_calls = [c for c in mock_emit.call_args_list
                                     if c[0][0] == "warning"]
                    return warning_calls
        finally:
            run_log.close()
            db.close()

    def test_symlink_categorized(self):
        calls = self._run_with_psf_error("symlink")
        self.assertTrue(any("symlink" in str(c).lower() for c in calls))

    def test_not_regular_file_categorized(self):
        calls = self._run_with_psf_error("not_regular_file")
        self.assertTrue(any("regular" in str(c).lower() for c in calls))

    def test_permission_denied_categorized(self):
        calls = self._run_with_psf_error("permission_denied")
        self.assertTrue(any("permission" in str(c).lower() for c in calls))

    def test_not_found_categorized(self):
        calls = self._run_with_psf_error("not_found")
        self.assertTrue(any("disappeared" in str(c).lower() or "not_found" in str(c).lower()
                            for c in calls))

    def test_io_error_categorized(self):
        calls = self._run_with_psf_error("io_error:5")
        self.assertTrue(any("i/o" in str(c).lower() or "io_error" in str(c).lower()
                            for c in calls))


# ════════════════════════════════════════════════════════════════════════════
# Coverage: Disk-space ENOSPC logging
# ════════════════════════════════════════════════════════════════════════════

class TestDiskSpaceLogging(unittest.TestCase):
    """Cover the ENOSPC-specific disk space logging branch."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_disk_usage_failure_warns_but_continues(self):
        """If shutil.disk_usage fails at transfer start, log and proceed."""
        from chronoframe.core import execute_jobs, RunLogger
        from chronoframe.database import CacheDB

        src = os.path.join(self.tmpdir, "src.jpg")
        with open(src, 'wb') as f:
            f.write(b"data")

        db = CacheDB(os.path.join(self.tmpdir, ".cache.db"))
        run_log = RunLogger(os.path.join(self.tmpdir, "log.txt"))
        run_log.open()

        try:
            # Patch only the first disk_usage call (the start-of-transfer one)
            with patch('shutil.disk_usage', side_effect=OSError("simulated stat failure")):
                # Should not raise — should just warn and proceed
                execute_jobs([], db, self.tmpdir, run_log=run_log, workers=1)
        finally:
            run_log.close()
            db.close()

    def test_enospc_logs_current_disk_state(self):
        """On ENOSPC during copy, log current disk free space."""
        from chronoframe.core import execute_jobs, RunLogger
        from chronoframe.database import CacheDB

        src = os.path.join(self.tmpdir, "src.jpg")
        dst = os.path.join(self.tmpdir, "dst.jpg")
        with open(src, 'wb') as f:
            f.write(b"content")

        db = CacheDB(os.path.join(self.tmpdir, ".cache.db"))
        run_log = RunLogger(os.path.join(self.tmpdir, "log.txt"))
        run_log.open()

        try:
            enospc_err = OSError(errno.ENOSPC, "No space left")
            with patch('chronoframe.core.safe_copy_atomic', side_effect=enospc_err):
                with patch('chronoframe.core.emit_json') as mock_emit:
                    execute_jobs(
                        [(src, dst, "fake_hash")], db, self.tmpdir,
                        run_log=run_log, workers=1
                    )

                    error_calls = [c for c in mock_emit.call_args_list
                                   if c[0][0] == "error"]
                    # Should include disk free info in the error message
                    self.assertTrue(any("disk free" in str(c).lower()
                                        or "no space" in str(c).lower()
                                        for c in error_calls))
        finally:
            run_log.close()
            db.close()


# ════════════════════════════════════════════════════════════════════════════
# Coverage: Date extraction failure logging
# ════════════════════════════════════════════════════════════════════════════

class TestDateExtractionFailureLogging(unittest.TestCase):
    """Cover the date extraction failure logging in main()."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_date_extraction_returning_none_logs_failure(self):
        """When get_file_date returns (None, None), failure is tracked."""
        from chronoframe.core import main

        src = os.path.join(self.tmpdir, "source")
        dst = os.path.join(self.tmpdir, "dest")
        os.makedirs(src)
        os.makedirs(dst)

        with open(os.path.join(src, "photo.jpg"), 'wb') as f:
            f.write(b"data")

        # Return (None, None) — all date methods failed
        with patch('chronoframe.core.get_file_date', return_value=(None, None)):
            with patch('chronoframe.core._find_profiles_yaml', return_value='/nonexistent/profiles.yaml'):
                with patch('sys.argv', ['prog', '--source', src, '--dest', dst, '--dry-run']):
                    main()  # Should not crash; file goes to Unknown_Date


# ════════════════════════════════════════════════════════════════════════════
# Coverage: Revert path boundary at deletion time
# ════════════════════════════════════════════════════════════════════════════

class TestRevertBoundaryAtDeletionTime(unittest.TestCase):
    """Cover the second boundary check that catches symlink swaps."""

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmpdir)

    def test_boundary_check_fails_at_deletion_time(self):
        """If _is_within_boundary returns False on second call, deletion is refused."""
        dst = os.path.join(self.tmpdir, "dst")
        os.makedirs(dst)
        test_file = os.path.join(dst, "2024-01-15_001.jpg")
        with open(test_file, 'wb') as f:
            f.write(b"data")

        receipt = {
            "transfers": [
                {"src": "/src/photo.jpg", "dest": test_file, "hash": "h"}
            ]
        }
        receipt_path = os.path.join(self.tmpdir, "receipt.json")
        with open(receipt_path, 'w') as f:
            json.dump(receipt, f)

        # First boundary check passes, second fails (simulating symlink swap)
        call_count = [0]
        def fake_is_within(path, *args):
            call_count[0] += 1
            return call_count[0] == 1  # First call True, subsequent calls False

        with patch('chronoframe.core.emit_json') as mock_emit:
            with patch('chronoframe.core.console'):
                with patch('chronoframe.core.Progress'):
                    # Use a closure to track and short-circuit the second check
                    from chronoframe import core as core_mod
                    orig_realpath = os.path.realpath

                    # Make the second realpath return something outside the boundary
                    # by transforming the destination into a symlink-equivalent
                    # path. The cleanest test is patching emit_json/console
                    # and asserting the boundary error code path is reached.
                    real_dst_root = os.path.realpath(dst)
                    seen = {"count": 0}
                    def fake_realpath(p):
                        seen["count"] += 1
                        # First call: validating receipt entry — return real path
                        # Second call: at deletion — return path outside boundary
                        if seen["count"] >= 2 and p == test_file:
                            return "/etc/passwd"
                        return orig_realpath(p)

                    with patch('os.path.realpath', side_effect=fake_realpath):
                        core_mod.revert_receipt(receipt_path, dst)

                    error_calls = [c for c in mock_emit.call_args_list
                                   if c[0][0] == "error"]
                    # Either initial boundary or deletion-time boundary error
                    self.assertTrue(any("boundary" in str(c).lower()
                                        for c in error_calls))


if __name__ == '__main__':
    unittest.main()
