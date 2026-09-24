# Kindle Manager

`KindleManager.ps1` downloads books and manages a connected Kindle from one self-contained PowerShell script. It includes colored prompts, file browsing, transfers, search, backups, and storage information.

## Requirements

- Windows with PowerShell 5.1 or later.
- Internet access for downloading books and checking download sources.
- A Kindle connected by USB and visible in File Explorer for the Manage Kindle menu. This menu uses Windows Shell / MTP and expects an `Internal Storage` folder.

No separate modules or package installation are required.

## Start

Open PowerShell in the folder containing the script:

```powershell
.\KindleManager.ps1

# Or launch explicitly using Windows PowerShell
powershell -NoProfile -File .\KindleManager.ps1
```

You can also run the published script directly from GitHub. Open PowerShell in the folder where you want `books`, `backup`, and `downloads` created, then run this one line:

```powershell
irm https://github.com/flightsadmin/kindletools/raw/main/Run-KindleManager.ps1 | iex
```

When launched this way, the current PowerShell folder becomes the application folder. The bootstrap saves `KindleManager.ps1` there and starts it with a temporary execution-policy bypass. It does not change your system policy or install anything. The **Run tests** option requires a local clone because the test files are separate from the script.

For a local checkout, double-click `Run-KindleManager.cmd` if available, or run `powershell -NoProfile -File .\KindleManager.ps1`.

The main menu contains:

1. **Download books**
2. **Manage Kindle**
3. **Run tests**
4. **Exit**

## Download books

The interactive flow asks for a source, format, maximum number of books, and whether to perform a dry run. Review the settings and confirm to start. Press ENTER to accept the displayed default.

| Source | Description |
| --- | --- |
| Standard Ebooks | Downloads EPUB or Kindle AZW3 files from the catalogue. Choose EPUB or MOBI / Kindle; this source does not provide PDF downloads. |
| AliceAndBooks | Downloads available files from its catalogue in the selected format. Availability depends on the book. |
| Global Grey | Downloads fiction in PDF, EPUB, or Kindle AZW3 format. Optional title filter; follows fiction catalogue pages until the limit is reached or matches run out. |
| Project Gutenberg | Downloads English fiction as EPUB or Kindle MOBI using its official machine-readable catalogue. Optional title/author filter; results follow catalogue order. |
| Direct authorized URL | Downloads a book from an HTTP or HTTPS file URL you provide. |
| JSON manifest | Downloads a list of book URLs from a local JSON file. |

The command-line default format is **PDF**, so specify `-Format epub` or `-Format kindle` for Standard Ebooks and Project Gutenberg. Their interactive format menus offer EPUB and Kindle only, defaulting to EPUB. Global Grey and AliceAndBooks default to PDF. The script downloads existing files; it does not convert books between formats. Use material you are authorized to download.

Choose **Global Grey** or **Project Gutenberg** to see an optional title-filter prompt. Enter `Pride and Prejudice`, for example, or leave it blank to browse the source's fiction catalogue. Gutenberg also matches author names. Global Grey searches catalogue pages sequentially, so finding a specific title may take time. Gutenberg loads its complete CSV catalogue into memory before filtering; it does not save a catalogue folder or history file. These integrations use [Global Grey's fiction catalogue](https://www.globalgreyebooks.com/category/ebooks/fiction-page-1.html) and [Gutenberg's machine-readable metadata](https://www.gutenberg.org/policy/robot_access.html).

By default, downloads are limited to three books, with a one-second delay between books and one attempt per book. Enter `0` for an unlimited count. A dry run checks paths and source availability without saving books or creating folders; catalogue and manifest checks inspect a limited sample.

Existing files are skipped automatically when their destination filename matches the incoming title and format. For catalogue sources, the script requests extra candidates and continues past skipped titles so your limit means “new books to download.” A skip message shows how many existing titles were ignored. If you want a different edition, rename or remove the old file first.

Successful downloads are also recorded per source as JSON under `downloads` (`standard.json`, `gutenberg.json`, `globalgrey.json`, and so on). The records are loaded on the next run and used with the actual files to skip repeats. If you delete a recorded book, the downloader notices that the file is missing and permits the book to be downloaded again.

Gutenberg uses at least two seconds between book downloads. Global Grey uses at least one second between catalogue/book-page requests and downloads. A higher `-Delay` is respected.

Downloads are validated before being moved into place. HTML/XML responses are rejected, and PDF/EPUB headers are checked. Normal repeat runs skip recorded or existing files; a successful new download is added to the source record immediately.

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
  KindleManager.ps1
  books/                 Default download and PC transfer folder
  backup/                Timestamped Kindle backups
  downloads/             Per-source JSON records of successful downloads
```

Folders are created when needed. Relative download, manifest, and Kindle paths are resolved from the script's directory, even when it is launched from another working directory. `-Output` changes the downloader's destination; the Manage Kindle menu continues to use the `books` folder beside the script.

## Command-line examples

```powershell
# Show help
.\KindleManager.ps1 -Help

# Open either workflow directly
.\KindleManager.ps1 -Mode Download
.\KindleManager.ps1 -Mode Transfer

# Run all offline test scripts
.\KindleManager.ps1 -Mode Test

# Download three EPUBs from Standard Ebooks
.\KindleManager.ps1 -Source standard -Format epub -Limit 3

# Check Standard Ebooks without saving files
.\KindleManager.ps1 -Source standard -Format epub -DryRun

# Download up to five PDFs from AliceAndBooks where available
.\KindleManager.ps1 -Source alice -Format pdf -Limit 5

# Find Pride and Prejudice on Gutenberg and download one EPUB
.\KindleManager.ps1 -Source gutenberg -Search 'Pride and Prejudice' -Format epub -Limit 1

# Find a PDF edition on Global Grey
.\KindleManager.ps1 -Source globalgrey -Search 'Pride and Prejudice' -Format pdf -Limit 1

# Check Global Grey EPUB links without saving books
.\KindleManager.ps1 -Source globalgrey -Format epub -Limit 3 -DryRun

# Download a direct file URL (replace this placeholder with your book URL)
.\KindleManager.ps1 -Url 'https://example.org/book.epub' -Format epub

# Download all entries in a manifest to a different folder
.\KindleManager.ps1 -Manifest .\books.json -Output .\library -Limit 0

# Use three attempts per book and a two-second delay between books
.\KindleManager.ps1 -Source standard -Format epub -Retries 3 -Delay 2000

# Copy downloads automatically to a Kindle with a drive letter
.\KindleManager.ps1 -Source standard -Format kindle -Kindle -KindlePath 'E:\documents'
```

Automatic copying during downloads (`-Kindle`) uses a filesystem path or a detected Kindle drive letter. It does not support the File Explorer display path `This PC\Kindle\Internal Storage`. For an MTP Kindle without a drive letter, download the books first, then use **Manage Kindle → Send books to Kindle**.

## Options

| Option | Purpose / default |
| --- | --- |
| `-Mode` | `Menu`, `Download`, `Transfer`, or `Test`; default `Menu` |
| `-Source` | `standard`, `alice`, `globalgrey`, `gutenberg`, `url`, or `manifest` |
| `-Search` | Optional title substring for Global Grey; title or author substring for Gutenberg. Case-insensitive; used only by these two sources. |
| `-Url` | Direct HTTP/HTTPS book URL; selects the URL source |
| `-Manifest` | JSON file path; selects the manifest source |
| `-Output` | Download destination; default `books` beside the script |
| `-Format` | `pdf`, `epub`, `mobi`, or `kindle`; default `pdf`. `kindle` aliases `mobi`; Standard Ebooks and Global Grey supply AZW3. Gutenberg supports EPUB and Kindle, not PDF. |
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

Choose **Run tests** or run `powershell -NoProfile -File .\KindleManager.ps1 -Mode Test` to execute the `Test*.ps1` files in the `tests` folder beside the script. Each suite runs in its own PowerShell process and reports PASS or FAIL, followed by a total. Command-line test mode returns exit code `1` if any suite fails or no tests are found. The current suites use mocked network/device operations and need no connected Kindle. The optional `tests` folder is required only for this feature.

All implementation code stays in `KindleManager.ps1`, arranged in collapsible `#region` sections for configuration, shared helpers, downloads, Kindle operations, and menu routing. Shared functions avoid duplicate implementations. Manage Kindle labels and actions are defined together in `$ManageActions`.

Dot-source the script to load its functions without opening a menu:

```powershell
. .\KindleManager.ps1
```
