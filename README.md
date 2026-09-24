# Kindle Manager

`kindleManager.ps1` downloads books and manages a connected Kindle from one self-contained PowerShell script. It includes colored prompts, file browsing, transfers, search, backups, and storage information.

## Requirements

- Windows with PowerShell 5.1 or later.
- Internet access for downloading books and checking download sources.
- A Kindle connected by USB and visible in File Explorer for the Manage Kindle menu. This menu uses Windows Shell / MTP and expects an `Internal Storage` folder.

No separate modules or package installation are required.

## Start

Open PowerShell in the folder containing the script:

```powershell
.\kindleManager.ps1

# Or launch explicitly using Windows PowerShell
powershell -NoProfile -File .\kindleManager.ps1
```

The main menu contains:

1. **Download books**
2. **Manage Kindle**
3. **Exit**

## Download books

The interactive flow asks for a source, format, maximum number of books, and whether to perform a dry run. Review the settings and confirm to start. Press ENTER to accept the displayed default.

| Source | Description |
| --- | --- |
| Standard Ebooks | Downloads EPUB or Kindle AZW3 files from the catalogue. Choose EPUB or MOBI / Kindle; this source does not provide PDF downloads. |
| AliceAndBooks | Downloads available files from its catalogue in the selected format. Availability depends on the book. |
| Direct authorized URL | Downloads a book from an HTTP or HTTPS file URL you provide. |
| JSON manifest | Downloads a list of book URLs from a local JSON file. |

The default format is **PDF**, so explicitly choose **EPUB** or **MOBI / Kindle** when using Standard Ebooks. The script downloads existing files; it does not convert books between formats. Use material you are authorized to download.

By default, downloads are limited to three books, with a one-second delay between books and one attempt per book. Enter `0` for an unlimited count. A dry run checks paths and source availability without saving books or creating folders; catalogue and manifest checks inspect a limited sample.

Downloads are validated before being moved into place. HTML/XML responses are rejected, and PDF/EPUB headers are checked. A successful download replaces an existing file with the same destination name. The script displays successful and failed download totals without maintaining a download-history file.

## Manage Kindle

1. **Send books to Kindle** — find supported files recursively in `books`, then transfer all or selected files to the Kindle documents folder.
2. **Copy books from Kindle** — copy all or selected documents to the PC books folder.
3. **Browse Kindle files** — navigate folders, inspect files, copy items to the PC, delete files, or search by filename.
4. **Backup Kindle** — copy internal storage to a timestamped folder under `backup`.
5. **Kindle information and storage** — show device details and a file-based storage report. Sizes depend on metadata exposed by Windows Shell.
6. **Open PC books folder** — open `books` in File Explorer.
7. **Return to Kindle Manager** — return to the main menu.

Browser commands:

| Input | Action |
| --- | --- |
| Number | Open a folder or inspect a file |
| `B` | Go back |
| `I` | Show information for a selected item |
| `C` | Copy an item to the PC |
| `D` | Delete a selected file, with confirmation |
| `S` | Search Kindle filenames recursively |
| `R` | Refresh the current listing |
| `Q` | Exit the browser |

Transfers copy files as they are; they do not convert formats or guarantee that the Kindle can read every transferred file.

## Folders and paths

```text
KindleTools/
  kindleManager.ps1
  books/                 Default download and PC transfer folder
  backup/                Timestamped Kindle backups
```

Folders are created when needed. Relative download, manifest, and Kindle paths are resolved from the script's directory, even when it is launched from another working directory. `-Output` changes the downloader's destination; the Manage Kindle menu continues to use the `books` folder beside the script.

## Command-line examples

```powershell
# Show help
.\kindleManager.ps1 -Help

# Open either workflow directly
.\kindleManager.ps1 -Mode Download
.\kindleManager.ps1 -Mode Transfer

# Download three EPUBs from Standard Ebooks
.\kindleManager.ps1 -Source standard -Format epub -Limit 3

# Check Standard Ebooks without saving files
.\kindleManager.ps1 -Source standard -Format epub -DryRun

# Download up to five PDFs from AliceAndBooks where available
.\kindleManager.ps1 -Source alice -Format pdf -Limit 5

# Download a direct file URL (replace this placeholder with your book URL)
.\kindleManager.ps1 -Url 'https://example.org/book.epub' -Format epub

# Download all entries in a manifest to a different folder
.\kindleManager.ps1 -Manifest .\books.json -Output .\library -Limit 0

# Use three attempts per book and a two-second delay between books
.\kindleManager.ps1 -Source standard -Format epub -Retries 3 -Delay 2000

# Copy downloads automatically to a Kindle with a drive letter
.\kindleManager.ps1 -Source standard -Format kindle -Kindle -KindlePath 'E:\documents'
```

Automatic copying during downloads (`-Kindle`) uses a filesystem path or a detected Kindle drive letter. It does not support the File Explorer display path `This PC\Kindle\Internal Storage`. For an MTP Kindle without a drive letter, download the books first, then use **Manage Kindle → Send books to Kindle**.

## Options

| Option | Purpose / default |
| --- | --- |
| `-Mode` | `Menu`, `Download`, or `Transfer`; default `Menu` |
| `-Source` | `standard`, `alice`, `url`, or `manifest` |
| `-Url` | Direct HTTP/HTTPS book URL; selects the URL source |
| `-Manifest` | JSON file path; selects the manifest source |
| `-Output` | Download destination; default `books` beside the script |
| `-Format` | `pdf`, `epub`, `mobi`, or `kindle`; default `pdf`. `kindle` aliases `mobi`; Standard Ebooks supplies AZW3. |
| `-Limit` | Maximum books; default `3`; `0` means unlimited |
| `-Delay` | Milliseconds between books; default `1000` |
| `-Retries` | Total attempts per book, including the first; default `1` |
| `-Timeout` | Request timeout in milliseconds; default `30000` |
| `-DryRun` | Check availability and paths without saving books |
| `-Kindle` | Copy completed downloads to a filesystem-accessible Kindle |
| `-KindlePath` | Kindle documents directory; requires `-Kindle`; otherwise auto-detected |
| `-Interactive` | Open the download prompts even when a source was supplied |
| `-Help` | Display command-line help |

With no arguments, the main menu opens. Supplying download options opens the downloader directly; without a source, URL, or manifest, it prompts interactively. Interactive prompts select source and format anew. Use a source argument without `-Interactive` for unattended downloads.

## JSON manifests

Save a manifest such as `books.json` beside the script. Replace these placeholder URLs with actual book-file URLs:

```json
{
  "books": [
    {
      "title": "Example Book",
      "url": "https://example.org/book.epub",
      "format": "epub"
    },
    {
      "title": "Example Document",
      "url": "https://example.org/document.pdf",
      "format": "pdf"
    }
  ]
}
```

A top-level array or a single book object is also accepted. Each entry needs an HTTP/HTTPS URL in `url`, `downloadUrl`, or `download_url`. `title` is optional and otherwise derived from the URL. `format` is optional and inferred from the URL, falling back to EPUB. Per-entry formats are used for manifest downloads; `-Format` does not convert them.

## Script organization

All implementation code stays in `kindleManager.ps1`, arranged in collapsible `#region` sections for configuration, shared helpers, downloads, Kindle operations, and menu routing. Shared functions avoid duplicate implementations. Manage Kindle labels and actions are defined together in `$ManageActions`.

Dot-source the script to load its functions without opening a menu:

```powershell
. .\kindleManager.ps1
```
