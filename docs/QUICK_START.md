# Chronoframe Quick Start

Get your photos organized in 5 minutes.

## Installation

1. Download `Chronoframe.zip` from [Releases](https://github.com/Nishith/Chronoframe/releases)
2. Unzip and drag `Chronoframe.app` to Applications
3. Open the app (macOS 13+)

If macOS blocks the app, right-click it and choose **Open**.

## Your First Organize

This is the basic workflow:

### Step 1: Choose Folders

1. Open **Organize** → **Setup**
2. Click **Select Source** and choose your messy photo folder
3. Click **Select Destination** and choose where organized photos should go
4. Pick a folder layout (e.g., `YYYY/MM/DD` for year/month/day)

### Step 2: Preview Your Plan

5. Click **Preview**
   - Chronoframe scans the source, resolves dates, and creates a transfer plan
   - This takes 10–60 seconds depending on your library size
6. Once done, click **Run**

### Step 3: Review (Optional)

7. In the **Review** tab, you'll see:
   - **Ready**: Photos ready to copy
   - **Unknown Dates**: Photos Chronoframe isn't sure about
   - **Duplicates**: Files that appear in both source and destination
   - **Issues**: Permission errors or read failures

8. For uncertain items, you can edit the date or event right in Review
9. Click **Rebuild Preview** after any edits

### Step 4: Transfer

10. Review the plan one more time
11. Click **Transfer**
    - Files are copied to destination, written safely, and verified
    - You'll see progress and a summary when done

### Step 5: Keep Your Originals Safe

12. **Your source folder stays untouched.** Nothing is deleted or modified.
13. You can review the transfer report under **History**
14. If something went wrong, use **History** → **Revert** to undo the transfer

That's it! Your photos are now organized.

## Tips

- **Trust the preview.** It shows exactly what will copy before anything happens.
- **Edit uncertain dates.** If a photo has an unknown date, fix it in Review and Chronoframe will use your correction.
- **Don't delete the source yet.** Keep it for a few days to make sure everything looks right.
- **Keyboard shortcuts** (once you're comfortable):
  - `Cmd+R` to preview
  - `Cmd+Return` to transfer
  - `Cmd+L` to show/hide the activity log

## Deduplicate (Bonus Feature)

Once your photos are organized, you can clean up duplicates:

1. Open **Deduplicate**
2. Click **Scan**
3. Chronoframe finds exact copies and similar shots
4. Review suggested "keep" items in each group
5. Click **Commit** to move duplicates to Trash

## Need Help?

- **First run taking too long?** Large libraries (50K+ files) can take 5–10 minutes to scan. That's normal.
- **Unsure about a photo?** You can look at it in Review before transfer.
- **Want to try without copying?** Use dry-run mode in Settings → Advanced.
- **Questions?** See [Troubleshooting](./TROUBLESHOOTING.md) or check the full [README](../README.md).

---

**Remember:** Your originals are always safe. Chronoframe only copies, never deletes your source folder.
