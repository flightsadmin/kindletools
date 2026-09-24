#requires -Version 5.1
<#
.SYNOPSIS
Download books and manage a Kindle from one self-contained script.
.\KindleManager.ps1
.\KindleManager.ps1 -Mode Transfer
.\KindleManager.ps1 -Source standard -Format epub -Limit 3
#>
param(
    [ValidateSet('Menu', 'Download', 'Transfer', 'Test')]
    [string]$Mode = 'Menu',

    [ValidateSet('standard', 'alice', 'globalgrey', 'gutenberg', 'url', 'manifest')]
    [string]$Source,

    [string]$Search,

    [string[]]$Category,

    [string]$Url,

    [string]$Manifest,

    [string]$Output,

    [switch]$Kindle,

    [string]$KindlePath,

    [ValidateSet('pdf', 'epub', 'mobi', 'kindle')]
    [string]$Format = 'mobi',

    [int]$Delay = 2000,

    [int]$Limit = 3,   # 0 = unlimited

    [int]$Retries = 1,

    [int]$Timeout = 30000,

    [int]$MaxRuntimeMinutes = 10,

    [switch]$DryRun,

    [switch]$Interactive,

    [switch]$Help
)



#region Configuration
# Data folders always live beside this script, regardless of the working directory.
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $script:ProjectRoot = $PSScriptRoot
} else {
    # Supports: irm <raw-url> | iex in Windows PowerShell 5.1.
    $script:ProjectRoot = (Get-Location).Path
}
$script:BOOKS_DIR = Join-Path $script:ProjectRoot 'books'
$script:BACKUP_DIR = Join-Path $script:ProjectRoot 'backup'
$script:DOWNLOAD_RECORDS_DIR = Join-Path $script:ProjectRoot 'downloads'
$script:KindleDirectExtensions = @('.azw3', '.azw', '.mobi', '.pdf')
#endregion

#region Shared prompts, logging, and file helpers
function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-WarnMsg([string]$Message) {
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrMsg([string]$Message) {
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Ensure-Directory([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

function Invoke-SelfRepair {
    param([string]$OutputFolder = $script:BOOKS_DIR)
    $fixed = 0
    foreach ($folder in @($OutputFolder, $script:BACKUP_DIR, $script:DOWNLOAD_RECORDS_DIR)) {
        try {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                Ensure-Directory $folder
                $fixed++
            }
        } catch {
            Write-WarnMsg "Could not create folder ${folder}: $($_.Exception.Message)"
        }
    }

    # A failed download can leave a temporary .download file. Remove only
    # files created by this application and only after they are one hour old.
    try {
        $cutoff = (Get-Date).AddHours(-1)
        foreach ($partial in @(Get-ChildItem -LiteralPath $OutputFolder -Filter '*.download' -File -ErrorAction SilentlyContinue)) {
            if ($partial.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $partial.FullName -Force
                $fixed++
                Write-WarnMsg "Removed abandoned partial download: $($partial.Name)"
            }
        }
    } catch {
        Write-WarnMsg "Could not clean partial downloads: $($_.Exception.Message)"
    }

    # Preserve malformed records for recovery, then let the downloader rebuild
    # a clean source record after the next successful download.
    if (Test-Path -LiteralPath $script:DOWNLOAD_RECORDS_DIR -PathType Container) {
        foreach ($recordFile in @(Get-ChildItem -LiteralPath $script:DOWNLOAD_RECORDS_DIR -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try {
                $null = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                $quarantine = "$($recordFile.FullName).invalid.$((Get-Date).ToString('yyyyMMddHHmmss'))"
                try {
                    Move-Item -LiteralPath $recordFile.FullName -Destination $quarantine -Force
                    $fixed++
                    Write-WarnMsg "Quarantined invalid download record: $($recordFile.Name)"
                } catch {
                    Write-WarnMsg "Could not quarantine invalid record $($recordFile.Name)."
                }
            }
        }
    }
    if ($fixed -gt 0) { Write-Success "Self-repair completed: fixed $fixed item(s)." }
}

function Read-DownloadInput {
    param([string]$Prompt)
    Write-Host "  $Prompt" -ForegroundColor Yellow
    Write-Host '  > ' -ForegroundColor Cyan -NoNewline
    return (Read-Host)
}

function Write-DownloadSetting {
    param([string]$Label, [string]$Value)
    Write-Host ('  {0,-12}' -f $Label) -ForegroundColor Gray -NoNewline
    Write-Host $Value -ForegroundColor Green
}

function Read-Choice {
    param(
        [string]$Prompt,
        [hashtable[]]$Choices,
        [string]$DefaultKey
    )

    Write-Host ''
    Write-Host $Prompt -ForegroundColor Cyan
    foreach ($c in $Choices) {
        $marker = if ($c.Key -eq $DefaultKey) { ' (default)' } else { '' }
        Write-Host ("  [{0}] " -f $c.Key) -ForegroundColor Yellow -NoNewline
        Write-Host $c.Label -ForegroundColor White -NoNewline
        Write-Host $marker -ForegroundColor Green
    }

    while ($true) {
        $answer = (Read-DownloadInput "Choose a number (ENTER = $DefaultKey)").Trim()
        if ([string]::IsNullOrEmpty($answer)) { $answer = $DefaultKey }
        $found = $Choices | Where-Object { $_.Key -eq $answer } | Select-Object -First 1
        if ($found) {
            Write-Host "  Selected: $($found.Label)" -ForegroundColor Green
            return $found.Value
        }
        Write-Host '  Invalid choice. Enter one of the numbers above.' -ForegroundColor Red
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-DownloadInput "$Prompt [$hint]").Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($answer)) { return $DefaultYes }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-Host '  Please enter y or n.' -ForegroundColor Red
    }
}

function Pause-Screen {
    Write-Host ""
    Read-Host "Press ENTER to continue" | Out-Null
}

function Format-Size {
    param(
        [AllowNull()]
        [double]$Bytes
    )

    if ($null -eq $Bytes) {
        return "Unknown"
    }

    if ($Bytes -lt 0) {
        return "Unknown"
    }

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "{0:N0} bytes" -f $Bytes
}
#endregion

#region Download helpers and help text
function Normalize-Format([string]$Format) {
    if ([string]::IsNullOrWhiteSpace($Format)) { return 'pdf' }
    $n = $Format.Trim().ToLowerInvariant().TrimStart('.')
    if ($n -eq 'kindle') { return 'mobi' }
    return $n
}

function Test-SupportedFormat([string]$Format) {
    $n = Normalize-Format $Format
    return $n -in @('epub', 'pdf', 'mobi')
}

function Get-SafeFilename([string]$Value, [string]$Fallback = 'book') {
    $name = if ([string]::IsNullOrWhiteSpace($Value)) { $Fallback } else { $Value }
    $invalid = [IO.Path]::GetInvalidFileNameChars() + @('<', '>', ':', '"', '/', '\', '|', '?', '*')
    foreach ($c in $invalid) {
        $name = $name.Replace([string]$c, ' ')
    }
    $name = ($name -replace '\s+', ' ').Trim().TrimEnd('.', ' ')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $Fallback }
    return $name
}

function Resolve-PortablePath([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Script:SCRIPT_DIR }
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    return [IO.Path]::GetFullPath((Join-Path $Script:SCRIPT_DIR $Value))
}

function Get-ExtensionFromUrl([string]$Url, [string]$Fallback = 'epub') {
    try {
        $uri = [Uri]$Url
        $path = [Uri]::UnescapeDataString($uri.AbsolutePath)
        if ($path -match '\.(epub|pdf|mobi|azw3)$') {
            $ext = $Matches[1].ToLowerInvariant()
            if ($ext -eq 'azw3') { return 'mobi' }
            return $ext
        }
    } catch { }
    return (Normalize-Format $Fallback)
}

function Get-FilenameFromUrl([string]$Url, [string]$FallbackFormat = 'epub') {
    try {
        $uri = [Uri]$Url
        $filename = [IO.Path]::GetFileName([Uri]::UnescapeDataString($uri.AbsolutePath))
        if ($filename) {
            $filename = Get-SafeFilename $filename
            if ($filename -match '\.(epub|pdf|mobi|azw3)$') { return $filename }
        }
    } catch { }
    $fmt = Get-ExtensionFromUrl $Url $FallbackFormat
    return "book.$fmt"
}

function Get-TitleFromUrl([string]$Url) {
    try {
        $uri = [Uri]$Url
        $title = [IO.Path]::GetFileName([Uri]::UnescapeDataString($uri.AbsolutePath))
        $title = $title -replace '\.(epub|pdf|mobi|azw3)$', ''
        $title = ($title -replace '[-_]+', ' ' -replace '\s+', ' ').Trim()
        if ($title) { return $title }
    } catch { }
    return 'Book'
}

function Test-HttpUrl([string]$Value) {
    try {
        $uri = [Uri]$Value
        return ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https')
    } catch {
        return $false
    }
}

function Show-Help {
    @"

KindleManager.ps1
Portable book downloader (PowerShell).

SOURCES
  standard           Download from Standard Ebooks (default in interactive)
  alice              Download from AliceAndBooks
  globalgrey         Fiction / Sci-Fi catalogue from Global Grey (PDF, EPUB, AZW3)
  gutenberg          English books from Project Gutenberg (EPUB, Kindle)
  url                Download from a direct authorized URL
  manifest           Download from a JSON manifest

OPTIONS
  -Source <source>       standard | alice | globalgrey | gutenberg | url | manifest
  -Search <text>        Title filter for Global Grey; title/author for Gutenberg
  -Category <name>      Fiction, Romance, or Sci-Fi; source-dependent
  -Url <url>             Direct authorized book URL (sets source=url)
  -Manifest <file>       JSON manifest file (sets source=manifest)
  -Output <folder>       Download destination (default: ./books)
  -Kindle                Copy downloaded books to Kindle
  -KindlePath <folder>   Kindle documents folder (auto-detect if omitted)
  -Format <format>       epub | pdf | mobi | kindle  (default: mobi)
  -Delay <ms>            Delay between downloads (default: 1000)
  -Limit <n>             Max number of books (default: 3; 0 = unlimited)
  -Retries <n>           Download attempts (default: 1; no retries)
  -Timeout <ms>          Download timeout (default: 30000)
  -MaxRuntimeMinutes <n> Stop after this many minutes (default: 10; 0 = no limit)
  -DryRun                Test only; no downloads or file changes
  -Interactive           Force interactive menu
  -Help                  Show this help

EXAMPLES
  .\KindleManager.ps1
  .\KindleManager.ps1 -Interactive
  .\KindleManager.ps1 -Source standard -Limit 10
  .\KindleManager.ps1 -Url "https://example.com/book.epub"
  .\KindleManager.ps1 -Manifest books.json
  .\KindleManager.ps1 -Source standard -Format mobi -Kindle
  .\KindleManager.ps1 -DryRun -Source standard -Limit 3

"@ | Write-Host
}
#endregion

function Test-DownloadTimeLimit {
    param($Options)

    if (-not $Options.Deadline) { return $false }
    if ([DateTime]::UtcNow -lt $Options.Deadline) { return $false }
    if (-not ($Options.PSObject.Properties.Name -contains 'TimeLimitReported' -and $Options.TimeLimitReported)) {
        Write-WarnMsg "Maximum runtime of $($Options.MaxRuntimeMinutes) minute(s) reached. Finishing without starting more downloads."
        $Options | Add-Member -NotePropertyName TimeLimitReported -NotePropertyValue $true -Force
    }
    return $true
}

#region HTTP requests
function Invoke-BookWebRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [string]$Accept = '*/*',
        [int]$TimeoutMs = 30000,
        [string]$OutFile
    )

    $headers = @{
        'User-Agent' = $Script:USER_AGENT
        'Accept'     = $Accept
    }

    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $headers
        TimeoutSec      = [Math]::Max(1, [int]($TimeoutMs / 1000))
        UseBasicParsing = $true
        MaximumRedirection = 5
    }

    if ($OutFile) {
        $params['OutFile'] = $OutFile
    }

    return Invoke-WebRequest @params
}

function Test-BookUrl {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutMs = 30000
    )

    if (-not (Test-HttpUrl $Uri)) {
        return [pscustomobject]@{ Ok = $false; Status = 0; Message = 'Invalid HTTP/HTTPS URL' }
    }

    try {
        $resp = $null
        try {
            $resp = Invoke-BookWebRequest -Uri $Uri -Method HEAD -TimeoutMs $TimeoutMs
        } catch {
            # Some servers reject HEAD
            $resp = Invoke-BookWebRequest -Uri $Uri -Method GET -TimeoutMs $TimeoutMs
        }
        $code = [int]$resp.StatusCode
        return [pscustomobject]@{
            Ok      = ($code -ge 200 -and $code -lt 400)
            Status  = $code
            Message = if ($code -ge 200 -and $code -lt 400) { 'OK' } else { "HTTP $code" }
        }
    } catch {
        return [pscustomobject]@{
            Ok      = $false
            Status  = 0
            Message = $_.Exception.Message
        }
    }
}
#endregion

#region Book sources and manifests
function Strip-Html([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $t = $Value
    $t = [regex]::Replace($t, '<script\b[^>]*>[\s\S]*?</script>', ' ', 'IgnoreCase')
    $t = [regex]::Replace($t, '<style\b[^>]*>[\s\S]*?</style>', ' ', 'IgnoreCase')
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = $t -replace '&nbsp;', ' ' -replace '&amp;', '&' -replace '&quot;', '"'
    $t = $t -replace '&#39;', "'" -replace '&lt;', '<' -replace '&gt;', '>'
    $t = ($t -replace '\s+', ' ').Trim()
    return $t
}

function Get-HtmlLinks {
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$BaseUrl
    )

    $results = New-Object System.Collections.Generic.List[object]
    $regex = [regex]'<a\b[^>]*href\s*=\s*["'']([^"'']+)["''][^>]*>([\s\S]*?)</a>'
    foreach ($m in $regex.Matches($Html)) {
        $href = $m.Groups[1].Value
        $text = Strip-Html $m.Groups[2].Value
        try {
            $abs = [Uri]::new([Uri]$BaseUrl, $href).AbsoluteUri
            $results.Add([pscustomobject]@{ Url = $abs; Text = $text })
        } catch { }
    }
    return $results
}

function Get-StandardSlugFromPath([string]$Pathname) {
    $parts = $Pathname.Trim('/').Replace('ebooks/', '') -split '/' | Where-Object { $_ }
    # pathname like /ebooks/author/title/...
    $clean = ($Pathname -replace '^/ebooks/', '' -replace '/+$', '')
    return ($clean -split '/' -join '_')
}

function Get-StandardDownloadInfo {
    param(
        [Parameter(Mandatory)][string]$PagePath,
        [string]$PreferredFormat = 'epub'
    )

    $slug = Get-StandardSlugFromPath $PagePath
    $base = "$($Script:STANDARD_URL)$($PagePath.TrimEnd('/'))/downloads"
    $fmt = Normalize-Format $PreferredFormat

    if ($fmt -eq 'pdf') {
        throw 'Standard Ebooks does not offer PDF downloads. Select AliceAndBooks for PDF, or choose EPUB.'
    }

    if ($fmt -eq 'mobi') {
        return [pscustomobject]@{
            # Use the file URL from the site's download-page redirect.
            Url       = "$base/$slug.azw3?source=download"
            Format    = 'mobi'
            Extension = 'azw3'
        }
    }

    return [pscustomobject]@{
        Url       = "$base/$slug.epub?source=download"
        Format    = 'epub'
        Extension = 'epub'
    }
}

function Get-StandardBooks {
    param($Options)

    Write-Step 'Reading Standard Ebooks catalogue...'
    $books = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $maxPages = 200
    $page = 1
    $emptyStreak = 0
    $limit = if ($Options.CandidateLimit -gt 0) { $Options.CandidateLimit } elseif ($Options.Limit -gt 0) { $Options.Limit } else { [int]::MaxValue }
    $hasCategoryFilter = @($Options.Category).Count -gt 0
    $bookItemRegex = [regex]'<li\b[^>]*typeof\s*=\s*["'']schema:Book["''][^>]*about\s*=\s*["'']([^"'']+)["''][^>]*>([\s\S]*?)</li>'
    $nameRegex = [regex]'property\s*=\s*["'']schema:name["''][^>]*>([^<]+)<'
    $subjects = if ($hasCategoryFilter) { @($Options.Category) } else { @('') }

    foreach ($subject in $subjects) {
      $page = 1
      $emptyStreak = 0
      while ($page -le $maxPages) {
        if (Test-DownloadTimeLimit -Options $Options) { break }
        $baseUrl = if ($subject) { "$($Script:STANDARD_URL)/subjects/$subject" } else { $Script:STANDARD_EBOOKS_URL }
        $url = "${baseUrl}?per-page=48&page=$page"
        try {
            $resp = Invoke-BookWebRequest -Uri $url -Accept 'text/html,application/xhtml+xml' -TimeoutMs $Options.Timeout
        } catch {
            if ($page -eq 1) { throw "Standard Ebooks request failed: $($_.Exception.Message)" }
            break
        }

        $html = $resp.Content
        $foundOnPage = 0

        foreach ($m in $bookItemRegex.Matches($html)) {
            $pagePath = $m.Groups[1].Value.Trim()
            if (-not $pagePath.StartsWith('/')) { $pagePath = "/$pagePath" }
            $pagePath = $pagePath.TrimEnd('/')

            if ($pagePath -notmatch '^/ebooks/[^/]+/[^/]+') { continue }
            if ($pagePath -match '/downloads') { continue }
            if ($seen.ContainsKey($pagePath)) { continue }
            $seen[$pagePath] = $true
            $foundOnPage++
            $block = $m.Groups[2].Value
            $title = $null
            $nm = $nameRegex.Match($block)
            if ($nm.Success) { $title = Strip-Html $nm.Groups[1].Value }
            if ([string]::IsNullOrWhiteSpace($title)) {
                $segs = $pagePath -replace '^/ebooks/', '' -split '/'
                $title = ($segs[1] -replace '[-_]+', ' ')
            }

            $books.Add([pscustomobject]@{
                Title    = $title
                PagePath = $pagePath
                PageUrl  = "$($Script:STANDARD_URL)$pagePath"
            })
        }

        if ($foundOnPage -eq 0) {
            $emptyStreak++
            if ($emptyStreak -ge 2) { break }
        } else {
            $emptyStreak = 0
        }

        if ($books.Count -ge $limit) { break }

        $page++
        if ($Options.Delay -gt 0) {
            Start-Sleep -Milliseconds ([Math]::Min($Options.Delay, 500))
        }
      }
    }

    return $books
}

function Build-StandardDownloadList {
    param($Options)

    $books = @(Get-StandardBooks -Options $Options)
    if ($books.Count -eq 0) {
        throw 'No books were found on Standard Ebooks.'
    }

    $limit = if (@($Options.Category).Count -gt 0) { $books.Count } elseif ($Options.CandidateLimit -gt 0) { $Options.CandidateLimit } elseif ($Options.Limit -gt 0) { $Options.Limit } else { $books.Count }
    $selected = $books | Select-Object -First $limit
    $downloads = New-Object System.Collections.Generic.List[object]

    foreach ($book in $selected) {
        $dl = Get-StandardDownloadInfo -PagePath $book.PagePath -PreferredFormat $Options.Format
        $downloads.Add([pscustomobject]@{
            Url       = $dl.Url
            Title     = $book.Title
            Format    = $dl.Format
            Extension = $dl.Extension
        })
    }

    return $downloads
}

function Get-AliceBookId([string]$Url) {
    if ($Url -match '/book/([^/?#]+)') { return $Matches[1] }
    return $null
}

function Get-AliceBooks {
    param($Options)

    Write-Step 'Reading AliceAndBooks catalogue...'
    $books = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $catalogueUrls = if (@($Options.Category).Count -gt 0) { @($Options.Category) } else { @($Script:ALICE_URL) }
    foreach ($catalogueUrl in $catalogueUrls) {
        $url = $catalogueUrl
        $seenPages = @{}
        $categoryCount = 0
        while ($url -and -not $seenPages.ContainsKey($url)) {
            if (Test-DownloadTimeLimit -Options $Options) { return $books }
            $seenPages[$url] = $true
            $resp = Invoke-BookWebRequest -Uri $url -Accept 'text/html' -TimeoutMs $Options.Timeout
            if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) { throw "AliceAndBooks returned HTTP $($resp.StatusCode)" }
            $links = @(Get-HtmlLinks -Html $resp.Content -BaseUrl $url)
            foreach ($link in $links) {
                if (([uri]$link.Url).Host -ne 'www.aliceandbooks.com' -or $link.Url -notmatch '/book/') { continue }
                $id = Get-AliceBookId $link.Url
                if (-not $id -or $seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                $title = if ($link.Text) { $link.Text } else { ($id -replace '[-_]+', ' ') }
                $books.Add([pscustomobject]@{ Id = $id; Title = $title; PageUrl = $link.Url })
                $categoryCount++
                if ($Options.CandidateLimit -gt 0 -and $categoryCount -ge $Options.CandidateLimit) { break }
            }
            if ($Options.CandidateLimit -gt 0 -and $categoryCount -ge $Options.CandidateLimit) { break }
            $next = $links | Where-Object { ([uri]$_.Url).Host -eq 'www.aliceandbooks.com' -and $_.Text -match '^(Next|Older|›|»)' } | Select-Object -First 1
            $url = if ($next) { $next.Url } else { $null }
            if ($url) { Start-Sleep -Milliseconds ([Math]::Min([Math]::Max(0, $Options.Delay), 500)) }
        }
    }

    return $books
}

function Get-AliceBookDownload {
    param(
        $Book,
        $Options
    )

    $resp = Invoke-BookWebRequest -Uri $Book.PageUrl -Accept 'text/html' -TimeoutMs $Options.Timeout
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        throw "Book page returned HTTP $($resp.StatusCode)"
    }

    $links = Get-HtmlLinks -Html $resp.Content -BaseUrl $Book.PageUrl
    $preferred = Normalize-Format $Options.Format

    foreach ($link in $links) {
        $directFormat = if ($link.Url -match '\.(epub|pdf|mobi)(?:[?#]|$)') { $Matches[1].ToLowerInvariant() } else { '' }
        $isDownloadEndpoint = ([Uri]$link.Url).AbsolutePath -match '^/book/download-link/\d+/\d+/?$'
        $labelMatches = $link.Text -match "(?i)\b$preferred\b"
        if ($directFormat -eq $preferred -or ($isDownloadEndpoint -and $labelMatches)) {
            return [pscustomobject]@{
                Url    = $link.Url
                Title  = $Book.Title
                Format = $preferred
            }
        }
    }

    throw "No $($preferred.ToUpperInvariant()) download found for `"$($Book.Title)`""
}

function Build-AliceDownloadList {
    param($Options)

    $books = @(Get-AliceBooks -Options $Options)
    if ($books.Count -eq 0) {
        throw 'No books were found on AliceAndBooks.'
    }

    $limit = if (@($Options.Category).Count -gt 0) { $books.Count } elseif ($Options.CandidateLimit -gt 0) { $Options.CandidateLimit } elseif ($Options.Limit -gt 0) { $Options.Limit } else { $books.Count }
    $selected = $books | Select-Object -First $limit
    $downloads = New-Object System.Collections.Generic.List[object]

    foreach ($book in $selected) {
        try {
            $dl = Get-AliceBookDownload -Book $book -Options $Options
            $downloads.Add($dl)
        } catch {
            Write-WarnMsg "$($book.Title): $($_.Exception.Message)"
        }
    }

    return $downloads
}

function Build-GutenbergDownloadList {
    param($Options)
    $format = Normalize-Format $Options.Format
    if ($format -eq 'pdf') {
        throw 'Project Gutenberg source supports EPUB and Kindle, not PDF. Choose EPUB or use Global Grey for PDF.'
    }
    Write-Step 'Reading Project Gutenberg fiction catalogue...'
    # Official machine-readable metadata avoids scraping the human-facing search pages.
    $response = Invoke-BookWebRequest -Uri 'https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv' -TimeoutMs $Options.Timeout -Accept 'text/csv'
    $catalogue = $response.Content | ConvertFrom-Csv
    $categoryPatterns = @{
        'Fiction' = '\bfiction\b'
        'Romance' = 'romance|love stories'
        'Sci-Fi' = 'science fiction|\bsci[- ]fi\b'
    }
    $selectedCategories = @($Options.Category | Where-Object { $_ -and $categoryPatterns.ContainsKey($_) })
    $matches = @($catalogue | Where-Object {
        $metadata = "$($_.Subjects);$($_.Bookshelves)"
        $categoryMatch = $false
        if ($selectedCategories.Count -gt 0) {
            foreach ($categoryName in $selectedCategories) {
                if ($metadata -match $categoryPatterns[$categoryName]) { $categoryMatch = $true; break }
            }
        } else {
            $categoryMatch = $metadata -match '\bFiction\b'
        }
        $_.Type -eq 'Text' -and $_.Language -eq 'en' -and $categoryMatch -and
        (-not $Options.Search -or ([string]$_.Title).IndexOf($Options.Search, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         ([string]$_.Authors).IndexOf($Options.Search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    if ($Options.CandidateLimit -gt 0) { $matches = @($matches | Select-Object -First $Options.CandidateLimit) }
    foreach ($book in $matches) {
        $id = [string]$book.'Text#'
        if ($id -notmatch '^\d+$') { continue }
        $suffix = if ($format -eq 'epub') { 'images.epub' } else { 'images-kf8.mobi' }
        [pscustomobject]@{
            Title = ($book.Title -replace '\s+', ' ').Trim()
            Url = "https://www.gutenberg.org/cache/epub/$id/pg$id-$suffix"
            Format = $format
            Extension = $format
        }
    }
}

function Get-GlobalGreyDownload {
    param([string]$PageUrl, [string]$Title, $Options)
    $response = Invoke-BookWebRequest -Uri $PageUrl -TimeoutMs $Options.Timeout -Accept 'text/html'
    $format = Normalize-Format $Options.Format
    $extension = if ($format -eq 'mobi') { 'azw3' } else { $format }
    foreach ($link in (Get-HtmlLinks -Html $response.Content -BaseUrl $PageUrl)) {
        $uri = [uri]$link.Url
        if ($uri.Host -eq 'www.globalgreyebooks.com' -and $uri.AbsolutePath -match "\.$extension`$") {
            return [pscustomobject]@{ Title = $Title; Url = $link.Url; Format = $format; Extension = $extension }
        }
    }
    throw "No $extension download found for $Title."
}

function Build-GlobalGreyDownloadList {
    param($Options)
    Write-Step 'Reading Global Grey catalogue...'
    $selectedCategories = @($Options.Category | Where-Object { $_ })
    $categoryPages = if ($selectedCategories.Count -gt 0) { $selectedCategories } else { @('https://www.globalgreyebooks.com/category/ebooks/fiction-page-1.html') }
    $seenPages = @{}
    $seenBooks = @{}
    foreach ($categoryPage in $categoryPages) {
        $url = $categoryPage
        $categoryCount = 0
        while ($url -and -not $seenPages.ContainsKey($url)) {
            if (Test-DownloadTimeLimit -Options $Options) { return }
            $seenPages[$url] = $true
            $response = Invoke-BookWebRequest -Uri $url -TimeoutMs $Options.Timeout -Accept 'text/html'
            $links = @(Get-HtmlLinks -Html $response.Content -BaseUrl $url)
            foreach ($link in $links) {
                if (Test-DownloadTimeLimit -Options $Options) { return }
                $uri = [uri]$link.Url
                if ($uri.Host -ne 'www.globalgreyebooks.com' -or $uri.AbsolutePath -notmatch '-ebook\.html$' -or
                    -not $link.Text -or $seenBooks.ContainsKey($link.Url)) { continue }
                $seenBooks[$link.Url] = $true
                if ($Options.Search -and $link.Text.IndexOf($Options.Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                Start-Sleep -Milliseconds ([Math]::Max(1000, $Options.Delay))
                try {
                    $book = Get-GlobalGreyDownload -PageUrl $link.Url -Title $link.Text -Options $Options
                    $book
                    $categoryCount++
                    if ($Options.CandidateLimit -gt 0 -and $categoryCount -ge $Options.CandidateLimit) { break }
                } catch { Write-WarnMsg $_.Exception.Message }
            }
            if ($Options.CandidateLimit -gt 0 -and $categoryCount -ge $Options.CandidateLimit) { break }
            $pathPattern = '^' + [regex]::Escape((([uri]$url).AbsolutePath -replace '\d+\.html$', '')) + '\d+\.html$'
            $next = $links | Where-Object {
                $_.Text -eq 'Next' -and ([uri]$_.Url).Host -eq 'www.globalgreyebooks.com' -and
                ([uri]$_.Url).AbsolutePath -match $pathPattern
            } | Select-Object -First 1
            $url = if ($next) { $next.Url } else { $null }
            if ($url) { Start-Sleep -Milliseconds ([Math]::Max(1000, $Options.Delay)) }
        }
    }
}

function Build-UrlDownloadList {
    param($Options)

    $fmt = Get-ExtensionFromUrl $Options.Url $Options.Format
    return @(
        [pscustomobject]@{
            Url    = $Options.Url
            Title  = (Get-TitleFromUrl $Options.Url)
            Format = $fmt
        }
    )
}

function Read-Manifest {
    param([string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest file not found: $ManifestPath"
    }

    $raw = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8
    try {
        $data = $raw | ConvertFrom-Json
    } catch {
        throw "Invalid JSON manifest: $($_.Exception.Message)"
    }

    $books = @()
    if ($data -is [System.Array]) {
        $books = @($data)
    } elseif ($data.PSObject.Properties.Name -contains 'books') {
        $books = @($data.books)
    } elseif ($data -is [pscustomobject]) {
        $books = @($data)
    } else {
        throw 'Manifest must be an array, an object with a "books" array, or a single book object.'
    }

    $result = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($book in $books) {
        $index++
        if (-not $book) { throw "Manifest entry $index is invalid." }

        $u = $null
        if ($book.PSObject.Properties.Name -contains 'url') { $u = $book.url }
        elseif ($book.PSObject.Properties.Name -contains 'downloadUrl') { $u = $book.downloadUrl }
        elseif ($book.PSObject.Properties.Name -contains 'download_url') { $u = $book.download_url }

        if (-not $u -or -not (Test-HttpUrl $u)) {
            throw "Manifest entry $index has no valid HTTP / HTTPS URL."
        }

        $fmt = if ($book.PSObject.Properties.Name -contains 'format' -and $book.format) {
            Normalize-Format $book.format
        } else {
            Get-ExtensionFromUrl $u 'epub'
        }

        if (-not (Test-SupportedFormat $fmt)) {
            throw "Manifest entry $index has unsupported format `"$fmt`"."
        }

        $title = if ($book.PSObject.Properties.Name -contains 'title' -and $book.title) {
            $book.title
        } else {
            Get-TitleFromUrl $u
        }

        $result.Add([pscustomobject]@{
            Url    = $u
            Title  = (Get-SafeFilename $title)
            Format = $fmt
        })
    }

    return $result
}

function Build-ManifestDownloadList {
    param($Options)

    $books = @(Read-Manifest -ManifestPath $Options.Manifest)
    if ($books.Count -eq 0) {
        throw 'The manifest contains no books.'
    }
    if ($Options.Limit -gt 0) {
        return @($books | Select-Object -First $Options.Limit)
    }
    return $books
}

function Build-DownloadList {
    param($Options)

    switch ($Options.Source) {
        'standard' { return Build-StandardDownloadList -Options $Options }
        'alice'    { return Build-AliceDownloadList -Options $Options }
        'globalgrey' { return Build-GlobalGreyDownloadList -Options $Options }
        'gutenberg' { return Build-GutenbergDownloadList -Options $Options }
        'url'      { return Build-UrlDownloadList -Options $Options }
        'manifest' { return Build-ManifestDownloadList -Options $Options }
        default    { throw "Unsupported source: $($Options.Source)" }
    }
}

function Get-DownloadFileName {
    param($Book, [string]$Format)
    $extension = if ($Book.PSObject.Properties.Name -contains 'Extension' -and $Book.Extension) { $Book.Extension } else { $Format }
    $title = if ($Book.Title) { $Book.Title } else { Get-FilenameFromUrl $Book.Url $Format }
    $name = Get-SafeFilename $title
    if (-not $name.ToLowerInvariant().EndsWith(".$extension")) { $name = "$name.$extension" }
    return $name
}

function Get-ExistingBookNames {
    param([string]$Output)
    if (-not (Test-Path -LiteralPath $Output -PathType Container)) { return @{} }
    $names = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Output -File -ErrorAction SilentlyContinue) {
        $names[$file.Name.ToLowerInvariant()] = $true
    }
    return $names
}

function Test-KindleDirectFormat {
    param([string]$Path)
    return ($script:KindleDirectExtensions -contains ([IO.Path]::GetExtension($Path).ToLowerInvariant()))
}

function Get-DownloadRecordPath {
    param([string]$Source)
    $safeSource = ($Source -replace '[^a-zA-Z0-9_-]', '_').ToLowerInvariant()
    return (Join-Path $script:DOWNLOAD_RECORDS_DIR "$safeSource.json")
}

function Read-DownloadRecords {
    param([string]$Source)
    $path = Get-DownloadRecordPath $Source
    $records = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $records }
    try {
        $data = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($record in @($data.records)) {
            if ($record.filename) { $records[$record.filename.ToLowerInvariant()] = $record }
        }
    } catch {
        Write-WarnMsg "Could not read download record $path; existing files will still be checked."
    }
    return $records
}

function Save-DownloadRecord {
    param([string]$Source, $Book, [string]$Filename, [string]$Format, [Int64]$Size)
    Ensure-Directory $script:DOWNLOAD_RECORDS_DIR
    $path = Get-DownloadRecordPath $Source
    $recordTable = Read-DownloadRecords -Source $Source
    $records = @($recordTable.Values)
    $records = @($records | Where-Object { $_.filename -ine $Filename })
    $records += [pscustomobject]@{ title = [string]$Book.Title; url = [string]$Book.Url; filename = $Filename; format = $Format; size = $Size; downloadedAt = (Get-Date).ToUniversalTime().ToString('o') }
    [pscustomobject]@{ source = $Source; records = @($records | Sort-Object filename) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
}
#endregion

#region Download validation and file saving
function Assert-BookFile([string]$Path, [string]$Format) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $header = New-Object byte[] 512
        $count = $stream.Read($header, 0, $header.Length)
        $text = [Text.Encoding]::ASCII.GetString($header, 0, $count)
        if ($text -match '(?is)<\s*(?:!doctype\s+html|html\b|\?xml)') {
            throw 'Server returned an HTML/XML page instead of a book.'
        }
        if ($Format -eq 'pdf' -and -not $text.StartsWith('%PDF-')) { throw 'Missing PDF header.' }
        if ($Format -eq 'epub' -and -not $text.StartsWith('PK')) { throw 'Missing EPUB ZIP header.' }
    } finally { $stream.Dispose() }
}

function Download-BookFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        $Options
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $Options.Retries; $attempt++) {
        $tempFile = "$Destination.download"
        try {
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }

            Write-Step "Downloading: $([IO.Path]::GetFileName($Destination))"
            if ($attempt -gt 1) {
                Write-Host "Attempt $attempt/$($Options.Retries)"
            }

            Invoke-BookWebRequest -Uri $Uri -TimeoutMs $Options.Timeout -OutFile $tempFile `
                -Accept 'application/epub+zip,application/pdf,application/x-mobipocket-ebook,*/*'

            if (-not (Test-Path -LiteralPath $tempFile)) {
                throw 'Download produced no file.'
            }

            $len = (Get-Item -LiteralPath $tempFile).Length
            if ($len -le 0) {
                throw 'Downloaded file is empty.'
            }

            Assert-BookFile -Path $tempFile -Format ([IO.Path]::GetExtension($Destination).TrimStart('.'))

            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            Move-Item -LiteralPath $tempFile -Destination $Destination -Force
            return
        } catch {
            $lastError = $_
            if (Test-Path -LiteralPath $tempFile) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -lt $Options.Retries) {
                Write-WarnMsg "Download failed: $($_.Exception.Message)"
                Start-Sleep -Seconds 1
            }
        }
    }

    $msg = if ($lastError) { $lastError.Exception.Message } else { 'Unknown error' }
    throw "Download failed after $($Options.Retries) attempt(s): $msg"
}
#endregion

#region Kindle drive copying
function Find-KindleWindows {
    if ($env:OS -notmatch 'Windows' -and $PSVersionTable.Platform -and $PSVersionTable.Platform -ne 'Win32NT') {
        return $null
    }

    try {
        $vol = Get-Volume -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DriveLetter -and (
                    $_.FileSystemLabel -like '*Kindle*' -or
                    $_.FriendlyName -like '*Kindle*'
                )
            } |
            Select-Object -First 1

        if ($vol -and $vol.DriveLetter) {
            return Join-Path "$($vol.DriveLetter):\" 'documents'
        }
    } catch { }

    return $null
}

function Get-ResolvedKindlePath {
    param($Options)

    if (-not $Options.Kindle) { return $null }
    if ($Options.KindlePath) { return $Options.KindlePath }
    return (Find-KindleWindows)
}

function Get-KindleFreeSpace([string]$KindlePath) {
    try {
        $root = [IO.Path]::GetPathRoot($KindlePath)
        $driveLetter = $root.TrimEnd('\', '/').TrimEnd(':')
        if (-not $driveLetter) { return $null }
        $d = Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue
        if ($d) { return [long]$d.Free }
    } catch { }
    return $null
}

function Test-KindlePath([string]$KindlePath) {
    if (-not $KindlePath) {
        return [pscustomobject]@{ Ok = $false; Message = 'Kindle was not detected.'; Path = $null; FreeSpace = $null }
    }
    try {
        if (-not (Test-Path -LiteralPath $KindlePath -PathType Container)) {
            return [pscustomobject]@{
                Ok = $false
                Message = 'Kindle path is not a directory.'
                Path = $KindlePath
                FreeSpace = $null
            }
        }
        $free = Get-KindleFreeSpace $KindlePath
        return [pscustomobject]@{
            Ok = $true
            Message = 'OK'
            Path = $KindlePath
            FreeSpace = $free
        }
    } catch {
        return [pscustomobject]@{
            Ok = $false
            Message = $_.Exception.Message
            Path = $KindlePath
            FreeSpace = $null
        }
    }
}

function Copy-ToKindle {
    param(
        [string]$Source,
        [string]$KindlePath
    )
    Ensure-Directory $KindlePath
    $dest = Join-Path $KindlePath ([IO.Path]::GetFileName($Source))
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force
    }
    Copy-Item -LiteralPath $Source -Destination $dest -Force
    return $dest
}

function Copy-ToKindleMtp {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)]$Documents
    )
    $name = [IO.Path]::GetFileName($Source)
    $existing = Find-MtpItem -Folder $Documents -Name $name
    if ($null -ne $existing) {
        if ($existing.IsFolder) { throw "Kindle destination is a folder: $name" }
        $existing.InvokeVerb('delete')
        Start-Sleep -Seconds 2
    }
    $Documents.CopyHere($Source, 20)
    if (-not (Wait-ForMtpItem -Folder $Documents -Name $name -TimeoutSeconds 45)) {
        throw "Could not verify $name on the Kindle."
    }
    return (Get-KindlePath + '\' + $name)
}
#endregion

#region Download prompts
function Get-SourceCategoryChoices {
    param([string]$Source, [int]$TimeoutMs = 30000)

    if ($Source -eq 'gutenberg') {
        $names = @('Fiction','Romance','Sci-Fi')
        return @($names | ForEach-Object {
            [pscustomobject]@{ Label = $_; Value = $_ }
        })
    }
    if ($Source -eq 'standard') {
        return @(
            @{ Label='Fiction'; Value='fiction' },
            @{ Label='Sci-Fi'; Value='science-fiction' }
        ) | ForEach-Object { [pscustomobject]$_ }
    }

    if ($Source -eq 'globalgrey') {
        $indexUrl = 'https://www.globalgreyebooks.com/ebook-categories.html'
        $response = Invoke-BookWebRequest -Uri $indexUrl -TimeoutMs $TimeoutMs -Accept 'text/html'
        $choices = New-Object System.Collections.Generic.List[object]
        foreach ($link in (Get-HtmlLinks -Html $response.Content -BaseUrl $indexUrl)) {
            $path = ([uri]$link.Url).AbsolutePath
            if ($path -notmatch '^/category/ebooks/.+-page-1\.html$') { continue }
            $label = ($link.Text -replace '\s+', ' ').Trim()
            if ($label -eq 'Fantasy & Sci-Fi') { $label = 'Sci-Fi' }
            if ($label -eq 'All' -and $path -match '/fiction-page-1\.html$') { $label = 'Fiction' }
            if ($label -notin @('Fiction','Sci-Fi')) { continue }
            if (-not ($choices | Where-Object Label -eq $label)) {
                $choices.Add([pscustomobject]@{ Label = $label; Value = $link.Url })
            }
        }
        if ($choices.Count -gt 0) { return $choices.ToArray() }
        throw 'Could not read Global Grey category list.'
    }

    if ($Source -eq 'alice') {
        $indexUrl = 'https://www.aliceandbooks.com/categories'
        $response = Invoke-BookWebRequest -Uri $indexUrl -TimeoutMs $TimeoutMs -Accept 'text/html'
        $choices = New-Object System.Collections.Generic.List[object]
        foreach ($link in (Get-HtmlLinks -Html $response.Content -BaseUrl $indexUrl)) {
            $path = ([uri]$link.Url).AbsolutePath.TrimEnd('/')
            if ($path -notmatch '^/categories/(.+)$') { continue }
            $segments = $Matches[1] -split '/'
            if ($segments[-1] -match '^\d+$') { $segments = @($segments | Select-Object -First ($segments.Count - 1)) }
            if ($segments.Count -eq 0) { continue }
            $lastSegment = $segments[-1]
            $label = switch ($lastSegment) {
                'fiction' { if ($segments.Count -eq 1) { 'Fiction' } else { '' } }
                'romance' { 'Romance' }
                { $_ -in @('science-fiction','sci-fi') } { 'Sci-Fi' }
                default { '' }
            }
            if (-not $label) { continue }
            if (-not ($choices | Where-Object Value -eq $link.Url)) {
                $choices.Add([pscustomobject]@{ Label = $label; Value = $link.Url })
            }
        }
        if ($choices.Count -gt 0) { return $choices.ToArray() }
        throw 'Could not read AliceAndBooks category list.'
    }
    return @()
}

function Read-CategorySelection {
    param([object[]]$Choices, [string[]]$Selected = @(), [string]$Source)

    Write-Host "  $Source categories (choose numbers separated by commas; ENTER keeps defaults):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $Choices[$i].Label)
    }
    Write-Host '  Enter 0 to clear the category filter.' -ForegroundColor Gray
    while ($true) {
        $answer = (Read-DownloadInput 'Category numbers').Trim()
        if (-not $answer) { return @($Selected) }
        if ($answer -eq '0') { return @() }
        $indexes = @($answer -split '[,;\s]+' | Where-Object { $_ })
        $valid = $indexes.Count -gt 0
        $picked = New-Object System.Collections.Generic.List[string]
        foreach ($indexText in $indexes) {
            $index = 0
            if (-not [int]::TryParse($indexText, [ref]$index) -or $index -lt 1 -or $index -gt $Choices.Count) {
                $valid = $false
                break
            }
            $value = [string]$Choices[$index - 1].Value
            if (-not $picked.Contains($value)) { $picked.Add($value) }
        }
        if ($valid) { return @($picked) }
        Write-Host '  Enter valid category numbers separated by commas, or 0 to clear.' -ForegroundColor Red
    }
}

function Resolve-CategoryArguments {
    param([string]$Source, [string[]]$Category, [int]$TimeoutMs = 30000)
    if (-not $Category -or $Source -notin @('standard','alice','globalgrey','gutenberg')) { return @($Category) }
    $choices = @(Get-SourceCategoryChoices -Source $Source -TimeoutMs $TimeoutMs)
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($requested in $Category) {
        $choice = $choices | Where-Object { $_.Value -eq $requested } | Select-Object -First 1
        if (-not $choice) {
            $choice = $choices | Where-Object {
                $_.Label -eq $requested -or $_.Label.EndsWith(" / $requested", [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1
        }
        if (-not $choice) { throw "Unknown $Source category: $requested" }
        if (-not $resolved.Contains([string]$choice.Value)) { $resolved.Add([string]$choice.Value) }
    }
    return @($resolved)
}

function Invoke-Interactive {
    param($Base)

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' DOWNLOAD BOOKS' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' Press ENTER to accept a default. Uppercase Y/N marks the default.' -ForegroundColor Gray

    $source = Read-Choice -Prompt '1 / 4  Download source' -DefaultKey '1' -Choices @(
        @{ Key = '1'; Label = 'Standard Ebooks (public domain, high quality)'; Value = 'standard' }
        @{ Key = '2'; Label = 'AliceAndBooks'; Value = 'alice' }
        @{ Key = '3'; Label = 'Global Grey (PDF, EPUB, Kindle)'; Value = 'globalgrey' }
        @{ Key = '4'; Label = 'Project Gutenberg (English catalogue: EPUB, Kindle)'; Value = 'gutenberg' }
        @{ Key = '5'; Label = 'Direct authorized URL'; Value = 'url' }
        @{ Key = '6'; Label = 'JSON manifest file'; Value = 'manifest' }
    )

    $url = $null
    $manifest = $null

    if ($source -eq 'url') {
        while ($true) {
            $url = (Read-DownloadInput 'Enter book URL (http/https)').Trim()
            if (Test-HttpUrl $url) { break }
            Write-Host '  Must be a valid HTTP or HTTPS URL.' -ForegroundColor Red
        }
    }

    if ($source -eq 'manifest') {
        while ($true) {
            $raw = (Read-DownloadInput 'Path to JSON manifest file').Trim()
            $manifest = Resolve-PortablePath $raw
            if (Test-Path -LiteralPath $manifest) { break }
            Write-Host "  File not found: $manifest" -ForegroundColor Red
        }
    }

    $search = $Base.Search
    if ($source -in @('globalgrey', 'gutenberg')) {
        $search = (Read-DownloadInput "Title filter (ENTER = all; current: $search)").Trim()
    }
    $categories = @($Base.Category)
    $categoryLabels = @()
    if ($source -in @('standard','alice','globalgrey','gutenberg')) {
        $categoryChoices = @(Get-SourceCategoryChoices -Source $source -TimeoutMs $Base.Timeout)
        if (-not $categories.Count -and $source -in @('alice','gutenberg','globalgrey')) {
            $defaultName = 'Fiction'
            $defaultChoice = $categoryChoices | Where-Object Label -eq $defaultName | Select-Object -First 1
            if ($defaultChoice) { $categories = @($defaultChoice.Value) }
        }
        $categories = Read-CategorySelection -Choices $categoryChoices -Selected $categories -Source $source
        $categoryLabels = @($categoryChoices | Where-Object { $categories -contains $_.Value } | ForEach-Object { $_.Label })
    }
    $formatChoices = @(
        @{ Key = '1'; Label = 'MOBI / Kindle (AZW3 on Standard Ebooks and Global Grey)'; Value = 'mobi' }
        @{ Key = '2'; Label = 'EPUB'; Value = 'epub' }
        @{ Key = '3'; Label = 'PDF (where available)'; Value = 'pdf' }
    )

    $defaultFormat = '1'
    if ($source -in @('standard', 'gutenberg')) {
        $formatChoices = @($formatChoices | Where-Object { $_.Value -ne 'pdf' })
    }
    $format = Read-Choice -Prompt '2 / 4  Book format' -DefaultKey $defaultFormat -Choices $formatChoices

    Write-Host ''
    Write-Host '3 / 4  Download limit' -ForegroundColor Cyan
    Write-Host '  Enter 0 for unlimited books.' -ForegroundColor Gray
    while ($true) {
        $limitRaw = (Read-DownloadInput "Max number of books (ENTER = $($Base.Limit))").Trim()
        $limit = $Base.Limit
        if (-not $limitRaw) { break }
        $n = 0
        if (-not [int]::TryParse($limitRaw, [ref]$n) -or $n -lt 0) {
            Write-Host '  Enter a whole number of 0 or more.' -ForegroundColor Red
            continue
        }
        $limit = $n
        break
    }

    Write-Host ''
    Write-Host '4 / 4  Download settings' -ForegroundColor Cyan
    $dryRun = [bool]$Base.DryRun
    $kindle = $Base.Kindle
    $kindlePath = $Base.KindlePath
    $delay = $Base.Delay
    $retries = $Base.Retries
    $timeout = $Base.Timeout
    $maxRuntimeMinutes = $Base.MaxRuntimeMinutes

    Write-Host ''
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ' REVIEW DOWNLOAD SETTINGS' -ForegroundColor Cyan
    Write-DownloadSetting 'Source' $source
    if ($search) { Write-DownloadSetting 'Search' $search }
    if ($categoryLabels.Count -gt 0) { Write-DownloadSetting 'Categories' ($categoryLabels -join ', ') }
    if ($url) { Write-DownloadSetting 'URL' $url }
    if ($manifest) { Write-DownloadSetting 'Manifest' $manifest }
    Write-DownloadSetting 'Format' $format.ToUpperInvariant()
    Write-DownloadSetting 'Save to' $(if ($Base.Output) { $Base.Output } else { $Script:BOOKS_DIR })
    Write-DownloadSetting 'Limit' $(if ($limit -gt 0) { $limit } else { 'Unlimited' })
    Write-DownloadSetting 'Mode' $(if ($dryRun) { 'Dry-run (no downloads)' } else { 'Download books' })
    Write-DownloadSetting 'Kindle' $(if ($kindle) { if ($kindlePath) { $kindlePath } else { 'Auto-detect' } } else { 'No automatic copy' })
    Write-DownloadSetting 'Delay' "$delay ms"
    Write-DownloadSetting 'Attempts' "$retries"
    Write-DownloadSetting 'Timeout' "$timeout ms"
    Write-DownloadSetting 'Max runtime' $(if ($maxRuntimeMinutes -gt 0) { "$maxRuntimeMinutes minute(s)" } else { 'None' })
    Write-Host '------------------------------------------------------------' -ForegroundColor DarkCyan
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Proceed with these settings?' -DefaultYes:$true)) {
        Write-Host '  Download cancelled.' -ForegroundColor Yellow
        return $null
    }

    return [pscustomobject]@{
        Source     = $source
        Search     = $search
        Category   = @($categories)
        Url        = $url
        Manifest   = $manifest
        Output     = $(if ($Base.Output) { $Base.Output } else { $Script:BOOKS_DIR })
        Kindle     = $kindle
        KindlePath = $kindlePath
        Format     = (Normalize-Format $format)
        Delay      = $delay
        Limit      = $limit
        Retries    = $retries
        Timeout    = $timeout
        MaxRuntimeMinutes = $maxRuntimeMinutes
        DryRun     = $dryRun
    }
}
#endregion

#region Download workflow
function Invoke-DryRun {
    param($Options)

    Write-Step 'DRY RUN'
    Write-Host 'No files will be created, downloaded, overwritten, or copied.'
    Write-Host ''
    Write-Host "Script folder: $($Script:SCRIPT_DIR)"
    Write-Host "Books folder:  $($Options.Output)"
    Write-Host "Backup folder: $($Script:BACKUP_DIR)"
    Write-Host "Source:        $($Options.Source)"
    Write-Host "Format:        $($Options.Format)"
    Write-Host "Delay:         $($Options.Delay) ms"
    $limitText = if ($Options.Limit -gt 0) { $Options.Limit } else { 'unlimited' }
    Write-Host "Limit:         $limitText"
  Write-Host "Attempts:      $($Options.Retries)"
  Write-Host "Timeout:       $($Options.Timeout) ms"
    $runtimeText = if ($Options.MaxRuntimeMinutes -gt 0) { "$($Options.MaxRuntimeMinutes) minute(s)" } else { 'none' }
    Write-Host "Max runtime:   $runtimeText"
    Write-Host ''

    Write-Step 'Testing output path...'
    try {
        $parent = Split-Path -Parent $Options.Output
        if (-not $parent) { $parent = $Options.Output }
        if (Test-Path -LiteralPath $parent) {
            Write-Success "Output parent exists: $parent"
        } else {
            Write-WarnMsg "Output parent does not currently exist: $parent"
            Write-Host 'Normal mode will create the folder.'
        }
    } catch {
        Write-WarnMsg $_.Exception.Message
    }

    Write-Step 'Testing selected source...'
    if ($Options.Source -in @('globalgrey', 'gutenberg')) {
        $sampleOptions = $Options.PSObject.Copy()
        $sampleOptions.Limit = if ($Options.Limit -gt 0) { [Math]::Min($Options.Limit, 5) } else { 5 }
        $sample = @(Build-DownloadList -Options $sampleOptions)
        if ($sample.Count -eq 0) { Write-WarnMsg 'No matching books found.' }
        foreach ($book in $sample) {
            $check = Test-BookUrl -Uri $book.Url -TimeoutMs $Options.Timeout
            if ($check.Ok) { Write-Success "$($book.Title) -> $($book.Extension.ToUpperInvariant())" }
            else { Write-WarnMsg "$($book.Title): $($check.Message)" }
            Start-Sleep -Milliseconds ([Math]::Max(2000, $Options.Delay))
        }
    }

    if ($Options.Source -eq 'standard') {
        $st = Test-BookUrl -Uri $Script:STANDARD_EBOOKS_URL -TimeoutMs $Options.Timeout
        if ($st.Ok) {
            Write-Success "Standard Ebooks reachable: HTTP $($st.Status)"
            try {
                $dryOpts = $Options.PSObject.Copy()
                $dryOpts.Limit = if ($Options.Limit -gt 0) { [Math]::Min($Options.Limit, 5) } else { 5 }
                $books = @(Get-StandardBooks -Options $dryOpts)
                if ($books.Count -eq 0) {
                    Write-WarnMsg 'Standard Ebooks responded, but no book links were found.'
                } else {
                    Write-Success "Found $($books.Count) book(s) in sample."
                    Write-Step 'Testing sample download URLs...'
                    foreach ($book in ($books | Select-Object -First 5)) {
                        $dl = Get-StandardDownloadInfo -PagePath $book.PagePath -PreferredFormat $Options.Format
                        $check = Test-BookUrl -Uri $dl.Url -TimeoutMs $Options.Timeout
                        if ($check.Ok) {
                            Write-Success "$($book.Title) -> $($dl.Extension.ToUpperInvariant())"
                        } else {
                            Write-WarnMsg "$($book.Title): download URL returned $($check.Message)"
                        }
                    }
                }
            } catch {
                Write-WarnMsg "Standard Ebooks catalogue test failed: $($_.Exception.Message)"
            }
        } else {
            Write-WarnMsg "Standard Ebooks is not reachable: $($st.Message)"
        }
    }

    if ($Options.Source -eq 'alice') {
        $st = Test-BookUrl -Uri $Script:ALICE_URL -TimeoutMs $Options.Timeout
        if ($st.Ok) {
            Write-Success "AliceAndBooks reachable: HTTP $($st.Status)"
            try {
                $books = @(Get-AliceBooks -Options $Options)
                if ($books.Count -eq 0) {
                    Write-WarnMsg 'AliceAndBooks responded, but no /book/ links were found.'
                } else {
                    $sample = $books | Select-Object -First $(if ($Options.Limit -gt 0) { [Math]::Min($Options.Limit, 5) } else { 5 })
                    Write-Success "Found $($books.Count) book page link(s)."
                    Write-Step "Testing up to $($sample.Count) book page(s)..."
                    foreach ($book in $sample) {
                        try {
                            $dl = Get-AliceBookDownload -Book $book -Options $Options
                            $check = Test-BookUrl -Uri $dl.Url -TimeoutMs $Options.Timeout
                            if ($check.Ok) {
                                Write-Success "$($book.Title) -> $($dl.Format.ToUpperInvariant())"
                            } else {
                                Write-WarnMsg "$($book.Title): download URL returned $($check.Message)"
                            }
                        } catch {
                            Write-WarnMsg "$($book.Title): $($_.Exception.Message)"
                        }
                    }
                }
            } catch {
                Write-WarnMsg "Alice catalogue test failed: $($_.Exception.Message)"
            }
        } else {
            Write-WarnMsg "AliceAndBooks is not reachable: $($st.Message)"
        }
    }

    if ($Options.Source -eq 'url') {
        $st = Test-BookUrl -Uri $Options.Url -TimeoutMs $Options.Timeout
        if ($st.Ok) {
            Write-Success "URL reachable: HTTP $($st.Status)"
            Write-Host "URL: $($Options.Url)"
            Write-Host "Detected format: $((Get-ExtensionFromUrl $Options.Url $Options.Format).ToUpperInvariant())"
        } else {
            Write-WarnMsg "URL test failed: $($st.Message)"
        }
    }

    if ($Options.Source -eq 'manifest') {
        Write-Step 'Testing manifest...'
        try {
            $books = @(Read-Manifest -ManifestPath $Options.Manifest)
            Write-Success "Manifest is valid: $($books.Count) book(s)"
            $sample = $books | Select-Object -First $(if ($Options.Limit -gt 0) { [Math]::Min($Options.Limit, 5) } else { 5 })
            foreach ($book in $sample) {
                $st = Test-BookUrl -Uri $book.Url -TimeoutMs $Options.Timeout
                if ($st.Ok) {
                    Write-Success "$($book.Title) -> HTTP $($st.Status)"
                } else {
                    Write-WarnMsg "$($book.Title): $($st.Message)"
                }
            }
        } catch {
            Write-WarnMsg "Manifest test failed: $($_.Exception.Message)"
        }
    }

    if ($Options.Kindle) {
        Write-Step 'Testing Kindle connection...'
        $kp = Get-ResolvedKindlePath -Options $Options
        if (-not $kp) {
            Write-WarnMsg 'No Kindle was detected automatically.'
            Write-Host 'If the Kindle uses MTP instead of a normal Windows drive, automatic detection may not work.'
        } else {
            $result = Test-KindlePath $kp
            if ($result.Ok) {
                Write-Success "Kindle detected: $($result.Path)"
                if ($null -ne $result.FreeSpace) {
                    $gb = [Math]::Round($result.FreeSpace / 1GB, 2)
                    Write-Success "Free space: $gb GB"
                }
            } else {
                Write-WarnMsg "Kindle test failed: $($result.Message)"
            }
        }
    }

    Write-Step 'DRY RUN COMPLETE'
    Write-Host 'No files were modified.'
}

function Invoke-DownloadWorkflow {
    if ($Help) {
        Show-Help
        return
    }

    # Normalize initial param-based options
    $options = [pscustomobject]@{
        Source     = $Source
        Search     = $Search
        Category   = @($Category)
        Url        = $Url
        Manifest   = $Manifest
        Output     = $(if ($Output) { Resolve-PortablePath $Output } else { $Script:BOOKS_DIR })
        Kindle     = [bool]$Kindle
        KindlePath = $(if ($KindlePath) { Resolve-PortablePath $KindlePath } else { $null })
        Format     = (Normalize-Format $Format)
        Delay      = $Delay
        Limit      = $Limit
        Retries    = $Retries
        Timeout    = $Timeout
        MaxRuntimeMinutes = $MaxRuntimeMinutes
        DryRun     = [bool]$DryRun
    }

    # Infer source from Url / Manifest if provided
    if ($Url) {
        $options.Source = 'url'
        $options.Url = $Url
    }
    if ($Manifest) {
        $options.Source = 'manifest'
        $options.Manifest = Resolve-PortablePath $Manifest
    }

    if ($Category -and $options.Source) {
        $options.Category = @(Resolve-CategoryArguments -Source $options.Source -Category $options.Category -TimeoutMs $options.Timeout)
    }

    $sourceExplicit = -not [string]::IsNullOrWhiteSpace($Source) -or $Url -or $Manifest
    $useInteractive = $Interactive -or (-not $sourceExplicit)

    if ($useInteractive) {
        $options = Invoke-Interactive -Base $options
        if ($null -eq $options) { return }
    } else {
        if ([string]::IsNullOrWhiteSpace($options.Source)) {
            $options.Source = 'standard'
        }
    }

    if ($options.Source -eq 'gutenberg') { $options.Delay = [Math]::Max(2000, $options.Delay) }
    if ($options.Source -eq 'globalgrey') { $options.Delay = [Math]::Max(1000, $options.Delay) }

    if ($options.MaxRuntimeMinutes -lt 0) {
        Write-ErrMsg '-MaxRuntimeMinutes must be 0 or greater.'
        throw 'Invalid runtime limit.'
    }

    # Validate
    if ($options.Source -notin @('standard', 'alice', 'globalgrey', 'gutenberg', 'url', 'manifest')) {
        Write-ErrMsg "Unsupported source `"$($options.Source)`"."
        throw 'Invalid download options.'
    }
    if (-not (Test-SupportedFormat $options.Format)) {
        Write-ErrMsg "Unsupported format `"$($options.Format)`"."
        throw 'Invalid download options.'
    }
    if ($options.Source -eq 'url' -and -not $options.Url) {
        Write-ErrMsg '-Source url requires -Url'
        throw 'Invalid download options.'
    }
    if ($options.Source -eq 'manifest' -and -not $options.Manifest) {
        Write-ErrMsg '-Source manifest requires -Manifest'
        throw 'Invalid download options.'
    }
    if ($options.Url -and -not (Test-HttpUrl $options.Url)) {
        Write-ErrMsg '-Url must be an HTTP or HTTPS URL'
        throw 'Invalid download options.'
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Portable Legal Book Downloader'
    Write-Host '============================================================'

    if ($options.DryRun) {
        Invoke-DryRun -Options $options
        return
    }

    Invoke-SelfRepair -OutputFolder $options.Output
    Ensure-Directory $options.Output
    Ensure-Directory $Script:BACKUP_DIR
    Ensure-Directory $script:DOWNLOAD_RECORDS_DIR

    $options | Add-Member -NotePropertyName StartedAt -NotePropertyValue ([DateTime]::UtcNow) -Force
    $options | Add-Member -NotePropertyName Deadline -NotePropertyValue $(if ($options.MaxRuntimeMinutes -gt 0) { [DateTime]::UtcNow.AddMinutes($options.MaxRuntimeMinutes) } else { $null }) -Force

    Write-Success "Books folder: $($options.Output)"
    Write-Success "Backup folder: $($Script:BACKUP_DIR)"
    if ($options.MaxRuntimeMinutes -gt 0) {
        Write-Host "Maximum runtime: $($options.MaxRuntimeMinutes) minute(s)" -ForegroundColor Gray
    } else {
        Write-Host 'Maximum runtime: none' -ForegroundColor Gray
    }

    $kindlePath = $null
    $kindleMtpDocuments = $null
    if ($options.Kindle) {
        $kindlePath = Get-ResolvedKindlePath -Options $options
        if (-not $kindlePath) {
            try {
                $Shell = New-Object -ComObject Shell.Application
                $kindleMtpDocuments = Get-KindleDocuments
            } catch {
                $kindleMtpDocuments = $null
            }
            if ($null -ne $kindleMtpDocuments) {
                Write-Success "Kindle detected through MTP: $(Get-KindlePath)"
            } else {
                Write-WarnMsg 'Kindle was not detected as a drive or MTP device.'
                Write-Host 'Continuing without Kindle copying.'
            }
        } else {
            $kt = Test-KindlePath $kindlePath
            if (-not $kt.Ok) {
                Write-WarnMsg "Kindle is unavailable: $($kt.Message)"
                $kindlePath = $null
            } else {
                Write-Success "Kindle: $kindlePath"
            }
        }
    }

    Write-Step "Building download list from $($options.Source)..."
    if (Test-DownloadTimeLimit -Options $options) { return }
    $existingNames = Get-ExistingBookNames -Output $options.Output
    $downloadRecords = Read-DownloadRecords -Source $options.Source
    foreach ($recordName in $downloadRecords.Keys) {
        if (Test-Path -LiteralPath (Join-Path $options.Output $recordName) -PathType Leaf) {
            $existingNames[$recordName] = $true
        }
    }
    $options | Add-Member -NotePropertyName ExistingNames -NotePropertyValue $existingNames -Force
    $options | Add-Member -NotePropertyName CandidateLimit -NotePropertyValue $(if ($options.Limit -gt 0) { [Math]::Max($options.Limit * 5, 25) } else { 0 }) -Force
    $downloads = @(Build-DownloadList -Options $options)

    $available = New-Object System.Collections.Generic.List[object]
    $skippedExisting = 0
    foreach ($candidate in $downloads) {
        $candidateFormat = Normalize-Format $(if ($candidate.Format) { $candidate.Format } else { $options.Format })
        $candidateName = Get-DownloadFileName -Book $candidate -Format $candidateFormat
        if ($existingNames.ContainsKey($candidateName.ToLowerInvariant())) {
            $skippedExisting++
            continue
        }
        $available.Add($candidate)
        if ($options.Limit -gt 0 -and $available.Count -ge $options.Limit) { break }
    }
    # Windows PowerShell 5.1 throws "Argument types do not match" when an
    # array subexpression wraps a generic List[object]. Convert explicitly.
    $downloads = $available.ToArray()
    if ($skippedExisting -gt 0) { Write-WarnMsg "Skipped $skippedExisting book(s) already present in $($options.Output)." }

    if ($downloads.Count -eq 0) {
        Write-WarnMsg 'No downloadable books were found.'
        return
    }

    Write-Success "Found $($downloads.Count) book(s) to process."

    $successful = 0
    $failed = 0
    $index = 0
    foreach ($book in $downloads) {
        if (Test-DownloadTimeLimit -Options $options) { break }
        $index++
        $format = Normalize-Format $(if ($book.Format) { $book.Format } else { $options.Format })
        $ext = if ($book.PSObject.Properties.Name -contains 'Extension' -and $book.Extension) {
            $book.Extension
        } else {
            $format
        }

        $finalFilename = Get-DownloadFileName -Book $book -Format $format
        $destination = Join-Path $options.Output $finalFilename


        Write-Host ''
        Write-Step "[$index/$($downloads.Count)] $($book.Title)"
        Write-Host "URL: $($book.Url)"
        Write-Host "Destination: $destination"

        try {
                Download-BookFile -Uri $book.Url -Destination $destination -Options $options
            $item = Get-Item -LiteralPath $destination
            $mb = [Math]::Round($item.Length / 1MB, 2)
            Write-Success "Downloaded $mb MB"
            Save-DownloadRecord -Source $options.Source -Book $book -Filename $finalFilename -Format $format -Size $item.Length

            $kindleDest = $null
            if (($kindlePath -or $kindleMtpDocuments) -and (Test-KindleDirectFormat $destination)) {
                try {
                    if ($kindlePath) {
                        $kindleDest = Copy-ToKindle -Source $destination -KindlePath $kindlePath
                    } else {
                        $kindleDest = Copy-ToKindleMtp -Source $destination -Documents $kindleMtpDocuments
                    }
                    Write-Success "Copied to Kindle: $kindleDest"
                } catch {
                    Write-WarnMsg "Kindle copy failed: $($_.Exception.Message)"
                }
            } elseif ($options.Kindle -and -not (Test-KindleDirectFormat $destination)) {
                Write-WarnMsg "Downloaded, but not copied: $format is not a direct USB/MTP Kindle format. Use AZW3, PDF, or Send to Kindle for EPUB."
            }

            $successful++
        } catch {
            Write-ErrMsg "$($book.Title): $($_.Exception.Message)"
            $failed++
        }

        if ($index -lt $downloads.Count -and $options.Delay -gt 0) {
            $sleepMs = $options.Delay
            if ($options.Deadline) {
                $remaining = [int][Math]::Max(0, ($options.Deadline - [DateTime]::UtcNow).TotalMilliseconds)
                $sleepMs = [Math]::Min($sleepMs, $remaining)
            }
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        }
    }


    Write-Host ''
    Write-Step 'Finished'
    Write-Success "Successful: $successful"
    if ($failed -gt 0) { Write-WarnMsg "Failed: $failed" }
    Write-Host ''
}
#endregion

#region Kindle connection and folder lookup
function Get-ThisPC {
    try {
        return $Shell.Namespace(17)
    }
    catch {
        return $null
    }
}

function Get-Kindle {
    $ThisPC = Get-ThisPC

    if ($null -eq $ThisPC) {
        return $null
    }

    try {
        foreach ($Item in $ThisPC.Items()) {
            try {
                $Name = [string]$Item.Name

                if (
                    $Name -like "*Kindle*" -or
                    $Name -like "*Amazon Kindle*"
                ) {
                    return $Item
                }
            }
            catch {
                continue
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-KindleName {
    $Kindle = Get-Kindle

    if ($null -eq $Kindle) {
        return "Kindle"
    }

    return [string]$Kindle.Name
}

function Get-KindleRootPath {
    $KindleName = Get-KindleName

    return "This PC\$KindleName"
}

function Get-KindleStoragePath {
    $KindleName = Get-KindleName

    return "This PC\$KindleName\Internal Storage"
}

function Get-KindlePath {
    $KindleName = Get-KindleName

    return "This PC\$KindleName\Internal Storage\documents"
}

# Windows Shell folders are COM objects; missing/disconnected folders return null.
function Get-MtpChildFolder {
    param($Folder, [string]$Name)
    if ($null -eq $Folder) { return $null }
    try {
        foreach ($item in $Folder.Items()) {
            if ($item.IsFolder -and [string]$item.Name -ieq $Name) {
                return $item.GetFolder()
            }
        }
    } catch { return $null }
    return $null
}

function Get-KindleInternalStorage {
    $kindle = Get-Kindle
    if ($null -eq $kindle) { return $null }
    try { return Get-MtpChildFolder -Folder $kindle.GetFolder() -Name 'Internal Storage' }
    catch { return $null }
}

function Get-KindleDocuments {
    return Get-MtpChildFolder -Folder (Get-KindleInternalStorage) -Name 'documents'
}
function Wait-ForKindle {
    param(
        [int]$TimeoutSeconds = 0
    )

    Write-Host ""
    Write-Host "Looking for Kindle..." -ForegroundColor Yellow

    $StartTime = Get-Date

    while ($true) {
        try {
            $Kindle = Get-Kindle

            if ($null -ne $Kindle) {
                $Storage = Get-KindleInternalStorage

                if ($null -ne $Storage) {
                    Write-Host ""
                    Write-Host "Kindle detected!" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Device:" -ForegroundColor Gray
                    Write-Host "  $($Kindle.Name)" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "Storage:" -ForegroundColor Gray
                    Write-Host "  $(Get-KindleStoragePath)" -ForegroundColor Cyan

                    return $true
                }
            }
        }
        catch {
        }

        if ($TimeoutSeconds -gt 0) {
            $Elapsed = ((Get-Date) - $StartTime).TotalSeconds

            if ($Elapsed -ge $TimeoutSeconds) {
                Write-Host ""
                Write-Host "Kindle was not detected." -ForegroundColor Red

                return $false
            }
        }

        Write-Host "." -NoNewline -ForegroundColor DarkGray

        Start-Sleep -Seconds 2
    }
}

function Test-KindleConnection {
    try {
        $Kindle = Get-Kindle

        if ($null -eq $Kindle) {
            return $false
        }

        $Storage = Get-KindleInternalStorage

        return ($null -ne $Storage)
    }
    catch {
        return $false
    }
}
#endregion

#region Kindle item metadata
function Get-MtpItems {
    param(
        [Parameter(Mandatory)]
        $Folder
    )

    try {
        if ($null -eq $Folder) {
            return @()
        }

        return @($Folder.Items())
    }
    catch {
        return @()
    }
}

function Get-MtpItemType {
    param(
        $Folder,
        $Item
    )

    if ($null -eq $Item) {
        return "Unknown"
    }

    if ($Item.IsFolder) {
        return "Folder"
    }

    try {
        $Type = $Folder.GetDetailsOf($Item, 2)

        if (-not [string]::IsNullOrWhiteSpace($Type)) {
            return $Type.Trim()
        }
    }
    catch {
    }

    try {
        $Extension = [System.IO.Path]::GetExtension(
            [string]$Item.Name
        )

        if (-not [string]::IsNullOrWhiteSpace($Extension)) {
            return "$Extension file"
        }
    }
    catch {
    }

    return "File"
}

function ConvertFrom-MtpSizeText {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 0 }
    $text = $Value.Trim().ToUpperInvariant().Replace(',', '')
    if ($text -match '([0-9\.]+)\s*TB') { return ([double]$matches[1] * 1TB) }
    if ($text -match '([0-9\.]+)\s*GB') { return ([double]$matches[1] * 1GB) }
    if ($text -match '([0-9\.]+)\s*MB') { return ([double]$matches[1] * 1MB) }
    if ($text -match '([0-9\.]+)\s*KB') { return ([double]$matches[1] * 1KB) }
    if ($text -match '([0-9\.]+)\s*BYTES?') { return [double]$matches[1] }
    return 0
}

function Get-MtpFileSize {
    param(
        $Documents,
        $Item
    )

    if ($null -eq $Item) {
        return 0
    }

    if ($Item.IsFolder) {
        return 0
    }

    try {
        # MTP devices can place Size in a different Shell column.
        for ($column = 0; $column -lt 40; $column++) {
            $header = $Documents.GetDetailsOf($null, $column)
            if ([string]$header -match '(?i)size') {
                $size = ConvertFrom-MtpSizeText ($Documents.GetDetailsOf($Item, $column))
                if ($size -gt 0) { return $size }
            }
        }

        # Keep the common fallback for devices that expose size only at column 1.
        return ConvertFrom-MtpSizeText ($Documents.GetDetailsOf($Item, 1))
    }
    catch {
    }

    return 0
}

function Get-MtpFileList {
    param(
        [Parameter(Mandatory)]
        $Folder
    )

    $Results = @()

    foreach ($Item in Get-MtpItems $Folder) {
        if (-not $Item.IsFolder) {
            $Size = Get-MtpFileSize `
                -Documents $Folder `
                -Item $Item

            $Results += [PSCustomObject]@{
                Item      = $Item
                Name      = [string]$Item.Name
                Size      = $Size
                Type      = Get-MtpItemType `
                    -Folder $Folder `
                    -Item $Item
            }
        }
    }

    return $Results
}

function Get-MtpFolderContentsRecursive {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$LogicalPath,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )

    try {
        foreach ($Item in Get-MtpItems $Folder) {
            try {
                $Name = [string]$Item.Name

                if ($Item.IsFolder) {
                    $ItemPath = "$LogicalPath\$Name"

                    $Results.Add(
                        [PSCustomObject]@{
                            Item        = $Item
                            Name        = $Name
                            Type        = "Folder"
                            Size        = 0
                            SizeText    = ""
                            LogicalPath = $ItemPath
                            IsFolder    = $true
                        }
                    )

                    $ChildFolder = $Item.GetFolder()

                    if ($null -ne $ChildFolder) {
                        Get-MtpFolderContentsRecursive `
                            -Folder $ChildFolder `
                            -LogicalPath $ItemPath `
                            -Results $Results
                    }
                }
                else {
                    $Size = Get-MtpFileSize `
                        -Documents $Folder `
                        -Item $Item

                    $Results.Add(
                        [PSCustomObject]@{
                            Item        = $Item
                            Name        = $Name
                            Type        = Get-MtpItemType `
                                -Folder $Folder `
                                -Item $Item
                            Size        = $Size
                            SizeText    = Format-Size $Size
                            LogicalPath = "$LogicalPath\$Name"
                            IsFolder    = $false
                        }
                    )
                }
            }
            catch {
                continue
            }
        }
    }
    catch {
    }
}
#endregion

#region Kindle transfers
function Copy-PCToKindle {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " PC -> KINDLE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Source:" -ForegroundColor Gray
    Write-Host "  $PcBooksFolder" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $PcBooksFolder)) {
        New-Item `
            -ItemType Directory `
            -Path $PcBooksFolder `
            -Force |
            Out-Null

        Write-Host ""
        Write-Host "Books folder created." -ForegroundColor Green
        Write-Host "Place your books there and run this option again."

        return
    }

    $Files = @(
        Get-ChildItem `
            -LiteralPath $PcBooksFolder `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $SupportedExtensions -contains $_.Extension.ToLower()
        }
    )

    $DirectFiles = @($Files | Where-Object { Test-KindleDirectFormat $_.FullName })
    $UnsupportedDirectFiles = @($Files | Where-Object { -not (Test-KindleDirectFormat $_.FullName) })
    if ($UnsupportedDirectFiles.Count -gt 0) {
        Write-Host ""
        Write-WarnMsg "Skipped $($UnsupportedDirectFiles.Count) file(s) that Kindle cannot read when copied directly by USB/MTP."
        Write-Host "Use AZW3, MOBI, or PDF for direct transfer. Use Send to Kindle for EPUB." -ForegroundColor Gray
    }
    $Files = $DirectFiles

    if ($Files.Count -eq 0) {
        Write-Host ""
        Write-Host "No supported books found." -ForegroundColor Yellow

        return
    }

    Write-Host ""
    Write-Host "Found $($Files.Count) book(s)." -ForegroundColor Green

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Documents = Get-KindleDocuments

    if ($null -eq $Documents) {
        Write-Host ""
        Write-Host "Could not find documents folder." -ForegroundColor Red

        return
    }

    Write-Host ""
    Write-Host "Destination:" -ForegroundColor Gray
    Write-Host "  $(Get-KindlePath)" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Transfer mode:" -ForegroundColor Gray
    Write-Host "  1. Transfer all"
    Write-Host "  2. Select files"

    Write-Host ""

    $Mode = Read-Host "Choose"

    if ($Mode -eq "2") {
        $SelectedFiles = Select-PCFiles -Files $Files

        if ($SelectedFiles.Count -eq 0) {
            Write-Host ""
            Write-Host "No files selected." -ForegroundColor Yellow

            return
        }

        $Files = $SelectedFiles
    }

    Write-Host ""
    Write-Host "Existing files on Kindle:" -ForegroundColor Cyan
    Write-Host "  1. Overwrite all"
    Write-Host "  2. Skip all"
    Write-Host "  3. Ask for each file"
    Write-Host ""
    $ConflictPolicy = Read-Host "Choose existing-file policy [2]"
    if ([string]::IsNullOrWhiteSpace($ConflictPolicy)) { $ConflictPolicy = "2" }
    while ($ConflictPolicy -notin @("1", "2", "3")) {
        Write-Host "Choose 1, 2, or 3." -ForegroundColor Red
        $ConflictPolicy = Read-Host "Choose existing-file policy [2]"
    }

    Write-Host ""
    Write-Host "Starting transfer..." -ForegroundColor Yellow
    Write-Host ""

    $Count = 0
    $Success = 0
    $Failed = 0

    foreach ($File in $Files) {
        $Count++

        Write-Host "[$Count/$($Files.Count)] $($File.Name)" `
            -ForegroundColor Cyan

        try {
            $Existing = Find-MtpItem `
                -Folder $Documents `
                -Name $File.Name

            if ($null -ne $Existing) {
                Write-Host "    Already exists on Kindle." `
                    -ForegroundColor Yellow

                $Overwrite = $false
                if ($ConflictPolicy -eq "1") {
                    $Overwrite = $true
                }
                elseif ($ConflictPolicy -eq "3") {
                    $Answer = Read-Host "    Replace it? (Y/N)"
                    $Overwrite = ($Answer -match "^[Yy]$")
                }

                if (-not $Overwrite) {
                    Write-Host "    Skipped." -ForegroundColor DarkGray

                    continue
                }

                if ($Existing.IsFolder) {
                    Write-Host "    Destination is a folder. Skipped." `
                        -ForegroundColor Red

                    $Failed++

                    continue
                }

                try {
                    $Existing.InvokeVerb("delete")
                    Start-Sleep -Seconds 2
                }
                catch {
                    Write-Host "    Could not remove existing file." `
                        -ForegroundColor Red

                    $Failed++

                    continue
                }
            }

            $Documents.CopyHere(
                $File.FullName,
                $CopyFlags
            )

            Write-Host "    Copy started. Verifying..." `
                -ForegroundColor Yellow

            $Verified = Wait-ForMtpItem `
                -Folder $Documents `
                -Name $File.Name `
                -TimeoutSeconds $VerificationTimeoutSeconds

            if ($Verified) {
                Write-Host "    Verified on Kindle." `
                    -ForegroundColor Green

                $Success++
            }
            else {
                Write-Host "    Could not verify destination." `
                    -ForegroundColor Red

                $Failed++
            }
        }
        catch {
            Write-Host "    FAILED" -ForegroundColor Red
            Write-Host "    $($_.Exception.Message)" `
                -ForegroundColor Red

            $Failed++
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Transfer finished" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host ""
    Write-Host "Successful : $Success" -ForegroundColor Green
    Write-Host "Failed     : $Failed" -ForegroundColor Red
}

function Select-PCFiles {
    param(
        [Parameter(Mandatory)]
        [array]$Files
    )

    Write-Host ""
    Write-Host "Available files:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Files.Count; $i++) {
        $Number = $i + 1

        Write-Host (
            "[{0}] {1} ({2})" -f `
                $Number,
                $Files[$i].Name,
                (Format-Size $Files[$i].Length)
        )
    }

    Write-Host ""
    Write-Host "Enter numbers separated by commas." -ForegroundColor Gray
    Write-Host "Example: 1,3,5"
    Write-Host ""

    $InputValue = Read-Host "Selection"

    $Selected = @()

    foreach ($Part in $InputValue.Split(",")) {
        $Part = $Part.Trim()

        if ($Part -match "^\d+$") {
            $Index = [int]$Part - 1

            if (
                $Index -ge 0 -and
                $Index -lt $Files.Count
            ) {
                $Selected += $Files[$Index]
            }
        }
    }

    return $Selected
}

function Find-MtpItem {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        foreach ($Item in $Folder.Items()) {
            if ([string]$Item.Name -ieq $Name) {
                return $Item
            }
        }
    }
    catch {
    }

    return $null
}

function Wait-ForMtpItem {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 45,

        [int]$IntervalMilliseconds = 750
    )

    $Start = Get-Date

    while ($true) {
        try {
            $Item = Find-MtpItem `
                -Folder $Folder `
                -Name $Name

            if ($null -ne $Item) {
                return $true
            }
        }
        catch {
        }

        $Elapsed = (
            (Get-Date) - $Start
        ).TotalSeconds

        if ($Elapsed -ge $TimeoutSeconds) {
            return $false
        }

        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
}

function Copy-KindleToPC {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " KINDLE -> PC" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Documents = Get-KindleDocuments

    if ($null -eq $Documents) {
        Write-Host ""
        Write-Host "Could not find documents folder." `
            -ForegroundColor Red

        return
    }

    $Files = @(Get-MtpFileList -Folder $Documents)

    if ($Files.Count -eq 0) {
        Write-Host ""
        Write-Host "No files found on Kindle." -ForegroundColor Yellow

        return
    }

    if (-not (Test-Path -LiteralPath $PcBooksFolder)) {
        New-Item `
            -ItemType Directory `
            -Path $PcBooksFolder `
            -Force |
            Out-Null
    }

    Write-Host ""
    Write-Host "Found $($Files.Count) file(s)." -ForegroundColor Green

    Write-Host ""
    Write-Host "Transfer mode:" -ForegroundColor Gray
    Write-Host "  1. Transfer all"
    Write-Host "  2. Select files"

    Write-Host ""

    $Mode = Read-Host "Choose"

    if ($Mode -eq "2") {
        $Files = Select-MtpFiles -Files $Files

        if ($Files.Count -eq 0) {
            Write-Host ""
            Write-Host "No files selected." -ForegroundColor Yellow

            return
        }
    }

    Write-Host ""
    Write-Host "Destination:" -ForegroundColor Gray
    Write-Host "  $PcBooksFolder" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Starting transfer..." -ForegroundColor Yellow
    Write-Host ""

    $Count = 0
    $Success = 0
    $Failed = 0

    foreach ($File in $Files) {
        $Count++

        Write-Host "[$Count/$($Files.Count)] $($File.Name)" `
            -ForegroundColor Cyan

        try {
            $DestinationPath = Join-Path `
                $PcBooksFolder `
                $File.Name

            if (Test-Path -LiteralPath $DestinationPath) {
                Write-Host "    File already exists on PC." `
                    -ForegroundColor Yellow

                $Overwrite = Read-Host "    Replace it? (Y/N)"

                if ($Overwrite -notmatch "^[Yy]$") {
                    Write-Host "    Skipped." -ForegroundColor DarkGray

                    continue
                }

                Remove-Item `
                    -LiteralPath $DestinationPath `
                    -Force
            }

            $PcFolder = $Shell.Namespace($PcBooksFolder)

            if ($null -eq $PcFolder) {
                throw "Could not access PC destination folder."
            }

            $PcFolder.CopyHere(
                $File.Item,
                $CopyFlags
            )

            Write-Host "    Copy started. Verifying..." `
                -ForegroundColor Yellow

            $Verified = Wait-ForPCFile `
                -Path $DestinationPath `
                -TimeoutSeconds $VerificationTimeoutSeconds

            if ($Verified) {
                Write-Host "    Verified on PC." `
                    -ForegroundColor Green

                $Success++
            }
            else {
                Write-Host "    Could not verify destination." `
                    -ForegroundColor Red

                $Failed++
            }
        }
        catch {
            Write-Host "    FAILED" -ForegroundColor Red
            Write-Host "    $($_.Exception.Message)" `
                -ForegroundColor Red

            $Failed++
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host " Transfer finished" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

    Write-Host ""
    Write-Host "Successful : $Success" -ForegroundColor Green
    Write-Host "Failed     : $Failed" -ForegroundColor Red
}

function Select-MtpFiles {
    param(
        [Parameter(Mandatory)]
        [array]$Files
    )

    Write-Host ""
    Write-Host "Available files:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Files.Count; $i++) {
        Write-Host (
            "[{0}] {1} ({2})" -f `
                ($i + 1),
                $Files[$i].Name,
                (Format-Size $Files[$i].Size)
        )
    }

    Write-Host ""
    Write-Host "Enter numbers separated by commas."
    Write-Host ""

    $InputValue = Read-Host "Selection"

    $Selected = @()

    foreach ($Part in $InputValue.Split(",")) {
        $Part = $Part.Trim()

        if ($Part -match "^\d+$") {
            $Index = [int]$Part - 1

            if (
                $Index -ge 0 -and
                $Index -lt $Files.Count
            ) {
                $Selected += $Files[$Index]
            }
        }
    }

    return $Selected
}

function Wait-ForPCFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [int]$TimeoutSeconds = 45
    )

    $Start = Get-Date

    while ($true) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $Item = Get-Item -LiteralPath $Path

                if ($Item.Length -ge 0) {
                    return $true
                }
            }
            catch {
            }
        }

        $Elapsed = (
            (Get-Date) - $Start
        ).TotalSeconds

        if ($Elapsed -ge $TimeoutSeconds) {
            return $false
        }

        Start-Sleep -Milliseconds $VerificationIntervalMs
    }
}
#endregion

#region Kindle browser and search
function Browse-Kindle {
    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {
        Write-Host ""
        Write-Host "Internal Storage unavailable." -ForegroundColor Red

        return
    }

    Invoke-KindleBrowser `
        -Folder $Storage `
        -LogicalPath $(Get-KindleStoragePath)
}

function Invoke-KindleBrowser {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$LogicalPath
    )

    while ($true) {
        Clear-Host

        Write-Host "============================================================" `
            -ForegroundColor Cyan

        Write-Host " KINDLE FILE BROWSER" `
            -ForegroundColor Cyan

        Write-Host "============================================================" `
            -ForegroundColor Cyan

        Write-Host ""
        Write-Host "Location:" -ForegroundColor Gray
        Write-Host "  $LogicalPath" -ForegroundColor White

        Write-Host ""

        $Items = @(Get-MtpItems $Folder)
        $DisplayItems = @()

        if ($Items.Count -eq 0) {
            Write-Host "This folder is empty or unavailable." `
                -ForegroundColor Yellow
        }
        else {
            $Folders = @(
                $Items |
                Where-Object { $_.IsFolder } |
                Sort-Object Name
            )

            $Files = @(
                $Items |
                Where-Object { -not $_.IsFolder } |
                Sort-Object Name
            )

            $DisplayItems = @()

            foreach ($Item in $Folders) {
                $DisplayItems += $Item
            }

            foreach ($Item in $Files) {
                $DisplayItems += $Item
            }

            for ($i = 0; $i -lt $DisplayItems.Count; $i++) {
                $Item = $DisplayItems[$i]

                if ($Item.IsFolder) {
                    Write-Host (
                        "[{0,3}] [DIR]  {1}" -f `
                        ($i + 1),
                        $Item.Name
                    ) -ForegroundColor Yellow
                }
                else {
                    $Size = Get-MtpFileSize `
                        -Documents $Folder `
                        -Item $Item

                    Write-Host (
                        "[{0,3}]        {1,-55} {2,10}" -f `
                        ($i + 1),
                        $Item.Name,
                        (Format-Size $Size)
                    )
                }
            }
        }

        Write-Host ""
        Write-Host "------------------------------------------------------------"
        Write-Host "Commands:"
        Write-Host ""
        Write-Host "  NUMBER  Open folder / inspect file"
        Write-Host "  B       Back"
        Write-Host "  I       File information"
        Write-Host "  C       Copy item to PC"
        Write-Host "  D       Delete file"
        Write-Host "  S       Search Kindle"
        Write-Host "  R       Refresh"
        Write-Host "  Q       Exit browser"
        Write-Host ""

        $Choice = Read-Host "Choose"

        if ($Choice -match "^[Qq]$") {
            return
        }

        if ($Choice -match "^[Ss]$") {
            Search-Kindle
            continue
        }

        if ($Choice -match "^[Rr]$") {
            continue
        }

        if ($Choice -match "^[Bb]$") {
            $Parent = Get-MtpParentFolder `
                -Folder $Folder

            if ($null -eq $Parent) {
                Write-Host ""
                Write-Host "Already at the top of this browser." `
                    -ForegroundColor Yellow

                Start-Sleep -Seconds 1
            }
            else {
                $ParentPath = Get-ParentLogicalPath `
                    -LogicalPath $LogicalPath

                Invoke-KindleBrowser `
                    -Folder $Parent `
                    -LogicalPath $ParentPath

                return
            }

            continue
        }

        if ($Choice -match "^[Ii]$") {
            $Selected = Select-MtpItem `
                -Folder $Folder

            if ($null -ne $Selected) {
                Show-MtpItemInformation `
                    -Folder $Folder `
                    -Item $Selected `
                    -LogicalPath $LogicalPath
            }

            continue
        }

        if ($Choice -match "^[Cc]$") {
            $Selected = Select-MtpItem `
                -Folder $Folder

            if ($null -ne $Selected) {
                Copy-MtpItemToPC `
                    -Folder $Folder `
                    -Item $Selected `
                    -LogicalPath $LogicalPath
            }

            continue
        }

        if ($Choice -match "^[Dd]$") {
            $Selected = Select-MtpItem `
                -Folder $Folder

            if ($null -ne $Selected) {
                Remove-MtpFile `
                    -Folder $Folder `
                    -Item $Selected `
                    -LogicalPath $LogicalPath
            }

            continue
        }

        if ($Choice -match "^\d+$") {
            $Number = [int]$Choice

            if (
                $Number -lt 1 -or
                $Number -gt $DisplayItems.Count
            ) {
                Write-Host ""
                Write-Host "Invalid selection." `
                    -ForegroundColor Red

                Start-Sleep -Seconds 1

                continue
            }

            $Selected = $DisplayItems[$Number - 1]

            if ($Selected.IsFolder) {
                try {
                    $ChildFolder = $Selected.GetFolder()

                    if ($null -ne $ChildFolder) {
                        Invoke-KindleBrowser `
                            -Folder $ChildFolder `
                            -LogicalPath "$LogicalPath\$($Selected.Name)"
                    }
                }
                catch {
                    Write-Host ""
                    Write-Host "Unable to open folder." `
                        -ForegroundColor Red

                    Start-Sleep -Seconds 1
                }

                continue
            }

            Show-MtpItemInformation `
                -Folder $Folder `
                -Item $Selected `
                -LogicalPath $LogicalPath

            continue
        }

        Write-Host ""
        Write-Host "Unknown command." -ForegroundColor Yellow

        Start-Sleep -Seconds 1
    }
}

function Get-MtpParentFolder {
    param(
        [Parameter(Mandatory)]
        $Folder
    )

    try {
        $Parent = $Folder.ParentFolder

        if ($null -ne $Parent) {
            return $Parent
        }
    }
    catch {
    }

    return $null
}

function Get-ParentLogicalPath {
    param(
        [Parameter(Mandatory)]
        [string]$LogicalPath
    )

    $Index = $LogicalPath.LastIndexOf("\")

    if ($Index -lt 0) {
        return $LogicalPath
    }

    return $LogicalPath.Substring(0, $Index)
}

function Select-MtpItem {
    param(
        [Parameter(Mandatory)]
        $Folder
    )

    $Items = @(Get-MtpItems $Folder)

    if ($Items.Count -eq 0) {
        Write-Host ""
        Write-Host "No items available." -ForegroundColor Yellow

        Pause-Screen

        return $null
    }

    Write-Host ""
    Write-Host "Select item:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $Item = $Items[$i]

        if ($Item.IsFolder) {
            Write-Host (
                "[{0}] [DIR] {1}" -f `
                ($i + 1),
                $Item.Name
            )
        }
        else {
            $Size = Get-MtpFileSize `
                -Documents $Folder `
                -Item $Item

            Write-Host (
                "[{0}]      {1} ({2})" -f `
                ($i + 1),
                $Item.Name,
                (Format-Size $Size)
            )
        }
    }

    Write-Host ""

    $Choice = Read-Host "Number (blank = cancel)"

    if ([string]::IsNullOrWhiteSpace($Choice)) {
        return $null
    }

    if ($Choice -notmatch "^\d+$") {
        Write-Host "Invalid selection." -ForegroundColor Red

        Pause-Screen

        return $null
    }

    $Number = [int]$Choice

    if (
        $Number -lt 1 -or
        $Number -gt $Items.Count
    ) {
        Write-Host "Invalid selection." -ForegroundColor Red

        Pause-Screen

        return $null
    }

    return $Items[$Number - 1]
}

function Show-MtpItemInformation {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [string]$LogicalPath
    )

    Clear-Host

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " ITEM INFORMATION" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Name:" -ForegroundColor Gray
    Write-Host "  $($Item.Name)" -ForegroundColor White

    Write-Host ""
    Write-Host "Type:" -ForegroundColor Gray
    Write-Host "  $(Get-MtpItemType -Folder $Folder -Item $Item)" `
        -ForegroundColor White

    Write-Host ""

    if ($Item.IsFolder) {
        Write-Host "Kind:" -ForegroundColor Gray
        Write-Host "  Folder" -ForegroundColor Yellow
    }
    else {
        $Size = Get-MtpFileSize `
            -Documents $Folder `
            -Item $Item

        Write-Host "Size:" -ForegroundColor Gray
        Write-Host "  $(Format-Size $Size)" `
            -ForegroundColor White
    }

    Write-Host ""

    Write-Host "Logical MTP path:" -ForegroundColor Gray
    Write-Host "  $LogicalPath\$($Item.Name)" `
        -ForegroundColor Cyan

    Write-Host ""

    try {
        if (-not [string]::IsNullOrWhiteSpace($Item.Path)) {
            Write-Host "Windows MTP path:" -ForegroundColor Gray
            Write-Host "  $($Item.Path)" `
                -ForegroundColor DarkCyan

            Write-Host ""
        }
    }
    catch {
    }

    Pause-Screen
}

function Copy-MtpItemToPC {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [string]$LogicalPath
    )

    $Name = [string]$Item.Name

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " COPY KINDLE ITEM TO PC" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Source:" -ForegroundColor Gray
    Write-Host "  $LogicalPath\$Name" -ForegroundColor White

    Write-Host ""
    Write-Host "Destination:" -ForegroundColor Gray
    Write-Host "  $PcBooksFolder" -ForegroundColor Cyan

    Write-Host ""

    $Confirm = Read-Host "Copy this item to PC? (Y/N)"

    if ($Confirm -notmatch "^[Yy]$") {
        Write-Host ""
        Write-Host "Cancelled." -ForegroundColor Yellow

        Pause-Screen

        return
    }

    if (-not (Test-Path -LiteralPath $PcBooksFolder)) {
        New-Item `
            -ItemType Directory `
            -Path $PcBooksFolder `
            -Force |
            Out-Null
    }

    $Destination = Join-Path `
        $PcBooksFolder `
        $Name

    if (Test-Path -LiteralPath $Destination) {
        Write-Host ""
        Write-Host "A file/folder with this name already exists:" `
            -ForegroundColor Yellow

        Write-Host "  $Destination"

        Write-Host ""

        $Overwrite = Read-Host "Replace it? (Y/N)"

        if ($Overwrite -notmatch "^[Yy]$") {
            Write-Host "Cancelled." -ForegroundColor Yellow

            Pause-Screen

            return
        }

        try {
            Remove-Item `
                -LiteralPath $Destination `
                -Recurse `
                -Force
        }
        catch {
            Write-Host ""
            Write-Host "Could not remove existing destination." `
                -ForegroundColor Red

            Write-Host $_.Exception.Message

            Pause-Screen

            return
        }
    }

    try {
        $PcFolder = $Shell.Namespace($PcBooksFolder)

        if ($null -eq $PcFolder) {
            throw "Unable to access PC destination."
        }

        $PcFolder.CopyHere(
            $Item,
            $CopyFlags
        )

        Write-Host ""
        Write-Host "Copy started." -ForegroundColor Yellow
        Write-Host "Waiting for Windows to expose the destination..."

        $Verified = Wait-ForPCFile `
            -Path $Destination `
            -TimeoutSeconds $VerificationTimeoutSeconds

        Write-Host ""

        if ($Verified) {
            Write-Host "Copy verified successfully." `
                -ForegroundColor Green
        }
        else {
            Write-Host `
                "Copy could not be verified within the timeout." `
                -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "Copy failed." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    Pause-Screen
}

function Remove-MtpFile {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        $Item,

        [Parameter(Mandatory)]
        [string]$LogicalPath
    )

    if ($Item.IsFolder) {
        Write-Host ""
        Write-Host "Folder deletion is disabled." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "This tool only deletes individual files."

        Pause-Screen

        return
    }

    $Name = [string]$Item.Name

    $Size = Get-MtpFileSize `
        -Documents $Folder `
        -Item $Item

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Red

    Write-Host " DELETE KINDLE FILE" `
        -ForegroundColor Red

    Write-Host "============================================================" `
        -ForegroundColor Red

    Write-Host ""

    Write-Host "File:" -ForegroundColor Gray
    Write-Host "  $Name" -ForegroundColor White

    Write-Host ""
    Write-Host "Path:" -ForegroundColor Gray
    Write-Host "  $LogicalPath\$Name" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Size:" -ForegroundColor Gray
    Write-Host "  $(Format-Size $Size)" -ForegroundColor Yellow

    Write-Host ""
    Write-Host "WARNING:" -ForegroundColor Red
    Write-Host "This will delete the file from the Kindle."
    Write-Host ""

    Write-Host "Type DELETE to confirm." -ForegroundColor Yellow

    $Confirm = Read-Host "Confirmation"

    if ($Confirm -cne "DELETE") {
        Write-Host ""
        Write-Host "Deletion cancelled." -ForegroundColor Green

        Pause-Screen

        return
    }

    try {
        $Item.InvokeVerb("delete")

        Write-Host ""
        Write-Host "Delete command sent." -ForegroundColor Green

        Write-Host ""
        Write-Host "Verifying removal..."

        $Start = Get-Date

        $Removed = $false

        while (
            ((Get-Date) - $Start).TotalSeconds `
            -lt $VerificationTimeoutSeconds
        ) {
            $StillThere = Find-MtpItem `
                -Folder $Folder `
                -Name $Name

            if ($null -eq $StillThere) {
                $Removed = $true

                break
            }

            Start-Sleep -Milliseconds $VerificationIntervalMs
        }

        Write-Host ""

        if ($Removed) {
            Write-Host "Deletion verified." `
                -ForegroundColor Green
        }
        else {
            Write-Host `
                "Delete command was sent, but removal could not be verified." `
                -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host ""
        Write-Host "FAILED to delete the file." -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }

    Pause-Screen
}

function Search-Kindle {
    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {
        Write-Host ""
        Write-Host "Internal Storage unavailable." -ForegroundColor Red

        return
    }

    Clear-Host

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " SEARCH KINDLE" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    $Query = Read-Host "Filename search"

    if ([string]::IsNullOrWhiteSpace($Query)) {
        return
    }

    Write-Host ""
    Write-Host "Searching recursively for:" -ForegroundColor Gray
    Write-Host "  $Query" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Please wait..." -ForegroundColor Yellow

    $Results = New-Object `
        System.Collections.Generic.List[object]

    Search-MtpFolderForFiles `
        -Folder $Storage `
        -LogicalPath $(Get-KindleStoragePath) `
        -Query $Query `
        -Results $Results

    Clear-Host

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " SEARCH RESULTS" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Search:" -ForegroundColor Gray
    Write-Host "  $Query"

    Write-Host ""
    Write-Host "Results: $($Results.Count)" `
        -ForegroundColor Green

    Write-Host ""

    if ($Results.Count -eq 0) {
        Write-Host "No matching files found." `
            -ForegroundColor Yellow

        Pause-Screen

        return
    }

    for ($i = 0; $i -lt $Results.Count; $i++) {
        $Result = $Results[$i]

        Write-Host (
            "[{0}] {1}" -f `
            ($i + 1),
            $Result.Name
        ) -ForegroundColor White

        Write-Host (
            "    Type : {0}" -f $Result.Type
        )

        Write-Host (
            "    Size : {0}" -f $Result.SizeText
        )

        Write-Host (
            "    Path : {0}" -f $Result.LogicalPath
        )

        Write-Host ""
    }

    Pause-Screen
}

function Search-MtpFolderForFiles {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$LogicalPath,

        [Parameter(Mandatory)]
        [string]$Query,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )

    try {
        foreach ($Item in Get-MtpItems $Folder) {
            try {
                $Name = [string]$Item.Name

                if ($Item.IsFolder) {
                    $ChildFolder = $Item.GetFolder()

                    if ($null -ne $ChildFolder) {
                        Search-MtpFolderForFiles `
                            -Folder $ChildFolder `
                            -LogicalPath "$LogicalPath\$Name" `
                            -Query $Query `
                            -Results $Results
                    }
                }
                else {
                    if ($Name -like "*$Query*") {
                        $Size = Get-MtpFileSize `
                            -Documents $Folder `
                            -Item $Item

                        $Results.Add(
                            [PSCustomObject]@{
                                Item        = $Item
                                Name        = $Name
                                Type        = Get-MtpItemType `
                                    -Folder $Folder `
                                    -Item $Item
                                Size        = $Size
                                SizeText    = Format-Size $Size
                                LogicalPath = "$LogicalPath\$Name"
                            }
                        )
                    }
                }
            }
            catch {
                continue
            }
        }
    }
    catch {
    }
}
#endregion

#region Kindle backups
function Backup-Kindle {
    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {
        Write-Host ""
        Write-Host "Internal Storage unavailable." -ForegroundColor Red

        return
    }

    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    $BackupRoot = Join-Path `
        $PcBackupFolder `
        $Timestamp

    New-Item `
        -ItemType Directory `
        -Path $BackupRoot `
        -Force |
        Out-Null

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " KINDLE BACKUP" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Backup destination:" -ForegroundColor Gray
    Write-Host "  $BackupRoot" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "The backup copies accessible files exposed by Windows MTP."
    Write-Host "The folder structure will be recreated on the PC."
    Write-Host ""

    $Confirm = Read-Host "Start backup? (Y/N)"

    if ($Confirm -notmatch "^[Yy]$") {
        Write-Host ""
        Write-Host "Backup cancelled." -ForegroundColor Yellow

        return
    }

    $Stats = @{
        Files   = 0
        Folders = 0
        Failed  = 0
        Bytes   = [double]0
    }

    Write-Host ""
    Write-Host "Starting backup..." -ForegroundColor Yellow
    Write-Host ""

    try {
        Backup-MtpFolder `
            -Folder $Storage `
            -LogicalPath $(Get-KindleStoragePath) `
            -Destination $BackupRoot `
            -Stats $Stats

        Write-Host ""
        Write-Host "============================================================" `
            -ForegroundColor Green

        Write-Host " BACKUP COMPLETE" `
            -ForegroundColor Green

        Write-Host "============================================================" `
            -ForegroundColor Green

        Write-Host ""

        Write-Host "Files copied : $($Stats.Files)"
        Write-Host "Folders      : $($Stats.Folders)"
        Write-Host "Failed       : $($Stats.Failed)"
        Write-Host "Known size   : $(Format-Size $Stats.Bytes)"

        Write-Host ""
        Write-Host "Backup folder:" -ForegroundColor Gray
        Write-Host "  $BackupRoot" -ForegroundColor Green
    }
    catch {
        Write-Host ""
        Write-Host "Backup failed:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

function Backup-MtpFolder {
    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$LogicalPath,

        [Parameter(Mandatory)]
        [string]$Destination,

        [Parameter(Mandatory)]
        [hashtable]$Stats
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item `
            -ItemType Directory `
            -Path $Destination `
            -Force |
            Out-Null
    }

    foreach ($Item in Get-MtpItems $Folder) {
        try {
            $Name = [string]$Item.Name

            if ($Item.IsFolder) {
                $Stats.Folders++

                $ChildDestination = Join-Path `
                    $Destination `
                    $Name

                if (-not (Test-Path -LiteralPath $ChildDestination)) {
                    New-Item `
                        -ItemType Directory `
                        -Path $ChildDestination `
                        -Force |
                        Out-Null
                }

                Backup-MtpFolder `
                    -Folder $Item.GetFolder() `
                    -LogicalPath "$LogicalPath\$Name" `
                    -Destination $ChildDestination `
                    -Stats $Stats

                continue
            }

            $Stats.Files++

            Write-Host "Copying: $LogicalPath\$Name"

            $PcFolder = $Shell.Namespace($Destination)

            if ($null -eq $PcFolder) {
                throw "Could not access backup destination."
            }

            $DestinationFile = Join-Path `
                $Destination `
                $Name

            if (Test-Path -LiteralPath $DestinationFile) {
                $BaseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
                $Extension = [System.IO.Path]::GetExtension($Name)

                $Counter = 1

                do {
                    $AlternativeName = `
                        "{0}_{1}{2}" -f `
                        $BaseName,
                        $Counter,
                        $Extension

                    $DestinationFile = Join-Path `
                        $Destination `
                        $AlternativeName

                    $Counter++
                } while (
                    Test-Path -LiteralPath $DestinationFile
                )
            }

            $PcFolder.CopyHere(
                $Item,
                $CopyFlags
            )

            $Size = Get-MtpFileSize `
                -Documents $Folder `
                -Item $Item

            if ($Size -gt 0) {
                $Stats.Bytes += $Size
            }

            $Verified = Wait-ForPCFile `
                -Path $DestinationFile `
                -TimeoutSeconds $VerificationTimeoutSeconds

            if ($Verified) {
                Write-Host "  Verified." `
                    -ForegroundColor Green
            }
            else {
                Write-Host "  Could not verify." `
                    -ForegroundColor Yellow

                $Stats.Failed++
            }

            Start-Sleep -Seconds $BackupCopyWaitSeconds
        }
        catch {
            $Stats.Failed++

            Write-Host ""
            Write-Host "FAILED: $LogicalPath\$($Item.Name)" `
                -ForegroundColor Red

            Write-Host $_.Exception.Message `
                -ForegroundColor Red
        }
    }
}
#endregion

#region Kindle information and storage
function Show-KindleStorage {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " KINDLE STORAGE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Kindle = Get-Kindle
    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {
        Write-Host ""
        Write-Host "Internal Storage unavailable." -ForegroundColor Red

        return
    }

    Write-Host ""
    Write-Host "Device:" -ForegroundColor Gray
    Write-Host "  $($Kindle.Name)" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Scanning accessible files..." -ForegroundColor Yellow
    Write-Host ""

    $Results = New-Object `
        System.Collections.Generic.List[object]

    Get-MtpFolderContentsRecursive `
        -Folder $Storage `
        -LogicalPath $(Get-KindleStoragePath) `
        -Results $Results

    $Files = @(
        $Results |
        Where-Object { -not $_.IsFolder }
    )

    $Folders = @(
        $Results |
        Where-Object { $_.IsFolder }
    )

    [double]$TotalSize = 0
    $KnownSizeFiles = 0

    foreach ($File in $Files) {
        if ($File.Size -gt 0) {
            $TotalSize += $File.Size
            $KnownSizeFiles++
        }
    }

    Write-Host "Accessible folders : $($Folders.Count)" `
        -ForegroundColor White

    Write-Host "Accessible files   : $($Files.Count)" `
        -ForegroundColor White

    Write-Host "Files with size    : $KnownSizeFiles" `
        -ForegroundColor White

    Write-Host ""
    Write-Host "Known file size    : $(Format-Size $TotalSize)" `
        -ForegroundColor Yellow

    Write-Host ""
    Write-Host "Windows MTP capacity information:" `
        -ForegroundColor Cyan

    $KindleFolder = $Kindle.GetFolder()

    $StorageItem = $null

    try {
        foreach ($Item in $KindleFolder.Items()) {
            if ([string]$Item.Name -eq "Internal Storage") {
                $StorageItem = $Item

                break
            }
        }
    }
    catch {
    }

    if ($null -ne $StorageItem) {
        $FoundInfo = $false

        for ($Column = 0; $Column -lt 40; $Column++) {
            try {
                $Text = $KindleFolder.GetDetailsOf(
                    $StorageItem,
                    $Column
                )

                if (-not [string]::IsNullOrWhiteSpace($Text)) {
                    if (
                        $Text -match "(?i)free" -or
                        $Text -match "(?i)space" -or
                        $Text -match "(?i)capacity" -or
                        $Text -match "(?i)size"
                    ) {
                        Write-Host "  $Text"

                        $FoundInfo = $true
                    }
                }
            }
            catch {
            }
        }

        if (-not $FoundInfo) {
            Write-Host ""
            Write-Host `
                "Windows MTP did not expose total/free capacity." `
                -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ""
        Write-Host `
            "Internal Storage details unavailable through Shell." `
            -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Note:" -ForegroundColor Gray
    Write-Host `
        "Known file size is calculated only from files whose sizes" `
        -ForegroundColor Gray
    Write-Host `
        "Windows exposes through the MTP Shell interface." `
        -ForegroundColor Gray
}

function Show-KindleInfo {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " KINDLE INFORMATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Kindle = Get-Kindle
    $Storage = Get-KindleInternalStorage
    $Documents = Get-KindleDocuments

    Write-Host ""

    Write-Host "Device:" -ForegroundColor Gray
    Write-Host "  $($Kindle.Name)" -ForegroundColor Green

    Write-Host ""

    Write-Host "Windows path:" -ForegroundColor Gray
    Write-Host "  $(Get-KindleRootPath)" -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Internal Storage:" -ForegroundColor Gray

    if ($null -ne $Storage) {
        Write-Host "  Detected" -ForegroundColor Green
    }
    else {
        Write-Host "  NOT FOUND" -ForegroundColor Red
    }

    Write-Host ""

    Write-Host "Documents path:" -ForegroundColor Gray
    Write-Host "  $(Get-KindlePath)" -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Documents folder:" -ForegroundColor Gray

    if ($null -ne $Documents) {
        Write-Host "  Detected" -ForegroundColor Green
    }
    else {
        Write-Host "  NOT FOUND" -ForegroundColor Red
    }

    Write-Host ""

    Write-Host "PC books folder:" -ForegroundColor Gray
    Write-Host "  $PcBooksFolder" -ForegroundColor Green

    Write-Host ""

    Write-Host "Backup folder:" -ForegroundColor Gray
    Write-Host "  $PcBackupFolder" -ForegroundColor Green

    Write-Host ""


    Write-Host "Supported PC file types:" -ForegroundColor Gray
    Write-Host "  $($SupportedExtensions -join ', ')" `
        -ForegroundColor DarkCyan

    Write-Host ""
}
#endregion

#region Manage Kindle menu
function Open-PCBooksFolder {
    try {
        Start-Process `
            explorer.exe `
            -ArgumentList "`"$PcBooksFolder`""

        Write-Host ""
        Write-Host "Opened:" -ForegroundColor Green
        Write-Host "  $PcBooksFolder"
    }
    catch {
        Write-Host ""
        Write-Host "Could not open folder." -ForegroundColor Red
    }
}

function Show-MainMenu {
    Clear-Host

    $Connected = Test-KindleConnection

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host "              KINDLE MTP FILE MANAGER" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""

    Write-Host "Kindle status:" -ForegroundColor Gray

    if ($Connected) {
        Write-Host `
            "  CONNECTED - $(Get-KindleName)" `
            -ForegroundColor Green
    }
    else {
        Write-Host `
            "  NOT CONNECTED" `
            -ForegroundColor Yellow
    }

    Write-Host ""

    Write-Host "PC books:" -ForegroundColor Gray
    Write-Host "  $PcBooksFolder" -ForegroundColor Cyan

    Write-Host ""

    Write-Host "------------------------------------------------------------"
    Write-Host ""

    for ($i = 0; $i -lt $ManageActions.Count; $i++) {
        Write-Host ('{0}. {1}' -f ($i + 1), $ManageActions[$i].Label)
    }
    Write-Host ('{0}. Return to Kindle Manager' -f ($ManageActions.Count + 1))

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host ""
}
#endregion

#region Application entry points
function Invoke-BookDownloader {
    [CmdletBinding()]
    param(
        [ValidateSet('standard', 'alice', 'globalgrey', 'gutenberg', 'url', 'manifest')]
        [string]$Source,

        [string]$Search,

        [string[]]$Category,

        [string]$Url,

        [string]$Manifest,

        [string]$Output,

        [switch]$Kindle,

        [string]$KindlePath,

        [ValidateSet('epub', 'pdf', 'mobi', 'kindle')]
        [string]$Format = 'mobi',

        [int]$Delay = 1000,

        [int]$Limit = 3,   # 0 = unlimited

        [int]$Retries = 1,

        [int]$Timeout = 30000,

        [switch]$DryRun,

        [switch]$Interactive,

        [switch]$Help
    )
    Set-StrictMode -Version Latest

    $ErrorActionPreference = 'Stop'

    $Script:SCRIPT_DIR = $script:ProjectRoot

    $Script:ALICE_URL = 'https://www.aliceandbooks.com'

    $Script:STANDARD_URL = 'https://standardebooks.org'

    $Script:STANDARD_EBOOKS_URL = "$($Script:STANDARD_URL)/ebooks"

    $Script:USER_AGENT = 'BookDownloader/3.1-ps1 (personal downloader)'

    try {
        Invoke-DownloadWorkflow
    } catch {
        Write-Host ''
        Write-ErrMsg ($_.Exception.Message)
        if ($_.ScriptStackTrace) {
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        }
        throw
    }
}

function Invoke-KindleTransfer {
    $ErrorActionPreference = "Stop"

    $PcRootFolder = $script:ProjectRoot

    $PcBooksFolder = $script:BOOKS_DIR

    $PcBackupFolder = $script:BACKUP_DIR

    $SupportedExtensions = @(
        ".epub",
        ".pdf",
        ".mobi",
        ".azw",
        ".azw3",
        ".kfx",
        ".doc",
        ".docx",
        ".rtf",
        ".html",
        ".htm",
        ".cbz",
        ".cbr"
    )

    $CopyFlags = 20

    $VerificationTimeoutSeconds = 45

    $VerificationIntervalMs     = 750

    $BackupCopyWaitSeconds = 2

    $Shell = New-Object -ComObject Shell.Application

    foreach ($folder in @($PcBooksFolder, $PcBackupFolder)) { Ensure-Directory $folder }

    $ManageActions = @(
        @{ Label = 'Send books to Kindle'; Action = { Copy-PCToKindle } }
        @{ Label = 'Copy books from Kindle'; Action = { Copy-KindleToPC } }
        @{ Label = 'Browse Kindle files'; Action = { Browse-Kindle } }
        @{ Label = 'Backup Kindle'; Action = { Backup-Kindle } }
        @{ Label = 'Kindle information and storage'; Action = {
            Show-KindleInfo
            if (Test-KindleConnection) { Show-KindleStorage }
        } }
        @{ Label = 'Open PC books folder'; Action = { Open-PCBooksFolder } }
    )
    while ($true) {
        Show-MainMenu
        $Choice = Read-Host "Choose an option"
        if ($Choice -eq [string]($ManageActions.Count + 1)) { return }
        Clear-Host
        $index = 0
        if ([int]::TryParse($Choice, [ref]$index) -and $index -ge 1 -and $index -le $ManageActions.Count) {
            try { & $ManageActions[$index - 1].Action }
            catch { Write-ErrMsg $_.Exception.Message }
        } else {
            Write-WarnMsg 'Invalid option.'
        }
        Pause-Screen
    }
}
#endregion

#region Test runner
function Invoke-KindleTests {
    $testFolder = Join-Path $script:ProjectRoot 'tests'
    $testFiles = @(Get-ChildItem -LiteralPath $testFolder -Filter 'Test*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($testFiles.Count -eq 0) {
        Write-ErrMsg "No test scripts found in $testFolder. Keep the tests folder beside KindleManager.ps1 to use this option."
        return $false
    }

    # Each suite gets a fresh process so its mocked functions cannot affect the app.
    $engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $engine = Join-Path $PSHOME $engineName
    $passed = 0
    foreach ($testFile in $testFiles) {
        Write-Step "Running $($testFile.Name)"
        try {
            & $engine -NoProfile -NonInteractive -File $testFile.FullName | Out-Host
            if ($LASTEXITCODE -eq 0) {
                $passed++
                Write-Success "PASS: $($testFile.Name)"
            } else {
                Write-ErrMsg "FAIL: $($testFile.Name) (exit code $LASTEXITCODE)"
            }
        } catch {
            Write-ErrMsg "FAIL: $($testFile.Name): $($_.Exception.Message)"
        }
    }
    Write-Step 'Test results'
    Write-Success "Passed: $passed / $($testFiles.Count)"
    if ($passed -ne $testFiles.Count) { Write-ErrMsg "Failed: $($testFiles.Count - $passed)" }
    return ($passed -eq $testFiles.Count)
}
#endregion

#region Main menu and command-line routing
# Dot-sourcing loads the functions without opening the interactive menu.
if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $DryRun) { Invoke-SelfRepair }
if ($Mode -eq 'Test') {
    if (-not (Invoke-KindleTests)) { exit 1 }
    return
}
$downloadArguments = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -ne 'Mode') { $downloadArguments[$key] = $PSBoundParameters[$key] }
}
if ($Mode -eq 'Transfer') {
    Invoke-KindleTransfer
    return
}
if ($Mode -eq 'Download' -or $downloadArguments.Count -gt 0) {
    if ($Help) {
        Write-Host 'Kindle Manager: run without arguments for the main menu.'
        Write-Host '  -Mode Transfer    Open the Kindle USB / MTP file manager'
        Write-Host '  -Mode Download    Open the book downloader'
        Write-Host '  -Mode Test        Run the offline test scripts'
    }
    Invoke-BookDownloader @downloadArguments
    return
}
while ($true) {
    Write-Host ''
    Write-Host 'Kindle Manager' -ForegroundColor Cyan
    Write-Host '  1. Download books'
    Write-Host '  2. Manage Kindle'
    Write-Host '  3. Run tests'
    Write-Host '  4. Exit'
    $selection = Read-Host 'Choose an option'
    try {
        switch ($selection) {
            '1' { Invoke-BookDownloader }
            '2' { Invoke-KindleTransfer }
            '3' { $null = Invoke-KindleTests; Pause-Screen }
            '4' { return }
            default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
        }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
#endregion
