#!/usr/bin/env pwsh
#Requires -Version 5.1
<#
.SYNOPSIS
  Portable legal/authorized book downloader (PowerShell)

.DESCRIPTION
  Supported sources:
    * Standard Ebooks (https://standardebooks.org)
    * AliceAndBooks
    * Direct authorized URLs
    * JSON manifests

  NOT supported:
    * Project Gutenberg
    * Internet Archive
    * Archive.org

  Features:
    * Uses its own folder as the working directory
    * Interactive menu when no source is specified
    * EPUB / PDF / MOBI (azw3 for Kindle via Standard Ebooks)
    * Optional Kindle copying + Windows auto-detect
    * Dry-run mode, retries, timeout, inventory JSON

.EXAMPLE
  .\book_downloader.ps1
  .\book_downloader.ps1 -Interactive
  .\book_downloader.ps1 -Source standard -Limit 10
  .\book_downloader.ps1 -Url "https://example.com/book.epub"
  .\book_downloader.ps1 -Manifest books.json -Format epub
  .\book_downloader.ps1 -Source standard -Kindle -DryRun
#>

[CmdletBinding()]
param(
    [ValidateSet('standard', 'alice', 'url', 'manifest')]
    [string]$Source,

    [string]$Url,

    [string]$Manifest,

    [string]$Output,

    [switch]$Kindle,

    [string]$KindlePath,

    [ValidateSet('epub', 'pdf', 'mobi', 'kindle')]
    [string]$Format = 'pdf',

    [int]$Delay = 1000,

    [int]$Limit = 3,   # 0 = unlimited

    [int]$Retries = 3,

    [int]$Timeout = 30000,

    [switch]$DryRun,

    [switch]$Interactive,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# CONSTANTS
# ============================================================
$Script:SCRIPT_DIR = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Script:BOOKS_DIR = Join-Path $Script:SCRIPT_DIR 'books'
$Script:BACKUP_DIR = Join-Path $Script:SCRIPT_DIR 'backup'
$Script:INVENTORY_DIR = Join-Path $Script:SCRIPT_DIR 'inventory'
$Script:INVENTORY_FILE = Join-Path $Script:INVENTORY_DIR 'inventory.json'
$Script:ALICE_URL = 'https://www.aliceandbooks.com'
$Script:STANDARD_URL = 'https://standardebooks.org'
$Script:STANDARD_EBOOKS_URL = "$($Script:STANDARD_URL)/ebooks"
$Script:USER_AGENT = 'LegalBookDownloader/3.1-ps1 (personal lawful-use downloader)'

# ============================================================
# LOGGING
# ============================================================
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

# ============================================================
# HELPERS
# ============================================================
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

function Ensure-Directory([string]$Directory) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

function Show-Help {
    @"

book_downloader.ps1
Portable legal/authorized book downloader (PowerShell).

SOURCES
  standard           Download from Standard Ebooks (default in interactive)
  alice              Download from AliceAndBooks
  url                Download from a direct authorized URL
  manifest           Download from a JSON manifest

OPTIONS
  -Source <source>       standard | alice | url | manifest
  -Url <url>             Direct authorized book URL (sets source=url)
  -Manifest <file>       JSON manifest file (sets source=manifest)
  -Output <folder>       Download destination (default: ./books)
  -Kindle                Copy downloaded books to Kindle
  -KindlePath <folder>   Kindle documents folder (auto-detect if omitted)
  -Format <format>       epub | pdf | mobi | kindle  (default: pdf)
  -Delay <ms>            Delay between downloads (default: 1000)
  -Limit <n>             Max number of books (default: 3; 0 = unlimited)
  -Retries <n>           Download attempts (default: 3)
  -Timeout <ms>          Download timeout (default: 30000)
  -DryRun                Test only; no downloads or file changes
  -Interactive           Force interactive menu
  -Help                  Show this help

EXAMPLES
  .\book_downloader.ps1
  .\book_downloader.ps1 -Interactive
  .\book_downloader.ps1 -Source standard -Limit 10
  .\book_downloader.ps1 -Url "https://example.com/book.epub"
  .\book_downloader.ps1 -Manifest books.json
  .\book_downloader.ps1 -Source standard -Format mobi -Kindle
  .\book_downloader.ps1 -DryRun -Source standard -Limit 3

"@ | Write-Host
}

# ============================================================
# HTTP
# ============================================================
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

# ============================================================
# HTML HELPERS
# ============================================================
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

# ============================================================
# STANDARD EBOOKS
# ============================================================
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

    if ($fmt -eq 'mobi') {
        return [pscustomobject]@{
            Url       = "$base/$slug.azw3"
            Format    = 'mobi'
            Extension = 'azw3'
        }
    }

    return [pscustomobject]@{
        Url       = "$base/$slug.epub"
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
    $limit = if ($Options.Limit -gt 0) { $Options.Limit } else { [int]::MaxValue }

    $bookItemRegex = [regex]'<li\b[^>]*typeof\s*=\s*["'']schema:Book["''][^>]*about\s*=\s*["'']([^"'']+)["''][^>]*>([\s\S]*?)</li>'
    $nameRegex = [regex]'property\s*=\s*["'']schema:name["''][^>]*>([^<]+)<'

    while ($page -le $maxPages) {
        $url = "$($Script:STANDARD_EBOOKS_URL)?page=$page"
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

    return $books
}

function Build-StandardDownloadList {
    param($Options)

    $books = @(Get-StandardBooks -Options $Options)
    if ($books.Count -eq 0) {
        throw 'No books were found on Standard Ebooks.'
    }

    $limit = if ($Options.Limit -gt 0) { $Options.Limit } else { $books.Count }
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

# ============================================================
# ALICEANDBOOKS
# ============================================================
function Get-AliceBookId([string]$Url) {
    if ($Url -match '/book/([^/?#]+)') { return $Matches[1] }
    return $null
}

function Get-AliceBooks {
    param($Options)

    Write-Step 'Reading AliceAndBooks catalogue...'
    $resp = Invoke-BookWebRequest -Uri $Script:ALICE_URL -Accept 'text/html' -TimeoutMs $Options.Timeout
    if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
        throw "AliceAndBooks returned HTTP $($resp.StatusCode)"
    }

    $links = Get-HtmlLinks -Html $resp.Content -BaseUrl $Script:ALICE_URL
    $books = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($link in $links) {
        if ($link.Url -notmatch '/book/') { continue }
        $id = Get-AliceBookId $link.Url
        if (-not $id -or $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $title = if ($link.Text) { $link.Text } else { ($id -replace '[-_]+', ' ') }
        $books.Add([pscustomobject]@{
            Id      = $id
            Title   = $title
            PageUrl = $link.Url
        })
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

    foreach ($link in $links) {
        if ($link.Url -match '\.(epub|pdf|mobi)(?:[?#]|$)') {
            return [pscustomobject]@{
                Url    = $link.Url
                Title  = $Book.Title
                Format = (Get-ExtensionFromUrl $link.Url 'epub')
            }
        }
    }

    foreach ($link in $links) {
        $text = ("$($link.Text) $($link.Url)").ToLowerInvariant()
        if ($text -match 'download|epub|pdf|mobi') {
            if (Test-HttpUrl $link.Url) {
                return [pscustomobject]@{
                    Url    = $link.Url
                    Title  = $Book.Title
                    Format = (Get-ExtensionFromUrl $link.Url 'epub')
                }
            }
        }
    }

    throw "No supported EPUB / PDF / MOBI download found for `"$($Book.Title)`""
}

function Build-AliceDownloadList {
    param($Options)

    $books = @(Get-AliceBooks -Options $Options)
    if ($books.Count -eq 0) {
        throw 'No books were found on AliceAndBooks.'
    }

    $limit = if ($Options.Limit -gt 0) { $Options.Limit } else { $books.Count }
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

# ============================================================
# DIRECT URL / MANIFEST
# ============================================================
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
        'url'      { return Build-UrlDownloadList -Options $Options }
        'manifest' { return Build-ManifestDownloadList -Options $Options }
        default    { throw "Unsupported source: $($Options.Source)" }
    }
}

# ============================================================
# DOWNLOAD
# ============================================================
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

# ============================================================
# KINDLE
# ============================================================
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

# ============================================================
# INVENTORY
# ============================================================
function Write-Inventory {
    param([object[]]$Records)

    Ensure-Directory $Script:INVENTORY_DIR
    $inventory = [ordered]@{
        generatedAt     = (Get-Date).ToUniversalTime().ToString('o')
        scriptDirectory = $Script:SCRIPT_DIR
        booksDirectory  = $Script:BOOKS_DIR
        backupDirectory = $Script:BACKUP_DIR
        records         = @($Records)
    }
    $json = $inventory | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Script:INVENTORY_FILE -Value $json -Encoding UTF8
}

# ============================================================
# DRY RUN
# ============================================================
function Invoke-DryRun {
    param($Options)

    Write-Step 'DRY RUN'
    Write-Host 'No files will be created, downloaded, overwritten, or copied.'
    Write-Host ''
    Write-Host "Script folder: $($Script:SCRIPT_DIR)"
    Write-Host "Books folder:  $($Options.Output)"
    Write-Host "Backup folder: $($Script:BACKUP_DIR)"
    Write-Host "Inventory:     $($Script:INVENTORY_FILE)"
    Write-Host "Source:        $($Options.Source)"
    Write-Host "Format:        $($Options.Format)"
    Write-Host "Delay:         $($Options.Delay) ms"
    $limitText = if ($Options.Limit -gt 0) { $Options.Limit } else { 'unlimited' }
    Write-Host "Limit:         $limitText"
    Write-Host "Retries:       $($Options.Retries)"
    Write-Host "Timeout:       $($Options.Timeout) ms"
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

# ============================================================
# INTERACTIVE
# ============================================================
function Read-Choice {
    param(
        [string]$Prompt,
        [hashtable[]]$Choices,
        [string]$DefaultKey
    )

    Write-Host ''
    Write-Host $Prompt
    foreach ($c in $Choices) {
        $marker = if ($c.Key -eq $DefaultKey) { ' (default)' } else { '' }
        Write-Host ("  {0}) {1}{2}" -f $c.Key, $c.Label, $marker)
    }

    while ($true) {
        $answer = (Read-Host "Enter choice [$DefaultKey]").Trim()
        if ([string]::IsNullOrEmpty($answer)) { $answer = $DefaultKey }
        $found = $Choices | Where-Object { $_.Key -eq $answer } | Select-Object -First 1
        if ($found) { return $found.Value }
        Write-Host 'Invalid choice. Please try again.'
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )
    $hint = if ($DefaultYes) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant()
        if ([string]::IsNullOrEmpty($answer)) { return $DefaultYes }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-Host 'Please enter y or n.'
    }
}

function Invoke-Interactive {
    param($Base)

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Portable Legal Book Downloader — Interactive Mode'
    Write-Host '============================================================'

    $source = Read-Choice -Prompt 'Select download source:' -DefaultKey '1' -Choices @(
        @{ Key = '1'; Label = 'Standard Ebooks (public domain, high quality)'; Value = 'standard' }
        @{ Key = '2'; Label = 'AliceAndBooks'; Value = 'alice' }
        @{ Key = '3'; Label = 'Direct authorized URL'; Value = 'url' }
        @{ Key = '4'; Label = 'JSON manifest file'; Value = 'manifest' }
    )

    $url = $null
    $manifest = $null

    if ($source -eq 'url') {
        while ($true) {
            $url = (Read-Host 'Enter book URL (http/https)').Trim()
            if (Test-HttpUrl $url) { break }
            Write-Host 'Must be a valid HTTP or HTTPS URL.'
        }
    }

    if ($source -eq 'manifest') {
        while ($true) {
            $raw = (Read-Host 'Path to JSON manifest file').Trim()
            $manifest = Resolve-PortablePath $raw
            if (Test-Path -LiteralPath $manifest) { break }
            Write-Host "File not found: $manifest"
        }
    }

    $format = Read-Choice -Prompt 'Preferred format:' -DefaultKey '2' -Choices @(
        @{ Key = '1'; Label = 'EPUB'; Value = 'epub' }
        @{ Key = '2'; Label = 'PDF (where available)'; Value = 'pdf' }
        @{ Key = '3'; Label = 'MOBI / Kindle (azw3 on Standard Ebooks)'; Value = 'mobi' }
    )

    $limitRaw = (Read-Host "Max number of books [$($Base.Limit)]").Trim()
    $limit = $Base.Limit
    if ($limitRaw) {
        $n = 0
        if (-not [int]::TryParse($limitRaw, [ref]$n) -or $n -lt 1) {
            throw 'Limit must be a positive integer.'
        }
        $limit = $n
    }

    $dryRun = Read-YesNo -Prompt 'Dry-run only (no downloads)?' -DefaultYes:$false
    $kindle = $Base.Kindle
    $kindlePath = $Base.KindlePath
    $delay = $Base.Delay
    $retries = $Base.Retries
    $timeout = $Base.Timeout

    Write-Host ''
    Write-Host 'Summary'
    Write-Host '-------'
    Write-Host "  Source:   $source"
    if ($url) { Write-Host "  URL:      $url" }
    if ($manifest) { Write-Host "  Manifest: $manifest" }
    Write-Host "  Format:   $format"
    Write-Host ("  Limit:    {0}" -f $(if ($limit -gt 0) { $limit } else { 'unlimited' }))
    Write-Host ("  Dry-run:  {0}" -f $(if ($dryRun) { 'yes' } else { 'no' }))
    Write-Host ("  Kindle:   {0}" -f $(if ($kindle) { $(if ($kindlePath) { $kindlePath } else { 'auto-detect' }) } else { 'no' }))
    Write-Host "  Delay:    $delay ms"
    Write-Host "  Retries:  $retries"
    Write-Host "  Timeout:  $timeout ms"
    Write-Host ''

    if (-not (Read-YesNo -Prompt 'Proceed with these settings?' -DefaultYes:$true)) {
        Write-Host 'Cancelled.'
        exit 0
    }

    return [pscustomobject]@{
        Source     = $source
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
        DryRun     = $dryRun
    }
}

# ============================================================
# MAIN
# ============================================================
function Main {
    if ($Help) {
        Show-Help
        return
    }

    # Normalize initial param-based options
    $options = [pscustomobject]@{
        Source     = $Source
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

    $sourceExplicit = -not [string]::IsNullOrWhiteSpace($Source) -or $Url -or $Manifest
    $useInteractive = $Interactive -or (-not $sourceExplicit)

    if ($useInteractive) {
        $options = Invoke-Interactive -Base $options
    } else {
        if ([string]::IsNullOrWhiteSpace($options.Source)) {
            $options.Source = 'standard'
        }
    }

    # Validate
    if ($options.Source -notin @('standard', 'alice', 'url', 'manifest')) {
        Write-ErrMsg "Unsupported source `"$($options.Source)`"."
        exit 1
    }
    if (-not (Test-SupportedFormat $options.Format)) {
        Write-ErrMsg "Unsupported format `"$($options.Format)`"."
        exit 1
    }
    if ($options.Source -eq 'url' -and -not $options.Url) {
        Write-ErrMsg '-Source url requires -Url'
        exit 1
    }
    if ($options.Source -eq 'manifest' -and -not $options.Manifest) {
        Write-ErrMsg '-Source manifest requires -Manifest'
        exit 1
    }
    if ($options.Url -and -not (Test-HttpUrl $options.Url)) {
        Write-ErrMsg '-Url must be an HTTP or HTTPS URL'
        exit 1
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host ' Portable Legal Book Downloader'
    Write-Host '============================================================'

    if ($options.DryRun) {
        Invoke-DryRun -Options $options
        return
    }

    Ensure-Directory $options.Output
    Ensure-Directory $Script:BACKUP_DIR
    Ensure-Directory $Script:INVENTORY_DIR

    Write-Success "Books folder: $($options.Output)"
    Write-Success "Backup folder: $($Script:BACKUP_DIR)"
    Write-Success "Inventory folder: $($Script:INVENTORY_DIR)"

    $kindlePath = $null
    if ($options.Kindle) {
        $kindlePath = Get-ResolvedKindlePath -Options $options
        if (-not $kindlePath) {
            Write-WarnMsg 'Kindle was not detected.'
            Write-Host 'Continuing without Kindle copying.'
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
    $downloads = @(Build-DownloadList -Options $options)

    if ($downloads.Count -eq 0) {
        Write-WarnMsg 'No downloadable books were found.'
        return
    }

    Write-Success "Found $($downloads.Count) book(s) to process."

    $records = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($book in $downloads) {
        $index++
        $format = Normalize-Format $(if ($book.Format) { $book.Format } else { $options.Format })
        $ext = if ($book.PSObject.Properties.Name -contains 'Extension' -and $book.Extension) {
            $book.Extension
        } else {
            $format
        }

        $filename = Get-SafeFilename $(if ($book.Title) { $book.Title } else { Get-FilenameFromUrl $book.Url $format })
        $finalFilename = if ($filename.ToLowerInvariant().EndsWith(".$ext")) {
            $filename
        } else {
            "$filename.$ext"
        }
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

            $kindleDest = $null
            if ($kindlePath) {
                try {
                    $kindleDest = Copy-ToKindle -Source $destination -KindlePath $kindlePath
                    Write-Success "Copied to Kindle: $kindleDest"
                } catch {
                    Write-WarnMsg "Kindle copy failed: $($_.Exception.Message)"
                }
            }

            $records.Add([pscustomobject]@{
                title        = $book.Title
                url          = $book.Url
                format       = $format
                file         = $destination
                size         = $item.Length
                downloadedAt = (Get-Date).ToUniversalTime().ToString('o')
                kindle       = $kindleDest
                status       = 'success'
            })
        } catch {
            Write-ErrMsg "$($book.Title): $($_.Exception.Message)"
            $records.Add([pscustomobject]@{
                title        = $book.Title
                url          = $book.Url
                format       = $format
                file         = $destination
                downloadedAt = (Get-Date).ToUniversalTime().ToString('o')
                kindle       = $null
                status       = 'failed'
                error        = $_.Exception.Message
            })
        }

        if ($index -lt $downloads.Count -and $options.Delay -gt 0) {
            Start-Sleep -Milliseconds $options.Delay
        }
    }

    Write-Inventory -Records $records.ToArray()

    Write-Host ''
    Write-Step 'Finished'
    $successful = @($records | Where-Object { $_.status -eq 'success' }).Count
    $failed = @($records | Where-Object { $_.status -eq 'failed' }).Count
    Write-Success "Successful: $successful"
    if ($failed -gt 0) { Write-WarnMsg "Failed: $failed" }
    Write-Success "Inventory: $($Script:INVENTORY_FILE)"
    Write-Host ''
}

try {
    Main
} catch {
    Write-Host ''
    Write-ErrMsg ($_.Exception.Message)
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}
