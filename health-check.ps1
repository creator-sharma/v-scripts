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
==================================================================================================== #>


param(
    [string]$Server = "apna-vps",
    [int]$Port = 22,
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

function Banner($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function SSH($cmd) {
    if ($VerboseOutput) { Write-Host "Running SSH: $cmd" -ForegroundColor DarkGray }
    $out = & ssh -p $Port $Server $cmd 2>$null
    return $out
}

Banner "1) Network Reachability"
$ping = Test-Connection -ComputerName $Server -Count 1 -Quiet
Write-Host ("Ping: " + ($(if ($ping) {"OK"} else {"FAILED"}))) `
    -ForegroundColor ($(if ($ping){"Green"}else{"Red"}))

try {
    SSH "echo SSH_OK" | Out-Null
    Write-Host "SSH: OK" -ForegroundColor Green
} catch {
    Write-Host "SSH: FAILED" -ForegroundColor Red
}

Banner "2) Service Status (Nginx + Gunicorn + Postgres)"
Write-Host (SSH "systemctl is-active nginx") -ForegroundColor Green
Write-Host (SSH "systemctl is-active gunicorn_apnagold") -ForegroundColor Green
Write-Host (SSH "systemctl is-active postgresql") -ForegroundColor Green

Banner "3) Django Application Health"
try {
    $health = Invoke-WebRequest -Uri "https://apnagold.in/api/healthz/" -TimeoutSec 5
    if ($health.StatusCode -eq 200) {
        Write-Host "/api/healthz/: OK (200)" -ForegroundColor Green
    } else {
        Write-Host "/api/healthz/: ERROR ($($health.StatusCode))" -ForegroundColor Red
    }
} catch {
    Write-Host "/api/healthz/: FAILED ($($_.Exception.Message))" -ForegroundColor Red
}

Banner "4) Recent Nginx Errors (last 20 lines)"
Write-Host (SSH "tail -n 20 /srv/apnagold/logs/nginx.error.log")

Banner "5) Recent Gunicorn Errors (last 20 lines)"
Write-Host (SSH "sudo journalctl -u gunicorn_apnagold -n 20 --no-pager")

Banner "6) Disk Usage"
Write-Host (SSH "df -h / /srv /home")

Banner "7) Memory / CPU Load"
Write-Host (SSH "free -h")
Write-Host ""
Write-Host (SSH "uptime")

Banner "8) Backup Freshness Check"
$latestBackup = SSH "ls -1t /home/apna/backups/daily/*.sql.gz 2>/dev/null | head -n1"
if ($latestBackup) {
    Write-Host "Latest backup: $latestBackup" -ForegroundColor Green
    Write-Host ("Timestamp: " + (SSH "date -r $latestBackup")) -ForegroundColor Gray
} else {
    Write-Host "No backups found!" -ForegroundColor Red
}

Banner "9) TLS Certificate Expiry"
$certInfo = SSH "sudo openssl x509 -enddate -noout -in /etc/letsencrypt/live/apnagold.in/fullchain.pem" 
$expiry = $certInfo -replace "notAfter=", ""
Write-Host "Certificate expires on: $expiry" -ForegroundColor Yellow

Banner "10) Firewall Status (UFW)"
Write-Host (SSH "sudo ufw status numbered")

Banner "11) System Uptime"
Write-Host (SSH "uptime -p")

Write-Host ""
Write-Host "=== Health Check Complete ===" -ForegroundColor Cyan
