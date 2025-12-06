<# ====================================================================================================
    health-check.ps1
    ---------------------------------------------------------------------------------------------
    Comprehensive health check for the VPS.

    Performs:
      ✔ Ping + SSH reachability
      ✔ Nginx service status
      ✔ Gunicorn service status
      ✔ Django API health endpoint check (/api/healthz/)
      ✔ Recent Nginx error logs (tail)
      ✔ Recent Gunicorn systemd logs (journalctl)
      ✔ Disk usage (/ /srv /home)
      ✔ Memory usage and CPU load
      ✔ PostgreSQL service status
      ✔ Latest DB backup timestamp
      ✔ TLS certificate expiry date
      ✔ UFW firewall status
      ✔ System uptime

    USAGE:
      PS> .\health-check.ps1
      PS> .\health-check.ps1 -VerboseOutput

    Comprehensive health check for the VPS with:
      • Non-zero exit code on failure (CI/monitoring friendly)
      • Simple OK/WARN/FAIL summary
      • Configurable health URL
==================================================================================================== #>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Server   = "apna-vps",

    [Parameter()]
    [string]$PingHost = "31.97.228.66",

    [Parameter()]
    [ValidateRange(1,65535)]
    [int]$Port = 22,

    [Parameter()]
    [string]$HealthUrl = "https://apnagold.in/api/healthz/",

    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

# Global sudo state (prompt once per run)
$script:SudoPasswordPlain = $null
$script:SudoPasswordAsked = $false

# Collect health state
$global:Health = [ordered]@{
    NetworkPing        = $false
    NetworkSSH         = $false
    ServiceNginx       = $false
    ServiceGunicorn    = $false
    ServicePostgres    = $false
    DjangoHealthz      = $false
    BackupsRecent      = $false
    TLSValid           = $false
    TLSWarn            = $false
    FirewallOk         = $false
}

function Banner([string]$text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function Invoke-RemoteSsh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if (-not $Command.Trim()) {
        throw "Invoke-RemoteSsh(): empty command passed."
    }

    if ($VerboseOutput) {
        Write-Host "Running SSH: ssh -p $Port $Server `"$Command`"" -ForegroundColor DarkGray
    }

    $sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source

    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $sshExe -o BatchMode=yes -o ConnectTimeout=5 -p $Port $Server $Command 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $oldPref

    if ($exit -ne 0) {
        if ($VerboseOutput) {
            Write-Host "SSH command failed (exit $exit): $Command" -ForegroundColor Yellow
            Write-Host $out -ForegroundColor DarkYellow
        }
        return $null
    }

    return $out
}

function Invoke-RemoteSudo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [string]$Label = ""
    )

    if (-not $Command.Trim()) {
        throw "Invoke-RemoteSudo(): empty command passed."
    }

    if ($Label) {
        Banner $Label
    }

    if (-not $script:SudoPasswordAsked) {
        $pw = Read-Host "Sudo password (or Enter to skip sudo-level checks)" -AsSecureString
        $script:SudoPasswordAsked = $true

        if ($pw.Length -gt 0) {
            $script:SudoPasswordPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw)
            )
        } else {
            $script:SudoPasswordPlain = $null
            Write-Host "(sudo-level checks disabled for this run)" -ForegroundColor DarkYellow
            return $null
        }
    }

    if (-not $script:SudoPasswordPlain) {
        Write-Host "(sudo-level checks disabled for this run)" -ForegroundColor DarkYellow
        return $null
    }

    if ($VerboseOutput) {
        Write-Host "Running SSH (sudo): ssh -p $Port $Server `"sudo -S -p '' $Command`"" -ForegroundColor DarkGray
    }

    $sshExe = (Get-Command ssh.exe -ErrorAction Stop).Source

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $sshExe
    $psi.Arguments              = "-p $Port $Server `"sudo -S -p '' $Command`""
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false

    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.WriteLine($script:SudoPasswordPlain)
    $p.StandardInput.Flush()

    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) {
        if ($VerboseOutput -and $err) {
            Write-Host "sudo command failed (exit $($p.ExitCode)): $Command" -ForegroundColor Yellow
            Write-Host $err -ForegroundColor DarkYellow
        }
        return $null
    } else {
        if ($out) { Write-Host $out }
    }

    return $out
}

function Show-ServiceStatus([string]$name, [string]$unit, [string]$healthKey) {
    $status = Invoke-RemoteSsh "systemctl is-active $unit" | Select-Object -First 1
    $statusTrimmed = ($status | ForEach-Object { $_.Trim() }) -join ''
    if (-not $statusTrimmed) { $statusTrimmed = "unknown" }

    $ok = ($statusTrimmed -eq "active")
    $global:Health[$healthKey] = $ok

    $color = if ($ok) { "Green" } else { "Red" }
    Write-Host ("{0,-10}: {1}" -f $name, $statusTrimmed) -ForegroundColor $color
}

# 1) Network Reachability
Banner "1) Network Reachability"

$ping = Test-Connection -ComputerName $PingHost -Count 1 -Quiet -ErrorAction SilentlyContinue
$global:Health["NetworkPing"] = [bool]$ping

Write-Host ("Ping ({0}): {1}" -f $PingHost, ($(if ($ping) { "OK" } else { "FAILED" }))) `
    -ForegroundColor ($(if ($ping) { "Green" } else { "Red" }))

$sshCheck = Invoke-RemoteSsh "echo SSH_OK" | Select-Object -First 1
$sshOk = ($sshCheck -match "SSH_OK")
$global:Health["NetworkSSH"] = $sshOk

if ($sshOk) {
    Write-Host "SSH: OK" -ForegroundColor Green
} else {
    Write-Host "SSH: FAILED (see SSH output above)" -ForegroundColor Red
}

# 2) Services
Banner "2) Service Status (Nginx + Gunicorn + Postgres)"

Show-ServiceStatus "nginx"      "nginx"              "ServiceNginx"
Show-ServiceStatus "gunicorn"   "gunicorn_apnagold"  "ServiceGunicorn"
Show-ServiceStatus "postgresql" "postgresql"         "ServicePostgres"

# 3) Django health endpoint
Banner "3) Django Application Health"

try {
    $health = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 5
    if ($health.StatusCode -eq 200) {
        Write-Host "$HealthUrl : OK (200)" -ForegroundColor Green
        $global:Health["DjangoHealthz"] = $true
    } else {
        Write-Host "$HealthUrl : ERROR ($($health.StatusCode))" -ForegroundColor Red
    }
} catch {
    Write-Host "$HealthUrl : FAILED ($($_.Exception.Message))" -ForegroundColor Red
}

# 4) Nginx errors
Banner "4) Recent Nginx Errors (last 20 lines)"
Invoke-RemoteSsh "tail -n 20 /srv/apnagold/logs/nginx.error.log"

# 5) Gunicorn errors (sudo)
Banner "5) Recent Gunicorn Errors (last 20 lines)"
Invoke-RemoteSudo "journalctl -u gunicorn_apnagold -n 20 --no-pager"

# 6) Disk usage
Banner "6) Disk Usage"
Invoke-RemoteSsh "df -h / /srv /home"

# 7) Memory / CPU Load
Banner "7) Memory / CPU Load"
Invoke-RemoteSsh "free -h"
Write-Host ""
Invoke-RemoteSsh "uptime"

# 8) Backup freshness
Banner "8) Backup Freshness Check"

$latestBackup = Invoke-RemoteSsh "ls -1t /home/apna/backups/daily/*.sql.gz 2>/dev/null | head -n1" |
                Select-Object -First 1

if ($latestBackup -and $latestBackup.Trim()) {
    $latestBackup = $latestBackup.Trim()
    Write-Host "Latest backup: $latestBackup" -ForegroundColor Green
    $backupTime = Invoke-RemoteSsh "date -r $latestBackup" | Select-Object -First 1
    Write-Host ("Timestamp: " + $backupTime) -ForegroundColor Gray
    $global:Health["BackupsRecent"] = $true
} else {
    Write-Host "No backups found!" -ForegroundColor Red
    $global:Health["BackupsRecent"] = $false
}

# 9) TLS certificate expiry (sudo)
Banner "9) TLS Certificate Expiry"

$certInfoRaw = Invoke-RemoteSudo `
    "openssl x509 -enddate -noout -in /etc/letsencrypt/live/apnagold.in/fullchain.pem"

if ($null -ne $certInfoRaw -and $certInfoRaw.Trim()) {
    $certInfo = $certInfoRaw | Select-Object -First 1
    $expiry   = $certInfo -replace "notAfter=", ""
    Write-Host "Certificate expires on: $expiry" -ForegroundColor Yellow

    try {
        $expiryDate = [DateTime]::ParseExact($expiry.Trim(), "MMM d HH:mm:ss yyyy 'GMT'",
                                             [System.Globalization.CultureInfo]::InvariantCulture)
        $daysLeft = ($expiryDate.ToUniversalTime() - [DateTime]::UtcNow).TotalDays

        if ($daysLeft -le 0) {
            Write-Host "TLS STATUS: EXPIRED!" -ForegroundColor Red
            $global:Health["TLSValid"] = $false
        } elseif ($daysLeft -lt 7) {
            Write-Host ("TLS STATUS: WARNING - expires in {0:N1} days" -f $daysLeft) -ForegroundColor DarkYellow
            $global:Health["TLSValid"] = $true
            $global:Health["TLSWarn"]  = $true
        } else {
            Write-Host ("TLS STATUS: OK - {0:N1} days remaining" -f $daysLeft) -ForegroundColor Green
            $global:Health["TLSValid"] = $true
        }
    } catch {
        Write-Host "Could not parse TLS expiry date." -ForegroundColor Yellow
    }
}

# 10) Firewall (UFW)
Banner "10) Firewall Status (UFW)"
$ufw = Invoke-RemoteSudo "ufw status numbered"
if ($ufw -match "Status:\s+active") {
    $global:Health["FirewallOk"] = $true
} elseif ($ufw -ne $null) {
    $global:Health["FirewallOk"] = $false
}

# 11) System uptime
Banner "11) System Uptime"
$uptimePretty = Invoke-RemoteSsh "uptime -p" | Select-Object -First 1
Write-Host $uptimePretty

Write-Host ""
Write-Host "=== Health Check Summary ===" -ForegroundColor Cyan

# Build summary
$failKeys = @()
$warnKeys = @()

foreach ($key in $Health.Keys) {
    $val = $Health[$key]
    if ($key -eq "TLSWarn" -and $val) {
        $warnKeys += "TLS expiry approaching"
        continue
    }
    if ($val -eq $false -and $key -ne "TLSWarn") {
        $failKeys += $key
    }
}

if ($failKeys.Count -eq 0 -and $warnKeys.Count -eq 0) {
    Write-Host "Overall: OK" -ForegroundColor Green
} elseif ($failKeys.Count -eq 0 -and $warnKeys.Count -gt 0) {
    Write-Host ("Overall: WARN ({0})" -f ($warnKeys -join ", ")) -ForegroundColor Yellow
} else {
    Write-Host ("Overall: FAIL (issues: {0})" -f ($failKeys -join ", ")) -ForegroundColor Red
}

# Decide exit code
$exitCode = 0
if ($failKeys.Count -gt 0) {
    $exitCode = 2   # hard failure
} elseif ($warnKeys.Count -gt 0) {
    $exitCode = 1   # warning
}

Write-Host "Exit code: $exitCode" -ForegroundColor Gray

# Clear sudo password from memory
$script:SudoPasswordPlain = $null
$script:SudoPasswordAsked = $false

exit $exitCode
