import os
import re
import subprocess
from datetime import datetime

try:
    import exifread
    HAS_EXIFREAD = True
except ImportError:
    HAS_EXIFREAD = False

PHOTO_EXTS = {'.jpg', '.jpeg', '.heic', '.png', '.gif', '.bmp', '.tiff', '.tif',
              '.dng', '.nef', '.cr2', '.arw', '.raf', '.orf'}
VIDEO_EXTS = {'.mov', '.mp4', '.m4v', '.avi', '.mkv', '.wmv', '.3gp'}
ALL_EXTS   = PHOTO_EXTS | VIDEO_EXTS
SKIP_FILES = {'organize_nas.py', 'organize_nas_v2.py', 'run_organize.sh',
              'run_new_folder.sh', 'reorganize_structure.sh',
              'nas_profiles.yaml', 'requirements.txt', 'README.md',
              'test_organize_nas.py'}

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

def get_date_mdls(path):
    try:
        if not os.path.isfile(path):
            return None
        result = subprocess.run(['mdls', '-name', 'kMDItemContentCreationDate', '-raw', path],
                                capture_output=True, text=True, timeout=5)
        val = result.stdout.strip()
        if val and val != '(null)':
            dt = datetime.strptime(val[:19], '%Y-%m-%d %H:%M:%S')
            return dt
    except Exception:
        pass
    return None

def get_date_from_filename(path):
    fname = os.path.basename(path)
    patterns = [r'(?:IMG|VID|PANO|BURST|MVIMG)_(\d{8})_\d{6}', r'^(\d{8})_\d{6}', r'_(\d{8})_']
    for pat in patterns:
        m = re.search(pat, fname)
        if m:
            s = m.group(1)
            try:
                dt = datetime(int(s[:4]), int(s[4:6]), int(s[6:8]))
                if 2000 <= dt.year <= 2030: return dt
            except ValueError:
                pass
    return None

def get_file_date(path):
    ext = os.path.splitext(path)[1].lower()
    if HAS_EXIFREAD and ext in PHOTO_EXTS:
        dt = get_date_exifread(path)
        if dt and dt.year > 1971: return dt

    dt = get_date_from_filename(path)
    if dt: return dt

    dt = get_date_mdls(path)
    if dt and dt.year > 1971: return dt

    return datetime.fromtimestamp(os.path.getmtime(path))
