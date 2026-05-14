import os
import re
import subprocess
from datetime import datetime, timezone

try:
    import exifread
    HAS_EXIFREAD = True
except ImportError:
    HAS_EXIFREAD = False

PHOTO_EXTS = {'.jpg', '.jpeg', '.heic', '.png', '.gif', '.bmp', '.tiff', '.tif',
              '.dng', '.nef', '.cr2', '.arw', '.raf', '.orf'}
VIDEO_EXTS = {'.mov', '.mp4', '.m4v', '.avi', '.mkv', '.wmv', '.3gp'}
ALL_EXTS   = PHOTO_EXTS | VIDEO_EXTS
SKIP_FILES = {'chronoframe.py', 'chronoframe_v2.py', 'run_organize.sh',
              'run_new_folder.sh', 'reorganize_structure.sh',
              'profiles.yaml', 'requirements.txt', 'README.md',
              'test_chronoframe.py'}

def get_date_exifread(path):
    try:
        with open(path, 'rb') as f:
            tags = exifread.process_file(f, stop_tag="EXIF DateTimeOriginal", details=False)
            keys = ['EXIF DateTimeOriginal', 'Image DateTime']
            for k in keys:
                if k in tags:
                    val = str(tags[k]).strip()
                    if val and val != "0000:00:00 00:00:00":
                        val = val.replace(":", "-", 2)
                        return datetime.strptime(val[:19], '%Y-%m-%d %H:%M:%S')
    except Exception:
        pass
    return None

def parse_mdls_creation_date(raw_value):
    val = (raw_value or "").strip()
    if not val or val == '(null)':
        return None

    try:
        # mdls emits tz-aware strings like "2024-06-15 19:00:00 +0000".
        # Normalize to UTC and strip tz so date buckets are timezone-stable
        # and match Swift's MediaDateResolver (which uses UTC throughout).
        dt = datetime.strptime(val, '%Y-%m-%d %H:%M:%S %z')
        return dt.astimezone(timezone.utc).replace(tzinfo=None)
    except ValueError:
        pass

    try:
        return datetime.strptime(val[:19], '%Y-%m-%d %H:%M:%S')
    except ValueError:
        return None

def get_date_mdls(path):
    try:
        if not os.path.isfile(path):
            return None
        result = subprocess.run(['mdls', '-name', 'kMDItemContentCreationDate', '-raw', path],
                                capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return None
        return parse_mdls_creation_date(result.stdout)
    except Exception:
        pass
    return None

_FILENAME_DATE_PATTERNS = [
    re.compile(r'(?:IMG|VID|PANO|BURST|MVIMG|PXL)_(\d{8})[_-]\d{6}'),
    re.compile(r'^(?:IMG|VID)-(\d{8})-WA\d+'),
    re.compile(r'^(\d{8})[_-]\d{6}'),
    re.compile(r'(\d{4})-(\d{2})-(\d{2})'),
    re.compile(r'_(\d{8})_'),
]

def get_date_from_filename(path):
    fname = os.path.basename(path)
    for pat in _FILENAME_DATE_PATTERNS:
        m = pat.search(fname)
        if m:
            if len(m.groups()) == 3:
                s = ''.join(m.groups())
            else:
                s = m.group(1)
            try:
                dt = datetime(int(s[:4]), int(s[4:6]), int(s[6:8]))
                if 1900 <= dt.year <= 2100: return dt
            except ValueError:
                pass
    return None

def get_file_date(path):
    """Extract file date, falling back through multiple sources.

    Returns: (datetime, source_method)
      source_method: "exif", "filename", "mdls", "mtime", or None
    """
    ext = os.path.splitext(path)[1].lower()
    if HAS_EXIFREAD and ext in PHOTO_EXTS:
        dt = get_date_exifread(path)
        if dt and 1900 <= dt.year <= 2100: return dt, "exif"

    dt = get_date_from_filename(path)
    if dt: return dt, "filename"

    dt = get_date_mdls(path)
    if dt and 1900 <= dt.year <= 2100: return dt, "mdls"

    try:
        return datetime.fromtimestamp(os.path.getmtime(path), timezone.utc).replace(tzinfo=None), "mtime"
    except OSError:
        return None, None
