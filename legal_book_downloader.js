#!/usr/bin/env node
/* Download public-domain or otherwise authorized book files (Node.js 18+).
 * Supports Project Gutenberg, public Internet Archive items, direct authorized
 * URLs, JSON manifests, and copying completed files to a Kindle documents folder.
 */

'use strict';

const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { execFileSync } = require('node:child_process');

const USER_AGENT = 'LegalBookDownloader/1.0 (personal lawful-use downloader)';
const FORMATS = new Set(['epub', 'kindle', 'text', 'pdf']);

function usage(message, exitCode = 2) {
  if (message) console.error(`Error: ${message}\n`);
  console.error(`Usage:
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] gutenberg ID [--format epub|kindle|text|pdf]
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] gutenberg-batch ID... [--format FORMAT]
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] archive IDENTIFIER [--format epub|pdf|text]
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] archive-batch IDENTIFIER... [--format FORMAT]
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] json FILE [--format FORMAT] [--delay SECONDS] [--limit N]
  node legal_book_downloader.js [--output FOLDER] [--kindle [DOCUMENTS_FOLDER]] url URL --authorized`);
  process.exitCode = exitCode;
}

function parseArgs(argv) {
  const options = { output: 'books', kindle: null, format: null, delay: 2, limit: null, authorized: false };
  const positional = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--output') options.output = argv[++index];
    else if (arg === '--kindle') {
      const next = argv[index + 1];
      const sources = new Set(['gutenberg', 'gutenberg-batch', 'archive', 'archive-batch', 'json', 'url']);
      options.kindle = next && !next.startsWith('--') && !sources.has(next) ? argv[++index] : 'auto';
    } else if (arg === '--format') options.format = argv[++index];
    else if (arg === '--delay') options.delay = Number(argv[++index]);
    else if (arg === '--limit') options.limit = Number(argv[++index]);
    else if (arg === '--authorized') options.authorized = true;
    else positional.push(arg);
  }
  const source = positional.shift();
  return { options, source, positional };
}

function safeName(value) {
  return (value || 'book-download').replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_').replace(/[. ]+$/g, '') || 'book-download';
}

async function unusedPath(folder, name) {
  const initial = path.join(folder, safeName(name));
  if (!fs.existsSync(initial)) return initial;
  const parsed = path.parse(initial);
  for (let index = 2; ; index += 1) {
    const candidate = path.join(parsed.dir, `${parsed.name}-${index}${parsed.ext}`);
    if (!fs.existsSync(candidate)) return candidate;
  }
}

function responseName(response, fallback) {
  const disposition = response.headers.get('content-disposition') || '';
  const match = disposition.match(/filename\*?=(?:UTF-8''|")?([^";]+)/i);
  if (match) return safeName(match[1].trim());
  try { return safeName(path.basename(new URL(response.url).pathname) || fallback); } catch { return fallback; }
}

async function download(url, outputFolder, fallback) {
  await fsp.mkdir(outputFolder, { recursive: true });
  const response = await fetch(url, { headers: { 'User-Agent': USER_AGENT } });
  if (!response.ok) throw new Error(`Download failed: HTTP ${response.status} ${response.statusText}`);
  if ((response.headers.get('content-type') || '').toLowerCase().startsWith('text/html')) {
    throw new Error('The address returned an HTML page, not a book file.');
  }
  const target = await unusedPath(outputFolder, responseName(response, fallback));
  if (!response.body) throw new Error('Download returned no content.');
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(target, { flags: 'wx' }));
  return target;
}

function gutenbergUrl(id, format) {
  const suffixes = { epub: '.epub', kindle: '.kindle.images', text: '.txt.utf-8', pdf: '.txt.utf-8' };
  return `https://www.gutenberg.org/ebooks/${id}${suffixes[format]}`;
}

function pdfEscape(value) {
  return value.replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)').replace(/[^\x20-\x7e]/g, '?');
}

async function textToPdf(textFile, id) {
  const text = await fsp.readFile(textFile, 'utf8');
  const lines = text.split(/\r?\n/).flatMap(line => line.length ? (line.match(/.{1,92}/g) || ['']) : ['']);
  const pages = [];
  for (let index = 0; index < lines.length || index === 0; index += 54) pages.push(lines.slice(index, index + 54));
  const objects = [Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'), null, Buffer.from('<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>')];
  objects[1] = Buffer.from(`<< /Type /Pages /Kids [${pages.map((_, index) => `${4 + index * 2} 0 R`).join(' ')}] /Count ${pages.length} >>`);
  for (let index = 0; index < pages.length; index += 1) {
    const content = ['BT', '/F1 10 Tf', '50 742 Td', '12 TL', `(Project Gutenberg ebook ${id}) Tj`, 'T*', ...pages[index].map(line => `(${pdfEscape(line)}) Tj T*`), 'ET'].join('\n');
    const stream = Buffer.from(content, 'latin1');
    const pageNumber = 4 + index * 2;
    objects.push(Buffer.from(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${pageNumber + 1} 0 R >>`));
    objects.push(Buffer.concat([Buffer.from(`<< /Length ${stream.length} >>\nstream\n`), stream, Buffer.from('\nendstream')]));
  }
  const chunks = [Buffer.from('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n', 'latin1')];
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.concat(chunks).length);
    chunks.push(Buffer.from(`${index + 1} 0 obj\n`), object, Buffer.from('\nendobj\n'));
  });
  const startXref = Buffer.concat(chunks).length;
  chunks.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${startXref}\n%%EOF\n`));
  const target = await unusedPath(path.dirname(textFile), `${path.parse(textFile).name}.pdf`);
  await fsp.writeFile(target, Buffer.concat(chunks));
  await fsp.unlink(textFile);
  return target;
}

async function downloadGutenberg(id, format, output) {
  const result = await download(gutenbergUrl(id, format), output, `gutenberg-${id}${format === 'epub' ? '.epub' : '.txt'}`);
  return format === 'pdf' ? textToPdf(result, id) : result;
}

async function archiveFile(identifier, format) {
  if (format === 'kindle') throw new Error('Kindle is not supported for Internet Archive entries.');
  const response = await fetch(`https://archive.org/metadata/${encodeURIComponent(identifier)}`, { headers: { 'User-Agent': USER_AGENT } });
  if (!response.ok) throw new Error(`Could not read Internet Archive item metadata: HTTP ${response.status}`);
  const record = await response.json();
  if ([true, 'true', '1'].includes(record.metadata?.['access-restricted'])) throw new Error('This Internet Archive item is access-restricted.');
  const extension = { epub: '.epub', pdf: '.pdf', text: '.txt' }[format];
  const files = (record.files || []).filter(file => file.name?.toLowerCase().endsWith(extension))
    .filter(file => !/(scandata|abbyy|chocr|hocr|djvu\.xml)/i.test(`${file.name} ${file.format || ''}`));
  if (!files.length) throw new Error(`No downloadable ${format.toUpperCase()} file was found for '${identifier}'.`);
  files.sort((left, right) => `${left.name} ${left.format || ''}`.length - `${right.name} ${right.format || ''}`.length);
  const name = files[0].name;
  return { url: `https://archive.org/download/${encodeURIComponent(identifier)}/${encodeURIComponent(name)}`, name };
}

function kindleDocuments(value) {
  if (value !== 'auto') {
    if (/^this pc\\/i.test(value)) throw new Error("'This PC\\…' is a File Explorer display path. Use a drive path such as E:\\documents.");
    if (!fs.statSync(value, { throwIfNoEntry: false })?.isDirectory()) throw new Error(`Kindle documents folder does not exist: ${value}`);
    return value;
  }
  if (process.platform !== 'win32') throw new Error('Automatic Kindle detection is available on Windows only; pass --kindle <documents-folder>.');
  const command = "Get-Volume | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -match '^Kindle' } | Select-Object -ExpandProperty DriveLetter";
  let letters;
  try { letters = execFileSync('powershell.exe', ['-NoProfile', '-Command', command], { encoding: 'utf8' }).trim().split(/\s+/).filter(Boolean); } catch { throw new Error('Could not detect a Kindle drive; pass --kindle E:\\documents.'); }
  const folders = letters.map(letter => `${letter}:\\documents`).filter(folder => fs.statSync(folder, { throwIfNoEntry: false })?.isDirectory());
  if (folders.length === 1) return folders[0];
  throw new Error('No unique Kindle documents folder was detected; pass --kindle E:\\documents.');
}

async function copyToKindle(book, documents) {
  if (!['.epub', '.pdf', '.txt', '.mobi', '.azw', '.azw3'].includes(path.extname(book).toLowerCase())) throw new Error(`${path.basename(book)} is not a supported Kindle transfer format.`);
  const target = await unusedPath(documents, path.basename(book));
  await fsp.copyFile(book, target, fs.constants.COPYFILE_EXCL);
  return target;
}

async function saveAndReport(book, kindle) {
  console.log(`Saved: ${path.resolve(book)}`);
  if (kindle) console.log(`Copied to Kindle: ${await copyToKindle(book, kindle)}`);
}

async function main() {
  const { options, source, positional } = parseArgs(process.argv.slice(2));
  if (source === '--help' || source === '-h') return usage(null, 0);
  if (!source || !options.output || !Number.isFinite(options.delay) || options.delay < 0 || (options.limit !== null && (!Number.isInteger(options.limit) || options.limit < 1))) return usage('Invalid or missing argument.');
  if (options.format && !FORMATS.has(options.format)) return usage('Unknown format.');
  let kindle;
  try { kindle = options.kindle === null ? null : kindleDocuments(options.kindle); } catch (error) { console.error(error.message); process.exitCode = 1; return; }
  const format = options.format || (source === 'archive' || source === 'archive-batch' ? 'epub' : 'epub');
  let failures = 0;
  async function oneGutenberg(id, title = `Gutenberg ${id}`) { console.log(`${title} (#${id})`); const file = await downloadGutenberg(id, format, options.output); await saveAndReport(file, kindle); }
  async function oneArchive(identifier, title = `Internet Archive ${identifier}`) { console.log(`${title} (${identifier})`); const item = await archiveFile(identifier, format); const file = await download(item.url, options.output, item.name); await saveAndReport(file, kindle); }
  let entries = [];
  if (source === 'gutenberg') entries = [{ source: 'gutenberg', id: positional[0] }];
  else if (source === 'gutenberg-batch') entries = positional.map(id => ({ source: 'gutenberg', id }));
  else if (source === 'archive') entries = [{ source: 'archive', identifier: positional[0] }];
  else if (source === 'archive-batch') entries = positional.map(identifier => ({ source: 'archive', identifier }));
  else if (source === 'url') { if (!options.authorized || !positional[0]) return usage('url requires a URL and --authorized.'); entries = [{ source: 'url', url: positional[0] }]; }
  else if (source === 'json') {
    if (!positional[0]) return usage('json requires a manifest filename.');
    try { entries = JSON.parse(await fsp.readFile(positional[0], 'utf8')); } catch (error) { console.error(`Could not read JSON book list: ${error.message}`); process.exitCode = 1; return; }
    if (!Array.isArray(entries)) return usage('The JSON book list must contain an array.');
  } else return usage('Unknown source.');
  if (options.limit !== null) entries = entries.slice(0, options.limit);
  for (let index = 0; index < entries.length; index += 1) {
    const entry = entries[index];
    try {
      const entrySource = String(entry.source || 'gutenberg').toLowerCase();
      if (entrySource === 'gutenberg') { const id = Number(entry.id); if (!Number.isInteger(id) || id < 1) throw new Error('invalid Gutenberg id'); await oneGutenberg(id, entry.title); }
      else if (entrySource === 'archive') { if (!entry.identifier) throw new Error('invalid Archive identifier'); await oneArchive(String(entry.identifier), entry.title); }
      else if (entrySource === 'url') { if (!entry.url) throw new Error('invalid authorized URL'); const file = await download(entry.url, options.output, 'authorized-book'); await saveAndReport(file, kindle); }
      else throw new Error(`unsupported source '${entrySource}'`);
    } catch (error) { failures += 1; console.error(`Entry ${index + 1}: ${error.message}`); }
    if (index < entries.length - 1 && (source === 'json' || source.endsWith('-batch'))) await new Promise(resolve => setTimeout(resolve, options.delay * 1000));
  }
  console.log(`Finished: ${entries.length - failures} downloaded, ${failures} failed.`);
  process.exitCode = failures ? 1 : 0;
}

main().catch(error => { console.error(error.stack || error.message); process.exitCode = 1; });
