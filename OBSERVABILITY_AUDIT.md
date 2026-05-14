# Chronoframe Observability Audit

**Status:** In Progress | **Date:** 2026-05-14  
**Goal:** Ensure logs contain sufficient diagnostic information for customer support to identify and fix issues without access to code

---

## Executive Summary

The logging infrastructure exists in three channels (JSON, console, file) and covers major success/failure paths. However, **critical diagnostic gaps** exist in:

1. **Error Context** — Many failures are logged without sufficient context to diagnose root cause
2. **Silent Fallbacks** — When operations fall back to alternatives (e.g., mtime after EXIF failure), this is not logged
3. **Transient Error Details** — Retry loops don't log which errors were retried vs. which failed permanently
4. **System State** — No logging of available resources at time of failure (disk space, file descriptors, memory)
5. **Individual File Issues** — Failures are counted but not traced back to specific files

---

## Critical Gaps & Proposed Fixes

### Gap 1: Date Extraction Failures Not Traced

**File:** `chronoframe/core.py:745-754`

**Current Code:**
```python
try:
    file_dates[path] = future.result()
except Exception:  # ← Silently catches ALL exceptions
    try:
        file_dates[path] = datetime.fromtimestamp(
            os.path.getmtime(path), timezone.utc
        ).replace(tzinfo=None)
    except OSError:
        file_dates[path] = None  # ← File ends up with no date, not logged
```

**Problems:**
- If date extraction fails, code silently falls back to mtime
- If mtime fails, file gets `None` with no context
- Support can't tell if file was:
  - Unreadable (permission denied)
  - Has corrupted EXIF
  - Clock-skewed
  - symlink
  - Zero-byte file

- Files ending up in "Unknown_Date" are not logged per-file

**What Customer Support Needs:**
- Which files failed date extraction and why
- Which files fell back to mtime
- Which files got None (classification will fail)
- Breakdown of date sources (EXIF, filename, mtime, Unknown)

**Proposed Fix:**
```python
# Track fallback reasons per file
date_extraction_stats = {'exif': 0, 'filename': 0, 'mtime': 0, 'unknown': 0}
failed_date_extraction = {}  # path -> reason

try:
    dt = future.result()
    file_dates[path] = dt
    if dt is None:
        date_extraction_stats['unknown'] += 1
    else:
        # Determine which method succeeded (requires introspection into get_file_date)
        # For now, count as 'exif' if not None
        date_extraction_stats['exif'] += 1
except Exception as e:
    failed_date_extraction[path] = str(e)
    date_extraction_stats['mtime'] += 1
    try:
        file_dates[path] = datetime.fromtimestamp(
            os.path.getmtime(path), timezone.utc
        ).replace(tzinfo=None)
    except OSError as mtime_err:
        failed_date_extraction[path] = f"date extraction failed: {e}; mtime also failed: {mtime_err}"
        file_dates[path] = None
        date_extraction_stats['unknown'] += 1

# After loop, log breakdown
if failed_date_extraction:
    msg = f"Date extraction failed for {len(failed_date_extraction)} files"
    run_log.warn(msg)
    for path, reason in list(failed_date_extraction.items())[:10]:  # First 10
        run_log.warn(f"  {path}: {reason}")

run_log.log(f"Date sources: {date_extraction_stats['exif']} EXIF, "
            f"{date_extraction_stats['filename']} filename, "
            f"{date_extraction_stats['mtime']} mtime, "
            f"{date_extraction_stats['unknown']} unknown")
emit_json("classification_dates", exif=date_extraction_stats['exif'],
          filename=date_extraction_stats['filename'],
          mtime=date_extraction_stats['mtime'],
          unknown=date_extraction_stats['unknown'],
          extraction_failures=len(failed_date_extraction))
```

**Impact:** Support can now see date source breakdown and which files had issues.

---

### Gap 2: Verification Failures Don't Distinguish Root Causes

**Files:**
- `chronoframe/io.py:39-45` (verify_copy silently returns False)
- `chronoframe/io.py:150-163` (process_single_file silently returns None)
- `chronoframe/core.py:1018-1026` (verification failure handling)

**Current Code:**
```python
def verify_copy(src_path, dst_path, expected_hash):
    try:
        actual = fast_hash(dst_path)
        return actual == expected_hash
    except OSError:
        return False  # ← Could be: permission denied, file missing, I/O error, symlink
```

**Problems:**
- Verification failures could be due to:
  1. **Real mismatch** — file data corrupted (genuine concern)
  2. **Permission denied** — destination exists but user can't read (security/ACL issue)
  3. **File missing** — destination was deleted mid-operation (filesystem race)
  4. **I/O error** — disk error, bad sectors (hardware issue)
  5. **Symlink** — destination became symlink (attack/malfunction)

- All returned as `False` with no context

- When verification fails (core.py:1018-1026), log only shows:
  ```
  emit_json("error", message=f"Verification failed: {src_path} -> {result}")
  ```

**What Customer Support Needs:**
- Is this a genuine data corruption issue or a transient I/O error?
- Should user retry or escalate?
- Is there a pattern (all verification failures, or specific destination)?

**Proposed Fix:**

In `io.py`, change verify_copy to return error reason:
```python
def verify_copy(src_path, dst_path, expected_hash):
    """Re-hash the destination file and compare to expected hash.
    
    Returns: (bool, Optional[str])
      (True, None) — hashes match
      (False, "mismatch") — hash differs (data corruption)
      (False, "permission_denied") — can't read destination
      (False, "not_found") — destination file missing
      (False, "io_error:<errno>") — disk I/O error
      (False, "symlink") — destination is symlink
      (False, "not_regular_file") — destination is directory or special
    """
    try:
        if not os.path.exists(dst_path):
            return False, "not_found"
        if os.path.islink(dst_path):
            return False, "symlink"
        st = os.lstat(dst_path)
        if not stat_module.S_ISREG(st.st_mode):
            return False, "not_regular_file"
        actual = fast_hash(dst_path)
        if actual == expected_hash:
            return True, None
        else:
            return False, "mismatch"
    except PermissionError:
        return False, "permission_denied"
    except OSError as e:
        return False, f"io_error:{e.errno}"
```

In `core.py`, handle each reason:
```python
if verify:
    match, reason = verify_copy(src_p, result, h)
    if not match:
        try:
            os.remove(result)
        except OSError as cleanup_err:
            run_log.warn(f"Failed to remove unverified copy: {result}: {cleanup_err}")
        
        if reason == "not_found":
            msg = f"Destination vanished after copy (filesystem race?): {src_p} → {result}"
            emit_json("error", message=msg, type="verification_not_found")
        elif reason == "symlink":
            msg = f"Destination became symlink (possible attack): {src_p} → {result}"
            emit_json("error", message=msg, type="verification_symlink")
        elif reason == "permission_denied":
            msg = f"Permission denied reading destination (ACL issue?): {src_p} → {result}"
            emit_json("error", message=msg, type="verification_permission")
        elif reason == "mismatch":
            msg = f"Hash mismatch (data corruption): {src_p} → {result}"
            emit_json("error", message=msg, type="verification_mismatch")
        else:
            msg = f"Verification failed ({reason}): {src_p} → {result}"
            emit_json("error", message=msg, type=f"verification_{reason}")
        
        if run_log:
            run_log.error(msg)
        verify_failures += 1
        # ... rest of failure handling
```

**Impact:** Support can now distinguish transient I/O errors (retry) from permanent issues (investigate hardware/permissions/security).

---

### Gap 3: Process_single_file Hash Failures Silent

**File:** `chronoframe/io.py:150-163`

**Current Code:**
```python
def process_single_file(path, cached_data):
    try:
        st = os.lstat(path)
        if stat_module.S_ISLNK(st.st_mode) or not stat_module.S_ISREG(st.st_mode):
            return None, 0, 0, False
        size = st.st_size
        mtime = st.st_mtime
        # ... cache check ...
        h = fast_hash(path, known_size=size)
        return h, size, mtime, True
    except OSError:
        return None, 0, 0, False  # ← All failures return None
```

**Problems:**
- Called during `build_dest_index()` when scanning destination directory
- If hashing fails (permission denied, I/O error, file deleted), returns None
- Caller doesn't know if it was a symlink, permission issue, or transient error
- Caller then skips file from dedup index without logging why

**What Customer Support Needs:**
- Which destination files couldn't be hashed (permission issue, I/O error)
- If systematic (all files in folder), suggests ACL or network issue
- If scattered, suggests transient I/O or bad sectors

**Proposed Fix:**

```python
def process_single_file(path, cached_data, on_error=None):
    """Hash a single file, using cache if size+mtime unchanged.
    
    Returns: (hash_or_none, size, mtime, was_recomputed)
    
    on_error: Optional callback(path, error_type, exception) for logging
    """
    try:
        st = os.lstat(path)
        if stat_module.S_ISLNK(st.st_mode):
            if on_error:
                on_error(path, 'symlink', None)
            return None, 0, 0, False
        if not stat_module.S_ISREG(st.st_mode):
            if on_error:
                on_error(path, 'not_regular_file', None)
            return None, 0, 0, False
        # ... cache check ...
        h = fast_hash(path, known_size=size)
        return h, size, mtime, True
    except PermissionError as e:
        if on_error:
            on_error(path, 'permission_denied', e)
        return None, 0, 0, False
    except OSError as e:
        if on_error:
            on_error(path, 'io_error', e)
        return None, 0, 0, False
```

Then in `build_dest_index()`:
```python
hash_errors = 0
symlink_skips = 0
permission_errors = {}
io_errors = {}

def on_hash_error(path, error_type, exc):
    global hash_errors, symlink_skips, permission_errors, io_errors
    hash_errors += 1
    if error_type == 'symlink':
        symlink_skips += 1
    elif error_type == 'permission_denied':
        permission_errors[path] = str(exc)
    elif error_type == 'io_error':
        io_errors[path] = str(exc)

# During indexing
for src_file in src_files:
    h, size, mtime, recomputed = process_single_file(src_file, cached.get(src_file), on_error=on_hash_error)
    # ... existing code ...

# After loop, log issues
if permission_errors:
    msg = f"Destination hash failures due to permission denied ({len(permission_errors)} files)"
    run_log.warn(msg)
    for path in list(permission_errors.keys())[:5]:
        run_log.warn(f"  {path}")
        
if io_errors:
    msg = f"Destination hash failures due to I/O errors ({len(io_errors)} files)"
    run_log.warn(msg)
    for path in list(io_errors.keys())[:5]:
        run_log.warn(f"  {path}")

emit_json("dest_index_errors", 
          total_errors=hash_errors,
          symlinks=symlink_skips,
          permission_denied=len(permission_errors),
          io_errors=len(io_errors))
```

**Impact:** Support can see which destination files couldn't be indexed and why, identifying ACL/permission/hardware issues.

---

### Gap 4: Collision Handling Limits Not Logged as Warning

**File:** `chronoframe/io.py:124-132`

**Current Code:**
```python
original_dst = dst
counter = 1
while os.path.exists(dst):
    if counter > MAX_COLLISIONS:  # MAX_COLLISIONS = 9999
        raise OSError(errno.EEXIST,
                      f"Too many collisions for destination path: {original_dst}")
    base, ext = os.path.splitext(original_dst)
    dst = f"{base}_collision_{counter}{ext}"
    counter += 1
```

**Problems:**
- Only raises error when collision count exceeds 9999
- No warning when approaching limit (e.g., collision_5000)
- User might have a destination directory with thousands of existing files with collision suffixes
- This indicates:
  1. **Copy loop issue** — file copied multiple times (user clicked retry repeatedly)
  2. **Destination not cleaned** — previous run left many collision files
  3. **Malicious collision attack** — attacker created many collision-named files

**What Customer Support Needs:**
- If user hits "too many collisions" error, what happened?
- Why are there so many collision files?
- Is this safe to retry, or is something broken?

**Proposed Fix:**

```python
# In safe_copy_atomic, track collision attempts
original_dst = dst
counter = 1
collision_warned_at = [1000, 5000, 9000]  # Log warnings at these thresholds
while os.path.exists(dst):
    if counter > MAX_COLLISIONS:
        # Don't just raise — log context first
        msg = f"Destination collision limit reached ({MAX_COLLISIONS}) for file. " \
              f"Too many files exist with same name: {original_dst}"
        # This will be caught and logged in execute_jobs
        raise OSError(errno.EEXIST, msg)
    
    if counter in collision_warned_at:
        # Log at module level (gets picked up by wrapper)
        import sys
        print(f"Warning: destination has {counter} existing collision files: {original_dst}",
              file=sys.stderr)
    
    base, ext = os.path.splitext(original_dst)
    dst = f"{base}_collision_{counter}{ext}"
    counter += 1
```

Then in `execute_jobs()`, capture collision data:
```python
except Exception as e:
    if e.errno == errno.EEXIST and "collision" in str(e):
        collision_msg = f"Destination collision limit hit: {dst_p}. " \
                        f"Check destination directory for many existing files with same name."
        run_log.error(collision_msg)
        emit_json("error", message=collision_msg, type="collision_limit", path=dst_p)
    else:
        run_log.error(f"Copy failed: {src_p} → {dst_p}: {e}")
        emit_json("error", message=f"Copy failed: {src_p} -> {dst_p}: {e}")
```

**Impact:** Support can identify when destination has collision file cleanup issues.

---

### Gap 5: Disk Space Checks Don't Log Pre-flight Results

**File:** `chronoframe/io.py:48-62`

**Current Code:**
```python
def check_disk_space(src_path, dst_dir):
    needed = os.path.getsize(src_path)
    free = shutil.disk_usage(dst_dir).free
    if free < needed + 10 * 1024 * 1024:
        raise OSError(
            errno.ENOSPC,
            f"Insufficient disk space on destination: "
            f"{free // (1024 * 1024)} MB free, {needed // (1024 * 1024)} MB needed",
        )
```

**Problems:**
- Only logs when space is INSUFFICIENT
- No log if check succeeds or is skipped
- If operation fails later with "Disk full", support doesn't know if pre-flight check was:
  - Never called
  - Called but failed silently
  - Called and space was OK at that time (but disk filled up later)

**What Customer Support Needs:**
- Was disk space pre-check performed?
- How much space was available when copy started?
- Did disk fill up during operation, or was there insufficient space to begin with?

**Proposed Fix:**

```python
def check_disk_space(src_path, dst_dir, log_success=False):
    """Check disk space and log results. Raise ENOSPC if insufficient."""
    try:
        needed = os.path.getsize(src_path)
        free = shutil.disk_usage(dst_dir).free
        
        if log_success:
            # Log pre-flight checks to help diagnose later failures
            import sys
            print(f"Disk space check: {free // (1024**3)} GB free, "
                  f"{needed // (1024**2)} MB needed for {os.path.basename(src_path)}",
                  file=sys.stderr)
        
        if free < needed + 10 * 1024 * 1024:
            msg = (f"Insufficient disk space on destination: "
                   f"{free // (1024 * 1024)} MB free, {needed // (1024 * 1024)} MB needed")
            raise OSError(errno.ENOSPC, msg)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            raise
        # For other OSErrors (disk_usage failed), don't raise — let copy fail naturally
        # but log that check was skipped
        import sys
        print(f"Warning: Could not verify destination disk space: {e}", file=sys.stderr)
```

Then in `execute_jobs()`, wrap copy:
```python
try:
    # Log disk space at start of copy phase (once)
    if count == 0:
        import shutil
        dst_dir = os.path.dirname(dst_p)
        free = shutil.disk_usage(dst_dir).free
        total = shutil.disk_usage(dst_dir).total
        run_log.log(f"Destination disk space: {total // (1024**3)} GB total, "
                    f"{free // (1024**3)} GB free at start of transfer")
        emit_json("system_state", disk_total_gb=total // (1024**3), 
                  disk_free_gb=free // (1024**3))
    
    result = safe_copy_atomic(src_p, dst_p)
except OSError as e:
    if e.errno == errno.ENOSPC:
        # Now we know it was disk full, get current state
        import shutil
        try:
            free = shutil.disk_usage(dst_dir).free
            run_log.error(f"Disk full during copy of {src_p}. "
                          f"Free space: {free // (1024**3)} GB")
        except:
            pass
    # ... rest of error handling ...
```

**Impact:** Support can see disk space at operation start and distinguish "disk full from beginning" from "disk filled up during operation".

---

### Gap 6: Symlink Handling Not Distinguished in Logs

**Files:**
- `chronoframe/core.py:623-647` (source discovery)
- `chronoframe/io.py:150-163` (destination processing)

**Current Code:**
```python
# Source discovery
if os.path.islink(src_path):
    symlinks_skipped += 1
    continue

# Destination processing
if stat_module.S_ISLNK(st.st_mode):
    return None, 0, 0, False  # ← Silently returns None
```

**Problems:**
- Symlinks skipped but not logged individually
- Support doesn't know if "file not found" is due to:
  - File truly missing
  - Symlink to missing target
  - Symlink to file outside source directory

**What Customer Support Needs:**
- Why was a file skipped?
- Is symlink broken (dangling) or valid?
- Should user fix symlinks or is this expected?

**Proposed Fix:**

```python
# In source discovery (core.py:623-647)
def _is_safe_symlink(path):
    """Check if symlink target exists and is regular file."""
    try:
        if not os.path.islink(path):
            return False
        target = os.path.realpath(path)
        return os.path.isfile(target)
    except OSError:
        return False

broken_symlinks = []
valid_symlinks = []
for src_path in walk_recursive(src):
    if os.path.islink(src_path):
        if _is_safe_symlink(src_path):
            valid_symlinks.append(src_path)
        else:
            broken_symlinks.append(src_path)
        symlinks_skipped += 1
        continue
    # ... rest of file processing ...

# Log results
if broken_symlinks:
    run_log.warn(f"Skipped {len(broken_symlinks)} broken symlinks")
    for path in broken_symlinks[:5]:
        run_log.warn(f"  {path} -> (broken target)")

if valid_symlinks:
    run_log.warn(f"Skipped {len(valid_symlinks)} symlinks (use --follow-symlinks to include)")
    for path in valid_symlinks[:5]:
        target = os.path.realpath(path)
        run_log.warn(f"  {path} -> {target}")

emit_json("symlinks_skipped",
          total=symlinks_skipped,
          broken=len(broken_symlinks),
          valid=len(valid_symlinks))
```

**Impact:** Support can see symlink breakdown and advise on whether files are missing or just symlinked.

---

### Gap 7: Temporary File Cleanup Not Tracked

**File:** `chronoframe/io.py:65-83`

**Current Code:**
```python
def cleanup_tmp_files(dst_dir):
    cleaned = 0
    for root, dirs, fnames in os.walk(dst_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if _CHRONOFRAME_TMP_RE.match(fname):
                path = os.path.join(root, fname)
                try:
                    os.remove(path)
                    cleaned += 1
                except OSError:
                    pass  # ← Silently ignores cleanup failures
    return cleaned
```

**Problems:**
- Cleanup failures ignored — might indicate:
  - Permission issue (destination is read-only)
  - Files in use (still being copied?)
  - Symlinks instead of regular files (security issue)
- Returns only count of successfully cleaned, not failed

**What Customer Support Needs:**
- How many orphaned tmp files were found?
- How many were successfully cleaned?
- Were there any cleanup failures, and why?

**Proposed Fix:**

```python
def cleanup_tmp_files(dst_dir, on_error=None):
    """Remove Chronoframe's own orphaned .tmp files.
    
    on_error: Optional callback(path, error) for logging failures
    
    Returns: (cleaned_count, failed_count)
    """
    cleaned = 0
    failed = 0
    failed_paths = {}
    
    for root, dirs, fnames in os.walk(dst_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if _CHRONOFRAME_TMP_RE.match(fname):
                path = os.path.join(root, fname)
                try:
                    os.remove(path)
                    cleaned += 1
                except OSError as e:
                    failed += 1
                    failed_paths[path] = str(e)
                    if on_error:
                        on_error(path, e)
    
    return cleaned, failed, failed_paths
```

Then in `main()` before transfer:
```python
cleaned, failed, failed_paths = cleanup_tmp_files(dst)
if cleaned > 0:
    msg = f"Cleaned {cleaned} orphaned temporary files"
    run_log.log(msg)
    emit_json("cleanup_complete", cleaned=cleaned, failed=failed)

if failed > 0:
    msg = f"Failed to clean {failed} temporary files (may be in use or permission issue)"
    run_log.warn(msg)
    for path in list(failed_paths.keys())[:3]:
        run_log.warn(f"  {path}: {failed_paths[path]}")
    emit_json("cleanup_errors", failed=failed, paths=list(failed_paths.keys())[:10])
```

**Impact:** Support can see if orphaned files are preventing retries, and whether there's a permission/in-use issue.

---

### Gap 8: Retry Logic Not Logged

**File:** `chronoframe/io.py:104-105` (tenacity retry decorator)

**Current Code:**
```python
@retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, min=1, max=10),
       retry=retry_if_exception(_is_retryable_error), reraise=True)
def safe_copy_atomic(src, dst):
    # ...
```

**Problems:**
- Retry logic is transparent — logs don't show if/why retries happened
- If copy eventually fails after 5 retries, support doesn't know:
  - Was it transient (failed, retried, failed again)?
  - Or permanent (failed immediately all 5 times)?
  - How long did retries take?

**What Customer Support Needs:**
- Did operation fail immediately or after retries?
- What errors triggered retries (network timeout, temp I/O error)?
- If all 5 retries failed with same error, likely permanent issue

**Proposed Fix:**

```python
def _retryable_copy_with_logging(src, dst, run_log=None):
    """Wrapper around safe_copy_atomic that logs retry attempts."""
    import time
    attempt = 1
    max_attempts = 5
    
    while attempt <= max_attempts:
        try:
            result = safe_copy_atomic(src, dst)
            if attempt > 1 and run_log:
                run_log.log(f"Copy succeeded on attempt {attempt}/{max_attempts}: {src}")
            return result
        except Exception as e:
            if _is_retryable_error(e):
                if attempt < max_attempts:
                    wait_time = min(10, 2 ** (attempt - 1))  # Exponential backoff
                    if run_log:
                        run_log.warn(f"Copy attempt {attempt}/{max_attempts} failed (retrying in {wait_time}s): {src}: {e}")
                    time.sleep(wait_time)
                    attempt += 1
                else:
                    if run_log:
                        run_log.error(f"Copy failed after {max_attempts} retries: {src}: {e}")
                    raise
            else:
                # Non-retryable error
                if run_log:
                    run_log.error(f"Copy failed (permanent error): {src}: {e}")
                raise
```

Then in `execute_jobs()`, use wrapper instead of direct call:
```python
try:
    result = _retryable_copy_with_logging(src_p, dst_p, run_log=run_log)
except Exception as e:
    # ... existing error handling ...
```

**Impact:** Support can see if operation was retried and why, helping distinguish transient from permanent failures.

---

### Gap 9: Transaction Failures During Database Operations

**File:** `chronoframe/database.py` (all write methods)

**Current:** We added rollback and error logging, but we should enhance error messages.

**Proposed Enhancement:**

```python
def save_batch(self, type_id, updates):
    if not updates:
        return
    with self._lock:
        try:
            self.conn.executemany("REPLACE INTO FileCache (id, path, hash, size, mtime) VALUES (?, ?, ?, ?, ?)",
                                  [(type_id, p, h, s, m) for p, h, s, m in updates])
            self.conn.commit()
        except sqlite3.IntegrityError as e:
            self.conn.rollback()
            import sys
            print(f"Error: Database constraint violation while saving {len(updates)} files: {e}", file=sys.stderr)
            raise
        except sqlite3.DatabaseError as e:
            self.conn.rollback()
            import sys
            print(f"Error: Database error while saving {len(updates)} files (corrupted database?): {e}", file=sys.stderr)
            raise
        except Exception as e:
            self.conn.rollback()
            import sys
            print(f"Error: Failed to save cache batch ({len(updates)} files): {e}", file=sys.stderr)
            raise
```

**Impact:** Distinguishes database corruption from constraint violations, helping diagnose issues.

---

## Logging Best Practices

### 1. Every Error Should Answer:
- **What failed?** (operation, file, system call)
- **Why?** (error code, reason, root cause)
- **What was being done?** (context, file name, destination)
- **What can user do?** (retry, fix permissions, clean up, escalate)

### 2. Count Errors by Category
```python
errors = {
    'permission_denied': [],
    'not_found': [],
    'io_error': [],
    'corruption': [],
}
# ... then log summary and details
```

### 3. Log System State at Failure
```python
import psutil
disk = psutil.disk_usage(path)
memory = psutil.virtual_memory()
print(f"System state at failure: {disk.free} GB free, {memory.available} MB RAM")
```

### 4. Distinguish Transient from Permanent
```python
if e.errno in {errno.ETIMEDOUT, errno.EAGAIN}:
    run_log.warn(f"Transient error (will retry): {e}")
else:
    run_log.error(f"Permanent error: {e}")
```

### 5. Log Each Phase Entry/Exit
```python
run_log.log(f"Starting phase: {phase_name}")
# ... do work ...
run_log.log(f"Completed phase: {phase_name}")
```

---

## Summary of Proposed Changes

| Gap | File | Severity | Effort | Impact |
|-----|------|----------|--------|--------|
| Date extraction failures | core.py:745-754 | High | 1 hour | Support can see which files failed date extraction and why |
| Verification failures | io.py, core.py | Critical | 2 hours | Support can distinguish data corruption from I/O errors |
| Hash failures in indexing | io.py:150-163 | High | 1 hour | Support can see which destination files couldn't be indexed |
| Collision limit warnings | io.py:124-132 | Medium | 30 min | Support can diagnose collision file buildup |
| Disk space logging | io.py:48-62 | Medium | 45 min | Support can see disk state at operation start/failure |
| Symlink breakdown | core.py, io.py | Medium | 1 hour | Support can see symlink counts and which are broken |
| Tmp file cleanup tracking | io.py:65-83 | Medium | 30 min | Support can see if cleanup failures block retries |
| Retry logic transparency | io.py:104 | Low | 1 hour | Support can see transient vs. permanent failures |
| Database error details | database.py | Medium | 30 min | Support can distinguish corruption from constraint violations |

**Total Estimated Effort:** ~9 hours

**Priority Order:** Critical gaps first (verification), then high-impact (date extraction, hashing), then medium (cleanup, symlinks).

---

## Next Steps

1. **Implement Gap #2 (Verification)** — Most critical for support diagnostics
2. **Implement Gap #1 (Date Extraction)** — High user impact
3. **Implement Gap #3 (Hash Failures)** — Necessary for destination index trust
4. **Add integration tests** — Verify logging works in realistic scenarios
5. **Document logging format** — Create reference for support team

