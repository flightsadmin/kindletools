# Legal book downloader

`legal_book_downloader.py` downloads public-domain Project Gutenberg ebooks and direct book-file URLs for material you are licensed or otherwise authorized to download. It does not scrape catalogues, bypass access controls, or support shadow libraries.

Requires Python 3.9+ and uses only the standard library.

A matching Node.js 18+ implementation is available in `legal_book_downloader.js`. Replace `py .\legal_book_downloader.py` in the examples below with `node .\legal_book_downloader.js`; it uses the same commands, JSON manifests, formats, delays, and Kindle option.

```powershell
# Download Project Gutenberg ebook 1342 (Pride and Prejudice) as EPUB
py .\legal_book_downloader.py gutenberg 1342

# Choose plain text or Kindle format and a different folder
py .\legal_book_downloader.py --output .\library gutenberg 1342 --format text

# Create a PDF locally from Gutenberg's plain-text edition
py .\legal_book_downloader.py --output .\library gutenberg 1342 --format pdf

# Download several Gutenberg books in one command
py .\legal_book_downloader.py --output .\library gutenberg-batch --format epub 1342 84 11

# Download every Gutenberg book listed in romance_books.json (86 entries)
# Requests run sequentially with a two-second pause by default.
py .\legal_book_downloader.py --output .\library json .\romance_books.json --format epub

# With a connected Kindle, copy each completed book into its documents folder
py .\legal_book_downloader.py --kindle --output .\library json .\romance_books.json --format epub

# Or specify the Kindle documents folder if automatic detection does not find it
py .\legal_book_downloader.py --kindle E:\documents --output .\library gutenberg 1342 --format epub

# Do not use File Explorer's "This PC\Kindle …" display path. Use --kindle on its
# own, or replace E: above with the Kindle's actual Windows drive letter.

# Download each public Internet Archive item listed in archive_books.json
py .\legal_book_downloader.py --output .\library json .\archive_books.json --format pdf

# Test just the first three entries, with a one-second pause
py .\legal_book_downloader.py --output .\library json .\romance_books.json --format pdf --limit 3 --delay 1

# Download a public Internet Archive item by its identifier
# (the identifier is the final part of https://archive.org/details/<identifier>)
py .\legal_book_downloader.py --output .\library archive pride-and-prejudice-pdf --format pdf

# Download several public Internet Archive items in one command
# Replace item-one and item-two with identifiers that offer the chosen format.
py .\legal_book_downloader.py --output .\library archive-batch --format pdf item-one item-two

# Download an openly licensed or personally authorized direct file URL
py .\legal_book_downloader.py url "https://example.org/book.epub" --authorized
```

The `url` command expects a direct file URL, rather than a web page that contains a download button.

Project Gutenberg does not offer PDFs for every title. The `pdf` format therefore downloads its UTF-8 plain-text edition and makes a basic, searchable PDF locally; it does not claim to be a publisher-formatted edition.

The `archive` command checks an item's public metadata, refuses items marked access-restricted, and downloads an available EPUB, PDF, or text file. Availability and reuse rights vary by item; check the item's rights statement and your local law before downloading.
