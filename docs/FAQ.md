# Frequently Asked Questions

## Safety & Originals

**Q: Will Chronoframe delete or modify my original photos?**

A: No. Chronoframe only *reads* your source folder. Your originals are never moved, modified, or deleted. You control when (and whether) to delete the source folder.

**Q: What if something goes wrong during the transfer?**

A: Chronoframe writes files atomically (to a temporary location, then renames them into place). If the transfer is interrupted, partially-copied files are left untouched. Use **History** to review what was copied, and **Revert** if needed.

**Q: Can I undo an organize operation?**

A: Yes. Open **Organize** → **History** and select the transfer you want to undo. Click **Revert** and Chronoframe will delete only the files it copied (not anything that was already in the destination). Revert verifies content hashes, so it won't delete files if they've been modified since the transfer.

**Q: How do I know what Chronoframe will copy?**

A: Preview shows the exact plan before transfer. You can review the plan, edit uncertain dates, and even skip items in the Review tab. The actual transfer uses the same plan you approved.

---

## Performance & System Requirements

**Q: What are the system requirements?**

A: macOS 13.0 or later. Chronoframe works on Intel and Apple Silicon Macs.

**Q: How much disk space do I need?**

A: Enough for your destination folder to hold copies of your source files. Chronoframe doesn't compress; it copies files as-is. You'll need roughly the same amount of free space as the size of your source folder.

**Q: Why is the first scan taking so long?**

A: Scanning reads metadata, computes content hashes, and resolves dates. Large libraries (50K+ photos) can take 5–10 minutes. Once done, Preview rebuilds are faster because destination metadata is cached in `.organize_cache.db`.

**Q: Can I speed things up?**

A: Yes—
- Use **Settings** → **Performance** to increase worker threads
- Use `--fast-dest` in CLI mode to skip rescanning the destination
- Pre-filter your source folder to smaller batches

---

## Dates & Organization

**Q: How does Chronoframe figure out photo dates?**

A: It checks in this order:
1. Photo metadata (EXIF capture time)
2. Filename patterns (e.g., `2024-01-15_photo.jpg`)
3. File creation date (from the filesystem)
4. File modification date (fallback)
5. **Your override** (if you edit it in Review)

Each source gets a confidence level (high, medium, low, unknown). Photos with unknown dates go to `Unknown_Date/` unless you provide an override.

**Q: Can I edit dates before organizing?**

A: Yes. In the **Review** tab during the Preview, you can click on an item's date and edit it. Chronoframe saves your correction and rebuilds the preview with your changes.

**Q: What does "Low Confidence Date" mean?**

A: It means Chronoframe isn't sure about the date—maybe the filename looks like a date but doesn't match metadata, or it's relying on filesystem dates. You can accept it or override it in Review.

**Q: Can I use custom event names?**

A: If your folder layout is `YYYY/Mon/Event`, Chronoframe suggests event names based on proximity and source folder names. You can accept suggestions in Review, or manually edit them.

---

## Features & Capabilities

**Q: What formats does Chronoframe support?**

A: Photos (JPG, PNG, HEIF, RAW, etc.) and videos (MP4, MOV, etc.). If your OS can read it, Chronoframe can organize it.

**Q: Can Chronoframe find duplicate photos?**

A: Yes. Use the **Deduplicate** workspace:
- Finds **exact copies** using content hashing (BLAKE2b)
- Finds **similar shots** using AI vision analysis
- Detects **burst groups** using capture-time proximity
- Recognizes **RAW+JPEG pairs** and **Live Photo pairs**

**Q: Can I organize into a folder that already has photos?**

A: Yes. Chronoframe detects existing files and won't overwrite them. If a destination collision happens, it gives the new file a distinct name (e.g., `photo_2.jpg`).

**Q: Does Chronoframe work with cloud drives (iCloud, Google Photos, OneDrive)?**

A: Yes, but **slowly**. Cloud drives aren't optimized for the file operations Chronoframe does. Use local or external drives for best performance.

---

## Common Issues

**Q: Chronoframe is asking for permission to access a folder. Why?**

A: macOS requires apps to ask permission before reading folders outside your home directory (like external drives). Click **Allow** and choose the folder.

**Q: The app says "Permission Denied" for some files.**

A: Chronoframe can't read every file in your source folder. This might be because:
- The file is locked (right-click → Get Info → check "Locked")
- Another app is using the file
- The file system is read-only
- The file is corrupted

You can review these errors in the Review tab or History logs.

**Q: Deduplicate didn't find duplicates I know exist.**

A: Chronoframe uses **content hashing** (not filename matching). Two files are duplicates only if their bytes are identical. If you have:
- Compressed differently (e.g., JPEG quality settings)
- Different metadata but same image data
- Very similar but not identical

…they won't match. You can adjust similarity thresholds in Deduplicate settings (strict, balanced, loose).

**Q: Can I organize to the same folder as source?**

A: Not recommended. It's confusing and risky. Always use a different destination folder.

---

## Advanced

**Q: Can I use Chronoframe from the command line?**

A: Yes. The Python CLI is at the repo root:

```bash
# Preview only
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized --dry-run

# Copy files
python3 chronoframe.py --source ~/Photos/Unsorted --dest ~/Photos/Organized

# Revert
python3 chronoframe.py --revert ~/Photos/Organized/.organize_logs/audit_receipt_*.json
```

See the [README](../README.md#command-line) for all flags.

**Q: Can I automate repeated runs?**

A: Yes. Save a **Profile** in the app with your source and destination folders. Profiles show up in Setup for one-click organization.

**Q: Where does Chronoframe store its data?**

A: Inside your destination folder:
- `.organize_cache.db` — metadata cache, review edits, dedupe cache
- `.organize_logs/` — transfer logs, receipts, and reports

You can safely delete these to free space; Chronoframe will recreate them next time.

---

**Still have questions?** Check the full [README](../README.md) or review the [Architecture](../README.md#architecture) section.
