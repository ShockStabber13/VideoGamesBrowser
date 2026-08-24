param(
    [switch]$ForceRebuild,
    [int]$BatchSize = 500
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Android = Join-Path $Root '_android'
$CacheRoot = Join-Path $Root '_cache\windows-steam-index-no-adult-v1'
$SteamConfigPath = Join-Path $Root 'steam-config.json'
$Endpoint = 'https://api.steampowered.com/IStoreQueryService/Query/v1/'
$BatchSize = [Math]::Max(1,[Math]::Min(500,$BatchSize))
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$GenreMap = [ordered]@{
    4=1743; 5=1774; 7=1621; 8=1625; 9=1664; 10=699; 11=1676; 12=122; 13=599; 14=701;
    15=9; 16=1741; 24=1708; 25=1646; 26=10437; 30=1038; 31=21; 32=492; 33=1773; 34=3799;
    35=1770; 36=1718; 2=1698
}

function Get-Prop($Object,[string]$Name,$Default=$null){
    if($null -eq $Object){ return $Default }
    $p=$Object.PSObject.Properties[$Name]
    if($null -eq $p){ return $Default }
    return $p.Value
}
function Write-AtomicText([string]$Path,[string]$Text){
    $dir=Split-Path -Parent $Path
    if($dir -and !(Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp=$Path+'.tmp'
    [IO.File]::WriteAllText($tmp,$Text,$Utf8NoBom)
    if(Test-Path -LiteralPath $Path){ Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Get-SystemCountry {
    try {
        $code=[Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName.ToUpperInvariant()
        if($code -match '^[A-Z]{2}$'){ return $code }
    } catch {}
    return 'SG'
}
function Get-SteamConfig {
    $api=''; $country=Get-SystemCountry
    if(Test-Path -LiteralPath $SteamConfigPath){
        try {
            $cfg=Get-Content -LiteralPath $SteamConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $api=[string](Get-Prop $cfg 'ApiKey' (Get-Prop $cfg 'Key' ''))
            $cc=[string](Get-Prop $cfg 'CountryCode' '')
            if($cc.Trim().ToUpperInvariant() -match '^[A-Z]{2}$'){ $country=$cc.Trim().ToUpperInvariant() }
        } catch {}
    }
    return [pscustomobject]@{ApiKey=$api.Trim();CountryCode=$country}
}
function New-TypeFilters {
    return [ordered]@{
        include_apps=$true; include_packages=$false; include_bundles=$false; include_games=$true;
        include_demos=$false; include_mods=$false; include_dlc=$false; include_software=$false;
        include_video=$false; include_hardware=$false; include_series=$false; include_music=$false
    }
}
function New-InputJson([int]$Start,[int]$Count,[string]$Country,[bool]$IncludeReviews=$true){
    $payload=[ordered]@{
        query_name='GameBrowser_Windows_Index_PC'
        query=[ordered]@{
            start=$Start; count=$Count; sort=2
            filters=[ordered]@{type_filters=(New-TypeFilters)}
        }
        context=[ordered]@{language='english';country_code=$Country;steam_realm=1}
        data_request=[ordered]@{
            include_assets=$false; include_release=$true; include_platforms=$true; include_tag_count=20;
            include_basic_info=$true; include_reviews=$IncludeReviews; include_supported_languages=$false;
            include_full_description=$false; include_screenshots=$false; include_trailers=$false; apply_user_filters=$false
        }
        override_country_code=$Country
    }
    return ($payload | ConvertTo-Json -Depth 12 -Compress)
}
function Invoke-StoreQuery([int]$Start,[int]$Count,[string]$Country,[string]$ApiKey){
    $last='Unknown Steam error'
    foreach($includeReviews in @($true,$false)){
        $json=New-InputJson $Start $Count $Country $includeReviews
        $encoded=[Uri]::EscapeDataString($json)
        $auth=@()
        if(-not [string]::IsNullOrWhiteSpace($ApiKey)){ $auth += $ApiKey }
        $auth += ''
        foreach($key in $auth){
            $url=$Endpoint+'?input_json='+$encoded+'&format=json'
            if(-not [string]::IsNullOrWhiteSpace($key)){ $url += '&key='+[Uri]::EscapeDataString($key) }
            for($attempt=1;$attempt -le 4;$attempt++){
                try {
                    return Invoke-RestMethod -Method Get -Uri $url -UseBasicParsing -Headers @{
                        'User-Agent'='GameBrowser-Windows-Index-Builder/1.0';'Accept'='application/json,text/plain,*/*';'Accept-Language'='en-US,en;q=0.9'
                    } -TimeoutSec 60
                } catch {
                    $last=$_.Exception.Message
                    $status=$null; try{$status=[int]$_.Exception.Response.StatusCode}catch{}
                    if($status -eq 429 -or ($status -ge 500 -and $status -le 599)){
                        Start-Sleep -Seconds ([Math]::Min(12,1+$attempt*2)); continue
                    }
                    break
                }
            }
        }
    }
    throw $last
}
function Get-ReviewPercent($Reviews){
    if($null -eq $Reviews){ return 0.0 }
    foreach($name in @('summary_filtered','summary_unfiltered','summary_language_specific')){
        $s=Get-Prop $Reviews $name $null; if($null -eq $s){continue}
        $pct=Get-Prop $s 'percent_positive' $null
        if($null -ne $pct){ try { $d=[double]$pct; if($d -ge 0 -and $d -le 100){ return $d } } catch {} }
        $pos=Get-Prop $s 'total_positive' 0; $neg=Get-Prop $s 'total_negative' 0
        try{ $p=[double]$pos;$n=[double]$neg;if(($p+$n)-gt 0){return 100.0*$p/($p+$n)}}catch{}
    }
    foreach($name in @('percent_positive','positive_percent','review_score_percent')){
        $v=Get-Prop $Reviews $name $null
        if($null -ne $v){try{$d=[double]$v;if($d -ge 0 -and $d -le 100){return $d}}catch{}}
    }
    return 0.0
}
function Get-UnixYear([int64]$Seconds){
    if($Seconds -le 0){return 0}
    try{return [DateTimeOffset]::FromUnixTimeSeconds($Seconds).UtcDateTime.Year}catch{return 0}
}
function Get-IntArray($Value){
    $out=New-Object 'System.Collections.Generic.List[int]'
    if($null -eq $Value){return $out.ToArray()}
    foreach($v in @($Value)){
        if($null -eq $v){continue}
        try{$n=[int]$v;if($n -gt 0){$out.Add($n)}}catch{}
    }
    return $out.ToArray()
}
function Convert-Batch($Response){
    $root=Get-Prop $Response 'response' $Response
    $meta=Get-Prop $root 'metadata' $null
    $total=0;$serverStart=0;$serverCount=0
    if($null -ne $meta){
        try{$total=[int](Get-Prop $meta 'total_matching_records' 0)}catch{}
        try{$serverStart=[int](Get-Prop $meta 'start' 0)}catch{}
        try{$serverCount=[int](Get-Prop $meta 'count' 0)}catch{}
    }
    $ids=@(Get-Prop $root 'ids' @())
    $items=Get-Prop $root 'store_items' $null
    if($null -eq $items){$items=Get-Prop $root 'items' @()}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    foreach($item in @($items)){
        $appId=Get-Prop $item 'appid' $null; $title=[string](Get-Prop $item 'name' '')
        if($null -eq $appId -or [string]::IsNullOrWhiteSpace($title)){continue}
        try{$appId=[int64]$appId}catch{continue}
        if($appId -le 0){continue}

        # Steam's official content descriptors are more reliable than community tags.
        # 3 = Adult Only Sexual Content; 4 = Frequent/Gratuitous Nudity or Sexual Content.
        # Keep ordinary mature/violent games; omit only explicitly sexual adult titles.
        $explicitAdult=$false
        foreach($descriptor in @(Get-Prop $item 'content_descriptorids' @())){
            try {
                $did=[int]$descriptor
                if($did -eq 3 -or $did -eq 4){$explicitAdult=$true;break}
            } catch {}
        }
        if($explicitAdult){continue}

        $platforms=Get-Prop $item 'platforms' $null
        if($null -ne $platforms){
            $win=Get-Prop $platforms 'windows' $false
            if(-not [bool]$win){continue}
        }
        $title=[Net.WebUtility]::HtmlDecode($title).Trim() -replace '\s+',' '
        if([string]::IsNullOrWhiteSpace($title)){continue}
        $categories=Get-Prop $item 'categories' $null
        $controllerIds=Get-IntArray (Get-Prop $categories 'controller_categoryids' @())
        $controllerMode=0
        if($controllerIds -contains 28){$controllerMode=2}elseif($controllerIds -contains 18){$controllerMode=1}
        $tagIds=New-Object 'System.Collections.Generic.HashSet[int]'
        foreach($t in @(Get-Prop $item 'tagids' @())){try{$n=[int]$t;if($n -gt 0){[void]$tagIds.Add($n)}}catch{}}
        if($tagIds.Count -eq 0){
            foreach($t in @(Get-Prop $item 'tags' @())){
                try{$n=[int](Get-Prop $t 'tagid' 0);if($n -gt 0){[void]$tagIds.Add($n)}}catch{}
            }
        }
        $genreIds=New-Object 'System.Collections.Generic.List[int]'
        foreach($pair in $GenreMap.GetEnumerator()){
            if($tagIds.Contains([int]$pair.Value)){$genreIds.Add([int]$pair.Key)}
        }
        $release=Get-Prop $item 'release' $null
        $unix=0L
        if($null -ne $release){
            $raw=Get-Prop $release 'original_release_date' $null
            if($null -eq $raw -or [int64]$raw -le 0){$raw=Get-Prop $release 'steam_release_date' $null}
            if($null -ne $raw){try{$unix=[int64]$raw}catch{}}
        }
        $review=Get-ReviewPercent (Get-Prop $item 'reviews' $null)
        $rows.Add([ordered]@{
            appid=$appId; title=$title; year=(Get-UnixYear $unix); release_date=$unix;
            review_percent=[Math]::Round([double]$review,4); genre_ids=(@($genreIds.ToArray() | Sort-Object -Unique) -join ','); controller_mode=$controllerMode
        })
    }
    $rawCount=$ids.Count
    if($rawCount -le 0){$rawCount=@($items).Count}
    if($serverCount -le 0){$serverCount=$rawCount}
    $advance=[Math]::Max($serverCount,$rawCount)
    $hasMore=if($total -gt 0 -and $advance -gt 0){($serverStart+$advance)-lt $total}else{$advance -gt 0}
    return [pscustomobject]@{Rows=$rows.ToArray();Total=$total;ServerStart=$serverStart;Advance=$advance;NextStart=($serverStart+$advance);HasMore=$hasMore;RawCount=$rawCount}
}
function Read-State([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){return $null}
    try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json}catch{return $null}
}
function Save-State([string]$Path,$State){ Write-AtomicText $Path ($State | ConvertTo-Json -Depth 8) }
function Format-Elapsed([TimeSpan]$T){ return ('{0:00}:{1:00}:{2:00}' -f [int]$T.TotalHours,$T.Minutes,$T.Seconds) }

$cfg=Get-SteamConfig
$Country=$cfg.CountryCode
$CountryCache=Join-Path $CacheRoot $Country
$BatchDir=Join-Path $CountryCache 'batches'
$StatePath=Join-Path $CountryCache 'state.json'
$PackageData=Join-Path $CountryCache 'windows_steam_index.ndjson'
$ManifestPath=Join-Path $CountryCache 'windows_steam_index_manifest.json'
$OutputZip=Join-Path $Android 'GameBrowser-Windows.zip'
New-Item -ItemType Directory -Force -Path $Android,$BatchDir | Out-Null

if($ForceRebuild -and (Test-Path -LiteralPath $CountryCache)){
    Remove-Item -LiteralPath $CountryCache -Recurse -Force
    New-Item -ItemType Directory -Force -Path $BatchDir | Out-Null
}
$state=Read-State $StatePath
if($null -ne $state -and [bool](Get-Prop $state 'complete' $false) -and -not $ForceRebuild){
    Write-Host ''
    Write-Host ('Windows Steam index is already complete for store {0}: {1:N0} games.' -f $Country,[int](Get-Prop $state 'indexed' 0)) -ForegroundColor Green
    Write-Host 'Use FORCE REBUILD WINDOWS INDEX.bat if you intentionally want to crawl the full StoreQuery catalog again.' -ForegroundColor DarkGray
    if(Test-Path -LiteralPath $OutputZip){ Write-Host ('Package: {0}' -f $OutputZip) -ForegroundColor Cyan; exit 0 }
    if((Test-Path -LiteralPath $PackageData) -and (Test-Path -LiteralPath $ManifestPath)){
        Write-Host 'Package ZIP is missing; recreating it from the completed local index without crawling Steam again...' -ForegroundColor Yellow
        $stage=Join-Path $CountryCache '_package_stage'
        if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Copy-Item -LiteralPath $PackageData -Destination (Join-Path $stage 'windows_steam_index.ndjson') -Force
        Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $stage 'windows_steam_index_manifest.json') -Force
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutputZip -CompressionLevel Optimal -Force
        Remove-Item -LiteralPath $stage -Recurse -Force
        Write-Host ('Package: {0}' -f $OutputZip) -ForegroundColor Cyan
        exit 0
    }
    throw 'Completed Windows index state exists, but its package data is missing. Run FORCE REBUILD WINDOWS INDEX.bat.'
}

$start=0;$total=0;$indexed=0;$startedAt=(Get-Date).ToUniversalTime().ToString('o')
if($null -ne $state -and -not [bool](Get-Prop $state 'complete' $false)){
    try{$start=[int](Get-Prop $state 'next_start' 0)}catch{}
    try{$total=[int](Get-Prop $state 'total' 0)}catch{}
    try{$indexed=[int](Get-Prop $state 'indexed' 0)}catch{}
    $savedStarted=[string](Get-Prop $state 'started_at' '')
    if($savedStarted){$startedAt=$savedStarted}
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '             WINDOWS STEAM INDEX BUILD' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ('Store country : {0}' -f $Country)
Write-Host ('Source        : IStoreQueryService/Query (game-type apps; explicit adult sexual content excluded)')
Write-Host ('Ordering      : sort=2 / AppID identifier order')
Write-Host ('Batch size    : {0}' -f $BatchSize)
Write-Host ('Checkpoint    : {0}' -f $StatePath)
if($start -gt 0){Write-Host ('RESUME        : raw offset {0:N0}; already indexed {1:N0} Windows games' -f $start,$indexed) -ForegroundColor Yellow}
else{Write-Host 'RESUME        : new build' -ForegroundColor DarkGray}
Write-Host ''

$sw=[Diagnostics.Stopwatch]::StartNew()
$current=$start
$batchNumber=[int][Math]::Floor($current/[double]$BatchSize)+1
while($true){
    $response=Invoke-StoreQuery $current $BatchSize $Country $cfg.ApiKey
    $batch=Convert-Batch $response
    if($batch.Total -gt 0){$total=$batch.Total}
    if($batch.Advance -le 0){break}

    # Save this batch atomically BEFORE advancing the resume checkpoint.
    $batchPath=Join-Path $BatchDir ('batch-{0:D9}.ndjson' -f $current)
    $sb=New-Object Text.StringBuilder
    foreach($row in @($batch.Rows)){[void]$sb.AppendLine(($row | ConvertTo-Json -Compress -Depth 5))}
    Write-AtomicText $batchPath $sb.ToString()

    $indexed += @($batch.Rows).Count
    $current=$batch.NextStart
    $pct=if($total -gt 0){[Math]::Min(100.0,100.0*$current/$total)}else{0.0}
    $rate=if($sw.Elapsed.TotalSeconds -gt 0){($current-$start)/$sw.Elapsed.TotalSeconds}else{0}
    $remaining=''
    if($total -gt 0 -and $rate -gt 0){
        $sec=[Math]::Max(0,($total-$current)/$rate)
        $remaining=(' | remaining ~{0}' -f (Format-Elapsed ([TimeSpan]::FromSeconds($sec))))
    }
    $msg=('Processed {0:N0}/{1:N0} raw ({2:0.0}%) | Windows indexed {3:N0} | batch {4} | elapsed {5} | {6:0.0} raw/s{7}' -f $current,$total,$pct,$indexed,$batchNumber,(Format-Elapsed $sw.Elapsed),$rate,$remaining)
    Write-Host $msg -ForegroundColor Cyan
    $state=[ordered]@{
        schema=1; country=$Country; source='IStoreQueryService/Query'; sort=2; batch_size=$BatchSize;
        next_start=$current; total=$total; indexed=$indexed; complete=$false; started_at=$startedAt;
        updated_at=(Get-Date).ToUniversalTime().ToString('o'); last_batch=('batch-{0:D9}.ndjson' -f ($batch.ServerStart))
    }
    Save-State $StatePath $state
    $batchNumber++
    if(-not $batch.HasMore){break}
    Start-Sleep -Milliseconds 120
}

Write-Host ''
Write-Host '[WINDOWS] Finalising cached batches into Android package...' -ForegroundColor Cyan
$tmpData=$PackageData+'.tmp'
$writer=New-Object IO.StreamWriter($tmpData,$false,$Utf8NoBom)
$finalCount=0
try{
    $files=@(Get-ChildItem -LiteralPath $BatchDir -Filter 'batch-*.ndjson' -File | Sort-Object Name)
    foreach($file in $files){
        $reader=New-Object IO.StreamReader($file.FullName,[Text.Encoding]::UTF8,$true)
        try{
            while(($line=$reader.ReadLine()) -ne $null){
                if([string]::IsNullOrWhiteSpace($line)){continue}
                $writer.WriteLine($line);$finalCount++
            }
        } finally {$reader.Dispose()}
    }
} finally {$writer.Dispose()}
if(Test-Path -LiteralPath $PackageData){Remove-Item -LiteralPath $PackageData -Force}
Move-Item -LiteralPath $tmpData -Destination $PackageData -Force

$generatedNow=(Get-Date).ToUniversalTime()
$generated=$generatedNow.ToString('o')
$generatedEpoch=[DateTimeOffset]$generatedNow
$generatedEpoch=$generatedEpoch.ToUnixTimeSeconds()
$manifest=[ordered]@{
    schema=1; package='GameBrowser-Windows'; generated_at=$generated; generated_epoch=$generatedEpoch; country=$Country;
    source='Steam IStoreQueryService/Query'; source_sort=2; game_count=$finalCount; raw_total=$total;
    fields=@('appid','title','year','release_date','review_percent','genre_ids','controller_mode')
}
Write-AtomicText $ManifestPath ($manifest | ConvertTo-Json -Depth 8)

$stage=Join-Path $CountryCache '_package_stage'
if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item -LiteralPath $PackageData -Destination (Join-Path $stage 'windows_steam_index.ndjson') -Force
Copy-Item -LiteralPath $ManifestPath -Destination (Join-Path $stage 'windows_steam_index_manifest.json') -Force
if(Test-Path -LiteralPath $OutputZip){Remove-Item -LiteralPath $OutputZip -Force}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutputZip -CompressionLevel Optimal -Force
Remove-Item -LiteralPath $stage -Recurse -Force
$hash=(Get-FileHash -LiteralPath $OutputZip -Algorithm SHA256).Hash.ToLowerInvariant()

$state=[ordered]@{
    schema=1; country=$Country; source='IStoreQueryService/Query'; sort=2; batch_size=$BatchSize;
    next_start=$current; total=$total; indexed=$finalCount; complete=$true; started_at=$startedAt;
    completed_at=$generated; updated_at=$generated; package_sha256=$hash
}
Save-State $StatePath $state

Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host 'WINDOWS STEAM INDEX READY' -ForegroundColor Green
Write-Host ('Games       : {0:N0}' -f $finalCount)
Write-Host ('Raw records : {0:N0}' -f $total)
Write-Host ('Store       : {0}' -f $Country)
Write-Host ('File        : {0}' -f $OutputZip)
Write-Host ('Size        : {0:N1} MB' -f ((Get-Item -LiteralPath $OutputZip).Length/1MB))
Write-Host ('SHA-256     : {0}' -f $hash)
Write-Host 'The batch cache/checkpoint is kept so an interrupted build can resume.' -ForegroundColor DarkGray
