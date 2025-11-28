# =====================================================================================================
#  verify-backup.ps1
#  ---------------------------------------------------------------------------------------------
#  Verifies database backups by:
#      • Computing SHA-256 and comparing to the stored .sha256
#      • Creating .sha256 files if missing
#      • Optional gzip integrity probe (-TestGzip)
#
#  By default: verifies ONLY the newest matching backup.
#  Use -All to verify EVERY matching backup.
#
#  USAGE EXAMPLES:
#
#    # Verify latest backup (default path)
#    PS> .\backups\verify-backup.ps1
#
#    # Verify from a different folder
#    PS> .\backups\verify-backup.ps1 -LocalDir "D:\DB_Backups"
#
#    # Verify using a different filename pattern
#    PS> .\backups\verify-backup.ps1 -Pattern "mydb_*.sql.gz"
#
#    # Verify + gzip integrity test
#    PS> .\backups\verify-backup.ps1 -TestGzip
#
#    # Verify all backups in the directory
#    PS> .\backups\verify-backup.ps1 -All
#
#    # Verify all + gzip test
#    PS> .\backups\verify-backup.ps1 -All -TestGzip
#
#    # Example overall return codes (considering all processed files):
#         0  = OK (all hashes matched; no gzip failures)
#         3  = One or more .sha256 files were missing and were created;
#              no mismatches / gzip errors
#         4  = One or more hash mismatches
#         5  = No mismatches, but one or more gzip checks failed
#         6  = No matching backup file found
#
#  This script is ideal for:
#    • daily verification tasks
#    • CI pipelines
#    • backup-monitoring alerts
#    • local validation after download
# =====================================================================================================

[CmdletBinding()]
param(
    [string]$LocalDir = "C:\Work13\scripts\backups\output",
    [string]$Pattern  = "apnagold_*.sql.gz",
    [switch]$TestGzip,   # optional: quickly test gzip integrity
    [switch]$All         # if set, verify all matching backups instead of only the latest
)

$ErrorActionPreference = "Stop"

# 1) Locate backup files
$files = Get-ChildItem -Path $LocalDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No backup files found in $LocalDir matching '$Pattern'." -ForegroundColor Yellow
    exit 6  # no file
}

if (-not $All) {
    # Only verify the latest one
    $files = $files | Select-Object -First 1
}

Write-Host "Found $($files.Count) backup file(s) to verify." -ForegroundColor Cyan

# Track overall status across all files
$overallHadCreatedHash = $false
$overallHadMismatch    = $false
$overallHadGzipFail    = $false

foreach ($file in $files) {
    $path     = $file.FullName
    $hashFile = "$path.sha256"

    Write-Host ""
    Write-Host "=== Verifying: $path ===" -ForegroundColor Cyan

    # 2) Compute SHA-256
    $computed = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
    Write-Host "Computed SHA256: $computed" -ForegroundColor DarkCyan

    $statusForThisFile = 0

    # 3) Compare vs stored hash (or create if missing)
    if (Test-Path -LiteralPath $hashFile) {
        # Pull first 64-hex string in the file (robust if the file contains extra text)
        $stored = (Get-Content -LiteralPath $hashFile -Raw) `
            -replace '(?s).*?([A-Fa-f0-9]{64}).*', '$1'

        if ($stored -and ($stored.ToUpperInvariant() -eq $computed.ToUpperInvariant())) {
            Write-Host "OK: hash matches ($hashFile)." -ForegroundColor Green
            $statusForThisFile = 0
        } else {
            Write-Host "ERROR: hash mismatch." -ForegroundColor Red
            Write-Host "Stored : $stored"
            Write-Host "Computed: $computed"
            $statusForThisFile = 4   # mismatch
            $overallHadMismatch = $true
        }
    } else {
        # Create a simple .sha256 with just the hex to keep it portable
        $computed | Out-File -LiteralPath $hashFile -Encoding ascii -NoNewline
        Write-Host "NOTE: no .sha256 found. Wrote new file: $hashFile" -ForegroundColor Yellow
        $statusForThisFile = 3       # missing hash (created)
        $overallHadCreatedHash = $true
    }

    # 4) Optional: quick gzip integrity probe (reads a small chunk)
    if ($TestGzip) {
        try {
            $fs = [System.IO.File]::OpenRead($path)
            try {
                $gz  = New-Object System.IO.Compression.GZipStream(
                    $fs,
                    [System.IO.Compression.CompressionMode]::Decompress
                )
                $buf = New-Object byte[] 2048
                [void]$gz.Read($buf, 0, $buf.Length)  # attempt to read a bit
                Write-Host "OK: gzip stream opened and read successfully." -ForegroundColor Green
            } finally {
                if ($gz) { $gz.Dispose() }
                if ($fs) { $fs.Dispose() }
            }
        } catch {
            Write-Host "ERROR: gzip integrity check failed: $($_.Exception.Message)" -ForegroundColor Red
            $overallHadGzipFail = $true
            # If this file was otherwise OK or just created hash, conceptually it's now "5"
            if ($statusForThisFile -eq 0 -or $statusForThisFile -eq 3) {
                $statusForThisFile = 5
            }
        }
    }
}

# Derive overall exit status
# Priority: mismatch (4) > gzip fail (5) > created hash (3) > OK (0)
$finalStatus = 0

if ($overallHadMismatch) {
    $finalStatus = 4
} elseif ($overallHadGzipFail) {
    $finalStatus = 5
} elseif ($overallHadCreatedHash) {
    $finalStatus = 3
} else {
    $finalStatus = 0
}

Write-Host ""
Write-Host "Overall verification status: $finalStatus" -ForegroundColor Cyan
switch ($finalStatus) {
    0 { Write-Host "All backups OK." -ForegroundColor Green }
    3 { Write-Host "OK, but some .sha256 were missing and were created." -ForegroundColor Yellow }
    4 { Write-Host "ERROR: One or more hash mismatches!" -ForegroundColor Red }
    5 { Write-Host "WARNING: Gzip integrity failed for one or more backups." -ForegroundColor Red }
    6 { Write-Host "No backup files found." -ForegroundColor Yellow }
}
exit $finalStatus
