param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$PlatformsPath = Join-Path $Root 'platforms.json'
$CatalogRoot = Join-Path $Root '_cache\platform-catalogs'
$OutRoot = Join-Path $Root '_android'
$CatalogOut = Join-Path $OutRoot 'game_catalog.json'
$ManifestOut = Join-Path $OutRoot 'manifest.json'
$ZipOut = Join-Path $OutRoot 'GameBrowser-Data.zip'
$HashOut = Join-Path $OutRoot 'GameBrowser-Data.sha256'

New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null

function State-Key([string]$Platform) {
    $k=($Platform.ToLowerInvariant() -replace '[^a-z0-9]+','_').Trim('_')
    if([string]::IsNullOrWhiteSpace($k)){ throw "Invalid platform name: $Platform" }
    return $k
}
function Num($Value, $Default=0) {
    if($null -eq $Value){ return $Default }
    try { return $Value } catch { return $Default }
}
function Array-Of($Value) {
    if($null -eq $Value){ return @() }
    return @($Value | ForEach-Object { $_ })
}
function Get-Prop($Object,[string]$Name,$Default=$null) {
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

$config = Get-Content -LiteralPath $PlatformsPath -Raw -Encoding UTF8 | ConvertFrom-Json
$datModes = @('redump','nointro','dat','other')
$staticPlatforms = @($config.platforms | Where-Object { [string]$_.mode -in $datModes })
$modernPlatforms = @($config.platforms | Where-Object { [string]$_.mode -eq 'igdb' } | ForEach-Object { [string]$_.name })
$steamPlatforms = @($config.platforms | Where-Object { [string]$_.mode -eq 'steam' } | ForEach-Object { [string]$_.name })

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter($CatalogOut,$false,$utf8NoBom,1048576)
$counts = New-Object 'System.Collections.Generic.List[object]'
$total = 0
$first = $true
$writer.Write('[')
try {
    foreach($cfg in $staticPlatforms) {
        $platform = [string]$cfg.name
        $path = Join-Path $CatalogRoot ((State-Key $platform)+'.json')
        if(!(Test-Path -LiteralPath $path)) {
            Write-Warning "[$platform] no platform cache yet: $path"
            [void]$counts.Add([pscustomobject]@{ platform=$platform; games=0; ready=$false })
            continue
        }
        $rows = @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) | ForEach-Object { $_ })
        $written = 0
        foreach($row in $rows) {
            $igdbId = [long](Get-Prop $row 'igdbId' 0)
            $title = [string](Get-Prop $row 'title' '')
            if($igdbId -le 0 -or [string]::IsNullOrWhiteSpace($title)){ continue }

            $obj = [ordered]@{
                id = 0
                igdbId = $igdbId
                title = $title
                platform = $platform
                year = [int](Get-Prop $row 'releaseYear' 0)
                rating = [double](Get-Prop $row 'rating' 0.0)
                genreIds = @(Array-Of (Get-Prop $row 'catalogGenreIds' @()) | ForEach-Object { [int]$_ })
                genreNames = @(Array-Of (Get-Prop $row 'catalogGenres' @()) | ForEach-Object { [string]$_ })
                coverUrl = $(if($row.PSObject.Properties['coverUrl'] -and $row.coverUrl){[string]$row.coverUrl}else{$null})
                summary = $(if($row.PSObject.Properties['summary']){[string]$row.summary}else{''})
                controllerSupport = $null
                catalogSource = 'IGDB + ANY DAT'
                matchedDatSources = @(Array-Of (Get-Prop $row 'preservationMatchedSources' @()) | ForEach-Object { [string]$_ })
            }
            $json = $obj | ConvertTo-Json -Depth 12 -Compress
            if(!$first){ $writer.Write(',') } else { $first=$false }
            $writer.Write($json)
            $written++; $total++
        }
        [void]$counts.Add([pscustomobject]@{ platform=$platform; games=$written; ready=($written -gt 0) })
        if(!$Quiet){ Write-Host ("[{0}] {1:N0} games" -f $platform,$written) -ForegroundColor DarkGray }
        Remove-Variable rows -ErrorAction SilentlyContinue
        [GC]::Collect(0)
    }
} finally {
    $writer.Write(']')
    $writer.Dispose()
}

$manifest = [ordered]@{
    format = 'gamebrowser-windows-catalog-v1'
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    totalGames = $total
    datBackedPlatforms = $counts.Count
    igdbOnlyPlatforms = $modernPlatforms
    steamPlatforms = $steamPlatforms
    platformCounts = $counts.ToArray()
    note = 'Contains DAT-backed platform catalogs only. Steam platforms and IGDB-only platforms remain live/on-demand on Android. Daily Chunks are distributed separately in GameBrowser-DailyChunks.zip.'
}
$manifestJson = $manifest | ConvertTo-Json -Depth 10
[IO.File]::WriteAllText($ManifestOut,$manifestJson,$utf8NoBom)

if(Test-Path -LiteralPath $ZipOut){ Remove-Item -LiteralPath $ZipOut -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs=[IO.File]::Open($ZipOut,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try {
    $zip=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create,$false)
    foreach($item in @(
        @{Path=$CatalogOut;Name='game_catalog.json'},
        @{Path=$ManifestOut;Name='manifest.json'}
    )) {
        $entry=$zip.CreateEntry($item.Name,[IO.Compression.CompressionLevel]::Optimal)
        $entryStream=$entry.Open()
        $input=[IO.File]::OpenRead($item.Path)
        try { $input.CopyTo($entryStream) } finally { $input.Dispose();$entryStream.Dispose() }
    }
    $zip.Dispose()
} finally { $fs.Dispose() }

$hash=(Get-FileHash -LiteralPath $ZipOut -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($HashOut,"$hash  GameBrowser-Data.zip`r`n",$utf8NoBom)
$size=(Get-Item -LiteralPath $ZipOut).Length
Write-Host ''
Write-Host ("Android database ready: {0:N0} games" -f $total) -ForegroundColor Green
Write-Host ("File: {0}" -f $ZipOut) -ForegroundColor Green
Write-Host ("Size: {0:N1} MB" -f ($size/1MB)) -ForegroundColor DarkGray
Write-Host ("SHA-256: {0}" -f $hash) -ForegroundColor DarkGray
Write-Host ''
