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
            args.fast_dest = False
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

    def test_build_dest_index_fast_dest_invalidation(self):
        dst_dir = os.path.join(self.tmpdir, "dest")
        os.makedirs(dst_dir)
        db_path = os.path.join(dst_dir, ".organize_cache.db")
        db = CacheDB(db_path)
        
        file_path = os.path.join(dst_dir, "test.jpg")
        with open(file_path, "wb") as f:
            f.write(b"data")
        
        # Seed cache with correct data
        st = os.stat(file_path)
        db.save_batch(2, [(file_path, "hash1", st.st_size, st.st_mtime)])
        
        # Modify file to trigger invalidation
        with open(file_path, "wb") as f:
            f.write(b"modified data")
        
        # Run with fast_dest
        hi, seq, _ = build_dest_index(dst_dir, db, fast_dest=True)
        
        # Hash should be updated
        self.assertIn(file_path, db.get_cache_dict(2))
        self.assertNotEqual(db.get_cache_dict(2)[file_path]["hash"], "hash1")
        
        # Test file removal
        os.remove(file_path)
        hi, seq, _ = build_dest_index(dst_dir, db, fast_dest=True)
        self.assertNotIn(file_path, db.get_cache_dict(2))
        
        db.close()

if __name__ == "__main__":
    unittest.main()
