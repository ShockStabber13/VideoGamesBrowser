param(
    [int]$PreferredPort = 8765,
    [switch]$OpenBrowser,
    [switch]$FastStart,
    [switch]$BuildStaticCache,
    [switch]$BuildPlatformBrowseCache,
    [switch]$UpdatePreservationDats,
    [switch]$ForceDatRefresh
)

$ErrorActionPreference = 'Stop'
# Speed up Invoke-WebRequest on Windows PowerShell 5.1 by suppressing per-byte progress updates.
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 can otherwise negotiate an obsolete TLS version.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$CatalogPath = Join-Path $Root 'catalog.json'
$ChunksPath = Join-Path $Root 'daily-chunks.json'
$MetadataPath = Join-Path $Root 'metadata-cache.json'
$IgdbConfigPath = Join-Path $Root 'igdb-config.json'
$CacheRoot = Join-Path $Root '_cache'
$DatsRoot = Join-Path $Root 'DATs'
$SourceStatePath = Join-Path $CacheRoot 'source-state.json'
$PlatformCatalogRoot = Join-Path $CacheRoot 'platform-catalogs'
New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null
New-Item -ItemType Directory -Force -Path $PlatformCatalogRoot | Out-Null
New-Item -ItemType Directory -Force -Path $DatsRoot | Out-Null
$script:AllowPreservationDownloads = [bool]($UpdatePreservationDats -or $ForceDatRefresh)
$script:ForcePreservationRefresh = [bool]$ForceDatRefresh
$script:PreservationRefreshDays = 7

$PlatformsConfigPath = Join-Path $Root 'platforms.json'
$platformConfigRaw = Get-Content -LiteralPath $PlatformsConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$PlatformConfigs = @($platformConfigRaw.platforms | ForEach-Object { $_ })
$Platforms = @($PlatformConfigs | ForEach-Object { [string]$_.name })
$DatBackedModes = @('redump','nointro','dat','other')
$StaticCachePlatforms = @($PlatformConfigs | Where-Object { [string]$_.mode -in $DatBackedModes } | ForEach-Object { [string]$_.name })
$script:PlatformConfigByName=@{}
foreach($pc in $PlatformConfigs){$script:PlatformConfigByName[[string]$pc.name]=$pc}
$script:IgdbPlatformDirectory=$null
$script:IgdbGenres=$null
$script:PcgwControllerIndex=$null
$script:ControllerQueryCaches=@{}
$script:SteamControllerQueryCaches=@{}
$script:IgdbDailyPriorityMemory=@{}
$script:IgdbToken = $null
$script:IgdbTokenExpires = [datetime]::MinValue
$script:IgdbLastRequest = [datetime]::MinValue
$script:IgdbUpdatedAtChangeCacheV6 = $null
$script:IgdbIncrementalProbeResults = @{}
$script:PcgwLastRequest = [datetime]::MinValue
$UserAgent = 'DailyChunkGames/5.0 (IGDB + preservation DAT intersection catalog)'

function Get-ContentType([string]$Path) {
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.txt'  { 'text/plain; charset=utf-8' }
        '.jpg'  { 'image/jpeg' }
        '.jpeg' { 'image/jpeg' }
        '.png'  { 'image/png' }
        '.webp' { 'image/webp' }
        '.gif'  { 'image/gif' }
        '.svg'  { 'image/svg+xml' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}
function Send-Response($Stream,[int]$Code,[string]$Text,[byte[]]$Body,[string]$Type='text/plain; charset=utf-8') {
    $head = "HTTP/1.1 $Code $Text`r`nContent-Type: $Type`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-cache, no-store, must-revalidate`r`nConnection: close`r`nReferrer-Policy: strict-origin-when-cross-origin`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb,0,$hb.Length)
    if($Body.Length){ $Stream.Write($Body,0,$Body.Length) }
    $Stream.Flush()
}
function Send-Json($Stream,[int]$Code,$Object) {
    $json = $Object | ConvertTo-Json -Depth 40 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $text = if($Code -eq 200){'OK'}elseif($Code -eq 400){'Bad Request'}else{'Error'}
    Send-Response $Stream $Code $text $bytes 'application/json; charset=utf-8'
}
function Read-Json([string]$Path,$Default) {
    try {
        if(!(Test-Path -LiteralPath $Path)){ return $Default }
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return $Default }
        return ($raw | ConvertFrom-Json)
    } catch { return $Default }
}
function Write-JsonAtomic($Value,[string]$Path) {
    $tmp = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Object-ToHashtable($Object) {
    $h=@{}
    if($null -eq $Object){ return $h }
    foreach($p in $Object.PSObject.Properties){ $h[$p.Name]=$p.Value }
    return $h
}
function Set-Prop($Object,[string]$Name,$Value) {
    if($Object.PSObject.Properties[$Name]){ $Object.$Name=$Value }
    else{ Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
function Copy-ControllerFields($From,$To) {
    if($null -eq $From -or $null -eq $To){ return }
    foreach($name in @('controllerCategory','controllerSupport','fullControllerSupport','controllerSource')) {
        if($From.PSObject.Properties[$name]){ Set-Prop $To $name $From.$name }
    }
}
function Normalize-Name([string]$s) {
    if([string]::IsNullOrWhiteSpace($s)){ return '' }
    $s = [Net.WebUtility]::HtmlDecode($s)
    $s = $s.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach($ch in $s.ToCharArray()) {
        if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark){ [void]$sb.Append($ch) }
    }
    $s = $sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $s = $s -replace '[™®©]',''
    $s = $s -replace '[^a-z0-9]+',' '
    return ($s -replace '\s+',' ').Trim()
}
function Get-TitleTokenSignature([string]$s) {
    $n=Normalize-Name $s
    if([string]::IsNullOrWhiteSpace($n)){ return '' }
    # Redump often moves articles around, e.g. "Simpsons, The" vs
    # IGDB's "The Simpsons". Sorting normalized tokens makes those titles
    # identical without any extra network request.
    $tokens=@($n.Split(' ') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    return ($tokens -join '|')
}
function Stable-Id([string]$Platform,[string]$Title) { return "$Platform::$Title" }
function New-Entry([string]$Platform,[string]$Title,[string]$Source,[string]$SourceId,[string]$SourceUrl,$ReleaseYear=$null) {
    return [pscustomobject]@{
        id = Stable-Id $Platform $Title
        platform = $Platform
        title = $Title
        catalogSource = $Source
        sourceId = $SourceId
        sourceUrl = $SourceUrl
        releaseYear = $ReleaseYear
    }
}
function Parse-Query([string]$Target) {
    $h=@{}
    $qIndex=$Target.IndexOf('?')
    if($qIndex -lt 0){ return $h }
    $q=$Target.Substring($qIndex+1)
    foreach($pair in $q.Split('&')) {
        if([string]::IsNullOrWhiteSpace($pair)){ continue }
        $idx=$pair.IndexOf('=')
        if($idx -lt 0){ $k=$pair; $v='' } else { $k=$pair.Substring(0,$idx); $v=$pair.Substring($idx+1) }
        $k=[uri]::UnescapeDataString(($k -replace '\+',' '))
        $v=[uri]::UnescapeDataString(($v -replace '\+',' '))
        $h[$k]=$v
    }
    return $h
}
function Get-BodyText($Reader,[int]$ContentLength) {
    if($ContentLength -le 0){ return '' }
    $chars=New-Object char[] $ContentLength
    $read=0
    while($read -lt $ContentLength) {
        $n=$Reader.Read($chars,$read,$ContentLength-$read)
        if($n -le 0){ break }
        $read += $n
    }
    if($read -le 0){ return '' }
    return -join $chars[0..($read-1)]
}
# Hot-path JSON caches. The browser may request many pages in one session;
# reparsing catalog.json and daily-chunks.json for every request is needlessly
# expensive under Windows PowerShell 5.1.
$script:CatalogMemory = $null
$script:CatalogPlatformMemory = @{}
$script:ChunksMemory = $null
$script:ChunkExactMemory = $null
$script:ChunkNormalizedMemory = $null

function Read-Catalog {
    if($null -ne $script:CatalogMemory){ return @($script:CatalogMemory) }
    $o=Read-Json $CatalogPath @()
    $script:CatalogMemory=@($o | ForEach-Object { $_ })
    return @($script:CatalogMemory)
}
function Save-Catalog($Rows) {
    $arr=@($Rows | ForEach-Object { $_ })
    Write-JsonAtomic $arr $CatalogPath
    $script:CatalogMemory=$arr
    $script:CatalogPlatformMemory=@{}
}
function Get-ChunkIndexes {
    if($null -ne $script:ChunkExactMemory -and $null -ne $script:ChunkNormalizedMemory){
        return [pscustomobject]@{exact=$script:ChunkExactMemory;normalized=$script:ChunkNormalizedMemory;count=@($script:ChunksMemory).Count}
    }
    $script:ChunksMemory=@((Read-Json $ChunksPath @())|ForEach-Object{$_})
    $exact=@{};$normalized=@{}
    foreach($c in $script:ChunksMemory) {
        $cid=[string]$c.id
        if(!$exact.ContainsKey($cid)){$exact[$cid]=$c}
        $nk=([string]$c.platform)+'|'+(Normalize-Name ([string]$c.title))
        if(!$normalized.ContainsKey($nk)){$normalized[$nk]=$c}
    }
    $script:ChunkExactMemory=$exact;$script:ChunkNormalizedMemory=$normalized
    return [pscustomobject]@{exact=$exact;normalized=$normalized;count=$script:ChunksMemory.Count}
}
function Reset-ChunkMemory {
    $script:ChunksMemory=$null;$script:ChunkExactMemory=$null;$script:ChunkNormalizedMemory=$null
}
function Read-State {
    $s=Read-Json $SourceStatePath $null
    if($null -eq $s){ $s=[pscustomobject]@{} }
    return $s
}
function Save-State($State) { Write-JsonAtomic $State $SourceStatePath }
function Get-PlatformConfig([string]$Platform) {
    if($script:PlatformConfigByName.ContainsKey($Platform)){ return $script:PlatformConfigByName[$Platform] }
    return $null
}
function State-Key([string]$Platform) {
    $k=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','_').Trim('_')
    if([string]::IsNullOrWhiteSpace($k)){ throw "Invalid platform name: $Platform" }
    return $k
}

function Get-PlatformCatalogPath([string]$Platform) {
    return (Join-Path $PlatformCatalogRoot ((State-Key $Platform)+'.json'))
}
function Write-PlatformCatalogCache([string]$Platform,$Rows) {
    $arr=@($Rows | ForEach-Object { $_ })
    $path=Get-PlatformCatalogPath $Platform
    Write-JsonAtomic $arr $path
    $script:CatalogPlatformMemory[$Platform]=$arr
    return $arr.Count
}
function Read-PlatformCatalog([string]$Platform) {
    if($script:CatalogPlatformMemory.ContainsKey($Platform)){
        return @($script:CatalogPlatformMemory[$Platform])
    }
    $path=Get-PlatformCatalogPath $Platform
    if(Test-Path -LiteralPath $path) {
        $rows=@((Read-Json $path @()) | ForEach-Object { $_ })
        $script:CatalogPlatformMemory[$Platform]=$rows
        return @($rows)
    }

    # Compatibility with an older installation that only has catalog.json.
    # This fallback is intentionally one-time: after the first read, persist the
    # platform slice so future server restarts never need the giant JSON parse.
    $rows=@(Get-CatalogPlatform @(Read-Catalog) $Platform)
    if($rows.Count) {
        try { [void](Write-PlatformCatalogCache $Platform $rows) } catch {}
    }
    return @($rows)
}
function Build-PlatformBrowseCaches {
    Write-Host ''
    Write-Host 'Building fast per-platform browse cache from existing catalog.json...' -ForegroundColor Cyan
    Write-Host 'No IGDB requests and no DAT downloads are performed.' -ForegroundColor DarkGray
    $catalog=@(Read-Catalog)
    $lists=@{}
    foreach($name in $StaticCachePlatforms){$lists[$name]=New-Object 'System.Collections.Generic.List[object]'}
    foreach($g in $catalog) {
        if($null -eq $g){continue}
        $name=[string]$g.platform
        if($lists.ContainsKey($name)){[void]$lists[$name].Add($g)}
    }
    $written=0
    foreach($name in $StaticCachePlatforms) {
        $rows=@($lists[$name].ToArray() | Sort-Object @{Expression={if($_.sourceOrder){[long]$_.sourceOrder}else{[long]::MaxValue}}},title)
        if($rows.Count) {
            [void](Write-PlatformCatalogCache $name $rows)
            $written++
            Write-Host ("  [{0}] {1:N0} games" -f $name,$rows.Count) -ForegroundColor DarkGray
        }
    }
    Write-Host ("Fast platform browse cache ready: {0} platform files." -f $written) -ForegroundColor Green
    Write-Host ''
}
function Get-PlatformState($State,[string]$Platform) {
    $key=State-Key $Platform
    if(!$State.PSObject.Properties[$key]) {
        $cfg=Get-PlatformConfig $Platform
        if($null -eq $cfg){ throw "Unknown platform: $Platform" }
        $initial=[pscustomobject]@{
            releaseOffset=0
            complete=$false
            batches=0
            source=[string]$cfg.mode
            catalogMode=''
        }
        Add-Member -InputObject $State -NotePropertyName $key -NotePropertyValue $initial -Force
    }
    $current=$State.$key
    foreach($prop in @('releaseOffset','complete','batches','source','catalogMode')){
        if(!$current.PSObject.Properties[$prop]){
            switch($prop){
                'releaseOffset'{Set-Prop $current $prop 0}
                'complete'{Set-Prop $current $prop $false}
                'batches'{Set-Prop $current $prop 0}
                'source'{Set-Prop $current $prop ([string](Get-PlatformConfig $Platform).mode)}
                'catalogMode'{Set-Prop $current $prop ''}
            }
        }
    }
    return $current
}
function Get-CatalogPlatform($Catalog,[string]$Platform) {
    if($script:CatalogPlatformMemory.ContainsKey($Platform)){
        return @($script:CatalogPlatformMemory[$Platform])
    }
    $rows=@($Catalog | Where-Object { $_.platform -eq $Platform } | Sort-Object @{Expression={if($_.sourceOrder){[long]$_.sourceOrder}else{[long]::MaxValue}}},title)
    $script:CatalogPlatformMemory[$Platform]=$rows
    return @($rows)
}
function Merge-Catalog([string]$Platform,$NewEntries) {
    # IMPORTANT for Windows PowerShell 5.1:
    # function output is automatically unrolled. An empty catalog can become
    # $null and a one-item catalog can become a single PSObject. Using += on
    # that PSObject causes: "PSObject does not contain a method named op_Addition".
    # Always materialize a real mutable List[object] here.
    $catalog = New-Object 'System.Collections.Generic.List[object]'
    foreach($g in @(Read-Catalog)) {
        if($null -ne $g){ [void]$catalog.Add($g) }
    }

    $byId=@{}
    $maxOrder=0
    foreach($g in $catalog) {
        $byId[[string]$g.id]=$g
        if([string]$g.platform -eq $Platform) {
            try {
                if($g.PSObject.Properties['sourceOrder'] -and [long]$g.sourceOrder -gt $maxOrder){
                    $maxOrder=[long]$g.sourceOrder
                }
            } catch {}
        }
    }

    $added=0
    foreach($n in @($NewEntries)) {
        if($null -eq $n){ continue }
        $id=[string]$n.id

        if($byId.ContainsKey($id)) {
            $e=$byId[$id]
            foreach($name in @('catalogSource','sourceId','sourceUrl','releaseYear','releaseDateEpoch','igdbId','switchReleaseDate','catalogRule','region','edition','windowsReleaseDate','catalogGenreIds','rating','ratingCount','dailyPriority','dailyOrder','controllerCategory','controllerSupport','fullControllerSupport','preservationProvider','preservationDatUrl','preservationMatchedSources','preservationMatchedSourceUrls','preservationSourceCount','preservationMatch','preservationTitles','preservationSerials','preservationVariantCount')) {
                if($n.PSObject.Properties[$name]){ Set-Prop $e $name $n.$name }
            }
            continue
        }

        $maxOrder++
        Set-Prop $n 'sourceOrder' $maxOrder
        [void]$catalog.Add($n)
        $byId[$id]=$n
        $added++
    }

    Save-Catalog $catalog
    return $added
}
function Strip-Html([string]$s) {
    if($null -eq $s){ return '' }
    $s=[regex]::Replace($s,'(?is)<script.*?</script>|<style.*?</style>',' ')
    $s=[regex]::Replace($s,'(?is)<[^>]+>',' ')
    $s=[Net.WebUtility]::HtmlDecode($s)
    return ($s -replace '\s+',' ').Trim()
}
function Invoke-WebRetry([string]$Uri,[int]$MaxAttempts=4) {
    $last=$null
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++) {
        try {
            return Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers @{
                'User-Agent'=$UserAgent
                'Accept'='text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8'
            } -TimeoutSec 60
        } catch {
            $last=$_
            if($attempt -lt $MaxAttempts){ Start-Sleep -Seconds ([Math]::Min(6,$attempt*2)) }
        }
    }

    # Redump sometimes fails TLS negotiation on older Windows PowerShell even
    # when the site itself is up. Try plain HTTP once; Redump may redirect it.
    if($Uri -match '^https://redump\.org/') {
        try {
            $httpUri=$Uri -replace '^https://','http://'
            return Invoke-WebRequest -UseBasicParsing -Uri $httpUri -Headers @{
                'User-Agent'=$UserAgent
                'Accept'='text/html,application/xhtml+xml,*/*;q=0.8'
            } -TimeoutSec 60
        } catch {}
    }

    if($last){ throw $last }
    throw "Unable to download $Uri"
}
function Invoke-RestRetry([string]$Uri,[int]$MaxAttempts=4) {
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++) {
        try { return Invoke-RestMethod -Uri $Uri -Headers @{'User-Agent'=$UserAgent} -TimeoutSec 60 }
        catch {
            $code=$null
            try{$code=[int]$_.Exception.Response.StatusCode}catch{}
            if($code -eq 429) {
                Start-Sleep -Seconds 65
                continue
            }
            if($attempt -eq $MaxAttempts){ throw }
            Start-Sleep -Seconds ($attempt*2)
        }
    }
}
function Escape-Igdb([string]$s) { return ($s -replace '\\','\\\\' -replace '"','\"') }
function Get-IgdbAuth {
    if($script:IgdbToken -and (Get-Date) -lt $script:IgdbTokenExpires){ return $script:IgdbToken }
    $cfg=Read-Json $IgdbConfigPath $null
    if($null -eq $cfg){ throw 'igdb-config.json is missing.' }
    $cid=[string]$cfg.ClientId
    $sec=[string]$cfg.ClientSecret
    if([string]::IsNullOrWhiteSpace($cid) -or [string]::IsNullOrWhiteSpace($sec) -or $cid -match 'PUT-YOUR' -or $sec -match 'PUT-YOUR') {
        throw 'IGDB credentials are not filled in. Edit igdb-config.json first.'
    }
    $url='https://id.twitch.tv/oauth2/token?client_id='+[uri]::EscapeDataString($cid)+'&client_secret='+[uri]::EscapeDataString($sec)+'&grant_type=client_credentials'
    $r=Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 60
    $script:IgdbToken=[string]$r.access_token
    $seconds=3600
    try{$seconds=[int]$r.expires_in}catch{}
    $script:IgdbTokenExpires=(Get-Date).AddSeconds([Math]::Max(300,$seconds-120))
    return $script:IgdbToken
}
function Wait-IgdbRate {
    # IGDB allows 4 requests/second. Keep a little safety margin so clock
    # granularity/network timing cannot accidentally push us over the limit.
    $elapsed=((Get-Date)-$script:IgdbLastRequest).TotalMilliseconds
    if($elapsed -lt 320){ Start-Sleep -Milliseconds ([int](320-$elapsed)) }
}
function Invoke-IgdbEndpoint([string]$Endpoint,[string]$Body,[int]$MaxAttempts=5) {
    $last=$null
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++) {
        Wait-IgdbRate
        try {
            $token=Get-IgdbAuth
            $cfg=Read-Json $IgdbConfigPath $null
            $headers=@{'Client-ID'=[string]$cfg.ClientId;'Authorization'="Bearer $token";'Accept'='application/json'}
            # Match the standalone PowerShell browser: let Invoke-RestMethod
            # parse IGDB JSON directly instead of routing through
            # Invoke-WebRequest + an extra ConvertFrom-Json pass.
            $r=Invoke-RestMethod -Uri ("https://api.igdb.com/v4/$Endpoint") -Method Post -Headers $headers -ContentType 'text/plain' -Body $Body -TimeoutSec 60
            $script:IgdbLastRequest=Get-Date
            if($null -eq $r){ return @() }
            return @($r | ForEach-Object { $_ })
        } catch {
            $script:IgdbLastRequest=Get-Date
            $last=$_
            $code=$null
            try { $code=[int]$_.Exception.Response.StatusCode } catch {}
            if($attempt -ge $MaxAttempts){ break }

            if($code -eq 429) {
                Write-Host ("[IGDB] rate limited; retrying request ({0}/{1})..." -f $attempt,$MaxAttempts) -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            } else {
                Start-Sleep -Milliseconds ([Math]::Min(3000,500*$attempt))
            }
        }
    }
    if($last){ throw $last }
    throw "IGDB request failed: $Endpoint"
}
function Get-IgdbGameTypeName($Game) {
    try { if($Game.game_type -and $Game.game_type.type){ return ([string]$Game.game_type.type).ToLowerInvariant() } } catch {}
    return ''
}
function Test-PlayableSwitch($Game) {
    if($null -eq $Game -or [string]::IsNullOrWhiteSpace([string]$Game.name)){ return $false }
    try { if($Game.version_parent){ return $false } } catch {}
    $type=Get-IgdbGameTypeName $Game
    if($type -match '^(dlc addon|dlc/addon|expansion|mod|season|pack|update)$'){ return $false }
    return $true
}

function Fetch-SwitchBatch($State) {
    $ps=Get-PlatformState $State 'Nintendo Switch'
    if($ps.complete){ return 0 }
    $limit=500
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $offset=[int]$ps.releaseOffset
    $body='fields game.id,game.name,game.slug,game.game_type.type,game.version_parent,game.first_release_date,game.themes,date,y; ' +
          "where platform = 130 & date <= $now; sort id asc; limit $limit; offset $offset;"
    $rows=@(Invoke-IgdbEndpoint 'release_dates' $body)
    $records=@{}
    foreach($rd in $rows) {
        $g=$rd.game
        if(!(Test-PlayableSwitch $g) -or (Test-IgdbEroticTheme $g)){ continue }
        $gid=$null;try{$gid=[long]$g.id}catch{}
        if(!$gid){ continue }
        $title=[string]$g.name
        $id=Stable-Id 'Nintendo Switch' $title
        $year=$null
        try{if($rd.y){$year=[int]$rd.y}elseif($rd.date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$rd.date).Year}}catch{}
        $entry=New-Entry 'Nintendo Switch' $title 'IGDB' ([string]$gid) ($(if($g.slug){"https://www.igdb.com/games/$($g.slug)"}else{'https://www.igdb.com/'})) $year
        Set-Prop $entry 'igdbId' $gid
        try{Set-Prop $entry 'switchReleaseDate' ([long]$rd.date)}catch{}
        Set-Prop $entry 'catalogRule' 'IGDB release_dates.platform = Nintendo Switch (130)'
        $records[$id]=$entry
    }
    $added=Merge-Catalog 'Nintendo Switch' @($records.Values)
    $ps.releaseOffset=$offset+$limit
    $ps.batches=[int]$ps.batches+1
    if($rows.Count -lt $limit){$ps.complete=$true}
    Save-State $State
    return $added
}

function Redump-Slug([string]$Platform) {
    switch($Platform){'PS2'{'ps2'}'PSP'{'psp'}'PS1'{'psx'}'GameCube'{'gc'}default{throw "Not a Redump platform: $Platform"}}
}
function Get-RedumpDatCode([string]$Platform) {
    switch($Platform){'PS2'{'PS2'}'PSP'{'PSP'}'PS1'{'PSX'}'GameCube'{'GC'}default{throw "Not a Redump platform: $Platform"}}
}
function Convert-RedumpDatTitle([string]$Name) {
    if([string]::IsNullOrWhiteSpace($Name)){ return '' }
    $s=[Net.WebUtility]::HtmlDecode($Name).Trim()

    # DAT names carry preservation metadata at the end of the display title.
    # Strip only known Redump-style metadata groups so the resulting title
    # matches the Daily Chunk database and IGDB lookup names.
    for($i=0;$i -lt 12;$i++) {
        $before=$s
        $s=$s -replace '(?i)\s+\((?:USA|Europe|Japan|World|Asia|Korea|Australia|New Zealand|China|Taiwan|Hong Kong|Canada|Brazil|Latin America|Argentina|Mexico|UK|United Kingdom|France|Germany|Italy|Spain|Portugal|Netherlands|Belgium|Austria|Switzerland|Poland|Russia|Greece|Scandinavia|Sweden|Norway|Denmark|Finland|Czech Republic|Hungary|Israel|South Africa|Singapore)(?:\s*,\s*(?:USA|Europe|Japan|World|Asia|Korea|Australia|New Zealand|China|Taiwan|Hong Kong|Canada|Brazil|Latin America|Argentina|Mexico|UK|United Kingdom|France|Germany|Italy|Spain|Portugal|Netherlands|Belgium|Austria|Switzerland|Poland|Russia|Greece|Scandinavia|Sweden|Norway|Denmark|Finland|Czech Republic|Hungary|Israel|South Africa|Singapore))*\)\s*$',''
        $s=$s -replace '(?i)\s+\((?:En|Ja|Jp|Fr|De|Es|It|Nl|Pt|Ru|Ko|Zh|Sv|No|Da|Fi|Pl|Cs|Hu|He)(?:\s*,\s*(?:En|Ja|Jp|Fr|De|Es|It|Nl|Pt|Ru|Ko|Zh|Sv|No|Da|Fi|Pl|Cs|Hu|He))*\)\s*$',''
        $s=$s -replace '(?i)\s+\((?:Disc|Disk|CD|DVD)\s*\d+(?:\s*of\s*\d+)?\)\s*$',''
        $s=$s -replace '(?i)\s+\((?:Rev(?:ision)?\s*[^)]*|v(?:er(?:sion)?)?\s*[0-9][^)]*)\)\s*$',''
        $s=$s -replace '(?i)\s+\((?:Greatest Hits|Platinum|Essentials|PlayStation 2 the Best|PS one Books|廉価版|Rerelease|Reprint|Alt(?:ernate)?|Bundled|Special Edition|Limited Edition|Collector''s Edition)[^)]*\)\s*$',''
        # No-Intro keeps digital distribution tags in the title. They describe
        # the release medium, not the game title, so strip them for IGDB matching.
        $s=$s -replace '(?i)\s+\((?:eShop|Digital|Download|Nintendo eShop|Wii U eShop|3DS eShop|WiiWare|DSiWare|PSN|PlayStation Network|Xbox Live Arcade|XBLA|Games on Demand|Virtual Console)\)\s*$',''
        if($s -eq $before){ break }
    }
    return $s.Trim()
}
function Test-RedumpDatGameName([string]$RawName) {
    if([string]::IsNullOrWhiteSpace($RawName)){ return $false }
    if($RawName -match '(?i)\((?:Demo|Beta|Prototype|Proto|Sampler|Promo|Kiosk|Trial|Preview|Trade Demo|Press Kit|Debug|Review Code|Taikenban|Tentou|Sample)[^)]*\)'){ return $false }
    if($RawName -match '(?i)\b(Official .*Magazine.*Demo|Demo Disc|Sampler Disc|Preview Disc|Prototype|Test Disc|Utility Disc|DVD Player|Network Access Disc|System Disc|Update Disc)\b'){ return $false }
    return $true
}
function Get-RedumpDatIntersectionIndex([string]$Platform) {
    $code=Get-RedumpDatCode $Platform
    $url="https://redump.info/datfile/$code"
    $zipPath=Join-Path $CacheRoot ("redump-{0}.zip" -f $code.ToLowerInvariant())

    Write-Host ("  [{0}] downloading official Redump DAT: {1}" -f $Platform,$url) -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{
        'User-Agent'=$UserAgent
        'Accept'='application/zip,application/octet-stream,*/*'
    } -OutFile $zipPath -TimeoutSec 120

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $zip=$null;$stream=$null;$reader=$null
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry=@($zip.Entries | Where-Object { $_.Name -match '(?i)\.(dat|xml)$' } | Sort-Object Length -Descending | Select-Object -First 1)
        if(!$entry.Count){ throw 'The Redump ZIP did not contain a DAT/XML file.' }
        $stream=$entry[0].Open()
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $xmlText=$reader.ReadToEnd()
    } finally {
        if($reader){$reader.Dispose()}
        elseif($stream){$stream.Dispose()}
        if($zip){$zip.Dispose()}
    }

    [xml]$doc=$xmlText
    $recordsByKey=@{}
    $nodes=@($doc.SelectNodes('//game | //machine'))
    foreach($node in $nodes) {
        $raw=[string]$node.GetAttribute('name')
        if([string]::IsNullOrWhiteSpace($raw)) {
            try{$raw=[string]$node.description}catch{}
        }
        if(!(Test-RedumpDatGameName $raw)){ continue }

        $title=Convert-RedumpDatTitle $raw
        if([string]::IsNullOrWhiteSpace($title)){ continue }
        $canonicalKey=Normalize-Name $title
        if([string]::IsNullOrWhiteSpace($canonicalKey)){ continue }

        $serial=''
        try {
            $sn=$node.SelectSingleNode('./serial | .//rom/@serial | .//rom/serial')
            if($sn){
                $serial=[string]$sn.InnerText
                if([string]::IsNullOrWhiteSpace($serial)){$serial=[string]$sn.Value}
            }
        } catch {}

        if(!$recordsByKey.ContainsKey($canonicalKey)) {
            $recordsByKey[$canonicalKey]=[pscustomobject]@{
                key=$canonicalKey
                title=$title
                variants=(New-Object 'System.Collections.Generic.List[object]')
            }
        }
        $rec=$recordsByKey[$canonicalKey]
        [void]$rec.variants.Add([pscustomobject]@{title=$raw;serial=$serial})
    }

    $records=@($recordsByKey.Values | Sort-Object title)
    $exact=@{}
    $token=@{}
    foreach($rec in $records) {
        $nk=Normalize-Name ([string]$rec.title)
        if(-not [string]::IsNullOrWhiteSpace($nk)) {
            if(!$exact.ContainsKey($nk)){$exact[$nk]=New-Object 'System.Collections.Generic.List[object]'}
            [void]$exact[$nk].Add($rec)
        }
        $tk=Get-TitleTokenSignature ([string]$rec.title)
        if(-not [string]::IsNullOrWhiteSpace($tk)) {
            if(!$token.ContainsKey($tk)){$token[$tk]=New-Object 'System.Collections.Generic.List[object]'}
            [void]$token[$tk].Add($rec)
        }
    }

    try{Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}catch{}
    return [pscustomobject]@{url=$url;records=$records;exact=$exact;token=$token}
}

function Build-IgdbRedumpIntersectionCatalog([string]$Platform) {
    # IGDB is the canonical game list. Redump is an inclusion test + source of
    # disc/region/revision variants. Only games present in BOTH sources survive.
    $redump=Get-RedumpDatIntersectionIndex $Platform
    $igdbRows=@(Get-IgdbPlatformTitleMap $Platform)
    if(!$igdbRows.Count){ throw 'IGDB platform map is empty.' }
    if(!$redump.records.Count){ throw 'Redump DAT produced no usable game records.' }

    $entries=New-Object 'System.Collections.Generic.List[object]'
    $matchedRedump=@{}
    $matchedExact=0
    $matchedToken=0

    foreach($row in $igdbRows) {
        if($null -eq $row){ continue }
        $gid=0L
        try{$gid=[long]$row.id}catch{}
        $title=[string]$row.name
        if($gid -le 0 -or [string]::IsNullOrWhiteSpace($title)){ continue }

        $names=New-Object 'System.Collections.Generic.List[string]'
        [void]$names.Add($title)
        try {
            foreach($alt in @($row.alternative_names)) {
                if($alt.name){ [void]$names.Add([string]$alt.name) }
            }
        } catch {}

        $candidateByKey=@{}
        foreach($name in $names) {
            $nk=Normalize-Name $name
            if([string]::IsNullOrWhiteSpace($nk)){ continue }
            if($redump.exact.ContainsKey($nk)) {
                # Do not wrap Generic.List<T> in @(...): PowerShell can throw
                # 'Argument types do not match'. Enumerate the list directly.
                foreach($rec in $redump.exact[$nk]){$candidateByKey[[string]$rec.key]=$rec}
            }
        }
        $matchKind='exact'

        if(!$candidateByKey.Count) {
            foreach($name in $names) {
                $tk=Get-TitleTokenSignature $name
                if([string]::IsNullOrWhiteSpace($tk)){ continue }
                if($redump.token.ContainsKey($tk)) {
                    foreach($rec in $redump.token[$tk]){$candidateByKey[[string]$rec.key]=$rec}
                }
            }
            $matchKind='token'
        }

        if(!$candidateByKey.Count){ continue }

        $redumpTitles=New-Object 'System.Collections.Generic.List[string]'
        $redumpSerials=New-Object 'System.Collections.Generic.List[string]'
        $seenTitles=@{};$seenSerials=@{}
        $variantCount=0
        foreach($rec in $candidateByKey.Values) {
            $matchedRedump[[string]$rec.key]=$true
            foreach($variant in $rec.variants) {
                $variantCount++
                $rt=[string]$variant.title
                if(-not [string]::IsNullOrWhiteSpace($rt) -and !$seenTitles.ContainsKey($rt)) {
                    $seenTitles[$rt]=$true;[void]$redumpTitles.Add($rt)
                }
                $rs=[string]$variant.serial
                if(-not [string]::IsNullOrWhiteSpace($rs) -and !$seenSerials.ContainsKey($rs)) {
                    $seenSerials[$rs]=$true;[void]$redumpSerials.Add($rs)
                }
            }
        }

        $year=$null
        try {
            if($row.first_release_date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.first_release_date).Year}
        } catch {}
        $igdbUrl='https://www.igdb.com/'
        try { if($row.slug){$igdbUrl="https://www.igdb.com/games/$($row.slug)"} } catch {}

        $entry=New-Entry $Platform $title 'IGDB + Redump' ([string]$gid) $igdbUrl $year
        # Use the canonical IGDB ID in our local catalog ID. This prevents old
        # Redump-title metadata failures from carrying into the new catalog.
        $entry.id="$Platform::IGDB::$gid"
        Set-Prop $entry 'igdbId' $gid
        Set-Prop $entry 'redumpDatUrl' ([string]$redump.url)
        Set-Prop $entry 'redumpMatch' $(if($matchKind -eq 'token'){'token-signature'}else{'exact-title-or-alias'})
        Set-Prop $entry 'redumpTitles' $redumpTitles.ToArray()
        Set-Prop $entry 'redumpSerials' $redumpSerials.ToArray()
        Set-Prop $entry 'redumpVariantCount' $variantCount
        Set-Prop $entry 'catalogRule' 'Intersection only: canonical IGDB platform-release game must match an official Redump DAT title or IGDB alternative name.'
        [void]$entries.Add($entry)
        if($matchKind -eq 'token'){$matchedToken++}else{$matchedExact++}
    }

    if(!$entries.Count){ throw 'IGDB/Redump intersection was empty; existing catalog was left untouched.' }
    Replace-CatalogPlatform $Platform $entries.ToArray()

    $state=Read-State
    $ps=Get-PlatformState $state $Platform
    $ps.complete=$true
    Set-Prop $ps 'source' 'IGDB + redump.info DAT intersection'
    Set-Prop $ps 'catalogMode' 'igdb-redump-intersection-v1'
    Set-Prop $ps 'igdbGames' $igdbRows.Count
    Set-Prop $ps 'redumpCanonicalTitles' $redump.records.Count
    Set-Prop $ps 'intersectionGames' $entries.Count
    Set-Prop $ps 'updatedAt' ((Get-Date).ToString('o'))
    if($ps.PSObject.Properties['queue']){$ps.queue=@()}
    if($ps.PSObject.Properties['visited']){$ps.visited=@()}
    Save-State $state

    $igdbOnly=[Math]::Max(0,$igdbRows.Count-$entries.Count)
    $redumpOnly=[Math]::Max(0,$redump.records.Count-$matchedRedump.Count)
    Write-Host ("[{0}] intersection complete: {1:N0} games" -f $Platform,$entries.Count) -ForegroundColor Green
    Write-Host ("  IGDB: {0:N0} | Redump canonical titles: {1:N0}" -f $igdbRows.Count,$redump.records.Count) -ForegroundColor DarkGray
    Write-Host ("  matched: exact {0:N0}, smart-title {1:N0}" -f $matchedExact,$matchedToken) -ForegroundColor DarkGray
    Write-Host ("  excluded: IGDB-only {0:N0}, Redump-only/unmatched {1:N0}" -f $igdbOnly,$redumpOnly) -ForegroundColor DarkGray
    return $entries.Count
}

function Replace-CatalogPlatform([string]$Platform,$Entries) {
    $catalog=New-Object 'System.Collections.Generic.List[object]'
    foreach($g in @(Read-Catalog)) {
        if($null -ne $g -and [string]$g.platform -ne $Platform){ [void]$catalog.Add($g) }
    }
    $order=0
    foreach($g in $Entries) {
        if($null -eq $g){ continue }
        $order++
        Set-Prop $g 'sourceOrder' $order
        [void]$catalog.Add($g)
    }
    Save-Catalog $catalog
}
function Fetch-RedumpDatCatalog([string]$Platform,$State) {
    $code=Get-RedumpDatCode $Platform
    $url="https://redump.info/datfile/$code"
    $zipPath=Join-Path $CacheRoot ("redump-{0}.zip" -f $code.ToLowerInvariant())

    Write-Host ("  downloading official Redump DAT: {0}" -f $url) -ForegroundColor DarkGray
    Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{
        'User-Agent'=$UserAgent
        'Accept'='application/zip,application/octet-stream,*/*'
    } -OutFile $zipPath -TimeoutSec 120

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=$null;$stream=$null;$reader=$null
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($zipPath)
        $entry=@($zip.Entries | Where-Object { $_.Name -match '(?i)\.(dat|xml)$' } | Sort-Object Length -Descending | Select-Object -First 1)
        if(!$entry.Count){ throw 'The Redump ZIP did not contain a DAT/XML file.' }
        $stream=$entry[0].Open()
        $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
        $xmlText=$reader.ReadToEnd()
    } finally {
        if($reader){$reader.Dispose()}
        elseif($stream){$stream.Dispose()}
        if($zip){$zip.Dispose()}
    }

    [xml]$doc=$xmlText
    $records=@{}
    $nodes=@($doc.SelectNodes('//game | //machine'))
    foreach($node in $nodes) {
        $raw=[string]$node.GetAttribute('name')
        if([string]::IsNullOrWhiteSpace($raw)) {
            try{$raw=[string]$node.description}catch{}
        }
        if(!(Test-RedumpDatGameName $raw)){ continue }
        $title=Convert-RedumpDatTitle $raw
        if([string]::IsNullOrWhiteSpace($title)){ continue }

        $id=Stable-Id $Platform $title
        if($records.ContainsKey($id)){ continue }

        $serial=''
        try {
            $sn=$node.SelectSingleNode('./serial | .//rom/@serial | .//rom/serial')
            if($sn){$serial=[string]$sn.InnerText;if([string]::IsNullOrWhiteSpace($serial)){$serial=[string]$sn.Value}}
        } catch {}

        $e=New-Entry $Platform $title 'Redump' $serial $url
        Set-Prop $e 'catalogRule' 'Official redump.info system DAT; demo/prototype/promo entries excluded; regional/revision duplicates collapsed by title.'
        $records[$id]=$e
    }

    $entries=@($records.Values | Sort-Object title)
    Replace-CatalogPlatform $Platform $entries

    $ps=Get-PlatformState $State $Platform
    $ps.complete=$true
    $ps.batches=1
    Set-Prop $ps 'source' 'redump.info DAT'
    Set-Prop $ps 'datUrl' $url
    Set-Prop $ps 'updatedAt' ((Get-Date).ToString('o'))
    # Old crawler fields are no longer used, but clear them to avoid huge state files.
    if($ps.PSObject.Properties['queue']){$ps.queue=@()}
    if($ps.PSObject.Properties['visited']){$ps.visited=@()}
    Save-State $State
    try{Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}catch{}
    return $entries.Count
}
function Redump-PageNumber([string]$Url) {
    if($Url -match '/page/(\d+)/?'){return [int]$Matches[1]}
    if($Url -match '[?&]page=(\d+)'){return [int]$Matches[1]}
    return 1
}
function Fetch-RedumpBatch([string]$Platform,$State) {
    $ps=Get-PlatformState $State $Platform
    if($ps.complete){ return 0 }
    $slug=Redump-Slug $Platform
    $queue=@($ps.queue)
    $visited=@($ps.visited)
    if(!$queue.Count){$ps.complete=$true;Save-State $State;return 0}
    $url=[string]$queue[0]
    if($queue.Count -gt 1){$queue=@($queue[1..($queue.Count-1)])}else{$queue=@()}
    if($visited -contains $url){$ps.queue=$queue;Save-State $State;return 0}
    $r=Invoke-WebRetry $url
    $records=@{}
    foreach($m in [regex]::Matches([string]$r.Content,'(?is)<tr[^>]*>(.*?)</tr>')) {
        $cells=[regex]::Matches($m.Groups[1].Value,'(?is)<td[^>]*>(.*?)</td>')
        if($cells.Count -lt 6){continue}
        $titleCell=$cells[1].Groups[1].Value
        $am=[regex]::Match($titleCell,'(?is)<a[^>]*>(.*?)</a>')
        $title=if($am.Success){Strip-Html $am.Groups[1].Value}else{Strip-Html $titleCell}
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $edition=if($cells.Count -gt 4){Strip-Html $cells[4].Groups[1].Value}else{''}
        $serial=if($cells.Count -gt 6){Strip-Html $cells[6].Groups[1].Value}else{''}
        $region=if($cells.Count -gt 0){Strip-Html $cells[0].Groups[1].Value}else{''}
        if($edition -match '(?i)\b(Demo|Preview|Prototype|Beta|Trial|Sampler|Kiosk|Promo)\b'){continue}
        if($title -match '(?i)(Official .*Magazine.*Demo|Demo Disc|Demo One|Sampler Disc|Preview Disc|Prototype|Test Disc|Utility Disc|DVD Player|Network Access Disc|System Disc|Update Disc)'){continue}
        $id=Stable-Id $Platform $title
        if(!$records.ContainsKey($id)) {
            $e=New-Entry $Platform $title 'Redump' $serial $url
            Set-Prop $e 'region' $region
            Set-Prop $e 'edition' $edition
            $records[$id]=$e
        }
    }
    $visited += $url
    foreach($link in @($r.Links)) {
        $href=[string]$link.href
        if([string]::IsNullOrWhiteSpace($href)){continue}
        $candidate=$null
        if($href -match "^/discs/system/$slug/page/\d+/?$"){$candidate="https://redump.org$href"}
        elseif($href -match "^/discs/system/$slug/\?page=\d+"){$candidate="https://redump.org$href"}
        if($candidate -and !($visited -contains $candidate) -and !($queue -contains $candidate)){ $queue += $candidate }
    }
    $queue=@($queue | Sort-Object { Redump-PageNumber $_ })
    $ps.queue=$queue
    $ps.visited=$visited
    $ps.batches=[int]$ps.batches+1
    if(!$queue.Count){$ps.complete=$true}
    $added=Merge-Catalog $Platform @($records.Values)
    Save-State $State
    return $added
}

function Wait-PcgwRate {
    $elapsed=((Get-Date)-$script:PcgwLastRequest).TotalMilliseconds
    if($elapsed -lt 2200){ Start-Sleep -Milliseconds ([int](2200-$elapsed)) }
}
function Get-PcgwControllerCategory([string]$ControllerSupport,[string]$FullControllerSupport) {
    $c=([string]$ControllerSupport).Trim().ToLowerInvariant()
    $f=([string]$FullControllerSupport).Trim().ToLowerInvariant()

    if($f -in @('true','always on')){ return 'Full' }

    $controllerPositive = $c -in @('true','always on','limited','hackable')
    $fullLimited = $f -in @('limited','hackable')

    if($controllerPositive -or $fullLimited){ return 'Partial' }
    if($c -eq 'false'){ return 'None' }
    return 'Unknown'
}

function Get-PcgwControllerBatch($Games) {
    # Windows catalog rows now come from IGDB, so resolve PCGamingWiki page IDs
    # from game titles first, then query the Input Cargo table for controller data.
    $list=@($Games | Where-Object {
        $null -ne $_ -and
        [string]$_.platform -eq 'Windows' -and
        -not [string]::IsNullOrWhiteSpace([string]$_.title)
    } | Select-Object -First 50)

    $result=@{}
    if(!$list.Count){ return $result }

    $normToGames=@{}
    foreach($g in $list) {
        $nk=Normalize-Name ([string]$g.title)
        if(!$normToGames.ContainsKey($nk)){ $normToGames[$nk]=New-Object 'System.Collections.Generic.List[object]' }
        [void]$normToGames[$nk].Add($g)
    }

    # Resolve up to 50 page titles in one MediaWiki API request.
    Wait-PcgwRate
    $titleText=(@($list | ForEach-Object {[string]$_.title}) -join '|')
    $params=[ordered]@{
        action='query';titles=$titleText;redirects='1';format='json';formatversion='2'
    }
    $pairs=@();foreach($k in $params.Keys){$pairs += ([uri]::EscapeDataString([string]$k)+'='+[uri]::EscapeDataString([string]$params[$k]))}
    $resolveUrl='https://www.pcgamingwiki.com/w/api.php?'+($pairs -join '&')
    $reply=Invoke-RestRetry $resolveUrl
    $script:PcgwLastRequest=Get-Date

    # Map redirect targets back to original normalized names when possible.
    $redirectFromTo=@{}
    foreach($r in @($reply.query.redirects)) {
        $redirectFromTo[(Normalize-Name ([string]$r.to))]=(Normalize-Name ([string]$r.from))
    }

    $pageToGame=@{}
    $ids=New-Object 'System.Collections.Generic.List[long]'
    foreach($page in @($reply.query.pages)) {
        $pageId=$null;try{$pageId=[long]$page.pageid}catch{}
        if(!$pageId -or $page.missing){ continue }
        $nk=Normalize-Name ([string]$page.title)
        $candidateKey=$nk
        if(!$normToGames.ContainsKey($candidateKey) -and $redirectFromTo.ContainsKey($nk)){$candidateKey=$redirectFromTo[$nk]}
        if($normToGames.ContainsKey($candidateKey)) {
            $g=$normToGames[$candidateKey][0]
            $pageToGame[[string]$pageId]=$g
            [void]$ids.Add($pageId)
        }
    }

    if(!$ids.Count) {
        foreach($g in $list){
            $result[[string]$g.id]=[pscustomobject]@{controllerCategory='Unknown';controllerSupport='unknown';fullControllerSupport='unknown';controllerSource='PCGamingWiki'}
        }
        return $result
    }

    Wait-PcgwRate
    $csv=(@($ids) -join ',')
    $fields='Input._pageID=PageID,Input.Controller_support=ControllerSupport,Input.Full_controller_support=FullControllerSupport'
    $where="Input._pageID IN ($csv)"
    $params=[ordered]@{action='cargoquery';tables='Input';fields=$fields;where=$where;limit='100';format='json'}
    $pairs=@();foreach($k in $params.Keys){$pairs += ([uri]::EscapeDataString([string]$k)+'='+[uri]::EscapeDataString([string]$params[$k]))}
    $url='https://www.pcgamingwiki.com/w/api.php?'+($pairs -join '&')
    $reply2=Invoke-RestRetry $url
    $script:PcgwLastRequest=Get-Date

    $seen=@{}
    foreach($row in @($reply2.cargoquery)) {
        $t=$row.title;if($null -eq $t){continue}
        $pageId=[string]$t.PageID
        if(!$pageToGame.ContainsKey($pageId)){continue}
        $g=$pageToGame[$pageId]
        $c=[string]$t.ControllerSupport;$f=[string]$t.FullControllerSupport
        $result[[string]$g.id]=[pscustomobject]@{
            controllerCategory=(Get-PcgwControllerCategory $c $f)
            controllerSupport=$c
            fullControllerSupport=$f
            controllerSource='PCGamingWiki'
        }
        $seen[[string]$g.id]=$true
    }

    foreach($g in $list) {
        $key=[string]$g.id
        if(!$seen.ContainsKey($key)) {
            $result[$key]=[pscustomobject]@{controllerCategory='Unknown';controllerSupport='unknown';fullControllerSupport='unknown';controllerSource='PCGamingWiki'}
        }
    }
    return $result
}

function Fetch-WindowsBatch($State) {
    $ps=Get-PlatformState $State 'Windows'
    if($ps.complete){ return 0 }

    # IGDB platform 6 is PC (Windows). Keep Windows on-demand just like Switch.
    $limit=500
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $offset=[int]$ps.releaseOffset
    $body='fields game.id,game.name,game.slug,game.game_type.type,game.version_parent,game.first_release_date,game.themes,date,y; ' +
          "where platform = 6 & date <= $now; sort id asc; limit $limit; offset $offset;"
    $rows=@(Invoke-IgdbEndpoint 'release_dates' $body)

    $records=@{}
    foreach($rd in $rows) {
        $g=$rd.game
        if(!(Test-PlayableSwitch $g) -or (Test-IgdbEroticTheme $g)){ continue }
        $gid=$null;try{$gid=[long]$g.id}catch{}
        if(!$gid){ continue }
        $title=[string]$g.name
        if([string]::IsNullOrWhiteSpace($title)){ continue }
        $id=Stable-Id 'Windows' $title
        $year=$null
        try{if($rd.y){$year=[int]$rd.y}elseif($rd.date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$rd.date).Year}}catch{}
        $entry=New-Entry 'Windows' $title 'IGDB' ([string]$gid) ($(if($g.slug){"https://www.igdb.com/games/$($g.slug)"}else{'https://www.igdb.com/'})) $year
        Set-Prop $entry 'igdbId' $gid
        try{Set-Prop $entry 'windowsReleaseDate' ([long]$rd.date)}catch{}
        Set-Prop $entry 'catalogRule' 'IGDB release_dates.platform = PC (6)'
        $records[$id]=$entry
    }

    $added=Merge-Catalog 'Windows' @($records.Values)
    $ps.releaseOffset=$offset+$limit
    $ps.batches=[int]$ps.batches+1
    $ps.source='IGDB'
    if($rows.Count -lt $limit){$ps.complete=$true}
    Save-State $State
    return $added
}

function Fetch-More([string]$Platform,$State) {
    switch($Platform) {
        'Nintendo Switch' { return Fetch-SwitchBatch $State }
        'Windows' { return Fetch-WindowsBatch $State }
        'PS2' { return Fetch-RedumpBatch 'PS2' $State }
        'PSP' { return Fetch-RedumpBatch 'PSP' $State }
        'PS1' { return Fetch-RedumpBatch 'PS1' $State }
        'GameCube' { return Fetch-RedumpBatch 'GameCube' $State }
        default { throw "Unknown platform: $Platform" }
    }
}
function Get-OnDemandPage([string]$Platform,[int]$Offset,[int]$Limit,[string]$Query) {
    if(!($Platforms -contains $Platform)){throw "Unknown platform: $Platform"}
    $Offset=[Math]::Max(0,$Offset)
    $Limit=[Math]::Min(200,[Math]::Max(20,$Limit))
    $state=Read-State
    $ps=Get-PlatformState $state $Platform

    if(-not [string]::IsNullOrWhiteSpace($Query)) {
        $cached=@(Get-CatalogPlatform @(Read-Catalog) $Platform)
        $q=$Query.ToLowerInvariant()
        $matches=@($cached | Where-Object { ([string]$_.title).ToLowerInvariant().Contains($q) })
        return [pscustomobject]@{
            items=@($matches | Select-Object -Skip $Offset -First $Limit)
            cachedCount=$cached.Count
            matchingCount=$matches.Count
            complete=[bool]$ps.complete
            sourceFetched=$false
            searchScope='cached'
            warning=$null
        }
    }

    # PS2 / PSP / PS1 / GameCube are prebuilt before launch and are cache-only
    # while the website is running. Only Switch and Windows fetch on demand.
    if($StaticCachePlatforms -contains $Platform) {
        $cached=@(Get-CatalogPlatform @(Read-Catalog) $Platform)
        return [pscustomobject]@{
            items=@($cached | Select-Object -Skip $Offset -First $Limit)
            cachedCount=$cached.Count
            matchingCount=$cached.Count
            complete=[bool]$ps.complete
            sourceFetched=$false
            searchScope='cache-only'
            warning=$(if($ps.complete){$null}else{'Static cache is incomplete. Run BUILD CACHE ONLY.bat to retry the prebuild.'})
        }
    }

    $target=$Offset+$Limit
    $sourceFetched=$false
    $sourceError=$null
    $guard=0

    while($true) {
        $cached=@(Get-CatalogPlatform @(Read-Catalog) $Platform)
        if($cached.Count -ge $target -or $ps.complete){break}
        $before=$cached.Count

        try {
            [void](Fetch-More $Platform $state)
            $sourceFetched=$true
        } catch {
            $sourceError=$_.Exception.Message
            break
        }

        $state=Read-State
        $ps=Get-PlatformState $state $Platform
        $after=@(Get-CatalogPlatform @(Read-Catalog) $Platform).Count
        $guard++
        if($guard -ge 5){break}
        if($after -le $before -and !$ps.complete){continue}
    }

    $cached=@(Get-CatalogPlatform @(Read-Catalog) $Platform)
    $items=@($cached | Select-Object -Skip $Offset -First $Limit)
    return [pscustomobject]@{
        items=$items
        cachedCount=$cached.Count
        matchingCount=$cached.Count
        complete=[bool]$ps.complete
        sourceFetched=$sourceFetched
        searchScope='source'
        warning=$sourceError
    }
}

function Convert-IgdbRowToMetadata($chosen,$FallbackTitle) {
    if($null -eq $chosen) {
        return [pscustomobject]@{
            status='not-found'
            title=[string]$FallbackTitle
            fetchedAt=(Get-Date).ToString('o')
        }
    }

    $cover=$null
    try {
        if($chosen.cover.image_id){
            $cover="https://images.igdb.com/igdb/image/upload/t_cover_big_2x/$($chosen.cover.image_id).jpg"
        }
    } catch {}

    $shots=@()
    foreach($s in @($chosen.screenshots)) {
        if($s.image_id){
            $shots+="https://images.igdb.com/igdb/image/upload/t_screenshot_big_2x/$($s.image_id).jpg"
        }
    }

    $videos=@()
    foreach($v in @($chosen.videos)) {
        if($v.video_id){
            $videos += [pscustomobject]@{
                name=[string]$v.name
                youtubeId=[string]$v.video_id
            }
        }
    }

    $genreIds=@();$genreTags=@()
    foreach($g in @($chosen.genres)){try{if($g.id){$id=[long]$g.id;$genreIds += $id;$genreTags += [pscustomobject]@{id=$id;name=[string]$g.name}}}catch{}}

    $modes=@()
    foreach($m in @($chosen.game_modes)){if($m.name){$modes += [string]$m.name}}

    $year=$null
    try {
        if($chosen.first_release_date){
            $year=[DateTimeOffset]::FromUnixTimeSeconds([long]$chosen.first_release_date).Year
        }
    } catch {}

    return [pscustomobject]@{
        status='ok'
        igdbId=[int]$chosen.id
        igdbName=[string]$chosen.name
        igdbUrl=$(if($chosen.slug){"https://www.igdb.com/games/$($chosen.slug)"}else{$null})
        releaseYear=$year
        rating=$chosen.rating
        ratingCount=$chosen.rating_count
        aggregatedRating=$chosen.aggregated_rating
        summary=[string]$chosen.summary
        genreIds=@($genreIds)
        genreTags=@($genreTags)
        gameModes=@($modes)
        cover=$cover
        screenshots=@($shots)
        videos=@($videos)
        fetchedAt=(Get-Date).ToString('o')
    }
}

function Convert-IgdbRowToCardMetadata($chosen,$FallbackTitle) {
    if($null -eq $chosen) {
        return [pscustomobject]@{status='not-found';detailsLoaded=$true;title=[string]$FallbackTitle}
    }
    $cover=$null
    try{if($chosen.cover.image_id){$cover="https://images.igdb.com/igdb/image/upload/t_cover_big_2x/$($chosen.cover.image_id).jpg"}}catch{}
    $genreIds=@();$genreTags=@();foreach($g in @($chosen.genres)){try{if($g.id){$id=[long]$g.id;$genreIds += $id;$genreTags += [pscustomobject]@{id=$id;name=[string]$g.name}}}catch{}}
    $year=$null;try{if($chosen.first_release_date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$chosen.first_release_date).Year}}catch{}
    return [pscustomobject]@{
        status='ok'
        detailsLoaded=$false
        igdbId=[int]$chosen.id
        igdbName=[string]$chosen.name
        igdbUrl=$(if($chosen.slug){"https://www.igdb.com/games/$($chosen.slug)"}else{$null})
        releaseYear=$year
        rating=$chosen.rating
        ratingCount=$chosen.rating_count
        genreIds=@($genreIds)
        genreTags=@($genreTags)
        cover=$cover
    }
}

function Get-IgdbCardMetadataBatch($Games) {
    # Fast list/card path: only fields that are visible before the gallery opens.
    # Screenshots, videos and summary are deliberately deferred to /api/enrich
    # for the single game the user opens.
    $list=@($Games | Where-Object {$null -ne $_});$result=@{};if(!$list.Count){return $result}
    $idToGame=@{};$numericIds=New-Object 'System.Collections.Generic.List[long]'
    foreach($game in $list){$gid=$null;try{if($game.igdbId){$gid=[long]$game.igdbId}}catch{};if($gid -and !$idToGame.ContainsKey([string]$gid)){$idToGame[[string]$gid]=$game;[void]$numericIds.Add($gid)}}
    if(!$numericIds.Count){return $result}
    $ids=@($numericIds | Select-Object -First 100);$csv=($ids -join ',')
    Write-Host "[IGDB] cards: $($ids.Count) IDs -> ONE lightweight /games request" -ForegroundColor Cyan
    $fields='fields id,name,slug,first_release_date,rating,rating_count,genres.id,genres.name,cover.image_id;'
    $rows=@(Invoke-IgdbEndpoint 'games' "$fields where id = ($csv); limit 100;")
    $returned=@{};foreach($row in $rows){$gid=[string]$row.id;$returned[$gid]=$true;if($idToGame.ContainsKey($gid)){$game=$idToGame[$gid];$result[[string]$game.id]=Convert-IgdbRowToCardMetadata $row ([string]$game.title)}}
    foreach($gid in $ids){$key=[string]$gid;if(!$returned.ContainsKey($key) -and $idToGame.ContainsKey($key)){$game=$idToGame[$key];$result[[string]$game.id]=Convert-IgdbRowToCardMetadata $null ([string]$game.title)}}
    return $result
}

function Get-IgdbMetadataBatch($Games) {
    # Exact-ID fast path.
    # IGDB supports: where id = (1,2,3,...)
    # One request can therefore enrich many Switch cards at once.
    $list=@($Games | Where-Object { $null -ne $_ })
    $result=@{}
    if(!$list.Count){ return $result }

    $idToGame=@{}
    $numericIds=New-Object 'System.Collections.Generic.List[long]'

    foreach($game in $list) {
        $gid=$null
        try {
            if($game.igdbId){ $gid=[long]$game.igdbId }
        } catch {}

        if($gid) {
            if(!$idToGame.ContainsKey([string]$gid)) {
                $idToGame[[string]$gid]=$game
                [void]$numericIds.Add($gid)
            }
        }
    }

    if(!$numericIds.Count){ return $result }

    # The browser sends at most 100 IDs. Keep the same server-side cap so
    # one visible 100-card page becomes one IGDB /games request.
    $ids=@($numericIds | Select-Object -First 100)
    $csv=($ids -join ',')
    Write-Host "[IGDB] metadata: $($ids.Count) IDs -> ONE /games request" -ForegroundColor Cyan

    $fields='fields id,name,slug,first_release_date,rating,rating_count,aggregated_rating,summary,genres.id,genres.name,game_modes.name,cover.image_id,screenshots.image_id,videos.name,videos.video_id;'
    $rows=@(Invoke-IgdbEndpoint 'games' "$fields where id = ($csv); limit 100;")

    $returned=@{}
    foreach($row in $rows) {
        $gid=[string]$row.id
        $returned[$gid]=$true
        if($idToGame.ContainsKey($gid)) {
            $game=$idToGame[$gid]
            $result[[string]$game.id]=Convert-IgdbRowToMetadata $row ([string]$game.title)
        }
    }

    # Cache explicit not-found results too, so missing records don't get
    # requested over and over on every scroll.
    foreach($gid in $ids) {
        $key=[string]$gid
        if(!$returned.ContainsKey($key) -and $idToGame.ContainsKey($key)) {
            $game=$idToGame[$key]
            $result[[string]$game.id]=Convert-IgdbRowToMetadata $null ([string]$game.title)
        }
    }

    return $result
}

function Get-IgdbPlatformDirectory {
    if($null -ne $script:IgdbPlatformDirectory){ return @($script:IgdbPlatformDirectory) }
    $path=Join-Path $CacheRoot 'igdb-platform-directory.json'
    $rows=@((Read-Json $path @()) | ForEach-Object { $_ })
    if(!$rows.Count){
        $rows=@(Invoke-IgdbEndpoint 'platforms' 'fields id,name,slug; sort name asc; limit 500;')
        if($rows.Count){Write-JsonAtomic $rows $path}
    }
    $script:IgdbPlatformDirectory=$rows
    return @($rows)
}
function Get-IgdbPlatformId([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    if($null -eq $cfg){ return $null }
    try{if($cfg.igdbId){return [long]$cfg.igdbId}}catch{}
    $aliases=New-Object 'System.Collections.Generic.List[string]'
    [void]$aliases.Add($Platform)
    try{foreach($a in $cfg.igdbNames){if($a){[void]$aliases.Add([string]$a)}}}catch{}
    $rows=@(Get-IgdbPlatformDirectory)
    foreach($alias in $aliases){
        $nk=Normalize-Name $alias
        foreach($r in $rows){
            if((Normalize-Name ([string]$r.name)) -eq $nk -or (Normalize-Name ([string]$r.slug)) -eq $nk){
                return [long]$r.id
            }
        }
    }
    # Conservative fallback: only accept a unique containment match.
    foreach($alias in $aliases){
        $nk=Normalize-Name $alias
        if($nk.Length -lt 4){continue}
        $matches=@($rows | Where-Object {
            $rn=Normalize-Name ([string]$_.name)
            $rn -eq $nk -or $rn.StartsWith($nk+' ') -or $nk.StartsWith($rn+' ')
        })
        if($matches.Count -eq 1){return [long]$matches[0].id}
    }
    Write-Warning ("IGDB platform ID could not be resolved for '{0}'." -f $Platform)
    return $null
}

function Get-IgdbUpdatedAtRowsV6([string]$Endpoint,[long]$FromUnix,[long]$ToUnix,[string]$Fields) {
    $items=New-Object 'System.Collections.Generic.List[object]'
    if($FromUnix -le 0 -or $ToUnix -le $FromUnix){return @()}
    $offset=0
    while($true) {
        $body="$Fields where updated_at > $FromUnix & updated_at <= $ToUnix; sort updated_at asc; limit 500; offset $offset;"
        $rows=@(Invoke-IgdbEndpoint $Endpoint $body)
        foreach($row in $rows){if($null -ne $row){[void]$items.Add($row)}}
        if($rows.Count -lt 500){break}
        $offset += $rows.Count
    }
    return $items.ToArray()
}
function Test-IgdbEroticTheme($Game) {
    if($null -eq $Game){return $false}
    try {
        foreach($theme in @($Game.themes)) {
            try {
                $id=0L
                if($theme -is [ValueType] -or $theme -is [string]){$id=[long]$theme}
                elseif($theme.PSObject.Properties['id']){$id=[long]$theme.id}
                if($id -eq 42L){return $true}
            } catch {}
        }
    } catch {}
    return $false
}
function Test-IgdbGameHasPlatformV6($Game,[long]$PlatformId) {
    if($null -eq $Game -or $PlatformId -le 0){return $false}
    if(Test-IgdbEroticTheme $Game){return $false}
    try {
        foreach($p in @($Game.platforms)) {
            try {
                if($p -is [ValueType] -or $p -is [string]) {
                    if([long]$p -eq $PlatformId){return $true}
                } elseif($p.PSObject.Properties['id'] -and [long]$p.id -eq $PlatformId) {
                    return $true
                }
            } catch {}
        }
    } catch {}
    return $false
}
function Get-LegacyIgdbMapBaselineUnixV7([string]$MapPath,[string]$StatePath) {
    # V3.4 did not save an IGDB updated_at watermark. The completed map file's
    # write time is the closest durable record of when that map was last built.
    # Start 24 hours earlier as a safety overlap so edits near/during the old
    # build are replayed instead of being silently missed.
    $stamp=$null
    try { if(Test-Path -LiteralPath $MapPath){$stamp=(Get-Item -LiteralPath $MapPath).LastWriteTimeUtc} } catch {}
    if($null -eq $stamp) {
        try { if(Test-Path -LiteralPath $StatePath){$stamp=(Get-Item -LiteralPath $StatePath).LastWriteTimeUtc} } catch {}
    }
    if($null -eq $stamp){return 0L}
    try {
        $baseline=([DateTimeOffset]$stamp).AddHours(-24).ToUnixTimeSeconds()
        $ceiling=[DateTimeOffset]::UtcNow.AddSeconds(-10).ToUnixTimeSeconds()
        if($baseline -ge $ceiling){$baseline=$ceiling-86400}
        if($baseline -lt 1){$baseline=1}
        return [long]$baseline
    } catch { return 0L }
}
function Adopt-LegacyIgdbUpdatedAtStateV7([string]$Platform,$State,[string]$StatePath,[string]$MapPath) {
    if($null -eq $State){return $false}
    $complete=$false;$schema='';$rel=0L;$game=0L
    try{$complete=[bool]$State.complete}catch{}
    try{$schema=[string]$State.syncSchema}catch{}
    try{$rel=[long]$State.lastReleaseSyncUnix}catch{}
    try{$game=[long]$State.lastGameSyncUnix}catch{}
    if(!$complete){return $false}
    if($schema -eq 'updated-at-v1' -and $rel -gt 0 -and $game -gt 0){return $true}
    if(!(Test-Path -LiteralPath $MapPath)){return $false}

    $baseline=Get-LegacyIgdbMapBaselineUnixV7 $MapPath $StatePath
    if($baseline -le 0){return $false}
    Set-Prop $State 'syncSchema' 'updated-at-v1'
    Set-Prop $State 'lastReleaseSyncUnix' $baseline
    Set-Prop $State 'lastGameSyncUnix' $baseline
    Set-Prop $State 'syncBaselineUnix' 0
    if($null -eq $State.PSObject.Properties['contentRevision']){Set-Prop $State 'contentRevision' 0}
    Set-Prop $State 'legacyV34BaselineUnix' $baseline
    Set-Prop $State 'legacyV34BaselineSource' 'map-file-time-minus-24h'
    Set-Prop $State 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
    Write-JsonAtomic $State $StatePath
    $when=[DateTimeOffset]::FromUnixTimeSeconds($baseline).UtcDateTime.ToString('u')
    Write-Host ("[{0}] adopted completed V3.4 IGDB map; incremental catch-up starts at {1} UTC (24h safety overlap)." -f $Platform,$when) -ForegroundColor DarkCyan
    return $true
}

function Initialize-IgdbUpdatedAtChangeCacheV6 {
    if($null -ne $script:IgdbUpdatedAtChangeCacheV6){return $script:IgdbUpdatedAtChangeCacheV6}

    # Keep the high-water mark a few seconds behind wall-clock time. This avoids
    # missing an update that lands in the same timestamp second while we query.
    $cutoff=[DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds()
    $minRelease=[long]::MaxValue
    $minGame=[long]::MaxValue
    $eligible=0
    foreach($platformName in $StaticCachePlatforms) {
        $safeName=($platformName.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
        $statePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeName)
        $mapPath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}.json" -f $safeName)
        $st=Read-Json $statePath $null
        if($null -eq $st){continue}
        # Upgrade an already-complete V3.4 map in place. This preserves the full
        # cached map and replays only IGDB records changed since its build time.
        [void](Adopt-LegacyIgdbUpdatedAtStateV7 $platformName $st $statePath $mapPath)
        $st=Read-Json $statePath $st
        $complete=$false;$schema='';$rel=0L;$game=0L
        try{$complete=[bool]$st.complete}catch{}
        try{$schema=[string]$st.syncSchema}catch{}
        try{$rel=[long]$st.lastReleaseSyncUnix}catch{}
        try{$game=[long]$st.lastGameSyncUnix}catch{}
        if(!$complete -or $schema -ne 'updated-at-v1' -or $rel -le 0 -or $game -le 0){continue}
        if($rel -lt $minRelease){$minRelease=$rel}
        if($game -lt $minGame){$minGame=$game}
        $eligible++
    }

    if($eligible -le 0) {
        $script:IgdbUpdatedAtChangeCacheV6=[pscustomobject]@{
            cutoffUnix=$cutoff;eligiblePlatforms=0;releaseRows=@();gameRows=@()
        }
        return $script:IgdbUpdatedAtChangeCacheV6
    }

    Write-Host ("[IGDB] incremental updated_at window: {0} cached platforms" -f $eligible) -ForegroundColor DarkCyan
    $releaseFields='fields id,platform,updated_at,game.id,game.name,game.slug,game.first_release_date,game.alternative_names.name,game.genres.id,game.rating,game.rating_count,game.platforms,game.themes;'
    $gameFields='fields id,name,slug,first_release_date,alternative_names.name,genres.id,rating,rating_count,platforms,themes,updated_at;'
    $releaseRows=@(Get-IgdbUpdatedAtRowsV6 'release_dates' $minRelease $cutoff $releaseFields)
    $gameRows=@(Get-IgdbUpdatedAtRowsV6 'games' $minGame $cutoff $gameFields)
    Write-Host ("[IGDB] changed since oldest cached sync: {0:N0} release rows, {1:N0} game rows" -f $releaseRows.Count,$gameRows.Count) -ForegroundColor DarkGray

    $script:IgdbUpdatedAtChangeCacheV6=[pscustomobject]@{
        cutoffUnix=$cutoff
        eligiblePlatforms=$eligible
        minReleaseSyncUnix=$minRelease
        minGameSyncUnix=$minGame
        releaseRows=$releaseRows
        gameRows=$gameRows
    }
    return $script:IgdbUpdatedAtChangeCacheV6
}
function Test-IgdbPlatformMapIncrementalV6([string]$Platform) {
    $probeKey=(State-Key $Platform)
    if($script:IgdbIncrementalProbeResults.ContainsKey($probeKey)){
        $saved=$script:IgdbIncrementalProbeResults[$probeKey]
        try{return [bool]$saved.needsRefresh}catch{return [bool]$saved}
    }
    $platformId=Get-IgdbPlatformId $Platform
    if(!$platformId){$script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$true;mode='full'};return $true}
    $safeName=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    $mapPath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}.json" -f $safeName)
    $statePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeName)
    $mapState=Read-Json $statePath $null
    if($null -eq $mapState){$script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$true;mode='full'};return $true}
    $isComplete=$false;$schema='';$lastReleaseSync=0L;$lastGameSync=0L
    try{$isComplete=[bool]$mapState.complete}catch{}
    try{$schema=[string]$mapState.syncSchema}catch{}
    try{$lastReleaseSync=[long]$mapState.lastReleaseSyncUnix}catch{}
    try{$lastGameSync=[long]$mapState.lastGameSyncUnix}catch{}
    if(!$isComplete){$script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$true;mode='resume'};return $true}

    # If this is a completed V3.4 map, adopt it in place instead of forcing a
    # historical rescan. The migration baseline comes from the map file's write
    # time minus a 24-hour overlap, then updated_at deltas catch it up.
    if($schema -ne 'updated-at-v1' -or $lastReleaseSync -le 0 -or $lastGameSync -le 0) {
        if(Adopt-LegacyIgdbUpdatedAtStateV7 $Platform $mapState $statePath $mapPath) {
            $mapState=Read-Json $statePath $mapState
            try{$schema=[string]$mapState.syncSchema}catch{}
            try{$lastReleaseSync=[long]$mapState.lastReleaseSyncUnix}catch{}
            try{$lastGameSync=[long]$mapState.lastGameSyncUnix}catch{}
        } else {
            Write-Host ("[{0}] no usable completed V3.4 map timestamp; full map refresh required." -f $Platform) -ForegroundColor Yellow
            $script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$true;mode='full'}
            return $true
        }
    }

    $changes=Initialize-IgdbUpdatedAtChangeCacheV6
    $cutoff=[long]$changes.cutoffUnix
    if($cutoff -le $lastReleaseSync -and $cutoff -le $lastGameSync) {
        $script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$false;mode='none';cutoffUnix=$cutoff}
        return $false
    }

    $cached=@((Read-Json $mapPath @()) | ForEach-Object { $_ })
    $cachedIds=@{}
    foreach($g in $cached){try{$gid=[long]$g.id;if($gid -gt 0){$cachedIds[[string]$gid]=$true}}catch{}}

    $releaseChanges=New-Object 'System.Collections.Generic.List[object]'
    foreach($rd in @($changes.releaseRows)) {
        $u=0L;$p=0L
        try{$u=[long]$rd.updated_at}catch{}
        try{$p=[long]$rd.platform}catch{}
        if($u -gt $lastReleaseSync -and $u -le $cutoff -and $p -eq $platformId){[void]$releaseChanges.Add($rd)}
    }

    $gameChanges=New-Object 'System.Collections.Generic.List[object]'
    foreach($g in @($changes.gameRows)) {
        $u=0L;$gid=0L
        try{$u=[long]$g.updated_at}catch{}
        try{$gid=[long]$g.id}catch{}
        if($u -le $lastGameSync -or $u -gt $cutoff -or $gid -le 0){continue}
        # Existing cached games are included even if IGDB removed this platform from
        # their current platforms list; that lets the incremental pass remove them.
        if($cachedIds.ContainsKey([string]$gid) -or (Test-IgdbGameHasPlatformV6 $g $platformId)){
            [void]$gameChanges.Add($g)
        }
    }

    Set-Prop $mapState 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
    if($releaseChanges.Count -eq 0 -and $gameChanges.Count -eq 0) {
        Set-Prop $mapState 'lastReleaseSyncUnix' $cutoff
        Set-Prop $mapState 'lastGameSyncUnix' $cutoff
        Write-JsonAtomic $mapState $statePath
        Write-Host ("[{0}] IGDB updated_at check: no platform changes." -f $Platform) -ForegroundColor DarkGray
        $script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{needsRefresh=$false;mode='none';cutoffUnix=$cutoff}
        return $false
    }

    Write-Host ("[{0}] IGDB changes detected: {1:N0} release rows, {2:N0} game records." -f $Platform,$releaseChanges.Count,$gameChanges.Count) -ForegroundColor Yellow
    $script:IgdbIncrementalProbeResults[$probeKey]=[pscustomobject]@{
        needsRefresh=$true
        mode='incremental'
        cutoffUnix=$cutoff
        releaseRows=$releaseChanges.ToArray()
        gameRows=$gameChanges.ToArray()
    }
    return $true
}

function Get-IgdbPlatformTitleMap([string]$Platform) {
    # Build the static-console IGDB map from RELEASE_DATES rather than from
    # games.platforms. This mirrors IGDB's platform pages more closely: each
    # platform release points at an IGDB game, and we deduplicate by game ID.
    #
    # A separate v2 cache is used so an older ~2k games.platforms map is never
    # mistaken for the complete release-based map.
    $platformId=Get-IgdbPlatformId $Platform
    if(!$platformId){ return @() }

    $safeName=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    $mapPath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}.json" -f $safeName)
    $statePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeName)

    $cached=@((Read-Json $mapPath @()) | ForEach-Object { $_ })
    $allById=@{}
    foreach($row in $cached) {
        if($null -eq $row){ continue }
        try {
            $gid=[long]$row.id
            if($gid -gt 0){ $allById[[string]$gid]=$row }
        } catch {}
    }

    $mapState=Read-Json $statePath ([pscustomobject]@{lastReleaseId=0;releaseRecords=0;complete=$false;syncSchema='';lastReleaseSyncUnix=0;lastGameSyncUnix=0;syncBaselineUnix=0;contentRevision=0})
    if($null -eq $mapState){ $mapState=[pscustomobject]@{lastReleaseId=0;releaseRecords=0;complete=$false;syncSchema='';lastReleaseSyncUnix=0;lastGameSyncUnix=0;syncBaselineUnix=0;contentRevision=0} }
    foreach($prop in @('lastReleaseId','releaseRecords','complete','syncSchema','lastReleaseSyncUnix','lastGameSyncUnix','syncBaselineUnix','contentRevision')) {
        if($null -eq $mapState.PSObject.Properties[$prop]) {
            switch($prop) {
                'lastReleaseId' { Set-Prop $mapState $prop 0 }
                'releaseRecords' { Set-Prop $mapState $prop 0 }
                'complete' { Set-Prop $mapState $prop $false }
                'syncSchema' { Set-Prop $mapState $prop '' }
                'lastReleaseSyncUnix' { Set-Prop $mapState $prop 0 }
                'lastGameSyncUnix' { Set-Prop $mapState $prop 0 }
                'syncBaselineUnix' { Set-Prop $mapState $prop 0 }
                'contentRevision' { Set-Prop $mapState $prop 0 }
            }
        }
    }

    if([bool]$mapState.complete -and $allById.Count -gt 0) {
        $needsRefresh=Test-IgdbPlatformMapIncrementalV6 $Platform
        if(!$needsRefresh) {
            Write-Host ("[{0}] IGDB release-based platform map complete: {1:N0} unique games" -f $Platform,$allById.Count) -ForegroundColor DarkGray
            return @($allById.Values | Sort-Object {[long]$_.id})
        }

        $probe=$null
        $probeKey=State-Key $Platform
        if($script:IgdbIncrementalProbeResults.ContainsKey($probeKey)){$probe=$script:IgdbIncrementalProbeResults[$probeKey]}
        $mode='';try{$mode=[string]$probe.mode}catch{}
        if($mode -eq 'incremental') {
            $addedOrUpdated=0;$removed=0
            foreach($rd in @($probe.releaseRows)) {
                $g=$null;try{$g=$rd.game}catch{}
                if($null -eq $g){continue}
                try {
                    $gid=[long]$g.id
                    if($gid -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$g.name)){
                        $allById[[string]$gid]=$g;$addedOrUpdated++
                    }
                } catch {}
            }
            foreach($g in @($probe.gameRows)) {
                if($null -eq $g){continue}
                $gid=0L;try{$gid=[long]$g.id}catch{}
                if($gid -le 0){continue}
                if(Test-IgdbGameHasPlatformV6 $g $platformId) {
                    if(-not [string]::IsNullOrWhiteSpace([string]$g.name)){$allById[[string]$gid]=$g;$addedOrUpdated++}
                } elseif($allById.ContainsKey([string]$gid)) {
                    $allById.Remove([string]$gid);$removed++
                }
            }
            $cutoff=[long]$probe.cutoffUnix
            Set-Prop $mapState 'syncSchema' 'updated-at-v1'
            Set-Prop $mapState 'lastReleaseSyncUnix' $cutoff
            Set-Prop $mapState 'lastGameSyncUnix' $cutoff
            Set-Prop $mapState 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Set-Prop $mapState 'complete' $true
            $revision=0L;try{$revision=[long]$mapState.contentRevision}catch{}
            Set-Prop $mapState 'contentRevision' ($revision+1)
            $final=@($allById.Values | Sort-Object {[long]$_.id})
            Write-JsonAtomic $final $mapPath
            Write-JsonAtomic $mapState $statePath
            Write-Host ("[{0}] IGDB incremental map applied: {1:N0} games ({2:N0} changed/additions, {3:N0} removals)." -f $Platform,$final.Count,$addedOrUpdated,$removed) -ForegroundColor Green
            return $final
        }

        # 'full' is now reserved for genuinely missing/unusable maps. Completed
        # V3.4 maps are normally adopted in place by Adopt-LegacyIgdbUpdatedAtStateV7.
        if($mode -eq 'full') {
            $allById=@{}
            Set-Prop $mapState 'lastReleaseId' 0
            Set-Prop $mapState 'releaseRecords' 0
            Set-Prop $mapState 'complete' $false
            Set-Prop $mapState 'syncSchema' 'updated-at-v1'
            Set-Prop $mapState 'lastReleaseSyncUnix' 0
            Set-Prop $mapState 'lastGameSyncUnix' 0
            Set-Prop $mapState 'syncBaselineUnix' ([DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds())
            try{Remove-Item -LiteralPath $mapPath -Force -ErrorAction SilentlyContinue}catch{}
            Write-JsonAtomic $mapState $statePath
        } else {
            Set-Prop $mapState 'complete' $false
        }
    }

    $lastReleaseId=0L
    $processed=0L
    try { $lastReleaseId=[long]$mapState.lastReleaseId } catch {}
    try { $processed=[long]$mapState.releaseRecords } catch {}

    $syncBaseline=0L
    try{$syncBaseline=[long]$mapState.syncBaselineUnix}catch{}
    if($syncBaseline -le 0) {
        $syncBaseline=[DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds()
        Set-Prop $mapState 'syncBaselineUnix' $syncBaseline
        Set-Prop $mapState 'syncSchema' 'updated-at-v1'
        Write-JsonAtomic $mapState $statePath
    }

    if($allById.Count -gt 0 -or $lastReleaseId -gt 0) {
        Write-Host ("[{0}] resuming IGDB release-based map: {1:N0} unique games, {2:N0} release rows processed..." -f $Platform,$allById.Count,$processed) -ForegroundColor Yellow
    } else {
        Write-Host ("[{0}] building IGDB release-based platform map..." -f $Platform) -ForegroundColor DarkCyan
    }

    while($true) {
        # Keyset pagination over release_dates avoids large offsets. A platform
        # can have multiple regional/date records for one game, so we collect
        # every referenced game and deduplicate by game.id locally.
        $body="fields id,updated_at,game.id,game.name,game.slug,game.first_release_date,game.alternative_names.name,game.genres.id,game.rating,game.rating_count,game.platforms,game.updated_at; where platform = $platformId & id > $lastReleaseId; sort id asc; limit 500;"
        $rows=@(Invoke-IgdbEndpoint 'release_dates' $body)
        if(!$rows.Count) {
            Set-Prop $mapState 'complete' $true
            break
        }

        $maxReleaseId=$lastReleaseId
        foreach($rd in $rows) {
            if($null -eq $rd){ continue }
            try {
                $releaseId=[long]$rd.id
                if($releaseId -gt $maxReleaseId){ $maxReleaseId=$releaseId }
            } catch {}

            $g=$null
            try { $g=$rd.game } catch {}
            if($null -eq $g){ continue }
            try {
                $gid=[long]$g.id
                if($gid -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$g.name)) {
                    $allById[[string]$gid]=$g
                }
            } catch {}
        }

        if($maxReleaseId -le $lastReleaseId) {
            Set-Prop $mapState 'complete' $true
            break
        }

        $lastReleaseId=$maxReleaseId
        $processed += $rows.Count
        Set-Prop $mapState 'lastReleaseId' $lastReleaseId
        Set-Prop $mapState 'releaseRecords' $processed

        $arr=@($allById.Values | Sort-Object {[long]$_.id})
        Write-JsonAtomic $arr $mapPath
        Write-JsonAtomic $mapState $statePath
        Write-Host ("  [{0}] IGDB releases: {1:N0} rows -> {2:N0} unique games" -f $Platform,$processed,$arr.Count) -ForegroundColor DarkGray

        if($rows.Count -lt 500) {
            Set-Prop $mapState 'complete' $true
            break
        }
    }

    $final=@($allById.Values | Sort-Object {[long]$_.id})
    if($final.Count -gt 0){ Write-JsonAtomic $final $mapPath }
    Write-JsonAtomic $mapState $statePath

    if([bool]$mapState.complete) {
        $baseline=0L;try{$baseline=[long]$mapState.syncBaselineUnix}catch{}
        if($baseline -le 0){$baseline=[DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds()}
        Set-Prop $mapState 'syncSchema' 'updated-at-v1'
        Set-Prop $mapState 'lastReleaseSyncUnix' $baseline
        Set-Prop $mapState 'lastGameSyncUnix' $baseline
        Set-Prop $mapState 'syncBaselineUnix' 0
        Set-Prop $mapState 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
        $revision=0L;try{$revision=[long]$mapState.contentRevision}catch{}
        Set-Prop $mapState 'contentRevision' ($revision+1)
        Write-JsonAtomic $mapState $statePath
        $script:IgdbIncrementalProbeResults[(State-Key $Platform)]=[pscustomobject]@{needsRefresh=$false;mode='none';cutoffUnix=$baseline}
        Write-Host ("[{0}] IGDB release-based platform map complete: {1:N0} unique games from {2:N0} release rows" -f $Platform,$final.Count,$processed) -ForegroundColor Green
    } else {
        Write-Warning ("[{0}] IGDB release-based platform map paused at {1:N0} unique games; it will resume next run." -f $Platform,$final.Count)
    }

    return $final
}

function Ensure-RedumpIgdbIds([string]$Platform) {
    $catalog=@(Read-Catalog)
    $games=@($catalog | Where-Object { [string]$_.platform -eq $Platform })
    if(!$games.Count){ return }

    $missing=@($games | Where-Object {
        $has=$false
        try { if($_.igdbId){ $has=$true } } catch {}
        !$has
    })

    if(!$missing.Count){
        Write-Host ("[{0}] IGDB IDs already cached for all mapped games." -f $Platform) -ForegroundColor DarkGray
        return
    }

    $rows=@(Get-IgdbPlatformTitleMap $Platform)
    if(!$rows.Count){
        Write-Warning ("[{0}] IGDB platform map was empty; metadata will fall back to title lookup." -f $Platform)
        return
    }

    # Build two LOCAL indexes from the one downloaded IGDB platform map:
    #   1) exact normalized title
    #   2) sorted-token signature
    # The second index handles Redump naming conventions such as
    # "Simpsons, The - Hit & Run" vs IGDB "The Simpsons: Hit & Run".
    # No additional IGDB requests are needed for these matches.
    $lookup=@{}
    $tokenLookup=@{}
    foreach($row in $rows) {
        $names=New-Object 'System.Collections.Generic.List[string]'
        if($row.name){ [void]$names.Add([string]$row.name) }
        try {
            foreach($alt in @($row.alternative_names)){
                if($alt.name){ [void]$names.Add([string]$alt.name) }
            }
        } catch {}

        foreach($name in $names) {
            $nk=Normalize-Name $name
            if(-not [string]::IsNullOrWhiteSpace($nk)) {
                if(!$lookup.ContainsKey($nk)){
                    $lookup[$nk]=New-Object 'System.Collections.Generic.List[object]'
                }
                [void]$lookup[$nk].Add($row)
            }

            $tk=Get-TitleTokenSignature $name
            if(-not [string]::IsNullOrWhiteSpace($tk)) {
                if(!$tokenLookup.ContainsKey($tk)){
                    $tokenLookup[$tk]=New-Object 'System.Collections.Generic.List[object]'
                }
                [void]$tokenLookup[$tk].Add($row)
            }
        }
    }

    $matched=0
    $matchedExact=0
    $matchedToken=0
    foreach($game in $missing) {
        $nk=Normalize-Name ([string]$game.title)
        $tk=Get-TitleTokenSignature ([string]$game.title)
        $candidates=@()
        $matchKind=$null

        if(-not [string]::IsNullOrWhiteSpace($nk) -and $lookup.ContainsKey($nk)) {
            $candidates=@($lookup[$nk] | ForEach-Object { $_ })
            $matchKind='exact'
        } elseif(-not [string]::IsNullOrWhiteSpace($tk) -and $tokenLookup.ContainsKey($tk)) {
            $candidates=@($tokenLookup[$tk] | ForEach-Object { $_ })
            $matchKind='token'
        }
        if(!$candidates.Count){ continue }

        # If several IGDB records share the same title/signature, use the
        # release year when available. Otherwise keep the first platform-local
        # candidate; all candidates already matched the full normalized token set.
        $chosen=$candidates[0]
        $wantedYear=$null
        try { if($game.releaseYear){ $wantedYear=[int]$game.releaseYear } } catch {}
        if($wantedYear -and $candidates.Count -gt 1) {
            $bestDiff=[int]::MaxValue
            foreach($candidate in $candidates) {
                $diff=[int]::MaxValue
                try {
                    if($candidate.first_release_date) {
                        $cy=[DateTimeOffset]::FromUnixTimeSeconds([long]$candidate.first_release_date).Year
                        $diff=[Math]::Abs($cy-$wantedYear)
                    }
                } catch {}
                if($diff -lt $bestDiff){ $bestDiff=$diff; $chosen=$candidate }
            }
        }

        if($null -eq $chosen){ continue }
        try {
            Set-Prop $game 'igdbId' ([long]$chosen.id)
            Set-Prop $game 'igdbMatch' $(if($matchKind -eq 'token'){'platform-prebuild-token'}else{'platform-prebuild-exact'})
            $matched++
            if($matchKind -eq 'token'){$matchedToken++}else{$matchedExact++}
        } catch {}
    }

    if($matched -gt 0){ Save-Catalog $catalog }

    # Old failed title searches may have written permanent not-found/error
    # metadata. Once a game has an exact IGDB ID, discard those stale entries
    # so /api/enrich immediately uses the fast ID batch.
    $meta=Object-ToHashtable (Read-Json $MetadataPath ([pscustomobject]@{}))
    $metaChanged=$false
    foreach($game in $games) {
        $hasId=$false
        try { if($game.igdbId){ $hasId=$true } } catch {}
        if(!$hasId){ continue }

        $key=[string]$game.id
        if(!$meta.ContainsKey($key)){ continue }
        $status=[string]$meta[$key].status
        if($status -eq 'not-found' -or $status -eq 'error') {
            [void]$meta.Remove($key)
            $metaChanged=$true
        }
    }
    if($metaChanged){ Write-JsonAtomic $meta $MetadataPath }

    $stillMissing=@($games | Where-Object {
        $has=$false
        try { if($_.igdbId){ $has=$true } } catch {}
        !$has
    }).Count

    Write-Host ("[{0}] IGDB IDs mapped this pass: {1:N0} (exact {2:N0}, smart-title {3:N0}); still unmatched: {4:N0}" -f $Platform,$matched,$matchedExact,$matchedToken,$stillMissing) -ForegroundColor Green
}

function Select-IgdbBestMatch($Rows,$Game) {
    $rowsList=@($Rows | Where-Object { $null -ne $_ })
    if(!$rowsList.Count){ return $null }

    $wanted=Normalize-Name ([string]$Game.title)
    $wantedYear=$null
    try { if($Game.releaseYear){ $wantedYear=[int]$Game.releaseYear } } catch {}
    $best=$null
    $bestScore=-1

    foreach($r in $rowsList) {
        $name=Normalize-Name ([string]$r.name)
        $score=0
        if($name -eq $wanted){$score=1000}
        elseif($name.StartsWith($wanted+' ') -or $wanted.StartsWith($name+' ')){$score=850}
        elseif($name.Contains($wanted) -or $wanted.Contains($name)){$score=700}
        else {
            $a=@($wanted.Split(' ')|Where-Object{$_})
            $b=@($name.Split(' ')|Where-Object{$_})
            $inter=@($a|Where-Object{$b -contains $_}).Count
            $score=[int](500*$inter/[Math]::Max(1,[Math]::Max($a.Count,$b.Count)))
        }

        # Prefer the release closest to the Redump year when the name scores tie.
        if($wantedYear) {
            try {
                if($r.first_release_date) {
                    $ry=[DateTimeOffset]::FromUnixTimeSeconds([long]$r.first_release_date).Year
                    $diff=[Math]::Abs($ry-$wantedYear)
                    if($diff -eq 0){$score+=80}elseif($diff -eq 1){$score+=40}elseif($diff -le 3){$score+=10}
                }
            } catch {}
        }

        if($score -gt $bestScore){$bestScore=$score;$best=$r}
    }

    if($bestScore -ge 300){ return $best }
    return $null
}

function Get-IgdbMetadataSearchBatch($Games) {
    # Redump games do not have IGDB IDs. IGDB Multi-Query lets us perform up
    # to 10 independent title searches in ONE HTTP request instead of one
    # network round trip per game.
    $list=@($Games | Where-Object { $null -ne $_ })
    $result=@{}
    if(!$list.Count){ return $result }

    $fields='fields id,name,slug,first_release_date,rating,rating_count,aggregated_rating,summary,genres.id,genres.name,game_modes.name,cover.image_id,screenshots.image_id,videos.name,videos.video_id;'
    Write-Host "[IGDB] first-time title matching: $($list.Count) games (IDs will be saved)" -ForegroundColor DarkCyan

    for($base=0;$base -lt $list.Count;$base+=10) {
        $group=@($list | Select-Object -Skip $base -First 10)
        $parts=New-Object 'System.Collections.Generic.List[string]'
        $nameToGame=@{}

        for($i=0;$i -lt $group.Count;$i++) {
            $game=$group[$i]
            $resultName="g$i"
            $nameToGame[$resultName]=$game
            $safe=Escape-Igdb ([string]$game.title)
            $platformId=Get-IgdbPlatformId ([string]$game.platform)
            $where=$(if($platformId){"where platforms = $platformId & version_parent = null & themes != (42);"}else{'where version_parent = null & themes != (42);'})
            [void]$parts.Add("query games `"$resultName`" { $fields search `"$safe`"; $where limit 15; };")
        }

        $multiBody=($parts -join "`n")
        $responses=@(Invoke-IgdbEndpoint 'multiquery' $multiBody)
        $seen=@{}

        foreach($response in $responses) {
            $resultName=[string]$response.name
            if(!$nameToGame.ContainsKey($resultName)){ continue }
            $game=$nameToGame[$resultName]
            $key=[string]$game.id
            $chosen=Select-IgdbBestMatch -Rows @($response.result) -Game $game
            if($null -ne $chosen) {
                try { Set-Prop $game 'igdbId' ([long]$chosen.id) } catch {}
            }
            $result[$key]=Convert-IgdbRowToMetadata $chosen ([string]$game.title)
            $seen[$resultName]=$true
        }

        # Ensure every requested game receives a result so the browser does
        # not permanently mark unreturned IDs as already requested.
        foreach($resultName in $nameToGame.Keys) {
            if(!$seen.ContainsKey($resultName)) {
                $game=$nameToGame[$resultName]
                $result[[string]$game.id]=Convert-IgdbRowToMetadata $null ([string]$game.title)
            }
        }
    }

    return $result
}

function Get-IgdbMetadata($Game) {
    $batch=Get-IgdbMetadataSearchBatch @($Game)
    $key=[string]$Game.id
    if($batch.ContainsKey($key)){ return $batch[$key] }
    return Convert-IgdbRowToMetadata $null ([string]$Game.title)
}
function Get-Stats {
    # Stats are informational only. Do not parse the obsolete persistent
    # metadata cache or rewrite source-state just to draw the header.
    $catalog=@(Read-Catalog)
    $chunkIndex=Get-ChunkIndexes
    $state=Read-State
    $counts=@{};foreach($g in $catalog){$p=[string]$g.platform;if(!$counts.ContainsKey($p)){$counts[$p]=0};$counts[$p]=[int]$counts[$p]+1}
    $platformInfo=New-Object 'System.Collections.Generic.List[object]'
    foreach($p in $Platforms) {
        $ps=Get-PlatformState $state $p
        $count=$(if($counts.ContainsKey($p)){[int]$counts[$p]}else{0})
        [void]$platformInfo.Add([pscustomobject]@{platform=$p;cached=$count;complete=[bool]$ps.complete})
    }
    return [pscustomobject]@{catalog=$catalog.Count;chunks=$chunkIndex.count;metadata=0;platforms=$platformInfo.ToArray()}
}



function Get-IgdbGenres {
    if($null -ne $script:IgdbGenres){ return @($script:IgdbGenres) }
    $path=Join-Path $CacheRoot 'igdb-genres.json'
    $rows=@((Read-Json $path @()) | ForEach-Object { $_ })
    if(!$rows.Count){
        $rows=@(Invoke-IgdbEndpoint 'genres' 'fields id,name; sort name asc; limit 500;')
        if($rows.Count){Write-JsonAtomic $rows $path}
    }
    $script:IgdbGenres=$rows
    return @($rows)
}
function Test-PreservationGameName([string]$RawName) {
    if(!(Test-RedumpDatGameName $RawName)){return $false}
    if($RawName -match '(?i)^\s*\[BIOS\]'){return $false}
    if($RawName -match '(?i)^\s*\(Event Preview\)'){return $false}
    if($RawName -match '(?i)\((?:Aftermarket|Homebrew|Unlicensed|Pirate)\)\s*$'){return $true}
    return $true
}
function Add-ClrmameDatTextToRecords([string]$Text,$RecordsByKey,[string]$SourceLabel) {
    if([string]::IsNullOrWhiteSpace($Text)){ return 0 }
    $added=0
    # All of the No-Intro/Libretro DATs used here expose one top-level
    # game/machine name. We only need the canonical display title for the
    # IGDB intersection; hashes are not required for this browser catalog.
    $matches=[regex]::Matches($Text,'(?ims)^\s*(?:game|machine)\s*\(\s*name\s+"([^"\r\n]+)"')
    foreach($m in $matches) {
        $raw=[string]$m.Groups[1].Value
        if(!(Test-PreservationGameName $raw)){continue}
        $title=Convert-RedumpDatTitle $raw
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $key=Normalize-Name $title
        if([string]::IsNullOrWhiteSpace($key)){continue}
        if(!$RecordsByKey.ContainsKey($key)){
            $RecordsByKey[$key]=[pscustomobject]@{key=$key;title=$title;variants=(New-Object 'System.Collections.Generic.List[object]')}
            $added++
        }
        [void]$RecordsByKey[$key].variants.Add([pscustomobject]@{title=$raw;serial='';source=$SourceLabel})
    }
    return $added
}
function Add-ConfiguredExtraDatSources($Cfg,[string]$Platform,$RecordsByKey,$Urls) {
    $extras=@()
    try { if($Cfg.PSObject.Properties['extraDatUrls']){$extras=@($Cfg.extraDatUrls)} } catch {}
    if(!$extras.Count){ return }
    $safe=(State-Key $Platform)
    $n=0
    foreach($extra in $extras) {
        $n++
        $url='';$label='Extra DAT'
        if($extra -is [string]){$url=[string]$extra}
        else {
            try{$url=[string]$extra.url}catch{}
            try{if($extra.label){$label=[string]$extra.label}}catch{}
        }
        if([string]::IsNullOrWhiteSpace($url)){continue}
        $downloadPath=Join-Path $CacheRoot ("preservation-{0}-extra-{1}.dat" -f $safe,$n)
        Write-Host ("  [{0}] downloading additional catalog: {1}" -f $Platform,$label) -ForegroundColor DarkGray
        Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{'User-Agent'=$UserAgent;'Accept'='text/plain,*/*'} -OutFile $downloadPath -TimeoutSec 180
        $text=Get-Content -LiteralPath $downloadPath -Raw
        try{Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue}catch{}
        if([string]::IsNullOrWhiteSpace($text)){continue}
        $before=$RecordsByKey.Count
        [void](Add-ClrmameDatTextToRecords $text $RecordsByKey $label)
        $after=$RecordsByKey.Count
        Write-Host ("  [{0}] {1}: +{2:N0} canonical titles ({3:N0} combined)" -f $Platform,$label,($after-$before),$after) -ForegroundColor DarkGray
        [void]$Urls.Add($url)
    }
}

function New-PreservationIndexFromRecords([string]$Url,$RecordsByKey) {
    $records=@($RecordsByKey.Values | Sort-Object title)
    $exact=@{};$token=@{}
    foreach($rec in $records) {
        $nk=Normalize-Name ([string]$rec.title)
        if(-not [string]::IsNullOrWhiteSpace($nk)) {
            if(!$exact.ContainsKey($nk)){$exact[$nk]=New-Object 'System.Collections.Generic.List[object]'}
            [void]$exact[$nk].Add($rec)
        }
        $tk=Get-TitleTokenSignature ([string]$rec.title)
        if(-not [string]::IsNullOrWhiteSpace($tk)) {
            if(!$token.ContainsKey($tk)){$token[$tk]=New-Object 'System.Collections.Generic.List[object]'}
            [void]$token[$tk].Add($rec)
        }
    }
    return [pscustomobject]@{url=$Url;records=$records;exact=$exact;token=$token}
}
function Get-PreservationDatIndex([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    if($null -eq $cfg){throw "Unknown platform: $Platform"}
    $mode=[string]$cfg.mode
    if($mode -eq 'igdb'){throw "$Platform is IGDB-only and has no preservation DAT configured."}

    $safe=(State-Key $Platform)
    $recordsByKey=@{}
    $sourceUrls=New-Object 'System.Collections.Generic.List[string]'

    if($mode -eq 'redump') {
        $code=[string]$cfg.datCode
        if([string]::IsNullOrWhiteSpace($code)){throw "No Redump DAT code configured for $Platform"}
        $url="https://redump.info/datfile/$code"
        [void]$sourceUrls.Add($url)
        $downloadPath=Join-Path $CacheRoot ("preservation-{0}-redump.bin" -f $safe)
        Write-Host ("  [{0}] downloading Redump DAT: {1}" -f $Platform,$url) -ForegroundColor DarkGray
        Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{'User-Agent'=$UserAgent;'Accept'='application/zip,application/xml,text/xml,*/*'} -OutFile $downloadPath -TimeoutSec 180

        $xmlText=$null
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
        try {
            $zip=[IO.Compression.ZipFile]::OpenRead($downloadPath)
            try {
                $entry=$zip.Entries | Where-Object { $_.Name -match '(?i)\.(dat|xml)$' } | Sort-Object Length -Descending | Select-Object -First 1
                if($null -eq $entry){throw 'No DAT/XML entry found in Redump archive.'}
                $stream=$entry.Open()
                try{$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{$xmlText=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
            } finally {$zip.Dispose()}
        } catch {
            # Some Redump endpoints may return XML directly rather than ZIP.
            $xmlText=Get-Content -LiteralPath $downloadPath -Raw
        }
        try{Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue}catch{}
        if([string]::IsNullOrWhiteSpace($xmlText)){throw 'Redump DAT was empty.'}
        [xml]$doc=$xmlText
        $nodes=@($doc.SelectNodes('//game | //machine'))
        foreach($node in $nodes) {
            $raw=[string]$node.GetAttribute('name')
            if([string]::IsNullOrWhiteSpace($raw)){try{$raw=[string]$node.description}catch{}}
            if(!(Test-PreservationGameName $raw)){continue}
            $title=Convert-RedumpDatTitle $raw
            if([string]::IsNullOrWhiteSpace($title)){continue}
            $key=Normalize-Name $title;if([string]::IsNullOrWhiteSpace($key)){continue}
            $serial=''
            try{$sn=$node.SelectSingleNode('./serial | .//rom/@serial | .//rom/serial');if($sn){$serial=[string]$sn.InnerText;if([string]::IsNullOrWhiteSpace($serial)){$serial=[string]$sn.Value}}}catch{}
            if(!$recordsByKey.ContainsKey($key)){$recordsByKey[$key]=[pscustomobject]@{key=$key;title=$title;variants=(New-Object 'System.Collections.Generic.List[object]')}}
            [void]$recordsByKey[$key].variants.Add([pscustomobject]@{title=$raw;serial=$serial})
        }
        Add-ConfiguredExtraDatSources $cfg $Platform $recordsByKey $sourceUrls
        return New-PreservationIndexFromRecords ($sourceUrls -join ' | ') $recordsByKey
    }

    if($mode -eq 'nointro') {
        $url=[string]$cfg.datUrl
        if([string]::IsNullOrWhiteSpace($url)){throw "No No-Intro DAT URL configured for $Platform"}
        [void]$sourceUrls.Add($url)
        $downloadPath=Join-Path $CacheRoot ("preservation-{0}-nointro.dat" -f $safe)
        Write-Host ("  [{0}] downloading No-Intro DAT mirror..." -f $Platform) -ForegroundColor DarkGray
        Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{'User-Agent'=$UserAgent;'Accept'='text/plain,*/*'} -OutFile $downloadPath -TimeoutSec 180
        $text=Get-Content -LiteralPath $downloadPath -Raw
        try{Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue}catch{}
        if([string]::IsNullOrWhiteSpace($text)){throw 'No-Intro DAT was empty.'}
        [void](Add-ClrmameDatTextToRecords $text $recordsByKey ("No-Intro {0}" -f $Platform))
        if(!$recordsByKey.Count){throw 'No-Intro DAT parser found no game records.'}
        Add-ConfiguredExtraDatSources $cfg $Platform $recordsByKey $sourceUrls
        return New-PreservationIndexFromRecords ($sourceUrls -join ' | ') $recordsByKey
    }
    throw "Unsupported preservation mode '$mode' for $Platform"
}

function Build-IgdbPreservationIntersectionCatalog([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    $dat=Get-PreservationDatIndex $Platform
    $igdbRows=@(Get-IgdbPlatformTitleMap $Platform)
    if(!$igdbRows.Count){throw 'IGDB platform map is empty.'}
    if(!$dat.records.Count){throw 'Preservation DAT produced no usable titles.'}

    $entries=New-Object 'System.Collections.Generic.List[object]'
    $matchedDat=@{};$matchedExact=0;$matchedToken=0
    foreach($row in $igdbRows) {
        if($null -eq $row){continue}
        $gid=0L;try{$gid=[long]$row.id}catch{}
        $title=[string]$row.name
        if($gid -le 0 -or [string]::IsNullOrWhiteSpace($title)){continue}
        $names=New-Object 'System.Collections.Generic.List[string]';[void]$names.Add($title)
        try{foreach($alt in $row.alternative_names){if($alt.name){[void]$names.Add([string]$alt.name)}}}catch{}
        $candidateByKey=@{}
        foreach($name in $names){$nk=Normalize-Name $name;if(!$nk){continue};if($dat.exact.ContainsKey($nk)){foreach($rec in $dat.exact[$nk]){$candidateByKey[[string]$rec.key]=$rec}}}
        $matchKind='exact'
        if(!$candidateByKey.Count){
            foreach($name in $names){$tk=Get-TitleTokenSignature $name;if(!$tk){continue};if($dat.token.ContainsKey($tk)){foreach($rec in $dat.token[$tk]){$candidateByKey[[string]$rec.key]=$rec}}}
            $matchKind='token'
        }
        if(!$candidateByKey.Count){continue}

        $datTitles=New-Object 'System.Collections.Generic.List[string]';$serials=New-Object 'System.Collections.Generic.List[string]'
        $seenTitles=@{};$seenSerials=@{};$variantCount=0
        foreach($rec in $candidateByKey.Values){
            $matchedDat[[string]$rec.key]=$true
            foreach($variant in $rec.variants){
                $variantCount++;$rt=[string]$variant.title;$rs=[string]$variant.serial
                if($rt -and !$seenTitles.ContainsKey($rt)){$seenTitles[$rt]=$true;[void]$datTitles.Add($rt)}
                if($rs -and !$seenSerials.ContainsKey($rs)){$seenSerials[$rs]=$true;[void]$serials.Add($rs)}
            }
        }
        $year=$null;try{if($row.first_release_date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.first_release_date).Year}}catch{}
        $igdbUrl='https://www.igdb.com/';try{if($row.slug){$igdbUrl="https://www.igdb.com/games/$($row.slug)"}}catch{}
        $provider=''
        try{if($cfg.PSObject.Properties['providerLabel']){$provider=[string]$cfg.providerLabel}}catch{}
        if([string]::IsNullOrWhiteSpace($provider)){$provider=$(if([string]$cfg.mode -eq 'redump'){'Redump'}else{'No-Intro'})}
        $entry=New-Entry $Platform $title ("IGDB + $provider") ([string]$gid) $igdbUrl $year
        $entry.id="$Platform::IGDB::$gid";Set-Prop $entry 'igdbId' $gid
        Set-Prop $entry 'preservationDatUrl' ([string]$dat.url);Set-Prop $entry 'preservationProvider' $provider
        Set-Prop $entry 'preservationMatch' $(if($matchKind -eq 'token'){'token-signature'}else{'exact-title-or-alias'})
        Set-Prop $entry 'preservationTitles' $datTitles.ToArray();Set-Prop $entry 'preservationSerials' $serials.ToArray();Set-Prop $entry 'preservationVariantCount' $variantCount
        try{Set-Prop $entry 'rating' ([double]$row.rating)}catch{};try{Set-Prop $entry 'ratingCount' ([long]$row.rating_count)}catch{}
        $gi=New-Object 'System.Collections.Generic.List[long]'
        try{foreach($gr in $row.genres){try{if($gr.id){[void]$gi.Add([long]$gr.id)}}catch{}}}catch{}
        Set-Prop $entry 'catalogGenreIds' $gi.ToArray()
        Set-Prop $entry 'catalogRule' ("Intersection only: IGDB platform release + $provider DAT match")
        [void]$entries.Add($entry);if($matchKind -eq 'token'){$matchedToken++}else{$matchedExact++}
    }
    if(!$entries.Count){throw 'IGDB/preservation DAT intersection was empty; existing catalog was left untouched.'}
    Replace-CatalogPlatform $Platform $entries.ToArray()
    $state=Read-State;$ps=Get-PlatformState $state $Platform;$ps.complete=$true
    $catalogMode='igdb-preservation-intersection-v2'
    try{if($cfg.PSObject.Properties['catalogMode'] -and $cfg.catalogMode){$catalogMode=[string]$cfg.catalogMode}}catch{}
    Set-Prop $ps 'source' ("IGDB + $provider intersection");Set-Prop $ps 'catalogMode' $catalogMode
    Set-Prop $ps 'igdbGames' $igdbRows.Count;Set-Prop $ps 'preservationTitles' $dat.records.Count;Set-Prop $ps 'intersectionGames' $entries.Count;Set-Prop $ps 'updatedAt' ((Get-Date).ToString('o'));Save-State $state
    Write-Host ("[{0}] intersection complete: {1:N0} games (exact {2:N0}, smart-title {3:N0})" -f $Platform,$entries.Count,$matchedExact,$matchedToken) -ForegroundColor Green
    return $entries.Count
}

function Ensure-StaticCatalogBasicMetadata([string]$Platform) {
    $catalog=@(Read-Catalog);$games=@($catalog | Where-Object {$_.platform -eq $Platform -and $_.igdbId})
    if(!$games.Count){return}
    $platformId=Get-IgdbPlatformId $Platform
    $need=@($games | Where-Object {
        $releaseEpoch=0L;try{if($_.PSObject.Properties['releaseDateEpoch']){$releaseEpoch=[long]$_.releaseDateEpoch}}catch{}
        !$_.PSObject.Properties['catalogGenreIds'] -or !$_.PSObject.Properties['ratingCount'] -or !$_.PSObject.Properties['coverUrl'] -or !$_.PSObject.Properties['summary'] -or $releaseEpoch -le 0
    })
    if(!$need.Count){return}
    Write-Host ("[{0}] filling lightweight genre/rating/full-release-date index for {1:N0} games..." -f $Platform,$need.Count) -ForegroundColor DarkCyan
    for($i=0;$i -lt $need.Count;$i+=500){
        $group=@($need | Select-Object -Skip $i -First 500);$ids=@($group | ForEach-Object {[long]$_.igdbId});if(!$ids.Count){continue}
        $rows=@(Invoke-IgdbEndpoint 'games' ("fields id,slug,first_release_date,release_dates.platform,release_dates.date,rating,rating_count,genres.id,genres.name,cover.image_id,summary; where id = ({0}); limit 500;" -f ($ids -join ',')))
        $by=@{};foreach($g in $group){$by[[string]$g.igdbId]=$g}
        foreach($r in $rows){$k=[string]$r.id;if(!$by.ContainsKey($k)){continue};$g=$by[$k]
            $gids=New-Object 'System.Collections.Generic.List[long]'
            try{foreach($gr in $r.genres){try{if($gr.id){[void]$gids.Add([long]$gr.id)}}catch{}}}catch{}
            Set-Prop $g 'catalogGenreIds' $gids.ToArray()
            $gnames=New-Object 'System.Collections.Generic.List[string]'
            try{foreach($gr in $r.genres){try{if($gr.name){[void]$gnames.Add([string]$gr.name)}}catch{}}}catch{}
            Set-Prop $g 'catalogGenres' $gnames.ToArray()
            try{Set-Prop $g 'rating' ([double]$r.rating)}catch{};try{Set-Prop $g 'ratingCount' ([long]$r.rating_count)}catch{}
            try{if($r.cover.image_id){Set-Prop $g 'coverUrl' ("https://images.igdb.com/igdb/image/upload/t_cover_big/$($r.cover.image_id).jpg")}}catch{}
            try{if($r.summary){Set-Prop $g 'summary' ([string]$r.summary)}else{Set-Prop $g 'summary' ''}}catch{}

            # Use the earliest dated release for THIS platform. A title may have several
            # regional release rows; all of them retain month/day precision. Only when
            # IGDB has no dated platform row do we fall back to game.first_release_date.
            $releaseEpoch=0L
            try {
                foreach($rd in @($r.release_dates)) {
                    $rp=0L;$rdDate=0L
                    try{$rp=[long]$rd.platform}catch{}
                    try{$rdDate=[long]$rd.date}catch{}
                    if($rp -eq $platformId -and $rdDate -gt 0 -and ($releaseEpoch -le 0 -or $rdDate -lt $releaseEpoch)){$releaseEpoch=$rdDate}
                }
            } catch {}
            if($releaseEpoch -le 0){try{if($r.first_release_date){$releaseEpoch=[long]$r.first_release_date}}catch{}}
            Set-Prop $g 'releaseDateEpoch' ([long]$releaseEpoch)
            if($releaseEpoch -gt 0){
                try{Set-Prop $g 'releaseYear' ([DateTimeOffset]::FromUnixTimeSeconds($releaseEpoch).Year)}catch{}
            } elseif(!$g.releaseYear) {
                try{if($r.first_release_date){Set-Prop $g 'releaseYear' ([DateTimeOffset]::FromUnixTimeSeconds([long]$r.first_release_date).Year)}}catch{}
            }
        }
    }
    Save-Catalog $catalog
}

function Get-GenericDailyChunk($Game) {
    # Canonical IGDB genre IDs are the only genre identity used internally.
    # IGDB: Fighting=4, Shooter=5, Platform=8, Puzzle=9, Racing=10,
    # RPG=12, Sport=14, Strategy=15, Tactical=24, Adventure=31.
    $ids=@();try{$ids=@($Game.catalogGenreIds | ForEach-Object {[long]$_})}catch{}
    $text='Complete one clear stage, mission, chapter, or objective set, then stop at the next natural save/checkpoint.';$minutes=35;$score=4
    if($ids -contains 10){ $text='Complete 3 races or one championship/event set, then stop before starting the next event.';$minutes=30;$score=5 }
    elseif($ids -contains 8){ $text='Finish 3 stages or reach the next major checkpoint/world marker.';$minutes=30;$score=5 }
    elseif($ids -contains 9){ $text='Complete 4–6 puzzles or one clearly defined puzzle chapter.';$minutes=25;$score=5 }
    elseif($ids -contains 12){ $text='Complete one quest, dungeon section, or major objective and stop at the next save point.';$minutes=45;$score=4 }
    elseif(($ids -contains 15) -or ($ids -contains 24)){ $text='Complete one mission, map, scenario, or clearly defined objective set.';$minutes=40;$score=5 }
    elseif($ids -contains 14){ $text='Play one match, round, tournament stage, or event set.';$minutes=30;$score=5 }
    elseif($ids -contains 4){ $text='Complete one arcade/tournament set or about 5 matches.';$minutes=25;$score=5 }
    elseif($ids -contains 5){ $text='Complete one mission/level or reach the next major checkpoint.';$minutes=35;$score=4 }
    elseif($ids -contains 31){ $text='Complete one chapter, area, or major story objective and stop at the next save point.';$minutes=40;$score=4 }
    return [pscustomobject]@{dailyChunk=$text;minutes=$minutes;chunkability=$score}
}
function Add-DailyChunkDataToRows($Rows) {
    [void](Get-ChunkIndexes)
    $exact=$script:ChunkExactMemory
    $normalized=$script:ChunkNormalizedMemory
    $result=New-Object 'System.Collections.Generic.List[object]'
    foreach($g in @($Rows)) {
        if($null -eq $g){continue}
        $c=$null
        $gid=[string]$g.id
        if($gid -and $exact.ContainsKey($gid)) {
            $c=$exact[$gid]
        } else {
            $nk=([string]$g.platform)+'|'+(Normalize-Name ([string]$g.title))
            if($normalized.ContainsKey($nk)){$c=$normalized[$nk]}
        }
        if($null -ne $c) {
            Set-Prop $g 'dailyChunk' ([string]$c.dailyChunk)
            try{Set-Prop $g 'chunkMinutes' ([int]$c.minutes)}catch{}
            try{Set-Prop $g 'chunkability' ([int]$c.chunkability)}catch{}
            try{Set-Prop $g 'chunkIntensity' ([int]$c.intensity)}catch{}
            try{Set-Prop $g 'chunkWhy' ([string]$c.why)}catch{}
        } elseif($g.dailyPriority) {
            # Defensive fallback. Priority rows should normally already have a
            # persisted daily-chunks.json entry. If an older catalog was kept
            # while the chunk file changed, still show a useful editable chunk.
            $tpl=Get-GenericDailyChunk $g
            Set-Prop $g 'dailyChunk' ([string]$tpl.dailyChunk)
            Set-Prop $g 'chunkMinutes' ([int]$tpl.minutes)
            Set-Prop $g 'chunkability' ([int]$tpl.chunkability)
        }
        [void]$result.Add($g)
    }
    return $result.ToArray()
}

function Ensure-DailyChunkPriorityForStaticPlatform([string]$Platform,[int]$Target=200) {
    [void](Get-ChunkIndexes)
    $catalog=@(Read-Catalog);$games=@($catalog | Where-Object {$_.platform -eq $Platform})
    if(!$games.Count){return}
    $chunkList=New-Object 'System.Collections.Generic.List[object]';foreach($c in @($script:ChunksMemory)){[void]$chunkList.Add($c)}
    $byNorm=@{};$order=0
    foreach($c in $chunkList){if([string]$c.platform -ne $Platform){continue};$order++;$nk=Normalize-Name ([string]$c.title);if($nk -and !$byNorm.ContainsKey($nk)){$byNorm[$nk]=[pscustomobject]@{chunk=$c;order=$order}}}
    $used=@{};$priority=0
    foreach($g in $games){Set-Prop $g 'dailyPriority' $false;Set-Prop $g 'dailyOrder' 0;$nk=Normalize-Name ([string]$g.title);if($byNorm.ContainsKey($nk) -and $priority -lt $Target){$priority++;$used[$nk]=$true;Set-Prop $g 'dailyPriority' $true;Set-Prop $g 'dailyOrder' ([int]$byNorm[$nk].order)}}
    if($priority -lt [Math]::Min($Target,$games.Count)){
        $candidates=@($games | Where-Object {!$_.dailyPriority} | Sort-Object @{Expression={try{-[long]$_.ratingCount}catch{0}}},@{Expression={try{-[double]$_.rating}catch{0}}},title)
        foreach($g in $candidates){if($priority -ge $Target){break};$nk=Normalize-Name ([string]$g.title);if($used.ContainsKey($nk)){continue};$tpl=Get-GenericDailyChunk $g
            $new=[pscustomobject]@{id=[string]$g.id;platform=$Platform;title=[string]$g.title;dailyChunk=[string]$tpl.dailyChunk;minutes=[int]$tpl.minutes;intensity=2;chunkability=[int]$tpl.chunkability;why='Auto-seeded so this system keeps 200 Daily Chunk games at the front; edit anytime.'}
            [void]$chunkList.Add($new);$priority++;$used[$nk]=$true;Set-Prop $g 'dailyPriority' $true;Set-Prop $g 'dailyOrder' (100000+$priority)
        }
        Write-JsonAtomic $chunkList.ToArray() $ChunksPath;Reset-ChunkMemory;[void](Get-ChunkIndexes)
    }
    Save-Catalog $catalog
    Write-Host ("[{0}] Daily Chunk priority: {1:N0}/{2:N0}" -f $Platform,[Math]::Min($priority,$Target),[Math]::Min($Target,$games.Count)) -ForegroundColor DarkGray
}

function Convert-IgdbCatalogRowToEntry([string]$Platform,$Row) {
    if($null -eq $Row){return $null}
    $gid=0L;try{$gid=[long]$Row.id}catch{};if($gid -le 0){return $null}
    $title=[string]$Row.name;if([string]::IsNullOrWhiteSpace($title)){return $null}
    $year=$null;try{if($Row.first_release_date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$Row.first_release_date).Year}}catch{}
    $url='https://www.igdb.com/';try{if($Row.slug){$url="https://www.igdb.com/games/$($Row.slug)"}}catch{}
    $e=New-Entry $Platform $title 'IGDB' ([string]$gid) $url $year;$e.id="$Platform::IGDB::$gid";Set-Prop $e 'igdbId' $gid
    try{Set-Prop $e 'rating' ([double]$Row.rating)}catch{};try{Set-Prop $e 'ratingCount' ([long]$Row.rating_count)}catch{}
    $ids=New-Object 'System.Collections.Generic.List[long]'
    try{foreach($gr in $Row.genres){try{if($gr.id){[void]$ids.Add([long]$gr.id)}}catch{}}}catch{}
    Set-Prop $e 'catalogGenreIds' $ids.ToArray()
    return $e
}
function Get-IgdbDirectGameRows([string]$Platform,[int]$Offset,[int]$Limit,[string]$Query,[long]$GenreId,[string]$Sort,$ExcludeIds) {
    $platformId=Get-IgdbPlatformId $Platform;if(!$platformId){throw "No IGDB platform ID for $Platform"}
    $Limit=[Math]::Min(500,[Math]::Max(1,$Limit));$Offset=[Math]::Max(0,$Offset)
    $clauses=New-Object 'System.Collections.Generic.List[string]';[void]$clauses.Add("release_dates.platform = $platformId");[void]$clauses.Add('version_parent = null');[void]$clauses.Add('themes != (42)')
    if($GenreId -gt 0){[void]$clauses.Add("genres = $GenreId")}
    $exclude=@($ExcludeIds | Where-Object {$_} | Select-Object -Unique)
    if($exclude.Count){[void]$clauses.Add("id != ($($exclude -join ','))")}
    $where='where '+($clauses -join ' & ')+';'
    $search='';if(-not [string]::IsNullOrWhiteSpace($Query)){$search='search "'+(Escape-Igdb $Query)+'";'}
    $sortClause=''
    if([string]::IsNullOrWhiteSpace($Query)){
        switch($Sort){
            'yearDesc'{$sortClause='sort first_release_date desc;'}
            'yearAsc'{$sortClause='sort first_release_date asc;'}
            'ratingDesc'{$sortClause='sort rating desc;'}
            default{$sortClause='sort name asc;'}
        }
    }
    # Return the page and its card/gallery metadata in the SAME IGDB request.
    # This mirrors the standalone PowerShell browser: no second metadata lookup
    # is needed for normal IGDB-only pages.
    $fields='id,name,slug,first_release_date,rating,rating_count,genres.id,genres.name,cover.image_id'
    $body="fields $fields; $search $where $sortClause limit $Limit; offset $Offset;"
    return @(Invoke-IgdbEndpoint 'games' $body)
}

function Get-IgdbPreparedDailyPriority([string]$Platform,[int]$Target=200) {
    # Normal browsing must NEVER build/scan daily-chunks.json. It only consumes
    # the already-prepared priority-ID file. BUILD CATALOGS can create it.
    if($script:IgdbDailyPriorityMemory.ContainsKey($Platform)){ return @($script:IgdbDailyPriorityMemory[$Platform]) }
    $safe=State-Key $Platform
    $path=Join-Path $CacheRoot ("daily-priority-{0}-v2.json" -f $safe)
    $cached=@((Read-Json $path @()) | ForEach-Object { $_ })
    $ready=@($cached | Where-Object {try{[long]$_.igdbId}catch{0}} | Select-Object -First $Target)
    $n=0
    foreach($e in $ready){
        $n++
        Set-Prop $e 'dailyPriority' $true
        if(!$e.dailyOrder){Set-Prop $e 'dailyOrder' $n}
    }
    $script:IgdbDailyPriorityMemory[$Platform]=$ready
    return $ready
}

function Ensure-IgdbDailyPriority([string]$Platform,[int]$Target=200) {
    if($script:IgdbDailyPriorityMemory.ContainsKey($Platform)){ return @($script:IgdbDailyPriorityMemory[$Platform]) }
    $safe=State-Key $Platform;$path=Join-Path $CacheRoot ("daily-priority-{0}-v2.json" -f $safe)
    $cached=@((Read-Json $path @()) | ForEach-Object { $_ })
    # Fast startup path: a completed priority file already contains the IGDB IDs
    # we need. Do not rescan the full Daily Chunk database or re-resolve titles
    # merely to display the first page.
    $ready=@($cached | Where-Object {try{[long]$_.igdbId}catch{0}} | Select-Object -First $Target)
    if($ready.Count -ge $Target){
        $n=0;foreach($e in $ready){$n++;Set-Prop $e 'dailyPriority' $true;if(!$e.dailyOrder){Set-Prop $e 'dailyOrder' $n}}
        $script:IgdbDailyPriorityMemory[$Platform]=$ready
        return $ready
    }
    $cachedByNorm=@{};foreach($e in $cached){$nk=Normalize-Name ([string]$e.title);if($nk -and !$cachedByNorm.ContainsKey($nk)){$cachedByNorm[$nk]=$e}}
    [void](Get-ChunkIndexes)
    $allChunks=New-Object 'System.Collections.Generic.List[object]';foreach($c in @($script:ChunksMemory)){[void]$allChunks.Add($c)}
    $platformChunks=@($allChunks | Where-Object {$_.platform -eq $Platform})
    $chunkNorm=@{};foreach($c in $platformChunks){$nk=Normalize-Name ([string]$c.title);if($nk -and !$chunkNorm.ContainsKey($nk)){$chunkNorm[$nk]=$c}}
    $platformId=Get-IgdbPlatformId $Platform;if(!$platformId){return @()}

    # Platforms without a curated 200-game chunk set get a lightweight top-200
    # seed in a single IGDB request. Existing curated Switch/Windows chunks are preserved.
    if($platformChunks.Count -lt $Target){
        $top=@(Invoke-IgdbEndpoint 'games' ("fields id,name,slug,first_release_date,rating,rating_count,genres.id; where release_dates.platform = {0} & version_parent = null & themes != (42); sort rating_count desc; limit {1};" -f $platformId,[Math]::Min(500,$Target*2)))
        foreach($r in $top){if($platformChunks.Count -ge $Target){break};$e=Convert-IgdbCatalogRowToEntry $Platform $r;if($null -eq $e){continue};$nk=Normalize-Name $e.title;if($chunkNorm.ContainsKey($nk)){continue};$tpl=Get-GenericDailyChunk $e
            $c=[pscustomobject]@{id=[string]$e.id;platform=$Platform;title=[string]$e.title;dailyChunk=[string]$tpl.dailyChunk;minutes=[int]$tpl.minutes;intensity=2;chunkability=[int]$tpl.chunkability;why='Auto-seeded so this system keeps 200 Daily Chunk games at the front; edit anytime.'}
            [void]$allChunks.Add($c);$platformChunks+=,$c;$chunkNorm[$nk]=$c;$cachedByNorm[$nk]=$e
        }
        Write-JsonAtomic $allChunks.ToArray() $ChunksPath;Reset-ChunkMemory;[void](Get-ChunkIndexes)
    }

    $selected=@($platformChunks | Select-Object -First $Target)
    $result=New-Object 'System.Collections.Generic.List[object]';$resolvedNorm=@{};$unresolved=New-Object 'System.Collections.Generic.List[object]'
    $order=0
    foreach($c in $selected){$order++;$nk=Normalize-Name ([string]$c.title);if($cachedByNorm.ContainsKey($nk)){$e=$cachedByNorm[$nk];Set-Prop $e 'dailyPriority' $true;Set-Prop $e 'dailyOrder' $order;[void]$result.Add($e);$resolvedNorm[$nk]=$true}else{[void]$unresolved.Add([pscustomobject]@{chunk=$c;order=$order})}}

    # Resolve curated chunk titles ten at a time with IGDB Multi-Query, then cache IDs forever.
    for($base=0;$base -lt $unresolved.Count;$base+=10){
        $group=@($unresolved | Select-Object -Skip $base -First 10);$parts=New-Object 'System.Collections.Generic.List[string]';$map=@{}
        for($i=0;$i -lt $group.Count;$i++){$x=$group[$i];$qn="p$i";$map[$qn]=$x;$safeTitle=Escape-Igdb ([string]$x.chunk.title);[void]$parts.Add("query games `"$qn`" { fields id,name,slug,first_release_date,rating,rating_count,genres.id; search `"$safeTitle`"; where release_dates.platform = $platformId & version_parent = null & themes != (42); limit 10; };")}
        $responses=@(Invoke-IgdbEndpoint 'multiquery' ($parts -join "`n"))
        foreach($resp in $responses){$qn=[string]$resp.name;if(!$map.ContainsKey($qn)){continue};$x=$map[$qn];$want=Normalize-Name ([string]$x.chunk.title);$wantTok=Get-TitleTokenSignature ([string]$x.chunk.title);$chosen=$null
            foreach($r in @($resp.result)){if((Normalize-Name ([string]$r.name)) -eq $want){$chosen=$r;break}}
            if($null -eq $chosen){$same=@($resp.result | Where-Object {(Get-TitleTokenSignature ([string]$_.name)) -eq $wantTok});if($same.Count -eq 1){$chosen=$same[0]}}
            if($null -ne $chosen){$e=Convert-IgdbCatalogRowToEntry $Platform $chosen;Set-Prop $e 'dailyPriority' $true;Set-Prop $e 'dailyOrder' ([int]$x.order);[void]$result.Add($e);$nk=Normalize-Name $e.title;$resolvedNorm[$nk]=$true;$cachedByNorm[$nk]=$e}
        }
    }

    # If curated names could not be mapped, fill the priority group with popular
    # platform games and add editable generic chunk rows until 200 actual games exist.
    if($result.Count -lt $Target){
        $top=@(Invoke-IgdbEndpoint 'games' ("fields id,name,slug,first_release_date,rating,rating_count,genres.id; where release_dates.platform = {0} & version_parent = null & themes != (42); sort rating_count desc; limit 500;" -f $platformId))
        foreach($r in $top){if($result.Count -ge $Target){break};$e=Convert-IgdbCatalogRowToEntry $Platform $r;if($null -eq $e){continue};$nk=Normalize-Name $e.title;if($resolvedNorm.ContainsKey($nk)){continue};$tpl=Get-GenericDailyChunk $e
            if(!$chunkNorm.ContainsKey($nk)){$c=[pscustomobject]@{id=[string]$e.id;platform=$Platform;title=[string]$e.title;dailyChunk=[string]$tpl.dailyChunk;minutes=[int]$tpl.minutes;intensity=2;chunkability=[int]$tpl.chunkability;why='Auto-seeded replacement for an unavailable Daily Chunk title; edit anytime.'};[void]$allChunks.Add($c);$chunkNorm[$nk]=$c}
            Set-Prop $e 'dailyPriority' $true;Set-Prop $e 'dailyOrder' (100000+$result.Count+1);[void]$result.Add($e);$resolvedNorm[$nk]=$true
        }
        Write-JsonAtomic $allChunks.ToArray() $ChunksPath;Reset-ChunkMemory;[void](Get-ChunkIndexes)
    }
    $final=@($result | Sort-Object dailyOrder | Select-Object -First $Target);Write-JsonAtomic $final $path
    if($final.Count){[void](Merge-Catalog $Platform $final)}
    $script:IgdbDailyPriorityMemory[$Platform]=$final
    return $final
}

function Get-PcgwControllerIndex([switch]$Force) {
    if(!$Force -and $null -ne $script:PcgwControllerIndex){return $script:PcgwControllerIndex}
    $path=Join-Path $CacheRoot 'pcgw-controller-index-v2.json'
    $saved=Read-Json $path $null;$fresh=$false
    if($null -ne $saved -and $saved.PSObject.Properties['fetchedAt']){try{$fresh=((Get-Date)-[datetime]$saved.fetchedAt).TotalDays -lt 7}catch{}}
    $items=@();if($null -ne $saved){try{$items=@($saved.items)}catch{}}
    if(!$Force -and $fresh -and $items.Count){
        $idx=@{};$tok=@{}
        foreach($x in $items){$nk=Normalize-Name ([string]$x.title);if($nk){$idx[$nk]=$x};$tk=Get-TitleTokenSignature ([string]$x.title);if($tk){if(!$tok.ContainsKey($tk)){$tok[$tk]=New-Object 'System.Collections.Generic.List[object]'};[void]$tok[$tk].Add($x)}}
        $script:PcgwControllerIndex=$idx;$script:PcgwControllerTokenIndex=$tok;return $idx
    }
    Write-Host '[PCGamingWiki] building catalog-wide controller support index (one-time / weekly cache)...' -ForegroundColor Cyan
    $list=New-Object 'System.Collections.Generic.List[object]';$offset=0
    try{
        while($true){
            Wait-PcgwRate
            $fields='Input._pageName=Page,Input.Controller_support=ControllerSupport,Input.Full_controller_support=FullControllerSupport'
            $where="(Input.Controller_support IS NOT NULL AND Input.Controller_support != '') OR (Input.Full_controller_support IS NOT NULL AND Input.Full_controller_support != '')"
            $params=[ordered]@{action='cargoquery';tables='Input';fields=$fields;where=$where;limit='500';offset=[string]$offset;format='json'}
            $pairs=@();foreach($k in $params.Keys){$pairs+=([uri]::EscapeDataString([string]$k)+'='+[uri]::EscapeDataString([string]$params[$k]))}
            $reply=Invoke-RestRetry ('https://www.pcgamingwiki.com/w/api.php?'+($pairs -join '&'));$script:PcgwLastRequest=Get-Date
            $rows=@($reply.cargoquery);if(!$rows.Count){break}
            foreach($row in $rows){$t=$row.title;if($null -eq $t){continue};$name=[string]$t.Page;if(!$name){continue};$c=[string]$t.ControllerSupport;$f=[string]$t.FullControllerSupport;[void]$list.Add([pscustomobject]@{title=$name;category=(Get-PcgwControllerCategory $c $f);controllerSupport=$c;fullControllerSupport=$f})}
            $offset+=$rows.Count;Write-Host ("  [PCGamingWiki] {0:N0} controller rows indexed" -f $offset) -ForegroundColor DarkGray
            if($rows.Count -lt 500){break}
        }
        if($list.Count){Write-JsonAtomic ([pscustomobject]@{fetchedAt=(Get-Date).ToString('o');items=$list.ToArray()}) $path;$items=$list.ToArray()}
    }catch{if(!$items.Count){throw};Write-Warning ('PCGamingWiki refresh failed; using the previous controller index: '+$_.Exception.Message)}
    $idx=@{};$tok=@{};foreach($x in $items){$nk=Normalize-Name ([string]$x.title);if($nk){$idx[$nk]=$x};$tk=Get-TitleTokenSignature ([string]$x.title);if($tk){if(!$tok.ContainsKey($tk)){$tok[$tk]=New-Object 'System.Collections.Generic.List[object]'};[void]$tok[$tk].Add($x)}}
    $script:PcgwControllerIndex=$idx;$script:PcgwControllerTokenIndex=$tok;return $idx
}
function Get-PcgwControllerInfoByTitle([string]$Title) {
    $idx=Get-PcgwControllerIndex;$nk=Normalize-Name $Title;if($idx.ContainsKey($nk)){return $idx[$nk]}
    $tk=Get-TitleTokenSignature $Title;if($script:PcgwControllerTokenIndex.ContainsKey($tk)){$rows=$script:PcgwControllerTokenIndex[$tk];if($rows.Count -eq 1){return $rows[0]}}
    return [pscustomobject]@{title=$Title;category='Unknown';controllerSupport='unknown';fullControllerSupport='unknown'}
}
function Test-PcgwControllerFilter([string]$Title,[string]$Filter) {
    if([string]::IsNullOrWhiteSpace($Filter) -or $Filter -eq 'All'){return $true}
    $info=Get-PcgwControllerInfoByTitle $Title;$c=[string]$info.category
    switch($Filter){'Friendly'{return $c -in @('Full','Partial')};'Full'{return $c -eq 'Full'};'Partial'{return $c -eq 'Partial'};'None'{return $c -eq 'None'};'Unknown'{return $c -eq 'Unknown'};default{return $true}}
}

# ---------------------------------------------------------------------------
# FAST WINDOWS CONTROLLER FILTER
# Steam controller-support search is queried ON DEMAND. This completely
# bypasses the old catalog-wide PCGamingWiki controller crawl.
# Steam category2=28 = Full Controller Support.
# Steam category2=18 = the legacy Partial Controller Support / current
# "Gamepad Preferred" controller bucket shown by Steam Search.
function Get-SteamControllerSort([string]$Sort) {
    switch($Sort){
        'title'{return 'Name_ASC'}
        'yearDesc'{return 'Released_DESC'}
        'yearAsc'{return 'Released_ASC'}
        'ratingDesc'{return 'Reviews_DESC'}
        default{return 'Relevance'}
    }
}
function Get-SteamControllerSearchPage([int]$Page,[string]$Query,[string]$Sort,[string]$ControllerMode) {
    $Page=[Math]::Max(1,$Page)
    $start=($Page-1)*50
    $steamSort=Get-SteamControllerSort $Sort
    if([string]::IsNullOrWhiteSpace($steamSort)){$steamSort='Relevance'}
    $category=if($ControllerMode -eq 'Partial'){'18'}else{'28'}
    $categoryLabel=if($ControllerMode -eq 'Partial'){'Partial Controller Support'}else{'Full Controller Support'}

    $url='https://store.steampowered.com/search/results/?query&start='+$start+'&count=50&dynamic_data=&filter=infinite&infinite=1&category2='+$category+'&l=english&cc=us'
    if(-not [string]::IsNullOrWhiteSpace($Query)){$url+='&term='+[uri]::EscapeDataString($Query)}
    if($steamSort -and $steamSort -ne 'Relevance'){$url+='&sort_by='+[uri]::EscapeDataString($steamSort)}

    $browserUa='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36'
    $html=''
    try {
        $resp=Invoke-WebRequest -UseBasicParsing -Uri $url -Headers @{
            'User-Agent'=$browserUa
            'Accept'='application/json,text/javascript,*/*;q=0.01'
            'X-Requested-With'='XMLHttpRequest'
            'Referer'=('https://store.steampowered.com/search/?category2='+$category)
        } -TimeoutSec 60
        $raw=[string]$resp.Content
        try {$json=$raw | ConvertFrom-Json;if($json -and $json.PSObject.Properties['results_html']){$html=[string]$json.results_html}else{$html=$raw}} catch {$html=$raw}
    } catch {Write-Host ('  [Steam] AJAX search failed; using normal search page: '+$_.Exception.Message) -ForegroundColor DarkYellow}

    if([string]::IsNullOrWhiteSpace($html) -or $html -notmatch 'search_result_row'){
        $pageUrl='https://store.steampowered.com/search/?category2='+$category+'&l=english&cc=us&page='+$Page
        if(-not [string]::IsNullOrWhiteSpace($Query)){$pageUrl+='&term='+[uri]::EscapeDataString($Query)}
        if($steamSort -and $steamSort -ne 'Relevance'){$pageUrl+='&sort_by='+[uri]::EscapeDataString($steamSort)}
        $resp=Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -Headers @{'User-Agent'=$browserUa;'Accept'='text/html,application/xhtml+xml,*/*;q=0.8'} -TimeoutSec 60
        $html=[string]$resp.Content
    }

    $out=New-Object 'System.Collections.Generic.List[object]';$seen=@{}
    foreach($m in [regex]::Matches($html,'(?is)<a\b(?<attrs>[^>]*)>(?<body>.*?)</a>')){
        $attrs=[string]$m.Groups['attrs'].Value;if($attrs -notmatch '(?i)search_result_row'){continue}
        $appid='';$am=[regex]::Match($attrs,'(?i)data-ds-appid\s*=\s*["'']?(?<id>\d+)')
        if($am.Success){$appid=[string]$am.Groups['id'].Value}
        if(!$appid){$am=[regex]::Match($attrs,'(?i)href\s*=\s*["''][^"'']*/app/(?<id>\d+)(?:/|[?"''])');if($am.Success){$appid=[string]$am.Groups['id'].Value}}
        if(!$appid -or $seen.ContainsKey($appid)){continue}
        $body=[string]$m.Groups['body'].Value;$title='';$tm=[regex]::Match($body,'(?is)<span[^>]*class\s*=\s*["''][^"'']*\btitle\b[^"'']*["''][^>]*>(?<t>.*?)</span>')
        if($tm.Success){$title=Strip-Html ([string]$tm.Groups['t'].Value)}
        if([string]::IsNullOrWhiteSpace($title)){$tm=[regex]::Match($body,'(?is)<span[^>]*>(?<t>[^<>]{2,160})</span>');if($tm.Success){$title=Strip-Html ([string]$tm.Groups['t'].Value)}}
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $seen[$appid]=$true;[void]$out.Add([pscustomobject]@{appid=$appid;title=$title;controllerCategory=$ControllerMode})
    }
    Write-Host ("  [Steam] page {0}: {1} {2} rows" -f $Page,$out.Count,$categoryLabel) -ForegroundColor DarkGray
    return $out.ToArray()
}
function Get-SteamControllerSearchBatch([int]$Page,[string]$Query,[string]$Sort,[string]$ControllerMode) {
    if($ControllerMode -ne 'Any'){
        $rows=@(Get-SteamControllerSearchPage $Page $Query $Sort $ControllerMode)
        return [pscustomobject]@{items=$rows;completeHint=($rows.Count -lt 50)}
    }
    $full=@(Get-SteamControllerSearchPage $Page $Query $Sort 'Full')
    $partial=@(Get-SteamControllerSearchPage $Page $Query $Sort 'Partial')
    $out=New-Object 'System.Collections.Generic.List[object]';$seen=@{};$max=[Math]::Max($full.Count,$partial.Count)
    for($i=0;$i -lt $max;$i++){
        if($i -lt $full.Count){$r=$full[$i];$id=[string]$r.appid;if($id -and !$seen.ContainsKey($id)){$seen[$id]=$true;[void]$out.Add($r)}}
        if($i -lt $partial.Count){$r=$partial[$i];$id=[string]$r.appid;if($id -and !$seen.ContainsKey($id)){$seen[$id]=$true;[void]$out.Add($r)}}
    }
    return [pscustomobject]@{items=$out.ToArray();completeHint=($full.Count -lt 50 -and $partial.Count -lt 50)}
}
function Get-IgdbRowsForSteamApps($SteamRows,[long]$GenreId) {
    $steam=@($SteamRows | Where-Object {$_.appid});if(!$steam.Count){return [pscustomobject]@{items=@();metadata=@{}}}
    $uids=@($steam | ForEach-Object {[string]$_.appid} | Select-Object -Unique);$quoted=@($uids | ForEach-Object {'"'+($_ -replace '"','\\"')+'"'})
    $extBody="fields game,uid,name,external_game_source; where external_game_source = 1 & uid = ($($quoted -join ',')); limit 500;"
    $external=@(Invoke-IgdbEndpoint 'external_games' $extBody)
    Write-Host ("  [IGDB] Steam App IDs mapped: {0}/{1}" -f $external.Count,$uids.Count) -ForegroundColor DarkGray
    $steamToGame=@{};foreach($x in $external){$uid=[string]$x.uid;$gid=0L;try{$gid=[long]$x.game}catch{};if($uid -and $gid -gt 0 -and !$steamToGame.ContainsKey($uid)){$steamToGame[$uid]=$gid}}
    $gids=@($steamToGame.Values | ForEach-Object {[long]$_} | Select-Object -Unique);if(!$gids.Count){return [pscustomobject]@{items=@();metadata=@{}}}
    $fields='id,name,slug,first_release_date,rating,rating_count,genres.id,genres.name,cover.image_id';$rows=@(Invoke-IgdbEndpoint 'games' ("fields $fields; where id = ($($gids -join ',')); limit 500;"))
    $byId=@{};foreach($r in $rows){try{$byId[[long]$r.id]=$r}catch{}}
    $items=New-Object 'System.Collections.Generic.List[object]';$meta=@{}
    foreach($sr in $steam){
        if(!$steamToGame.ContainsKey([string]$sr.appid)){continue};$gid=[long]$steamToGame[[string]$sr.appid];if(!$byId.ContainsKey($gid)){continue};$r=$byId[$gid]
        if($GenreId -gt 0){$ok=$false;try{foreach($gr in @($r.genres)){if([long]$gr.id -eq $GenreId){$ok=$true;break}}}catch{};if(!$ok){continue}}
        $e=Convert-IgdbCatalogRowToEntry 'Windows' $r;if($null -eq $e){continue}
        $cat=if([string]$sr.controllerCategory -eq 'Partial'){'Partial'}else{'Full'}
        Set-Prop $e 'controllerCategory' $cat;Set-Prop $e 'controllerSupport' ($cat.ToLowerInvariant());Set-Prop $e 'fullControllerSupport' $(if($cat -eq 'Full'){'full'}else{'partial'});Set-Prop $e 'controllerSource' 'Steam';Set-Prop $e 'steamAppId' ([string]$sr.appid)
        [void]$items.Add($e);$meta[[string]$e.id]=Convert-IgdbRowToCardMetadata $r ([string]$e.title)
    }
    return [pscustomobject]@{items=$items.ToArray();metadata=$meta}
}
function Get-SteamControllerCatalogPage([int]$Offset,[int]$Limit,[string]$Query,[long]$GenreId,[string]$Sort,[string]$Daily,[string]$ControllerMode) {
    $dailyOnly=([string]$Daily -eq 'Only');$priority=@();$priorityIds=@{}
    if($dailyOnly){$priority=@(Get-IgdbPreparedDailyPriority 'Windows' 200);foreach($p in $priority){try{$gid=[long]$p.igdbId;if($gid -gt 0){$priorityIds[$gid]=$p}}catch{}};if(!$priorityIds.Count){return [pscustomobject]@{items=@();metadata=@{};cachedCount=0;matchingCount=0;complete=$true;hasMore=$false;sourceFetched=$true;searchScope='steam-controller';warning='Daily Chunk priority list has not been prepared yet.';priorityCount=0}}}
    $key=($ControllerMode+'|'+$Query+'|'+$GenreId+'|'+$Sort+'|'+$Daily)
    if(!$script:SteamControllerQueryCaches.ContainsKey($key)){$script:SteamControllerQueryCaches[$key]=[pscustomobject]@{steamPage=1;complete=$false;matches=(New-Object 'System.Collections.Generic.List[object]');metadata=@{};seen=@{}}}
    $st=$script:SteamControllerQueryCaches[$key];$target=$Offset+$Limit
    while($st.matches.Count -lt $target -and !$st.complete){
        $batch=Get-SteamControllerSearchBatch ([int]$st.steamPage) $Query $Sort $ControllerMode
        $steamRows=@($batch.items);if(!$steamRows.Count){$st.complete=$true;break}
        $mapped=Get-IgdbRowsForSteamApps $steamRows $GenreId
        foreach($e in @($mapped.items)){
            $gid=0L;try{$gid=[long]$e.igdbId}catch{};if($dailyOnly -and !$priorityIds.ContainsKey($gid)){continue}
            $eid=[string]$e.id;if($st.seen.ContainsKey($eid)){continue};$st.seen[$eid]=$true
            if($priorityIds.ContainsKey($gid)){$p=$priorityIds[$gid];Set-Prop $e 'dailyPriority' $true;Set-Prop $e 'dailyOrder' ([int]$p.dailyOrder)}
            [void]$st.matches.Add($e);if($mapped.metadata.ContainsKey($eid)){$st.metadata[$eid]=$mapped.metadata[$eid]}
        }
        $st.steamPage=[int]$st.steamPage+1
        if([bool]$batch.completeHint){$st.complete=$true}
    }
    $page=@($st.matches | Select-Object -Skip $Offset -First $Limit);if($dailyOnly){$page=@(Add-DailyChunkDataToRows $page)}
    $pageMeta=@{};foreach($e in $page){if($st.metadata.ContainsKey([string]$e.id)){$pageMeta[[string]$e.id]=$st.metadata[[string]$e.id]}}
    $scope='steam-'+$ControllerMode.ToLowerInvariant()+'-controller'
    return [pscustomobject]@{items=$page;metadata=$pageMeta;cachedCount=0;matchingCount=$null;complete=[bool]$st.complete;hasMore=($st.matches.Count -gt $Offset+$page.Count -or !$st.complete);sourceFetched=$true;searchScope=$scope;warning=$null;priorityCount=($priorityIds.Count)}
}

function Sort-CatalogRows($Rows,[string]$Sort) {
    switch($Sort){
        'yearDesc'{return @($Rows | Sort-Object @{Expression={try{-[int]$_.releaseYear}catch{0}}},title)}
        'yearAsc'{return @($Rows | Sort-Object @{Expression={try{[int]$_.releaseYear}catch{9999}}},title)}
        'ratingDesc'{return @($Rows | Sort-Object @{Expression={try{-[double]$_.rating}catch{0}}},@{Expression={try{-[long]$_.ratingCount}catch{0}}},title)}
        default{return @($Rows | Sort-Object title)}
    }
}
function Test-CatalogIgdbGenreMatch($Game,[long]$GenreId) {
    if($GenreId -le 0){return $true}
    $ids=@();try{$ids=@($Game.catalogGenreIds | Where-Object {$_})}catch{}
    foreach($id in $ids){try{if([long]$id -eq $GenreId){return $true}}catch{}}
    return $false
}

function Get-StaticCatalogPageV2([string]$Platform,[int]$Offset,[int]$Limit,[string]$Query,[long]$GenreId,[string]$Sort,[string]$Daily) {
    # Fast path: read only this platform's small JSON file. Do not parse the
    # combined catalog.json merely because the user changed platforms.
    $rows=@(Read-PlatformCatalog $Platform)
    if($Query){$nq=$Query.ToLowerInvariant();$rows=@($rows | Where-Object {([string]$_.title).ToLowerInvariant().Contains($nq)})}
    if($GenreId -gt 0){$rows=@($rows | Where-Object {Test-CatalogIgdbGenreMatch $_ $GenreId})}
    $dailyOnly=([string]$Daily -eq 'Only')
    if($dailyOnly){$rows=@($rows | Where-Object {$_.dailyPriority})}
    $priority=@($rows | Where-Object {$_.dailyPriority});$rest=@($rows | Where-Object {!$_.dailyPriority})
    if($Sort -eq 'daily' -or [string]::IsNullOrWhiteSpace($Sort)){$priority=@($priority | Sort-Object dailyOrder,title);$rest=@($rest | Sort-Object title)}else{$priority=Sort-CatalogRows $priority $Sort;$rest=Sort-CatalogRows $rest $Sort}
    $ordered=@($priority)+@($rest)
    $items=@($ordered | Select-Object -Skip $Offset -First $Limit)
    # Normal browsing does ZERO daily-chunks.json lookup. Only the explicit
    # Daily Chunk filter loads chunk text for the visible 20 rows.
    if($dailyOnly){$items=@(Add-DailyChunkDataToRows $items)}

    # DAT-backed catalogs already store the canonical IGDB ID. Fetch the
    # CURRENT PAGE in one bulk /games request and return it directly to the UI.
    # Nothing is written to metadata-cache.json.
    $pageMetadata=@{}
    if($items.Count){
        try{$pageMetadata=Get-IgdbCardMetadataBatch $items}
        catch{Write-Warning ("[{0}] page metadata request failed: {1}" -f $Platform,$_.Exception.Message)}
    }

    $state=Read-State;$ps=Get-PlatformState $state $Platform
    return [pscustomobject]@{items=$items;metadata=$pageMetadata;cachedCount=$rows.Count;matchingCount=$ordered.Count;complete=[bool]$ps.complete;hasMore=($Offset+$items.Count -lt $ordered.Count);sourceFetched=$false;searchScope='platform-file-catalog';warning=$null}
}

function Get-ControllerFilteredIgdbRest([string]$Platform,[int]$NeedOffset,[int]$NeedLimit,[string]$Query,[long]$GenreId,[string]$Sort,[string]$Controller,$ExcludeIds) {
    [void](Get-PcgwControllerIndex)
    $key=($Platform+'|'+$Query+'|'+$GenreId+'|'+$Sort+'|'+$Controller+'|'+(@($ExcludeIds)-join ','))
    if(!$script:ControllerQueryCaches.ContainsKey($key)){$script:ControllerQueryCaches[$key]=[pscustomobject]@{scanOffset=0;complete=$false;matches=(New-Object 'System.Collections.Generic.List[object]')}}
    $st=$script:ControllerQueryCaches[$key];$target=$NeedOffset+$NeedLimit
    while($st.matches.Count -lt $target -and !$st.complete){
        $rows=@(Get-IgdbDirectGameRows $Platform ([int]$st.scanOffset) 500 $Query $GenreId $Sort $ExcludeIds)
        if(!$rows.Count){$st.complete=$true;break}
        foreach($r in $rows){if(Test-PcgwControllerFilter ([string]$r.name) $Controller){$e=Convert-IgdbCatalogRowToEntry $Platform $r;$ci=Get-PcgwControllerInfoByTitle $e.title;Set-Prop $e 'controllerCategory' ([string]$ci.category);Set-Prop $e 'controllerSupport' ([string]$ci.controllerSupport);Set-Prop $e 'fullControllerSupport' ([string]$ci.fullControllerSupport);[void]$st.matches.Add($e)}}
        $st.scanOffset=[int]$st.scanOffset+$rows.Count;if($rows.Count -lt 500){$st.complete=$true}
    }
    $page=@($st.matches | Select-Object -Skip $NeedOffset -First $NeedLimit);if($page.Count){[void](Merge-Catalog $Platform $page)}
    return [pscustomobject]@{items=$page;hasMore=($st.matches.Count -gt $NeedOffset+$page.Count -or !$st.complete);complete=[bool]$st.complete}
}

function Get-OnDemandCatalogPageV2([string]$Platform,[int]$Offset,[int]$Limit,[string]$Query,[long]$GenreId,[string]$Sort,[string]$Controller,[string]$Daily) {
    # Windows Full Controller Support comes directly from Steam search. No PCGamingWiki index.
    if($Platform -eq 'Windows' -and $Controller -in @('Full','Partial','Any')){return Get-SteamControllerCatalogPage $Offset $Limit $Query $GenreId $Sort $Daily $Controller}
    $priority=@(Get-IgdbPreparedDailyPriority $Platform 200)
    $pfiltered=@($priority)
    if($Query){$nq=$Query.ToLowerInvariant();$pfiltered=@($pfiltered | Where-Object {([string]$_.title).ToLowerInvariant().Contains($nq)})}
    if($GenreId -gt 0){$pfiltered=@($pfiltered | Where-Object {Test-CatalogIgdbGenreMatch $_ $GenreId})}
    $dailyOnly=([string]$Daily -eq 'Only')
    if($Sort -eq 'daily' -or [string]::IsNullOrWhiteSpace($Sort)){$pfiltered=@($pfiltered | Sort-Object dailyOrder,title)}else{$pfiltered=Sort-CatalogRows $pfiltered $Sort}
    $excludeIds=@($priority | ForEach-Object {try{[long]$_.igdbId}catch{}} | Where-Object {$_})
    $items=New-Object 'System.Collections.Generic.List[object]'
    $pageMetadata=@{}
    $priorityCount=$pfiltered.Count;$restOffset=[Math]::Max(0,$Offset-$priorityCount)
    if($Offset -lt $priorityCount){foreach($e in @($pfiltered | Select-Object -Skip $Offset -First $Limit)){[void]$items.Add($e)}}
    $remaining=$Limit-$items.Count;$restHasMore=$false;$restComplete=$false
    if($dailyOnly){$remaining=0;$restComplete=$true}
    if($remaining -gt 0){
            # For normal IGDB-only pages this ONE request already contains the
            # complete card/gallery metadata. Do not issue a second enrichment request.
            $probe=[Math]::Min(500,$remaining+1)
            $rows=@(Get-IgdbDirectGameRows $Platform $restOffset $probe $Query $GenreId $Sort $excludeIds)
            $pageRows=@($rows | Select-Object -First $remaining)
            $newEntries=New-Object 'System.Collections.Generic.List[object]'
            foreach($row in $pageRows){
                $e=Convert-IgdbCatalogRowToEntry $Platform $row
                if($null -ne $e){
                    [void]$items.Add($e);[void]$newEntries.Add($e)
                    $pageMetadata[[string]$e.id]=Convert-IgdbRowToCardMetadata $row ([string]$e.title)
                }
            }
            # IGDB-only browsing is intentionally stateless, like the standalone
            # PowerShell browser. Do not rewrite the giant catalog.json merely
            # because the user viewed another 20 games.
            $restHasMore=($rows.Count -gt $remaining);$restComplete=(!$restHasMore)
    }
    $hasMore=($Offset+$items.Count -lt $priorityCount) -or ((-not $dailyOnly) -and $restHasMore)
    # Avoid reparsing the full multi-system catalog on every IGDB-only page.
    $cached=$priority.Count
    $pageItems=@($items.ToArray())
    if($dailyOnly){$pageItems=@(Add-DailyChunkDataToRows $pageItems)}

    # Priority rows (and controller-filtered rows) came from local ID lists, so
    # bulk-fetch only the metadata that was not already returned by the direct
    # page query. This is at most ONE /games request for the visible page.
    $missing=New-Object 'System.Collections.Generic.List[object]'
    foreach($e in $pageItems){if(!$pageMetadata.ContainsKey([string]$e.id)){[void]$missing.Add($e)}}
    if($missing.Count){
        try{
            $batch=Get-IgdbCardMetadataBatch $missing.ToArray()
            foreach($kv in $batch.GetEnumerator()){$pageMetadata[[string]$kv.Key]=$kv.Value}
        }catch{Write-Warning ("[{0}] page metadata request failed: {1}" -f $Platform,$_.Exception.Message)}
    }

    return [pscustomobject]@{items=$pageItems;metadata=$pageMetadata;cachedCount=$cached;matchingCount=$null;complete=$restComplete;hasMore=$hasMore;sourceFetched=$true;searchScope='igdb-server-filtered';warning=$null;priorityCount=$priorityCount}
}

function Get-CatalogPageV2([string]$Platform,[int]$Offset,[int]$Limit,[string]$Query,[long]$GenreId,[string]$Sort,[string]$Controller,[string]$Daily) {
    if(!($Platforms -contains $Platform)){throw "Unknown platform: $Platform"};$Offset=[Math]::Max(0,$Offset);$Limit=[Math]::Min(100,[Math]::Max(20,$Limit))
    if($StaticCachePlatforms -contains $Platform){return Get-StaticCatalogPageV2 $Platform $Offset $Limit $Query $GenreId $Sort $Daily}
    return Get-OnDemandCatalogPageV2 $Platform $Offset $Limit $Query $GenreId $Sort $Controller $Daily
}


# ============================================================================
# ANY-DAT INTERSECTION v5 (IGDB updated_at sync v1; V3.4 in-place migration)
# Universal rule for static systems:
#   IGDB AND (configured DAT 1 OR configured DAT 2 OR configured DAT 3 ...)
# IGDB remains canonical. Preservation sources only decide inclusion.
# ============================================================================
function Get-PreservationSourcesV4($Cfg,[string]$Platform) {
    $list=New-Object 'System.Collections.Generic.List[object]'
    $seen=@{}
    try {
        if($Cfg.PSObject.Properties['preservationSources']) {
            foreach($src in $Cfg.preservationSources) {
                if($null -eq $src){continue}
                $type='dat-url';$label='Preservation DAT';$url='';$code=''
                try{if($src.type){$type=[string]$src.type}}catch{}
                try{if($src.label){$label=[string]$src.label}}catch{}
                try{if($src.url){$url=[string]$src.url}}catch{}
                try{if($src.datCode){$code=[string]$src.datCode}}catch{}
                if($type -eq 'redump') {
                    if([string]::IsNullOrWhiteSpace($code)){continue}
                    $key=('redump:'+($code.ToUpperInvariant()))
                } else {
                    if([string]::IsNullOrWhiteSpace($url)){continue}
                    $key=$url.ToLowerInvariant()
                }
                if($seen.ContainsKey($key)){continue};$seen[$key]=$true
                [void]$list.Add([pscustomobject]@{type=$type;label=$label;url=$url;datCode=$code})
            }
        }
    } catch {}
    if($list.Count -gt 0){return $list.ToArray()}

    # Backwards compatibility for older platforms.json files.
    $mode=[string]$Cfg.mode
    if($mode -eq 'redump') {
        $code=[string]$Cfg.datCode
        if($code){[void]$list.Add([pscustomobject]@{type='redump';label=("Redump {0}" -f $Platform);url='';datCode=$code})}
    } elseif($mode -eq 'nointro') {
        $url=[string]$Cfg.datUrl
        if($url){[void]$list.Add([pscustomobject]@{type='dat-url';label=("No-Intro {0}" -f $Platform);url=$url;datCode=''})}
    }
    try {
        foreach($extra in $Cfg.extraDatUrls) {
            $url='';$label='Additional DAT'
            if($extra -is [string]){$url=[string]$extra}else{try{$url=[string]$extra.url}catch{};try{if($extra.label){$label=[string]$extra.label}}catch{}}
            if($url){[void]$list.Add([pscustomobject]@{type='dat-url';label=$label;url=$url;datCode=''})}
        }
    } catch {}
    return $list.ToArray()
}
function Get-PreservationSourceLocalPathV5($Source,[string]$Platform,[int]$Index) {
    $safe=State-Key $Platform
    $type=[string]$Source.type
    $url=''
    if($type -eq 'redump'){$url="https://redump.info/datfile/$([string]$Source.datCode)"}else{$url=[string]$Source.url}
    if([string]::IsNullOrWhiteSpace($url)){throw 'Preservation source URL is empty.'}

    $ext=$(if($type -eq 'redump'){'.bin'}else{'.dat'})
    $identity=('{0}|{1}|{2}' -f $type,[string]$Source.datCode,$url)
    $sha=[Security.Cryptography.SHA1]::Create()
    try{$hashBytes=$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity));$shortHash=(($hashBytes | ForEach-Object {$_.ToString('x2')}) -join '').Substring(0,12)}finally{$sha.Dispose()}
    $platformDatRoot=Join-Path $DatsRoot $safe
    $path=Join-Path $platformDatRoot ("source-{0}-{1}{2}" -f $Index,$shortHash,$ext)
    return [pscustomobject]@{path=$path;url=$url;safe=$safe;ext=$ext;shortHash=$shortHash}
}
function Get-PreservationSourceFingerprint([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    if($null -eq $cfg){return ''}
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $idx=0
    foreach($src in (Get-PreservationSourcesV4 $cfg $Platform)) {
        $idx++
        $local=Get-PreservationSourceLocalPathV5 $src $Platform $idx
        $contentSha256='MISSING'
        $bytes=0L
        if(Test-Path -LiteralPath ([string]$local.path)) {
            try {
                $contentSha256=(Get-FileHash -LiteralPath ([string]$local.path) -Algorithm SHA256).Hash.ToLowerInvariant()
                $bytes=(Get-Item -LiteralPath ([string]$local.path)).Length
            } catch {
                $contentSha256='HASH-ERROR'
            }
        }
        # Configuration identifies the source; SHA-256 identifies the actual downloaded bytes.
        $part=('{0}|{1}|{2}|{3}|bytes={4}|sha256={5}' -f ([string]$src.type),([string]$src.datCode),([string]$src.url),([string]$src.label),$bytes,$contentSha256)
        [void]$parts.Add($part)
    }
    # V5 is deliberately part of the fingerprint so matcher-rule changes invalidate old caches.
    [void]$parts.Add('matcher=igdb-any-preservation-dat-v5-unambiguous-token')
    $text=(($parts.ToArray() | Sort-Object) -join "`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($text)
        $hash=$sha.ComputeHash($bytes)
        return (($hash | ForEach-Object {$_.ToString('x2')}) -join '')
    } finally {$sha.Dispose()}
}

function Add-PreservationDatTextV4([string]$Text,$RecordsByKey,[string]$SourceLabel,[string]$SourceUrl) {
    if([string]::IsNullOrWhiteSpace($Text)){return 0}
    $before=$RecordsByKey.Count
    $matches=[regex]::Matches($Text,'(?ims)^\s*(?:game|machine)\s*\(\s*name\s+"([^"\r\n]+)"')
    foreach($m in $matches) {
        $raw=[string]$m.Groups[1].Value
        if(!(Test-PreservationGameName $raw)){continue}
        $title=Convert-RedumpDatTitle $raw
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $key=Normalize-Name $title
        if([string]::IsNullOrWhiteSpace($key)){continue}
        if(!$RecordsByKey.ContainsKey($key)){
            $RecordsByKey[$key]=[pscustomobject]@{key=$key;title=$title;variants=(New-Object 'System.Collections.Generic.List[object]')}
        }
        [void]$RecordsByKey[$key].variants.Add([pscustomobject]@{title=$raw;serial='';source=$SourceLabel;sourceUrl=$SourceUrl})
    }
    return ($RecordsByKey.Count-$before)
}
function Add-RedumpXmlV4([string]$XmlText,$RecordsByKey,[string]$SourceLabel,[string]$SourceUrl) {
    if([string]::IsNullOrWhiteSpace($XmlText)){return 0}
    $before=$RecordsByKey.Count
    [xml]$doc=$XmlText
    foreach($node in @($doc.SelectNodes('//game | //machine'))) {
        $raw=[string]$node.GetAttribute('name')
        if([string]::IsNullOrWhiteSpace($raw)){try{$raw=[string]$node.description}catch{}}
        if(!(Test-PreservationGameName $raw)){continue}
        $title=Convert-RedumpDatTitle $raw
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $key=Normalize-Name $title;if([string]::IsNullOrWhiteSpace($key)){continue}
        $serial=''
        try{$sn=$node.SelectSingleNode('./serial | .//rom/@serial | .//rom/serial');if($sn){$serial=[string]$sn.InnerText;if([string]::IsNullOrWhiteSpace($serial)){$serial=[string]$sn.Value}}}catch{}
        if(!$RecordsByKey.ContainsKey($key)){$RecordsByKey[$key]=[pscustomobject]@{key=$key;title=$title;variants=(New-Object 'System.Collections.Generic.List[object]')}}
        [void]$RecordsByKey[$key].variants.Add([pscustomobject]@{title=$raw;serial=$serial;source=$SourceLabel;sourceUrl=$SourceUrl})
    }
    return ($RecordsByKey.Count-$before)
}

function Get-HttpStatusCodeV4($ErrorRecord) {
    try { return [int]$ErrorRecord.Exception.Response.StatusCode } catch { return 0 }
}
function Get-RetryAfterSecondsV4($ErrorRecord,[int]$FallbackSeconds) {
    $seconds=0
    try {
        $raw=[string]$ErrorRecord.Exception.Response.Headers['Retry-After']
        if($raw -match '^\d+$'){$seconds=[int]$raw}
    } catch {}
    if($seconds -le 0){$seconds=$FallbackSeconds}
    return [Math]::Max(1,[Math]::Min(120,$seconds))
}
function Invoke-DownloadFileRetryV4([string]$Uri,[string]$OutFile,[string]$Accept='*/*',[int]$MaxAttempts=6) {
    $last=$null
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers @{
                'User-Agent'=$UserAgent
                'Accept'=$Accept
            } -OutFile $OutFile -TimeoutSec 240
            return
        } catch {
            $last=$_
            $code=Get-HttpStatusCodeV4 $_
            if($attempt -ge $MaxAttempts){break}
            if($code -eq 429) {
                $fallback=[Math]::Min(60,[int](5*[Math]::Pow(2,$attempt-1)))
                $wait=Get-RetryAfterSecondsV4 $_ $fallback
                Write-Host ("      HTTP 429 from source; retrying in {0}s ({1}/{2})..." -f $wait,$attempt,$MaxAttempts) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            } else {
                $wait=[Math]::Min(15,$attempt*2)
                Write-Host ("      download retry {0}/{1} in {2}s..." -f $attempt,$MaxAttempts,$wait) -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
            }
        }
    }
    if($last){throw $last}
    throw "Unable to download $Uri"
}
function Ensure-LibretroDatabaseBundleV4 {
    $bundleRoot=Join-Path $CacheRoot 'libretro-database-master'
    $datDir=Join-Path $bundleRoot 'dat'
    $metaDir=Join-Path $bundleRoot 'metadat'
    if((Test-Path -LiteralPath $datDir) -and (Test-Path -LiteralPath $metaDir)){return $bundleRoot}

    $zipPath=Join-Path $CacheRoot 'libretro-database-master.zip'
    $zipTmp="$zipPath.download"
    $extractTmp=Join-Path $CacheRoot 'libretro-database-extract'
    $archiveUrl='https://codeload.github.com/libretro/libretro-database/zip/refs/heads/master'

    if(!(Test-Path -LiteralPath $zipPath)) {
        Write-Host '      downloading Libretro database bundle once for all Libretro/No-Intro DAT sources...' -ForegroundColor DarkGray
        try{Remove-Item -LiteralPath $zipTmp -Force -ErrorAction SilentlyContinue}catch{}
        Invoke-DownloadFileRetryV4 $archiveUrl $zipTmp 'application/zip,*/*' 6
        Move-Item -LiteralPath $zipTmp -Destination $zipPath -Force
    } else {
        Write-Host '      using cached Libretro database bundle...' -ForegroundColor DarkGray
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    try{Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    New-Item -ItemType Directory -Path $extractTmp -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($zipPath,$extractTmp)
        $extracted=Join-Path $extractTmp 'libretro-database-master'
        if(!(Test-Path -LiteralPath $extracted)){throw 'Libretro bundle archive did not contain libretro-database-master.'}
        try{Remove-Item -LiteralPath $bundleRoot -Recurse -Force -ErrorAction SilentlyContinue}catch{}
        Move-Item -LiteralPath $extracted -Destination $bundleRoot -Force
    } catch {
        # If a cached archive is damaged, discard it so the next run can redownload cleanly.
        try{Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue}catch{}
        throw
    } finally {
        try{Remove-Item -LiteralPath $extractTmp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
    }
    return $bundleRoot
}
function Get-LibretroBundleFileV4([string]$Url) {
    $prefix='https://raw.githubusercontent.com/libretro/libretro-database/master/'
    if(!$Url.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return $null}
    $relative=$Url.Substring($prefix.Length)
    try{$relative=[Uri]::UnescapeDataString($relative)}catch{}
    $relative=$relative -replace '/', [IO.Path]::DirectorySeparatorChar
    $root=Ensure-LibretroDatabaseBundleV4
    $candidate=Join-Path $root $relative
    if(Test-Path -LiteralPath $candidate){return $candidate}
    Write-Warning ("Libretro bundle does not contain expected DAT path: {0}" -f $relative)
    return $null
}

function Get-LibretroJsDelivrUrlV5([string]$Url) {
    $prefix='https://raw.githubusercontent.com/libretro/libretro-database/master/'
    if(!$Url.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){return ''}
    $relative=$Url.Substring($prefix.Length)
    # Keep the original URL escaping. jsDelivr accepts the same relative path.
    return ('https://cdn.jsdelivr.net/gh/libretro/libretro-database@master/' + $relative)
}

function Get-PreservationSourceFileV4($Source,[string]$Platform,[int]$Index) {
    $type=[string]$Source.type
    $local=Get-PreservationSourceLocalPathV5 $Source $Platform $Index
    $safe=[string]$local.safe
    $url=[string]$local.url
    $ext=[string]$local.ext
    $shortHash=[string]$local.shortHash

    # DATs live in a dedicated local folder. START WEBSITE never downloads them.
    $platformDatRoot=Join-Path $DatsRoot $safe
    New-Item -ItemType Directory -Force -Path $platformDatRoot | Out-Null
    $path=[string]$local.path

    # Migrate the old _cache preservation file automatically when present.
    $legacyPath=Join-Path $CacheRoot ("preservation-{0}-source-{1}-{2}{3}" -f $safe,$Index,$shortHash,$ext)
    if(!(Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $legacyPath)) {
        try {
            Copy-Item -LiteralPath $legacyPath -Destination $path -Force
            Write-Host ("      migrated cached DAT into DATs\{0}" -f $safe) -ForegroundColor DarkGray
        } catch {}
    }

    # Normal website/cache building is deliberately LOCAL ONLY. Network access to
    # preservation providers is available only through UPDATE DATS.bat.
    if(!$script:AllowPreservationDownloads) {
        if(Test-Path -LiteralPath $path){return [pscustomobject]@{path=$path;url=$url;fromCache=$true;skippedFresh=$false}}
        throw ("Local DAT missing for '{0}'. Run UPDATE DATS.bat, then start the website again." -f [string]$Source.label)
    }

    # A normal UPDATE DATS run is resumable: successful files newer than seven
    # days are reused instead of being hammered again. FORCE UPDATE DATS.bat
    # bypasses this freshness check.
    if((Test-Path -LiteralPath $path) -and !$script:ForcePreservationRefresh) {
        $ageDays=9999.0
        try{$ageDays=((Get-Date)-(Get-Item -LiteralPath $path).LastWriteTime).TotalDays}catch{}
        if($ageDays -lt $script:PreservationRefreshDays) {
            return [pscustomobject]@{path=$path;url=$url;fromCache=$true;skippedFresh=$true}
        }
    }

    $tmp="$path.download"
    $accept=$(if($type -eq 'redump'){'application/zip,application/xml,text/xml,*/*'}else{'text/plain,application/xml,*/*'})
    $updateFailed=$false
    try {
        try{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}catch{}

        if($type -ne 'redump') {
            $cdnUrl=Get-LibretroJsDelivrUrlV5 $url
            if(![string]::IsNullOrWhiteSpace($cdnUrl)) {
                Write-Host '      downloading DAT through jsDelivr CDN...' -ForegroundColor DarkGray
                try {
                    Invoke-DownloadFileRetryV4 $cdnUrl $tmp $accept 4
                } catch {
                    Write-Warning ("[{0}] jsDelivr download failed for {1}; falling back to GitHub raw." -f $Platform,[string]$Source.label)
                    try{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}catch{}
                    Invoke-DownloadFileRetryV4 $url $tmp $accept 3
                }
            } else {
                Invoke-DownloadFileRetryV4 $url $tmp $accept 4
            }
        } else {
            Invoke-DownloadFileRetryV4 $url $tmp $accept 6
        }

        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        try{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}catch{}
        if(Test-Path -LiteralPath $path) {
            $updateFailed=$true
            Write-Warning ("[{0}] update failed for {1}; keeping the previously downloaded local DAT." -f $Platform,[string]$Source.label)
        } else {throw}
    }
    return [pscustomobject]@{path=$path;url=$url;fromCache=$updateFailed;skippedFresh=$false;updateFailed=$updateFailed}
}

function Read-RedumpSourceTextV4([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($Path)
        try {
            $entry=$zip.Entries | Where-Object {$_.Name -match '(?i)\.(dat|xml)$'} | Sort-Object Length -Descending | Select-Object -First 1
            if($null -eq $entry){throw 'No DAT/XML entry found in Redump archive.'}
            $stream=$entry.Open()
            try{$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true);try{return $reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
        } finally {$zip.Dispose()}
    } catch {
        return (Get-Content -LiteralPath $Path -Raw)
    }
}
function Get-PreservationDatIndex([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    if($null -eq $cfg){throw "Unknown platform: $Platform"}
    if([string]$cfg.mode -eq 'igdb'){throw "$Platform is IGDB-only and has no preservation DAT configured."}
    $sources=@(Get-PreservationSourcesV4 $cfg $Platform)
    if(!$sources.Count){throw "No preservation DAT sources configured for $Platform"}

    $recordsByKey=@{}
    $sourceInfo=New-Object 'System.Collections.Generic.List[object]'
    $idx=0
    foreach($source in $sources) {
        $idx++
        $label=[string]$source.label
        if([string]::IsNullOrWhiteSpace($label)){$label=("DAT source {0}" -f $idx)}
        Write-Host ("  [{0}] source {1}/{2}: {3}" -f $Platform,$idx,$sources.Count,$label) -ForegroundColor DarkGray
        $file=Get-PreservationSourceFileV4 $source $Platform $idx
        $before=$recordsByKey.Count
        if([string]$source.type -eq 'redump') {
            $text=Read-RedumpSourceTextV4 ([string]$file.path)
            [void](Add-RedumpXmlV4 $text $recordsByKey $label ([string]$file.url))
        } else {
            $text=Get-Content -LiteralPath ([string]$file.path) -Raw
            if([string]::IsNullOrWhiteSpace($text)){throw "$label DAT was empty."}
            [void](Add-PreservationDatTextV4 $text $recordsByKey $label ([string]$file.url))
        }
        $newTitles=$recordsByKey.Count-$before
        [void]$sourceInfo.Add([pscustomobject]@{label=$label;url=[string]$file.url;type=[string]$source.type;newCanonicalTitles=$newTitles})
        Write-Host ("      +{0:N0} new canonical titles; {1:N0} combined" -f $newTitles,$recordsByKey.Count) -ForegroundColor DarkGray
    }
    if(!$recordsByKey.Count){throw 'All configured preservation DATs were empty or produced no usable game titles.'}
    $index=New-PreservationIndexFromRecords (($sourceInfo.ToArray() | ForEach-Object {$_.url}) -join ' | ') $recordsByKey
    Set-Prop $index 'sources' $sourceInfo.ToArray()
    Set-Prop $index 'sourceCount' $sourceInfo.Count
    return $index
}
function Build-IgdbPreservationIntersectionCatalog([string]$Platform) {
    $cfg=Get-PlatformConfig $Platform
    $dat=Get-PreservationDatIndex $Platform
    $igdbRows=@(Get-IgdbPlatformTitleMap $Platform)
    if(!$igdbRows.Count){throw 'IGDB platform map is empty.'}
    if(!$dat.records.Count){throw 'Preservation DAT union produced no usable titles.'}

    $entries=New-Object 'System.Collections.Generic.List[object]'
    $matchedExact=0;$matchedToken=0;$ambiguousTokenSkipped=0;$sourceHitCounts=@{}
    foreach($row in $igdbRows) {
        if($null -eq $row){continue}
        $gid=0L;try{$gid=[long]$row.id}catch{}
        $title=[string]$row.name
        if($gid -le 0 -or [string]::IsNullOrWhiteSpace($title)){continue}
        $names=New-Object 'System.Collections.Generic.List[string]';[void]$names.Add($title)
        try{foreach($alt in $row.alternative_names){if($alt.name){[void]$names.Add([string]$alt.name)}}}catch{}
        $candidateByKey=@{}
        foreach($name in $names.ToArray()){
            $nk=Normalize-Name $name;if(!$nk){continue}
            if($dat.exact.ContainsKey($nk)){foreach($rec in $dat.exact[$nk]){$candidateByKey[[string]$rec.key]=$rec}}
        }
        $matchKind='exact'
        if(!$candidateByKey.Count){
            $tokenCandidates=@{}
            foreach($name in $names.ToArray()){
                $tk=Get-TitleTokenSignature $name;if(!$tk){continue}
                if($dat.token.ContainsKey($tk)){foreach($rec in $dat.token[$tk]){$tokenCandidates[[string]$rec.key]=$rec}}
            }
            # Sorted-token matching is useful for DAT naming order differences, but it is only
            # safe as an automatic inclusion rule when it points to ONE canonical DAT title.
            # Multiple canonical titles with the same token set are ambiguous and are skipped.
            if($tokenCandidates.Count -eq 1) {
                foreach($k in $tokenCandidates.Keys){$candidateByKey[$k]=$tokenCandidates[$k]}
                $matchKind='token'
            } elseif($tokenCandidates.Count -gt 1) {
                $ambiguousTokenSkipped++
                continue
            }
        }
        # This is the universal inclusion gate: no DAT match = no catalog row.
        if(!$candidateByKey.Count){continue}

        $datTitles=New-Object 'System.Collections.Generic.List[string]'
        $serials=New-Object 'System.Collections.Generic.List[string]'
        $matchedSources=New-Object 'System.Collections.Generic.List[string]'
        $matchedUrls=New-Object 'System.Collections.Generic.List[string]'
        $seenTitles=@{};$seenSerials=@{};$seenSources=@{};$seenUrls=@{};$variantCount=0
        foreach($rec in $candidateByKey.Values) {
            foreach($variant in $rec.variants) {
                $variantCount++
                $rt=[string]$variant.title;$rs=[string]$variant.serial;$sl='';$su=''
                try{$sl=[string]$variant.source}catch{};try{$su=[string]$variant.sourceUrl}catch{}
                if($rt -and !$seenTitles.ContainsKey($rt)){$seenTitles[$rt]=$true;[void]$datTitles.Add($rt)}
                if($rs -and !$seenSerials.ContainsKey($rs)){$seenSerials[$rs]=$true;[void]$serials.Add($rs)}
                if($sl -and !$seenSources.ContainsKey($sl)){$seenSources[$sl]=$true;[void]$matchedSources.Add($sl)}
                if($su -and !$seenUrls.ContainsKey($su)){$seenUrls[$su]=$true;[void]$matchedUrls.Add($su)}
            }
        }
        foreach($sl in $matchedSources.ToArray()) {if(!$sourceHitCounts.ContainsKey($sl)){$sourceHitCounts[$sl]=0};$sourceHitCounts[$sl]=[int]$sourceHitCounts[$sl]+1}

        $year=$null;try{if($row.first_release_date){$year=[DateTimeOffset]::FromUnixTimeSeconds([long]$row.first_release_date).Year}}catch{}
        $igdbUrl='https://www.igdb.com/';try{if($row.slug){$igdbUrl="https://www.igdb.com/games/$($row.slug)"}}catch{}
        $provider=($matchedSources.ToArray() -join ' + ');if([string]::IsNullOrWhiteSpace($provider)){$provider='Preservation DAT'}
        $entry=New-Entry $Platform $title 'IGDB + DAT intersection' ([string]$gid) $igdbUrl $year
        $entry.id="$Platform::IGDB::$gid";Set-Prop $entry 'igdbId' $gid
        Set-Prop $entry 'preservationDatUrl' ($matchedUrls.ToArray() -join ' | ')
        Set-Prop $entry 'preservationProvider' $provider
        Set-Prop $entry 'preservationMatchedSources' $matchedSources.ToArray()
        Set-Prop $entry 'preservationMatchedSourceUrls' $matchedUrls.ToArray()
        Set-Prop $entry 'preservationSourceCount' $matchedSources.Count
        Set-Prop $entry 'preservationMatch' $(if($matchKind -eq 'token'){'token-signature'}else{'exact-title-or-alias'})
        Set-Prop $entry 'preservationTitles' $datTitles.ToArray();Set-Prop $entry 'preservationSerials' $serials.ToArray();Set-Prop $entry 'preservationVariantCount' $variantCount
        try{Set-Prop $entry 'rating' ([double]$row.rating)}catch{};try{Set-Prop $entry 'ratingCount' ([long]$row.rating_count)}catch{}
        $gi=New-Object 'System.Collections.Generic.List[long]'
        try{foreach($gr in $row.genres){try{if($gr.id){[void]$gi.Add([long]$gr.id)}}catch{}}}catch{}
        Set-Prop $entry 'catalogGenreIds' $gi.ToArray()
        Set-Prop $entry 'catalogRule' 'IGDB AND (DAT1 OR DAT2 OR DAT3 ...): matched at least one configured preservation DAT'
        [void]$entries.Add($entry);if($matchKind -eq 'token'){$matchedToken++}else{$matchedExact++}
    }
    if(!$entries.Count){throw 'IGDB/ANY-DAT intersection was empty; existing catalog was left untouched.'}
    Replace-CatalogPlatform $Platform $entries.ToArray()
    $state=Read-State;$ps=Get-PlatformState $state $Platform;$ps.complete=$true
    $catalogMode='igdb-any-preservation-dat-v5'
    Set-Prop $ps 'source' 'IGDB + any configured preservation DAT'
    Set-Prop $ps 'catalogMode' $catalogMode
    Set-Prop $ps 'preservationSourceFingerprint' (Get-PreservationSourceFingerprint $Platform)
    Set-Prop $ps 'preservationSourceCount' ([int]$dat.sourceCount)
    $safeMapName=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    $mapStatePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeMapName)
    $savedMapState=Read-Json $mapStatePath $null
    $mapRevision=0L;try{$mapRevision=[long]$savedMapState.contentRevision}catch{}
    Set-Prop $ps 'igdbMapRevision' $mapRevision
    Set-Prop $ps 'igdbGames' $igdbRows.Count;Set-Prop $ps 'preservationTitles' $dat.records.Count;Set-Prop $ps 'intersectionGames' $entries.Count;Set-Prop $ps 'updatedAt' ((Get-Date).ToString('o'));Save-State $state
    Write-Host ("[{0}] ANY-DAT intersection complete: {1:N0} games (exact {2:N0}, unambiguous smart-title {3:N0})" -f $Platform,$entries.Count,$matchedExact,$matchedToken) -ForegroundColor Green
    if($ambiguousTokenSkipped -gt 0){Write-Host ("  skipped ambiguous smart-title matches: {0:N0}" -f $ambiguousTokenSkipped) -ForegroundColor Yellow}
    foreach($sourceName in @($sourceHitCounts.Keys | Sort-Object)) {Write-Host ("  matched via {0}: {1:N0} games" -f $sourceName,[int]$sourceHitCounts[$sourceName]) -ForegroundColor DarkGray}
    return $entries.Count
}


function Update-AllPreservationDats {
    Write-Host ''
    Write-Host 'Updating local preservation DAT library...' -ForegroundColor Cyan
    Write-Host ("Destination: {0}" -f $DatsRoot) -ForegroundColor DarkGray
    Write-Host 'This is the ONLY workflow that downloads preservation DATs.' -ForegroundColor Yellow
    Write-Host 'START WEBSITE.bat and BUILD CACHE ONLY.bat use DATs\ locally and never download preservation files.' -ForegroundColor DarkGray
    if($script:ForcePreservationRefresh) {
        Write-Host 'Mode: FORCE REFRESH every configured source.' -ForegroundColor Yellow
    } else {
        Write-Host ("Mode: resume/update missing or older-than-{0}-day files; recent successful DATs are reused." -f $script:PreservationRefreshDays) -ForegroundColor DarkGray
    }
    Write-Host ''

    $available=0;$failed=0;$downloaded=0;$skipped=0;$total=0
    $manifest=New-Object 'System.Collections.Generic.List[object]'
    foreach($platformName in $StaticCachePlatforms) {
        $cfg=Get-PlatformConfig $platformName
        $sources=@(Get-PreservationSourcesV4 $cfg $platformName)
        if(!$sources.Count){continue}
        Write-Host ("[{0}] updating {1} DAT source(s)..." -f $platformName,$sources.Count) -ForegroundColor Yellow
        $idx=0
        foreach($source in $sources) {
            $idx++;$total++
            $label=[string]$source.label;if([string]::IsNullOrWhiteSpace($label)){$label=("DAT source {0}" -f $idx)}
            Write-Host ("  source {0}/{1}: {2}" -f $idx,$sources.Count,$label) -ForegroundColor DarkGray
            $status='failed';$local='';$bytes=0L;$message=''
            try {
                $file=Get-PreservationSourceFileV4 $source $platformName $idx
                $local=[string]$file.path
                if(Test-Path -LiteralPath $local) {
                    $bytes=(Get-Item -LiteralPath $local).Length
                    $available++
                    $wasFresh=$false;$updateFailed=$false
                    try{$wasFresh=[bool]$file.skippedFresh}catch{}
                    try{$updateFailed=[bool]$file.updateFailed}catch{}
                    if($updateFailed) {
                        $status='kept-old-after-failed-refresh';$failed++
                        Write-Host ("      kept previous local DAT ({0:N0} bytes)" -f $bytes) -ForegroundColor Yellow
                    } elseif($wasFresh) {
                        $status='cached-fresh';$skipped++
                        Write-Host ("      local DAT already fresh ({0:N0} bytes)" -f $bytes) -ForegroundColor DarkGreen
                    } else {
                        $status='updated';$downloaded++
                        Write-Host ("      saved locally ({0:N0} bytes)" -f $bytes) -ForegroundColor Green
                    }
                } else {throw 'download did not create a local DAT file'}
            } catch {
                $failed++;$message=$_.Exception.Message
                Write-Warning ("[{0}] {1}: {2}" -f $platformName,$label,$message)
            }
            [void]$manifest.Add([pscustomobject]@{
                platform=$platformName;sourceIndex=$idx;label=$label;type=[string]$source.type;
                url=$(if([string]$source.type -eq 'redump'){"https://redump.info/datfile/$([string]$source.datCode)"}else{[string]$source.url});
                localPath=$local;bytes=$bytes;status=$status;message=$message;checkedAt=(Get-Date).ToString('o')
            })
            # Avoid bursting dozens of requests at a single host. This updater is
            # intentionally separate from website startup, so reliability wins.
            Start-Sleep -Milliseconds 1200
        }
    }
    try {
        $manifestPath=Join-Path $DatsRoot 'source-manifest.json'
        Write-JsonAtomic ([pscustomobject]@{updatedAt=(Get-Date).ToString('o');forceRefresh=[bool]$script:ForcePreservationRefresh;sources=$manifest.ToArray()}) $manifestPath
    } catch {}
    Write-Host ''
    Write-Host ("DAT update finished: {0}/{1} available | {2} downloaded/refreshed | {3} recent reused | {4} failed." -f $available,$total,$downloaded,$skipped,$failed) -ForegroundColor $(if($failed -eq 0){'Green'}else{'Yellow'})
    if($failed -gt 0) {
        Write-Host 'Run UPDATE DATS.bat again later: successful recent DATs will be skipped, so it resumes the missing/failed sources.' -ForegroundColor Yellow
        Write-Host 'Previously downloaded DATs were kept whenever an update failed.' -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ============================================================================
# LOGIC AUDIT v8: canonical static-platform IGDB discovery comes from games.platforms.
# release_dates is still used for platform-specific release-year metadata and as one
# incremental change signal, but it no longer defines whether a game belongs to a platform.
# This prevents valid IGDB platform games with incomplete release_dates rows from being lost
# before the ANY-DAT intersection is even attempted.
# ============================================================================
function Get-IgdbPlatformTitleMap([string]$Platform) {
    $platformId=Get-IgdbPlatformId $Platform
    if(!$platformId){ return @() }

    # Keep the historical filenames so existing tooling/state inspection still works, but mark
    # the discovery schema explicitly. The first v8 run performs one clean games.platforms scan.
    $safeName=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
    $mapPath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}.json" -f $safeName)
    $statePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeName)
    $desiredDiscoverySchema='games-platform-v2-no-erotic'

    $mapState=Read-Json $statePath ([pscustomobject]@{
        lastReleaseId=0;releaseRecords=0;lastGameId=0;gameRecords=0;complete=$false
        discoverySchema='';syncSchema='';lastReleaseSyncUnix=0;lastGameSyncUnix=0
        syncBaselineUnix=0;contentRevision=0
    })
    if($null -eq $mapState){$mapState=[pscustomobject]@{lastReleaseId=0;releaseRecords=0;lastGameId=0;gameRecords=0;complete=$false;discoverySchema='';syncSchema='';lastReleaseSyncUnix=0;lastGameSyncUnix=0;syncBaselineUnix=0;contentRevision=0}}
    foreach($prop in @('lastReleaseId','releaseRecords','lastGameId','gameRecords','complete','discoverySchema','syncSchema','lastReleaseSyncUnix','lastGameSyncUnix','syncBaselineUnix','contentRevision')) {
        if($null -eq $mapState.PSObject.Properties[$prop]) {
            switch($prop) {
                'complete' { Set-Prop $mapState $prop $false }
                'discoverySchema' { Set-Prop $mapState $prop '' }
                'syncSchema' { Set-Prop $mapState $prop '' }
                default { Set-Prop $mapState $prop 0 }
            }
        }
    }

    $currentDiscovery='';try{$currentDiscovery=[string]$mapState.discoverySchema}catch{}
    if($currentDiscovery -ne $desiredDiscoverySchema) {
        Write-Host ("[{0}] migrating IGDB platform discovery: release_dates -> games.platforms (one-time full scan)..." -f $Platform) -ForegroundColor Yellow
        Set-Prop $mapState 'lastReleaseId' 0
        Set-Prop $mapState 'releaseRecords' 0
        Set-Prop $mapState 'lastGameId' 0
        Set-Prop $mapState 'gameRecords' 0
        Set-Prop $mapState 'complete' $false
        Set-Prop $mapState 'discoverySchema' $desiredDiscoverySchema
        Set-Prop $mapState 'syncSchema' 'updated-at-v1'
        Set-Prop $mapState 'lastReleaseSyncUnix' 0
        Set-Prop $mapState 'lastGameSyncUnix' 0
        Set-Prop $mapState 'syncBaselineUnix' ([DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds())
        $revision=0L;try{$revision=[long]$mapState.contentRevision}catch{}
        Set-Prop $mapState 'contentRevision' ($revision+1)
        try{Remove-Item -LiteralPath $mapPath -Force -ErrorAction SilentlyContinue}catch{}
        Write-JsonAtomic $mapState $statePath
        try{[void]$script:IgdbIncrementalProbeResults.Remove((State-Key $Platform))}catch{}
    }

    $cached=@((Read-Json $mapPath @()) | ForEach-Object { $_ })
    $allById=@{}
    foreach($row in $cached){
        if($null -eq $row){continue}
        try{$gid=[long]$row.id;if($gid -gt 0){$allById[[string]$gid]=$row}}catch{}
    }

    if([bool]$mapState.complete -and $allById.Count -gt 0) {
        $needsRefresh=Test-IgdbPlatformMapIncrementalV6 $Platform
        if(!$needsRefresh) {
            Write-Host ("[{0}] IGDB games.platforms map complete: {1:N0} unique games" -f $Platform,$allById.Count) -ForegroundColor DarkGray
            return @($allById.Values | Sort-Object {[long]$_.id})
        }
        $probe=$null;$probeKey=State-Key $Platform
        if($script:IgdbIncrementalProbeResults.ContainsKey($probeKey)){$probe=$script:IgdbIncrementalProbeResults[$probeKey]}
        $mode='';try{$mode=[string]$probe.mode}catch{}
        if($mode -eq 'incremental') {
            $changed=0;$removed=0
            # A release-date update can carry refreshed embedded game fields, but platform
            # membership is always re-checked against game.platforms before accepting it.
            foreach($rd in @($probe.releaseRows)) {
                $g=$null;try{$g=$rd.game}catch{}
                if($null -eq $g){continue}
                $gid=0L;try{$gid=[long]$g.id}catch{}
                if($gid -le 0){continue}
                if(Test-IgdbGameHasPlatformV6 $g $platformId) {
                    if(-not [string]::IsNullOrWhiteSpace([string]$g.name)){$allById[[string]$gid]=$g;$changed++}
                } elseif($allById.ContainsKey([string]$gid)) {$allById.Remove([string]$gid);$removed++}
            }
            foreach($g in @($probe.gameRows)) {
                if($null -eq $g){continue}
                $gid=0L;try{$gid=[long]$g.id}catch{}
                if($gid -le 0){continue}
                if(Test-IgdbGameHasPlatformV6 $g $platformId) {
                    if(-not [string]::IsNullOrWhiteSpace([string]$g.name)){$allById[[string]$gid]=$g;$changed++}
                } elseif($allById.ContainsKey([string]$gid)) {$allById.Remove([string]$gid);$removed++}
            }
            $cutoff=[long]$probe.cutoffUnix
            Set-Prop $mapState 'lastReleaseSyncUnix' $cutoff
            Set-Prop $mapState 'lastGameSyncUnix' $cutoff
            Set-Prop $mapState 'syncSchema' 'updated-at-v1'
            Set-Prop $mapState 'discoverySchema' $desiredDiscoverySchema
            Set-Prop $mapState 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
            Set-Prop $mapState 'complete' $true
            $revision=0L;try{$revision=[long]$mapState.contentRevision}catch{}
            Set-Prop $mapState 'contentRevision' ($revision+1)
            $final=@($allById.Values | Sort-Object {[long]$_.id})
            Write-JsonAtomic $final $mapPath;Write-JsonAtomic $mapState $statePath
            Write-Host ("[{0}] IGDB incremental games.platforms map applied: {1:N0} games ({2:N0} changed/additions, {3:N0} removals)." -f $Platform,$final.Count,$changed,$removed) -ForegroundColor Green
            return $final
        }
        if($mode -eq 'full') {
            $allById=@{}
            Set-Prop $mapState 'lastGameId' 0;Set-Prop $mapState 'gameRecords' 0;Set-Prop $mapState 'complete' $false
            Set-Prop $mapState 'syncBaselineUnix' ([DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds())
            try{Remove-Item -LiteralPath $mapPath -Force -ErrorAction SilentlyContinue}catch{}
            Write-JsonAtomic $mapState $statePath
        }
    }

    $lastGameId=0L;$processed=0L
    try{$lastGameId=[long]$mapState.lastGameId}catch{}
    try{$processed=[long]$mapState.gameRecords}catch{}
    $syncBaseline=0L;try{$syncBaseline=[long]$mapState.syncBaselineUnix}catch{}
    if($syncBaseline -le 0){$syncBaseline=[DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds();Set-Prop $mapState 'syncBaselineUnix' $syncBaseline;Write-JsonAtomic $mapState $statePath}

    if($allById.Count -gt 0 -or $lastGameId -gt 0){
        Write-Host ("[{0}] resuming IGDB games.platforms map: {1:N0} unique games, {2:N0} game rows processed..." -f $Platform,$allById.Count,$processed) -ForegroundColor Yellow
    } else {
        Write-Host ("[{0}] building IGDB games.platforms map..." -f $Platform) -ForegroundColor DarkCyan
    }

    while($true) {
        $body="fields id,name,slug,first_release_date,alternative_names.name,genres.id,rating,rating_count,platforms,themes,updated_at; where platforms = ($platformId) & themes != (42) & id > $lastGameId; sort id asc; limit 500;"
        $rows=@(Invoke-IgdbEndpoint 'games' $body)
        if(!$rows.Count){Set-Prop $mapState 'complete' $true;break}
        $maxGameId=$lastGameId
        foreach($g in $rows){
            if($null -eq $g){continue}
            $gid=0L;try{$gid=[long]$g.id}catch{}
            if($gid -gt $maxGameId){$maxGameId=$gid}
            if($gid -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$g.name)){$allById[[string]$gid]=$g}
        }
        if($maxGameId -le $lastGameId){Set-Prop $mapState 'complete' $true;break}
        $lastGameId=$maxGameId;$processed += $rows.Count
        Set-Prop $mapState 'lastGameId' $lastGameId;Set-Prop $mapState 'gameRecords' $processed
        $arr=@($allById.Values | Sort-Object {[long]$_.id})
        Write-JsonAtomic $arr $mapPath;Write-JsonAtomic $mapState $statePath
        Write-Host ("  [{0}] IGDB games: {1:N0} rows -> {2:N0} unique platform games" -f $Platform,$processed,$arr.Count) -ForegroundColor DarkGray
        if($rows.Count -lt 500){Set-Prop $mapState 'complete' $true;break}
    }

    $final=@($allById.Values | Sort-Object {[long]$_.id})
    if($final.Count -gt 0){Write-JsonAtomic $final $mapPath}
    if([bool]$mapState.complete) {
        $baseline=0L;try{$baseline=[long]$mapState.syncBaselineUnix}catch{}
        if($baseline -le 0){$baseline=[DateTimeOffset]::UtcNow.AddSeconds(-5).ToUnixTimeSeconds()}
        Set-Prop $mapState 'discoverySchema' $desiredDiscoverySchema
        Set-Prop $mapState 'syncSchema' 'updated-at-v1'
        Set-Prop $mapState 'lastReleaseSyncUnix' $baseline
        Set-Prop $mapState 'lastGameSyncUnix' $baseline
        Set-Prop $mapState 'syncBaselineUnix' 0
        Set-Prop $mapState 'lastIncrementalCheckAt' ((Get-Date).ToUniversalTime().ToString('o'))
        $revision=0L;try{$revision=[long]$mapState.contentRevision}catch{}
        Set-Prop $mapState 'contentRevision' ($revision+1)
        Write-JsonAtomic $mapState $statePath
        $script:IgdbIncrementalProbeResults[(State-Key $Platform)]=[pscustomobject]@{needsRefresh=$false;mode='none';cutoffUnix=$baseline}
        Write-Host ("[{0}] IGDB games.platforms map complete: {1:N0} unique games" -f $Platform,$final.Count) -ForegroundColor Green
    } else {
        Write-JsonAtomic $mapState $statePath
        Write-Warning ("[{0}] IGDB games.platforms map paused at {1:N0} unique games; it will resume next run." -f $Platform,$final.Count)
    }
    return $final
}

function Build-StaticCatalogCache {
    $defaultRequiredMode='igdb-any-preservation-dat-v5'
    Write-Host ''
    Write-Host 'Building IGDB + ANY-DAT console catalogs before website launch...' -ForegroundColor Cyan
    Write-Host 'Catalog rule: IGDB AND (DAT1 OR DAT2 OR DAT3 ...). A match in ANY configured DAT includes the game.' -ForegroundColor Yellow
    Write-Host 'Each system may union Redump, No-Intro physical/digital, GameTDB/Libretro, PSN or other configured DATs.' -ForegroundColor DarkGray
    Write-Host 'IGDB-only and Steam platforms remain live/on-demand and are not part of this static package.' -ForegroundColor DarkGray

    # One global updated_at delta is shared by every completed DAT-backed platform.
    # This avoids repeating the same IGDB change scan dozens of times.
    [void](Initialize-IgdbUpdatedAtChangeCacheV6)

    $failedPlatforms=New-Object 'System.Collections.Generic.List[string]'
    foreach($platformName in $StaticCachePlatforms) {
        $cfg=Get-PlatformConfig $platformName
        $requiredMode=$defaultRequiredMode
        try{if($cfg.PSObject.Properties['catalogMode'] -and $cfg.catalogMode){$requiredMode=[string]$cfg.catalogMode}}catch{}
        try {
            $st=Read-State
            $pst=Get-PlatformState $st $platformName
            $count=@(Get-CatalogPlatform @(Read-Catalog) $platformName).Count
            $mode=''
            try { if($pst.PSObject.Properties['catalogMode']){$mode=[string]$pst.catalogMode} } catch {}

            $expectedFingerprint=Get-PreservationSourceFingerprint $platformName
            $savedFingerprint='';try{if($pst.PSObject.Properties['preservationSourceFingerprint']){$savedFingerprint=[string]$pst.preservationSourceFingerprint}}catch{}
            $igdbNeedsRefresh=Test-IgdbPlatformMapIncrementalV6 $platformName
            $safeMapName=($platformName.ToLowerInvariant() -replace '[^a-z0-9]+','-').Trim('-')
            $mapStatePath=Join-Path $CacheRoot ("igdb-platform-release-map-v2-{0}-state.json" -f $safeMapName)
            $currentMapState=Read-Json $mapStatePath $null
            $currentMapRevision=0L;$catalogMapRevision=0L
            try{$currentMapRevision=[long]$currentMapState.contentRevision}catch{}
            try{if($pst.PSObject.Properties['igdbMapRevision']){$catalogMapRevision=[long]$pst.igdbMapRevision}}catch{}
            $igdbCatalogOutOfSync=($currentMapRevision -gt 0 -and $catalogMapRevision -ne $currentMapRevision)
            $discoverySchema='';try{$discoverySchema=[string]$currentMapState.discoverySchema}catch{}
            $discoveryNeedsMigration=($discoverySchema -ne 'games-platform-v2-no-erotic')
            if($pst.complete -and !$discoveryNeedsMigration -and !$igdbNeedsRefresh -and !$igdbCatalogOutOfSync -and $count -gt 0 -and $mode -eq $requiredMode -and $savedFingerprint -eq $expectedFingerprint) {
                Write-Host ("[{0}] ANY-DAT intersection cache already complete: {1:N0} games" -f $platformName,$count) -ForegroundColor Green
            } else {
                $provider=''
                try{if($cfg.PSObject.Properties['providerLabel']){$provider=[string]$cfg.providerLabel}}catch{}
                if([string]::IsNullOrWhiteSpace($provider)){$provider=$(if([string]$cfg.mode -eq 'redump'){'Redump'}else{'No-Intro DAT mirror'})}
                Write-Host ("[{0}] building IGDB + ANY configured DAT intersection..." -f $platformName) -ForegroundColor Yellow
                $count=Build-IgdbPreservationIntersectionCatalog $platformName
            }

            # Genre/year/rating are deliberately lightweight catalog fields. They
            # let global filters and sorting run BEFORE page slicing without waiting
            # for the heavier screenshot/video enrichment cache.
            Ensure-StaticCatalogBasicMetadata $platformName
            # Persist the finalized catalog row set (including genre/rating and
            # Daily Priority flags) into the small per-platform browse file.
            [void](Write-PlatformCatalogCache $platformName (Get-CatalogPlatform @(Read-Catalog) $platformName))
        } catch {
            [void]$failedPlatforms.Add($platformName)
            Write-Warning ("[{0}] catalog build/update failed: {1}" -f $platformName,$_.Exception.Message)
            $existing=@(Get-CatalogPlatform @(Read-Catalog) $platformName).Count
            if($existing -gt 0){Write-Host ("[{0}] existing cache kept on disk: {1:N0} games (NOT packaged as a successful refresh)" -f $platformName,$existing) -ForegroundColor Yellow}
        }
    }

    # Daily Chunk selection/building is intentionally separate in V48.16+.
    # BUILD DATABASE never prepares/fills Daily Chunk priority rows.

    if($failedPlatforms.Count -gt 0) {
        $names=($failedPlatforms.ToArray() -join ', ')
        Write-Host ''
        Write-Host ("CATALOG REFRESH FAILED: {0}/{1} DAT-backed platform(s) failed." -f $failedPlatforms.Count,$StaticCachePlatforms.Count) -ForegroundColor Red
        Write-Host ("Failed: {0}" -f $names) -ForegroundColor Red
        Write-Host 'Existing caches were preserved, but GameBrowser-Data.zip will NOT be repackaged from a mixed-age refresh.' -ForegroundColor Yellow
        throw ("Static catalog refresh incomplete: {0}" -f $names)
    }
    Write-Host ("Catalog prebuild finished: {0}/{0} DAT-backed platforms validated." -f $StaticCachePlatforms.Count) -ForegroundColor Green
    Write-Host ''
}

if($UpdatePreservationDats -or $ForceDatRefresh) {
    Update-AllPreservationDats
    exit 0
}

if($BuildPlatformBrowseCache) {
    Build-PlatformBrowseCaches
    exit 0
}

if($BuildStaticCache) {
    Build-StaticCatalogCache
    exit 0
}

$listener=$null;$Port=$PreferredPort
for($p=$PreferredPort;$p -le $PreferredPort+50;$p++) {
    try{$test=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$p);$test.Start();$listener=$test;$Port=$p;break}
    catch{try{$test.Stop()}catch{}}
}
if($null -eq $listener){throw 'No free local port found.'}
$url="http://127.0.0.1:$Port/index.html"
Write-Host 'Daily Chunk Games - Local Cache + IGDB On-Demand'
Write-Host "URL: $url"
Write-Host 'DAT-backed platforms use prebuilt IGDB + ANY-DAT intersections; IGDB-only platforms stay on-demand.'
if($FastStart) {
    Write-Host 'Fast start: skipping startup catalog/system checks and index pre-warm.' -ForegroundColor Green
} else {
    Write-Host 'Warming local catalog + Daily Chunk indexes...' -ForegroundColor DarkGray
    [void](Read-Catalog)
    [void](Get-ChunkIndexes)
    foreach($warmPlatform in $Platforms){ [void](Get-CatalogPlatform @(Read-Catalog) $warmPlatform) }
    Write-Host 'Local indexes ready.' -ForegroundColor Green
}
if($OpenBrowser){Start-Sleep -Milliseconds 150;Start-Process $url}

try {
    while($true) {
        $client=$listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout=15000
            $stream=$client.GetStream()
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$false,16384,$true)
            $requestLine=$reader.ReadLine()
            if([string]::IsNullOrWhiteSpace($requestLine)){continue}
            $headers=@{}
            while($true) {
                $line=$reader.ReadLine()
                if([string]::IsNullOrEmpty($line)){break}
                $idx=$line.IndexOf(':')
                if($idx -gt 0){$headers[$line.Substring(0,$idx).Trim().ToLowerInvariant()]=$line.Substring($idx+1).Trim()}
            }
            $parts=$requestLine.Split(' ')
            if($parts.Count -lt 2){continue}
            $method=$parts[0].ToUpperInvariant()
            $target=$parts[1]
            $path=$target.Split('?')[0]
            $query=Parse-Query $target
            $bodyText=''
            $contentLength=0
            if($headers.ContainsKey('content-length')){[void][int]::TryParse($headers['content-length'],[ref]$contentLength)}
            if($contentLength -gt 0){$bodyText=Get-BodyText $reader $contentLength}

            if($path -eq '/api/platforms' -and $method -eq 'GET') {
                # Keep this endpoint lightweight.  The UI needs the cached-game
                # count for static/DAT-backed platforms, but calculating /api/stats
                # scans the full catalog and can block the first Load More request.
                # The intersection builder already persists its final count in
                # source-state.json as intersectionGames, so use that instead.
                $rows=New-Object 'System.Collections.Generic.List[object]'
                $platformState=Read-State
                foreach($cfg in $PlatformConfigs) {
                    $isStatic=([string]$cfg.mode -in $DatBackedModes)
                    $cachedCount=0
                    $isComplete=$false
                    if($isStatic) {
                        try {
                            $pst=Get-PlatformState $platformState ([string]$cfg.name)
                            $isComplete=[bool]$pst.complete
                            if($pst.PSObject.Properties['intersectionGames']) {
                                $cachedCount=[int]$pst.intersectionGames
                            }
                        } catch {}
                    }
                    [void]$rows.Add([pscustomobject]@{
                        name=[string]$cfg.name
                        mode=[string]$cfg.mode
                        static=$isStatic
                        cached=$cachedCount
                        complete=$isComplete
                        controllerIndex=([bool]($cfg.PSObject.Properties['controllerIndex'] -and $cfg.controllerIndex))
                    })
                }
                Send-Json $stream 200 ([pscustomobject]@{items=$rows.ToArray()})
                continue
            }

            if($path -eq '/api/genres' -and $method -eq 'GET') {
                try { Send-Json $stream 200 ([pscustomobject]@{items=@(Get-IgdbGenres)}) }
                catch { Send-Json $stream 500 ([pscustomobject]@{error=$_.Exception.Message}) }
                continue
            }

            if($path -eq '/api/catalog-page' -and $method -eq 'GET') {
                try {
                    $platform=[string]$query['platform']
                    $offset=0;$limit=50
                    [void][int]::TryParse([string]$query['offset'],[ref]$offset)
                    [void][int]::TryParse([string]$query['limit'],[ref]$limit)
                    $q=[string]$query['q']
                    $genreId=0L;[void][long]::TryParse([string]$query['genreId'],[ref]$genreId)
                    $sort=[string]$query['sort']
                    $controller=[string]$query['controller']
                    $daily=[string]$query['daily']
                    $result=Get-CatalogPageV2 $platform $offset $limit $q $genreId $sort $controller $daily
                    Send-Json $stream 200 $result
                } catch {
                    Send-Json $stream 500 ([pscustomobject]@{error=$_.Exception.Message})
                }
                continue
            }

            if($path -eq '/api/stats' -and $method -eq 'GET') {
                Send-Json $stream 200 (Get-Stats)
                continue
            }

            if($path -eq '/api/chunks' -and $method -eq 'POST') {
                $payload=$bodyText|ConvertFrom-Json
                $chunkIndex=Get-ChunkIndexes
                $exact=$chunkIndex.exact
                $normalized=$chunkIndex.normalized

                $result=@{}
                foreach($g in @($payload.games)) {
                    if($null -eq $g){continue}
                    $currentId=[string]$g.id
                    if($exact.ContainsKey($currentId)) {
                        $result[$currentId]=$exact[$currentId]
                        continue
                    }
                    $nk=([string]$g.platform)+'|'+(Normalize-Name ([string]$g.title))
                    if($normalized.ContainsKey($nk)) {$result[$currentId]=$normalized[$nk]}
                }
                foreach($id in @($payload.ids)) {
                    $key=[string]$id
                    if($exact.ContainsKey($key)){$result[$key]=$exact[$key]}
                }
                Send-Json $stream 200 ([pscustomobject]@{items=$result})
                continue
            }
            if($path -eq '/api/controllers' -and $method -eq 'POST') {
                $payload=$bodyText|ConvertFrom-Json
                $ids=@($payload.ids|Select-Object -First 100)

                $catalog=@(Read-Catalog)
                $byId=@{}
                foreach($g in $catalog){$byId[[string]$g.id]=$g}

                $cache=Object-ToHashtable (Read-Json $MetadataPath ([pscustomobject]@{}))
                $need=New-Object 'System.Collections.Generic.List[object]'
                $result=@{}

                foreach($id in $ids) {
                    $key=[string]$id
                    if(!$byId.ContainsKey($key)){continue}
                    $g=$byId[$key]
                    if([string]$g.platform -ne 'Windows'){continue}

                    if($cache.ContainsKey($key) -and $cache[$key].PSObject.Properties['controllerCategory']) {
                        $m=$cache[$key]
                        $result[$key]=[pscustomobject]@{
                            controllerCategory=[string]$m.controllerCategory
                            controllerSupport=[string]$m.controllerSupport
                            fullControllerSupport=[string]$m.fullControllerSupport
                            controllerSource=[string]$m.controllerSource
                        }
                    } else {
                        [void]$need.Add($g)
                    }
                }

                if($need.Count) {
                    try {
                        $batch=Get-PcgwControllerBatch $need
                        foreach($entry in $batch.GetEnumerator()) {
                            $key=[string]$entry.Key
                            $ci=$entry.Value

                            if($cache.ContainsKey($key)) {
                                $m=$cache[$key]
                            } else {
                                $m=[pscustomobject]@{
                                    status='controller-only'
                                    fetchedAt=(Get-Date).ToString('o')
                                }
                            }

                            Set-Prop $m 'controllerCategory' ([string]$ci.controllerCategory)
                            Set-Prop $m 'controllerSupport' ([string]$ci.controllerSupport)
                            Set-Prop $m 'fullControllerSupport' ([string]$ci.fullControllerSupport)
                            Set-Prop $m 'controllerSource' ([string]$ci.controllerSource)

                            $cache[$key]=$m
                            $result[$key]=$ci
                        }
                        Write-JsonAtomic $cache $MetadataPath
                    } catch {
                        # Controller metadata is optional; do not break the game list.
                    }
                }

                Send-Json $stream 200 ([pscustomobject]@{
                    items=$result
                    metadataCount=$cache.Count
                })
                continue
            }

            if($path -eq '/api/enrich' -and $method -eq 'POST') {
                # Fallback for a failed/missing page metadata result or a gallery
                # opened later. IGDB metadata is returned directly and is NOT
                # persisted to metadata-cache.json.
                $payload=$bodyText|ConvertFrom-Json
                $ids=@($payload.ids|Select-Object -First 100)
                $byId=@{}
                foreach($g in @($payload.games | Select-Object -First 100)){if($g -and $g.id){$byId[[string]$g.id]=$g}}
                # The browser sends the visible game's id/igdbId directly. Only
                # fall back to catalog.json for older callers that supplied ids alone.
                $missingIds=@($ids | Where-Object {!$byId.ContainsKey([string]$_)})
                $catalog=@()
                if($missingIds.Count){$catalog=@(Read-Catalog);foreach($g in $catalog){$key=[string]$g.id;if($missingIds -contains $key){$byId[$key]=$g}}}
                $result=@{}
                $exactGames=New-Object 'System.Collections.Generic.List[object]'
                $fallbackGames=New-Object 'System.Collections.Generic.List[object]'
                foreach($id in $ids){
                    $key=[string]$id;if(!$byId.ContainsKey($key)){continue};$game=$byId[$key]
                    $hasExact=$false;try{if($game.igdbId){$hasExact=$true}}catch{}
                    if($hasExact){[void]$exactGames.Add($game)}else{[void]$fallbackGames.Add($game)}
                }
                if($exactGames.Count){
                    try{$batch=Get-IgdbMetadataBatch $exactGames.ToArray();foreach($kv in $batch.GetEnumerator()){$result[[string]$kv.Key]=$kv.Value}}
                    catch{foreach($g in $exactGames){$result[[string]$g.id]=[pscustomobject]@{status='error';message=$_.Exception.Message;fetchedAt=(Get-Date).ToString('o')}}}
                }
                $catalogChanged=$false
                if($fallbackGames.Count){
                    try{
                        $batch=Get-IgdbMetadataSearchBatch $fallbackGames.ToArray()
                        foreach($g in $fallbackGames){try{if($g.igdbId){$catalogChanged=$true}}catch{}}
                        foreach($kv in $batch.GetEnumerator()){$result[[string]$kv.Key]=$kv.Value}
                    }catch{foreach($g in $fallbackGames){$result[[string]$g.id]=[pscustomobject]@{status='error';message=$_.Exception.Message;fetchedAt=(Get-Date).ToString('o')}}}
                }
                if($catalogChanged -and $catalog.Count){Save-Catalog $catalog}
                Send-Json $stream 200 ([pscustomobject]@{items=$result;metadataCount=0})
                continue
            }


            if($path -eq '/api/save-chunk' -and $method -eq 'POST') {
                $payload=$bodyText|ConvertFrom-Json
                if([string]::IsNullOrWhiteSpace([string]$payload.id)){Send-Json $stream 400 ([pscustomobject]@{error='Missing id'});continue}
                [void](Get-ChunkIndexes)
                $chunks=@($script:ChunksMemory | ForEach-Object { $_ })
                $found=$false
                $payloadKey=([string]$payload.platform)+'|'+(Normalize-Name ([string]$payload.title))
                foreach($c in $chunks) {
                    $sameId=([string]$c.id -eq [string]$payload.id)
                    $sameTitle=((([string]$c.platform)+'|'+(Normalize-Name ([string]$c.title))) -eq $payloadKey)
                    if($sameId -or $sameTitle) {
                        Set-Prop $c 'platform' ([string]$payload.platform)
                        Set-Prop $c 'title' ([string]$payload.title)
                        Set-Prop $c 'dailyChunk' ([string]$payload.dailyChunk)
                        Set-Prop $c 'chunkability' ([int]$payload.chunkability)
                        Set-Prop $c 'minutes' ([int]$payload.minutes)
                        $found=$true;break
                    }
                }
                if(!$found) {
                    $chunks += [pscustomobject]@{
                        id=[string]$payload.id;platform=[string]$payload.platform;title=[string]$payload.title;
                        dailyChunk=[string]$payload.dailyChunk;minutes=[int]$payload.minutes;intensity=2;
                        chunkability=[int]$payload.chunkability;why=''
                    }
                }
                Write-JsonAtomic @($chunks) $ChunksPath
                Reset-ChunkMemory
                [void](Get-ChunkIndexes)
                Send-Json $stream 200 ([pscustomobject]@{ok=$true})
                continue
            }

            if($path -eq '/api/reset-catalog' -and $method -eq 'POST') {
                Write-JsonAtomic @() $CatalogPath
                $script:CatalogMemory=@()
                $script:CatalogPlatformMemory=@{}
                Write-JsonAtomic ([pscustomobject]@{}) $SourceStatePath
                Send-Json $stream 200 ([pscustomobject]@{ok=$true})
                continue
            }

            if($method -ne 'GET'){Send-Response $stream 405 'Method Not Allowed' ([Text.Encoding]::UTF8.GetBytes('Method not allowed'));continue}
            $decoded=[uri]::UnescapeDataString($path)
            if($decoded -eq '/' -or !$decoded){$decoded='/index.html'}
            $relative=$decoded.TrimStart('/').Replace('/',[IO.Path]::DirectorySeparatorChar)
            $candidate=[IO.Path]::GetFullPath((Join-Path $Root $relative))
            if(!$candidate.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)){Send-Response $stream 403 'Forbidden' ([Text.Encoding]::UTF8.GetBytes('Forbidden'));continue}
            if(!(Test-Path -LiteralPath $candidate -PathType Leaf)){Send-Response $stream 404 'Not Found' ([Text.Encoding]::UTF8.GetBytes('Not found'));continue}
            Send-Response $stream 200 'OK' ([IO.File]::ReadAllBytes($candidate)) (Get-ContentType $candidate)
        } catch {
            try{Send-Json $stream 500 ([pscustomobject]@{error=$_.Exception.Message})}catch{}
        } finally { try{$client.Close()}catch{} }
    }
} finally { try{$listener.Stop()}catch{} }
