<# ====================================================================================================
  Get-Logs.ps1
  --------------------------------------------------------------------------------
  Fetches and/or tails the latest production logs from the VPS.

  Default behavior (no switches):
    - Tails the last 200 lines of key logs over SSH and shows them in the console.

  Examples (from C:\Work13):
    PS C:\Work13> .\scripts\Get-Logs.ps1
       → show last 200 lines from nginx/app/backup + journalctl for gunicorn/nginx

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Tail 500
       → tail 500 lines instead of 200

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Follow
       → live follow (interactive) nginx.error.log + gunicorn/nginx journal

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Download
       → downloads current + rotated logs to C:\Work13\logs\<timestamp>\

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Download -IncludeRotated -Zip
       → also grabs *.log.1 and *.log.*.gz, then zips the folder

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Kinds Nginx,App
       → only nginx + app logs (skip backup/journal)

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Download -Files nginx.error.log,payment_system.log
       → download only those two files from /srv/apnagold/logs

    PS C:\Work13> .\scripts\Get-Logs.ps1 -Download -RemoteGlobs "nginx.*.log.*.gz","errors.log.1*"
       → download by server-side glob expansion

    PS C:\Work13> .\scripts\Get-Logs.ps1 -OutFile "C:\Work13\logs\run.txt"
       → save all console output to a local text file (transcript)

  Exit codes:
    0 = OK
    1 = SSH command failed
    2 = Download failed
    3 = Zip failed
==================================================================================================== #>

[CmdletBinding()]
param(
  [string]$Server        = "apna-vps",
  [int]$Port             = 22,

  # Remote locations (from your runbook)
  [string]$RemoteLogDir  = "/srv/apnagold/logs",

  # Local destination for downloads
  [string]$LocalDir      = "C:\Work13\logs",

  # What to show/download
  [ValidateSet("All","Nginx","App","Backup","Journal")]
  [string[]]$Kinds       = @("All"),

  # Tail / follow
  [int]$Tail             = 200,
  [switch]$Follow,              # interactive follow (ssh streams until you Ctrl+C)
  [string]$Since,               # for journalctl, e.g. "today", "1 hour ago", "2025-11-12 10:00"

  # Download options
  [switch]$Download,
  [switch]$IncludeRotated,       # include *.log.1 and *.log.*.gz
  [switch]$Zip,                  # zip the downloaded folder

  # Precise selections + capture output
  [string[]]$Files,              # e.g. "nginx.error.log","payment_system.log" or "/var/log/syslog"
  [string[]]$RemoteGlobs,        # e.g. "nginx.*.log.*.gz","errors.log.1*"
  [string]$OutFile               # e.g. "C:\Work13\logs\run.txt"
)

$ErrorActionPreference = "Stop"

# Start transcript if requested
if ($OutFile) {
  $outDir = Split-Path -Path $OutFile -Parent
  if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  }
  Start-Transcript -Path $OutFile -Force | Out-Null
}

function Write-Section($title) {
  Write-Host ""
  Write-Host "===== $title =====" -ForegroundColor Cyan
}

function Invoke-SSH([string]$cmd) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "ssh"
  $psi.Arguments = "-p $Port $Server $cmd"
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { throw "ssh failed (exit $($p.ExitCode)): $stderr" }
  return $stdout
}

function Run-Interactive([string]$cmd, [string]$title) {
  Write-Section $title
  & ssh -p $Port $Server $cmd
  if ($LASTEXITCODE -ne 0) { throw "ssh interactive failed (exit $LASTEXITCODE)" }
}

# Interactive with sudo password sent via STDIN (not visible on cmdline)
function Run-InteractiveSudo {
  param(
    [string]$remoteCmd,   # journalctl ... (without sudo)
    [string]$title
  )
  Write-Section $title
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "ssh"
  $psi.Arguments = "-p $Port $Server `"sudo -S -p '' $remoteCmd`""
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError  = $false
  $psi.UseShellExecute = $false

  # 1) Try without password first (-n)
  & ssh -p $Port $Server "sudo -n $remoteCmd"
  if ($LASTEXITCODE -eq 0) { return }

  # 2) Need password
  $pw = Read-Host "Sudo password required. Enter password or press Enter to skip" -AsSecureString
  $pwPlain = if ($pw.Length -gt 0) { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)) } else { "" }
  if (-not $pwPlain) {
    Write-Host "(skipped $title)" -ForegroundColor DarkYellow
    return
  }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $sw = $p.StandardInput
  $sw.WriteLine($pwPlain)
  $sw.Flush()
  $p.WaitForExit()
  if ($p.ExitCode -ne 0) { throw "ssh interactive sudo failed (exit $($p.ExitCode))" }
}

# Helper: for non-follow journalctl blocks (try no-password sudo, else prompt once)
function Show-JournalBlock {
  param(
    [string]$unit,
    [int]$tailLines,
    [string]$sinceArg
  )
  Write-Section "journalctl: $unit (last $tailLines)"
  try {
    Invoke-SSH "sudo -n journalctl -u $unit -n $tailLines --no-pager $sinceArg" | Write-Host
  } catch {
    $pw = Read-Host "Sudo password required to read $unit logs. Enter password or press Enter to skip" -AsSecureString
    $pwPlain = if ($pw.Length -gt 0) { [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)) } else { "" }
    if ($pwPlain) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName  = "ssh"
      $psi.Arguments = "-p $Port $Server `"sudo -S -p '' journalctl -u $unit -n $tailLines --no-pager $sinceArg`""
      $psi.RedirectStandardInput  = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError  = $true
      $psi.UseShellExecute        = $false
      $p = New-Object System.Diagnostics.Process
      $p.StartInfo = $psi
      [void]$p.Start()
      $p.StandardInput.WriteLine($pwPlain)
      $p.StandardInput.Flush()
      $out = $p.StandardOutput.ReadToEnd()
      $err = $p.StandardError.ReadToEnd()
      $p.WaitForExit()
      if ($p.ExitCode -ne 0) {
        Write-Host "(failed to read $($unit): $err)" -ForegroundColor Yellow
      } else {
        $out | Write-Host
      }
    } else {
      Write-Host "(skipped $unit logs)" -ForegroundColor DarkYellow
    }
  }
}

# Helper: build Linux-style paths safely (no backslashes)
function Join-UnixPath {
  param([string]$a,[string]$b)
  return ($a.TrimEnd('/') + '/' + $b.TrimStart('/'))
}

# Resolve Kinds
$wantAll     = ($Kinds -contains "All")
$wantNginx   = $wantAll -or ($Kinds -contains "Nginx")
$wantApp     = $wantAll -or ($Kinds -contains "App")
$wantBackup  = $wantAll -or ($Kinds -contains "Backup")
$wantJournal = $wantAll -or ($Kinds -contains "Journal")

# Canonical log file list from your runbook
$nginxLogs = @("nginx.error.log","nginx.access.log")
$appLogs   = @("errors.log","payment_system.log","sql.log")
$backupLog = @("backup.log")

# Compose remote file list (priority: Files/Globs -> Kinds)
$remoteFiles = @()

# Explicit files (relative to RemoteLogDir unless absolute) - PS 5.1 safe
if ($Files) {
  foreach ($f in $Files) {
    if ([string]::IsNullOrWhiteSpace($f)) { continue }
    if ($f.StartsWith("/")) {
      $remoteFiles += $f
    } else {
      $remoteFiles += (Join-UnixPath $RemoteLogDir $f)
    }
  }
}

# Remote globs (expanded on server via ls) - PS 5.1 safe
if ($RemoteGlobs) {
  foreach ($g in $RemoteGlobs) {
    if ([string]::IsNullOrWhiteSpace($g)) { continue }
    $glob = ""
    if ($g.StartsWith("/")) {
      $glob = $g
    } else {
      $glob = (Join-UnixPath $RemoteLogDir $g)
    }
    try {
      $list = Invoke-SSH "ls -1 $glob 2>/dev/null || true"
      $remoteFiles += ($list -split "`n" | Where-Object { $_.Trim() }) | ForEach-Object { $_.Trim() }
    } catch { }
  }
}

# Fallback to Kinds if nothing specified
if (-not $remoteFiles) {
  if ($wantNginx) { $remoteFiles += $nginxLogs | ForEach-Object { Join-UnixPath $RemoteLogDir $_ } }
  if ($wantApp)   { $remoteFiles += $appLogs   | ForEach-Object { Join-UnixPath $RemoteLogDir $_ } }
  if ($wantBackup){ $remoteFiles += $backupLog | ForEach-Object { Join-UnixPath $RemoteLogDir $_ } }
}

# 1) View/tail
try {
  if (-not $Download) {
    $sinceArg = if ($Since) { "--since `"$Since`"" } else { "" }

    if ($Follow) {
      if ($wantNginx) {
        $errPath = Join-UnixPath $RemoteLogDir "nginx.error.log"
        Run-Interactive "tail -n $Tail -F $errPath" "LIVE: nginx.error.log (Ctrl+C to stop)"
      }
      if ($wantJournal) {
        Run-InteractiveSudo -remoteCmd "journalctl -u gunicorn_apnagold -f --no-pager $sinceArg" `
                            -title "LIVE: journalctl gunicorn_apnagold (Ctrl+C to stop)"
        Run-InteractiveSudo -remoteCmd "journalctl -u nginx -f --no-pager $sinceArg" `
                            -title "LIVE: journalctl nginx (Ctrl+C to stop)"
      }
    } else {
      if ($wantNginx) {
        $errPath = Join-UnixPath $RemoteLogDir "nginx.error.log"
        $accPath = Join-UnixPath $RemoteLogDir "nginx.access.log"
        Write-Section "nginx.error.log (last $Tail)"
        Invoke-SSH "tail -n $Tail $errPath" | Write-Host
        Write-Section "nginx.access.log (last $Tail)"
        Invoke-SSH "tail -n $Tail $accPath" | Write-Host
      }
      if ($wantApp) {
        foreach ($f in $appLogs) {
          $p = Join-UnixPath $RemoteLogDir $f
          Write-Section "$f (last $Tail)"
          try { Invoke-SSH "tail -n $Tail $p" | Write-Host }
          catch { Write-Host "(skipped: $f not found)" -ForegroundColor DarkYellow }
        }
      }
      if ($wantBackup) {
        $bp = Join-UnixPath $RemoteLogDir "backup.log"
        Write-Section "backup.log (last $Tail)"
        try { Invoke-SSH "tail -n $Tail $bp" | Write-Host }
        catch { Write-Host "(skipped: backup.log not found)" -ForegroundColor DarkYellow }
      }
      if ($wantJournal) {
        Show-JournalBlock -unit "gunicorn_apnagold" -tailLines $Tail -sinceArg $sinceArg
        Show-JournalBlock -unit "nginx"             -tailLines $Tail -sinceArg $sinceArg
      }
    }
  }
} catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  if ($OutFile) { Stop-Transcript | Out-Null }
  exit 1
}

# 2) Download block
if ($Download) {
  try {
    if (!(Test-Path -LiteralPath $LocalDir)) {
      New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    }
    $stamp = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
    $dest  = Join-Path $LocalDir $stamp
    New-Item -ItemType Directory -Force -Path $dest | Out-Null

    Write-Section "Downloading logs -> $dest"

    function Copy-RemoteFile([string]$remotePath) {
      & scp -P $Port -p -q "${Server}:`"$remotePath`"" "$dest\"
      if ($LASTEXITCODE -ne 0) {
        Write-Host "(missing or not accessible) $remotePath" -ForegroundColor DarkYellow
      } else {
        Write-Host "OK: $(Split-Path $remotePath -Leaf)"
      }
    }

    foreach ($rf in $remoteFiles | Select-Object -Unique) {
      Copy-RemoteFile $rf
    }

    if ($IncludeRotated) {
      $rotPatterns = @(
        (Join-UnixPath $RemoteLogDir "*.log.1"),
        (Join-UnixPath $RemoteLogDir "*.log.1.gz"),
        (Join-UnixPath $RemoteLogDir "*.log.*.gz")
      )

      if (-not $wantAll) {
        $rotPatterns = @()
        if ($wantNginx) {
          $rotPatterns += @(
            (Join-UnixPath $RemoteLogDir "nginx.*.log.1"),
            (Join-UnixPath $RemoteLogDir "nginx.*.log.1.gz"),
            (Join-UnixPath $RemoteLogDir "nginx.*.log.*.gz"),
            (Join-UnixPath $RemoteLogDir "nginx.error.log.1"),
            (Join-UnixPath $RemoteLogDir "nginx.error.log.1.gz"),
            (Join-UnixPath $RemoteLogDir "nginx.access.log.1"),
            (Join-UnixPath $RemoteLogDir "nginx.access.log.1.gz")
          )
        }
        if ($wantApp) {
          foreach ($n in @("errors.log","payment_system.log","sql.log")) {
            $rotPatterns += @(
              (Join-UnixPath $RemoteLogDir "$n.1"),
              (Join-UnixPath $RemoteLogDir "$n.1.gz"),
              (Join-UnixPath $RemoteLogDir "$n.*.gz")
            )
          }
        }
        if ($wantBackup) {
          $rotPatterns += @(
            (Join-UnixPath $RemoteLogDir "backup.log.1"),
            (Join-UnixPath $RemoteLogDir "backup.log.1.gz"),
            (Join-UnixPath $RemoteLogDir "backup.log.*.gz")
          )
        }
      }

      foreach ($pat in $rotPatterns | Select-Object -Unique) {
        try {
          $list = Invoke-SSH "ls -1 $pat 2>/dev/null || true"
          ($list -split "`n" | Where-Object { $_.Trim() }) | ForEach-Object {
            Copy-RemoteFile $_.Trim()
          }
        } catch { }
      }
    }

    # Manifest of what we attempted / collected
    try {
      Set-Content -Path (Join-Path $dest "_manifest.txt") -Value ($remoteFiles | Sort-Object -Unique)
    } catch { }

    if ($Zip) {
      Write-Section "Creating zip archive"
      $zipPath = Join-Path $LocalDir ("logs_" + $stamp + ".zip")
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      try {
        [System.IO.Compression.ZipFile]::CreateFromDirectory($dest, $zipPath)
        Write-Host "ZIP -> $zipPath"
      } catch {
        Write-Host "WARNING: Failed to zip: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($OutFile) { Stop-Transcript | Out-Null }
        exit 3
      }
    }

  } catch {
    Write-Host "ERROR during download: $($_.Exception.Message)" -ForegroundColor Red
    if ($OutFile) { Stop-Transcript | Out-Null }
    exit 2
  }
}

if ($OutFile) { Stop-Transcript | Out-Null }
exit 0
