#!/usr/bin/env node
'use strict';
/*
 * ============================================================
 * book_downloader.js
 *
 * Portable legal/authorized book downloader
 *
 * Supported sources:
 *   * AliceAndBooks
 *   * Direct authorized URLs
 *   * JSON manifests
 *
 * NOT supported:
 *   * Project Gutenberg
 *   * Internet Archive
 *   * Archive.org
 *
 * Portable folder structure:
 *
 *   book_downloader.js
 *   books\
 *   backup\
 *   inventory\
 *
 * Features:
 *   * Uses its own folder as the working directory
 *   * AliceAndBooks support
 *   * Direct authorized URL downloads
 *   * JSON manifest downloads
 *   * EPUB / PDF / MOBI
 *   * Existing files are overwritten
 *   * Optional Kindle copying
 *   * Automatic Windows Kindle detection
 *   * Dry-run mode
 *   * Download retries
 *   * Download timeout
 *   * Inventory JSON
 *
 * Requirements:
 *   * Node.js 18+
 *
 * Examples:
 *
 *   node book_downloader.js
 *   node book_downloader.js --source alice
 *   node book_downloader.js --url "https://example.com/book.epub"
 *   node book_downloader.js --manifest books.json
 *   node book_downloader.js --kindle
 *   node book_downloader.js --kindle "D:\Kindle\documents"
 *   node book_downloader.js --dry-run
 *   node book_downloader.js --dry-run --kindle
 *   node book_downloader.js --format pdf
 *   node book_downloader.js --limit 10
 *   node book_downloader.js --retries 5 --timeout 60000
 */

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

/* ============================================================
 * CONSTANTS
 * ============================================================ */
const SCRIPT_DIR = path.resolve(__dirname);
const BOOKS_DIR = path.join(SCRIPT_DIR, 'books');
const BACKUP_DIR = path.join(SCRIPT_DIR, 'backup');
const INVENTORY_DIR = path.join(SCRIPT_DIR, 'inventory');
const INVENTORY_FILE = path.join(INVENTORY_DIR, 'inventory.json');
const ALICE_URL = 'https://www.aliceandbooks.com';
const USER_AGENT =
  'LegalBookDownloader/3.0 (personal lawful-use downloader)';
const FORMATS = new Set(['epub', 'pdf', 'mobi']);
const SOURCES = new Set(['alice', 'url', 'manifest']);

/* ============================================================
 * LOGGING
 * ============================================================ */
function writeStep(message) {
  console.log(`\n==> ${message}`);
}
function writeSuccess(message) {
  console.log(`✓ ${message}`);
}
function writeWarn(message) {
  console.warn(`⚠ ${message}`);
}
function writeError(message) {
  console.error(`✗ ${message}`);
}

/* ============================================================
 * GENERAL HELPERS
 * ============================================================ */
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeFormat(format) {
  if (!format) {
    return 'epub';
  }
  const normalized = String(format).trim().toLowerCase().replace(/^\./, '');
  if (normalized === 'kindle') {
    return 'mobi';
  }
  return normalized;
}

function isSupportedFormat(format) {
  return FORMATS.has(normalizeFormat(format));
}

function safeFilename(value, fallback = 'book') {
  let name = String(value || fallback);
  name = name
    .replace(/[<>:"/\\|?*\x00-\x1F]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/[. ]+$/g, '');
  if (!name) {
    name = fallback;
  }
  return name;
}

function resolvePortablePath(value) {
  if (!value) {
    return SCRIPT_DIR;
  }
  if (path.isAbsolute(value)) {
    return path.resolve(value);
  }
  return path.resolve(SCRIPT_DIR, value);
}

function extensionFromUrl(url, fallback = 'epub') {
  try {
    const parsed = new URL(url);
    const pathname = decodeURIComponent(parsed.pathname);
    const match = pathname.match(/\.(epub|pdf|mobi)$/i);
    if (match) {
      return match[1].toLowerCase();
    }
  } catch {
    // Ignore invalid URLs here.
  }
  return normalizeFormat(fallback);
}

function filenameFromUrl(url, fallbackFormat = 'epub') {
  try {
    const parsed = new URL(url);
    let filename = path.basename(decodeURIComponent(parsed.pathname));
    if (filename) {
      filename = safeFilename(filename);
      if (/\.(epub|pdf|mobi)$/i.test(filename)) {
        return filename;
      }
    }
  } catch {
    // Fall back below.
  }
  const format = extensionFromUrl(url, fallbackFormat);
  return `book.${format}`;
}

function titleFromUrl(url) {
  try {
    const parsed = new URL(url);
    let title = path.basename(decodeURIComponent(parsed.pathname));
    title = title.replace(/\.(epub|pdf|mobi)$/i, '');
    title = title
      .replace(/[-_]+/g, ' ')
      .replace(/\s+/g, ' ')
      .trim();
    return title || 'Book';
  } catch {
    return 'Book';
  }
}

function isHttpUrl(value) {
  try {
    const parsed = new URL(value);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

/* ============================================================
 * COMMAND LINE
 * ============================================================ */
function showHelp() {
  console.log(`
book_downloader.js
Portable legal/authorized book downloader.

SOURCES
  alice              Download from AliceAndBooks
  url                Download from a direct authorized URL
  manifest           Download from a JSON manifest

OPTIONS
  -s, --source <source>
      Source: alice | url | manifest
      Default: alice

  -u, --url <url>
      Direct authorized book URL.
      Automatically selects: --source url

  -m, --manifest <file>
      JSON manifest file.
      Automatically selects: --source manifest

  -o, --output <folder>
      Download destination.
      Relative paths are resolved relative to the folder containing this script.
      Default: ./books

  --kindle [folder]
      Copy downloaded books to Kindle.
      Without a folder, Windows Kindle detection is attempted automatically.
      Relative paths are resolved relative to the folder containing this script.

  -f, --format <format>
      Preferred format: epub | pdf | mobi | kindle
      "kindle" is normalized to "mobi".
      Default: epub

  --delay <milliseconds>
      Delay between downloads.
      Default: 1000

  --limit <number>
      Maximum number of books.
      Default: unlimited

  --retries <number>
      Number of download attempts.
      Default: 3

  --timeout <milliseconds>
      Download timeout.
      Default: 30000

  --dry-run
      Test configuration, source connectivity,
      sample download URLs and Kindle detection.
      Does NOT:
        - create directories
        - download files
        - overwrite files
        - copy files to Kindle
        - modify inventory

  -h, --help
      Show this help.

EXAMPLES
  node book_downloader.js
  node book_downloader.js --source alice
  node book_downloader.js --url "https://example.com/book.epub"
  node book_downloader.js --manifest books.json
  node book_downloader.js --kindle
  node book_downloader.js --kindle "D:\\Kindle\\documents"
  node book_downloader.js --dry-run
  node book_downloader.js --dry-run --kindle
  node book_downloader.js --format pdf
  node book_downloader.js --limit 10
  node book_downloader.js --retries 5 --timeout 60000
`);
}

function parseArgs(argv) {
  const options = {
    source: 'alice',
    url: null,
    manifest: null,
    output: BOOKS_DIR,
    kindle: false,
    kindlePath: null,
    format: 'epub',
    delay: 1000,
    limit: Infinity,
    retries: 3,
    timeout: 30000,
    dryRun: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '-h':
      case '--help':
        showHelp();
        process.exit(0);
        break;

      case '-s':
      case '--source': {
        const value = argv[++i];
        if (!value) {
          throw new Error('--source requires a value');
        }
        options.source = value.toLowerCase();
        break;
      }

      case '-u':
      case '--url': {
        const value = argv[++i];
        if (!value) {
          throw new Error('--url requires a value');
        }
        options.url = value;
        options.source = 'url';
        break;
      }

      case '-m':
      case '--manifest': {
        const value = argv[++i];
        if (!value) {
          throw new Error('--manifest requires a file');
        }
        options.manifest = resolvePortablePath(value);
        options.source = 'manifest';
        break;
      }

      case '-o':
      case '--output': {
        const value = argv[++i];
        if (!value) {
          throw new Error('--output requires a folder');
        }
        options.output = resolvePortablePath(value);
        break;
      }

      case '--kindle': {
        options.kindle = true;
        const next = argv[i + 1];
        if (next && !next.startsWith('-')) {
          options.kindlePath = resolvePortablePath(next);
          i++;
        }
        break;
      }

      case '-f':
      case '--format': {
        const value = argv[++i];
        if (!value) {
          throw new Error('--format requires a value');
        }
        options.format = normalizeFormat(value);
        break;
      }

      case '--delay': {
        const value = Number(argv[++i]);
        if (!Number.isFinite(value) || value < 0) {
          throw new Error('--delay must be a non-negative number');
        }
        options.delay = value;
        break;
      }

      case '--limit': {
        const value = Number(argv[++i]);
        if (!Number.isInteger(value) || value < 1) {
          throw new Error('--limit must be a positive integer');
        }
        options.limit = value;
        break;
      }

      case '--retries': {
        const value = Number(argv[++i]);
        if (!Number.isInteger(value) || value < 1) {
          throw new Error('--retries must be a positive integer');
        }
        options.retries = value;
        break;
      }

      case '--timeout': {
        const value = Number(argv[++i]);
        if (!Number.isInteger(value) || value < 1) {
          throw new Error('--timeout must be a positive integer');
        }
        options.timeout = value;
        break;
      }

      case '--dry-run':
        options.dryRun = true;
        break;

      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!SOURCES.has(options.source)) {
    throw new Error(
      `Unsupported source "${options.source}". Use alice, url, or manifest.`
    );
  }

  if (!isSupportedFormat(options.format)) {
    throw new Error(
      `Unsupported format "${options.format}". Use epub, pdf, mobi, or kindle.`
    );
  }

  if (options.source === 'url' && !options.url) {
    throw new Error('--source url requires --url');
  }

  if (options.source === 'manifest' && !options.manifest) {
    throw new Error('--source manifest requires --manifest');
  }

  if (options.url && !isHttpUrl(options.url)) {
    throw new Error('--url must be an HTTP or HTTPS URL');
  }

  return options;
}

/* ============================================================
 * FILE SYSTEM
 * ============================================================ */
async function ensureDirectory(directory) {
  await fsp.mkdir(directory, { recursive: true });
}

async function pathExists(target) {
  try {
    await fsp.access(target);
    return true;
  } catch {
    return false;
  }
}

/* ============================================================
 * HTTP
 * ============================================================ */
async function fetchResponse(url, options = {}) {
  const timeout = options.timeout || 30000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);

  try {
    return await fetch(url, {
      method: options.method || 'GET',
      headers: {
        'User-Agent': USER_AGENT,
        Accept: options.accept || '*/*',
      },
      redirect: 'follow',
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

async function checkUrl(url, timeout = 30000) {
  if (!isHttpUrl(url)) {
    return {
      ok: false,
      status: 0,
      message: 'Invalid HTTP/HTTPS URL',
    };
  }

  try {
    let response = await fetchResponse(url, {
      method: 'HEAD',
      timeout,
    });

    if (response.status === 405 || response.status === 403) {
      response = await fetchResponse(url, {
        method: 'GET',
        timeout,
        accept: '*/*',
      });
    }

    return {
      ok: response.ok,
      status: response.status,
      message: response.ok ? 'OK' : `HTTP ${response.status}`,
    };
  } catch (error) {
    return {
      ok: false,
      status: 0,
      message: error.message,
    };
  }
}

/* ============================================================
 * HTML EXTRACTION
 * ============================================================ */
function stripHtml(value) {
  return String(value || '')
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

function extractLinks(html, baseUrl) {
  const results = [];
  const regex =
    /<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  let match;
  while ((match = regex.exec(html)) !== null) {
    const href = match[1];
    const text = stripHtml(match[2]);
    try {
      const url = new URL(href, baseUrl).href;
      results.push({ url, text });
    } catch {
      // Ignore malformed links.
    }
  }
  return results;
}

/* ============================================================
 * ALICEANDBOOKS
 * ============================================================ */
function extractBookId(url) {
  const match = url.match(/\/book\/([^/?#]+)/i);
  return match ? match[1] : null;
}

async function getAliceBooks() {
  writeStep('Reading AliceAndBooks catalogue...');
  const response = await fetchResponse(ALICE_URL, {
    timeout: 30000,
    accept: 'text/html',
  });

  if (!response.ok) {
    throw new Error(`AliceAndBooks returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const links = extractLinks(html, ALICE_URL);
  const books = [];
  const seen = new Set();

  for (const link of links) {
    if (!/\/book\//i.test(link.url)) {
      continue;
    }
    const id = extractBookId(link.url);
    if (!id || seen.has(id)) {
      continue;
    }
    seen.add(id);
    books.push({
      id,
      title: link.text || id.replace(/[-_]+/g, ' '),
      pageUrl: link.url,
    });
  }

  return books;
}

async function getAliceBookDownload(book) {
  const response = await fetchResponse(book.pageUrl, {
    timeout: 30000,
    accept: 'text/html',
  });

  if (!response.ok) {
    throw new Error(`Book page returned HTTP ${response.status}`);
  }

  const html = await response.text();
  const links = extractLinks(html, book.pageUrl);

  // Prefer direct file links
  for (const link of links) {
    if (/\.(epub|pdf|mobi)(?:[?#]|$)/i.test(link.url)) {
      return {
        url: link.url,
        title: book.title,
        format: extensionFromUrl(link.url, 'epub'),
      };
    }
  }

  // Fallback: look for download-looking links
  for (const link of links) {
    const text = `${link.text} ${link.url}`.toLowerCase();
    if (
      text.includes('download') ||
      text.includes('epub') ||
      text.includes('pdf') ||
      text.includes('mobi')
    ) {
      if (isHttpUrl(link.url)) {
        return {
          url: link.url,
          title: book.title,
          format: extensionFromUrl(link.url, 'epub'),
        };
      }
    }
  }

  throw new Error(
    `No supported EPUB / PDF / MOBI download found for "${book.title}"`
  );
}

async function buildAliceDownloadList(options) {
  const books = await getAliceBooks();
  if (!books.length) {
    throw new Error('No books were found on AliceAndBooks.');
  }

  const selected = books.slice(
    0,
    Number.isFinite(options.limit) ? options.limit : books.length
  );

  const downloads = [];
  for (const book of selected) {
    try {
      const download = await getAliceBookDownload(book);
      downloads.push(download);
    } catch (error) {
      writeWarn(`${book.title}: ${error.message}`);
    }
  }

  return downloads;
}

/* ============================================================
 * DIRECT URL
 * ============================================================ */
function buildUrlDownloadList(options) {
  const format = extensionFromUrl(options.url, options.format);
  return [
    {
      url: options.url,
      title: titleFromUrl(options.url),
      format,
    },
  ];
}

/* ============================================================
 * MANIFEST
 * ============================================================ */
function normalizeManifestBook(book, index) {
  if (!book || typeof book !== 'object') {
    throw new Error(`Manifest entry ${index + 1} is invalid.`);
  }

  const url = book.url || book.downloadUrl || book.download_url;
  if (!url || !isHttpUrl(url)) {
    throw new Error(
      `Manifest entry ${index + 1} has no valid HTTP / HTTPS URL.`
    );
  }

  const format = normalizeFormat(
    book.format || extensionFromUrl(url, 'epub')
  );

  if (!isSupportedFormat(format)) {
    throw new Error(
      `Manifest entry ${index + 1} has unsupported format "${format}".`
    );
  }

  const title = book.title || titleFromUrl(url);
  return {
    url,
    title: safeFilename(title),
    format,
  };
}

async function readManifest(manifestPath) {
  if (!(await pathExists(manifestPath))) {
    throw new Error(`Manifest file not found: ${manifestPath}`);
  }

  const raw = await fsp.readFile(manifestPath, 'utf8');
  let data;
  try {
    data = JSON.parse(raw);
  } catch (error) {
    throw new Error(`Invalid JSON manifest: ${error.message}`);
  }

  let books;
  if (Array.isArray(data)) {
    books = data;
  } else if (data && Array.isArray(data.books)) {
    books = data.books;
  } else if (data && typeof data === 'object') {
    books = [data];
  } else {
    throw new Error(
      'Manifest must be an array, an object with a "books" array, or a single book object.'
    );
  }

  return books.map(normalizeManifestBook);
}

async function buildManifestDownloadList(options) {
  const books = await readManifest(options.manifest);
  if (!books.length) {
    throw new Error('The manifest contains no books.');
  }
  if (Number.isFinite(options.limit)) {
    return books.slice(0, options.limit);
  }
  return books;
}

/* ============================================================
 * DOWNLOAD
 * ============================================================ */
async function downloadFile(url, destination, options) {
  let lastError = null;

  for (let attempt = 1; attempt <= options.retries; attempt++) {
    const tempFile = `${destination}.download`;
    try {
      await fsp.rm(tempFile, { force: true });

      writeStep(`Downloading: ${path.basename(destination)}`);
      if (attempt > 1) {
        console.log(`Attempt ${attempt}/${options.retries}`);
      }

      const response = await fetchResponse(url, {
        timeout: options.timeout,
        accept:
          'application/epub+zip,application/pdf,application/x-mobipocket-ebook,*/*',
      });

      if (!response.ok) {
        throw new Error(`HTTP ${response.status}`);
      }

      if (!response.body) {
        throw new Error('Response has no readable body.');
      }

      const fileHandle = await fsp.open(tempFile, 'w');
      try {
        const reader = response.body.getReader();
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          await fileHandle.write(value);
        }
      } finally {
        await fileHandle.close();
      }

      await fsp.rm(destination, { force: true });
      await fsp.rename(tempFile, destination);
      return;
    } catch (error) {
      lastError = error;
      await fsp.rm(tempFile, { force: true });
      if (attempt < options.retries) {
        writeWarn(`Download failed: ${error.message}`);
        await sleep(1000);
      }
    }
  }

  throw new Error(
    `Download failed after ${options.retries} attempt(s): ${lastError?.message || 'Unknown error'
    }`
  );
}

/* ============================================================
 * KINDLE
 * ============================================================ */
function detectKindleWindows() {
  if (process.platform !== 'win32') {
    return null;
  }

  const script = `
    Get-Volume |
      Where-Object {
        $_.DriveLetter -and (
          $_.FileSystemLabel -like '*Kindle*' -or
          $_.FriendlyName -like '*Kindle*'
        )
      } |
      Select-Object -First 1 -ExpandProperty DriveLetter
  `;

  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { encoding: 'utf8', windowsHide: true }
  );

  if (result.error || result.status !== 0) {
    return null;
  }

  const drive = String(result.stdout || '').trim();
  if (!drive) {
    return null;
  }

  return path.join(`${drive}:\\`, 'documents');
}

function getKindlePath(options) {
  if (!options.kindle) {
    return null;
  }
  if (options.kindlePath) {
    return options.kindlePath;
  }
  return detectKindleWindows();
}

function getKindleFreeSpace(kindlePath) {
  if (process.platform !== 'win32') {
    return null;
  }

  const root = path.parse(kindlePath).root;
  const drive = root.replace(/[\\/:]/g, '');
  if (!drive) {
    return null;
  }

  const script = `
    $drive = '${drive}'
    Get-PSDrive -Name $drive | Select-Object -ExpandProperty Free
  `;

  const result = spawnSync(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
    { encoding: 'utf8', windowsHide: true }
  );

  if (result.error || result.status !== 0) {
    return null;
  }

  const value = Number(String(result.stdout || '').trim());
  return Number.isFinite(value) ? value : null;
}

async function testKindle(kindlePath) {
  if (!kindlePath) {
    return {
      ok: false,
      message: 'Kindle was not detected.',
    };
  }

  try {
    const stats = await fsp.stat(kindlePath);
    if (!stats.isDirectory()) {
      return {
        ok: false,
        message: 'Kindle path is not a directory.',
      };
    }

    const freeSpace = getKindleFreeSpace(kindlePath);
    return {
      ok: true,
      path: kindlePath,
      freeSpace,
    };
  } catch (error) {
    return {
      ok: false,
      path: kindlePath,
      message: error.message,
    };
  }
}

async function copyToKindle(source, kindlePath) {
  await ensureDirectory(kindlePath);
  const destination = path.join(kindlePath, path.basename(source));
  await fsp.rm(destination, { force: true });
  await fsp.copyFile(source, destination);
  return destination;
}

/* ============================================================
 * INVENTORY
 * ============================================================ */
async function writeInventory(records) {
  await ensureDirectory(INVENTORY_DIR);
  const inventory = {
    generatedAt: new Date().toISOString(),
    scriptDirectory: SCRIPT_DIR,
    booksDirectory: BOOKS_DIR,
    backupDirectory: BACKUP_DIR,
    records,
  };
  await fsp.writeFile(
    INVENTORY_FILE,
    JSON.stringify(inventory, null, 2),
    'utf8'
  );
}

/* ============================================================
 * DRY RUN
 * ============================================================ */
async function dryRun(options) {
  writeStep('DRY RUN');
  console.log(
    'No files will be created, downloaded, overwritten, or copied.'
  );
  console.log('');
  console.log(`Script folder: ${SCRIPT_DIR}`);
  console.log(`Books folder:  ${options.output}`);
  console.log(`Backup folder: ${BACKUP_DIR}`);
  console.log(`Inventory:     ${INVENTORY_FILE}`);
  console.log(`Source:        ${options.source}`);
  console.log(`Format:        ${options.format}`);
  console.log(`Delay:         ${options.delay} ms`);
  console.log(
    `Limit:         ${Number.isFinite(options.limit) ? options.limit : 'unlimited'
    }`
  );
  console.log(`Retries:       ${options.retries}`);
  console.log(`Timeout:       ${options.timeout} ms`);
  console.log('');

  /* Test output parent without creating it. */
  writeStep('Testing output path...');
  try {
    const parent = path.dirname(options.output);
    await fsp.access(parent, fs.constants.W_OK);
    writeSuccess(`Output parent is writable: ${parent}`);
  } catch {
    writeWarn(
      `Output parent does not currently exist or is not writable: ${path.dirname(
        options.output
      )}`
    );
    console.log(
      'This is not necessarily a problem because normal mode will create the folder.'
    );
  }

  /* Test source. */
  writeStep('Testing selected source...');

  if (options.source === 'alice') {
    const aliceStatus = await checkUrl(ALICE_URL, options.timeout);
    if (aliceStatus.ok) {
      writeSuccess(
        `AliceAndBooks reachable: HTTP ${aliceStatus.status}`
      );
      try {
        const books = await getAliceBooks();
        if (!books.length) {
          writeWarn(
            'AliceAndBooks responded, but no /book/ links were found.'
          );
        } else {
          const sample = books.slice(
            0,
            Number.isFinite(options.limit)
              ? Math.min(options.limit, 5)
              : 5
          );
          writeSuccess(`Found ${books.length} book page link(s).`);
          writeStep(`Testing up to ${sample.length} book page(s)...`);
          for (const book of sample) {
            try {
              const download = await getAliceBookDownload(book);
              const status = await checkUrl(download.url, options.timeout);
              if (status.ok) {
                writeSuccess(
                  `${book.title} -> ${download.format.toUpperCase()}`
                );
              } else {
                writeWarn(
                  `${book.title}: download URL returned ${status.message}`
                );
              }
            } catch (error) {
              writeWarn(`${book.title}: ${error.message}`);
            }
          }
        }
      } catch (error) {
        writeWarn(`Alice catalogue test failed: ${error.message}`);
      }
    } else {
      writeWarn(
        `AliceAndBooks is not reachable: ${aliceStatus.message}`
      );
    }
  }

  if (options.source === 'url') {
    const status = await checkUrl(options.url, options.timeout);
    if (status.ok) {
      writeSuccess(`URL reachable: HTTP ${status.status}`);
      console.log(`URL: ${options.url}`);
      console.log(
        `Detected format: ${extensionFromUrl(
          options.url,
          options.format
        ).toUpperCase()}`
      );
    } else {
      writeWarn(`URL test failed: ${status.message}`);
    }
  }

  if (options.source === 'manifest') {
    writeStep('Testing manifest...');
    try {
      const books = await readManifest(options.manifest);
      writeSuccess(`Manifest is valid: ${books.length} book(s)`);
      const sample = books.slice(
        0,
        Number.isFinite(options.limit)
          ? Math.min(options.limit, 5)
          : 5
      );
      for (const book of sample) {
        const status = await checkUrl(book.url, options.timeout);
        if (status.ok) {
          writeSuccess(`${book.title} -> HTTP ${status.status}`);
        } else {
          writeWarn(`${book.title}: ${status.message}`);
        }
      }
    } catch (error) {
      writeWarn(`Manifest test failed: ${error.message}`);
    }
  }

  /* Test Kindle. */
  if (options.kindle) {
    writeStep('Testing Kindle connection...');
    const kindlePath = getKindlePath(options);
    if (!kindlePath) {
      writeWarn('No Kindle was detected automatically.');
      console.log(
        'If the Kindle uses MTP instead of a normal Windows drive, automatic drive detection may not work.'
      );
    } else {
      const result = await testKindle(kindlePath);
      if (result.ok) {
        writeSuccess(`Kindle detected: ${result.path}`);
        if (result.freeSpace !== null) {
          writeSuccess(
            `Free space: ${(
              result.freeSpace /
              1024 /
              1024 /
              1024
            ).toFixed(2)} GB`
          );
        }
      } else {
        writeWarn(`Kindle test failed: ${result.message}`);
      }
    }
  }

  writeStep('DRY RUN COMPLETE');
  console.log('No files were modified.');
}

/* ============================================================
 * BUILD DOWNLOAD LIST
 * ============================================================ */
async function buildDownloadList(options) {
  switch (options.source) {
    case 'alice':
      return buildAliceDownloadList(options);
    case 'url':
      return buildUrlDownloadList(options);
    case 'manifest':
      return buildManifestDownloadList(options);
    default:
      throw new Error(`Unsupported source: ${options.source}`);
  }
}

/* ============================================================
 * MAIN
 * ============================================================ */
async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    writeError(error.message);
    console.log('\nRun "node book_downloader.js --help" for usage.');
    process.exit(1);
  }

  console.log('');
  console.log(
    '============================================================'
  );
  console.log(' Portable Legal Book Downloader');
  console.log(
    '============================================================'
  );

  if (options.dryRun) {
    await dryRun(options);
    return;
  }

  /* Create normal working directories. */
  await ensureDirectory(options.output);
  await ensureDirectory(BACKUP_DIR);
  await ensureDirectory(INVENTORY_DIR);

  writeSuccess(`Books folder: ${options.output}`);
  writeSuccess(`Backup folder: ${BACKUP_DIR}`);
  writeSuccess(`Inventory folder: ${INVENTORY_DIR}`);

  /* Kindle. */
  let kindlePath = null;
  if (options.kindle) {
    kindlePath = getKindlePath(options);
    if (!kindlePath) {
      writeWarn('Kindle was not detected.');
      console.log('Continuing without Kindle copying.');
    } else {
      const kindleTest = await testKindle(kindlePath);
      if (!kindleTest.ok) {
        writeWarn(`Kindle is unavailable: ${kindleTest.message}`);
        kindlePath = null;
      } else {
        writeSuccess(`Kindle: ${kindlePath}`);
      }
    }
  }

  /* Build download list. */
  writeStep(`Building download list from ${options.source}...`);
  const downloads = await buildDownloadList(options);

  if (!downloads.length) {
    writeWarn('No downloadable books were found.');
    return;
  }

  writeSuccess(`Found ${downloads.length} book(s) to process.`);

  const records = [];

  /* Download books. */
  for (let index = 0; index < downloads.length; index++) {
    const book = downloads[index];
    const format = normalizeFormat(book.format || options.format);
    const filename = safeFilename(
      book.title || filenameFromUrl(book.url, format)
    );
    const finalFilename = filename.toLowerCase().endsWith(`.${format}`)
      ? filename
      : `${filename}.${format}`;
    const destination = path.join(options.output, finalFilename);

    console.log('');
    writeStep(`[${index + 1}/${downloads.length}] ${book.title}`);
    console.log(`URL: ${book.url}`);
    console.log(`Destination: ${destination}`);

    try {
      await downloadFile(book.url, destination, options);
      const stats = await fsp.stat(destination);
      writeSuccess(
        `Downloaded ${(stats.size / 1024 / 1024).toFixed(2)} MB`
      );

      let kindleDestination = null;
      if (kindlePath) {
        try {
          kindleDestination = await copyToKindle(destination, kindlePath);
          writeSuccess(`Copied to Kindle: ${kindleDestination}`);
        } catch (error) {
          writeWarn(`Kindle copy failed: ${error.message}`);
        }
      }

      records.push({
        title: book.title,
        url: book.url,
        format,
        file: destination,
        size: stats.size,
        downloadedAt: new Date().toISOString(),
        kindle: kindleDestination || null,
        status: 'success',
      });
    } catch (error) {
      writeError(`${book.title}: ${error.message}`);
      records.push({
        title: book.title,
        url: book.url,
        format,
        file: destination,
        downloadedAt: new Date().toISOString(),
        kindle: null,
        status: 'failed',
        error: error.message,
      });
    }

    if (index < downloads.length - 1 && options.delay > 0) {
      await sleep(options.delay);
    }
  }

  /* Write inventory. */
  await writeInventory(records);

  console.log('');
  writeStep('Finished');
  const successful = records.filter(
    (record) => record.status === 'success'
  ).length;
  const failed = records.filter(
    (record) => record.status === 'failed'
  ).length;
  writeSuccess(`Successful: ${successful}`);
  if (failed > 0) {
    writeWarn(`Failed: ${failed}`);
  }
  writeSuccess(`Inventory: ${INVENTORY_FILE}`);
  console.log('');
}

main().catch((error) => {
  console.error('');
  writeError(error.stack || error.message || String(error));
  process.exit(1);
});
