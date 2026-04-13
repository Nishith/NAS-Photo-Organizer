import os
import shutil
import hashlib
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type


def fast_hash(path, known_size=None):
    """Fast partial hash: size + blake2b(first 512KB + last 512KB)."""
    size = known_size if known_size is not None else os.path.getsize(path)
    h = hashlib.blake2b()
    h.update(str(size).encode())
    chunk = 512 * 1024
    with open(path, 'rb') as f:
        h.update(f.read(chunk))
        if size > chunk:
            f.seek(-min(chunk, size - chunk), 2)
            h.update(f.read(chunk))
    return f"{size}_{h.hexdigest()}"


def verify_copy(src_path, dst_path, expected_hash):
    """Re-hash the destination file and compare to expected hash. Returns True if match."""
    try:
        actual = fast_hash(dst_path)
        return actual == expected_hash
    except OSError:
        return False


def cleanup_tmp_files(dst_dir):
    """Remove orphaned .tmp files left by interrupted copies. Returns count removed."""
    cleaned = 0
    for root, dirs, fnames in os.walk(dst_dir):
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for fname in fnames:
            if fname.endswith('.tmp'):
                path = os.path.join(root, fname)
                try:
                    os.remove(path)
                    cleaned += 1
                except OSError:
                    pass
    return cleaned


@retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, min=1, max=10),
       retry=retry_if_exception_type(OSError))
def safe_copy_atomic(src, dst):
    """Copy src to dst atomically: write to .tmp, fsync, rename."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    dst_dir = os.path.dirname(dst)

    # Check available disk space before attempting copy (10 MB safety buffer)
    try:
        needed = os.path.getsize(src)
        free = shutil.disk_usage(dst_dir).free
        if free < needed + 10 * 1024 * 1024:
            raise OSError(
                f"Insufficient disk space on destination: {free // (1024*1024)} MB free, "
                f"{needed // (1024*1024)} MB needed"
            )
    except OSError as e:
        if "Insufficient disk space" in str(e):
            raise
        # getsize or disk_usage failed for another reason; proceed and let copy fail naturally

    original_dst = dst
    counter = 1
    while os.path.exists(dst):
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
        raise e


def process_single_file(path, cached_data):
    """Hash a single file, using cache if size+mtime unchanged."""
    try:
        st = os.stat(path)
        size = st.st_size
        mtime = st.st_mtime
        if cached_data and cached_data["size"] == size and abs(cached_data["mtime"] - mtime) < 0.001:
            return cached_data["hash"], size, mtime, False
        h = fast_hash(path, known_size=size)
        return h, size, mtime, True
    except OSError:
        return None, 0, 0, False
