#!/usr/bin/env python3
"""Download public-domain or otherwise authorized book files.

Supported sources:
  * Project Gutenberg by ebook ID
  * Public, non-restricted Internet Archive items by identifier
  * A direct file URL for which you have permission to download the material

Examples:
  python legal_book_downloader.py gutenberg 1342
  python legal_book_downloader.py archive pride-and-prejudice-pdf --format pdf
  python legal_book_downloader.py url https://example.org/book.epub --authorized
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import textwrap
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


USER_AGENT = "LegalBookDownloader/1.0 (personal lawful-use downloader)"
CHUNK_SIZE = 128 * 1024


def safe_name(value: str) -> str:
    """Return a filesystem-safe filename, keeping a useful extension."""
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(". ")
    return value or "book-download"


def filename_from_response(response, fallback: str) -> str:
    disposition = response.headers.get("Content-Disposition", "")
    match = re.search(r"filename\*?=(?:UTF-8''|\")?([^\";]+)", disposition, re.I)
    if match:
        return safe_name(match.group(1).strip())
    return safe_name(Path(urlparse(response.url).path).name or fallback)


def download(url: str, destination: Path, fallback_name: str) -> Path:
    destination.mkdir(parents=True, exist_ok=True)
    request = Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=45) as response:
            content_type = response.headers.get_content_type()
            if content_type.startswith("text/html"):
                raise RuntimeError("The address returned an HTML page, not a book file.")
            output = destination / filename_from_response(response, fallback_name)
            # Do not silently overwrite an existing book.
            if output.exists():
                stem, suffix = output.stem, output.suffix
                index = 2
                while output.exists():
                    output = destination / f"{stem}-{index}{suffix}"
                    index += 1
            total = int(response.headers.get("Content-Length", 0))
            received = 0
            with output.open("xb") as file:
                while chunk := response.read(CHUNK_SIZE):
                    file.write(chunk)
                    received += len(chunk)
                    if total:
                        print(f"\rDownloaded {received / 1_048_576:.1f} / {total / 1_048_576:.1f} MiB", end="", flush=True)
            print()
            return output
    except (HTTPError, URLError) as error:
        raise RuntimeError(f"Download failed: {error}") from error


def gutenberg_url(book_id: int, fmt: str) -> str:
    # Gutenberg's static-file pattern is documented by its catalog infrastructure.
    suffixes = {"epub": ".epub", "kindle": ".kindle.images", "text": ".txt.utf-8", "pdf": ".txt.utf-8"}
    return f"https://www.gutenberg.org/ebooks/{book_id}{suffixes[fmt]}"


def archive_file(identifier: str, fmt: str) -> tuple[str, str]:
    """Find a public Internet Archive derivative for the requested format."""
    request = Request(f"https://archive.org/metadata/{quote(identifier, safe='')}", headers={"User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=45) as response:
            record = json.load(response)
    except (HTTPError, URLError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not read Internet Archive item metadata: {error}") from error

    if record.get("metadata", {}).get("access-restricted") in (True, "true", "1"):
        raise RuntimeError("This Internet Archive item is access-restricted and cannot be downloaded by this tool.")

    extensions = {"epub": (".epub",), "pdf": (".pdf",), "text": (".txt",)}[fmt]
    candidates: list[tuple[int, str]] = []
    for file in record.get("files", []):
        name = file.get("name", "")
        if not name.lower().endswith(extensions):
            continue
        label = f"{name} {file.get('format', '')}".lower()
        if any(marker in label for marker in ("scandata", "abbyy", "chocr", "hocr", "djvu.xml")):
            continue
        score = len(name)
        if fmt == "pdf" and "text pdf" in label:
            score -= 20
        if fmt == "epub" and "epub" in label:
            score -= 20
        if fmt == "text" and ("djvu" in label or "full text" in label):
            score -= 20
        candidates.append((score, name))
    if not candidates:
        raise RuntimeError(f"No downloadable {fmt.upper()} file was found for Internet Archive item '{identifier}'.")

    name = min(candidates)[1]
    return f"https://archive.org/download/{quote(identifier, safe='')}/{quote(name)}", name


def pdf_escape(value: str) -> str:
    """Escape a string for a literal PDF text object (Windows-1252 subset)."""
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def plain_text_to_pdf(text_path: Path, output: Path, title: str) -> Path:
    """Create a basic PDF without third-party packages from a UTF-8 text file."""
    raw_text = text_path.read_text(encoding="utf-8", errors="replace")
    lines: list[str] = []
    for line in raw_text.splitlines():
        wrapped = textwrap.wrap(line.expandtabs(4), width=92, replace_whitespace=False)
        lines.extend(wrapped or [""])

    # Letter pages: 54 monospaced lines fit comfortably with 10 pt leading.
    pages = [lines[index:index + 54] for index in range(0, len(lines), 54)] or [[""]]
    objects: list[bytes] = []
    objects.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objects.append(f"<< /Type /Pages /Kids [{' '.join(f'{4 + index * 2} 0 R' for index in range(len(pages)))}] /Count {len(pages)} >>".encode())
    objects.append(f"<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>".encode())
    for index, page in enumerate(pages):
        content = ["BT", "/F1 10 Tf", "50 742 Td", "12 TL", f"({pdf_escape(title)}) Tj", "T*"]
        content.extend(f"({pdf_escape(line.encode('cp1252', 'replace').decode('cp1252'))}) Tj T*" for line in page)
        content.append("ET")
        stream = "\n".join(content).encode("cp1252", "replace")
        page_number = 4 + index * 2
        content_number = page_number + 1
        objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents {content_number} 0 R >>".encode())
        objects.append(f"<< /Length {len(stream)} >>\nstream\n".encode() + stream + b"\nendstream")

    payload = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for number, obj in enumerate(objects, start=1):
        offsets.append(len(payload))
        payload.extend(f"{number} 0 obj\n".encode())
        payload.extend(obj)
        payload.extend(b"\nendobj\n")
    start_xref = len(payload)
    payload.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    payload.extend(b"".join(f"{offset:010d} 00000 n \n".encode() for offset in offsets[1:]))
    payload.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{start_xref}\n%%EOF\n".encode())
    output.write_bytes(payload)
    return output


def convert_gutenberg_pdf(text_file: Path, book_id: int) -> Path:
    """Convert a temporary Gutenberg text download to a non-overwriting PDF."""
    pdf_path = text_file.with_suffix(".pdf")
    if pdf_path.exists():
        stem, suffix = pdf_path.stem, pdf_path.suffix
        index = 2
        while pdf_path.exists():
            pdf_path = pdf_path.with_name(f"{stem}-{index}{suffix}")
            index += 1
    plain_text_to_pdf(text_file, pdf_path, f"Project Gutenberg ebook {book_id}")
    text_file.unlink()
    return pdf_path


def download_gutenberg(book_id: int, fmt: str, destination: Path) -> Path:
    """Download one Gutenberg ebook, converting plain text when PDF is requested."""
    result = download(gutenberg_url(book_id, fmt), destination,
                      f"gutenberg-{book_id}{'.epub' if fmt == 'epub' else '.txt'}")
    return convert_gutenberg_pdf(result, book_id) if fmt == "pdf" else result


def load_book_list(path: Path) -> list[dict]:
    """Load a JSON array containing Gutenberg entries with an integer `id` field."""
    try:
        contents = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        raise RuntimeError(f"Could not read JSON book list: {error}") from error
    if not isinstance(contents, list):
        raise RuntimeError("The JSON book list must contain an array of book objects.")
    return contents


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("books"), help="download folder (default: books)")
    commands = parser.add_subparsers(dest="source", required=True)

    gutenberg = commands.add_parser("gutenberg", help="download a public-domain Project Gutenberg ebook")
    gutenberg.add_argument("id", type=int, help="Project Gutenberg ebook ID")
    gutenberg.add_argument("--format", choices=("epub", "kindle", "text", "pdf"), default="epub",
                           help="PDF is generated locally from Gutenberg's plain-text edition")

    gutenberg_batch = commands.add_parser("gutenberg-batch", help="download several Project Gutenberg ebooks")
    gutenberg_batch.add_argument("ids", type=int, nargs="+", help="one or more Project Gutenberg ebook IDs")
    gutenberg_batch.add_argument("--format", choices=("epub", "kindle", "text", "pdf"), default="epub",
                                 help="PDF is generated locally from Gutenberg's plain-text edition")

    json_list = commands.add_parser("json", help="download all Gutenberg books listed in a JSON file")
    json_list.add_argument("path", type=Path, help="JSON array of objects containing at least an id field")
    json_list.add_argument("--format", choices=("epub", "kindle", "text", "pdf"), default="epub")
    json_list.add_argument("--delay", type=float, default=2.0,
                           help="seconds to wait between requests (default: 2)")
    json_list.add_argument("--limit", type=int, help="download only the first N valid entries")

    archive = commands.add_parser("archive", help="download a public, non-restricted Internet Archive item")
    archive.add_argument("identifier", help="Internet Archive identifier from its item URL")
    archive.add_argument("--format", choices=("epub", "pdf", "text"), default="epub")

    archive_batch = commands.add_parser("archive-batch", help="download several public Internet Archive items")
    archive_batch.add_argument("identifiers", nargs="+", help="one or more Internet Archive item identifiers")
    archive_batch.add_argument("--format", choices=("epub", "pdf", "text"), default="epub")

    direct = commands.add_parser("url", help="download a file from a URL you are authorized to access")
    direct.add_argument("url", help="direct book-file URL (not a catalogue or landing page)")
    direct.add_argument("--authorized", action="store_true", help="confirm you have permission or a valid license")

    args = parser.parse_args()
    if args.source == "gutenberg-batch":
        failures = 0
        for book_id in args.ids:
            try:
                result = download_gutenberg(book_id, args.format, args.output)
                print(f"Saved: {result.resolve()}")
            except RuntimeError as error:
                failures += 1
                print(f"Gutenberg {book_id}: {error}", file=sys.stderr)
        return 1 if failures else 0
    if args.source == "json":
        if args.delay < 0:
            parser.error("--delay must be zero or greater.")
        if args.limit is not None and args.limit < 1:
            parser.error("--limit must be at least 1.")
        try:
            entries = load_book_list(args.path)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
        failures = 0
        successes = 0
        processed = 0
        for entry in entries:
            if args.limit is not None and processed >= args.limit:
                break
            if not isinstance(entry, dict):
                failures += 1
                print("Skipped invalid JSON entry (expected an object).", file=sys.stderr)
                continue
            try:
                book_id = int(entry["id"])
                if book_id < 1:
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                failures += 1
                print(f"Skipped entry without a valid positive id: {entry!r}", file=sys.stderr)
                continue
            processed += 1
            title = entry.get("title", f"Gutenberg {book_id}")
            print(f"[{processed}] {title} (#{book_id})")
            try:
                result = download_gutenberg(book_id, args.format, args.output)
                successes += 1
                print(f"Saved: {result.resolve()}")
            except RuntimeError as error:
                failures += 1
                print(f"Gutenberg {book_id}: {error}", file=sys.stderr)
            if processed < len(entries) and (args.limit is None or processed < args.limit):
                time.sleep(args.delay)
        print(f"Finished: {successes} downloaded, {failures} failed or skipped.")
        return 1 if failures else 0
    if args.source == "archive-batch":
        failures = 0
        for identifier in args.identifiers:
            try:
                url, fallback = archive_file(identifier, args.format)
                result = download(url, args.output, fallback)
                print(f"Saved: {result.resolve()}")
            except RuntimeError as error:
                failures += 1
                print(f"Internet Archive {identifier}: {error}", file=sys.stderr)
        return 1 if failures else 0
    if args.source == "gutenberg":
        url = gutenberg_url(args.id, args.format)
        fallback = f"gutenberg-{args.id}{'.epub' if args.format == 'epub' else '.txt'}"
    elif args.source == "archive":
        try:
            url, fallback = archive_file(args.identifier, args.format)
        except RuntimeError as error:
            print(error, file=sys.stderr)
            return 1
    else:
        if not args.authorized:
            parser.error("url downloads require --authorized to confirm lawful access.")
        url, fallback = args.url, "authorized-book"

    try:
        result = download(url, args.output, fallback)
        if args.source == "gutenberg" and args.format == "pdf":
            result = convert_gutenberg_pdf(result, args.id)
    except RuntimeError as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Saved: {result.resolve()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
