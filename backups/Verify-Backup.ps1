# =====================================================================================================
#  Verify-Backup.ps1
#  -----------------------------------------------------------------------------
#  Verifies the latest local ApnaGold backup by:
#      • computing SHA-256 and comparing to the stored .sha256 file
#      • or generating a new .sha256 if missing
#      • optional gzip integrity probe (-TestGzip)
#
#  USAGE EXAMPLES:
#
#    # Basic verification in default backup directory
#    PS> .\Verify-Backup.ps1
#
#    # Specify a different local backup directory
#    PS> .\Verify-Backup.ps1 -LocalDir "D:\DB_Backups"
#
#    # Verify using a different filename pattern
#    PS> .\Verify-Backup.ps1 -Pattern "mydb_*.sql.gz"
#
#    # Verify + test gzip integrity
#    PS> .\Verify-Backup.ps1 -TestGzip
#
#    # Example return codes:
#         0  = OK (hash matched)
#         3  = Hash file missing → created
#         4  = Hash mismatch
#         5  = Gzip test failed
#         6  = No matching backup found
#
#  This script is ideal for **daily verification tasks**, CI pipelines,
#  backup-monitoring alerts, or local validation after download.
# =====================================================================================================

param(
    [string]$LocalDir = "C:\Work13\scripts\backups\output",
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
            $gz  = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
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
