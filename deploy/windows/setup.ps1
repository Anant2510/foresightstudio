<#
.SYNOPSIS
  Foresight Studio - one-time setup on the xPerion Azure VM (Windows Server).

.DESCRIPTION
  1. Checks the VM (admin rights, Node, free ports, outbound access)
  2. Asks for the Anthropic API key (and optional login / GitHub token)
  3. Installs the app server to C:\xperion and locks down permissions
  4. Registers the app server to start with Windows (runs as LOCAL SERVICE)
  5. Opens Windows Firewall for 80/443
  6. Installs Caddy as the HTTPS front door (Windows service)
  7. Runs smoke tests

  Safe to re-run: keeps the stored key, login and token unless you replace them.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy\windows\setup.ps1 -Domain xperion2.centralindia.cloudapp.azure.com -Email you@coforge.com

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy\windows\setup.ps1
  (no domain yet: serves plain HTTP on port 80 by IP address)
#>
[CmdletBinding()]
param(
  [string]$Domain = "",
  [string]$Email = "",
  [string]$Root = "C:\xperion",
  [int]$Port = 8790,
  [string]$Repo = "anant2510/foresightstudio",
  [string]$Branch = "main",
  [switch]$NoAutoUpdate,
  [switch]$UpdateCaddy,
  [string]$CaddyExe = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = $Utf8NoBom

# ------------------------------------------------------------------ paths
$KitDir     = $PSScriptRoot
$RepoDir    = Split-Path -Parent (Split-Path -Parent $KitDir)
$AppSrc     = Join-Path $RepoDir "index.html"
$ServerSrc  = Join-Path $KitDir "server.js"
$FsDir      = Join-Path $Root "foresightstudio"
$AppDir     = Join-Path $FsDir "app"
$ServerDir  = Join-Path $FsDir "server"
$RuntimeDir = Join-Path $Root "runtime"
$SecretsDir = Join-Path $Root "secrets"
$LogsDir    = Join-Path $Root "logs"
$CaddyDir   = Join-Path $Root "caddy"
$KeyFile    = Join-Path $SecretsDir "anthropic.key"
$TokenFile  = Join-Path $SecretsDir "github.token"
$ConfigFile = Join-Path $ServerDir "config.json"
$ServerJs   = Join-Path $ServerDir "server.js"
$ServerLog  = Join-Path $LogsDir "foresight-server.log"
$NodeExe    = Join-Path $RuntimeDir "node.exe"
$CaddyBin   = Join-Path $CaddyDir "caddy.exe"
$Caddyfile  = Join-Path $CaddyDir "Caddyfile"
$TaskName   = "xPerion Foresight Server"
$SvcName    = "xperion-web"
$FwRule     = "xPerion Web (HTTP/HTTPS)"
$Curl       = Join-Path $env:SystemRoot "System32\curl.exe"
$BasePath   = "/foresightstudio"

# SIDs, so this works on any Windows display language
$SidAdmins = "*S-1-5-32-544"; $SidSystem = "*S-1-5-18"; $SidLocalSvc = "*S-1-5-19"; $SidUsers = "*S-1-5-32-545"

# ------------------------------------------------------------------ helpers
function Step($t) { Write-Host ""; Write-Host $t -ForegroundColor White }
function Ok($t)   { Write-Host "  [ok] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  ->   $t" -ForegroundColor Cyan }
function Warn($t) { Write-Host "  [!]  $t" -ForegroundColor Yellow }
function Fail($t) { Write-Host "  [x]  $t" -ForegroundColor Red; exit 1 }

function YesNo([string]$Question, [bool]$Default) {
  $hint = "[y/N]"; if ($Default) { $hint = "[Y/n]" }
  $a = Read-Host "    $Question $hint"
  if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
  return ($a -match '^[Yy]')
}

function ToPlain([Security.SecureString]$Secure) {
  if (-not $Secure) { return "" }
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function WriteText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom) }

function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments, [string]$StdIn)
  $ErrorActionPreference = "Continue"
  if ($PSBoundParameters.ContainsKey("StdIn")) { $out = $StdIn | & $Exe @Arguments 2>&1 }
  else { $out = & $Exe @Arguments 2>&1 }
  $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $text }
}

function Get-Http([string[]]$CurlArgs) {
  $tmp = [IO.Path]::GetTempFileName()
  $r = Invoke-Native $Curl (@("-s", "--ssl-no-revoke", "--max-time", "60", "-o", $tmp, "-w", "%{http_code}") + $CurlArgs)
  $body = ""
  try { $body = [IO.File]::ReadAllText($tmp) } catch { }
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return [pscustomobject]@{ Code = "$($r.Out)".Trim(); Body = $body }
}

function Set-Acl2([string]$Path, [string[]]$IcaclsArgs) {
  $r = Invoke-Native "icacls.exe" (@($Path) + $IcaclsArgs)
  if ($r.Code -ne 0) { Fail "Could not set permissions on ${Path}: $($r.Out)" }
}

function Get-Listeners([int[]]$Ports) {
  $list = @()
  $conns = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $Ports -contains $_.LocalPort }
  foreach ($c in $conns) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.OwningProcess)" -ErrorAction SilentlyContinue
    $name = "pid $($c.OwningProcess)"; $exe = ""; $cmd = ""
    if ($p) { $name = $p.Name; $exe = "$($p.ExecutablePath)"; $cmd = "$($p.CommandLine)" }
    $list += [pscustomobject]@{ Port = $c.LocalPort; Name = $name; Exe = $exe; Cmd = $cmd }
  }
  return $list
}

function Stop-OurNode {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { "$($_.CommandLine)" -like "*$ServerDir*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ==================================================================
Step "1/7  Pre-flight checks"
# ==================================================================
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail "Run PowerShell as Administrator (right-click > Run as administrator)." }
foreach ($f in @($AppSrc, $ServerSrc)) { if (-not (Test-Path $f)) { Fail "Missing $f. Run this from the foresightstudio repo folder." } }
$appText = [IO.File]::ReadAllText($AppSrc)
if ($appText -notmatch 'FORESIGHT_PROXY') { Fail "index.html is the old version (no server-proxy support). Use the updated repo." }
if ($appText -match 'sk-ant-[A-Za-z0-9_-]{20,}') { Fail "index.html contains an API key. Remove it first." }
if (-not (Test-Path $Curl)) { Fail "curl.exe not found in System32." }
if ($Domain -and $Domain -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { Fail "-Domain should be a host name like xperion2.centralindia.cloudapp.azure.com" }
Ok "Repo looks right: $RepoDir"

$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCmd) { Fail "Node.js not found. Install Node 22 LTS or newer, then re-run." }
$nodeSrc = $nodeCmd.Path
if ([IO.Path]::GetExtension($nodeSrc) -ne ".exe") { Fail "node resolves to $nodeSrc (a shim). Point PATH at a real node.exe." }
$nodeVer = (Invoke-Native $nodeSrc @("-v")).Out.Trim()
$vParts = $nodeVer.TrimStart("v").Split(".")
if ([int]$vParts[0] -lt 20 -or ([int]$vParts[0] -eq 20 -and [int]$vParts[1] -lt 3)) { Fail "Node $nodeVer is too old. Install Node 22 LTS or newer." }
Ok "Node $nodeVer"

# Stop a previous install so files and ports are free
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Stop-OurNode
Start-Sleep -Seconds 1

foreach ($l in (Get-Listeners @(80, 443))) {
  if ($l.Exe -ne $CaddyBin) { Fail "Port $($l.Port) is already used by $($l.Name) ($($l.Exe)). Stop it or share this message." }
}
foreach ($l in (Get-Listeners @($Port))) { Fail "Port $Port is used by $($l.Name). Re-run with -Port 8791 (or another free port)." }
Ok "Ports 80, 443 and $Port are available"

$r = Get-Http @("-I", "https://api.anthropic.com")
if ($r.Code -eq "000") { Fail "This VM can't reach https://api.anthropic.com (outbound 443 blocked?)." }
Ok "Outbound access to Anthropic works"

if ($Domain) {
  $dns = Resolve-DnsName $Domain -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress }
  if (-not $dns) {
    Warn "$Domain doesn't resolve yet. Set the DNS name label on the VM's Public IP first (MIGRATION.md, Phase 2)."
    if (-not (YesNo "Continue anyway? Caddy will keep retrying for a certificate." $false)) { exit 1 }
  } else { Ok "$Domain resolves to $(($dns | Select-Object -ExpandProperty IPAddress) -join ', ')" }
}

# ==================================================================
Step "2/7  Settings"
# ==================================================================
$existingCfg = $null
if (Test-Path $ConfigFile) { try { $existingCfg = [IO.File]::ReadAllText($ConfigFile) | ConvertFrom-Json } catch { } }

# API key
$key = "$env:FS_API_KEY".Trim()
$keepKey = $false
if (-not $key -and (Test-Path $KeyFile)) { $keepKey = YesNo "An API key is already stored on this VM. Keep it?" $true }
if (-not $key -and -not $keepKey) {
  Write-Host "    Paste the Anthropic API key for this VM (input hidden)."
  Write-Host "    Tip: create a new key named 'foresight-azure-vm' rather than reusing the GitHub one."
  $key = (ToPlain (Read-Host "    API key" -AsSecureString)).Trim()
}
if (-not $keepKey -and $key -notmatch '^sk-ant-[A-Za-z0-9_-]{20,}$') { Fail "That doesn't look like an Anthropic key (expected sk-ant-...)." }

# Optional login
$authMode = "off"; $authUser = ""; $authPass = ""
if ($existingCfg -and $existingCfg.auth) {
  if (YesNo "Login is on (user '$($existingCfg.auth.user)'). Keep it?" $true) { $authMode = "keep" }
  elseif (YesNo "Set a new login instead? (No = turn the login off)" $true) { $authMode = "new" }
} elseif (YesNo "Require a username/password to open Foresight Studio? (recommended if the link will circulate widely)" $false) {
  $authMode = "new"
}
if ($authMode -eq "new") {
  $authUser = Read-Host "    Username"
  if ($authUser -notmatch '^[A-Za-z0-9._-]+$') { Fail "Username can use letters, digits, . _ - only." }
  $authPass = ToPlain (Read-Host "    Password (8+ characters)" -AsSecureString)
  if ($authPass -ne (ToPlain (Read-Host "    Repeat password" -AsSecureString))) { Fail "Passwords don't match." }
  if ($authPass.Length -lt 8) { Fail "Use at least 8 characters." }
  if (-not $Domain) { Warn "Without -Domain the site is plain HTTP, so the password travels unencrypted. Add a domain soon." }
}

# GitHub auto-deploy
$autoUpdate = -not $NoAutoUpdate
$useToken = $false
if ($autoUpdate) {
  $gh = Get-Http @("-H", "User-Agent: xperion-setup", "https://api.github.com/repos/$Repo")
  if ($gh.Code -eq "200") {
    Ok "GitHub repo $Repo is public: auto-deploy needs no token"
  } elseif ($gh.Code -eq "404") {
    $tok = ""
    if (Test-Path $TokenFile) { $tok = [IO.File]::ReadAllText($TokenFile).Trim() }
    if ($tok) {
      $chk = Get-Http @("-H", "User-Agent: xperion-setup", "-H", "Authorization: Bearer $tok", "https://api.github.com/repos/$Repo")
      if ($chk.Code -ne "200") { $tok = "" }
    }
    if (-not $tok) {
      Write-Host "    $Repo is private (or not found). Paste a fine-grained GitHub token with read-only"
      Write-Host "    'Contents' access to this repo, or press Enter to skip auto-deploy."
      $tok = (ToPlain (Read-Host "    GitHub token" -AsSecureString)).Trim()
      if ($tok) {
        $chk = Get-Http @("-H", "User-Agent: xperion-setup", "-H", "Authorization: Bearer $tok", "https://api.github.com/repos/$Repo")
        if ($chk.Code -ne "200") { Fail "GitHub rejected that token (HTTP $($chk.Code))." }
        $newToken = $tok
      }
    }
    if ($tok) { $useToken = $true; Ok "GitHub token works" } else { $autoUpdate = $false; Warn "Auto-deploy off. Re-run setup later to turn it on." }
  } else {
    Warn "Couldn't check GitHub (HTTP $($gh.Code)). Auto-deploy will keep retrying."
  }
}
Ok "Settings captured"

# ==================================================================
Step "3/7  Files and permissions"
# ==================================================================
foreach ($d in @($Root, $FsDir, $AppDir, $ServerDir, $RuntimeDir, $SecretsDir, $LogsDir, $CaddyDir, (Join-Path $CaddyDir "data"))) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}
# C:\xperion: admins + SYSTEM full, app server (LOCAL SERVICE) read-only
Set-Acl2 $Root @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F", "${SidLocalSvc}:(OI)(CI)RX")
# It may update the app and write logs
Set-Acl2 $AppDir @("/grant:r", "${SidLocalSvc}:(OI)(CI)M")
Set-Acl2 $LogsDir @("/grant:r", "${SidLocalSvc}:(OI)(CI)M", "${SidUsers}:(OI)(CI)RX")
# Secrets: readable by the app server only; Caddy's TLS keys: admins + SYSTEM only
Set-Acl2 $SecretsDir @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F", "${SidLocalSvc}:(OI)(CI)R")
Set-Acl2 $CaddyDir @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F")
Ok "Folders under $Root locked down"

Copy-Item $nodeSrc $NodeExe -Force
Copy-Item $ServerSrc $ServerJs -Force
Copy-Item $AppSrc (Join-Path $AppDir "index.html") -Force
Remove-Item (Join-Path $AppDir ".deploy-state.json") -Force -ErrorAction SilentlyContinue   # re-sync with GitHub on start
Ok "App server, app and Node runtime installed"

if (-not $keepKey) { WriteText $KeyFile $key }
if ($newToken) { WriteText $TokenFile $newToken }
Ok "Secrets stored in $SecretsDir"

$authObj = $null
if ($authMode -eq "keep") {
  $authObj = [ordered]@{ user = $existingCfg.auth.user; salt = $existingCfg.auth.salt; hash = $existingCfg.auth.hash }
} elseif ($authMode -eq "new") {
  $h = Invoke-Native $NodeExe @($ServerJs, "--hash-password") -StdIn $authPass
  if ($h.Code -ne 0) { Fail "Could not hash the password: $($h.Out)" }
  $hj = $h.Out.Trim() | ConvertFrom-Json
  $authObj = [ordered]@{ user = $authUser; salt = $hj.salt; hash = $hj.hash }
}

$rate = [ordered]@{ perMinute = 60; burst = 30 }
if ($existingCfg -and $existingCfg.rateLimit) { $rate = [ordered]@{ perMinute = $existingCfg.rateLimit.perMinute; burst = $existingCfg.rateLimit.burst } }
$tokenPath = $null; if ($useToken) { $tokenPath = $TokenFile }

$cfgObj = [ordered]@{
  host = "127.0.0.1"; port = $Port; basePath = $BasePath
  appDir = $AppDir; keyFile = $KeyFile; logFile = $ServerLog
  upstream = "https://api.anthropic.com"; upstreamTimeoutMs = 120000; maxBodyBytes = 5242880
  trustProxy = $true; rateLimit = $rate; auth = $authObj
  autoUpdate = [ordered]@{ enabled = $autoUpdate; repo = $Repo; branch = $Branch; path = "index.html"; intervalSeconds = 120; tokenFile = $tokenPath; apiBase = "https://api.github.com" }
}
WriteText $ConfigFile ($cfgObj | ConvertTo-Json -Depth 5)

$c = Invoke-Native $NodeExe @($ServerJs, "--check")
if ($c.Code -ne 0) { Fail "Self-check failed:`n$($c.Out)" }
Ok $c.Out.Trim()

# ==================================================================
Step "4/7  App server (starts with Windows)"
# ==================================================================
$action   = New-ScheduledTaskAction -Execute $NodeExe -Argument ('"' + $ServerJs + '"') -WorkingDirectory $ServerDir
$triggers = @(
  (New-ScheduledTaskTrigger -AtStartup),
  (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1))  # revives it if it ever stops
)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$registered = $false; $lastErr = ""; $runAs = ""
foreach ($acct in @("NT AUTHORITY\LOCAL SERVICE", "LOCALSERVICE")) {
  try {
    $principal = New-ScheduledTaskPrincipal -UserId $acct -LogonType ServiceAccount -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal `
      -Description "Foresight Studio app server (C:\xperion). Managed by deploy\windows\setup.ps1" -Force | Out-Null
    $registered = $true; $runAs = $acct; break
  } catch { $lastErr = $_.Exception.Message }
}
if (-not $registered) { Fail "Could not register the startup task: $lastErr" }
Enable-ScheduledTask -TaskName $TaskName | Out-Null
Start-ScheduledTask -TaskName $TaskName

$health = $null
for ($i = 0; $i -lt 25; $i++) {
  Start-Sleep -Seconds 1
  $r = Get-Http @("http://127.0.0.1:$Port/healthz")
  if ($r.Code -eq "200") { $health = $r.Body | ConvertFrom-Json; break }
}
if (-not $health) {
  if (Test-Path $ServerLog) { Get-Content $ServerLog -Tail 15 | ForEach-Object { Write-Host "    $_" } }
  Fail "The app server didn't start. See the log lines above ($ServerLog)."
}
if (-not $health.keyConfigured) { Fail "The app server can't read the API key ($KeyFile). Check the folder permissions." }
Ok "App server running as $runAs on 127.0.0.1:$Port"

# ==================================================================
Step "5/7  Windows Firewall"
# ==================================================================
if (-not (Get-NetFirewallRule -DisplayName $FwRule -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName $FwRule -Direction Inbound -Protocol TCP -LocalPort 80, 443 -Action Allow -Profile Any | Out-Null
}
Ok "Inbound TCP 80/443 allowed (rule '$FwRule'). Azure NSG must allow them too."

# ==================================================================
Step "6/7  Caddy (HTTPS front door)"
# ==================================================================
$svc = Get-Service $SvcName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Stopped") { Stop-Service $SvcName -Force; Start-Sleep -Seconds 1 }

$needCaddy = $UpdateCaddy -or $CaddyExe -or -not (Test-Path $CaddyBin)
if ($needCaddy) {
  if ($CaddyExe) {
    if (-not (Test-Path $CaddyExe)) { Fail "-CaddyExe not found: $CaddyExe" }
    Copy-Item $CaddyExe $CaddyBin -Force
  } else {
    Info "Downloading Caddy (latest release from GitHub)..."
    try {
      $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/caddyserver/caddy/releases/latest" -Headers @{ "User-Agent" = "xperion-setup" }
    } catch { Fail "Couldn't reach GitHub to download Caddy. Download caddy.exe manually and re-run with -CaddyExe <path>." }
    $zipAsset = $rel.assets | Where-Object { $_.name -match '^caddy_[0-9.]+_windows_amd64\.zip$' } | Select-Object -First 1
    $sumAsset = $rel.assets | Where-Object { $_.name -match '_checksums\.txt$' } | Select-Object -First 1
    if (-not $zipAsset) { Fail "No Windows build found in Caddy's latest release. Download caddy.exe manually and re-run with -CaddyExe <path>." }
    $tmp = Join-Path $env:TEMP ("caddy-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    $zip = Join-Path $tmp $zipAsset.name
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing
    if ($sumAsset) {
      $sumFile = Join-Path $tmp "checksums.txt"
      Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sumFile -UseBasicParsing
      $line = Get-Content $sumFile | Where-Object { $_ -match [regex]::Escape($zipAsset.name) } | Select-Object -First 1
      if ($line) {
        $expected = ($line.Trim() -split '\s+')[0]
        $alg = "SHA512"; if ($expected.Length -eq 64) { $alg = "SHA256" }
        if ((Get-FileHash $zip -Algorithm $alg).Hash -ne $expected) { Fail "Caddy download failed its checksum. Try again." }
        Ok "Caddy $($rel.tag_name) downloaded, checksum verified"
      } else { Warn "Caddy checksum not listed; continuing with the GitHub download." }
    } else { Warn "Caddy checksums file not found; continuing with the GitHub download." }
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $exe = Get-ChildItem -Path $tmp -Filter "caddy.exe" -Recurse | Select-Object -First 1
    if (-not $exe) { Fail "caddy.exe not found in the download." }
    Copy-Item $exe.FullName $CaddyBin -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Ok "Caddy $((Invoke-Native $CaddyBin @('version')).Out.Trim().Split(' ')[0]) at $CaddyBin"

$fwd = { param($p) $p -replace '\\', '/' }
$siteAddr = ":80"; if ($Domain) { $siteAddr = $Domain }
$emailLine = ""; if ($Email) { $emailLine = "    email $Email`n" }
$cf = @"
# Generated by deploy\windows\setup.ps1 - re-run setup to change it.
{
    storage file_system {
        root $(& $fwd $CaddyDir)/data
    }
    log {
        output file $(& $fwd $LogsDir)/caddy.log {
            roll_size 10MiB
            roll_keep 5
        }
    }
$emailLine}

$siteAddr {
    encode zstd gzip
    log {
        output file $(& $fwd $LogsDir)/caddy-access.log {
            roll_size 10MiB
            roll_keep 5
        }
    }
    # More xPerion apps can sit beside Foresight Studio later, e.g.:
    # handle /intellisight* {
    #     reverse_proxy 127.0.0.1:8791
    # }
    handle {
        reverse_proxy 127.0.0.1:$Port
    }
}
"@
WriteText $Caddyfile $cf
Invoke-Native $CaddyBin @("fmt", "--overwrite", $Caddyfile) | Out-Null
$v = Invoke-Native $CaddyBin @("validate", "--config", $Caddyfile, "--adapter", "caddyfile")
if ($v.Code -ne 0) { Write-Host $v.Out; Fail "Caddy rejected the generated Caddyfile (see above)." }
Ok "Caddyfile valid ($Caddyfile)"

$binPath = '"' + $CaddyBin + '" run --config "' + $Caddyfile + '" --adapter caddyfile'
if (-not (Get-Service $SvcName -ErrorAction SilentlyContinue)) {
  New-Service -Name $SvcName -BinaryPathName $binPath -DisplayName "xPerion Web (Caddy)" `
    -Description "HTTPS front door for xPerion demos. Config: $Caddyfile" -StartupType Automatic | Out-Null
} else {
  Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$SvcName" -Name ImagePath -Value $binPath
  Set-Service -Name $SvcName -StartupType Automatic
}
Invoke-Native "sc.exe" @("failure", $SvcName, "reset=", "86400", "actions=", "restart/5000/restart/5000/restart/60000") | Out-Null
try { Start-Service $SvcName } catch {
  Warn "The Caddy service didn't start. To see why, run it in the foreground:"
  Warn "  & '$CaddyBin' run --config '$Caddyfile' --adapter caddyfile"
  Fail $_.Exception.Message
}
Ok "Caddy running as Windows service '$SvcName'"

# ==================================================================
Step "7/7  Smoke tests"
# ==================================================================
$failed = $false
$creds = @(); if ($authMode -eq "new") { $creds = @("-u", "${authUser}:$authPass") }
if ($Domain) {
  $site = "https://$Domain"
  $route = @("--connect-to", "${Domain}:443:127.0.0.1:443")
  $r = Get-Http @("--connect-to", "${Domain}:80:127.0.0.1:80", "http://$Domain$BasePath/")
  if ($r.Code -match '^30[178]$') { Ok "HTTP redirects to HTTPS" } else { Warn "Expected a redirect on http://, got HTTP $($r.Code)" }
  Info "Waiting for the HTTPS certificate (usually under a minute)..."
  $code = "000"
  for ($i = 0; $i -lt 18 -and $code -eq "000"; $i++) {
    $code = (Get-Http ($route + $creds + @("$site$BasePath/"))).Code
    if ($code -eq "000") { Start-Sleep -Seconds 5 }
  }
} else {
  $site = "http://127.0.0.1"
  $route = @()
}

$page = Get-Http ($route + $creds + @("$site$BasePath/"))
if ($authMode -eq "keep") {
  if ($page.Code -eq "401") { Ok "App is behind the existing login" } else { Warn "Expected 401 from $site$BasePath/, got HTTP $($page.Code)"; $failed = $true }
} elseif ($page.Code -eq "200" -and $page.Body -match 'FORESIGHT_PROXY') {
  Ok "App loads: $site$BasePath/"
} else {
  Warn "App page returned HTTP $($page.Code) at $site$BasePath/"
  if ($Domain -and $page.Code -eq "000") { Warn "No certificate yet. Check NSG ports 80/443 and the DNS label, then see $LogsDir\caddy.log" }
  $failed = $true
}

if ($authMode -ne "keep") {
  $cfgJs = Get-Http ($route + $creds + @("$site$BasePath/config.js"))
  if ($cfgJs.Body -match 'FORESIGHT_PROXY' -and $cfgJs.Body -notmatch 'sk-ant-[A-Za-z0-9_-]{20,}') { Ok "config.js has no key in it" }
  else { Warn "config.js check failed (HTTP $($cfgJs.Code))"; $failed = $true }

  $model = [regex]::Match($appText, 'var _MODEL="([^"]+)"').Groups[1].Value
  if (-not $model) { $model = "claude-sonnet-4-6" }
  $bodyFile = [IO.Path]::GetTempFileName()
  WriteText $bodyFile ('{"model":"' + $model + '","max_tokens":5,"messages":[{"role":"user","content":"Reply: ok"}]}')
  $api = Get-Http ($route + $creds + @("-X", "POST", "-H", "content-type: application/json", "-H", "anthropic-version: 2023-06-01",
                                       "--data-binary", "@$bodyFile", "$site$BasePath/api/v1/messages"))
  Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
  if ($api.Code -eq "200") { Ok "AI Engine reachable through the server (model: $model)" }
  else {
    $snippet = $api.Body; if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
    Warn "AI call returned HTTP $($api.Code): $snippet"
    if ($api.Code -eq "401") { Warn "401 = Anthropic rejected the key. Re-run setup and paste a valid key." }
    $failed = $true
  }
}

# ------------------------------------------------------------------ summary
$publicUrl = ""
if ($Domain) { $publicUrl = "https://$Domain$BasePath/" }
else {
  $ip = (Get-Http @("https://api.ipify.org")).Body.Trim()
  if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { $publicUrl = "http://$ip$BasePath/" } else { $publicUrl = "http://<vm-public-ip>$BasePath/" }
}
Write-Host ""
if (-not $failed) { Write-Host "  Foresight Studio is live:  $publicUrl" -ForegroundColor Green }
else { Write-Host "  Setup finished with warnings (see above). Target: $publicUrl" -ForegroundColor Yellow }
Write-Host ""
Write-Host "  Next:"
Write-Host "   - Azure NSG must allow inbound TCP 80 and 443 (MIGRATION.md, Phase 2)."
if ($autoUpdate) { Write-Host "   - Pushes to $Repo@$Branch go live within ~2 minutes (log: $ServerLog)." }
Write-Host "   - Rotate the key: re-run this script and answer 'n' to keeping the key."
if ($failed) { exit 1 }
