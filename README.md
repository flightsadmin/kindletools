# Legal book downloader

`legal_book_downloader.py` downloads public-domain Project Gutenberg ebooks and direct book-file URLs for material you are licensed or otherwise authorized to download. It does not scrape catalogues, bypass access controls, or support shadow libraries.

Requires Python 3.9+ and uses only the standard library.

```powershell
# Download Project Gutenberg ebook 1342 (Pride and Prejudice) as EPUB
py .\legal_book_downloader.py gutenberg 1342

# Choose plain text or Kindle format and a different folder
py .\legal_book_downloader.py --output .\library gutenberg 1342 --format text

# Create a PDF locally from Gutenberg's plain-text edition
py .\legal_book_downloader.py --output .\library gutenberg 1342 --format pdf

# Download an openly licensed or personally authorized direct file URL
py .\legal_book_downloader.py url "https://example.org/book.epub" --authorized
```

The `url` command expects a direct file URL, rather than a web page that contains a download button.

Project Gutenberg does not offer PDFs for every title. The `pdf` format therefore downloads its UTF-8 plain-text edition and makes a basic, searchable PDF locally; it does not claim to be a publisher-formatted edition.
