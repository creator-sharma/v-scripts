# =====================================================================================================
#  Get-Logs.ps1
#  -----------------------------------------------------------------------------
#  Fetches or streams logs from the VPS:
#
#    • View recent logs via SSH (nginx, app, backup, journalctl)
#    • Follow logs live (-Follow)
#    • Filter which categories to show (-Kinds)
#    • Download raw log files via SCP (-Download)
#    • Include rotated logs (-IncludeRotated)
#    • ZIP downloaded logs (-Zip)
#    • Output everything to a transcript file (-OutFile)
#
#  SUPPORTED LOG GROUPS:
#        Nginx     → nginx.error.log, nginx.access.log
#        App       → errors.log, payment_system.log, sql.log
#        Backup    → backup.log
#        Journal   → systemd units: gunicorn_apnagold, nginx
#        All       → everything above
#
#  USAGE EXAMPLES:
#
#    # Show the last 200 lines of all logs
#    PS> .\Get-Logs.ps1
#
#    # Show only nginx logs
#    PS> .\Get-Logs.ps1 -Kinds Nginx
#
#    # Show only app logs, last 50 lines
#    PS> .\Get-Logs.ps1 -Kinds App -Tail 50
#
#    # Follow nginx error log live
#    PS> .\Get-Logs.ps1 -Kinds Nginx -Follow
#
#    # View logs since a specific timestamp
#    PS> .\Get-Logs.ps1 -Since "2025-11-13 10:00"
#
#    # Download current nginx+app logs to local folder
#    PS> .\Get-Logs.ps1 -Download -Kinds Nginx,App
#
#    # Download all logs + rotated logs + zip
#    PS> .\Get-Logs.ps1 -Download -IncludeRotated -Zip
#
#    # Download specific named files
#    PS> .\Get-Logs.ps1 -Files "sql.log","nginx.error.log" -Download
#
#    # Download using remote server-side wildcard
#    PS> .\Get-Logs.ps1 -RemoteGlobs "nginx*.gz" -Download
#
#    # Save all output (including live/SSH text) to a transcript
#    PS> .\Get-Logs.ps1 -OutFile "C:\Work13\logs\session.txt"
#
#  NOTES:
#    • Requires ssh/scp (Windows built-in OpenSSH works fine).
#    • sudo journalctl will prompt once per run (cached thereafter).
#    • Local and remote directories are fully configurable.
# =====================================================================================================


[CmdletBinding()]
param(
  [string]$Server        = "apna-vps",
  [int]$Port             = 22,

  # Remote
  [string]$RemoteLogDir  = "/srv/apnagold/logs",

  # Local
  [string]$LocalDir      = "C:\Work13\scripts\logs",

  # Scope
  [ValidateSet("All","Nginx","App","Backup","Journal")]
  [string[]]$Kinds       = @("All"),

  # Tail / Follow
  [int]$Tail             = 200,
  [switch]$Follow,
  [string]$Since,

  # Download
  [switch]$Download,
  [switch]$IncludeRotated,
  [switch]$Zip,

  # Explicit
  [string[]]$Files,
  [string[]]$RemoteGlobs,
  [string]$OutFile
)

$ErrorActionPreference = "Stop"

# Global sudo state (prompt once per run)
$script:SudoPasswordPlain = $null
$script:SudoPasswordAsked = $false

# =============================================================
# Utility: Ensure directory exists
# =============================================================
function Ensure-Dir([string]$path) {
  if ($path -and -not (Test-Path -LiteralPath $path)) {
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }
}

# =============================================================
# Transcript
# =============================================================
if ($OutFile) {
  Ensure-Dir (Split-Path -Parent $OutFile)
  Start-Transcript -Path $OutFile -Force | Out-Null
}

# =============================================================
# Section printing
# =============================================================
function Section([string]$title) {
  Write-Host ""
  Write-Host "===== $title =====" -ForegroundColor Cyan
}

# =============================================================
# Build SSH command safely
# =============================================================
function Invoke-SSH([string]$cmd) {
  # Escape double-quotes for bash
  $escaped = $cmd.Replace('"', '\"')

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "ssh"
  $psi.Arguments = "-p $Port $Server `"$escaped`""
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false

  $p = [System.Diagnostics.Process]::Start($psi)
  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    throw "SSH failed ($($p.ExitCode)): $stderr"
  }

  return $stdout.TrimEnd()
}

# =============================================================
# SUDO wrapper — unified for journalctl or other commands
#   - prompts once per run
#   - reuses password for all sudo calls
# =============================================================
function Invoke-Sudo([string]$cmd, [string]$title) {
  Section $title

  # Ask for password once per run
  if (-not $script:SudoPasswordAsked) {
    $pw = Read-Host "Sudo password (or Enter to skip sudo-protected logs)" -AsSecureString
    $script:SudoPasswordAsked = $true

    if ($pw.Length -gt 0) {
      $script:SudoPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)
      )
    } else {
      $script:SudoPasswordPlain = $null
      Write-Host "(sudo logs disabled for this run)" -ForegroundColor DarkYellow
      return
    }
  }

  if (-not $script:SudoPasswordPlain) {
    Write-Host "(sudo logs disabled for this run)" -ForegroundColor DarkYellow
    return
  }

  # Escape double-quotes for bash
  $escaped = $cmd.Replace('"', '\"')

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = "ssh"
  $psi.Arguments = "-p $Port $Server `"sudo -S -p '' $escaped`""
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true

  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.WriteLine($script:SudoPasswordPlain)
  $p.StandardInput.Flush()

  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    Write-Host "(sudo failed: $err)" -ForegroundColor Yellow
  } else {
    Write-Host $out
  }
}

# =============================================================
# Unix path join
# =============================================================
function Join-Unix($a,$b) { return ($a.TrimEnd('/') + '/' + $b.TrimStart('/')) }

# =============================================================
# What logs we want
# =============================================================
$wantAll     = $Kinds -contains "All"
$wantNginx   = $wantAll -or $Kinds -contains "Nginx"
$wantApp     = $wantAll -or $Kinds -contains "App"
$wantBackup  = $wantAll -or $Kinds -contains "Backup"
$wantJournal = $wantAll -or $Kinds -contains "Journal"

$nginxLogs = @("nginx.error.log","nginx.access.log")
$appLogs   = @("errors.log","payment_system.log","sql.log")
$backupLog = @("backup.log")

# =============================================================
# Build list of remote files to fetch
# =============================================================
$remoteFiles = @()

# Explicit Files
if ($Files) {
  foreach ($f in $Files) {
    if ($f.StartsWith("/")) { $remoteFiles += $f }
    else                    { $remoteFiles += Join-Unix $RemoteLogDir $f }
  }
}

# Server-side globs
if ($RemoteGlobs) {
  foreach ($g in $RemoteGlobs) {
    $pat = if ($g.StartsWith("/")) { $g } else { Join-Unix $RemoteLogDir $g }
    try {
      $list = Invoke-SSH "ls -1 $pat 2>/dev/null || true"
      $remoteFiles += $list -split "`n" | Where-Object { $_.Trim() }
    } catch { }
  }
}

# Fallback to --Kinds
if (-not $remoteFiles) {
  if ($wantNginx) { $remoteFiles += $nginxLogs | ForEach-Object { Join-Unix $RemoteLogDir $_ } }
  if ($wantApp)   { $remoteFiles += $appLogs   | ForEach-Object { Join-Unix $RemoteLogDir $_ } }
  if ($wantBackup){ $remoteFiles += $backupLog | ForEach-Object { Join-Unix $RemoteLogDir $_ } }
}

# =============================================================
# VIEW / TAIL
# =============================================================
if (-not $Download) {
  $sinceArg = if ($Since) { "--since `"$Since`"" } else { "" }

  if ($Follow) {
    if ($wantNginx) {
      $err = Join-Unix $RemoteLogDir "nginx.error.log"
      Section "LIVE: nginx.error.log"
      & ssh -p $Port $Server "tail -F -n $Tail $err"
    }

    if ($wantJournal) {
      Invoke-Sudo "journalctl -u gunicorn_apnagold -f --no-pager $sinceArg" "LIVE: gunicorn"
      Invoke-Sudo "journalctl -u nginx -f --no-pager $sinceArg" "LIVE: nginx service"
    }
  }
  else {
    if ($wantNginx) {
      foreach ($n in $nginxLogs) {
        $p = Join-Unix $RemoteLogDir $n
        Section "$n (last $Tail)"
        try { Invoke-SSH "tail -n $Tail $p" | Write-Host }
        catch { Write-Host "(missing: $n)" -ForegroundColor DarkYellow }
      }
    }

    if ($wantApp) {
      foreach ($n in $appLogs) {
        $p = Join-Unix $RemoteLogDir $n
        Section "$n (last $Tail)"
        try { Invoke-SSH "tail -n $Tail $p" | Write-Host }
        catch { Write-Host "(missing: $n)" -ForegroundColor DarkYellow }
      }
    }

    if ($wantBackup) {
      $p = Join-Unix $RemoteLogDir "backup.log"
      Section "backup.log (last $Tail)"
      try { Invoke-SSH "tail -n $Tail $p" | Write-Host }
      catch { Write-Host "(missing backup.log)" -ForegroundColor DarkYellow }
    }

    if ($wantJournal) {
      Invoke-Sudo "journalctl -u gunicorn_apnagold -n $Tail --no-pager $sinceArg" "gunicorn"
      Invoke-Sudo "journalctl -u nginx -n $Tail --no-pager $sinceArg" "nginx"
    }
  }
}

# =============================================================
# DOWNLOAD
# =============================================================
if ($Download) {
  try {
    Ensure-Dir $LocalDir

    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $dest  = Join-Path $LocalDir $stamp
    Ensure-Dir $dest

    Section "Downloading logs to $dest"

    function Copy-One([string]$remote) {
      # Build "server:/path/to/file" safely without interpolation weirdness
      $remoteArg = "{0}:{1}" -f $Server, $remote   # e.g. apna-vps:/srv/apnagold/logs/nginx.error.log

      # Dest is a directory, scp will keep filenames
      & scp -P $Port -p -q $remoteArg $dest
      if ($LASTEXITCODE -ne 0) {
        Write-Host "(missing) $remote" -ForegroundColor DarkYellow
      } else {
        Write-Host "OK: $(Split-Path $remote -Leaf)" -ForegroundColor Green
      }
    }

    # Base files
    $remoteFiles | Select-Object -Unique | ForEach-Object { Copy-One $_ }

    # Rotated?
    if ($IncludeRotated) {
      $patterns = @()

      # unified logic
      if ($wantAll -or $wantNginx) {
        $patterns += "nginx*.log.1","nginx*.log.*.gz"
      }
      if ($wantAll -or $wantApp) {
        $patterns += "errors.log.*","payment_system.log.*","sql.log.*"
      }
      if ($wantAll -or $wantBackup) {
        $patterns += "backup.log.*"
      }

      foreach ($pat in $patterns | Select-Object -Unique) {
        $glob = Join-Unix $RemoteLogDir $pat
        try {
          $list = Invoke-SSH "ls -1 $glob 2>/dev/null || true"
          $list -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Copy-One $_.Trim() }
        } catch { }
      }
    }

    # Manifest
    Set-Content -Path (Join-Path $dest "_manifest.txt") -Value ($remoteFiles | Sort-Object -Unique)

    # Zip?
    if ($Zip) {
      Section "Creating zip"
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      $zipPath = Join-Path $LocalDir ("logs_$stamp.zip")
      [System.IO.Compression.ZipFile]::CreateFromDirectory($dest,$zipPath)
      Write-Host "ZIP -> $zipPath" -ForegroundColor Green
    }

  } catch {
    Write-Host "ERROR during download: $($_.Exception.Message)" -ForegroundColor Red
    if ($OutFile) { Stop-Transcript | Out-Null }
    exit 2
  }
}

# =============================================================
# Cleanup
# =============================================================
if ($OutFile) { Stop-Transcript | Out-Null }
exit 0
