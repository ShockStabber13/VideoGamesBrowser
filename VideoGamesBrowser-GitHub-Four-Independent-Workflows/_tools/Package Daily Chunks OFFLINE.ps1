param()
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Out=Join-Path $Root '_android'
$Chunks=Join-Path $Root 'daily-chunks.json'
$Series=Join-Path $Root 'daily-chunk-series.json'
$Index=Join-Path $Out 'daily_chunk_index.json'
$Featured=Join-Path $Out 'featured_game_index.json'
$Platforms=Join-Path $Root 'platforms.json'
$CatalogRoot=Join-Path $Root '_cache\platform-catalogs'
if(!(Test-Path -LiteralPath $Chunks)){throw 'daily-chunks.json missing'}
if(!(Test-Path -LiteralPath $Series)){throw 'daily-chunk-series.json missing'}
if(!(Test-Path -LiteralPath $Index)){throw '_android\daily_chunk_index.json missing'}
if(!(Test-Path -LiteralPath $Featured)){throw '_android\featured_game_index.json missing; run the normal Daily Chunks + Featured build once before OFFLINE repack'}
if(!(Test-Path -LiteralPath $Platforms)){throw 'platforms.json missing'}
$utf8=New-Object System.Text.UTF8Encoding($false)
$c=@((Get-Content -LiteralPath $Chunks -Raw -Encoding UTF8|ConvertFrom-Json)|ForEach-Object{$_})
$s=@((Get-Content -LiteralPath $Series -Raw -Encoding UTF8|ConvertFrom-Json)|ForEach-Object{$_})
$i=@((Get-Content -LiteralPath $Index -Raw -Encoding UTF8|ConvertFrom-Json)|ForEach-Object{$_})
$f=@((Get-Content -LiteralPath $Featured -Raw -Encoding UTF8|ConvertFrom-Json)|ForEach-Object{$_})
$pcfg=Get-Content -LiteralPath $Platforms -Raw -Encoding UTF8|ConvertFrom-Json

function State-Key([string]$p){return (($p.ToLowerInvariant() -replace '[^a-z0-9]+','_').Trim('_'))}
function NT([string]$t){
    if([string]::IsNullOrWhiteSpace($t)){return ''}
    $x=$t.Normalize([Text.NormalizationForm]::FormD)
    $sb=New-Object Text.StringBuilder
    foreach($ch in $x.ToCharArray()){
        if([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark){[void]$sb.Append($ch)}
    }
    $x=$sb.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $x=$x -replace '[™®©]',''
    return (($x -replace '[^a-z0-9]+',' ').Trim() -replace '\s+',' ')
}
function NK([string]$p,[string]$t){return ($p.ToLowerInvariant()+'::'+(NT $t))}
function Get-Prop($o,[string]$n,$d=$null){if($null -ne $o -and $o.PSObject.Properties[$n]){return $o.$n};return $d}

$modeByPlatform=@{}
foreach($p in @($pcfg.platforms)){$modeByPlatform[[string]$p.name]=[string]$p.mode}
$catalogIds=@{}
function Get-CatalogIds([string]$platform){
    if($catalogIds.ContainsKey($platform)){return $catalogIds[$platform]}
    $ids=@{}
    $path=Join-Path $CatalogRoot ((State-Key $platform)+'.json')
    if(Test-Path -LiteralPath $path){
        foreach($r in @((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json)|ForEach-Object{$_})){
            $id=0L;try{$id=[long](Get-Prop $r 'igdbId' 0)}catch{}
            if($id -gt 0){$ids[[string]$id]=$true}
        }
    }
    $catalogIds[$platform]=$ids
    return $ids
}

$lookup=@{}
foreach($x in $c){$lookup[(NK ([string]$x.platform) ([string]$x.title))]=$x}
$kept=New-Object 'System.Collections.Generic.List[object]'
foreach($x in $i){
    $platform=[string](Get-Prop $x 'platform' '')
    $title=[string](Get-Prop $x 'title' '')
    if([string]::IsNullOrWhiteSpace($platform) -or [string]::IsNullOrWhiteSpace($title)){continue}

    # Re-validate the preservation rule during an offline repack. A stale direct index can never
    # smuggle a DAT-backed title into the package just because it already existed in _android.
    $mode=[string]$modeByPlatform[$platform]
    if($platform -eq 'Windows'){
        if([string]::IsNullOrWhiteSpace([string](Get-Prop $x 'steamAppId' ''))){continue}
    } elseif($mode -eq 'igdb') {
        # Offline mode cannot resolve missing IDs. An IGDB-only row is retained only when the
        # previously built direct index already contains a genuine positive IGDB ID.
        $gid=0L;try{$gid=[long](Get-Prop $x 'igdbId' 0)}catch{}
        if($gid -le 0){continue}
    } else {
        $gid=0L;try{$gid=[long](Get-Prop $x 'igdbId' 0)}catch{}
        $ids=Get-CatalogIds $platform
        if($gid -le 0 -or -not $ids.ContainsKey([string]$gid)){continue}
    }

    # Quality-only policy: an offline repack must never resurrect the old genre/generic fallback.
    $source=[string](Get-Prop $x 'chunkSource' '')
    if($source -ne 'game-specific' -and $source -ne 'franchise'){ continue }
    if([string]::IsNullOrWhiteSpace([string](Get-Prop $x 'dailyChunk' ''))) { continue }
    [void]$kept.Add($x)
}

$featuredKept=New-Object 'System.Collections.Generic.List[object]'
foreach($x in $f){
    $platform=[string](Get-Prop $x 'platform' '')
    $title=[string](Get-Prop $x 'title' '')
    if([string]::IsNullOrWhiteSpace($platform) -or [string]::IsNullOrWhiteSpace($title)){continue}
    $mode=[string]$modeByPlatform[$platform]
    if($platform -eq 'Windows'){
        if(([string](Get-Prop $x 'steamAppId' '')) -notmatch '^\d+$'){continue}
    } elseif($mode -eq 'igdb') {
        $gid=0L;try{$gid=[long](Get-Prop $x 'igdbId' 0)}catch{}
        if($gid -le 0){continue}
    } else {
        $gid=0L;try{$gid=[long](Get-Prop $x 'igdbId' 0)}catch{}
        $ids=Get-CatalogIds $platform
        if($gid -le 0 -or -not $ids.ContainsKey([string]$gid)){continue}
    }
    [void]$featuredKept.Add($x)
}

$compat=@($kept.ToArray()|ForEach-Object{[pscustomobject]@{id=([string]$_.platform+'::'+[string]$_.title);platform=[string]$_.platform;title=[string]$_.title;dailyChunk=[string]$_.dailyChunk;minutes=[int](Get-Prop $_ 'minutes' 30);chunkability=[int](Get-Prop $_ 'chunkability' 4)}})
[IO.File]::WriteAllText((Join-Path $Out 'daily_chunks.json'),($compat|ConvertTo-Json -Depth 12 -Compress),$utf8)
[IO.File]::WriteAllText((Join-Path $Out 'daily_chunk_series.json'),($s|ConvertTo-Json -Depth 12 -Compress),$utf8)
[IO.File]::WriteAllText($Index,($kept.ToArray()|ConvertTo-Json -Depth 12 -Compress),$utf8)
[IO.File]::WriteAllText($Featured,($featuredKept.ToArray()|ConvertTo-Json -Depth 12 -Compress),$utf8)
$counts=@($compat|Group-Object platform|Sort-Object Name|ForEach-Object{[pscustomobject]@{platform=$_.Name;chunks=$_.Count}})
$ic=@($kept.ToArray()|Group-Object platform|Sort-Object Name|ForEach-Object{[pscustomobject]@{platform=$_.Name;indexedGames=$_.Count}})
$fc=@($featuredKept.ToArray()|Group-Object platform|Sort-Object Name|ForEach-Object{[pscustomobject]@{platform=$_.Name;featuredGames=$_.Count}})
$m=[ordered]@{
    format='gamebrowser-daily-chunks-v3';schemaVersion=3;generatedAt=(Get-Date).ToUniversalTime().ToString('o')
    totalChunks=$compat.Count;directIndexGames=$kept.Count;featuredGames=$featuredKept.Count;seriesRules=$s.Count
    platformCounts=$counts;directIndexPlatformCounts=$ic;featuredPlatformCounts=$fc
    note='OFFLINE repack only. Daily Chunks retain only game-specific/franchise rules; generic/genre fallback is rejected. Featured is carried only from the previously validated featured_game_index.json and is never auto-filled. Windows requires Steam AppID; IGDB-only rows require positive IGDB IDs; DAT-backed rows require IDs present in the local catalog. No network/API/build scans.'
}
[IO.File]::WriteAllText((Join-Path $Out 'manifest.json'),($m|ConvertTo-Json -Depth 10),$utf8)
[IO.File]::WriteAllText((Join-Path $Out 'daily_chunks_manifest.json'),($m|ConvertTo-Json -Depth 10),$utf8)
$zip=Join-Path $Out 'GameBrowser-DailyChunks.zip'
if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip -Force}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs=[IO.File]::Open($zip,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $za=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach($fn in @('daily_chunks.json','daily_chunk_series.json','daily_chunk_index.json','featured_game_index.json','manifest.json')){
        $src=Join-Path $Out $fn;$e=$za.CreateEntry($fn,[IO.Compression.CompressionLevel]::Optimal)
        $es=$e.Open();$ins=[IO.File]::OpenRead($src)
        try{$ins.CopyTo($es)}finally{$ins.Dispose();$es.Dispose()}
    }
    $za.Dispose()
}finally{$fs.Dispose()}
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText((Join-Path $Out 'GameBrowser-DailyChunks.sha256'),"$hash  GameBrowser-DailyChunks.zip`r`n",$utf8)
Write-Host ''
Write-Host ("OFFLINE package ready: {0} quality chunks / {1} indexed games / {2} Featured games" -f $compat.Count,$kept.Count,$featuredKept.Count) -ForegroundColor Green
Write-Host 'No Steam / controller / IGDB / DAT network lookup was performed.' -ForegroundColor Green
