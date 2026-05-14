import errno
import os
import re
import stat as stat_module
import shutil
import hashlib
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception

HASH_CHUNK_SIZE = 8 * 1024 * 1024
MAX_COLLISIONS = 9999

# Matches Chronoframe's own .tmp files only — covers every variant our copy
# pipelines produce. Update both sides if filename conventions change:
#   - chronoframe/io.py: safe_copy_atomic() temp name (line ~119)
#   - ui/Sources/ChronoframeCore/TransferExecutor.swift: chronoframeTmpPattern
_CHRONOFRAME_TMP_RE = re.compile(
    r'^(?:\d{4}-\d{2}-\d{2}|Unknown)_\d+(?:_collision_\d+)?'
    r'\.[a-zA-Z0-9]+(?:\.[0-9a-fA-F-]{36})?\.tmp$'
)


def fast_hash(path, known_size=None):
    """Stream a full-file blake2b hash prefixed with size for collision-resistant identity."""
    st = os.lstat(path)
    if stat_module.S_ISLNK(st.st_mode) or not stat_module.S_ISREG(st.st_mode):
        raise OSError(errno.EINVAL, f"Refusing to hash non-regular file: {path}")
    size = known_size if known_size is not None else st.st_size
    h = hashlib.blake2b()
    h.update(str(size).encode())
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(HASH_CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
    return f"{size}_{h.hexdigest()}"


def verify_copy(src_path, dst_path, expected_hash):
    """Re-hash the destination file and compare to expected hash.

    Returns: (bool, Optional[str])
      (True, None) — hashes match
      (False, "mismatch") — hash differs (data corruption)
      (False, "not_found") — destination file missing
      (False, "symlink") — destination is symlink
      (False, "not_regular_file") — destination is directory or special
      (False, "permission_denied") — can't read destination
      (False, "io_error") — disk I/O error
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
    except OSError:
        return False, "io_error"


def check_disk_space(src_path, dst_dir):
    """Raise OSError(ENOSPC) if destination lacks free space for src_path.

    Uses a 10 MB safety buffer beyond the file size. Silently ignores
    stat/disk_usage failures (non-ENOSPC) so the caller can proceed and let
    the copy fail naturally if something else is wrong.
    """
    needed = os.path.getsize(src_path)
    free = shutil.disk_usage(dst_dir).free
    if free < needed + 10 * 1024 * 1024:
        raise OSError(
            errno.ENOSPC,
            f"Insufficient disk space on destination: "
            f"{free // (1024 * 1024)} MB free, {needed // (1024 * 1024)} MB needed",
        )


def cleanup_tmp_files(dst_dir):
    """Remove Chronoframe's own orphaned .tmp files from interrupted copies.

    Only files matching Chronoframe's destination naming pattern are removed.
    Foreign .tmp files (from other applications using the same directory) are
    left alone.
    """
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
                    pass
    return cleaned


def _is_retryable_error(exc):
    """Return True for transient OSErrors that are worth retrying.

    Permanent local-path errors should fail fast so stale queue entries do not
    stall large resumed runs.
    """
    non_retryable_errnos = {
        errno.ENOSPC,
        errno.ENOENT,
        errno.ENOTDIR,
        errno.EISDIR,
        errno.EINVAL,
        errno.EACCES,
        errno.EPERM,
    }
    return isinstance(exc, OSError) and getattr(exc, 'errno', None) not in non_retryable_errnos


@retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, min=1, max=10),
       retry=retry_if_exception(_is_retryable_error), reraise=True)
def safe_copy_atomic(src, dst):
    """Copy src to dst atomically: write to .tmp, fsync, rename.

    Pre-flight checks disk space (raises ENOSPC immediately, not retried).
    Collision-safe: appends _collision_N suffix if dst already exists.
    """
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    dst_dir = os.path.dirname(dst)

    # Check available disk space (10 MB buffer). Non-space OSErrors are ignored
    # here — the copy itself will raise them if needed.
    try:
        check_disk_space(src, dst_dir)
    except OSError as e:
        if e.errno == errno.ENOSPC:
            raise
        # getsize / disk_usage failed for another reason; proceed

    original_dst = dst
    counter = 1
    while os.path.exists(dst):
        if counter > MAX_COLLISIONS:
            raise OSError(errno.EEXIST,
                          f"Too many collisions for destination path: {original_dst}")
        base, ext = os.path.splitext(original_dst)
        dst = f"{base}_collision_{counter}{ext}"
        counter += 1

    tmp_dst = dst + ".tmp"
    try:
        shutil.copy2(src, tmp_dst)
        with open(tmp_dst, 'rb') as f:
            os.fsync(f.fileno())
        os.rename(tmp_dst, dst)
        return dst
    except Exception as e:
        if os.path.exists(tmp_dst):
            try:
                os.remove(tmp_dst)
            except OSError:
                pass
        raise


def process_single_file(path, cached_data):
    """Hash a single file, using cache if size+mtime unchanged.

    Returns: (hash_or_none, size, mtime, was_recomputed, error_reason_or_none)
      error_reason: None if success, else "symlink", "not_regular_file", "permission_denied",
                   "not_found", "io_error", or error message
    """
    try:
        st = os.lstat(path)
        if stat_module.S_ISLNK(st.st_mode):
            return None, 0, 0, False, "symlink"
        if not stat_module.S_ISREG(st.st_mode):
            return None, 0, 0, False, "not_regular_file"
        size = st.st_size
        mtime = st.st_mtime
        if cached_data and cached_data["size"] == size and abs(cached_data["mtime"] - mtime) < 0.001:
            return cached_data["hash"], size, mtime, False, None
        h = fast_hash(path, known_size=size)
        return h, size, mtime, True, None
    except FileNotFoundError:
        return None, 0, 0, False, "not_found"
    except PermissionError:
        return None, 0, 0, False, "permission_denied"
    except OSError as e:
        return None, 0, 0, False, f"io_error:{e.errno}"
