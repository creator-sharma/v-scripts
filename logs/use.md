---

````markdown
# Get-Logs.ps1 — VPS Log Helper

PowerShell helper script to **view, follow, and download** production logs from the VPS.

- Server: `apna-vps` (default, override with `-Server`)
- Remote logs: `/srv/apnagold/logs`
- Local log downloads: `C:\Work13\scripts\logs` (by default)
- Stack: Nginx + Django + Gunicorn + custom app logs + backup logs

---

## 🔧 What This Script Does

### 1. Tail / View Logs (default mode)

Without any special switches, the script:

- Connects over SSH to the VPS (`ssh -p <Port> <Server>`).
- Tails the last `<Tail>` lines (default **200**) of:

  - `nginx.error.log`
  - `nginx.access.log`
  - `errors.log`
  - `payment_system.log`
  - `sql.log`
  - `backup.log`

- Optionally (if `Journal` is included in `-Kinds`):

  - Shows `journalctl` logs for:
    - `gunicorn_apnagold`
    - `nginx`

The output is grouped by clear sections like:

```text
===== nginx.access.log (last 200) =====
...
===== payment_system.log (last 200) =====
...
===== gunicorn =====
...
===== nginx =====
...
```

---

### 2. Download Logs via SCP

With `-Download`, the script:

1. Creates a timestamped folder under `-LocalDir`

   - e.g. `C:\Work13\scripts\logs\2025-11-14_162030\`

2. Downloads selected logs from `-RemoteLogDir` using `scp`
3. Optionally includes rotated / gzipped logs (`*.log.1`, `*.log.*.gz`) when `-IncludeRotated` is used
4. Optionally zips that folder into `logs_<timestamp>.zip` when `-Zip` is used
5. Writes a manifest file: `_manifest.txt` with the list of primary log paths that were targeted

---

### 3. Sudo / Journal Logs

For `journalctl`-based logs (when `-Kinds` includes `Journal`):

- The script prompts once per run:

  ```text
  Sudo password (or Enter to skip sudo-protected logs):
  ```

- If you enter a password:

  - It is reused for all `Invoke-Sudo` calls in that run
  - You see sections like:

    ```text
    ===== gunicorn =====
    (journalctl output)

    ===== nginx =====
    (journalctl output)
    ```

- If you press Enter without a password:

  - Journal sections are **skipped** for the rest of that run
  - Nginx/App/Backup file logs still work

To avoid all sudo/journal activity entirely, simply exclude `Journal` from `-Kinds`.

---

## 📁 Log Files Covered

Remote log directory: `/srv/apnagold/logs`

**Nginx logs:**

- `nginx.access.log`
- `nginx.error.log`

**Django / app logs:**

- `errors.log`
- `payment_system.log`
- `sql.log` (SQL debug log, sometimes empty)

**Backup logs:**

- `backup.log`

**Journalctl (services):**

- `gunicorn_apnagold`
- `nginx`

---

## ⚙️ Parameters

```powershell
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
```

### Connection

- `-Server`
  Hostname or IP of the VPS. Default: `apna-vps`.

- `-Port`
  SSH port. Default: `22`.

### Paths

- `-RemoteLogDir`
  Base log directory on the VPS. Default: `/srv/apnagold/logs`.

- `-LocalDir`
  Local base folder for downloaded logs and zip archives.
  Default: `C:\Work13\scripts\logs`.

### Scope of logs (`-Kinds`)

Controls which _categories_ are included:

- `All` (default): Nginx + App + Backup + Journal
- `Nginx`: nginx.error.log + nginx.access.log
- `App`: errors.log + payment_system.log + sql.log
- `Backup`: backup.log
- `Journal`: `journalctl` for `gunicorn_apnagold` and `nginx`

You can combine them, e.g.:

```powershell
-Kinds Nginx,App
-Kinds Nginx,App,Backup
```

> 💡 To **avoid sudo/journalctl**, do _not_ include `Journal` in `-Kinds`.

### Tail / Follow

- `-Tail <int>`
  Number of lines to show from each log file (default: 200).

- `-Follow` (switch)
  When set, runs interactive `tail -F` / `journalctl -f` on the server.
  You’ll see a live stream until you press **Ctrl+C**.

- `-Since <string>`
  Passed to `journalctl --since "<value>"` for journal sections.
  Examples:

  - `"today"`
  - `"1 hour ago"`
  - `"2025-11-12 10:00"`

### Download options

- `-Download` (switch)
  Enables download mode; logs are copied via `scp` to a timestamped folder under `-LocalDir`.

- `-IncludeRotated` (switch)
  Also downloads rotated/gzipped logs:

  - `nginx*.log.1`, `nginx*.log.*.gz`
  - `errors.log.*`, `payment_system.log.*`, `sql.log.*`
  - `backup.log.*`

- `-Zip` (switch)
  After download, zip the folder into `logs_<timestamp>.zip` in `-LocalDir`.

### Explicit file selection

- `-Files <string[]>`
  Explicit log files to include.

  - If a value starts with `/`, it’s treated as an absolute path on the server.
  - Otherwise, it’s joined with `-RemoteLogDir`.

  Examples:

  ```powershell
  -Files "nginx.error.log", "payment_system.log"
  -Files "/var/log/syslog"
  ```

- `-RemoteGlobs <string[]>`
  Server-side glob patterns, expanded on the VPS using `ls`.
  Again, relative patterns are joined with `-RemoteLogDir`.

  Examples:

  ```powershell
  -RemoteGlobs "nginx.*.log.*.gz", "errors.log.1*"
  -RemoteGlobs "/var/log/nginx/*.log"
  ```

### Transcript

- `-OutFile <string>`
  Enables a PowerShell transcript to the given path.
  All console output (sections, logs, prompts) is also written to this file.

  Example:

  ```powershell
  -OutFile "C:\Work13\scripts\logs\run_2025-11-14.txt"
  ```

---

## ✅ Typical Usage Scenarios

### 1. Quick view of the latest logs (all kinds)

```powershell
.\logs\Get-Logs.ps1 -Tail 200
```

Shows:

- nginx.error.log
- nginx.access.log
- errors.log
- payment_system.log
- sql.log
- backup.log
- gunicorn journal (sudo)
- nginx journal (sudo)

You’ll get **one sudo prompt** for journalctl.

---

### 2. View only file logs (no sudo, no journalctl)

```powershell
.\logs\Get-Logs.ps1 -Tail 100 -Kinds Nginx,App,Backup
```

Shows:

- nginx.error.log / nginx.access.log
- errors.log / payment_system.log / sql.log
- backup.log

No sudo prompts, no journal output.

---

### 3. Capture everything into a transcript file

```powershell
.\logs\Get-Logs.ps1 -Tail 50 -OutFile "C:\Work13\scripts\logs\run.txt"
```

- Same as the default view
- Additionally writes everything into `run.txt`

---

### 4. Live follow of nginx error log + journal

```powershell
.\logs\Get-Logs.ps1 -Tail 50 -Follow -Kinds Nginx,Journal
```

- Live `tail -F` of `nginx.error.log`
- Live `journalctl -f` for:

  - `gunicorn_apnagold`
  - `nginx`

Press **Ctrl+C** to stop.

---

### 5. Download current logs (file-based only)

```powershell
.\logs\Get-Logs.ps1 -Download -Kinds Nginx,App,Backup
```

Creates a folder like:

```text
C:\Work13\scripts\logs\2025-11-14_162030\
```

and downloads:

- `/srv/apnagold/logs/nginx.error.log`
- `/srv/apnagold/logs/nginx.access.log`
- `/srv/apnagold/logs/errors.log`
- `/srv/apnagold/logs/payment_system.log`
- `/srv/apnagold/logs/sql.log`
- `/srv/apnagold/logs/backup.log`

Also writes `_manifest.txt` in that folder.

---

### 6. Download current + rotated logs and zip them

```powershell
.\logs\Get-Logs.ps1 -Download -IncludeRotated -Zip
```

- Creates timestamped folder
- Downloads main logs (based on `-Kinds`)
- Also fetches patterns:

  - `nginx*.log.1`, `nginx*.log.*.gz`
  - `errors.log.*`, `payment_system.log.*`, `sql.log.*`
  - `backup.log.*`

- Zips everything to:

  ```text
  C:\Work13\scripts\logs\logs_<timestamp>.zip
  ```

---

### 7. Download only specific files

```powershell
.\logs\Get-Logs.ps1 `
  -Download `
  -Files "nginx.error.log","payment_system.log"
```

Downloads just:

- `/srv/apnagold/logs/nginx.error.log`
- `/srv/apnagold/logs/payment_system.log`

to a timestamped folder under `-LocalDir`.

---

### 8. Download by glob patterns (server-side expansion)

```powershell
.\logs\Get-Logs.ps1 `
  -Download `
  -RemoteGlobs "nginx.*.log.*.gz","errors.log.1*"
```

- Expands these on the server under `/srv/apnagold/logs`
- Downloads all matches into the timestamped folder

---

### 9. Use a different server / port

```powershell
.\logs\Get-Logs.ps1 -Server "srv933796" -Port 2222 -Tail 100
```

Useful if you change hostnames or run a local test VM.

---

## 🔐 Requirements & Assumptions

- You can SSH to the server with:

  ```bash
  ssh apna-vps
  ```

  (or `-Server` / `-Port` values you pass to the script)

- `ssh` and `scp` must be in your PATH (Git for Windows, Windows OpenSSH, etc.)

- Your user on the server can:

  - read `/srv/apnagold/logs/*`
  - run `sudo journalctl -u gunicorn_apnagold` and `sudo journalctl -u nginx` when you provide the correct sudo password (or have passwordless sudo configured for those).

```

```
