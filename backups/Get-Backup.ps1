# =====================================================================================================
#  Get-Backup.ps1
#  -----------------------------------------------------------------------------
#  Downloads the most recent database backup (.sql.gz) from the VPS,
#  stores it locally, writes a SHA-256 checksum, optionally extracts it using
#  7-Zip, optionally performs a gzip integrity check, and prunes older local
#  copies beyond a specified retention count.
#
#  USAGE EXAMPLES:
#
#    # Basic download of latest backup
#    PS> .\Get-Backup.ps1
#
#    # Download + extract into the same folder
#    PS> .\Get-Backup.ps1 -Extract
#
#    # Download + test gzip integrity
#    PS> .\Get-Backup.ps1 -TestGzip
#
#    # Keep last 10 local backups, delete older ones
#    PS> .\Get-Backup.ps1 -Keep 10
#
#    # Download from a different server
#    PS> .\Get-Backup.ps1 -Server "backup-prod" -Port 2222
#
#    # Use custom local and remote paths
#    PS> .\Get-Backup.ps1 -RemoteDir "/home/apna/backups/daily" `
#                          -LocalDir "D:\DB_Backups"
#
#    # Combine features:
#    PS> .\Get-Backup.ps1 -Extract -TestGzip -Keep 14
#
#  REQUIREMENTS:
#     - SSH/SCP installed (Windows OpenSSH is fine)
#     - For extraction: optional 7-Zip installed at:
#           C:\Program Files\7-Zip\7z.exe
# =====================================================================================================

param(
    [string]$Server    = "apna-vps",
    [string]$RemoteDir = "/home/apna/backups/daily",
    [string]$LocalDir  = "C:\Work13\scripts\backups\output",
    [int]$Port         = 22,
    [int]$Keep         = 5,          # keep last N local .sql.gz files; set 0 to disable
    [switch]$Extract,                # auto-extract with 7-Zip if available
    [switch]$TestGzip                # quick gzip integrity probe after download
)

$ErrorActionPreference = "Stop"

Write-Host "Checking for latest backup on $Server ..." -ForegroundColor Cyan

# Get latest file path on the server
$sshCmd = "ls -1t $RemoteDir/*.sql.gz | head -n 1"
$latest = & ssh -p $Port $Server $sshCmd 2>$null

if (-not $latest) {
    Write-Host "No backup file found in $RemoteDir" -ForegroundColor Yellow
    exit 1
}

$latest   = $latest.Trim()
$filename = Split-Path $latest -Leaf

Write-Host "Downloading $filename ..." -ForegroundColor Cyan

# Ensure local folder exists
if (!(Test-Path -LiteralPath $LocalDir)) {
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
}

# Download (build remote arg safely)
$remoteArg = "{0}:{1}" -f $Server, $latest
& scp -P $Port -p -q $remoteArg $LocalDir
if ($LASTEXITCODE -ne 0) {
    Write-Host "Download failed." -ForegroundColor Red
    exit 2
}

$localPath = Join-Path $LocalDir $filename
Write-Host "Download complete -> $localPath" -ForegroundColor Green

# Write SHA-256 checksum next to the file
try {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash
    $hashFile = "$localPath.sha256"
    $hash | Out-File -LiteralPath $hashFile -Encoding ascii -NoNewline
    Write-Host "SHA256: $hash" -ForegroundColor DarkCyan
    Write-Host "Wrote checksum -> $hashFile" -ForegroundColor Green
} catch {
    Write-Host "WARNING: Failed to compute/write SHA256: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Optional gzip integrity check (quick probe)
if ($TestGzip) {
    try {
        $fs = [System.IO.File]::OpenRead($localPath)
        try {
            $gz  = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
            $buf = New-Object byte[] 2048
            [void]$gz.Read($buf, 0, $buf.Length)
            Write-Host "Gzip quick-check: OK (stream opened & read)." -ForegroundColor Green
        } finally {
            if ($gz) { $gz.Dispose() }
            if ($fs) { $fs.Dispose() }
        }
    } catch {
        Write-Host "Gzip quick-check: FAILED → $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Optional: extract with 7-Zip if requested
if ($Extract) {
    $sevenZip = "C:\Program Files\7-Zip\7z.exe"
    if (Test-Path $sevenZip) {
        Write-Host "Extracting with 7-Zip..." -ForegroundColor Cyan
        # extract into LocalDir explicitly
        & $sevenZip e $localPath "-o$LocalDir" -aoa | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $sqlName = ($filename -replace '\.gz$', '')
            Write-Host "Extracted -> $(Join-Path $LocalDir $sqlName)" -ForegroundColor Green
        } else {
            Write-Host "Extraction failed (7-Zip exit $LASTEXITCODE)" -ForegroundColor Red
        }
    } else {
        Write-Host "7-Zip not found at '$sevenZip'. Skipping extraction." -ForegroundColor Yellow
    }
}

# Optional: prune old local .sql.gz files
if ($Keep -gt 0) {
    $pattern = "apnagold_*.sql.gz"
    $files = Get-ChildItem -Path $LocalDir -Filter $pattern -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    if ($files.Count -gt $Keep) {
        $toDelete = $files | Select-Object -Skip $Keep
        foreach ($f in $toDelete) {
            try {
                Remove-Item -LiteralPath $f.FullName -Force
                Write-Host "Removed old backup: $($f.Name)" -ForegroundColor DarkYellow
                # Also remove any sidecar .sha256
                $sidecar = "$($f.FullName).sha256"
                if (Test-Path -LiteralPath $sidecar) {
                    Remove-Item -LiteralPath $sidecar -Force
                }
            } catch {
                Write-Host "Failed to delete $($f.Name): $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}
