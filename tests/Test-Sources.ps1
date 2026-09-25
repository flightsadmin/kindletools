#requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'KindleManager.ps1')
function Start-Sleep { param($Milliseconds, $Seconds) }
function Invoke-BookWebRequest {
    param($Uri, $TimeoutMs, $Accept)
    $content = switch -Regex ($Uri) {
        'sitemap\.xml$' { '<urlset><url><loc>https://www.globalgreyebooks.com/pride-and-prejudice-ebook.html</loc></url></urlset>' }
        'pg_catalog\.csv$' {
            'Text#,Type,Title,Language,Authors,Subjects,Bookshelves' + "`n" +
            '1,Text,Nonfiction,en,Author,History,History' + "`n" +
            '1342,Text,Pride and Prejudice,en,Jane Austen,Fiction,Classics' + "`n" +
            '999,Text,French novel,fr,Author,Fiction,Classics'
        }
        'fiction-page-1\.html$' {
            '<a href="/missing-ebook.html">Missing PDF</a><a href="/category/ebooks/fiction-page-2.html">Next</a>'
        }
        'fiction-page-2\.html$' {
            '<a href="/pride-and-prejudice-ebook.html"><img src="cover.jpg"></a><a href="/pride-and-prejudice-ebook.html">Pride and Prejudice</a><a href="/pride-and-prejudice-ebook.html">Duplicate</a>'
        }
        '/missing-ebook\.html$' { '<a href="/ebooks/missing.epub">EPUB</a>' }
        '/pride-and-prejudice-ebook\.html$' {
            '<a href="/ebooks/austen.pdf">PDF</a><a href="/ebooks/austen.epub">EPUB</a><a href="/ebooks/austen.azw3">AZW3</a>'
        }
        default { throw "Unexpected request: $Uri" }
    }
    [pscustomobject]@{ Content = $content; StatusCode = 200 }
}
$options = [pscustomobject]@{ Source='gutenberg'; Search='Austen'; Format='epub'; Limit=1; Delay=0; Timeout=1000 }
$books = @(Build-DownloadList $options)
if ($books.Count -ne 1 -or $books[0].Title -ne 'Pride and Prejudice' -or $books[0].Url -notmatch '/1342/pg1342-images\.epub$') { throw 'Gutenberg filtering or URL resolution failed.' }
$options.Format = 'mobi'
if ((Build-DownloadList $options).Url -notmatch '-images-kf8\.mobi$') { throw 'Wrong Gutenberg Kindle URL.' }
$options.Format = 'pdf'
$rejected = $false
try { $null = Build-DownloadList $options } catch { $rejected = $_.Exception.Message -match 'not PDF' }
if (-not $rejected) { throw 'Gutenberg PDF must be rejected clearly.' }
$options.Source = 'globalgrey'
$options.Search = ''
$books = @(Build-DownloadList $options)
if ($books.Count -ne 1 -or $books[0].Title -ne 'Pride and Prejudice' -or $books[0].Extension -ne 'pdf') { throw 'Global Grey pagination, format filtering, or deduplication failed.' }
$options.Format = 'mobi'
$options.Search = 'Pride'
$books = @(Build-DownloadList $options)
if ($books.Count -ne 1 -or $books[0].Extension -ne 'azw3') { throw 'Global Grey search or Kindle format failed.' }
$options.Search = 'No matching title'
if (@(Build-DownloadList $options).Count -ne 0) { throw 'Title filter was ignored.' }
Write-Host 'All source checks passed.' -ForegroundColor Green

& {
    $script:STANDARD_URL = 'https://standardebooks.org'
    $script:STANDARD_EBOOKS_URL = "$script:STANDARD_URL/ebooks"
    $script:ALICE_URL = 'https://www.aliceandbooks.com'
    $requested = [Collections.Generic.List[string]]::new()
    function Invoke-BookWebRequest {
        param($Uri, $TimeoutMs, $Accept)
        $requested.Add($Uri)
        $content = switch -Regex ($Uri) {
            'standardebooks.org' {
                if ($Uri -notmatch 'query=Pride%20and%20Prejudice') { throw 'Search query was not encoded.' }
                '<li typeof="schema:Book" about="/ebooks/jane-austen/pride-and-prejudice"><span property="schema:name">Pride and Prejudice</span></li>'
            }
            '/sitemap$' {
                '<a href="/book/unrelated/author/1">Unrelated recommendation</a><a href="/book/pride-and-prejudice/jane-austen/2"><img src="cover.jpg"></a><a href="/book/pride-and-prejudice/jane-austen/2">Pride and Prejudice</a>'
            }
            '/book/pride-and-prejudice/' { '<a href="https://www.aliceandbooks.com/download/book.epub">EPUB</a>' }
            'globalgrey' { throw 'Simulated unavailable library' }
            'pg_catalog' { 'Text#,Type,Title,Language,Authors,Subjects,Bookshelves' + "`n" + '1342,Text,Pride and Prejudice,en,Jane Austen,Fiction,Classics' }
            default { throw "Unexpected request: $Uri" }
        }
        [pscustomobject]@{ Content = $content; StatusCode = 200 }
    }
    $options = [pscustomobject]@{ Source='all'; Search='Pride and Prejudice'; Format='epub'; Limit=1; CandidateLimit=1; Delay=0; Timeout=1000; Deadline=$null }
    $books = @(Build-DownloadList $options)
    if ($books.Count -ne 3) { throw 'Search must continue across libraries after a failure.' }
    if (($books.Source -join ',') -ne 'standard,alice,gutenberg') { throw 'Search lost source provenance.' }
    if ($books.Title -contains 'Unrelated recommendation') { throw 'Search included an unrelated recommendation.' }
    $requested.Clear()
    $options.Format = 'pdf'
    $null = @(Build-DownloadList $options)
    if (@($requested | Where-Object { $_ -match 'standardebooks|pg_catalog' }).Count) { throw 'PDF search queried unsupported libraries.' }

    $answers = [Collections.Generic.Queue[string]]::new()
    @('99', '1,2', '2,2') | ForEach-Object { $answers.Enqueue($_) }
    function Read-DownloadInput { param($Prompt) if (-not $answers.Count) { throw 'Unexpected prompt' }; $answers.Dequeue() }
    $selected = @(Select-SearchBooks -Books $books -Limit 1)
    if ($selected.Count -ne 1 -or $selected[0].Source -ne 'alice' -or $answers.Count) { throw 'Result selection validation failed.' }
    $answers.Enqueue('')
    if (@(Select-SearchBooks -Books $books -Limit 0).Count) { throw 'Search cancellation selected books.' }
}
Write-Host 'All cross-library search checks passed.' -ForegroundColor Green
