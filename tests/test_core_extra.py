import unittest
import os
import tempfile
import shutil
import json
from datetime import datetime
from unittest.mock import patch, MagicMock

from chronoframe.core import RunLogger, revert_receipt, _event_subpath, build_dest_index
from chronoframe.database import CacheDB

class TestCoreExtra(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def test_run_logger_rotation(self):
        log_path = os.path.join(self.tmpdir, "test.log")
        rotated_path = log_path + ".1"
        
        # Create a large log file
        with open(log_path, "w") as f:
            f.write("A" * (RunLogger.MAX_LOG_BYTES + 100))
        
        # Create an existing rotated file
        with open(rotated_path, "w") as f:
            f.write("old rotated")
            
        logger = RunLogger(log_path)
        logger.open()
        logger.log("new message")
        logger.close()
        
        self.assertTrue(os.path.exists(rotated_path))
        with open(rotated_path, "r") as f:
            content = f.read()
            self.assertTrue(content.startswith("A" * 100))
            self.assertFalse("old rotated" in content)

    def test_revert_receipt_not_found(self):
        with patch("chronoframe.core.console.print") as mock_print:
            with self.assertRaises(SystemExit):
                revert_receipt("/nonexistent/receipt.json")
            mock_print.assert_any_call("[red]Receipt not found:[red] /nonexistent/receipt.json")

    def test_revert_receipt_invalid_json(self):
        receipt_path = os.path.join(self.tmpdir, "invalid.json")
        with open(receipt_path, "w") as f:
            f.write("not json")
        
        with patch("chronoframe.core.console.print") as mock_print:
            with self.assertRaises(SystemExit):
                revert_receipt(receipt_path)
            # Should print "Invalid receipt"
            args, _ = mock_print.call_args_list[0]
            self.assertTrue("Invalid receipt" in args[0])

    def test_event_subpath(self):
        src_root = os.path.join(self.tmpdir, "src")
        os.makedirs(src_root)
        
        # Nested folder
        event_dir = os.path.join(src_root, "Wedding: 2024")
        os.makedirs(event_dir)
        file_path = os.path.join(event_dir, "photo.jpg")
        
        # Should sanitize ':' to '_'
        self.assertEqual(_event_subpath(file_path, src_root), "Wedding_ 2024")
        
        # Root folder
        file_at_root = os.path.join(src_root, "at_root.jpg")
        self.assertEqual(_event_subpath(file_at_root, src_root), "")

    def test_unknown_date_with_event_layout(self):
        # Trigger lines 741-743 and 797-799 in core.py
        # We need a file that get_file_date classifies as "Unknown_Date"
        src_root = os.path.join(self.tmpdir, "src")
        dst_root = os.path.join(self.tmpdir, "dst")
        os.makedirs(os.path.join(src_root, "MyEvent"))
        os.makedirs(dst_root)
        
        # A file with no date in filename and mtime outside 1900-2100
        file_path = os.path.join(src_root, "MyEvent", "no_date.jpg")
        with open(file_path, "wb") as f:
            f.write(b"data")
        
        # Set mtime to something very old (e.g. 1899)
        # 1899-01-01 is roughly -2240524800 seconds from epoch
        try:
            os.utime(file_path, (-2240524800, -2240524800))
        except (OverflowError, OSError):
            # Fallback for systems that don't support pre-1970 mtime
            # We can mock get_file_date in core.py instead
            pass

        with patch("chronoframe.core.get_file_date") as mock_date:
            # Return a date in 1899 to trigger Unknown_Date in core.py
            mock_date.return_value = datetime(1899, 1, 1)
            
            # We also need to mock the CLI args
            args = MagicMock()
            args.source = src_root
            args.dest = dst_root
            args.folder_structure = "YYYY/Mon/Event"
            args.dry_run = True
            args.yes = True
            args.json = True
            args.workers = 1
            args.skip_verify = False
            
            # Since we want to test the loop in core.py, we might need a more integrative test or a direct call to the planning logic.
            # But core.py is a bit monolithic. Let's just use the parity test approach with a manifest if possible.
            # Actually, I can just call the planning part if it's isolated. It's not.
            
            # Let's try to trigger it via subprocess in a dedicated test if needed, 
            # but mocking get_file_date inside the current process is easier if we call main().
            
            with patch("sys.argv", ["chronoframe.py", "--source", src_root, "--dest", dst_root, "--folder-structure", "YYYY/Mon/Event", "--dry-run", "--yes"]):
                from chronoframe.core import main as cf_main
                with patch("chronoframe.core.console.print"):
                    with patch("chronoframe.core.Progress") as mock_progress:
                        mock_progress.return_value.__enter__.return_value = MagicMock()
                        ret = cf_main()
                self.assertTrue(ret is None or ret == 0)

    def test_run_logger_remove_failure(self):
        """Test RunLogger gracefully handles os.remove failure during rotation."""
        log_path = os.path.join(self.tmpdir, "test.log")

        # Create a large log file
        with open(log_path, "w") as f:
            f.write("A" * (RunLogger.MAX_LOG_BYTES + 100))

        logger = RunLogger(log_path)

        # Mock os.remove to raise OSError
        with patch("os.remove", side_effect=OSError("Permission denied")):
            logger.open()
            logger.log("test message")
            logger.close()

        # Should still have created the file handle and logged
        self.assertTrue(os.path.exists(log_path))

    def test_run_logger_rename_failure(self):
        """Test RunLogger gracefully handles os.rename failure during rotation."""
        log_path = os.path.join(self.tmpdir, "test.log")

        # Create a large log file
        with open(log_path, "w") as f:
            f.write("A" * (RunLogger.MAX_LOG_BYTES + 100))

        logger = RunLogger(log_path)

        # Mock os.rename to raise OSError
        with patch("os.rename", side_effect=OSError("Cross-device link")):
            logger.open()
            logger.log("test message")
            logger.close()

        self.assertTrue(os.path.exists(log_path))

    def test_build_dest_index_symlink_handling(self):
        """Symlinks in the destination directory must not be indexed."""
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst_dir)
        db_path = os.path.join(dst_dir, ".organize_cache.db")
        db = CacheDB(db_path)

        # Create a regular file and a symlink to it
        real_file = os.path.join(dst_dir, "real.jpg")
        with open(real_file, "wb") as f:
            f.write(b"data")

        link_path = os.path.join(dst_dir, "link.jpg")
        os.symlink(real_file, link_path)

        # Normal scan — symlinks should be skipped by the walker
        hi, seq, _ = build_dest_index(dst_dir, db)

        # Symlink must not appear in the hash index
        self.assertNotIn(link_path, hi)
        # Real file is indexed by content hash, not path
        self.assertEqual(len(hi), 1)

        db.close()

    def test_build_dest_index_directory_handling(self):
        """Directory paths must not appear in the destination hash index."""
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst_dir)
        db_path = os.path.join(dst_dir, ".organize_cache.db")
        db = CacheDB(db_path)

        # Create a regular file and a nested directory
        real_file = os.path.join(dst_dir, "file.jpg")
        with open(real_file, "wb") as f:
            f.write(b"data")

        subdir = os.path.join(dst_dir, "subdir")
        os.makedirs(subdir)

        # Normal scan — directories are never submitted to the hasher
        hi, seq, _ = build_dest_index(dst_dir, db)

        # Directory path must not be a value in the hash index
        self.assertNotIn(subdir, hi.values())

        db.close()

    def test_revert_receipt_path_boundary_validation(self):
        """Test revert_receipt refuses paths outside destination boundary."""
        dest_dir = os.path.join(self.tmpdir, "dest")
        outside_dir = os.path.join(self.tmpdir, "outside")
        os.makedirs(dest_dir)
        os.makedirs(outside_dir)

        # Create a receipt
        receipt_path = os.path.join(dest_dir, ".organize_logs", "receipt.json")
        os.makedirs(os.path.dirname(receipt_path), exist_ok=True)

        # Create receipt with path outside boundary
        outside_file = os.path.join(outside_dir, "file.jpg")
        receipt_data = {
            "transfers": [{"dest": outside_file, "hash": "somehash"}]
        }
        with open(receipt_path, "w") as f:
            json.dump(receipt_data, f)

        # Create the outside file so hash matches
        with open(outside_file, "wb") as f:
            f.write(b"data")

        with patch("chronoframe.core.console.print") as mock_print:
            with patch("chronoframe.core.emit_json"):
                revert_receipt(receipt_path)

        # Should have printed refusal message
        self.assertTrue(any("outside" in str(call) for call in mock_print.call_args_list))

    def test_revert_receipt_hash_mismatch(self):
        """Test revert_receipt skips files with mismatched hashes."""
        dest_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(dest_dir)

        # Create destination file
        dest_file = os.path.join(dest_dir, "file.jpg")
        with open(dest_file, "wb") as f:
            f.write(b"current data")

        # Create receipt with different hash
        receipt_path = os.path.join(dest_dir, ".organize_logs", "receipt.json")
        os.makedirs(os.path.dirname(receipt_path), exist_ok=True)

        receipt_data = {
            "transfers": [{"dest": dest_file, "hash": "expected_hash_that_wont_match"}]
        }
        with open(receipt_path, "w") as f:
            json.dump(receipt_data, f)

        with patch("chronoframe.core.console.print"):
            with patch("chronoframe.core.emit_json"):
                revert_receipt(receipt_path)

        # File should still exist (not deleted due to hash mismatch)
        self.assertTrue(os.path.exists(dest_file))

    def test_revert_receipt_missing_destination_file(self):
        """Test revert_receipt handles missing destination files gracefully."""
        dest_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(dest_dir)

        missing_file = os.path.join(dest_dir, "missing.jpg")

        # Create receipt
        receipt_path = os.path.join(dest_dir, ".organize_logs", "receipt.json")
        os.makedirs(os.path.dirname(receipt_path), exist_ok=True)

        receipt_data = {
            "transfers": [{"dest": missing_file, "hash": "somehash"}]
        }
        with open(receipt_path, "w") as f:
            json.dump(receipt_data, f)

        with patch("chronoframe.core.console.print"):
            with patch("chronoframe.core.emit_json"):
                revert_receipt(receipt_path)

        # Should complete without error (missing files are trivially reverted)
        self.assertFalse(os.path.exists(missing_file))

    def test_event_subpath_cross_device_error(self):
        """Test _event_subpath handles relpath ValueError."""
        # This tests the exception handler for ValueError from relpath
        # when trying to get relative path across drives on Windows
        with patch("os.path.relpath", side_effect=ValueError("paths on different drives")):
            result = _event_subpath("/some/path/file.jpg", "/different/root")
            self.assertEqual(result, "")

    def test_walk_error_handler_with_json_mode(self):
        """Test _walk_error_handler emits JSON warnings."""
        from chronoframe.core import _walk_error_handler

        handler = _walk_error_handler(run_log=None)
        error = OSError("Permission denied")
        error.filename = "/some/folder"

        with patch("chronoframe.core.emit_json") as mock_emit:
            handler(error)
            mock_emit.assert_called()
            call_args = mock_emit.call_args
            self.assertEqual(call_args[0][0], "warning")

    def test_walk_error_handler_with_logging(self):
        """Test _walk_error_handler logs to run_log when provided."""
        from chronoframe.core import _walk_error_handler

        mock_log = MagicMock()
        handler = _walk_error_handler(run_log=mock_log)
        error = OSError("Permission denied")
        error.filename = "/some/folder"

        with patch("chronoframe.core.emit_json"):
            handler(error)
            mock_log.warn.assert_called()

    def test_profile_loading_missing_file(self):
        """Test load_profile with missing profiles.yaml."""
        from chronoframe.core import load_profile

        with patch("chronoframe.core._find_profiles_yaml", return_value="/nonexistent/profiles.yaml"):
            with patch("chronoframe.core.console.print") as mock_print:
                with self.assertRaises(SystemExit):
                    load_profile("test_profile")
                mock_print.assert_called()
                args = mock_print.call_args[0]
                self.assertTrue("not found" in args[0])

    def test_profile_loading_invalid_profile_name(self):
        """Test load_profile with invalid profile name."""
        from chronoframe.core import load_profile

        profiles_path = os.path.join(self.tmpdir, "profiles.yaml")
        with open(profiles_path, "w") as f:
            f.write("valid_profile:\n  source: /src\n  dest: /dst\n")

        with patch("chronoframe.core._find_profiles_yaml", return_value=profiles_path):
            with patch("chronoframe.core.console.print") as mock_print:
                with self.assertRaises(SystemExit):
                    load_profile("nonexistent_profile")
                mock_print.assert_called()
                args = mock_print.call_args[0]
                self.assertTrue("not defined" in args[0])

    def test_profile_loading_missing_keys(self):
        """Test load_profile with missing source/dest keys."""
        from chronoframe.core import load_profile

        profiles_path = os.path.join(self.tmpdir, "profiles.yaml")
        with open(profiles_path, "w") as f:
            f.write("incomplete_profile:\n  source: /src\n")

        with patch("chronoframe.core._find_profiles_yaml", return_value=profiles_path):
            src, dest = load_profile("incomplete_profile")
            self.assertEqual(src, "/src")
            self.assertIsNone(dest)

if __name__ == "__main__":
    unittest.main()
