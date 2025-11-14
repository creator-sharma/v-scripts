# =====================================================================================================
#  Verify-Backup.ps1
#  -----------------------------------------------------------------------------
#  Verifies the latest local ApnaGold backup by:
#    • computing SHA-256 and comparing with the sidecar .sha256 (or creating it if missing)
#    • optional quick gzip integrity probe (-TestGzip)
#
#  EXAMPLES:
#    PS C:\Work13> .\scripts\Verify-Backup.ps1
#       → verifies latest backup in C:\Work13\backups
#
#    PS C:\Work13> .\scripts\Verify-Backup.ps1 -LocalDir "D:\SafeCopies"
#       → verifies from another folder
#
#    PS C:\Work13> .\scripts\Verify-Backup.ps1 -TestGzip
#       → also opens the gzip stream and reads a small chunk
#
#    Exit codes:
#       0 = OK (hash matched)
#       3 = No .sha256 existed; script created it
#       4 = Hash mismatch
#       5 = Gzip probe failed
#       6 = No matching backup file found
# =====================================================================================================

param(
    [string]$LocalDir = "C:\Work13\backups",
    [string]$Pattern  = "apnagold_*.sql.gz",
    [switch]$TestGzip   # optional: quickly test gzip integrity
)

$ErrorActionPreference = "Stop"

# 1) Locate latest backup
$latest = Get-ChildItem -Path $LocalDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending |
          Select-Object -First 1

if (-not $latest) {
    Write-Host "No backup files found in $LocalDir matching '$Pattern'."
    exit 6  # no file
}

$path     = $latest.FullName
$hashFile = "$path.sha256"

Write-Host "Latest backup: $path"

# 2) Compute SHA-256
$computed = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
Write-Host "Computed SHA256: $computed"

# 3) Compare vs stored hash (or create if missing)
if (Test-Path -LiteralPath $hashFile) {
    # Pull first 64-hex string in the file (robust if the file contains extra text)
    $stored = (Get-Content -LiteralPath $hashFile -Raw) `
        -replace '(?s).*?([A-Fa-f0-9]{64}).*', '$1'

    if ($stored -and ($stored.ToUpperInvariant() -eq $computed.ToUpperInvariant())) {
        Write-Host "OK: hash matches ($hashFile)."
        $status = 0
    } else {
        Write-Host "ERROR: hash mismatch."
        Write-Host "Stored : $stored"
        Write-Host "Computed: $computed"
        $status = 4   # mismatch
    }
} else {
    # Create a simple .sha256 with just the hex to keep it portable
    $computed | Out-File -LiteralPath $hashFile -Encoding ascii -NoNewline
    Write-Host "NOTE: no .sha256 found. Wrote new file: $hashFile"
    $status = 3       # missing hash (created)
}

# 4) Optional: quick gzip integrity probe (reads a small chunk)
if ($TestGzip) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $gz  = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
            $buf = New-Object byte[] 2048
            [void]$gz.Read($buf, 0, $buf.Length)  # attempt to read a bit
            Write-Host "OK: gzip stream opened and read successfully."
        } finally {
            if ($gz) { $gz.Dispose() }
            if ($fs) { $fs.Dispose() }
        }
    } catch {
        Write-Host "ERROR: gzip integrity check failed: $($_.Exception.Message)"
        if ($status -eq 0 -or $status -eq 3) { $status = 5 }
    }
}

exit $status
