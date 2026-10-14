<#
.SYNOPSIS
  xPerion VM - set up or update the demo apps hosted on this Azure VM (Windows Server).

.DESCRIPTION
  Reads deploy\windows\apps.json (which apps, which GitHub repos, which use AI), then:
  1. Checks the VM (admin rights, Node, free ports, outbound access)
  2. Asks for the AI API key (and optional login / GitHub token)
  3. Installs the app server to C:\xperion and locks down permissions
  4. Registers the app server to start with Windows (runs as LOCAL SERVICE)
     and waits for every app to download from GitHub
  5. Opens Windows Firewall for 80/443
  6. Installs Caddy as the HTTPS front door (Windows service)
  7. Runs smoke tests for every app

  Safe to re-run: keeps the stored key, login, token, endpoint and model unless you
  replace them, and remembers -Domain, -Email, -Upstream and -Model for later runs.
  Also upgrades a single-app (Foresight-only) install from the first version.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\deploy\windows\setup.ps1 -Domain xperion2.centralindia.cloudapp.azure.com -Email you@coforge.com

.EXAMPLE
  Claude in Microsoft Foundry instead of the Anthropic API (remembered for later runs):
  ... setup.ps1 -Domain <name> -Upstream https://<resource>.services.ai.azure.com/anthropic -Model <deployment-name>
#>
[CmdletBinding()]
param(
  [string]$Domain = "",
  [string]$Email = "",
  [string]$Root = "C:\xperion",
  [int]$Port = 8790,
  [string]$Upstream = "",   # default https://api.anthropic.com; or https://<resource>.services.ai.azure.com/anthropic
  [string]$Model = "",      # pin every AI call to this model / Foundry deployment name
  [string]$AppsFile = "",   # default: apps.json next to this script
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
$ServerSrc  = Join-Path $KitDir "server.js"
if (-not $AppsFile) { $AppsFile = Join-Path $KitDir "apps.json" }
$ServerDir  = Join-Path $Root "server"
$AppsDir    = Join-Path $Root "apps"
$RuntimeDir = Join-Path $Root "runtime"
$SecretsDir = Join-Path $Root "secrets"
$LogsDir    = Join-Path $Root "logs"
$CaddyDir   = Join-Path $Root "caddy"
$KeyFile    = Join-Path $SecretsDir "ai.key"
$TokenFile  = Join-Path $SecretsDir "github.token"
$ConfigFile = Join-Path $ServerDir "config.json"
$ServerJs   = Join-Path $ServerDir "server.js"
$ServerLog  = Join-Path $LogsDir "app-server.log"
$NodeExe    = Join-Path $RuntimeDir "node.exe"
$CaddyBin   = Join-Path $CaddyDir "caddy.exe"
$Caddyfile  = Join-Path $CaddyDir "Caddyfile"
$TaskName   = "xPerion App Server"
$SvcName    = "xperion-web"
$FwRule     = "xPerion Web (HTTP/HTTPS)"
$Curl       = Join-Path $env:SystemRoot "System32\curl.exe"
# First version (Foresight only) - upgraded and cleaned up by this script
$LegacyDir    = Join-Path $Root "foresightstudio"
$LegacyConfig = Join-Path $LegacyDir "server\config.json"
$LegacyKey    = Join-Path $SecretsDir "anthropic.key"
$LegacyTask   = "xPerion Foresight Server"

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
    $name = "pid $($c.OwningProcess)"; $exe = ""
    if ($p) { $name = $p.Name; $exe = "$($p.ExecutablePath)" }
    $list += [pscustomobject]@{ Port = $c.LocalPort; Name = $name; Exe = $exe }
  }
  return $list
}

function Stop-OurNode {
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { "$($_.CommandLine)" -like "*$ServerDir*" -or "$($_.CommandLine)" -like "*$LegacyDir*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-Task([string]$Name) {
  if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
    Disable-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  }
}

function Get-Health { $h = Get-Http @("http://127.0.0.1:$Port/healthz"); if ($h.Code -eq "200") { return ($h.Body | ConvertFrom-Json) }; return $null }

# ==================================================================
Step "1/7  Pre-flight checks"
# ==================================================================
$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Fail "Run PowerShell as Administrator (right-click > Run as administrator)." }
foreach ($f in @($ServerSrc, $AppsFile)) { if (-not (Test-Path $f)) { Fail "Missing $f. Run this from the foresightstudio repo folder." } }
if (-not (Test-Path $Curl)) { Fail "curl.exe not found in System32." }
# App list
try { $manifest = [IO.File]::ReadAllText($AppsFile) | ConvertFrom-Json } catch { Fail "apps.json is not valid JSON: $($_.Exception.Message)" }
$apps = @($manifest.apps)
if ($apps.Count -eq 0) { Fail "apps.json lists no apps." }
$names = @{}
foreach ($a in $apps) {
  if ("$($a.name)" -notmatch '^[a-z0-9][a-z0-9-]*$') { Fail "apps.json: name '$($a.name)' must be lowercase letters, digits and dashes." }
  if ($names.ContainsKey($a.name)) { Fail "apps.json: '$($a.name)' is listed twice." }
  $names[$a.name] = $true
  if ("$($a.repo)" -notmatch '^[\w.-]+/[\w.-]+$') { Fail "apps.json: repo for '$($a.name)' must look like owner/name." }
  if ($a.proxyVar -and "$($a.proxyVar)" -notmatch '^[A-Za-z_$][\w$]*$') { Fail "apps.json: proxyVar for '$($a.name)' must be a JavaScript name." }
  foreach ($al in @($a.aliases)) {
    if (-not $al) { continue }
    if ("$al" -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Fail "apps.json: alias '$al' for '$($a.name)' must be letters, digits, dots and dashes." }
    if ($names.ContainsKey("$al")) { Fail "apps.json: '$al' is used twice." }
    $names["$al"] = $true
  }
}
$aiApps = @($apps | Where-Object { $_.proxyVar })
Ok "$($apps.Count) app(s) in $AppsFile`: $(($apps | ForEach-Object { $_.name }) -join ', ')"

# Previous settings (this version, or the first Foresight-only version)
$existingCfg = $null
foreach ($p in @($ConfigFile, $LegacyConfig)) {
  if (-not $existingCfg -and (Test-Path $p)) { try { $existingCfg = [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { } }
}
$isUpgrade = (Test-Path $LegacyDir) -and -not (Test-Path $ConfigFile)
if ($isUpgrade) { Info "Upgrading the Foresight-only install to the multi-app layout" }

if (-not $Domain -and $existingCfg -and $existingCfg.domain) { $Domain = "$($existingCfg.domain)" }
if (-not $Email -and $existingCfg -and $existingCfg.email) { $Email = "$($existingCfg.email)" }
if ($Domain -and $Domain -notmatch '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { Fail "-Domain should be a host name like xperion2.centralindia.cloudapp.azure.com" }
if ($Domain) { Ok "Domain: $Domain" } else { Warn "No -Domain given: the apps will be served over plain HTTP by IP address." }

if (-not $Upstream) { if ($existingCfg -and $existingCfg.upstream) { $Upstream = "$($existingCfg.upstream)" } else { $Upstream = "https://api.anthropic.com" } }
$Upstream = ($Upstream.Trim() -replace '/+$', '') -replace '/v1/messages$', '' -replace '/v1$', ''
$Upstream = $Upstream -replace '/+$', ''
if ($Upstream -notmatch '^https://[A-Za-z0-9.-]+(:\d+)?(/[A-Za-z0-9._~-]+)*$') { Fail "-Upstream must be an https URL like https://<resource>.services.ai.azure.com/anthropic" }
if (-not $Model -and $existingCfg -and $existingCfg.model) { $Model = "$($existingCfg.model)" }
if ($Model -and $Model -notmatch '^[A-Za-z0-9._:-]+$') { Fail "-Model should be a model or deployment name like claude-sonnet-5-5" }
$isAnthropic = ($Upstream -eq "https://api.anthropic.com")
$aiName = "Anthropic"; if (-not $isAnthropic) { $aiName = ([Uri]$Upstream).Host }
$modelNote = "model from each app"; if ($Model) { $modelNote = "model pinned to $Model" }
Ok "AI endpoint: $Upstream/v1/messages ($modelNote)"

$nodeCmd = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $nodeCmd) { Fail "Node.js not found. Install Node 22 LTS or newer, then re-run." }
$nodeSrc = $nodeCmd.Path
if ([IO.Path]::GetExtension($nodeSrc) -ne ".exe") { Fail "node resolves to $nodeSrc (a shim). Point PATH at a real node.exe." }
$nodeVer = (Invoke-Native $nodeSrc @("-v")).Out.Trim()
$vParts = $nodeVer.TrimStart("v").Split(".")
if ([int]$vParts[0] -lt 20 -or ([int]$vParts[0] -eq 20 -and [int]$vParts[1] -lt 3)) { Fail "Node $nodeVer is too old. Install Node 22 LTS or newer." }
Ok "Node $nodeVer"

# Stop the running app server (this version or the first one) so files and the port are free
Stop-Task $TaskName
Stop-Task $LegacyTask
Stop-OurNode
Start-Sleep -Seconds 1

foreach ($l in (Get-Listeners @(80, 443))) {
  if ($l.Exe -ne $CaddyBin) { Fail "Port $($l.Port) is already used by $($l.Name) ($($l.Exe)). Stop it or share this message." }
}
foreach ($l in (Get-Listeners @($Port))) { Fail "Port $Port is used by $($l.Name). Re-run with -Port 8791 (or another free port)." }
Ok "Ports 80, 443 and $Port are available"

if ($aiApps.Count -gt 0) {
  $r = Get-Http @("-I", "$Upstream/v1/messages")
  if ($r.Code -eq "000") { Fail "This VM can't reach $Upstream (outbound 443 blocked, or a private-only endpoint?)." }
  Ok "Outbound access to $aiName works"
}

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
# API key (shared by every app that uses AI)
$key = "$env:FS_API_KEY".Trim()
$keepKey = $false
$haveKey = (Test-Path $KeyFile) -or (Test-Path $LegacyKey)
if ($aiApps.Count -eq 0) { $keepKey = $true }
elseif (-not $key -and $haveKey) { $keepKey = YesNo "An API key is already stored on this VM. Keep it?" $true }
if (-not $key -and -not $keepKey) {
  if ($isAnthropic) {
    Write-Host "    Paste the Anthropic API key for this VM (input hidden)."
  } else {
    Write-Host "    Paste the API key for $aiName (input hidden)."
    Write-Host "    Find it in the Foundry portal (your deployment > Details > Key) or Azure portal > resource > Keys and Endpoint."
  }
  $key = (ToPlain (Read-Host "    API key" -AsSecureString)).Trim()
}
if (-not $keepKey) {
  if ($isAnthropic -and $key -notmatch '^sk-ant-[A-Za-z0-9_-]{20,}$') { Fail "That doesn't look like an Anthropic key (expected sk-ant-...)." }
  if (-not $isAnthropic -and $key -notmatch '^[A-Za-z0-9._~+/=-]{20,}$') { Fail "That doesn't look like an API key (20+ letters/digits, no spaces)." }
}

# Optional login (applies to every app)
$authMode = "off"; $authUser = ""; $authPass = ""
if ($existingCfg -and $existingCfg.auth) {
  if (YesNo "Login is on (user '$($existingCfg.auth.user)'). Keep it?" $true) { $authMode = "keep" }
  elseif (YesNo "Set a new login instead? (No = turn the login off)" $true) { $authMode = "new" }
} elseif (YesNo "Require a username/password to open the apps? (recommended if links will circulate widely)" $false) {
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

# GitHub access for every repo
$private = @()
foreach ($a in $apps) {
  # git's own protocol: not subject to GitHub's 60-per-hour REST API limit
  $gh = Get-Http @("-A", "git/2.45.0", "https://github.com/$($a.repo).git/info/refs?service=git-upload-pack")
  if ($gh.Code -eq "401" -or $gh.Code -eq "404") { $private += "$($a.repo)" }
  elseif ($gh.Code -ne "200") { Warn "Couldn't check $($a.repo) on GitHub (HTTP $($gh.Code)). The server will keep retrying." }
}
$useToken = $false; $newToken = ""
if ($private.Count -gt 0) {
  $tok = ""; if (Test-Path $TokenFile) { $tok = [IO.File]::ReadAllText($TokenFile).Trim() }
  $tokOk = $false
  if ($tok) {
    $tokOk = $true
    foreach ($rp in $private) { if ((Get-Http @("-A", "git/2.45.0", "-u", "x-access-token:$tok", "https://github.com/$rp.git/info/refs?service=git-upload-pack")).Code -ne "200") { $tokOk = $false } }
  }
  if (-not $tokOk) {
    Write-Host "    These repos are private or don't exist yet: $($private -join ', ')"
    Write-Host "    Paste a fine-grained GitHub token with read-only 'Contents' access to them,"
    Write-Host "    or press Enter to skip (the other apps still deploy)."
    $tok = (ToPlain (Read-Host "    GitHub token" -AsSecureString)).Trim()
    if ($tok) {
      foreach ($rp in $private) {
        $chk = Get-Http @("-A", "git/2.45.0", "-u", "x-access-token:$tok", "https://github.com/$rp.git/info/refs?service=git-upload-pack")
        if ($chk.Code -ne "200") { Fail "That token can't read $rp (HTTP $($chk.Code)). Check the repo name in apps.json and the token's access." }
      }
      $newToken = $tok; $tokOk = $true
    }
  }
  if ($tokOk) { $useToken = $true; Ok "GitHub token works for the private repo(s)" }
  else { Warn "No token: $($private -join ', ') won't deploy until the repo exists and is public (or re-run with a token)." }
} else {
  Ok "No private repos found: no GitHub token needed"
}
Ok "Settings captured"

# ==================================================================
Step "3/7  Files and permissions"
# ==================================================================
$dirs = @($Root, $ServerDir, $AppsDir, $RuntimeDir, $SecretsDir, $LogsDir, $CaddyDir, (Join-Path $CaddyDir "data"))
foreach ($a in $apps) { $dirs += (Join-Path $AppsDir $a.name) }
foreach ($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
# C:\xperion: admins + SYSTEM full, app server (LOCAL SERVICE) read-only
Set-Acl2 $Root @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F", "${SidLocalSvc}:(OI)(CI)RX")
# It mirrors the apps from GitHub and writes logs
Set-Acl2 $AppsDir @("/grant:r", "${SidLocalSvc}:(OI)(CI)M")
Set-Acl2 $LogsDir @("/grant:r", "${SidLocalSvc}:(OI)(CI)M", "${SidUsers}:(OI)(CI)RX")
# Secrets: readable by the app server only; Caddy's TLS keys: admins + SYSTEM only
Set-Acl2 $SecretsDir @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F", "${SidLocalSvc}:(OI)(CI)R")
Set-Acl2 $CaddyDir @("/inheritance:r", "/grant:r", "${SidAdmins}:(OI)(CI)F", "${SidSystem}:(OI)(CI)F")
Ok "Folders under $Root locked down"

Copy-Item $nodeSrc $NodeExe -Force
Copy-Item $ServerSrc $ServerJs -Force
Ok "App server and Node runtime installed"

# Upgrade from the Foresight-only install: copy the live Foresight page across first,
# so it keeps serving even before the first GitHub download completes.
$fsNewIdx = Join-Path (Join-Path $AppsDir "foresightstudio") "index.html"
$fsOldIdx = Join-Path $LegacyDir "app\index.html"
if ((Test-Path $fsOldIdx) -and (Test-Path (Split-Path $fsNewIdx)) -and -not (Test-Path $fsNewIdx)) {
  Copy-Item $fsOldIdx $fsNewIdx -Force
  Ok "Foresight carried over as-is (same page, same address)"
}

if (-not $keepKey) { WriteText $KeyFile $key }
elseif (-not (Test-Path $KeyFile) -and (Test-Path $LegacyKey)) { Move-Item $LegacyKey $KeyFile -Force }
if ((Test-Path $LegacyKey) -and (Test-Path $KeyFile)) { Remove-Item $LegacyKey -Force }
if ($newToken) { WriteText $TokenFile $newToken }
if ($aiApps.Count -gt 0 -and -not (Test-Path $KeyFile)) { Fail "No API key stored. Re-run and paste the key." }
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
$modelVal = $null; if ($Model) { $modelVal = $Model }
$domainVal = $null; if ($Domain) { $domainVal = $Domain }
$emailVal = $null; if ($Email) { $emailVal = $Email }
$rootRedirect = "/$($apps[0].name)/"; if ($manifest.rootRedirect) { $rootRedirect = "$($manifest.rootRedirect)" }

$cfgApps = @()
foreach ($a in $apps) {
  $branch = "main"; if ($a.branch) { $branch = "$($a.branch)" }
  $pv = $null; if ($a.proxyVar) { $pv = "$($a.proxyVar)" }
  $al = @(); foreach ($x in @($a.aliases)) { if ($x) { $al += "$x" } }
  $cfgApps += [ordered]@{ name = "$($a.name)"; basePath = "/$($a.name)"; appDir = (Join-Path $AppsDir $a.name); repo = "$($a.repo)"; branch = $branch; proxyVar = $pv; aliases = $al }
}
$cfgObj = [ordered]@{
  host = "127.0.0.1"; port = $Port; domain = $domainVal; email = $emailVal
  logFile = $ServerLog; keyFile = $KeyFile; rootRedirect = $rootRedirect
  upstream = $Upstream; model = $modelVal; upstreamTimeoutMs = 120000; maxBodyBytes = 5242880
  trustProxy = $true; rateLimit = $rate; auth = $authObj
  github = [ordered]@{ apiBase = "https://api.github.com"; tokenFile = $tokenPath; intervalSeconds = 120 }
  apps = $cfgApps
}
WriteText $ConfigFile ($cfgObj | ConvertTo-Json -Depth 6)

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
      -Description "xPerion demo apps server ($Root). Managed by deploy\windows\setup.ps1" -Force | Out-Null
    $registered = $true; $runAs = $acct; break
  } catch { $lastErr = $_.Exception.Message }
}
if (-not $registered) { Fail "Could not register the startup task: $lastErr" }
Enable-ScheduledTask -TaskName $TaskName | Out-Null
Start-ScheduledTask -TaskName $TaskName

$health = $null
for ($i = 0; $i -lt 25 -and -not $health; $i++) { Start-Sleep -Seconds 1; $health = Get-Health }
if (-not $health) {
  if (Test-Path $ServerLog) { Get-Content $ServerLog -Tail 15 | ForEach-Object { Write-Host "    $_" } }
  Fail "The app server didn't start. See the log lines above ($ServerLog)."
}
if ($aiApps.Count -gt 0 -and -not $health.keyConfigured) { Fail "The app server can't read the API key ($KeyFile). Check the folder permissions." }
Ok "App server running as $runAs on 127.0.0.1:$Port"

Info "Downloading the apps from GitHub (large datasets can take a minute)..."
$deadline = (Get-Date).AddSeconds(240)
do {
  Start-Sleep -Seconds 3
  $health = Get-Health
  $pending = @()
  if ($health) { $pending = @($health.apps | Where-Object { -not $_.synced -and -not $_.error }) }
} while ($health -and $pending.Count -gt 0 -and (Get-Date) -lt $deadline)
if (-not $health) { Fail "The app server stopped responding. See $ServerLog" }
$failed = $false
$deployed = @{}
foreach ($a in @($health.apps)) {
  if ($a.synced -and -not $a.error) { Ok "$($a.name) deployed ($($a.synced.Substring(0, 7)))"; $deployed[$a.name] = $true }
  elseif ($a.synced) { Warn "$($a.name): serving the last good version; latest change not applied: $($a.error)"; $deployed[$a.name] = $true }
  elseif (Test-Path (Join-Path (Join-Path $AppsDir $a.name) "index.html")) { Warn "$($a.name): serving the existing copy; GitHub check will retry: $($a.error)"; $deployed[$a.name] = $true }
  elseif ($a.error) { Warn "$($a.name) not deployed: $($a.error)"; $failed = $true }
  else { Warn "$($a.name) still downloading; it will finish in the background (log: $ServerLog)"; $failed = $true }
}

if (Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $LegacyTask -Confirm:$false
  Ok "Removed the old task '$LegacyTask'"
}
if ((Test-Path $LegacyDir) -and (Test-Path $fsNewIdx)) {
  Remove-Item $LegacyDir -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $LegacyDir)) { Ok "Removed the old folder $LegacyDir" } else { Warn "Couldn't fully remove $LegacyDir; delete it later." }
}

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
# Every app is served by the app server; the list of apps lives in deploy\windows\apps.json.
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
$creds = @(); if ($authMode -eq "new") { $creds = @("-u", "${authUser}:$authPass") }
$first = "/$($apps[0].name)/"
if ($Domain) {
  $site = "https://$Domain"
  $route = @("--connect-to", "${Domain}:443:127.0.0.1:443")
  $r = Get-Http @("--connect-to", "${Domain}:80:127.0.0.1:80", "http://$Domain$first")
  if ($r.Code -match '^30[178]$') { Ok "HTTP redirects to HTTPS" } else { Warn "Expected a redirect on http://, got HTTP $($r.Code)" }
  Info "Checking the HTTPS certificate..."
  $code = "000"
  for ($i = 0; $i -lt 18 -and $code -eq "000"; $i++) {
    $code = (Get-Http ($route + $creds + @("$site$first"))).Code
    if ($code -eq "000") { Start-Sleep -Seconds 5 }
  }
  if ($code -eq "000") { Warn "No HTTPS certificate yet. Check NSG ports 80/443 and the DNS label, then see $LogsDir\caddy.log" }
} else {
  $site = "http://127.0.0.1"
  $route = @()
}

$bodyFile = [IO.Path]::GetTempFileName()
foreach ($a in $apps) {
  if (-not $deployed[$a.name]) { continue }
  $base = "$site/$($a.name)"
  $page = Get-Http ($route + $creds + @("$base/"))
  if ($authMode -eq "keep") {
    if ($page.Code -eq "401") { Ok "$($a.name): behind the existing login" } else { Warn "$($a.name): expected 401, got HTTP $($page.Code)"; $failed = $true }
    continue
  }
  if ($page.Code -eq "200" -and $page.Body -match '</html>') { Ok "$($a.name): page loads" }
  else { Warn "$($a.name): page returned HTTP $($page.Code) at $base/"; $failed = $true; continue }
  if (-not $a.proxyVar) { continue }

  $cfgJs = Get-Http ($route + $creds + @("$base/config.js"))
  if ($cfgJs.Body -match [regex]::Escape($a.proxyVar) -and $cfgJs.Body -notmatch 'sk-ant-[A-Za-z0-9_-]{20,}') { Ok "$($a.name): config.js has no key in it" }
  else { Warn "$($a.name): config.js check failed (HTTP $($cfgJs.Code))"; $failed = $true }

  $appModel = ""
  $idx = Join-Path (Join-Path $AppsDir $a.name) "index.html"
  if (Test-Path $idx) { $appModel = [regex]::Match([IO.File]::ReadAllText($idx), '\b_?MODEL\s*=\s*[''"]([^''"]+)[''"]').Groups[1].Value }
  if (-not $appModel) { $appModel = "claude-sonnet-4-6" }
  $usedModel = $appModel; if ($Model) { $usedModel = $Model }
  WriteText $bodyFile ('{"model":"' + $appModel + '","max_tokens":5,"messages":[{"role":"user","content":"Reply: ok"}]}')
  $api = Get-Http ($route + $creds + @("-X", "POST", "-H", "content-type: application/json", "-H", "anthropic-version: 2023-06-01",
                                       "--data-binary", "@$bodyFile", "$base/api/v1/messages"))
  if ($api.Code -eq "200") { Ok "$($a.name): AI Engine reachable ($aiName, model: $usedModel)" }
  else {
    $snippet = $api.Body; if ($snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
    Warn "$($a.name): AI call returned HTTP $($api.Code): $snippet"
    if ($api.Code -eq "401") { Warn "401 = $aiName rejected the key. Re-run setup and paste a valid key." }
    if ($api.Code -eq "404" -and -not $isAnthropic) { Warn "404 on Foundry usually means the deployment name is wrong. Re-run with -Model <exact deployment name>." }
    $failed = $true
  }
}
Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ summary
$publicBase = ""
if ($Domain) { $publicBase = "https://$Domain" }
else {
  $ip = (Get-Http @("https://api.ipify.org")).Body.Trim()
  if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { $publicBase = "http://$ip" } else { $publicBase = "http://<vm-public-ip>" }
}
Write-Host ""
if (-not $failed) { Write-Host "  All apps are live:" -ForegroundColor Green }
else { Write-Host "  Setup finished with warnings (see above). Apps:" -ForegroundColor Yellow }
foreach ($a in $apps) {
  $mark = "  "; if ($deployed[$a.name]) { $mark = "* " }
  Write-Host "   $mark$publicBase/$($a.name)/"
}
Write-Host ""
Write-Host "  Next:"
Write-Host "   - Pushes to each app's repo go live within ~2 minutes (log: $ServerLog)."
Write-Host "   - Add or remove apps: edit deploy\windows\apps.json, push, re-download and re-run this script."
Write-Host "   - Rotate the key: re-run this script and answer 'n' to keeping the key."
if ($failed) { exit 1 }
