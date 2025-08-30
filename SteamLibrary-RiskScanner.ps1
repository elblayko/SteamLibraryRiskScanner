<#
================================================================================
  SteamLibrary-RiskScanner.ps1
  -------------------------------------------------------------------------------
  Purpose:
    - Scans your public Steam library (no API key required).
    - Lets you choose what to detect:
        - Chinese origin (dev/pub/title/CJK)
        - DRM & 3rd-party account/launcher
        - Anti-cheat (incl. kernel-level heuristics)
    - Computes a RiskScore (0-10) + RiskFactors summary for review priority.
    - Exports to HTML by default; CSV optional.

  RiskScore (0-10):
    - Strong Chinese origin (dev/pub/title/CJK): +5
    - Chinese language (full audio, '*'): +2
    - Chinese language supported (no full audio): +1
    - Kernel-level anti-cheat present/mentioned: +4
    - Non-kernel anti-cheat vendor present: +1
    - DRM: Denuvo +2, other DRM +1
    - Third-party account/launcher: +1
    - Trusted U.S. dev/publisher detected: -1 (floored at 0)
    - Cap at 10; if no signals, score = 0

  Features:
    - Pure CLI wizard or command-line parameters.
    - Default HTML path is auto-generated; CSV is optional.
    - HTTP 429 handling with exponential backoff + progress bar.
    - Dedupes app IDs; cleans HTML in language/notice fields.
    - Cache-first store lookups with atomic JSON cache file (steam_scan.json).
    - True CSV export (sortable/filterable in Excel).
    - Suppresses flickery progress UI from web requests.
    - Polite exit pauses (disable with -NoPause).
    - Prints a ready-to-copy CLI command to repeat this exact scan (no files saved).

  Usage:
    # Wizard (default on no args) - writes HTML; prompts whether to also write CSV
    .\SteamLibrary-RiskScanner.ps1 -Wizard

    # CLI - HTML auto if -OutHtml omitted; CSV only if you pass -OutCsv
    .\SteamLibrary-RiskScanner.ps1 -SteamID64 76561198000000000 -UseCache -OnlyFlagged -ScanChinese -ScanDRM -ScanKernelAC -OutCsv .\report.csv

  Requirements:
    - Windows PowerShell 5.1
    - Steam profile "Game details" set to Public

  Attribution:
    Script drafted with assistance from OpenAI's ChatGPT.
    Polished and heavily "vibe-coded" for practical use.

  Disclaimer:
    - Community tool; not affiliated with Valve.
    - Keyword/title lists and heuristics are evolving; verify before acting on results.
================================================================================
#>

param(
  [string]$Vanity,
  [string]$SteamID64,
  [string]$OutCsv,
  [string]$OutHtml,
  [int]$DelayMsBetweenStoreCalls = 400,
  [switch]$OnlyFlagged,
  [switch]$Wizard,
  [switch]$UseCache,
  [string]$CacheFile = ".\steam_scan.json",
  [switch]$NoPause,

  # Choose checks via CLI (if none provided, defaults to ALL when not using wizard)
  [switch]$ScanChinese,
  [switch]$ScanDRM,
  [switch]$ScanKernelAC
)

# Hide built-in progress bars from Invoke-WebRequest / Invoke-RestMethod
$ProgressPreference = 'SilentlyContinue'

# Ensure TLS 1.2 (older Windows boxes)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Auto-launch wizard if no parameters were provided
if (-not $PSBoundParameters.Keys.Count) { $Wizard = $true }

# ---------------- Exit/Console Helpers ----------------
function Should-Pause {
  param([switch]$OnError)
  if ($NoPause) { return $false }
  if ($Host.Name -ne 'ConsoleHost') { return $false }
  if ($OnError) { return $true }
  return $true
}
function Exit-WithPause {
  param([int]$Code = 0, [string]$Message = $null, [switch]$OnError)
  if ($Message) { if ($OnError) { Write-Error $Message } else { Write-Host $Message } }
  if (Should-Pause -OnError:$OnError) { [void](Read-Host "`nPress Enter to exit...") }
  exit $Code
}
function Get-ScriptPath {
  if ($PSCommandPath) { return $PSCommandPath }
  if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
  return ".\SteamLibrary-RiskScanner.ps1"
}

# ---------------- UI Helpers (CLI only) ----------------
function Prompt-YesNo {
  param([string]$Message, [switch]$DefaultYes)
  $def = $(if ($DefaultYes) {'Y'} else {'N'})
  while ($true) {
    $ans = Read-Host "$Message (Y/N) [Default: $def]"
    if ([string]::IsNullOrWhiteSpace($ans)) { return ($def -eq 'Y') }
    switch -regex ($ans.Trim()) {
      '^(y|yes)$' { return $true }
      '^(n|no)$'  { return $false }
      default     { Write-Warning "Please answer Y or N." }
    }
  }
}
function Prompt-Menu {
  param([string]$Title, [string[]]$Options, [int]$DefaultIndex = 0)
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  for ($i=0; $i -lt $Options.Count; $i++) {
    $star = if ($i -eq $DefaultIndex) { "*" } else { " " }
    Write-Host (" [{0}] {1} {2}" -f $i, $Options[$i], $star)
  }
  while ($true) {
    $raw = Read-Host ("Enter choice number [Default: {0}]" -f $DefaultIndex)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultIndex }
    if ($raw -match '^\d+$') {
      $n = [int]$raw
      if ($n -ge 0 -and $n -lt $Options.Count) { return $n }
    }
    Write-Warning ("Enter 0-{0}." -f ($Options.Count-1))
  }
}
function Prompt-IntInRange {
  param([string]$Message, [int]$Min = 0, [int]$Max = 2000, [int]$Default = 400)
  while ($true) {
    $raw = Read-Host "$Message [$Default]"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    $n = 0
    if ([int]::TryParse($raw, [ref]$n)) {
      if ($n -ge $Min -and $n -le $Max) { return $n }
      Write-Warning "Enter an integer between $Min and $Max."
    } else { Write-Warning "Enter numbers only (no units or punctuation)." }
  }
}
function Prompt-String {
  param([string]$Message, [string]$Default = $null, [scriptblock]$Validate = { param($v) $true })
  while ($true) {
    $prompt = if ($null -ne $Default) { "$Message [$Default]" } else { $Message }
    $raw = Read-Host $prompt
    $val = if ([string]::IsNullOrWhiteSpace($raw) -and $null -ne $Default) { $Default } else { $raw }
    try { if (& $Validate $val) { return $val } } catch { Write-Warning $_.Exception.Message }
  }
}

# ------------- Backoff Progress Bar -------------
function Show-BackoffProgress {
  param([double]$TotalSeconds, [string]$Activity = "Steam rate-limit backoff", [string]$StatusPrefix = "Too many requests; waiting")
  if ($TotalSeconds -lt 0.25) { return }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    while ($sw.Elapsed.TotalSeconds -lt $TotalSeconds) {
      $elapsed   = $sw.Elapsed.TotalSeconds
      $remaining = [math]::Max(0, $TotalSeconds - $elapsed)
      $pct       = [math]::Min(100, [math]::Max(0, ($elapsed / $TotalSeconds) * 100))
      Write-Progress -Activity $Activity -Status ("{0}... {1:N1}s remaining" -f $StatusPrefix, $remaining) -PercentComplete $pct -SecondsRemaining ([int][math]::Ceiling($remaining))
      Start-Sleep -Milliseconds 200
    }
  } finally { Write-Progress -Activity $Activity -Completed }
}

# ---------------- HTTP Helper with 429 Backoff ----------------
function Invoke-Get {
  param([Parameter(Mandatory=$true)][string]$Uri, [int]$Retries = 6, [int]$DelayMs = 300)
  $headers = @{
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell-SteamScan/2.6"
    "Accept"      = "*/*"
  }
  for ($i = 0; $i -lt $Retries; $i++) {
    try {
      return Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $headers -TimeoutSec 30
    } catch {
      $resp = $null; $status = $null
      try { $resp = $_.Exception.Response } catch {}
      if ($resp) { try { $status = [int]$resp.StatusCode.value__ } catch {} }

      if ($status -eq 429) {
        $retryAfterSec = 0.0
        try {
          $ra = $resp.Headers["Retry-After"]
          if ($ra) {
            [int]$secs = 0
            if ([int]::TryParse($ra, [ref]$secs)) { $retryAfterSec = [double]$secs }
            else {
              [datetime]$dt = $null
              if ([datetime]::TryParse($ra, [ref]$dt)) { $retryAfterSec = [math]::Max(1.0, ($dt - [datetime]::UtcNow).TotalSeconds) }
            }
          }
        } catch {}
        if ($retryAfterSec -le 0) { $retryAfterSec = [Math]::Min(90, [Math]::Pow(2, [Math]::Min($i+1, 6))) + (Get-Random -Minimum 0 -Maximum 1) }
        Show-BackoffProgress -TotalSeconds $retryAfterSec -Activity "Steam rate-limit backoff" -StatusPrefix "HTTP 429"
        continue
      }

      if ($i -lt ($Retries-1)) { Start-Sleep -Milliseconds $DelayMs; continue }
      throw
    }
  }
}

# ---------------- Steam Helpers ----------------
function Resolve-SteamID64FromVanity {
  param([string]$Vanity)
  $u = "https://steamcommunity.com/id/$([uri]::EscapeDataString($Vanity))/?xml=1"
  $resp = Invoke-Get -Uri $u
  try { [xml]$xml = $resp.Content } catch { throw "Failed to parse vanity XML for '$Vanity'." }
  $id = $xml.profile.steamID64
  if (-not $id) { throw "Could not find steamID64 in vanity XML (profile private or invalid)." }
  return $id
}
function Get-XmlText { param($node)
  if ($null -eq $node) { return $null }
  if ($node.PSObject.Properties['#text']) { return [string]$node.'#text' }
  if ($node.PSObject.Properties['InnerText']) { return [string]$node.InnerText }
  if ($node.PSObject.Properties['InnerXml']) { return ([string]$node.InnerXml -replace '<.*?>','') }
  return [string]$node
}
function Get-PublicGames {
  param([string]$SteamID64)
  $u = "https://steamcommunity.com/profiles/$SteamID64/games?tab=all&xml=1"
  $resp = Invoke-Get -Uri $u
  try { [xml]$xml = $resp.Content } catch { throw "Failed to parse games XML. Is the profile public?" }
  if (-not $xml.gamesList -or -not $xml.gamesList.games) { throw "No games list found. Ensure your Game Details are set to Public." }
  $ids = [System.Collections.Generic.HashSet[int]]::new()
  $games = New-Object System.Collections.ArrayList
  foreach ($g in $xml.gamesList.games.game) {
    $id = [int]$g.appID
    if (-not $ids.Contains($id)) {
      $null = $ids.Add($id)
      [void]$games.Add([pscustomobject]@{ AppID = $id; Name = Get-XmlText $g.name })
    }
  }
  return ,$games
}

# ---------------- JSON helpers ----------------
function ConvertFrom-JsonCompat { param([Parameter(Mandatory=$true)][string]$Json)
  if (Get-Command ConvertFrom-Json -ErrorAction SilentlyContinue) { return $Json | ConvertFrom-Json }
  Add-Type -AssemblyName System.Web.Extensions
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  return $ser.DeserializeObject($Json)
}
function Get-JsonProp { param($obj, [string]$Name)
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) { return $obj[$Name] }
  $p = $obj.PSObject.Properties[$Name]; if ($p) { return $p.Value } else { return $null }
}

# ---------------- In-memory Cache ----------------
if (-not (Get-Variable -Name AppCache -Scope Script -ErrorAction SilentlyContinue)) { $script:AppCache = @{} }

# --------------- Origin Signals ---------------
$Global:BaseCNKeywords = @(
  # Giants
  'tencent','netease','mihoyo','hoyoverse','perfect world','bilibili','seasun','cmge','papergames',
  'yostar','hypergryph','lilith','kuro games','game science','lemtree','gryphline',

  # Sub-brands / subsidiaries / alt names
  'xd network','xd inc','x.d. network','xindong',
  '24 entertainment','tiancity','qingci','droidhang','tap4fun','wangyuan shengtang',
  'lemon jam','paper studio','s-game','wildfire game',

  # Other major / mid-tier studios
  'pathea','pathea games','suriyun','kugetsu',
  'lemon jam studio','pixmain','gamera games','toge productions china','thermite games','celadon',
  'cmge group','cmge entertainment','guangzhou duoyi','duoyi network','xishanju','seasun entertainment',
  'boke technology','boke game','irisloft','yunchang game','yunchang technology',

  # Known indie / popular on Steam
  'spark games','neowiz china','glass heart games','chillyroom','miniclip china','xd global',
  'red candle games cn','fabled game studio','white matrix','heartbeat plus','snail games','snail digital',
  'kong studio','pal company','softstar (china)','domo studio (china)','island party games',
  'aquiris china','feiyu technology','superprism games','xd corp','patriot games studio'

  # Extra catch-alls (common in publisher names)
  #'shanghai','beijing','guangzhou','chengdu','shenzhen'
)

# ---------------- Known Chinese Games ----------------
$Global:KnownChineseGames = @(
  "AI Limit","Amazing Cultivation Simulator","Anno: Mutationem","Arise of Awakener",
  "Arena of Valor","Badlanders","Black Myth: Wukong","Boundary","Bright Memory",
  "Bright Memory: Infinite","Broken Delusion","Call of Duty: Mobile","Candleman",
  "Chinese Parents","Chinese Parents 2","Code: Hardcore","Convallaria","CrossFire",
  "CrossFireX","Dyson Sphere Program","Eggy Party","Ever Forward","Faith of Danschant",
  "Faith of Danschant 2","F.I.S.T.: Forged In Shadow Torch","Genshin Impact","GuJian",
  "GuJian 3","Hardcore Mecha","Hero’s Adventure","Honor of Kings","Honkai Impact 3rd",
  "Honkai: Star Rail","ICEY","Identity V","Infinite Lagrange","Justice Online",
  "Lost Castle","Metal Revolution","Moonlight Blade","My Time at Portia",
  "My Time at Sandrock","Naraka: Bladepoint","Onmyoji","Oriental Sword Legend",
  "Paper Bride","Paper Bride 2","Paper Bride 3","Paper Bride 4","Peacekeeper Elite",
  "Planet Explorers","Project Mugen","Project: The Perceiver","PUBG Mobile",
  "QQ Speed","Ring of Elysium","Showa American Story","Sword and Fairy",
  "Sword and Fairy 7","Sword and Fairy Inn","Sword and Fairy: Together Forever",
  "Sword of Convallaria","Tale of Immortal","The Immortal Mayor","The Rewinder",
  "The Scroll of Taiwu","Volcano Princess","Westward Journey Online","Where Winds Meet",
  "World of Cultivation","Xuan-Yuan Sword VII","Xuan-Yuan Sword: The Clouds Faraway",
  "Xuan-Yuan Sword: The Gate of Firmament","Zenless Zone Zero"
)

# ---------------- Trusted U.S. companies (confidence reducer) ---------------
$Global:TrustedUSCompanies = @(
  '2K','2K Games','2K Sports','Activision','Activision Publishing','Arkane Studios',
  'Avalanche Software','Bethesda','Bethesda Game Studios','Bethesda Softworks',
  'Blizzard','Blizzard Entertainment','Bungie','Bungie Inc.','Bungie, Inc.',
  'ConcernedApe','Crystal Dynamics','Double Fine','Double Fine Productions',
  'EA','EA Games','Electronic Arts','Electronic Arts Inc.','Epic','Epic Games',
  'Firaxis Games','Gearbox','Gearbox Publishing','Gearbox Software','id Software',
  'InXile','InXile Entertainment','Insomniac','Insomniac Games','Microsoft',
  'Microsoft Studios','Monolith Productions','Naughty Dog','Naughty Dog LLC',
  'Obsidian','Obsidian Entertainment','Respawn','Respawn Entertainment',
  'Rockstar','Rockstar Games','Sledgehammer Games','Stoic','Stoic Studio',
  'Sucker Punch','Sucker Punch Productions','Supergiant','Supergiant Games',
  'Treyarch','Turtle Rock Studios','Valve','Valve Corporation','Xbox Game Studios',
  'ZeniMax','ZeniMax Media'
)

# ----- Known DRM / launchers (hard-coded patterns) -----
$Global:KnownDRMImplementations = @(
  @{ Pattern = 'denuvo';                          Name = 'Denuvo Anti-tamper' }
  @{ Pattern = 'securom';                         Name = 'SecuROM' }
  @{ Pattern = 'vmprotect';                       Name = 'VMProtect' }
  @{ Pattern = 'arxan|guardit';                   Name = 'Arxan (GuardIT)' }
  @{ Pattern = 'starforce';                       Name = 'StarForce' }
  @{ Pattern = 'steamworks(\s*drm)?';             Name = 'Steamworks DRM' }
  @{ Pattern = '\bdrm\b';                         Name = 'DRM (unspecified)' }
)
$Global:KnownThirdPartyAccounts = @(
  @{ Pattern = 'ubisoft|uplay|ubisoft connect';   Name = 'Ubisoft Connect' }
  @{ Pattern = '\b(ea app|origin)\b';             Name = 'EA App / Origin' }
  @{ Pattern = 'rockstar( games)?( social club)?';Name = 'Rockstar Social Club' }
  @{ Pattern = 'bethesda\.net|bethesda';          Name = 'Bethesda.net' }
  @{ Pattern = 'epic games|egs';                  Name = 'Epic Games' }
  @{ Pattern = 'battle\.net|bnet';                Name = 'Battle.net' }
)
if (-not (Get-Variable -Name DRMByAppID -Scope Global -ErrorAction SilentlyContinue)) { $Global:DRMByAppID = @{} }

# ---------------- Get-AppDetails (cache-first, fetch on miss) ----------------
function Get-AppDetails {
  param([int]$AppID, [ref]$WasWebFetch = $(New-Object bool -ArgumentList 0))
  $WasWebFetch.Value = $false
  if ($script:AppCache.ContainsKey($AppID)) { return $script:AppCache[$AppID] }

  $u = "https://store.steampowered.com/api/appdetails?appids=$AppID&l=en&cc=us"
  $resp = Invoke-Get -Uri $u
  $obj = $null
  try { $obj = ConvertFrom-JsonCompat -Json $resp.Content } catch { return $null }
  $entry = Get-JsonProp $obj "$AppID"; if (-not $entry) { return $null }
  $success = Get-JsonProp $entry 'success'; if (-not $success) { return $null }
  $data = Get-JsonProp $entry 'data'
  if ($data) { $script:AppCache[$AppID] = $data; $WasWebFetch.Value = $true }
  return $data
}

# ---------------- Text cleaners ----------------
function Clean-Languages {
  param([string]$raw)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
  $s = $raw -replace '(?i)<br\s*/?>','; '
  $s = $s -replace '<.*?>',''
  if ([type]::GetType('System.Web.HttpUtility')) { $s = [System.Web.HttpUtility]::HtmlDecode($s) }
  $s = $s -replace '\s{2,}',' '
  return $s.Trim()
}
function Clean-PlainText {
  param([string]$raw)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
  $s = $raw -replace '(?i)<br\s*/?>', "`n"
  $s = $s -replace '<.*?>',''
  if ([type]::GetType('System.Web.HttpUtility')) { $s = [System.Web.HttpUtility]::HtmlDecode($s) }
  return ($s -replace '\s+',' ' ).Trim()
}
function Get-AllTextForScan {
  param($Data)
  $buf = @()
  foreach ($k in 'drm_notice','ext_user_account_notice','legal_notice','about_the_game','detailed_description') {
    if ($Data.$k) { $buf += Clean-PlainText ([string]$Data.$k) }
    elseif ($Data[$k]) { $buf += Clean-PlainText ([string]$Data[$k]) }
  }
  foreach ($rk in 'pc_requirements','linux_requirements','mac_requirements') {
    $req = $Data.$rk
    if ($req) {
      foreach ($sub in 'minimum','recommended') {
        if ($req.$sub)      { $buf += Clean-PlainText ([string]$req.$sub) }
        elseif ($req[$sub]) { $buf += Clean-PlainText ([string]$req[$sub]) }
      }
    }
  }
  ($buf | Where-Object { $_ }) -join " | "
}

# ---------------- Chinese-origin assessment ----------------
function Get-ChineseOriginAssessment {
  param(
    [string[]]$Developers,
    [string[]]$Publishers,
    [string]$SupportedLanguages,
    [string]$Name,
    [string[]]$ExtraKeywords = @()
  )

  $cnKeywords = @($Global:BaseCNKeywords + $ExtraKeywords) | ForEach-Object { $_.ToLowerInvariant() }
  $reason = @()
  $strong = $false

  $all = @()
  if ($Developers) { $all += $Developers }
  if ($Publishers) { $all += $Publishers }
  $allLower = $all | ForEach-Object { $_.ToLowerInvariant() }

  foreach ($kw in $cnKeywords) {
    if ($allLower -match [regex]::Escape($kw)) { $strong = $true; $reason += "Keyword match: '$kw'"; break }
  }
  if (-not $strong -and $all) {
    foreach ($n in $all) {
      if ($n -match '[\p{IsCJKUnifiedIdeographs}]') { $strong = $true; $reason += "CJK characters in name: '$n'"; break }
    }
  }
  if (-not $strong -and $Name) {
    foreach ($title in $Global:KnownChineseGames) {
      if ($Name -like "*$title*") { $strong = $true; $reason += "Matched known Chinese game title: '$title'"; break }
    }
  }

  $hasChineseLang = $false
  $hasChineseFullAudio = $false
  if ($SupportedLanguages) {
    $sl = $SupportedLanguages.ToLowerInvariant()
    if ($sl -match 'schinese|tchinese|simplified chinese|traditional chinese') {
      $hasChineseLang = $true
    }
    if ($sl -match '(schinese|tchinese|simplified chinese|traditional chinese)\s*\*') {
      $hasChineseFullAudio = $true
    }
  }

  $isOrigin = $strong
  $weakLang = $false
  if (-not $strong -and $hasChineseLang) {
    $weakLang = $true
    if ($hasChineseFullAudio) { $reason += "Chinese language fully voiced" }
    else { $reason += "Chinese language supported" }
  }

  [pscustomobject]@{
    IsChineseOrigin   = [bool]$isOrigin
    WeakChineseLang   = [bool]$weakLang
    ChineseFullAudio  = [bool]$hasChineseFullAudio
    Reason            = ($reason -join '; ')
  }
}

# ---------------- DRM detection (hard-coded + scan + overrides) ----------------
function Get-DRMInsight {
  param($Data, [int]$AppID)

  if ($Global:DRMByAppID.ContainsKey($AppID)) {
    $override = [string]$Global:DRMByAppID[$AppID]
    return [pscustomobject]@{
      DRMNotice         = $override
      ThirdPartyAccount = $null
      DRMKeywords       = $override
    }
  }

  $drmNotice = $null
  if ($Data.drm_notice) { $drmNotice = Clean-PlainText ([string]$Data.drm_notice) }
  elseif ($Data["drm_notice"]) { $drmNotice = Clean-PlainText ([string]$Data["drm_notice"]) }

  $joined = Get-AllTextForScan -Data $Data
  $t = if ($joined) { $joined.ToLowerInvariant() } else { "" }

  $drmHits = New-Object System.Collections.ArrayList
  foreach ($item in $Global:KnownDRMImplementations) { if ($t -match $item.Pattern) { [void]$drmHits.Add($item.Name) } }
  $drmHits = $drmHits | Select-Object -Unique

  $acct = $null
  foreach ($acc in $Global:KnownThirdPartyAccounts) { if ($t -match $acc.Pattern) { $acct = $acc.Name; break } }

  $display = if ($drmNotice) { $drmNotice }
             elseif ($drmHits -and $drmHits.Count -gt 0) { ($drmHits -join '; ') }
             elseif ($acct) { "Requires third-party account: $acct" }
             else { $null }

  [pscustomobject]@{
    DRMNotice         = $display
    ThirdPartyAccount = $acct
    DRMKeywords       = if ($drmHits -and $drmHits.Count) { $drmHits -join '; ' } else { $null }
  }
}

# ---------------- Anti-cheat detection (incl. kernel-level) ----------------
function Get-AntiCheatInsight {
  param($Data)

  $text = Get-AllTextForScan -Data $Data
  if (-not $text) {
    return [pscustomobject]@{
      AntiCheatVendors     = $null
      UsesKernelAnticheat  = $false
      AntiCheatKeywords    = $null
      AntiCheatNotes       = $null
    }
  }
  $t = $text.ToLowerInvariant()

  $map = @{
    'riot vanguard'        = @{ vendor='Riot Vanguard';        kernel=$true  }
    'vanguard'             = @{ vendor='Riot Vanguard';        kernel=$true  }
    'ricochet'             = @{ vendor='Ricochet';             kernel=$true  }
    'battleye'             = @{ vendor='BattlEye';             kernel=$true  }
    'easy anti-cheat'      = @{ vendor='Easy Anti-Cheat';      kernel=$true  }
    'eac'                  = @{ vendor='Easy Anti-Cheat';      kernel=$true  }
    'nprotect gameguard'   = @{ vendor='nProtect GameGuard';   kernel=$true  }
    'gameguard'            = @{ vendor='nProtect GameGuard';   kernel=$true  }
    'faceit anti-cheat'    = @{ vendor='FACEIT AC';            kernel=$true  }
    'esea'                 = @{ vendor='ESEA';                 kernel=$true  }
    'xigncode3'            = @{ vendor='XIGNCODE3';            kernel=$false }
    'xigncode'             = @{ vendor='XIGNCODE';             kernel=$false }
  }

  $foundVendors = New-Object System.Collections.ArrayList
  $keywords     = New-Object System.Collections.ArrayList
  $kernelHit    = $false

  foreach ($key in $map.Keys) {
    if ($t -match [regex]::Escape($key.ToLower())) {
      [void]$foundVendors.Add($map[$key].vendor)
      [void]$keywords.Add($key)
      if ($map[$key].kernel) { $kernelHit = $true }
    }
  }

  if ($t -match 'kernel[- ]level driver|ring ?0|kernel[- ]mode anti[- ]cheat') {
    $kernelHit = $true
    [void]$keywords.Add('kernel-mode mention')
  }
  if ($t -match 'anti[- ]cheat') { [void]$keywords.Add('anti-cheat mention') }

  $vendorsOut = if ($foundVendors.Count) { ($foundVendors | Select-Object -Unique) -join '; ' } else { $null }
  $kwOut      = if ($keywords.Count)     { ($keywords     | Select-Object -Unique) -join '; ' } else { $null }

  $note = if ($kernelHit -and $vendorsOut) { "Kernel-level AC detected: $vendorsOut" }
          elseif ($vendorsOut)             { "Anti-cheat detected: $vendorsOut" }
          elseif ($kernelHit)              { "Kernel-level AC mentioned" }
          else                             { $null }

  [pscustomobject]@{
    AntiCheatVendors     = $vendorsOut
    UsesKernelAnticheat  = [bool]$kernelHit
    AntiCheatKeywords    = $kwOut
    AntiCheatNotes       = $note
  }
}

# ---------------- Risk score (0-10) ----------------
function Get-RiskScore {
  param(
    [bool]$IsChineseOrigin,
    [bool]$WeakChineseLang,
    [bool]$ChineseFullAudio,
    [string]$DRMNotice,
    [string]$DRMKeywords,
    [string]$ThirdPartyAccount,
    [bool]$UsesKernelAnticheat,
    [string]$AntiCheatVendors,
    [bool]$TrustedUS
  )
  $score = 0
  $factors = @()

  if ($IsChineseOrigin) { $score += 5; $factors += 'Strong Chinese origin (+5)' }
  elseif ($ChineseFullAudio) { $score += 2; $factors += 'Chinese language (full audio) (+2)' }
  elseif ($WeakChineseLang)  { $score += 1; $factors += 'Chinese language supported (+1)' }

  if ($UsesKernelAnticheat) {
    $score += 4; $factors += 'Kernel-level anti-cheat (+4)'
  } elseif ($AntiCheatVendors) {
    $score += 1; $factors += 'Anti-cheat vendor (non-kernel) (+1)'
  }

  $drmWeight = 0
  $hasDRMText = ($DRMNotice) -or ($DRMKeywords)
  if ($hasDRMText) {
    $txt = (("$DRMNotice $DRMKeywords") -as [string]).ToLower()
    if ($txt -match 'denuvo') { $drmWeight = [Math]::Max($drmWeight, 2) }
    elseif ($txt.Trim().Length -gt 0) { $drmWeight = [Math]::Max($drmWeight, 1) }
  }
  if ($drmWeight -gt 0) {
    $score += $drmWeight
    if ($drmWeight -eq 2) { $factors += 'Denuvo DRM (+2)' } else { $factors += 'DRM present (+1)' }
  }

  if ($ThirdPartyAccount) { $score += 1; $factors += '3rd-party account/launcher (+1)' }

  if ($TrustedUS) {
    $score = [Math]::Max(0, $score - 1)
    $factors += 'Trusted US publisher/developer (-1)'
  }

  if ($score -gt 10) { $score = 10 }
  $notes = if ($factors.Count) { ($factors -join '; ') } else { $null }
  [pscustomobject]@{ RiskScore = [int]$score; RiskFactors = $notes }
}

# ---------------- Save helpers (retry + atomic) ----------------
function Save-FileWithRetry {
  param([Parameter(Mandatory=$true)][scriptblock]$SaveAction, [string]$Description = "file", [int]$MaxRetries = 6)
  for ($i=0; $i -lt $MaxRetries; $i++) {
    try { & $SaveAction; return $true }
    catch {
      if ($i -ge ($MaxRetries-1)) { Write-Warning "Failed to save $Description after $MaxRetries attempts. $($_.Exception.Message)"; return $false }
      $sleepMs = [Math]::Min(4000, [Math]::Pow(2, $i) * 150) + (Get-Random -Minimum 0 -Maximum 300)
      Write-Warning "Save of $Description failed (attempt $($i+1)). Retrying in $sleepMs ms..."
      Start-Sleep -Milliseconds $sleepMs
    }
  }
}
function Save-AppCache {
  param([string]$Path, [hashtable]$Cache)
  $stringKeyDict = @{}; foreach ($k in $Cache.Keys) { $stringKeyDict["$k"] = $Cache[$k] }
  try { $jsonOut = $stringKeyDict | ConvertTo-Json -Depth 8 -Compress } catch { Write-Warning "Could not serialize cache: $($_.Exception.Message)"; return $false }
  $dir = Split-Path -Parent $Path; if (-not $dir) { $dir = "." }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + ".tmp")
  $ok = Save-FileWithRetry -Description "cache temp '$tmp'" -SaveAction { Set-Content -Path $tmp -Value $jsonOut -Encoding UTF8 }
  if (-not $ok) { return $false }
  $ok = Save-FileWithRetry -Description "cache file '$Path'" -SaveAction {
    if (Test-Path $Path) { Remove-Item -Path $Path -Force }
    Rename-Item -Path $tmp -NewName (Split-Path -Leaf $Path)
  }
  return $ok
}
function Save-CsvAtomic {
  param([Parameter(Mandatory=$true)][object]$Data, [Parameter(Mandatory=$true)][string]$Path)
  if ($null -eq $Data) { throw "No data to write." }
  if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) { $seq = $Data } else { $seq = @($Data) }

  $dir = Split-Path -Parent $Path; if (-not $dir) { $dir = "." }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + ".tmp")

  $ok = Save-FileWithRetry -Description "CSV temp '$tmp'" -SaveAction { $seq | Export-Csv -Path $tmp -NoTypeInformation -Encoding UTF8 }
  if (-not $ok) { return $false }

  return Save-FileWithRetry -Description "CSV '$Path'" -SaveAction {
    if (Test-Path $Path) { Remove-Item -Path $Path -Force }
    Rename-Item -Path $tmp -NewName (Split-Path -Leaf $Path)
  }
}
function Save-HtmlAtomic {
  param([Parameter(Mandatory=$true)][object]$Data, [Parameter(Mandatory=$true)][string]$Path, [string]$Title = "Steam Library Risk Report")
  if ($null -eq $Data) { throw "No data to write." }
  $rows = if ($Data -is [System.Collections.IEnumerable] -and -not ($Data -is [string])) { $Data } else { @($Data) }

  try { Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue } catch {}
  $enc = { param($s) if ($s -eq $null) { return '' } if ([type]::GetType('System.Web.HttpUtility')) { return [System.Web.HttpUtility]::HtmlEncode([string]$s) } else { return ([string]$s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;') } }
  $encAttr = { param($s) if ($s -eq $null) { return '' } $t = (& $enc $s); ($t -replace '"','&quot;' -replace "'", '&#39;' -replace "\r?\n", '&#10;') }

  # Columns to show (ordered)
  $columns = @(
    'RiskScore','Name','AppID','IsChineseOrigin','WeakChineseLang','ChineseFullAudio','Reason',
    'UsesKernelAnticheat','AntiCheatVendors','AntiCheatNotes',
    'DRMNotice','ThirdPartyAccount','DRMKeywords',
    'Developers','Publishers','SupportedLangs','TrustedUS','RiskFactors','StoreURL'
  ) | Where-Object { $rows.Count -eq 0 -or ($rows[0].PSObject.Properties.Name -contains $_) }

  $date = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $count = $rows.Count
  $css = @"
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#0b0b0c;color:#e7e7ea}
h1{font-size:20px;margin:0 0 6px}
.summary{color:#a0a0a8;margin-bottom:14px}
table{border-collapse:collapse;width:100%;background:#121215}
th,td{border:1px solid #2a2a31;padding:8px 10px;vertical-align:top}
th{position:sticky;top:0;background:#1a1a22;text-align:left}
tr:nth-child(even){background:#141418}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:12px}
.risk0{background:#1e3a1e;color:#a6f0a6}
.risk1-3{background:#2b3a1e;color:#d9f0a6}
.risk4-6{background:#3a341e;color:#f0e3a6}
.risk7-8{background:#3a281e;color:#f0cda6}
.risk9-10{background:#3a1e1e;color:#f0a6a6}
a{color:#7ab8ff}
small{color:#8c8c93}
"@

  function Get-RiskClass([int]$n){
    if ($n -ge 9) { return "risk9-10" }
    elseif ($n -ge 7) { return "risk7-8" }
    elseif ($n -ge 4) { return "risk4-6" }
    elseif ($n -ge 1) { return "risk1-3" }
    else { return "risk0" }
  }

  $tbody = New-Object System.Text.StringBuilder
  foreach ($r in $rows) {
    $rs = [int]($r.RiskScore)
    $cls = Get-RiskClass $rs
    [void]$tbody.Append("<tr>")
    foreach ($c in $columns) {
      $v = $r.$c
      if ($c -eq 'RiskScore') {
        [void]$tbody.Append("<td><span class='badge $cls' title='" + (& $encAttr $r.RiskFactors) + "'>$rs</span></td>")
      } elseif ($c -eq 'StoreURL' -and $v) {
        $url  = & $enc $v
        [void]$tbody.Append("<td><a href='$url' target='_blank' rel='noreferrer noopener'>Store Page</a></td>")
      } else {
        [void]$tbody.Append("<td>" + (& $enc $v) + "</td>")
      }
    }
    [void]$tbody.Append("</tr>")
  }

  $thead = "<tr>" + ($columns | ForEach-Object { "<th>" + (& $enc $_) + "</th>" }) -join '' + "</tr>"

  $html = @"
<!doctype html>
<html lang="en">
<meta charset="utf-8" />
<title>$((& $enc $Title))</title>
<style>$css</style>
<body>
  <h1>$((& $enc $Title))</h1>
  <div class="summary">
    Generated: $date<br/>
    Rows: $count<br/>
    Legend: <span class='badge risk0'>0</span>
            <span class='badge risk1-3'>1-3</span>
            <span class='badge risk4-6'>4-6</span>
            <span class='badge risk7-8'>7-8</span>
            <span class='badge risk9-10'>9-10</span>
    <br/><small>Tip: Click column headers in your viewer to sort, or open CSV in Excel.</small>
  </div>
  <table>
    <thead>$thead</thead>
    <tbody>$tbody</tbody>
  </table>
</body>
</html>
"@

  $dir = Split-Path -Parent $Path; if (-not $dir) { $dir = "." }
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + ".tmp")

  $ok = Save-FileWithRetry -Description "HTML temp '$tmp'" -SaveAction { Set-Content -Path $tmp -Value $html -Encoding UTF8 }
  if (-not $ok) { return $false }

  return Save-FileWithRetry -Description "HTML '$Path'" -SaveAction {
    if (Test-Path $Path) { Remove-Item -Path $Path -Force }
    Rename-Item -Path $tmp -NewName (Split-Path -Leaf $Path)
  }
}

# ---------------- Rerun command builder (prints only; no files saved) ----------------
function Build-RerunCommand {
  param(
    [string]$SteamID64,
    [string]$Vanity,
    [string]$OutCsv,
    [int]$DelayMs,
    [bool]$OnlyFlagged,
    [bool]$UseCache,
    [bool]$ScanChinese,
    [bool]$ScanDRM,
    [bool]$ScanKernelAC,
    [string]$OutHtml
  )

  $scriptPath = Get-ScriptPath
  $q = '"' # quote
  $args = @("powershell.exe","-NoProfile","-ExecutionPolicy","Bypass","-File",$q + $scriptPath + $q)

  if ($SteamID64) { $args += @("-SteamID64",$SteamID64) }
  elseif ($Vanity) { $args += @("-Vanity",$q + $Vanity + $q) }

  if ($OutHtml) { $args += @("-OutHtml",$q + $OutHtml + $q) }  # defaulted
  if ($OutCsv)  { $args += @("-OutCsv",$q + $OutCsv + $q) }    # optional
  if ($DelayMs -ne $null) { $args += @("-DelayMsBetweenStoreCalls",$DelayMs) }
  if ($OnlyFlagged) { $args += "-OnlyFlagged" }
  if ($UseCache) { $args += "-UseCache" }
  if ($ScanChinese) { $args += "-ScanChinese" }
  if ($ScanDRM) { $args += "-ScanDRM" }
  if ($ScanKernelAC) { $args += "-ScanKernelAC" }
  $args += "-NoPause"

  return ($args -join ' ')
}

# ---------------- Wizard (CLI) ----------------
function Invoke-Wizard {
  $modeIdx = Prompt-Menu -Title "Select identity mode" -Options @("Vanity (community ID name)", "SteamID64 (17-digit)") -DefaultIndex 0
  if ($modeIdx -eq 0) {
    $script:Vanity = Prompt-String -Message "Enter your Steam vanity name (community ID)" -Validate { param($v) if ([string]::IsNullOrWhiteSpace($v)) { throw "Vanity cannot be empty." } $true }
    Write-Host "Resolving vanity..."
    $resolved = Resolve-SteamID64FromVanity -Vanity $script:Vanity
    Write-Host "Resolved SteamID64: $resolved"
    $script:SteamID64 = $resolved
  } else {
    $script:SteamID64 = Prompt-String -Message "Enter SteamID64 (exactly 17 digits)" -Validate { param($v) if ($v -notmatch '^\d{17}$') { throw "SteamID64 must be exactly 17 digits." } $true }
  }

  $script:ScanChinese   = Prompt-YesNo -Message "Scan for Chinese origin?" -DefaultYes
  $script:ScanDRM       = Prompt-YesNo -Message "Scan for DRM / 3rd-party accounts?" -DefaultYes
  $script:ScanKernelAC  = Prompt-YesNo -Message "Scan for kernel-level anti-cheat?" -DefaultYes
  if (-not ($script:ScanChinese -or $script:ScanDRM -or $script:ScanKernelAC)) { throw "You must enable at least one scan type." }

  # Default output names: HTML default ON; CSV optional
  $parts = @()
  if ($script:ScanChinese)  { $parts += 'cn' }
  if ($script:ScanDRM)      { $parts += 'drm' }
  if ($script:ScanKernelAC) { $parts += 'kernel' }
  $suffix = ($parts -join '_'); if ([string]::IsNullOrEmpty($suffix)) { $suffix = 'report' }

  if (-not $PSBoundParameters.ContainsKey('OutHtml')) {
    $script:OutHtml = ".\steam_scan_$suffix.html"
  } else {
    $script:OutHtml = $OutHtml
  }

  # Ask for CSV
  if (-not $PSBoundParameters.ContainsKey('OutCsv')) {
    if (Prompt-YesNo -Message "Also export a CSV report?" -DefaultYes:$false) {
      $script:OutCsv = ".\steam_scan_$suffix.csv"
    } else {
      $script:OutCsv = $null
    }
  } else {
    $script:OutCsv = $OutCsv
  }

  $script:DelayMsBetweenStoreCalls = Prompt-IntInRange -Message "Delay (ms) between Store API calls" -Min 0 -Max 2000 -Default $script:DelayMsBetweenStoreCalls
  $script:OnlyFlagged = Prompt-YesNo -Message "Only export rows flagged by selected checks?" -DefaultYes
  $script:UseCache = Prompt-YesNo -Message "Cache API results into steam_scan.json for faster rescans?" -DefaultYes

  if ($script:ScanChinese -and (Prompt-YesNo -Message "Add extra developer/publisher keywords? (comma-separated)")) {
    $extra = Prompt-String -Message "Enter keywords (e.g., 'Hoyoverse, XD Network, Lilith')" -Default ""
    $script:ExtraKeywords = @(); if (-not [string]::IsNullOrWhiteSpace($extra)) { $script:ExtraKeywords = ($extra -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
  } else { $script:ExtraKeywords = @() }

  Write-Host "`nSummary:"
  Write-Host "  SteamID64   : $($script:SteamID64)"
  Write-Host "  Checks      : $(@(@($script:ScanChinese) -replace 'True','Chinese') + @(@($script:ScanDRM) -replace 'True','DRM') + @(@($script:ScanKernelAC) -replace 'True','Kernel AC') | Where-Object {$_})"
  Write-Host "  OutHtml     : $($script:OutHtml)"
  Write-Host "  OutCsv      : $($script:OutCsv)"
  Write-Host "  Delay (ms)  : $($script:DelayMsBetweenStoreCalls)"
  Write-Host "  OnlyFlagged : $([bool]$script:OnlyFlagged)"
  Write-Host "  Cache to DB : $([bool]$script:UseCache)"
  if ($script:ExtraKeywords.Count) { Write-Host "  ExtraKeywords: $($script:ExtraKeywords -join ', ')" }
  if (-not (Prompt-YesNo -Message "Looks good? Start scan now?" -DefaultYes)) { throw "Canceled by user." }
}

# --------------- Guard Rails (non-wizard) ---------------
if (-not $Wizard) {
  if (-not ($ScanChinese -or $ScanDRM -or $ScanKernelAC)) {
    $ScanChinese = $true; $ScanDRM = $true; $ScanKernelAC = $true
  }
  # Default HTML if not specified
  if (-not $PSBoundParameters.ContainsKey('OutHtml') -or [string]::IsNullOrWhiteSpace($OutHtml)) {
    $parts = @()
    if ($ScanChinese)  { $parts += 'cn' }
    if ($ScanDRM)      { $parts += 'drm' }
    if ($ScanKernelAC) { $parts += 'kernel' }
    $suffix = ($parts -join '_'); if ([string]::IsNullOrEmpty($suffix)) { $suffix = 'report' }
    $OutHtml = ".\steam_scan_$suffix.html"
  }
  # CSV only if explicitly passed

  if ([string]::IsNullOrWhiteSpace($Vanity) -and [string]::IsNullOrWhiteSpace($SteamID64)) { Exit-WithPause -Code 1 -Message "Provide either -Vanity '<name>' or -SteamID64 <17-digit>, or run with -Wizard." -OnError }
  if (-not [string]::IsNullOrWhiteSpace($Vanity) -and -not [string]::IsNullOrWhiteSpace($SteamID64)) { Exit-WithPause -Code 1 -Message "Use either -Vanity or -SteamID64, not both." -OnError }
  if (-not [string]::IsNullOrWhiteSpace($SteamID64) -and ($SteamID64 -notmatch '^\d{17}$')) { Exit-WithPause -Code 1 -Message "SteamID64 should be a 17-digit number." -OnError }
} else {
  try { Invoke-Wizard } catch { Exit-WithPause -Code 1 -Message $_.Exception.Message -OnError }
}

# ---------------- Load cache if requested ----------------
if ($UseCache -or ($Wizard -and $script:UseCache)) {
  if (Test-Path $CacheFile) {
    try {
      $json = Get-Content $CacheFile -Raw -ErrorAction Stop
      $data = ConvertFrom-JsonCompat -Json $json
      if ($data) {
        $script:AppCache = @{}
        if ($data -isnot [System.Collections.IDictionary]) {
          foreach ($prop in $data.PSObject.Properties) {
            if ($prop -and $prop.Name) { $appid = 0; if ([int]::TryParse($prop.Name, [ref]$appid)) { $script:AppCache[$appid] = $prop.Value } }
          }
        } else {
          foreach ($k in $data.Keys) { $appid = 0; if ([int]::TryParse($k, [ref]$appid)) { $script:AppCache[$appid] = $data[$k] } }
        }
        Write-Host "Loaded $($script:AppCache.Count) cached entries from $CacheFile"
      }
    } catch { Write-Warning "Failed to load cache file. Starting fresh. ($_)" }
  }
}

# ---------------- Main ----------------
try {
  if ($Wizard -and $script:SteamID64) {
    $SteamID64 = $script:SteamID64; $OutHtml = $script:OutHtml; $OutCsv = $script:OutCsv
    $DelayMsBetweenStoreCalls = $script:DelayMsBetweenStoreCalls
    $OnlyFlagged = [bool]$script:OnlyFlagged
    $UseCache = [bool]$script:UseCache
    $ExtraKeywords = $script:ExtraKeywords
    $ScanChinese = $script:ScanChinese
    $ScanDRM = $script:ScanDRM
    $ScanKernelAC = $script:ScanKernelAC
  } elseif (-not [string]::IsNullOrWhiteSpace($Vanity)) {
    Write-Host "Resolving vanity '$Vanity' to SteamID64..."
    $SteamID64 = Resolve-SteamID64FromVanity -Vanity $Vanity
    $ExtraKeywords = @()
  } else {
    $ExtraKeywords = @()
  }

  Write-Host "Using SteamID64: $SteamID64"
  Write-Host "Fetching public games list..."
  $games = Get-PublicGames -SteamID64 $SteamID64
  if (-not $games -or $games.Count -eq 0) { throw "No games found (profile private or empty library)." }

  Write-Host "Found $($games.Count) games. Querying store metadata..."

  $results = New-Object System.Collections.ArrayList
  $fetchCount = 0
  $i = 0
  foreach ($g in $games) {
    $i++

    $didFetch = $false
    $data = Get-AppDetails -AppID $g.AppID -WasWebFetch ([ref]$didFetch)
    if ($didFetch) {
      $fetchCount++
      if ($DelayMsBetweenStoreCalls -gt 0) { Start-Sleep -Milliseconds $DelayMsBetweenStoreCalls }
      if (($fetchCount % 50) -eq 0) { Start-Sleep -Seconds 5 }
    }

    $title = if ($data -and $data.name) { [string]$data.name } else { Get-XmlText $g.Name }

    # Defaults (columns present even if not scanning that dimension)
    $devs = @(); $pubs = @(); $supported = $null
    $isCN = $null; $weakLang = $null; $fullAudio = $false; $reason = $null
    $drmNotice = $null; $acct = $null; $drmKeys = $null
    $acVendors = $null; $kernel = $false; $acKeys = $null; $acNotes = $null

    if ($data) {
      if ($data.developers) { $devs = @($data.developers) } elseif ($data["developers"]) { $devs = @($data["developers"]) }
      if ($data.publishers) { $pubs = @($data.publishers) } elseif ($data["publishers"]) { $pubs = @($data["publishers"]) }
      if ($data.supported_languages) { $supported = Clean-Languages ([string]$data.supported_languages) }
      elseif ($data["supported_languages"]) { $supported = Clean-Languages ([string]$data["supported_languages"]) }

      if ($ScanChinese) {
        $ass = Get-ChineseOriginAssessment -Developers $devs -Publishers $pubs -SupportedLanguages $supported -Name $title -ExtraKeywords $ExtraKeywords
        $isCN = $ass.IsChineseOrigin
        $weakLang = $ass.WeakChineseLang
        $fullAudio = $ass.ChineseFullAudio
        $reason = $ass.Reason
      }
      if ($ScanDRM) {
        $drm = Get-DRMInsight -Data $data -AppID $g.AppID
        $drmNotice = $drm.DRMNotice
        $acct = $drm.ThirdPartyAccount
        $drmKeys = $drm.DRMKeywords
      }
      if ($ScanKernelAC) {
        $ac = Get-AntiCheatInsight -Data $data
        $acVendors = $ac.AntiCheatVendors
        $kernel = $ac.UsesKernelAnticheat
        $acKeys = $ac.AntiCheatKeywords
        $acNotes = $ac.AntiCheatNotes
      }
    }

    # -------- Trusted U.S. publisher/developer detection (for -1 score) --------
    $trustedUS = $false
    if ($devs.Count -or $pubs.Count) {
        $allNames = @($devs + $pubs) | ForEach-Object { $_.ToLowerInvariant().Trim() }
        foreach ($us in $Global:TrustedUSCompanies) {
            $needle = $us.ToLowerInvariant().Trim()
            if ($allNames -contains $needle) {
                $trustedUS = $true
                break
            }
        }
    }

    # Risk score
    $rs = Get-RiskScore `
      -IsChineseOrigin     ($isCN -eq $true) `
      -WeakChineseLang     ($weakLang -eq $true) `
      -ChineseFullAudio    ($fullAudio -eq $true) `
      -DRMNotice           $drmNotice `
      -DRMKeywords         $drmKeys `
      -ThirdPartyAccount   $acct `
      -UsesKernelAnticheat ($kernel -eq $true) `
      -AntiCheatVendors    $acVendors `
      -TrustedUS           $trustedUS

    $row = [pscustomobject]@{
      AppID               = $g.AppID
      Name                = $title
      Developers          = ($devs -join ' | ')
      Publishers          = ($pubs -join ' | ')
      SupportedLangs      = $supported
      IsChineseOrigin     = $isCN
      WeakChineseLang     = $weakLang
      ChineseFullAudio    = $fullAudio
      Reason              = $reason
      DRMNotice           = $drmNotice
      ThirdPartyAccount   = $acct
      DRMKeywords         = $drmKeys
      AntiCheatVendors    = $acVendors
      UsesKernelAnticheat = $kernel
      AntiCheatKeywords   = $acKeys
      AntiCheatNotes      = $acNotes
      TrustedUS           = $trustedUS
      RiskScore           = $rs.RiskScore
      RiskFactors         = $rs.RiskFactors
      StoreURL            = "https://store.steampowered.com/app/$($g.AppID)/"
    }

    # OnlyFlagged now means: any selected dimension flagged OR RiskScore>0
    $interesting = $false
    if ($ScanChinese  -and ($row.IsChineseOrigin -eq $true -or $row.WeakChineseLang -eq $true -or $row.ChineseFullAudio -eq $true)) { $interesting = $true }
    if ($ScanDRM      -and ($row.DRMNotice -or $row.ThirdPartyAccount -or $row.DRMKeywords)) { $interesting = $true }
    if ($ScanKernelAC -and ($row.UsesKernelAnticheat -or $row.AntiCheatVendors)) { $interesting = $true }
    if ($row.RiskScore -gt 0) { $interesting = $true }

    if ($OnlyFlagged) { if ($interesting) { [void]$results.Add($row) } }
    else { [void]$results.Add($row) }

    if (($i % 25) -eq 0) { Write-Host ("Processed {0}/{1}... (web fetches so far: {2})" -f $i, $games.Count, $fetchCount) }
  }

  $script:__finalSorted = $results | Sort-Object -Property @{Expression='RiskScore';Descending=$true}, Name
  $script:__finalOnlyFlagged = [bool]$OnlyFlagged

} catch {
  Write-Error $_.Exception.Message
  if ($Wizard) { Exit-WithPause -Code 1 -OnError }
  else { exit 1 }
} finally {
  if ($script:__finalSorted) {
    # HTML (default)
    if ($OutHtml) {
      $title = "Steam Library Risk Report"
      if (Save-HtmlAtomic -Data $script:__finalSorted -Path $OutHtml -Title $title) {
        Write-Host "`nHTML report saved to: $OutHtml"
      } else {
        Write-Warning "Could not save HTML to '$OutHtml'. The file may be open in another program."
      }
    }

    # CSV (optional)
    if ($OutCsv) {
      if (Save-CsvAtomic -Data $script:__finalSorted -Path $OutCsv) {
        Write-Host "CSV report saved to: $OutCsv"
        if ($script:__finalOnlyFlagged) { Write-Host "(Only rows flagged by selected checks/score were included.)" }
        Write-Host "Tip: In Excel, sort/filter by RiskScore, UsesKernelAnticheat, DRMNotice, AntiCheatVendors, IsChineseOrigin."
      } else {
        Write-Warning "Could not save CSV to '$OutCsv'. The file may be open in another program."
      }
    }
  }

  if ($UseCache -or ($Wizard -and $script:UseCache)) {
    if ($script:AppCache -and $script:AppCache.Count -gt 0) {
      if (Save-AppCache -Path $CacheFile -Cache $script:AppCache) {
        Write-Host "Cache saved to $CacheFile ($($script:AppCache.Count) entries)"
      } else {
        Write-Warning "Cache not saved. Close any tools locking the file, then rerun."
      }
    }
  }

  # Print rerun command after wizard (no files written)
  if ($Wizard) {
    $rerunCmd = Build-RerunCommand -SteamID64 $SteamID64 -Vanity $script:Vanity -OutHtml $OutHtml -OutCsv $OutCsv `
      -DelayMs $DelayMsBetweenStoreCalls -OnlyFlagged:$script:OnlyFlagged -UseCache:$script:UseCache `
      -ScanChinese:$script:ScanChinese -ScanDRM:$script:ScanDRM -ScanKernelAC:$script:ScanKernelAC

    Write-Host "`nRerun this exact scan next time with:"
    Write-Host "  $rerunCmd" -ForegroundColor Yellow
    if (-not $NoPause) { [void](Read-Host "`nDone. Press Enter to exit...") }
  }
}
