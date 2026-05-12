# Troubleshooting Guide

## Installation & Launch

### macOS blocks the app on first launch

**Problem:** You see "Chronoframe cannot be opened because the developer cannot be verified."

**Solution:**
1. Right-click `Chronoframe.app` in Applications
2. Choose **Open**
3. Click **Open** in the confirmation dialog

This is a one-time check.

### App crashes on launch

**Problem:** The app opens briefly then closes.

**Solution:**
1. Make sure you're on **macOS 13 or later** (`About This Mac` → System Report)
2. Try removing and reinstalling the app
3. Check the system logs for crash details (`Console.app` → `Chronoframe`)

If the issue persists, [report it on GitHub](https://github.com/Nishith/Chronoframe/issues).

### Permission denied when launching

**Problem:** "Chronoframe does not have permission to run."

**Solution:**
1. Open **System Preferences** → **Security & Privacy** → **General**
2. If you see "Chronoframe was blocked," click **Allow**
3. Relaunch the app

---

## Preview Issues

### Preview is taking too long

**Problem:** The preview has been running for 10+ minutes.

**Solution:**
- **Large libraries** (50K+ files) naturally take longer. Give it time (5–15 min is normal).
- Check the activity log (Cmd+L) to see progress.
- If it's frozen (no progress for several minutes), force-quit and try again.
- **To speed up future previews:**
  - Use **Settings** → **Performance** to increase worker threads
  - Filter your source folder to smaller batches
  - Use `--fast-dest` in CLI mode

### Preview failed with a read error

**Problem:** Preview shows errors for some files.

**Solution:**
- Those files are likely corrupted or locked by another app
- In Review, scroll to **Errors** to see which files failed
- You have three options:
  1. Delete the problematic file from source and retry preview
  2. Skip it (Chronoframe will skip errors during transfer)
  3. Check if the file is locked (right-click → Get Info → Locked) and unlock it

### Preview shows "Unknown Date" for many files

**Problem:** Many photos are routing to `Unknown_Date/` folder.

**Solution:**
- Click the **Unknown Dates** filter in Review to see them
- For each item, you can:
  1. **Edit the date** directly in Review (your edit is saved)
  2. **Check the source filename** for date patterns
  3. **Accept Unknown** if you're okay with putting it in `Unknown_Date/`
- Rebuild Preview after edits (button is at top of Review tab)

---

## Transfer Issues

### Transfer failed partway through

**Problem:** Transfer stopped with errors.

**Solution:**
- Check the **Activity Log** (Cmd+L) to see what went wrong
- **Permission errors?** Check that you have write access to destination folder
- **Disk full?** Free up space and try again
- **File locked?** Close other apps using destination files and retry
- **Network drive slow?** Transfer to a local drive instead

You can safely retry the transfer—Chronoframe will skip files already in destination and copy the rest.

### Destination folder has permission issues

**Problem:** "Permission denied" when trying to write to destination.

**Solution:**
1. Open Finder, right-click the destination folder
2. Click **Get Info** → **Sharing & Permissions**
3. Make sure your user account has **Read & Write** access
4. Close the info window and try again in Chronoframe

### Transfer completed but some files are missing

**Problem:** Fewer files copied than expected.

**Solution:**
- Check the **History** tab → transfer report to see what was skipped
- Common reasons:
  - **Already in destination** — file was found in destination before copy
  - **Duplicate** — exact copy already exists in destination
  - **Error** — file couldn't be read (corrupted or locked)
- Review the detailed report to see which files were affected

### Revert failed or left files behind

**Problem:** Revert didn't undo the transfer completely.

**Solution:**
- Revert is **hash-verified** — it only deletes files whose content still matches what was copied
- If a file has been modified or deleted since transfer, revert won't touch it
- Check **History** to see which files were reverted
- You can manually delete the remaining files if needed

---

## Deduplicate Issues

### Deduplicate didn't find duplicates

**Problem:** You know there are duplicate photos, but Deduplicate found none.

**Solution:**
- Chronoframe uses **content hashing**, not filename matching
- Two files are duplicates only if their **bytes are identical**
- If duplicates have different:
  - Compression settings (JPEG quality)
  - Metadata (photographer name, date, etc.)
  - Format (one JPG, one PNG of the same image)
  - …they won't match
- **Try adjusting settings:**
  1. Open **Deduplicate** → **Settings**
  2. Try **Loose** similarity instead of **Balanced**
  3. Rescan

### Similarity detection isn't working

**Problem:** "Similar Photos" mode found nothing or very few.

**Solution:**
- First scan creates a cache. **Second scans are much faster.**
- Make sure you have a GPU (Apple Silicon or Intel with dedicated GPU recommended)
- Adjust the similarity threshold:
  1. **Settings** → **Similarity Strictness**
  2. Try **Balanced** or **Loose** for more matches (but more false positives)

### "Commit" button is grayed out

**Problem:** You can't commit your deduplicate choices.

**Solution:**
- Make sure you've **selected keep/delete choices** for at least one group
- Click a group on the left and select items to keep/delete
- The **Commit** button will activate

---

## Performance

### App is slow or unresponsive

**Problem:** Chronoframe is sluggish, especially with large libraries.

**Solution:**
1. **Reduce worker threads** — sometimes more isn't better
   - **Settings** → **Performance** → reduce worker count
2. **Close other apps** to free up memory
3. **Use a faster drive** — local SSDs are much faster than network drives
4. **Reduce preview scope** — organize smaller batches at a time

### Hashing is slow

**Problem:** Preview is waiting on "Hashing files..." step.

**Solution:**
- BLAKE2b hashing can be slow on large files (videos, RAW photos)
- This is normal for libraries with 100K+ files
- You can't skip hashing (it's how Chronoframe finds duplicates safely)
- Performance improves on subsequent previews thanks to caching

---

## File Access

### "Permission denied" for some files

**Problem:** Chronoframe can't read certain files in source.

**Solution:**
- The file might be **locked** by another app or macOS
- Check if the file is **Locked** (right-click → Get Info → Locked checkbox)
- Unlock it and try again
- Or simply skip those files (Chronoframe skips read errors gracefully)

### Can't select source or destination folder

**Problem:** The folder picker is disabled or doesn't open.

**Solution:**
1. Make sure Chronoframe has folder access (System Preferences → Security & Privacy → Full Disk Access)
2. If the folder is on an external drive, make sure it's mounted
3. Try closing and reopening the app

### External drive isn't showing up

**Problem:** Your external drive doesn't appear in the folder picker.

**Solution:**
- Make sure the drive is **mounted** in Finder
- Try unplugging and replugging the drive
- Check that the drive's file system is supported (macOS works with most formats)
- If the drive is encrypted, unlock it first

---

## Data & Privacy

### Where is my data stored?

**Answer:**
- Source data is **never stored** — Chronoframe reads and copies it
- Destination data is **your files** in the folder you selected
- Chronoframe metadata is in `.organize_cache.db` and `.organize_logs/` inside your destination folder
- You can safely delete these folders; Chronoframe will recreate them

### How can I delete Chronoframe?

**Answer:**
1. **Quit the app** (Cmd+Q)
2. Open Finder → Applications
3. Right-click **Chronoframe** → Move to Trash
4. Empty Trash

That's it—Chronoframe doesn't install anything system-wide.

---

## Still Stuck?

If your issue isn't covered here:
1. Check the [FAQ](./FAQ.md) for general questions
2. Review the [README](../README.md#architecture) for technical details
3. Check the [Releases page](https://github.com/Nishith/Chronoframe/releases) for known issues
4. [Open a GitHub issue](https://github.com/Nishith/Chronoframe/issues) with details about what's happening

**When reporting a bug, include:**
- Your macOS version and hardware (Intel vs. Apple Silicon)
- The error message or steps to reproduce
- The Activity Log (Cmd+L in Chronoframe) or relevant `.organize_logs/` files
