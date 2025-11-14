# =====================================================================================================
#  Get-Backup.ps1
#  -----------------------------------------------------------------------------
#  Downloads the most recent database backup (.sql.gz) from the VPS,
#  saves it locally, writes a SHA-256 checksum, optionally extracts it, and prunes older local copies.
#
#  REQUIREMENTS:
#    • ssh/scp available (Windows 10/11 built-in OpenSSH is fine)
#    • Optional for -Extract: 7-Zip at "C:\Program Files\7-Zip\7z.exe"
#
#  EXAMPLES (run from PowerShell):
#    PS C:\Work13> .\scripts\Get-Backup.ps1
#       → downloads latest backup to C:\Work13\backups + writes .sha256
#
#    PS C:\Work13> .\scripts\Get-Backup.ps1 -Extract
#       → download, write .sha256, then extract with 7-Zip
#
#    PS C:\Work13> .\scripts\Get-Backup.ps1 -Keep 10
#       → keeps the last 10 local .sql.gz files
#
#    PS C:\Work13> .\scripts\Get-Backup.ps1 -TestGzip
#       → additionally opens the gzip stream to quickly sanity-check integrity
#
#    PS C:\Work13> .\scripts\Get-Backup.ps1 -Server "apna-vps" -RemoteDir "/home/apna/backups/daily"
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

Write-Host "Checking for latest backup on $Server ..."

# Get latest file path on the server
$sshCmd = "ls -1t $RemoteDir/*.sql.gz | head -n 1"
$latest = & ssh -p $Port $Server $sshCmd 2>$null

if (-not $latest) {
    Write-Host "No backup file found in $RemoteDir"
    exit 1
}

$latest   = $latest.Trim()
$filename = Split-Path $latest -Leaf

Write-Host "Downloading $filename ..."

# Ensure local folder exists
if (!(Test-Path -LiteralPath $LocalDir)) {
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
}

# Download
& scp -P $Port -p -q "$($Server):$latest" "$LocalDir\"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Download failed."
    exit 2
}

$localPath = Join-Path $LocalDir $filename
Write-Host "Download complete -> $localPath"

# Write SHA-256 checksum next to the file
try {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $localPath).Hash
    $hashFile = "$localPath.sha256"
    $hash | Out-File -LiteralPath $hashFile -Encoding ascii -NoNewline
    Write-Host "SHA256: $hash"
    Write-Host "Wrote checksum -> $hashFile"
} catch {
    Write-Host "WARNING: Failed to compute/write SHA256: $($_.Exception.Message)"
}

# Optional gzip integrity check (quick probe)
if ($TestGzip) {
    try {
        $fs = [System.IO.File]::OpenRead($localPath)
        try {
            $gz  = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
            $buf = New-Object byte[] 2048
            [void]$gz.Read($buf, 0, $buf.Length)
            Write-Host "Gzip quick-check: OK (stream opened & read)."
        } finally {
            if ($gz) { $gz.Dispose() }
            if ($fs) { $fs.Dispose() }
        }
    } catch {
        Write-Host "Gzip quick-check: FAILED → $($_.Exception.Message)"
    }
}

# Optional: extract with 7-Zip if requested
if ($Extract) {
    $sevenZip = "C:\Program Files\7-Zip\7z.exe"
    if (Test-Path $sevenZip) {
        Write-Host "Extracting with 7-Zip..."
        & $sevenZip e $localPath -aoa | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $sqlName = ($filename -replace '\.gz$', '')
            Write-Host "Extracted -> $(Join-Path $LocalDir $sqlName)"
        } else {
            Write-Host "Extraction failed (7-Zip exit $LASTEXITCODE)"
        }
    } else {
        Write-Host "7-Zip not found at '$sevenZip'. Skipping extraction."
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
                Write-Host "Removed old backup: $($f.Name)"
                # Also remove any sidecar .sha256
                $sidecar = "$($f.FullName).sha256"
                if (Test-Path -LiteralPath $sidecar) {
                    Remove-Item -LiteralPath $sidecar -Force
                }
            } catch {
                Write-Host "Failed to delete $($f.Name): $($_.Exception.Message)"
            }
        }
    }
}
