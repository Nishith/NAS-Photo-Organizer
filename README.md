# NAS Photo Organizer v3 (Enterprise Edition)

> **TL;DR:** A high-performance Python package built to recursively scan, identify, deduplicate, and organize massive photo/video datasets over hostile network configurations (NAS, SMB, AFP) without data loss. It transfers media into an immaculate `YYYY/MM/DD` folder structure utilizing Write-Ahead Logging (WAL) SQLite databases, `concurrent.futures` multithreading, and `BLAKE2b` hardware-accelerated chunk-hashing. It survives network drops natively via exponential backoff retries and atomic OS disk flushing (`fsync`).

---

## 🚀 Architecture Overview

This project evolved from a monolithic script into an enterprise toolkit tailored exclusively for extreme scale and fault tolerance when dealing with Network Attached Storage devices dropping packets:

- **Atomic Network File Synchronization:** Avoids dreaded "corrupted partial file" scenarios. Byte transfers are spooled into `.ext.tmp` buffers securely. Only when the host hardware reports a successful physical spindle `os.fsync()` cache flush will the file rename lock natively commit over the network.
- **SQLite WAL & State Machine Queue:** No more starting from scratch if processing hundreds of thousands of files crashes. Your index arrays dump safely into an SQLite database (`.organize_cache.db`). The active transfers execute sequentially off an idempotent robust `CopyJobs` queue using isolated Database Write-Ahead Logging schemas. Power outage? Just turn the script back on and it resumes hashing precisely where it died.
- **Multithreaded I/O Backoffs:** Disk latency and spotty connection drops are shielded by native concurrent thread pools looping over dynamic `tenacity` exponential network backoffs. 
- **BLAKE2b Verification Hashing:** Verifies strict byte-uniqueness utilizing non-cryptographic `hashlib.blake2b()` native streaming, safely replacing outdated MD5 limits.

## 🗂 Data Structure Rules

1. **Zero Deletion:** Operations exist solely in `Read` and `Copy`. The source environment is absolutely never modified or deleted. 
2. **Global Deduplication:** It aggressively indexes destination drives. Identical files (matching by file size and chunked hash digests) found redundantly strewn across the source drive bypass the unified timeline and route seamlessly into an isolated `Duplicate/YYYY/MM/DD/` bucket to keep chronological folders completely sterile.

#### Date Exaction Flow (Graceful Degradation)
1. **EXIF Base Data:** It utilizes standard `exifread` to extract `EXIF DateTimeOriginal`, pulling exact camera-shutter timings natively. 
2. **Regex Parsing:** Useful for stripped or encrypted files sent natively via WhatsApp/Android (e.g. `IMG_20240101_XXX`).
3. **Spotlight APIs:** Runs Mac native `mdls` subprocesses to analyze deeper network-layer OS metadata limits for tricky formats like `.MOV`.
4. **Modified Times:** System bounds fallback mapping strictly as a last resort.

If the file refuses to yield a date, it isolates gently in an `Unknown_Date/` bin for manual user resolution.

## 💻 Usage & Installation 

To prevent polluting your `sys.path`, simply boot the wrapper launcher `organize_nas.py` sitting at the root logic. It auto-resolves your Python dependencies inside your environment, checks for `requirements.txt` (`tenacity`, `exifread`), securely installs them, and routes internally to the engine.

```bash
python3 organize_nas.py --source /Volumes/NAS/Unsorted --dest /Volumes/NAS/Organized
```

### CLI Arguments

| Flag | Operation Effect |
| :--- | :--- |
| `--dry-run` | Strictly constructs a target database, scans duplicates, establishes chunked memory maps, and previews the file sequences on standard output without executing copy-writes. |
| `-y` or  `--yes` | Silences the manual user prompt buffer asking for `Proceed to Copy Database? [Y/n]` (ideal for unmonitored crontabs). |
| `--verify` | Enforces a dual-hash post-flush re-verification layer immediately checking if the written drive bytes identically match the memory payload bytes over the wire. |
| `--rebuild-cache` | Triggers a hard deletion wiping out `.organize_cache.db` arrays, forcibly resolving the metadata over the entire hierarchy from byte 0. |

## 🧪 Validations

We maintain a dynamic Python `unittest` suite injecting temporary local DB environments masking NAS limits locally to guarantee sequences never destruct identically indexed buffers. 

```bash
python3 -m unittest test_organize_nas.py -v
```
