param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$ChunksPath = Join-Path $Root 'daily-chunks.json'
$SeriesPath = Join-Path $Root 'daily-chunk-series.json'
$GameSpecificPath = Join-Path $Root 'daily-chunk-game-specific.json'
$FeaturedCuratedPath = Join-Path $Root 'featured-games-curated.json'
$PlatformsPath = Join-Path $Root 'platforms.json'
$IgdbConfigPath = Join-Path $Root 'igdb-config.json'
$SteamConfigPath = Join-Path $Root 'steam-config.json'
$CacheRoot = Join-Path $Root '_cache'
$CatalogRoot = Join-Path $CacheRoot 'platform-catalogs'
$WindowsSteamLegacyCachePath = Join-Path $CacheRoot 'daily-chunk-windows-steam-v1.json'
$WindowsSteamCachePath = Join-Path $CacheRoot 'daily-chunk-windows-steam-v2.json'
$SteamTitleIndexPath = Join-Path $CacheRoot 'steam-game-title-index-v1.json'
$OutRoot = Join-Path $Root '_android'
$ChunksOut = Join-Path $OutRoot 'daily_chunks.json'
$SeriesOut = Join-Path $OutRoot 'daily_chunk_series.json'
$IndexOut = Join-Path $OutRoot 'daily_chunk_index.json'
$FeaturedOut = Join-Path $OutRoot 'featured_game_index.json'
$ManifestOut = Join-Path $OutRoot 'daily_chunks_manifest.json'
$ZipOut = Join-Path $OutRoot 'GameBrowser-DailyChunks.zip'
$HashOut = Join-Path $OutRoot 'GameBrowser-DailyChunks.sha256'
$FeaturedManifestOut = Join-Path $OutRoot 'featured_manifest.json'
$FeaturedZipOut = Join-Path $OutRoot 'GameBrowser-Featured.zip'
$FeaturedHashOut = Join-Path $OutRoot 'GameBrowser-Featured.sha256'

if(!(Test-Path -LiteralPath $ChunksPath)){ throw "daily-chunks.json not found: $ChunksPath" }
if(!(Test-Path -LiteralPath $SeriesPath)){ throw "daily-chunk-series.json not found: $SeriesPath" }
if(!(Test-Path -LiteralPath $GameSpecificPath)){ throw "daily-chunk-game-specific.json not found: $GameSpecificPath" }
if(!(Test-Path -LiteralPath $FeaturedCuratedPath)){ throw "featured-games-curated.json not found: $FeaturedCuratedPath" }
if(!(Test-Path -LiteralPath $PlatformsPath)){ throw "platforms.json not found: $PlatformsPath" }
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
New-Item -ItemType Directory -Force -Path $CacheRoot | Out-Null

function State-Key([string]$Platform) {
    $k=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','_').Trim('_')
    if([string]::IsNullOrWhiteSpace($k)){ throw "Invalid platform name: $Platform" }
    return $k
}
function Norm([string]$Value) {
    if([string]::IsNullOrWhiteSpace($Value)){ return '' }
    $text=[Net.WebUtility]::HtmlDecode($Value).Normalize([Text.NormalizationForm]::FormD)
    $sb=New-Object Text.StringBuilder
    foreach($ch in $text.ToCharArray()){
        if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark){ [void]$sb.Append($ch) }
    }
    $text=$sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $text=$text -replace '[™®©]',''
    return (($text -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' ')
}
function Get-Prop($Object,[string]$Name,$Default=$null) {
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Array-Of($Value) {
    if($null -eq $Value){ return @() }
    return @($Value | ForEach-Object { $_ })
}
function To-Long($Value) { try { return [long]$Value } catch { return 0L } }
function To-Int($Value) { try { return [int]$Value } catch { return 0 } }
function To-Double($Value) { try { return [double]$Value } catch { return 0.0 } }
function Extract-IgdbId($Row) {
    $v=To-Long (Get-Prop $Row 'igdbId' 0)
    if($v -gt 0){ return $v }
    $id=[string](Get-Prop $Row 'id' '')
    if($id -match '::IGDB::(\d+)$'){ return [long]$Matches[1] }
    return 0L
}
function Get-ControllerClass($Data) {
    if($null -eq $Data){ return '' }
    $ids=@()
    foreach($c in @(Get-Prop $Data 'categories' @())){
        try { $ids += [int]$c.id } catch {}
    }
    $raw=([string](Get-Prop $Data 'controller_support' '')).Trim().ToLowerInvariant()
    if($ids -contains 28 -or $raw -eq 'full'){ return 'Full Controller Support' }
    if($ids -contains 18 -or $raw -eq 'partial'){ return 'Partial Controller Support' }
    return ''
}
function Normalize-ControllerClass([string]$Value) {
    if($Value -eq 'Full Controller Support'){ return $Value }
    if($Value -eq 'Partial Controller Support'){ return $Value }
    return ''
}

function Find-SeriesDailyChunk([string]$Title) {
    $tn=Norm $Title
    if(!$tn){ return $null }
    $best=$null
    $bestLen=0
    foreach($rule in @($series)){
        foreach($pattern in @(Array-Of (Get-Prop $rule 'patterns' @()))){
            $pn=Norm ([string]$pattern)
            if(!$pn){ continue }
            # Normalized word-boundary-ish matching. Prefer the longest matching franchise pattern.
            $hay=' '+$tn+' '
            $needle=' '+$pn+' '
            if($hay.Contains($needle)){
                if($pn.Length -gt $bestLen){ $best=$rule; $bestLen=$pn.Length }
            }
        }
    }
    return $best
}

function Resolve-DailyChunkDefinition([string]$Platform,[string]$Title,$Row) {
    $candidateTitles=New-Object 'System.Collections.Generic.List[string]'
    if($Title){ [void]$candidateTitles.Add($Title) }
    $curatedTitle=[string](Get-Prop $Row 'curatedTitle' '')
    if($curatedTitle -and $curatedTitle -ne $Title){ [void]$candidateTitles.Add($curatedTitle) }

    # PRIORITY 1: exact per-game curated rule.
    foreach($ct in $candidateTitles){
        $k=$Platform.ToLowerInvariant()+'::'+(Norm $ct)
        if($gameSpecificLookup.ContainsKey($k)){
            $x=$gameSpecificLookup[$k]
            return [pscustomobject]@{
                dailyChunk=[string](Get-Prop $x 'dailyChunk' '')
                minutes=To-Int (Get-Prop $x 'minutes' 30)
                chunkability=To-Int (Get-Prop $x 'chunkability' 5)
                chunkSource='game-specific'
                chunkRule=[string](Get-Prop $x 'title' $ct)
            }
        }
    }

    # PRIORITY 2: franchise/series rule.
    foreach($ct in $candidateTitles){
        $r=Find-SeriesDailyChunk $ct
        if($null -ne $r){
            return [pscustomobject]@{
                dailyChunk=[string](Get-Prop $r 'dailyChunk' '')
                minutes=To-Int (Get-Prop $r 'minutes' 30)
                chunkability=4
                chunkSource='franchise'
                chunkRule=[string](Get-Prop $r 'name' '')
            }
        }
    }

    # QUALITY-ONLY: no generic/genre fallback. If a game has neither an exact per-game rule
    # nor a franchise rule, it is deliberately omitted from the Daily Chunk package.
    return $null
}


# ---------- Strict IGDB-only Daily Chunk resolution ----------
# A curated Daily Chunk title on an IGDB-only platform is useful only after it has a genuine
# IGDB game ID. Never manufacture an IGDB ID from a title/hash. Exact successful mappings are
# cached in daily-priority-<platform>-v2.json so later builds do not need to resolve them again.
$script:DailyIgdbToken=$null
$script:DailyIgdbTokenExpires=[datetime]::MinValue
$script:DailyIgdbLastRequest=[datetime]::MinValue

function Get-DailyIgdbPlatformId([string]$Platform) {
    switch($Platform){
        'Windows' { return 6L }
        'Nintendo Switch' { return 130L }
        'PS4' { return 48L }
        'PS5' { return 167L }
        'Xbox One' { return 49L }
        'Xbox Series X|S' { return 169L }
        default { return 0L }
    }
}
function Get-DailyIgdbConfig {
    if(!(Test-Path -LiteralPath $IgdbConfigPath)){ return $null }
    try {
        $cfg=Get-Content -LiteralPath $IgdbConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cid=[string](Get-Prop $cfg 'ClientId' '')
        $sec=[string](Get-Prop $cfg 'ClientSecret' '')
        if([string]::IsNullOrWhiteSpace($cid) -or [string]::IsNullOrWhiteSpace($sec)){ return $null }
        if($cid -match 'PUT-YOUR|YOUR-' -or $sec -match 'PUT-YOUR|YOUR-'){ return $null }
        return $cfg
    } catch { return $null }
}
function Get-DailyIgdbToken {
    if($script:DailyIgdbToken -and (Get-Date) -lt $script:DailyIgdbTokenExpires){ return $script:DailyIgdbToken }
    $cfg=Get-DailyIgdbConfig
    if($null -eq $cfg){ throw 'IGDB credentials are unavailable in igdb-config.json.' }
    $url='https://id.twitch.tv/oauth2/token?client_id='+[uri]::EscapeDataString([string]$cfg.ClientId)+'&client_secret='+[uri]::EscapeDataString([string]$cfg.ClientSecret)+'&grant_type=client_credentials'
    $r=Invoke-RestMethod -Uri $url -Method Post -TimeoutSec 60
    $script:DailyIgdbToken=[string]$r.access_token
    $expires=3600;try{$expires=[int]$r.expires_in}catch{}
    $script:DailyIgdbTokenExpires=(Get-Date).AddSeconds([Math]::Max(300,$expires-120))
    return $script:DailyIgdbToken
}
function Escape-DailyIgdb([string]$Value) {
    if($null -eq $Value){ return '' }
    return ($Value -replace '\\','\\\\' -replace '"','\"')
}
function Invoke-DailyIgdb([string]$Endpoint,[string]$Body,[int]$MaxAttempts=5) {
    $last=$null
    for($attempt=1;$attempt -le $MaxAttempts;$attempt++){
        $elapsed=((Get-Date)-$script:DailyIgdbLastRequest).TotalMilliseconds
        if($elapsed -lt 330){ Start-Sleep -Milliseconds ([int](330-$elapsed)) }
        try {
            $cfg=Get-DailyIgdbConfig
            if($null -eq $cfg){ throw 'IGDB credentials are unavailable in igdb-config.json.' }
            $token=Get-DailyIgdbToken
            $headers=@{'Client-ID'=[string]$cfg.ClientId;'Authorization'="Bearer $token";'Accept'='application/json'}
            $r=Invoke-RestMethod -Uri ("https://api.igdb.com/v4/$Endpoint") -Method Post -Headers $headers -ContentType 'text/plain' -Body $Body -TimeoutSec 60
            $script:DailyIgdbLastRequest=Get-Date
            if($null -eq $r){ return @() }
            return @($r | ForEach-Object {$_})
        } catch {
            $script:DailyIgdbLastRequest=Get-Date
            $last=$_
            $code=$null;try{$code=[int]$_.Exception.Response.StatusCode}catch{}
            if($attempt -ge $MaxAttempts){ break }
            if($code -eq 429){ Start-Sleep -Seconds 2 } else { Start-Sleep -Milliseconds ([Math]::Min(3000,500*$attempt)) }
        }
    }
    if($last){ throw $last }
    throw "IGDB request failed: $Endpoint"
}
function Convert-DailyIgdbGame([string]$Platform,$Curated,$Game,[int]$Order) {
    $gid=To-Long (Get-Prop $Game 'id' 0)
    if($gid -le 0){ return $null }
    $title=[string](Get-Prop $Curated 'title' '')
    if([string]::IsNullOrWhiteSpace($title)){ return $null }
    $year=0
    try {
        $ts=To-Long (Get-Prop $Game 'first_release_date' 0)
        if($ts -gt 0){ $year=[DateTimeOffset]::FromUnixTimeSeconds($ts).Year }
    } catch {}
    $genreIds=New-Object 'System.Collections.Generic.List[int]'
    $genreNames=New-Object 'System.Collections.Generic.List[string]'
    foreach($g in @(Get-Prop $Game 'genres' @())){
        $id=To-Int (Get-Prop $g 'id' 0);if($id -gt 0){[void]$genreIds.Add($id)}
        $name=[string](Get-Prop $g 'name' '');if($name){[void]$genreNames.Add($name)}
    }
    $coverUrl=''
    try {
        $imageId=[string](Get-Prop (Get-Prop $Game 'cover' $null) 'image_id' '')
        if($imageId){ $coverUrl="https://images.igdb.com/igdb/image/upload/t_cover_big/$imageId.jpg" }
    } catch {}
    return [pscustomobject][ordered]@{
        id="$Platform::IGDB::$gid"
        title=$title
        igdbId=[long]$gid
        releaseYear=[int]$year
        rating=To-Double (Get-Prop $Game 'rating' 0.0)
        catalogGenreIds=$genreIds.ToArray()
        catalogGenres=$genreNames.ToArray()
        coverUrl=$coverUrl
        summary=[string](Get-Prop $Game 'summary' '')
        dailyPriority=$true
        dailyOrder=$Order
    }
}
function Resolve-IgdbOnlyCuratedRows([string]$Platform,$CuratedRows,[string]$PriorityPath) {
    $target=@($CuratedRows | ForEach-Object {$_})
    if($target.Count -eq 0){ return @() }

    $cached=@()
    if(Test-Path -LiteralPath $PriorityPath){
        try { $cached=@((Get-Content -LiteralPath $PriorityPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object {$_}) } catch { $cached=@() }
    }
    $cachedByTitle=@{}
    foreach($row in $cached){
        $gid=Extract-IgdbId $row
        $k=Norm ([string](Get-Prop $row 'title' ''))
        if($gid -gt 0 -and $k -and -not $cachedByTitle.ContainsKey($k)){ $cachedByTitle[$k]=$row }
    }

    $resolved=New-Object 'System.Collections.Generic.List[object]'
    $unresolved=New-Object 'System.Collections.Generic.List[object]'
    $usedIds=@{}
    $order=0
    foreach($cr in $target){
        $order++
        $gid=Extract-IgdbId $cr
        $k=Norm ([string](Get-Prop $cr 'title' ''))
        $row=$null
        # Prefer a previously proven cached mapping because it also carries the rich IGDB metadata
        # needed by direct Featured/Daily cards. An explicit source ID is used immediately only when
        # it agrees with that previously proven cached title mapping.
        if($k -and $cachedByTitle.ContainsKey($k)){
            $cachedRow=$cachedByTitle[$k]
            $cachedId=Extract-IgdbId $cachedRow
            if($gid -le 0 -or $cachedId -eq $gid){ $row=$cachedRow }
        }
        # Never trust a hand-entered IGDB ID by itself. A supplied ID is accepted immediately
        # only when it agrees with a previously proven cached title mapping. Otherwise the exact
        # title + platform is verified live below, and any supplied ID must agree with that result.
        if($null -ne $row){
            $rid=Extract-IgdbId $row
            if($rid -gt 0 -and -not $usedIds.ContainsKey([string]$rid)){
                # Preserve the user's curated display title and Daily Chunk ordering.
                $copy=[ordered]@{}
                foreach($prop in $row.PSObject.Properties){ $copy[$prop.Name]=$prop.Value }
                $copy['title']=[string](Get-Prop $cr 'title' '')
                $copy['igdbId']=[long]$rid
                $copy['curatedTitle']=[string](Get-Prop $cr 'title' '')
                $copy['dailyPriority']=$true
                $copy['dailyOrder']=$order
                [void]$resolved.Add([pscustomobject]$copy)
                $usedIds[[string]$rid]=$true
            }
        } else {
            [void]$unresolved.Add([pscustomobject]@{curated=$cr;order=$order})
        }
    }

    $platformId=Get-DailyIgdbPlatformId $Platform
    $cfg=Get-DailyIgdbConfig
    if($unresolved.Count -gt 0 -and $platformId -gt 0 -and $null -ne $cfg){
        if(!$Quiet){ Write-Host ("[$Platform] resolving {0} curated titles to genuine IGDB IDs..." -f $unresolved.Count) -ForegroundColor DarkCyan }
        for($base=0;$base -lt $unresolved.Count;$base+=10){
            $group=@($unresolved | Select-Object -Skip $base -First 10)
            $parts=New-Object 'System.Collections.Generic.List[string]'
            $byName=@{}
            for($j=0;$j -lt $group.Count;$j++){
                $q="q$j";$byName[$q]=$group[$j]
                $safe=Escape-DailyIgdb ([string](Get-Prop $group[$j].curated 'title' ''))
                # Fast pass: IGDB documents scalar platform membership as `where platforms = 130` for a single platform ID.
                # A direct title-only fallback below independently verifies the returned platforms array.
                [void]$parts.Add("query games `"$q`" { fields id,name,alternative_names.name,platforms,first_release_date,rating,rating_count,genres.id,genres.name,cover.image_id,summary; search `"$safe`"; where platforms = $platformId & version_parent = null; limit 10; };")
            }
            try {
                $responses=@(Invoke-DailyIgdb 'multiquery' ($parts -join "`n"))
                foreach($resp in $responses){
                    $q=[string](Get-Prop $resp 'name' '')
                    if(!$byName.ContainsKey($q)){continue}
                    $item=$byName[$q]
                    $want=Norm ([string](Get-Prop $item.curated 'title' ''))
                    $exact=New-Object 'System.Collections.Generic.List[object]'
                    foreach($candidate in @(Get-Prop $resp 'result' @())){
                        $names=New-Object 'System.Collections.Generic.List[string]'
                        [void]$names.Add([string](Get-Prop $candidate 'name' ''))
                        foreach($alt in @(Get-Prop $candidate 'alternative_names' @())){
                            [void]$names.Add([string](Get-Prop $alt 'name' ''))
                        }
                        $isExact=$false
                        foreach($candidateName in @($names.ToArray())){
                            if((Norm $candidateName) -eq $want){ $isExact=$true; break }
                        }
                        if($isExact){ [void]$exact.Add($candidate) }
                    }
                    $exactRows=@($exact.ToArray() | Group-Object { [string](Get-Prop $_ 'id' '') } | ForEach-Object {$_.Group[0]})
                    $wantId=Extract-IgdbId $item.curated
                    if($wantId -gt 0){ $exactRows=@($exactRows | Where-Object { (To-Long (Get-Prop $_ 'id' 0)) -eq $wantId }) }
                    if($exactRows.Count -ne 1){continue} # Ambiguous, wrong explicit ID, or no exact canonical/alternate title: fail closed.
                    $row=Convert-DailyIgdbGame $Platform $item.curated $exactRows[0] ([int]$item.order)
                    if($null -eq $row){continue}
                    $rid=Extract-IgdbId $row
                    if($rid -le 0 -or $usedIds.ContainsKey([string]$rid)){continue}
                    [void]$resolved.Add($row)
                    $usedIds[[string]$rid]=$true
                    $cachedByTitle[$want]=$row
                }
            } catch {
                if(!$Quiet){ Write-Warning ("[$Platform] IGDB curated-title resolution failed for one batch: "+$_.Exception.Message) }
            }
        }

        # Direct fallback: search IGDB by title without a platform WHERE clause, then verify
        # the returned game's platforms array locally. This avoids losing valid games when
        # IGDB search ranking/platform filtering interact poorly inside multiquery.
        $fallbackItems=New-Object 'System.Collections.Generic.List[object]'
        # Windows PowerShell 5.1 can throw "Argument types do not match" when
        # @() directly wraps a Generic.List[object]. Index it explicitly instead.
        for($fallbackIndex=0; $fallbackIndex -lt $unresolved.Count; $fallbackIndex++){
            $item=$unresolved[$fallbackIndex]
            $want=Norm ([string](Get-Prop $item.curated 'title' ''))
            if(!$cachedByTitle.ContainsKey($want)){ [void]$fallbackItems.Add($item) }
        }
        if($fallbackItems.Count -gt 0){
            if(!$Quiet){ Write-Host ("[$Platform] retrying {0} unresolved titles with direct IGDB title lookup + local platform verification..." -f $fallbackItems.Count) -ForegroundColor DarkCyan }
            foreach($item in @($fallbackItems.ToArray())){
                $title=[string](Get-Prop $item.curated 'title' '')
                $want=Norm $title
                $safe=Escape-DailyIgdb $title
                try {
                    $body="fields id,name,alternative_names.name,platforms,first_release_date,rating,rating_count,genres.id,genres.name,cover.image_id,summary; search `"$safe`"; where version_parent = null; limit 20;"
                    $candidates=@(Invoke-DailyIgdb 'games' $body)
                    $exact=New-Object 'System.Collections.Generic.List[object]'
                    foreach($candidate in $candidates){
                        $hasPlatform=$false
                        foreach($p in @(Get-Prop $candidate 'platforms' @())){
                            $candidatePlatformId=0
                            if($p -is [ValueType] -or $p -is [string]){ $candidatePlatformId=To-Int $p }
                            else { $candidatePlatformId=To-Int (Get-Prop $p 'id' 0) }
                            if($candidatePlatformId -eq $platformId){ $hasPlatform=$true; break }
                        }
                        if(!$hasPlatform){ continue }

                        $names=New-Object 'System.Collections.Generic.List[string]'
                        [void]$names.Add([string](Get-Prop $candidate 'name' ''))
                        foreach($alt in @(Get-Prop $candidate 'alternative_names' @())){
                            [void]$names.Add([string](Get-Prop $alt 'name' ''))
                        }
                        $isExact=$false
                        foreach($candidateName in @($names.ToArray())){
                            if((Norm $candidateName) -eq $want){ $isExact=$true; break }
                        }
                        if($isExact){ [void]$exact.Add($candidate) }
                    }
                    $exactRows=@($exact.ToArray() | Group-Object { [string](Get-Prop $_ 'id' '') } | ForEach-Object {$_.Group[0]})
                    $wantId=Extract-IgdbId $item.curated
                    if($wantId -gt 0){ $exactRows=@($exactRows | Where-Object { (To-Long (Get-Prop $_ 'id' 0)) -eq $wantId }) }
                    if($exactRows.Count -ne 1){ continue }
                    $row=Convert-DailyIgdbGame $Platform $item.curated $exactRows[0] ([int]$item.order)
                    if($null -eq $row){ continue }
                    $rid=Extract-IgdbId $row
                    if($rid -le 0 -or $usedIds.ContainsKey([string]$rid)){ continue }
                    [void]$resolved.Add($row)
                    $usedIds[[string]$rid]=$true
                    $cachedByTitle[$want]=$row
                } catch {
                    if(!$Quiet){ Write-Warning ("[$Platform] direct IGDB lookup failed for '$title': "+$_.Exception.Message) }
                }
            }
        }
    } elseif($unresolved.Count -gt 0 -and !$Quiet) {
        Write-Warning ("[$Platform] {0} curated titles have no proven IGDB ID and IGDB resolution is unavailable. They will be omitted." -f $unresolved.Count)
    }

    $final=@($resolved.ToArray() | Where-Object {(Extract-IgdbId $_) -gt 0} | Sort-Object @{Expression={To-Int (Get-Prop $_ 'dailyOrder' 999999)}},title)

    # Cache every proven title mapping we know, including new exact matches. Unrelated existing
    # cached rows are preserved because other builder/browser paths may still use them.
    $cacheById=@{}
    foreach($row in $cached){$gid=Extract-IgdbId $row;if($gid -gt 0){$cacheById[[string]$gid]=$row}}
    foreach($row in $final){$gid=Extract-IgdbId $row;if($gid -gt 0){$cacheById[[string]$gid]=$row}}
    if($cacheById.Count -gt 0){
        $utf8=New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($PriorityPath,(@($cacheById.Values) | ConvertTo-Json -Depth 12 -Compress),$utf8)
    }

    if(!$Quiet -and $final.Count -lt $target.Count){
        Write-Warning ("[$Platform] strict IGDB rule kept {0}/{1} curated titles; unresolved/ambiguous titles were omitted." -f $final.Count,$target.Count)
    }
    return $final
}

# ---------- Core Daily Chunk package ----------
$chunks = @((Get-Content -LiteralPath $ChunksPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
if($chunks.Count -eq 0){ throw 'daily-chunks.json contains no entries.' }
$series = @((Get-Content -LiteralPath $SeriesPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
$gameSpecific = @((Get-Content -LiteralPath $GameSpecificPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
$gameSpecificLookup=@{}
foreach($gs in $gameSpecific){
    $gp=[string](Get-Prop $gs 'platform' '')
    $gt=[string](Get-Prop $gs 'title' '')
    $gc=[string](Get-Prop $gs 'dailyChunk' '')
    if($gp -and $gt -and $gc){ $gameSpecificLookup[$gp.ToLowerInvariant()+'::'+(Norm $gt)]=$gs }
}
$config = Get-Content -LiteralPath $PlatformsPath -Raw -Encoding UTF8 | ConvertFrom-Json

# ---------- Hand-curated Featured source ----------
# This file is the ONLY source of Featured membership. The builder validates/resolves these
# choices; it never auto-adds games from ratings, review scores, popularity or Daily Chunk order.
$featuredDocument = Get-Content -LiteralPath $FeaturedCuratedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$featuredCurated = @(Array-Of (Get-Prop $featuredDocument 'games' @()) | ForEach-Object { $_ })
if($featuredCurated.Count -eq 0){ throw 'featured-games-curated.json contains no games.' }
$configuredFeaturedPlatforms=@{}
foreach($p in @($config.platforms)){ $configuredFeaturedPlatforms[[string]$p.name]=$true }
$featuredSeen=@{}
$featuredSourceCounts=@{}
foreach($fr in $featuredCurated){
    $fp=[string](Get-Prop $fr 'platform' '')
    $ft=[string](Get-Prop $fr 'title' '')
    if([string]::IsNullOrWhiteSpace($fp) -or [string]::IsNullOrWhiteSpace($ft)){
        throw 'Every Featured entry must contain non-empty platform and title fields.'
    }
    if(!$configuredFeaturedPlatforms.ContainsKey($fp)){ throw "Featured entry uses unknown platform: $fp :: $ft" }
    $fk=$fp.ToLowerInvariant()+'::'+(Norm $ft)
    if($featuredSeen.ContainsKey($fk)){ throw "Duplicate Featured entry: $fp :: $ft" }
    $featuredSeen[$fk]=$true
    if(!$featuredSourceCounts.ContainsKey($fp)){ $featuredSourceCounts[$fp]=0 }
    $featuredSourceCounts[$fp]++
    if($featuredSourceCounts[$fp] -gt 50){ throw "Featured curation exceeds 50 games for platform: $fp" }
}

$valid = New-Object 'System.Collections.Generic.List[object]'
$platformCounts = @{}
$chunkLookup=@{}
foreach($row in $chunks){
    $platform = [string]$row.platform
    $title = [string]$row.title
    $text = [string]$row.dailyChunk
    if([string]::IsNullOrWhiteSpace($platform) -or [string]::IsNullOrWhiteSpace($title) -or [string]::IsNullOrWhiteSpace($text)){ continue }
    $obj = [ordered]@{
        id = $(if($row.PSObject.Properties['id'] -and $row.id){[string]$row.id}else{"${platform}::$title"})
        platform = $platform
        title = $title
        dailyChunk = $text
        minutes = $(if($row.PSObject.Properties['minutes']){[int]$row.minutes}else{30})
        chunkability = $(if($row.PSObject.Properties['chunkability']){[int]$row.chunkability}elseif($row.PSObject.Properties['fit']){[int]$row.fit}else{4})
    }
    foreach($optional in @('igdbId','steamAppId','controllerSupport','intensity','why')){
        if($row.PSObject.Properties[$optional]){
            $value=$row.PSObject.Properties[$optional].Value
            if($null -ne $value -and [string]$value -ne ''){ $obj[$optional]=$value }
        }
    }
    $o=[pscustomobject]$obj
    [void]$valid.Add($o)
    $chunkLookup[($platform.ToLowerInvariant()+'::'+(Norm $title))]=$o
    if(!$platformCounts.ContainsKey($platform)){ $platformCounts[$platform]=0 }
    $platformCounts[$platform]++
}
if($valid.Count -eq 0){ throw 'No valid Daily Chunk entries were found.' }

# ---------- Windows Daily Chunk -> Steam ID/controller cache ----------
# Windows Daily Chunks are mapped from their title to a Steam AppID once.
# The mapping uses Valve's IStoreService/GetAppList endpoint with the user's
# normal Steam Web API key. The key is saved only in this local builder folder.
function Get-WindowsSteamCacheKey($Row) {
    # Windows Daily Chunks are Steam-title based. Use the normalized title as the stable key
    # even when an IGDB ID happens to be present. V3.6 mixed IGDB and title keys, which made
    # proven Steam mappings disappear when the curated row did not carry the same IGDB ID.
    $title=[string](Get-Prop $Row 'title' '')
    $nk=Norm $title
    if($nk){ return ('title:'+$nk) }
    $gid=Extract-IgdbId $Row
    if($gid -gt 0){ return ('igdb:'+([string]$gid)) }
    return 'title:'
}
function SecureString-ToPlain([Security.SecureString]$Secure) {
    $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Get-SteamApiKey {
    if(Test-Path -LiteralPath $SteamConfigPath){
        try {
            $cfg=Get-Content -LiteralPath $SteamConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved=[string](Get-Prop $cfg 'ApiKey' (Get-Prop $cfg 'Key' ''))
            if(-not [string]::IsNullOrWhiteSpace($saved)){ return $saved.Trim() }
        } catch {}
    }
    if($Quiet){ return $null }
    Write-Host ''
    Write-Host 'Steam Web API key is needed once to map Windows Daily Chunk titles to Steam AppIDs.' -ForegroundColor Yellow
    Write-Host 'It will be saved only in steam-config.json inside this local builder folder.' -ForegroundColor DarkGray
    $secure=Read-Host 'Steam Web API key' -AsSecureString
    $key=SecureString-ToPlain $secure
    if([string]::IsNullOrWhiteSpace($key)){ throw 'Steam Web API key was blank.' }
    $key=$key.Trim()
    $utf8=New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($SteamConfigPath,([pscustomobject]@{ApiKey=$key} | ConvertTo-Json),$utf8)
    Write-Host 'Saved Steam Web API key to steam-config.json.' -ForegroundColor Green
    return $key
}
function Flatten-Objects($Value) {
    $out=New-Object 'System.Collections.Generic.List[object]'
    if($null -eq $Value){ return $out.ToArray() }
    foreach($x in @($Value)){
        if($null -eq $x){ continue }
        if($x -is [Array]){
            foreach($y in $x){ if($null -ne $y){ [void]$out.Add($y) } }
        } else { [void]$out.Add($x) }
    }
    return $out.ToArray()
}
function Read-SteamTitleIndex {
    if(!(Test-Path -LiteralPath $SteamTitleIndexPath)){ return @() }
    try {
        $raw=Get-Content -LiteralPath $SteamTitleIndexPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $apps=Get-Prop $raw 'apps' $raw
        return @(Flatten-Objects $apps)
    } catch { return @() }
}
function Save-SteamTitleIndex($Apps) {
    try {
        $payload=[ordered]@{
            format='gamebrowser-steam-title-index-v1'
            generatedAt=(Get-Date).ToUniversalTime().ToString('o')
            gameCount=@($Apps).Count
            apps=@($Apps)
        }
        $utf8=New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($SteamTitleIndexPath,($payload | ConvertTo-Json -Depth 6 -Compress),$utf8)
    } catch {
        if(!$Quiet){ Write-Warning ('Could not save Steam title index cache: '+$_.Exception.Message) }
    }
}
function Get-AllSteamGames([string]$Key) {
    $all=New-Object 'System.Collections.Generic.List[object]'
    $lastAppId=0L
    $requests=0
    while($true){
        $url=('https://api.steampowered.com/IStoreService/GetAppList/v1/?key='+[uri]::EscapeDataString($Key)+'&include_games=true&include_dlc=false&include_software=false&include_videos=false&include_hardware=false&max_results=50000')
        if($lastAppId -gt 0){ $url+='&last_appid='+[string]$lastAppId }
        try {
            $r=Invoke-RestMethod -Method Get -Uri $url -Headers @{'User-Agent'='GameBrowser-Database-Builder/1.0'} -TimeoutSec 120
        } catch {
            $msg=$_.Exception.Message
            if($msg -match '403|Forbidden'){
                throw 'Steam rejected the Web API key with 403 Forbidden. Check steam-config.json or delete it and rerun to enter the key again.'
            }
            throw
        }
        $requests++
        $apps=@(Flatten-Objects (Get-Prop (Get-Prop $r 'response' $null) 'apps' @()))
        foreach($a in $apps){
            $appid=To-Long (Get-Prop $a 'appid' 0)
            $name=[string](Get-Prop $a 'name' '')
            if($appid -gt 0 -and -not [string]::IsNullOrWhiteSpace($name)){
                [void]$all.Add([pscustomobject]@{appid=[long]$appid;name=$name})
            }
        }
        if(!$Quiet){ Write-Host ("`r[Windows] Steam API request {0}: {1:N0} game records" -f $requests,$all.Count) -NoNewline }
        if($apps.Count -eq 0 -or $apps.Count -lt 50000){ break }
        $newLast=To-Long (Get-Prop $apps[$apps.Count-1] 'appid' 0)
        if($newLast -le $lastAppId){ throw 'Steam GetAppList continuation did not advance.' }
        $lastAppId=$newLast
    }
    if(!$Quiet){ Write-Host '' }
    return $all.ToArray()
}
function Get-SteamTitleIndexForMapping {
    $cached=@(Read-SteamTitleIndex)
    if($cached.Count -gt 0){
        if(!$Quiet){ Write-Host ("[Windows] reusing cached Steam title index: {0:N0} games" -f $cached.Count) -ForegroundColor DarkGray }
        return $cached
    }
    # If the older/prebuilt Windows platform catalog is present, reuse it first.
    $windowsCatalog=Join-Path $CatalogRoot 'windows.json'
    if(Test-Path -LiteralPath $windowsCatalog){
        try {
            $rows=@(Flatten-Objects (Get-Content -LiteralPath $windowsCatalog -Raw -Encoding UTF8 | ConvertFrom-Json))
            $fromCatalog=New-Object 'System.Collections.Generic.List[object]'
            foreach($r in $rows){
                $sid=To-Long (Get-Prop $r 'steamAppId' (Get-Prop $r 'appid' 0))
                $title=[string](Get-Prop $r 'title' (Get-Prop $r 'name' ''))
                if($sid -gt 0 -and -not [string]::IsNullOrWhiteSpace($title)){
                    [void]$fromCatalog.Add([pscustomobject]@{appid=[long]$sid;name=$title})
                }
            }
            if($fromCatalog.Count -gt 1000){
                if(!$Quiet){ Write-Host ("[Windows] using existing Windows catalog as Steam title index: {0:N0} games" -f $fromCatalog.Count) -ForegroundColor DarkGray }
                Save-SteamTitleIndex $fromCatalog.ToArray()
                return $fromCatalog.ToArray()
            }
        } catch {}
    }
    $key=Get-SteamApiKey
    if([string]::IsNullOrWhiteSpace([string]$key)){ return @() }
    if(!$Quiet){ Write-Host '[Windows] downloading Steam game-name index (up to 50,000 games per request)...' -ForegroundColor DarkCyan }
    $apps=@(Get-AllSteamGames $key)
    if($apps.Count -gt 0){ Save-SteamTitleIndex $apps }
    return $apps
}
function Get-SteamCandidateMetadata([string[]]$Ids) {
    $result=@{}
    $clean=@($Ids | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    if($clean.Count -eq 0){ return $result }

    # Steam Store appdetails is most reliable one AppID at a time. Multi-AppID requests can
    # return HTTP 400, which was the reason an otherwise resolvable ambiguous title failed.
    foreach($sid in $clean){
        $url='https://store.steampowered.com/api/appdetails?appids='+[uri]::EscapeDataString([string]$sid)+'&cc=us&l=english'
        try {
            $r=Invoke-RestMethod -Method Get -Uri $url -Headers @{
                'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36'
                'Accept'='application/json,text/plain,*/*'
                'Accept-Language'='en-US,en;q=0.9'
                'Referer'='https://store.steampowered.com/'
            } -TimeoutSec 60
            $entry=Get-Prop $r ([string]$sid) $null
            if($entry -and $entry.success -eq $true -and $entry.data){
                $d=$entry.data
                $recommendations=0
                $rec=Get-Prop $d 'recommendations' $null
                if($rec){ $recommendations=To-Int (Get-Prop $rec 'total' 0) }
                $platforms=Get-Prop $d 'platforms' $null
                $isWindows=$false
                if($platforms){ try { $isWindows=[bool](Get-Prop $platforms 'windows' $false) } catch {} }
                $release=Get-Prop $d 'release_date' $null
                $comingSoon=$false
                if($release){ try { $comingSoon=[bool](Get-Prop $release 'coming_soon' $false) } catch {} }
                $result[[string]$sid]=[pscustomobject]@{
                    appid=[string]$sid
                    name=[string](Get-Prop $d 'name' '')
                    type=([string](Get-Prop $d 'type' '')).ToLowerInvariant()
                    windows=$isWindows
                    recommendations=$recommendations
                    comingSoon=$comingSoon
                }
            }
        } catch {
            if(!$Quiet){ Write-Warning ('[Windows] Steam metadata check failed for AppID '+$sid+': '+$_.Exception.Message) }
        }
        Start-Sleep -Milliseconds 180
    }
    return $result
}
function Resolve-SteamIdsByTitle($NeedEntries,$SteamApps) {
    $resolved=@{}
    if(@($NeedEntries).Count -eq 0 -or @($SteamApps).Count -eq 0){ return $resolved }

    $wanted=@{}
    foreach($item in @($NeedEntries)){
        $title=[string](Get-Prop $item 'title' '')
        $n=Norm $title
        if($n){ $wanted[$n]=$true }
    }

    $matches=@{}
    foreach($a in @($SteamApps)){
        $name=[string](Get-Prop $a 'name' '')
        $n=Norm $name
        if(!$n -or !$wanted.ContainsKey($n)){ continue }
        if(!$matches.ContainsKey($n)){ $matches[$n]=New-Object 'System.Collections.Generic.List[object]' }
        [void]$matches[$n].Add($a)
    }

    # First resolve every title that has a single unique Steam AppID.
    # Ambiguous exact-title duplicates are collected and validated against Steam Store metadata.
    $ambiguous=New-Object 'System.Collections.Generic.List[object]'
    $candidateIds=New-Object 'System.Collections.Generic.List[string]'
    foreach($item in @($NeedEntries)){
        $key=[string](Get-Prop $item 'cacheKey' '')
        $title=[string](Get-Prop $item 'title' '')
        $n=Norm $title
        if(!$key -or !$matches.ContainsKey($n)){ continue }
        $candidates=@($matches[$n].ToArray())
        if($candidates.Count -eq 1){
            $resolved[$key]=[string](Get-Prop $candidates[0] 'appid' '')
            continue
        }
        $exact=@($candidates | Where-Object { ([string](Get-Prop $_ 'name' '')) -ieq $title })
        if($exact.Count -eq 1){
            $resolved[$key]=[string](Get-Prop $exact[0] 'appid' '')
            continue
        }
        $pool=$(if($exact.Count -gt 1){$exact}else{$candidates})
        [void]$ambiguous.Add([pscustomobject]@{cacheKey=$key;title=$title;candidates=@($pool)})
        foreach($c in @($pool)){
            $sid=[string](Get-Prop $c 'appid' '')
            if($sid -match '^\d+$'){ [void]$candidateIds.Add($sid) }
        }
    }

    if($ambiguous.Count -gt 0){
        if(!$Quiet){ Write-Host ("[Windows] validating {0} ambiguous Daily Chunk titles against Steam metadata..." -f $ambiguous.Count) -ForegroundColor DarkCyan }
        $meta=Get-SteamCandidateMetadata ([string[]]@($candidateIds.ToArray() | Select-Object -Unique))
        foreach($item in @($ambiguous.ToArray())){
            $title=[string]$item.title
            $key=[string]$item.cacheKey
            $scored=New-Object 'System.Collections.Generic.List[object]'
            foreach($c in @($item.candidates)){
                $sid=[string](Get-Prop $c 'appid' '')
                if(!$meta.ContainsKey($sid)){ continue }
                $m=$meta[$sid]
                $storeName=[string](Get-Prop $m 'name' '')
                $exactName=($storeName -ieq $title)
                $isGame=(([string](Get-Prop $m 'type' '')) -eq 'game')
                $isWindows=[bool](Get-Prop $m 'windows' $false)
                $recs=To-Int (Get-Prop $m 'recommendations' 0)
                $coming=[bool](Get-Prop $m 'comingSoon' $false)
                # Eligibility signals first; recommendation count is only a tie-breaker among
                # otherwise valid exact Windows games. This avoids blindly taking the newest AppID.
                $base=0
                if($exactName){ $base+=1000 }
                if($isGame){ $base+=500 }
                if($isWindows){ $base+=250 }
                if(!$coming){ $base+=25 }
                [void]$scored.Add([pscustomobject]@{appid=$sid;base=$base;recommendations=$recs;exact=$exactName;game=$isGame;windows=$isWindows})
            }
            if($scored.Count -eq 0){
                if(!$Quiet){ Write-Warning ("[Windows] ambiguous Steam title still unresolved: {0}" -f $title) }
                continue
            }
            $ordered=@($scored.ToArray() | Sort-Object -Property @{Expression={$_.base};Descending=$true}, @{Expression={$_.recommendations};Descending=$true})
            $top=$ordered[0]
            $second=$(if($ordered.Count -gt 1){$ordered[1]}else{$null})
            $choose=$false
            if($ordered.Count -eq 1){
                $choose=$true
            } elseif($top.base -gt $second.base){
                $choose=$true
            } elseif($top.base -ge 1750 -and $top.recommendations -gt 0 -and $top.recommendations -gt ($second.recommendations * 2)){
                # If both candidates look like exact released Windows games, only use popularity
                # when the lead is decisive (more than 2x) rather than guessing on a small gap.
                $choose=$true
            }
            if($choose){
                $resolved[$key]=[string]$top.appid
                if(!$Quiet){ Write-Host ("[Windows] resolved ambiguous title: {0} -> AppID {1}" -f $title,$top.appid) -ForegroundColor DarkGray }
            } elseif(!$Quiet){
                Write-Warning ("[Windows] ambiguous Steam title still unresolved: {0}" -f $title)
            }
        }
    }
    return $resolved
}
function Invoke-SteamAppDetailsRecursive([string[]]$Ids,[hashtable]$Result) {
    # Despite the historical function name, query Store appdetails one AppID at a time.
    # Multi-AppID Store requests can return HTTP 400; single-AppID requests are reliable.
    $clean=@($Ids | Where-Object {$_ -match '^\d+$'} | Select-Object -Unique)
    foreach($sid in $clean){
        $url='https://store.steampowered.com/api/appdetails?appids='+[uri]::EscapeDataString([string]$sid)+'&cc=us&l=english'
        $done=$false
        for($attempt=1;$attempt -le 3 -and -not $done;$attempt++){
            try {
                $r=Invoke-RestMethod -Method Get -Uri $url -Headers @{
                    'User-Agent'='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/151 Safari/537.36'
                    'Accept'='application/json,text/plain,*/*'
                    'Accept-Language'='en-US,en;q=0.9'
                    'Referer'='https://store.steampowered.com/'
                } -TimeoutSec 60
                $entry=Get-Prop $r ([string]$sid) $null
                if($entry -and $entry.success -eq $true -and $entry.data){
                    $Result[[string]$sid]=Get-ControllerClass $entry.data
                }
                $done=$true
            } catch {
                if($attempt -lt 3){ Start-Sleep -Milliseconds (600*$attempt) }
            }
        }
        Start-Sleep -Milliseconds 180
    }
}
function Ensure-WindowsSteamCache($WindowsRows) {
    $cache=@{}

    # V2 fixes V3.6's mixed IGDB/title cache keys. On the first run, migrate every useful
    # V1 mapping by TITLE so the already-proven Steam AppIDs are not downloaded/resolved again.
    # Blank V1 controller results are intentionally marked unchecked because that old cache
    # incorrectly stored controllerChecked=true even when no classification had been obtained.
    $cacheSources=New-Object 'System.Collections.Generic.List[object]'
    if(Test-Path -LiteralPath $WindowsSteamCachePath){
        [void]$cacheSources.Add([pscustomobject]@{path=$WindowsSteamCachePath;legacy=$false})
    }
    if(Test-Path -LiteralPath $WindowsSteamLegacyCachePath){
        [void]$cacheSources.Add([pscustomobject]@{path=$WindowsSteamLegacyCachePath;legacy=$true})
    }
    foreach($source in @($cacheSources.ToArray())){
        try {
            foreach($c in @(Flatten-Objects (Get-Content -LiteralPath $source.path -Raw -Encoding UTF8 | ConvertFrom-Json))){
                $gid=To-Long (Get-Prop $c 'igdbId' 0)
                $title=[string](Get-Prop $c 'title' '')
                $nk=Norm $title
                $k=$(if($nk){'title:'+$nk}elseif($gid -gt 0){'igdb:'+([string]$gid)}else{'title:'})
                if($k -eq 'title:'){ continue }

                $sid=[string](Get-Prop $c 'steamAppId' '')
                $support=Normalize-ControllerClass ([string](Get-Prop $c 'controllerSupport' ''))
                $mappingChecked=[bool](Get-Prop $c 'mappingChecked' $false)
                if($sid){ $mappingChecked=$true }
                $controllerChecked=[bool](Get-Prop $c 'controllerChecked' $false)
                if([bool]$source.legacy -and -not $support){ $controllerChecked=$false }
                if($support){ $controllerChecked=$true }

                $candidate=[pscustomobject]@{
                    title=$title
                    igdbId=[long]$gid
                    steamAppId=$sid
                    controllerSupport=$support
                    controllerChecked=$controllerChecked
                    mappingChecked=$mappingChecked
                }

                if(!$cache.ContainsKey($k)){
                    $cache[$k]=$candidate
                } else {
                    # Prefer whichever duplicate has the useful Steam mapping/controller result.
                    $old=$cache[$k]
                    $oldSid=[string](Get-Prop $old 'steamAppId' '')
                    $oldSupport=Normalize-ControllerClass ([string](Get-Prop $old 'controllerSupport' ''))
                    if((!$oldSid -and $sid) -or (!$oldSupport -and $support)){ $cache[$k]=$candidate }
                }
            }
        } catch {}
    }
    # Seed/refresh cache rows from the current 200-game Windows Daily Chunk set.
    foreach($row in @($WindowsRows)){
        $k=Get-WindowsSteamCacheKey $row
        if($k -eq 'title:'){ continue }
        $gid=Extract-IgdbId $row
        $title=[string](Get-Prop $row 'title' '')
        $rowSid=[string](Get-Prop $row 'steamAppId' '')
        $rowController=Normalize-ControllerClass ([string](Get-Prop $row 'controllerSupport' ''))
        $existing=$(if($cache.ContainsKey($k)){$cache[$k]}else{$null})
        $sid=$(if($rowSid){$rowSid}else{[string](Get-Prop $existing 'steamAppId' '')})
        $controller=$(if($rowController){$rowController}else{Normalize-ControllerClass ([string](Get-Prop $existing 'controllerSupport' ''))})
        $checked=[bool](Get-Prop $existing 'controllerChecked' $false)
        $mappingChecked=[bool](Get-Prop $existing 'mappingChecked' $false)
        if($sid){ $mappingChecked=$true }
        if($rowController){ $checked=$true }
        if(([string](Get-Prop $row 'controllerSupport' '')) -eq 'None'){ $checked=$true }
        $cache[$k]=[pscustomobject]@{title=$title;igdbId=[long]$gid;steamAppId=$sid;controllerSupport=$controller;controllerChecked=$checked;mappingChecked=$mappingChecked}
    }
    $needMap=New-Object 'System.Collections.Generic.List[object]'
    foreach($k in @($cache.Keys)){
        $c=$cache[$k]
        if([string]::IsNullOrWhiteSpace([string](Get-Prop $c 'steamAppId' '')) -and -not [bool](Get-Prop $c 'mappingChecked' $false)){
            [void]$needMap.Add([pscustomobject]@{cacheKey=[string]$k;title=[string](Get-Prop $c 'title' '')})
        }
    }
    if($needMap.Count -gt 0){
        try {
            if(!$Quiet){ Write-Host ("[Windows] resolving {0} Daily Chunk games to Steam AppIDs..." -f $needMap.Count) -ForegroundColor DarkCyan }
            $steamApps=@(Get-SteamTitleIndexForMapping)
            if($steamApps.Count -gt 0){
                $mapped=Resolve-SteamIdsByTitle $needMap.ToArray() $steamApps
                foreach($k in @($mapped.Keys)){
                    if(!$cache.ContainsKey($k)){ continue }
                    $existing=$cache[$k]
                    $cache[$k]=[pscustomobject]@{
                        title=[string](Get-Prop $existing 'title' '')
                        igdbId=[long](To-Long (Get-Prop $existing 'igdbId' 0))
                        steamAppId=[string]$mapped[$k]
                        controllerSupport=Normalize-ControllerClass ([string](Get-Prop $existing 'controllerSupport' ''))
                        controllerChecked=[bool](Get-Prop $existing 'controllerChecked' $false)
                        mappingChecked=$true
                    }
                }
                $unmapped=@($needMap.ToArray() | Where-Object {!$mapped.ContainsKey([string]$_.cacheKey)})
                if(!$Quiet -and $unmapped.Count -gt 0){ Write-Warning ("[Windows] {0} Daily Chunk titles could not be matched uniquely to Steam." -f $unmapped.Count) }
            } elseif(!$Quiet){ Write-Warning '[Windows] Steam title index unavailable; keeping any existing mappings.' }
        } catch {
            if($_.Exception.Message -match 'Steam rejected the Web API key|Steam Web API key was blank'){ throw }
            if(!$Quiet){ Write-Warning ("[Windows] Steam AppID mapping skipped: {0}" -f $_.Exception.Message) }
        }
    }
    $needController=@($cache.GetEnumerator() | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string](Get-Prop $_.Value 'steamAppId' '')) -and -not [bool](Get-Prop $_.Value 'controllerChecked' $false)
    } | ForEach-Object {[string](Get-Prop $_.Value 'steamAppId' '')} | Select-Object -Unique)
    if($needController.Count -gt 0){
        try {
            if(!$Quiet){ Write-Host ("[Windows] classifying controller support for {0} Daily Chunk Steam games..." -f $needController.Count) -ForegroundColor DarkCyan }
            $classes=@{}
            for($start=0;$start -lt $needController.Count;$start+=50){
                Invoke-SteamAppDetailsRecursive -Ids ([string[]]@($needController | Select-Object -Skip $start -First 50)) -Result $classes
            }
            foreach($k in @($cache.Keys)){
                $entry=$cache[$k];$sid=[string](Get-Prop $entry 'steamAppId' '')
                if($sid -and $classes.ContainsKey($sid)){
                    $cache[$k]=[pscustomobject]@{
                        title=[string](Get-Prop $entry 'title' '')
                        igdbId=[long](To-Long (Get-Prop $entry 'igdbId' 0))
                        steamAppId=$sid
                        controllerSupport=Normalize-ControllerClass ([string]$classes[$sid])
                        controllerChecked=$true
                        mappingChecked=$true
                    }
                }
            }
        } catch { if(!$Quiet){ Write-Warning ("[Windows] controller classification skipped: {0}" -f $_.Exception.Message) } }
    }
    $rows=@($cache.GetEnumerator() | Sort-Object Name | ForEach-Object {$_.Value})
    try { [IO.File]::WriteAllText($WindowsSteamCachePath,($rows | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false))) } catch {}
    return $cache
}

# ---------- Hand-curated Featured validation/resolution ----------
function Resolve-FeaturedAgainstCatalog([string]$Platform,$CuratedRows,[string]$CatalogPath) {
    $target=@($CuratedRows | ForEach-Object {$_})
    if($target.Count -eq 0){ return @() }
    if(!(Test-Path -LiteralPath $CatalogPath)){
        if(!$Quiet){ Write-Warning "[$Platform] Featured validation catalog is missing: $CatalogPath" }
        return @()
    }
    try { $all=@((Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object {$_}) }
    catch {
        if(!$Quiet){ Write-Warning ("[$Platform] Featured catalog could not be read: "+$_.Exception.Message) }
        return @()
    }
    $byId=@{}
    $byTitle=@{}
    foreach($row in $all){
        $gid=Extract-IgdbId $row
        if($gid -gt 0 -and -not $byId.ContainsKey([string]$gid)){ $byId[[string]$gid]=$row }
        $nk=Norm ([string](Get-Prop $row 'title' ''))
        if($nk){
            if(!$byTitle.ContainsKey($nk)){ $byTitle[$nk]=New-Object 'System.Collections.Generic.List[object]' }
            [void]$byTitle[$nk].Add($row)
        }
    }
    $resolved=New-Object 'System.Collections.Generic.List[object]'
    $usedIds=@{}
    $order=0
    foreach($cr in $target){
        $order++
        $chosen=$null
        $wantId=Extract-IgdbId $cr
        if($wantId -gt 0 -and $byId.ContainsKey([string]$wantId)){
            $chosen=$byId[[string]$wantId]
        } else {
            $nk=Norm ([string](Get-Prop $cr 'title' ''))
            if($nk -and $byTitle.ContainsKey($nk)){
                $unique=@{}
                foreach($candidate in @($byTitle[$nk].ToArray())){
                    $candidateId=Extract-IgdbId $candidate
                    if($candidateId -gt 0 -and -not $unique.ContainsKey([string]$candidateId)){ $unique[[string]$candidateId]=$candidate }
                }
                if($unique.Count -eq 1){ $chosen=@($unique.Values)[0] }
            }
        }
        if($null -eq $chosen){
            if(!$Quiet){ Write-Warning ("[$Platform] hand-curated Featured choice was not an unambiguous verified catalog match and was omitted: "+[string](Get-Prop $cr 'title' '')) }
            continue
        }
        $gid=Extract-IgdbId $chosen
        if($gid -le 0 -or $usedIds.ContainsKey([string]$gid)){ continue }
        $copy=[ordered]@{}
        foreach($prop in $chosen.PSObject.Properties){ $copy[$prop.Name]=$prop.Value }
        $copy['curatedTitle']=[string](Get-Prop $cr 'title' '')
        $copy['featuredSourceOrder']=$order
        [void]$resolved.Add([pscustomobject]$copy)
        $usedIds[[string]$gid]=$true
    }
    return @($resolved.ToArray() | Sort-Object @{Expression={To-Int (Get-Prop $_ 'featuredSourceOrder' 999999)}},title)
}

function Resolve-WindowsFeaturedRows($CuratedRows) {
    $target=@($CuratedRows | ForEach-Object {$_})
    if($target.Count -eq 0){ return @() }
    $steamApps=@()
    try { $steamApps=@(Get-SteamTitleIndexForMapping) }
    catch {
        if(!$Quiet){ Write-Warning ("[Windows] Featured Steam game index unavailable: "+$_.Exception.Message) }
        return @()
    }
    if($steamApps.Count -eq 0){ return @() }
    $byId=@{}
    foreach($a in $steamApps){
        $sid=[string](Get-Prop $a 'appid' '')
        if($sid -match '^\d+$'){ $byId[$sid]=$a }
    }
    $need=New-Object 'System.Collections.Generic.List[object]'
    $resolvedByKey=@{}
    $order=0
    foreach($cr in $target){
        $order++
        $title=[string](Get-Prop $cr 'title' '')
        $key='featured:'+([string]$order)+':'+(Norm $title)
        $sid=[string](Get-Prop $cr 'steamAppId' '')
        if($sid -match '^\d+$' -and $byId.ContainsKey($sid)){
            $resolvedByKey[$key]=[pscustomobject]@{title=$title;steamAppId=$sid;featuredSourceOrder=$order}
        } else {
            [void]$need.Add([pscustomobject]@{cacheKey=$key;title=$title;order=$order})
        }
    }
    if($need.Count -gt 0){
        $mapped=Resolve-SteamIdsByTitle $need.ToArray() $steamApps
        foreach($item in @($need.ToArray())){
            $key=[string]$item.cacheKey
            if(!$mapped.ContainsKey($key)){
                if(!$Quiet){ Write-Warning ("[Windows] hand-curated Featured choice could not be resolved uniquely to a Steam game and was omitted: "+[string]$item.title) }
                continue
            }
            $sid=[string]$mapped[$key]
            if(!$byId.ContainsKey($sid)){ continue }
            $resolvedByKey[$key]=[pscustomobject]@{title=[string]$item.title;steamAppId=$sid;featuredSourceOrder=[int]$item.order}
        }
    }
    return @($resolvedByKey.Values | Sort-Object featuredSourceOrder,title)
}

# ---------- Build direct curated per-platform index ----------
# The source daily-chunks.json is now authoritative for BOTH selection and per-platform count.
# This lets older systems use 50 rows while PS1-era-and-newer systems use 200 (or every verified
# game when the verified catalog is smaller). DAT-backed selections are resolved directly against
# the existing IGDB + DAT catalog, so changing Daily Chunks does NOT require rebuilding that catalog.
$direct = New-Object 'System.Collections.Generic.List[object]'
$directPlatformCounts=@{}
$windowsRowsForCache=@()
$priorityByPlatform=@{}
foreach($pcfg in @($config.platforms)){
    $platform=[string]$pcfg.name
    $mode=[string](Get-Prop $pcfg 'mode' '')
    $slug=State-Key $platform
    $catalogPath=Join-Path $CatalogRoot ($slug+'.json')
    $priorityPath=Join-Path $CacheRoot ('daily-priority-'+$slug+'-v2.json')
    $rows=@()
    $curatedRows=@($valid.ToArray() | Where-Object {$_.platform -eq $platform})

    # Only platforms that actually have curated rows belong in this package.
    if($curatedRows.Count -eq 0){
        $priorityByPlatform[$platform]=@()
        continue
    }

    if($platform -eq 'Windows'){
        # Curated Windows Daily Chunks are the source of truth; Steam mapping below proves each row.
        $rows=@($curatedRows)
    } elseif($mode -ne 'igdb') {
        # DAT-backed systems: resolve each curated row against the EXISTING strict IGDB + DAT catalog.
        # Prefer genuine IGDB ID, then an unambiguous exact normalized catalog title. Never invent IDs.
        if(Test-Path -LiteralPath $catalogPath){
            try {
                $all=@((Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object {$_})
                $byId=@{}
                $byTitle=@{}
                foreach($g in $all){
                    $gid=Extract-IgdbId $g
                    if($gid -gt 0 -and -not $byId.ContainsKey([string]$gid)){ $byId[[string]$gid]=$g }
                    $nk=Norm ([string](Get-Prop $g 'title' ''))
                    if($nk){
                        if(!$byTitle.ContainsKey($nk)){ $byTitle[$nk]=New-Object 'System.Collections.Generic.List[object]' }
                        [void]$byTitle[$nk].Add($g)
                    }
                }
                $picked=New-Object 'System.Collections.Generic.List[object]'
                $usedIds=@{}
                $ord=0
                foreach($cr in $curatedRows){
                    $ord++
                    $chosen=$null
                    $wantId=Extract-IgdbId $cr
                    if($wantId -gt 0 -and $byId.ContainsKey([string]$wantId)){
                        $chosen=$byId[[string]$wantId]
                    } else {
                        $nk=Norm ([string](Get-Prop $cr 'title' ''))
                        if($nk -and $byTitle.ContainsKey($nk) -and $byTitle[$nk].Count -eq 1){ $chosen=$byTitle[$nk][0] }
                    }
                    if($null -eq $chosen){
                        if(!$Quiet){ Write-Warning ("[$platform] curated Daily Chunk is not in the verified IGDB + DAT catalog and was omitted: "+[string](Get-Prop $cr 'title' '')) }
                        continue
                    }
                    $gid=Extract-IgdbId $chosen
                    if($gid -le 0 -or $usedIds.ContainsKey([string]$gid)){ continue }
                    $copy=[ordered]@{}
                    foreach($prop in $chosen.PSObject.Properties){ $copy[$prop.Name]=$prop.Value }
                    $copy['curatedTitle']=[string](Get-Prop $cr 'title' '')
                $copy['dailyPriority']=$true
                    $copy['dailyOrder']=$ord
                    $copy['dailyChunk']=[string](Get-Prop $cr 'dailyChunk' '')
                    $copy['chunkMinutes']=To-Int (Get-Prop $cr 'minutes' 30)
                    $copy['chunkability']=To-Int (Get-Prop $cr 'chunkability' 4)
                    [void]$picked.Add([pscustomobject]$copy)
                    $usedIds[[string]$gid]=$true
                }
                $rows=@($picked.ToArray())
                if(!$Quiet -and $rows.Count -lt $curatedRows.Count){
                    Write-Warning ("[$platform] strict DAT rule kept {0}/{1} curated Daily Chunk rows." -f $rows.Count,$curatedRows.Count)
                }
            } catch {
                if(!$Quiet){ Write-Warning ("[$platform] could not read/resolve DAT-backed catalog: "+$_.Exception.Message) }
                $rows=@()
            }
        } elseif(!$Quiet) {
            Write-Warning "[$platform] no DAT-backed catalog exists, so no direct Daily Chunk index will be generated for it."
        }
    } else {
        # IGDB-only systems are strict: every direct-index row must have a genuine IGDB ID.
        # Reuse proven cached mappings, then resolve remaining exact curated titles through IGDB.
        $rows=@(Resolve-IgdbOnlyCuratedRows $platform $curatedRows $priorityPath)
    }
    $priorityByPlatform[$platform]=$rows
    if($platform -eq 'Windows'){ $windowsRowsForCache=$rows }
}
$windowsSteam=Ensure-WindowsSteamCache $windowsRowsForCache

# ---------- Featured games ----------
# Featured membership comes ONLY from featured-games-curated.json. Each platform is resolved
# against its own authoritative source. Invalid/ambiguous choices are omitted; nothing replaces them.
$featured=New-Object 'System.Collections.Generic.List[object]'
$featuredPlatformCounts=@{}
foreach($pcfg in @($config.platforms)){
    $platform=[string]$pcfg.name
    $mode=[string](Get-Prop $pcfg 'mode' '')
    $slug=State-Key $platform
    $curatedRows=@($featuredCurated | Where-Object { ([string](Get-Prop $_ 'platform' '')) -eq $platform })
    if($curatedRows.Count -eq 0){ continue }
    $resolved=@()
    if($platform -eq 'Windows' -or $mode -eq 'steam'){
        $resolved=@(Resolve-WindowsFeaturedRows $curatedRows)
    } elseif($mode -eq 'igdb'){
        $featuredPriorityPath=Join-Path $CacheRoot ('featured-priority-'+$slug+'-v1.json')
        $dailyPrioritySeed=Join-Path $CacheRoot ('daily-priority-'+$slug+'-v2.json')
        if(!(Test-Path -LiteralPath $featuredPriorityPath) -and (Test-Path -LiteralPath $dailyPrioritySeed)){
            Copy-Item -LiteralPath $dailyPrioritySeed -Destination $featuredPriorityPath -Force
        }
        $resolved=@(Resolve-IgdbOnlyCuratedRows $platform $curatedRows $featuredPriorityPath)
    } else {
        $catalogPath=Join-Path $CatalogRoot ($slug+'.json')
        $resolved=@(Resolve-FeaturedAgainstCatalog $platform $curatedRows $catalogPath)
    }

    $featuredOrder=0
    foreach($row in $resolved){
        $title=[string](Get-Prop $row 'title' (Get-Prop $row 'curatedTitle' ''))
        if([string]::IsNullOrWhiteSpace($title)){ continue }
        $gid=Extract-IgdbId $row
        $sid=[string](Get-Prop $row 'steamAppId' '')
        if($platform -eq 'Windows'){
            if($sid -notmatch '^\d+$'){ continue }
            $gid=0L
        } elseif($gid -le 0){
            continue
        }
        $featuredOrder++
        [void]$featured.Add([pscustomobject][ordered]@{
            platform=$platform
            title=$title
            igdbId=[long]$gid
            steamAppId=$sid
            controllerSupport=[string](Get-Prop $row 'controllerSupport' '')
            year=To-Int (Get-Prop $row 'releaseYear' (Get-Prop $row 'year' 0))
            rating=$(if($platform -eq 'Windows'){0.0}else{To-Double (Get-Prop $row 'rating' 0.0)})
            genreIds=@(Array-Of (Get-Prop $row 'catalogGenreIds' (Get-Prop $row 'genreIds' @())) | ForEach-Object {To-Int $_} | Where-Object {$_ -gt 0})
            genreNames=@(Array-Of (Get-Prop $row 'catalogGenres' (Get-Prop $row 'genreNames' @())) | ForEach-Object {[string]$_} | Where-Object {$_})
            coverUrl=[string](Get-Prop $row 'coverUrl' '')
            summary=[string](Get-Prop $row 'summary' '')
            featuredOrder=$featuredOrder
        })
        if(!$featuredPlatformCounts.ContainsKey($platform)){$featuredPlatformCounts[$platform]=0}
        $featuredPlatformCounts[$platform]++
    }
    if(!$Quiet -and $featuredOrder -lt $curatedRows.Count){
        Write-Warning ("[$platform] Featured validation kept {0}/{1} hand-curated choices; invalid/ambiguous entries were omitted and NOT replaced." -f $featuredOrder,$curatedRows.Count)
    }
}

foreach($pcfg in @($config.platforms)){
    $platform=[string]$pcfg.name
    $mode=[string](Get-Prop $pcfg 'mode' '')
    $rows=@($priorityByPlatform[$platform])
    $order=0
    foreach($row in $rows){
        $title=[string](Get-Prop $row 'title' '')
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $gid=Extract-IgdbId $row
        $sid=[string](Get-Prop $row 'steamAppId' '')
        $controller=[string](Get-Prop $row 'controllerSupport' '')

        # Every non-Windows Daily Chunk card is IGDB-backed. IGDB-only platforms may not use
        # title/hash fallback IDs; DAT-backed platforms already came from their verified catalog.
        if($platform -ne 'Windows' -and $gid -le 0){ continue }

        # Daily Chunk text priority is deliberately independent from selection/resolution:
        # exact game-specific curation > franchise rule. No generic fallback is allowed.
        $chunk=Resolve-DailyChunkDefinition $platform $title $row
        if($null -eq $chunk -or [string]::IsNullOrWhiteSpace([string](Get-Prop $chunk 'dailyChunk' ''))){ continue }

        if($platform -eq 'Windows'){
            $winKey=Get-WindowsSteamCacheKey $row
            if($windowsSteam.ContainsKey($winKey)){
                $sid=[string](Get-Prop $windowsSteam[$winKey] 'steamAppId' $sid)
                $controller=[string](Get-Prop $windowsSteam[$winKey] 'controllerSupport' $controller)
            }
        }
        # Windows is Steam-only. Unmapped titles are not valid for the direct Windows index.
        if($platform -eq 'Windows' -and [string]::IsNullOrWhiteSpace($sid)){continue}
        $order++
        $obj=[ordered]@{
            platform=$platform
            title=$title
            igdbId=[long]$gid
            steamAppId=$sid
            controllerSupport=$controller
            year=To-Int (Get-Prop $row 'releaseYear' (Get-Prop $row 'year' 0))
            rating=To-Double (Get-Prop $row 'rating' 0.0)
            genreIds=@(Array-Of (Get-Prop $row 'catalogGenreIds' (Get-Prop $row 'genreIds' @())) | ForEach-Object {To-Int $_} | Where-Object {$_ -gt 0})
            genreNames=@(Array-Of (Get-Prop $row 'catalogGenres' (Get-Prop $row 'genreNames' @())) | ForEach-Object {[string]$_} | Where-Object {$_})
            coverUrl=[string](Get-Prop $row 'coverUrl' '')
            summary=[string](Get-Prop $row 'summary' '')
            dailyChunk=[string](Get-Prop $chunk 'dailyChunk' '')
            minutes=To-Int (Get-Prop $chunk 'minutes' 30)
            chunkability=To-Int (Get-Prop $chunk 'chunkability' 4)
            chunkSource=[string](Get-Prop $chunk 'chunkSource' '')
            chunkRule=[string](Get-Prop $chunk 'chunkRule' '')
            dailyOrder=$order
        }
        [void]$direct.Add([pscustomobject]$obj)
        if(!$directPlatformCounts.ContainsKey($platform)){$directPlatformCounts[$platform]=0}
        $directPlatformCounts[$platform]++
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$packageChunks=@($direct.ToArray() | ForEach-Object { [pscustomobject]@{ id=([string]$_.platform+'::'+[string]$_.title); platform=[string]$_.platform; title=[string]$_.title; dailyChunk=[string]$_.dailyChunk; minutes=[int]$_.minutes; chunkability=[int]$_.chunkability } })
[IO.File]::WriteAllText($ChunksOut,($packageChunks | ConvertTo-Json -Depth 12 -Compress),$utf8NoBom)
[IO.File]::WriteAllText($SeriesOut,($series | ConvertTo-Json -Depth 12 -Compress),$utf8NoBom)
[IO.File]::WriteAllText($IndexOut,($direct.ToArray() | ConvertTo-Json -Depth 12 -Compress),$utf8NoBom)
[IO.File]::WriteAllText($FeaturedOut,($featured.ToArray() | ConvertTo-Json -Depth 12 -Compress),$utf8NoBom)

$counts = @($platformCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ platform=[string]$_.Name; chunks=[int]$_.Value }
})
$indexCounts=@($directPlatformCounts.GetEnumerator() | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ platform=[string]$_.Name; indexedGames=[int]$_.Value }
})
$featuredCounts=@($featuredPlatformCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]@{ platform=[string]$_.Name; featuredGames=[int]$_.Value } })
$chunkSourceCounts=@($direct.ToArray() | Group-Object chunkSource | Sort-Object Name | ForEach-Object { [pscustomobject]@{source=[string]$_.Name;games=[int]$_.Count} })
$manifest = [ordered]@{
    format = 'gamebrowser-daily-chunks-v3'
    schemaVersion = 3
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    totalChunks = $packageChunks.Count
    directIndexGames = $direct.Count
    gameSpecificRules = $gameSpecific.Count
    seriesRules = $series.Count
    chunkSourceCounts = $chunkSourceCounts
    platformCounts = $counts
    directIndexPlatformCounts = $indexCounts
    note = 'Independent Daily Chunk package. Daily Chunks are quality-only: exact game-specific rule, then franchise rule; there is NO generic/genre fallback. Featured Games are published separately in GameBrowser-Featured.zip.'
}
[IO.File]::WriteAllText($ManifestOut,($manifest | ConvertTo-Json -Depth 10),$utf8NoBom)

$featuredManifest = [ordered]@{
    format = 'gamebrowser-featured-v1'
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    featuredGames = $featured.Count
    featuredCuratedChoices = $featuredCurated.Count
    featuredPlatformCounts = $featuredCounts
    selectionPolicy = 'hand-curated-only'
    note = 'Featured membership comes ONLY from featured-games-curated.json. Ratings, Steam review scores, popularity and Daily Chunk order do not select or rank Featured games. Invalid/ambiguous entries are omitted without replacement.'
}
[IO.File]::WriteAllText($FeaturedManifestOut,($featuredManifest | ConvertTo-Json -Depth 10),$utf8NoBom)

if(Test-Path -LiteralPath $ZipOut){ Remove-Item -LiteralPath $ZipOut -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs=[IO.File]::Open($ZipOut,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $zip=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach($item in @(
        @{Path=$ChunksOut;Name='daily_chunks.json'},
        @{Path=$SeriesOut;Name='daily_chunk_series.json'},
        @{Path=$IndexOut;Name='daily_chunk_index.json'},
        @{Path=$ManifestOut;Name='manifest.json'}
    )) {
        $entry=$zip.CreateEntry($item.Name,[IO.Compression.CompressionLevel]::Optimal)
        $entryStream=$entry.Open();$input=[IO.File]::OpenRead($item.Path)
        try { $input.CopyTo($entryStream) } finally { $input.Dispose();$entryStream.Dispose() }
    }
    $zip.Dispose()
} finally { $fs.Dispose() }

$hash=(Get-FileHash -LiteralPath $ZipOut -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($HashOut,"$hash  GameBrowser-DailyChunks.zip`r`n",$utf8NoBom)

if(Test-Path -LiteralPath $FeaturedZipOut){ Remove-Item -LiteralPath $FeaturedZipOut -Force }
$ffs=[IO.File]::Open($FeaturedZipOut,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $fzip=New-Object IO.Compression.ZipArchive($ffs,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach($item in @(
        @{Path=$FeaturedOut;Name='featured_game_index.json'},
        @{Path=$FeaturedManifestOut;Name='manifest.json'}
    )) {
        $entry=$fzip.CreateEntry($item.Name,[IO.Compression.CompressionLevel]::Optimal)
        $entryStream=$entry.Open();$input=[IO.File]::OpenRead($item.Path)
        try { $input.CopyTo($entryStream) } finally { $input.Dispose();$entryStream.Dispose() }
    }
    $fzip.Dispose()
} finally { $ffs.Dispose() }
$featuredHash=(Get-FileHash -LiteralPath $FeaturedZipOut -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($FeaturedHashOut,"$featuredHash  GameBrowser-Featured.zip`r`n",$utf8NoBom)
$size=(Get-Item -LiteralPath $ZipOut).Length
Write-Host ''
Write-Host ("Daily Chunk package ready: {0:N0} quality chunks across {1:N0} systems" -f $packageChunks.Count,$directPlatformCounts.Count) -ForegroundColor Green
Write-Host ("Direct Daily Chunk index: {0:N0} validated quality games" -f $direct.Count) -ForegroundColor Green
Write-Host ("Featured index: {0:N0}/{1:N0} hand-curated choices validated across {2:N0} systems" -f $featured.Count,$featuredCurated.Count,$featuredPlatformCounts.Count) -ForegroundColor Green
foreach($cs in $chunkSourceCounts){ Write-Host ("  {0}: {1:N0}" -f $cs.source,$cs.games) -ForegroundColor DarkGray }
if($directPlatformCounts.ContainsKey('Windows')){
    $win=@($direct.ToArray() | Where-Object {$_.platform -eq 'Windows'})
    $full=@($win | Where-Object {$_.controllerSupport -eq 'Full Controller Support'}).Count
    $partial=@($win | Where-Object {$_.controllerSupport -eq 'Partial Controller Support'}).Count
    $other=$win.Count-$full-$partial
    Write-Host ("Windows indexed: {0} total | {1} Full | {2} Partial | {3} All-only/unflagged" -f $win.Count,$full,$partial,$other) -ForegroundColor DarkGray
}
Write-Host ("Daily Chunk file: {0}" -f $ZipOut) -ForegroundColor Green
Write-Host ("Daily Chunk size: {0:N1} MB" -f ($size/1MB)) -ForegroundColor DarkGray
Write-Host ("Daily Chunk SHA-256: {0}" -f $hash) -ForegroundColor DarkGray
$featuredSize=(Get-Item -LiteralPath $FeaturedZipOut).Length
Write-Host ("Featured file: {0}" -f $FeaturedZipOut) -ForegroundColor Green
Write-Host ("Featured size: {0:N1} MB" -f ($featuredSize/1MB)) -ForegroundColor DarkGray
Write-Host ("Featured SHA-256: {0}" -f $featuredHash) -ForegroundColor DarkGray
Write-Host ''
