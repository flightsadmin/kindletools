#requires -Version 5.1

# ============================================================
# KindleTransfer.ps1
#
# Enhanced Kindle Paperwhite USB / MTP File Manager
#
# PC:
#   D:\KindleTools\books
#   D:\KindleTools\backup
#
# Kindle:
#   This PC\Kindle...\Internal Storage
#
# FEATURES
#   1.  PC -> Kindle
#   2.  Kindle -> PC
#   3.  Full Kindle browser
#   4.  Browse documents
#   5.  Search Kindle files
#   6.  File information
#   7.  Timestamped Kindle backup
#   8.  Storage report
#   9.  Delete Kindle files
#   10. Kindle information
#   11. Open Kindle in File Explorer
#   12. Refresh / reconnect
#   13. Open PC books folder
#   14. List files in documents
#   15. Exit
#
# SAFETY
#   - No firmware operations
#   - No .bin update installation
#   - No jailbreak automation
#   - No security bypass
#   - Normal Windows Shell / MTP file operations only
#
# ============================================================

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$PcRootFolder       = "D:\KindleTools"
$PcBooksFolder      = Join-Path $PcRootFolder "books"
$PcBackupFolder     = Join-Path $PcRootFolder "backup"

# Supported files for PC -> Kindle.
$SupportedExtensions = @(
    ".epub",
    ".pdf",
    ".mobi",
    ".azw",
    ".azw3",
    ".kfx",
    ".txt",
    ".doc",
    ".docx",
    ".rtf",
    ".html",
    ".htm",
    ".cbz",
    ".cbr"
)

# CopyHere flags.
#
# 4  = No error UI
# 16 = No confirmation UI
#
# 20 = 4 + 16
$CopyFlags = 20

# MTP operations are asynchronous.
$VerificationTimeoutSeconds = 45
$VerificationIntervalMs     = 750

# Backup operations can involve many files.
$BackupCopyWaitSeconds = 2

# ============================================================
# WINDOWS SHELL
# ============================================================

$Shell = New-Object -ComObject Shell.Application

# ============================================================
# CREATE LOCAL DIRECTORIES
# ============================================================

function Initialize-LocalFolders {

    foreach ($Folder in @(
        $PcRootFolder,
        $PcBooksFolder,
        $PcBackupFolder
    )) {

        if (-not (Test-Path -LiteralPath $Folder)) {

            New-Item `
                -ItemType Directory `
                -Path $Folder `
                -Force |
                Out-Null
        }
    }
}

# ============================================================
# PAUSE
# ============================================================

function Pause-Screen {

    Write-Host ""
    Read-Host "Press ENTER to continue" | Out-Null
}

# ============================================================
# FORMAT SIZE
# ============================================================

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

# ============================================================
# GET THIS PC
# ============================================================

function Get-ThisPC {

    try {
        return $Shell.Namespace(17)
    }
    catch {
        return $null
    }
}

# ============================================================
# FIND KINDLE
# ============================================================

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

# ============================================================
# GET KINDLE NAME
# ============================================================

function Get-KindleName {

    $Kindle = Get-Kindle

    if ($null -eq $Kindle) {
        return "Kindle"
    }

    return [string]$Kindle.Name
}

# ============================================================
# GET KINDLE LOGICAL ROOT PATH
# ============================================================

function Get-KindleRootPath {

    $KindleName = Get-KindleName

    return "This PC\$KindleName"
}

# ============================================================
# GET KINDLE LOGICAL INTERNAL STORAGE PATH
# ============================================================

function Get-KindleStoragePath {

    $KindleName = Get-KindleName

    return "This PC\$KindleName\Internal Storage"
}

# ============================================================
# GET KINDLE LOGICAL DOCUMENTS PATH
# ============================================================

function Get-KindlePath {

    $KindleName = Get-KindleName

    return "This PC\$KindleName\Internal Storage\documents"
}

# ============================================================
# GET INTERNAL STORAGE
# ============================================================

function Get-KindleInternalStorage {

    $Kindle = Get-Kindle

    if ($null -eq $Kindle) {
        return $null
    }

    try {

        $KindleFolder = $Kindle.GetFolder()

        if ($null -eq $KindleFolder) {
            return $null
        }

        foreach ($Item in $KindleFolder.Items()) {

            if (
                [string]$Item.Name -eq "Internal Storage" -and
                $Item.IsFolder
            ) {
                return $Item.GetFolder()
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

# ============================================================
# GET DOCUMENTS
# ============================================================

function Get-KindleDocuments {

    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {
        return $null
    }

    try {

        foreach ($Item in $Storage.Items()) {

            if (
                [string]$Item.Name -eq "documents" -and
                $Item.IsFolder
            ) {
                return $Item.GetFolder()
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

# ============================================================
# WAIT FOR KINDLE
# ============================================================

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

# ============================================================
# TEST KINDLE CONNECTION
# ============================================================

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

# ============================================================
# GET MTP ITEMS
# ============================================================

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

# ============================================================
# FIND CHILD FOLDER
# ============================================================

function Find-MtpFolder {

    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$Name
    )

    try {

        foreach ($Item in $Folder.Items()) {

            if (
                $Item.IsFolder -and
                [string]$Item.Name -ieq $Name
            ) {

                return $Item.GetFolder()
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

# ============================================================
# GET ITEM TYPE
# ============================================================

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

# ============================================================
# GET FILE SIZE FROM MTP
# ============================================================

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

        # Windows Shell details column.
        # On most Windows systems column 1 is Size.

        $SizeText = $Documents.GetDetailsOf($Item, 1)

        if ([string]::IsNullOrWhiteSpace($SizeText)) {
            return 0
        }

        $Text = $SizeText.Trim().ToUpper()

        $Text = $Text.Replace(",", "")

        if ($Text -match "([0-9\.]+)\s*TB") {

            return ([double]$matches[1] * 1TB)
        }

        if ($Text -match "([0-9\.]+)\s*GB") {

            return ([double]$matches[1] * 1GB)
        }

        if ($Text -match "([0-9\.]+)\s*MB") {

            return ([double]$matches[1] * 1MB)
        }

        if ($Text -match "([0-9\.]+)\s*KB") {

            return ([double]$matches[1] * 1KB)
        }

        if ($Text -match "([0-9\.]+)\s*BYTES") {

            return [double]$matches[1]
        }

        if ($Text -match "([0-9\.]+)") {

            return [double]$matches[1]
        }
    }
    catch {
    }

    return 0
}

# ============================================================
# GET FILE LIST IN CURRENT FOLDER
# ============================================================

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

# ============================================================
# GET ALL ITEMS
# ============================================================

function Get-MtpInventoryRecursive {

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

                        Get-MtpInventoryRecursive `
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

# ============================================================
# PC -> KINDLE
# ============================================================

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

                $Overwrite = Read-Host "    Replace it? (Y/N)"

                if ($Overwrite -notmatch "^[Yy]$") {

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

# ============================================================
# SELECT PC FILES
# ============================================================

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

# ============================================================
# FIND MTP ITEM
# ============================================================

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

# ============================================================
# WAIT FOR MTP ITEM
# ============================================================

function Wait-ForMtpItem {

    param(
        [Parameter(Mandatory)]
        $Folder,

        [Parameter(Mandatory)]
        [string]$Name,

        [int]$TimeoutSeconds = 45
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

        Start-Sleep -Milliseconds $VerificationIntervalMs
    }
}

# ============================================================
# KINDLE -> PC
# ============================================================

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

# ============================================================
# SELECT MTP FILES
# ============================================================

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

# ============================================================
# WAIT FOR PC FILE
# ============================================================

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

# ============================================================
# LIST DOCUMENTS
# ============================================================

function List-KindleFiles {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " FILES ON KINDLE" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Documents = Get-KindleDocuments

    if ($null -eq $Documents) {

        Write-Host ""
        Write-Host "Documents folder not found." -ForegroundColor Red

        return
    }

    $Files = @(Get-MtpFileList -Folder $Documents)

    Write-Host ""
    Write-Host "Device:" -ForegroundColor Gray
    Write-Host "  $(Get-KindleName)" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Path:" -ForegroundColor Gray
    Write-Host "  $(Get-KindlePath)" -ForegroundColor Cyan

    Write-Host ""

    if ($Files.Count -eq 0) {

        Write-Host "No files found." -ForegroundColor Yellow

        return
    }

    Write-Host (
        "{0,4}  {1,-60}  {2,12}" -f `
        "#",
        "FILE",
        "SIZE"
    ) -ForegroundColor Gray

    Write-Host (
        "{0,4}  {1,-60}  {2,12}" -f `
        "---",
        "------------------------------------------------------------",
        "------------"
    ) -ForegroundColor DarkGray

    $Count = 0
    [double]$TotalSize = 0

    foreach ($File in $Files) {

        $Count++

        $SizeText = "Unknown"

        if ($File.Size -gt 0) {

            $SizeText = Format-Size $File.Size

            $TotalSize += $File.Size
        }

        $Name = $File.Name

        if ($Name.Length -gt 60) {
            $Name = $Name.Substring(0, 57) + "..."
        }

        Write-Host (
            "{0,4}  {1,-60}  {2,12}" -f `
            $Count,
            $Name,
            $SizeText
        )
    }

    Write-Host ""
    Write-Host "----------------------------------------"

    Write-Host ""
    Write-Host "Total files: $Count" -ForegroundColor Green

    if ($TotalSize -gt 0) {

        Write-Host `
            "Known file size: $(Format-Size $TotalSize)" `
            -ForegroundColor Yellow
    }
}

# ============================================================
# FULL KINDLE BROWSER
# ============================================================

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

# ============================================================
# BROWSE DOCUMENTS
# ============================================================

function Browse-KindleDocuments {

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Documents = Get-KindleDocuments

    if ($null -eq $Documents) {

        Write-Host ""
        Write-Host "Documents folder unavailable." -ForegroundColor Red

        return
    }

    Invoke-KindleBrowser `
        -Folder $Documents `
        -LogicalPath $(Get-KindlePath)
}

# ============================================================
# KINDLE BROWSER
# ============================================================

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
        Write-Host "  R       Refresh"
        Write-Host "  Q       Exit browser"
        Write-Host ""

        $Choice = Read-Host "Choose"

        if ($Choice -match "^[Qq]$") {
            return
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

# ============================================================
# GET MTP PARENT
# ============================================================

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

# ============================================================
# GET PARENT LOGICAL PATH
# ============================================================

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

# ============================================================
# SELECT MTP ITEM
# ============================================================

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

# ============================================================
# FILE INFORMATION
# ============================================================

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

# ============================================================
# COPY MTP ITEM TO PC
# ============================================================

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

# ============================================================
# DELETE MTP FILE
# ============================================================

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

# ============================================================
# SEARCH KINDLE
# ============================================================

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

# ============================================================
# SEARCH RECURSIVELY
# ============================================================

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

# ============================================================
# BACKUP KINDLE
# ============================================================

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

# ============================================================
# BACKUP MTP FOLDER
# ============================================================

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

# ============================================================
# STORAGE REPORT
# ============================================================

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

    Get-MtpInventoryRecursive `
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

# ============================================================
# DELETE FROM DOCUMENTS
# ============================================================

function Delete-KindleFiles {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " DELETE FILE FROM KINDLE" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Documents = Get-KindleDocuments

    if ($null -eq $Documents) {

        Write-Host ""
        Write-Host "Documents folder not found." -ForegroundColor Red

        return
    }

    $Files = @(Get-MtpFileList -Folder $Documents)

    if ($Files.Count -eq 0) {

        Write-Host ""
        Write-Host "No files found." -ForegroundColor Yellow

        return
    }

    Write-Host ""
    Write-Host "Files:" -ForegroundColor Cyan
    Write-Host ""

    for ($i = 0; $i -lt $Files.Count; $i++) {

        Write-Host (
            "[{0,4}] {1,-60} {2,12}" -f `
            ($i + 1),
            $Files[$i].Name,
            (Format-Size $Files[$i].Size)
        )
    }

    Write-Host ""
    Write-Host "Enter 0 to cancel."
    Write-Host ""

    $Selection = Read-Host "File number"

    if ($Selection -notmatch "^\d+$") {

        Write-Host ""
        Write-Host "Invalid selection." -ForegroundColor Red

        return
    }

    $Number = [int]$Selection

    if ($Number -eq 0) {

        Write-Host ""
        Write-Host "Cancelled." -ForegroundColor Yellow

        return
    }

    if (
        $Number -lt 1 -or
        $Number -gt $Files.Count
    ) {

        Write-Host ""
        Write-Host "Invalid file number." -ForegroundColor Red

        return
    }

    $Selected = $Files[$Number - 1]

    Remove-MtpFile `
        -Folder $Documents `
        -Item $Selected.Item `
        -LogicalPath $(Get-KindlePath)
}

# ============================================================
# KINDLE INFORMATION
# ============================================================

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

# ============================================================
# OPEN KINDLE IN FILE EXPLORER
# ============================================================

function Open-KindleExplorer {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " OPEN KINDLE IN FILE EXPLORER" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if (-not (Wait-ForKindle -TimeoutSeconds 30)) {
        return
    }

    $Kindle = Get-Kindle

    if ($null -eq $Kindle) {

        Write-Host ""
        Write-Host "Kindle not available." -ForegroundColor Red

        return
    }

    try {

        $Kindle.InvokeVerb("open")

        Write-Host ""
        Write-Host "Kindle opened in File Explorer." `
            -ForegroundColor Green
    }
    catch {

        Write-Host ""
        Write-Host "Could not automatically open Kindle." `
            -ForegroundColor Yellow

        Write-Host ""
        Write-Host "Windows path:" -ForegroundColor Gray
        Write-Host "  $(Get-KindleRootPath)" `
            -ForegroundColor Cyan
    }
}

# ============================================================
# OPEN PC BOOKS FOLDER
# ============================================================

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

# ============================================================
# REFRESH / RECONNECT
# ============================================================

function Refresh-Kindle {

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " REFRESH / RECONNECT" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Rechecking Windows MTP devices..." `
        -ForegroundColor Yellow

    $Kindle = Get-Kindle

    if ($null -eq $Kindle) {

        Write-Host ""
        Write-Host "Kindle is currently not detected." `
            -ForegroundColor Red

        Write-Host ""
        Write-Host "Make sure:"
        Write-Host "  - USB cable is connected"
        Write-Host "  - Kindle is unlocked"
        Write-Host "  - Kindle is showing USB / MTP access"

        return
    }

    $Storage = Get-KindleInternalStorage

    if ($null -eq $Storage) {

        Write-Host ""
        Write-Host "Kindle detected, but Internal Storage is unavailable." `
            -ForegroundColor Yellow

        return
    }

    Write-Host ""
    Write-Host "Connection refreshed." -ForegroundColor Green

    Write-Host ""
    Write-Host "Device:"
    Write-Host "  $($Kindle.Name)" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "Internal Storage:"
    Write-Host "  Available" -ForegroundColor Green
}

# ============================================================
# MAIN MENU
# ============================================================

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

    Write-Host "1.  PC -> Kindle"
    Write-Host "2.  Kindle -> PC"
    Write-Host "3.  Browse Kindle"
    Write-Host "4.  Browse Kindle documents"
    Write-Host "5.  Search Kindle"
    Write-Host "6.  File information"
    Write-Host "7.  Backup Kindle"
    Write-Host "8.  Check Kindle storage"
    Write-Host "9.  Delete file from Kindle" -ForegroundColor Magenta
    Write-Host "10. Kindle information"
    Write-Host "11. Open Kindle in File Explorer"
    Write-Host "12. Refresh / Reconnect"
    Write-Host "13. Open PC books folder"
    Write-Host "14. List files in documents"
    Write-Host "15. Exit"

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host ""
}

# ============================================================
# START APPLICATION
# ============================================================

Initialize-LocalFolders

while ($true) {

    Show-MainMenu

    $Choice = Read-Host "Choose an option"

    switch ($Choice) {

        # ----------------------------------------------------
        # PC -> KINDLE
        # ----------------------------------------------------

        "1" {

            Clear-Host

            Copy-PCToKindle

            Pause-Screen
        }

        # ----------------------------------------------------
        # KINDLE -> PC
        # ----------------------------------------------------

        "2" {

            Clear-Host

            Copy-KindleToPC

            Pause-Screen
        }

        # ----------------------------------------------------
        # FULL BROWSER
        # ----------------------------------------------------

        "3" {

            Clear-Host

            Browse-Kindle

            Pause-Screen
        }

        # ----------------------------------------------------
        # DOCUMENTS BROWSER
        # ----------------------------------------------------

        "4" {

            Clear-Host

            Browse-KindleDocuments

            Pause-Screen
        }

        # ----------------------------------------------------
        # SEARCH
        # ----------------------------------------------------

        "5" {

            Search-Kindle

            Pause-Screen
        }

        # ----------------------------------------------------
        # FILE INFORMATION
        # ----------------------------------------------------

        "6" {

            Clear-Host

            if (-not (Wait-ForKindle -TimeoutSeconds 30)) {

                Pause-Screen

                continue
            }

            $Documents = Get-KindleDocuments

            if ($null -eq $Documents) {

                Write-Host ""
                Write-Host "Documents folder not found." `
                    -ForegroundColor Red

                Pause-Screen

                continue
            }

            $Selected = Select-MtpItem `
                -Folder $Documents

            if ($null -ne $Selected) {

                Show-MtpItemInformation `
                    -Folder $Documents `
                    -Item $Selected `
                    -LogicalPath $(Get-KindlePath)
            }
        }

        # ----------------------------------------------------
        # BACKUP
        # ----------------------------------------------------

        "7" {

            Clear-Host

            Backup-Kindle

            Pause-Screen
        }

        # ----------------------------------------------------
        # STORAGE
        # ----------------------------------------------------

        "8" {

            Clear-Host

            Show-KindleStorage

            Pause-Screen
        }

        # ----------------------------------------------------
        # DELETE
        # ----------------------------------------------------

        "9" {

            Clear-Host

            Delete-KindleFiles

            Pause-Screen
        }

        # ----------------------------------------------------
        # INFORMATION
        # ----------------------------------------------------

        "10" {

            Clear-Host

            Show-KindleInfo

            Pause-Screen
        }

        # ----------------------------------------------------
        # FILE EXPLORER
        # ----------------------------------------------------

        "11" {

            Clear-Host

            Open-KindleExplorer

            Pause-Screen
        }

        # ----------------------------------------------------
        # REFRESH
        # ----------------------------------------------------

        "12" {

            Clear-Host

            Refresh-Kindle

            Pause-Screen
        }

        # ----------------------------------------------------
        # OPEN PC BOOKS
        # ----------------------------------------------------

        "13" {

            Clear-Host

            Open-PCBooksFolder

            Pause-Screen
        }

        # ----------------------------------------------------
        # LIST DOCUMENTS
        # ----------------------------------------------------

        "14" {

            Clear-Host

            List-KindleFiles

            Pause-Screen
        }

        # ----------------------------------------------------
        # EXIT
        # ----------------------------------------------------

        "15" {

            Clear-Host

            Write-Host ""
            Write-Host "Kindle MTP File Manager closed." `
                -ForegroundColor Green

            Write-Host ""

            exit
        }

        # ----------------------------------------------------
        # INVALID
        # ----------------------------------------------------

        default {

            Write-Host ""
            Write-Host "Invalid option." -ForegroundColor Red

            Start-Sleep -Seconds 1
        }
    }
}