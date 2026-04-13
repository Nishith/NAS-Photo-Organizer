import os
import shutil
import hashlib
from tenacity import retry, stop_after_attempt, wait_exponential


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


@retry(stop=stop_after_attempt(5), wait=wait_exponential(multiplier=1, min=1, max=10))
def safe_copy_atomic(src, dst):
    """Copy src to dst atomically: write to .tmp, fsync, rename."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        base, ext = os.path.splitext(dst)
        dst = f"{base}_collision{ext}"

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
