param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('DailyChunks','Featured')]
    [string]$Package
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutRoot = Join-Path $RepoRoot '_android'
New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Prop($Object,[string]$Name,$Default=$null) {
    if($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function To-Long($Value) { try { return [long]$Value } catch { return 0L } }
function To-Int($Value) { try { return [int]$Value } catch { return 0 } }
function To-Double($Value) { try { return [double]$Value } catch { return 0.0 } }

function Read-JsonArray([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required curated file is missing: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "Curated file is empty: $Path" }
    try { $value = $raw | ConvertFrom-Json } catch { throw "Invalid JSON in $Path : $($_.Exception.Message)" }
    return @($value | ForEach-Object { $_ })
}

function Write-Zip([string]$ZipPath, [array]$Files) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $fs = [IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $zip = New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create,$false)
        try {
            foreach ($item in $Files) {
                $entry = $zip.CreateEntry([string]$item.Name,[IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                $input = [IO.File]::OpenRead([string]$item.Path)
                try { $input.CopyTo($entryStream) } finally { $input.Dispose(); $entryStream.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function Get-CompactIdentity($row) {
    $title = ([string](Get-Prop $row 'title' (Get-Prop $row 'name' ''))).Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { return $null }

    $source = ([string](Get-Prop $row 'source' '')).Trim()
    $platform = ([string](Get-Prop $row 'platform' '')).Trim()
    $idValue = Get-Prop $row 'id' $null

    if ($source -eq 'Steam') {
        $sid = ([string]$idValue).Trim()
        if ($sid -notmatch '^\d+$') { $sid = ([string](Get-Prop $row 'steamAppId' '')).Trim() }
        if ($sid -notmatch '^\d+$') { return $null }
        return [pscustomobject]@{ title=$title; source='Steam'; id=[long]$sid; platform='Windows' }
    }
    if ($source -like 'IGDB:*') {
        $p = $source.Substring(5).Trim()
        $gid = To-Long $idValue
        if ($gid -le 0) { $gid = To-Long (Get-Prop $row 'igdbId' 0) }
        if ([string]::IsNullOrWhiteSpace($p) -or $gid -le 0) { return $null }
        return [pscustomobject]@{ title=$title; source=('IGDB:'+$p); id=[long]$gid; platform=$p }
    }

    # Legacy rich curated rows remain accepted and are rewritten to the compact schema.
    $sid = ([string](Get-Prop $row 'steamAppId' '')).Trim()
    if ($sid -match '^\d+$') {
        return [pscustomobject]@{ title=$title; source='Steam'; id=[long]$sid; platform='Windows' }
    }
    $gid = To-Long (Get-Prop $row 'igdbId' 0)
    if ($gid -gt 0 -and -not [string]::IsNullOrWhiteSpace($platform)) {
        return [pscustomobject]@{ title=$title; source=('IGDB:'+$platform); id=[long]$gid; platform=$platform }
    }
    return $null
}

function Get-ReleaseEpoch($row) {
    $epoch = To-Long (Get-Prop $row 'releaseDateEpoch' 0)
    if ($epoch -gt 0) { return $epoch }
    $epoch = To-Long (Get-Prop $row 'first_release_date' 0)
    if ($epoch -gt 100000000) { return $epoch }

    $year = To-Int (Get-Prop $row 'releaseYear' (Get-Prop $row 'year' 0))
    if ($year -le 0) { return 0L }
    try {
        $date = [DateTime]::new($year,1,1,0,0,0,[DateTimeKind]::Utc)
        return [DateTimeOffset]::new($date).ToUnixTimeSeconds()
    } catch { return 0L }
}

function New-CompactIndex([array]$Rows,[bool]$Daily) {
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $identity = Get-CompactIdentity $row
        if ($null -eq $identity) { throw "Curated index contains a row without a valid Steam/IGDB identity: $([string](Get-Prop $row 'title' (Get-Prop $row 'name' '<untitled>')))" }

        $rating = To-Double (Get-Prop $row 'rating' (Get-Prop $row 'steamReviewScore' (Get-Prop $row 'reviewScore' 0.0)))
        if ($rating -lt 0) { $rating = 0.0 }
        $releaseDateEpoch = Get-ReleaseEpoch $row

        $obj = [ordered]@{
            title = [string]$identity.title
            source = [string]$identity.source
            id = [long]$identity.id
            rating = [double]$rating
            releaseDateEpoch = [long]$releaseDateEpoch
        }
        if ($Daily) {
            $chunk = ([string](Get-Prop $row 'dailyChunk' '')).Trim()
            if ([string]::IsNullOrWhiteSpace($chunk)) { throw "Daily Chunk row has no dailyChunk text: $($identity.title)" }
            $obj['dailyChunk'] = $chunk
            $obj['minutes'] = [int](To-Int (Get-Prop $row 'minutes' (Get-Prop $row 'chunkMinutes' 30)))
            if ($obj['minutes'] -lt 10) { $obj['minutes'] = 10 }
            $chunkability = To-Int (Get-Prop $row 'chunkability' (Get-Prop $row 'fit' 4))
            if ($chunkability -gt 5) { $chunkability = [Math]::Ceiling($chunkability / 2.0) }
            $obj['chunkability'] = [int]([Math]::Max(1,[Math]::Min(5,$chunkability)))
        }
        [void]$out.Add([pscustomobject]$obj)
    }
    return $out.ToArray()
}

function Stable-Identity($row) {
    $identity = Get-CompactIdentity $row
    if ($null -eq $identity) { return '' }
    return (([string]$identity.source).ToLowerInvariant()+'::'+[string]$identity.id)
}

function Platform-Of($row) {
    $identity = Get-CompactIdentity $row
    if ($null -eq $identity) { return 'Unknown' }
    return [string]$identity.platform
}

if ($Package -eq 'DailyChunks') {
    $SourceRoot = Join-Path $RepoRoot '_curated\daily-chunks'
    $ChunksPath = Join-Path $SourceRoot 'daily_chunks.json'
    $SeriesPath = Join-Path $SourceRoot 'daily_chunk_series.json'
    $IndexSourcePath  = Join-Path $SourceRoot 'daily_chunk_index.json'

    $chunks = Read-JsonArray $ChunksPath
    $series = Read-JsonArray $SeriesPath
    $indexSource = Read-JsonArray $IndexSourcePath
    if ($chunks.Count -eq 0) { throw 'daily_chunks.json contains no curated games.' }
    if ($indexSource.Count -eq 0)  { throw 'daily_chunk_index.json contains no curated games.' }

    # Rich curation files may carry provenance. If present, reject generic/genre-generated rows.
    $bad = @($indexSource | Where-Object {
        $source = ([string](Get-Prop $_ 'chunkSource' '')).Trim()
        $source -and $source -notin @('game-specific','franchise')
    })
    if ($bad.Count -gt 0) {
        throw "Daily Chunk index contains $($bad.Count) non-curated/generic source entries. Allowed: game-specific, franchise."
    }

    $index = @(New-CompactIndex $indexSource $true)
    $dupes = @($index | Group-Object { Stable-Identity $_ } | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) { throw "Daily Chunk index contains $($dupes.Count) duplicate game identities." }

    $sourceCounts = @($indexSource | Group-Object {
        $v=([string](Get-Prop $_ 'chunkSource' '')).Trim(); if($v){$v}else{'curated'}
    } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ source=[string]$_.Name; games=[int]$_.Count }
    })
    $platformCounts = @($index | Group-Object { Platform-Of $_ } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ platform=[string]$_.Name; indexedGames=[int]$_.Count }
    })

    $IndexOut = Join-Path $OutRoot 'daily_chunk_index.json'
    [IO.File]::WriteAllText($IndexOut,($index | ConvertTo-Json -Depth 8 -Compress),$utf8NoBom)

    $manifest = [ordered]@{
        format = 'gamebrowser-daily-chunks-v4'
        schemaVersion = 4
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        totalChunks = $chunks.Count
        directIndexGames = $index.Count
        seriesRules = $series.Count
        chunkSourceCounts = $sourceCounts
        directIndexPlatformCounts = $platformCounts
        selectionPolicy = 'human-curated-only'
        indexSchema = 'source + id + title + rating + releaseDateEpoch + dailyChunk + minutes + chunkability'
        note = 'Publish-only package. GitHub strips all nonessential direct-index metadata. No generic/genre auto-fill.'
    }
    $ManifestPath = Join-Path $OutRoot 'daily_chunks_manifest.json'
    [IO.File]::WriteAllText($ManifestPath,($manifest | ConvertTo-Json -Depth 10),$utf8NoBom)

    $ZipPath = Join-Path $OutRoot 'GameBrowser-DailyChunks.zip'
    Write-Zip $ZipPath @(
        @{Path=$ChunksPath;Name='daily_chunks.json'},
        @{Path=$SeriesPath;Name='daily_chunk_series.json'},
        @{Path=$IndexOut;Name='daily_chunk_index.json'},
        @{Path=$ManifestPath;Name='manifest.json'}
    )
    $HashPath = Join-Path $OutRoot 'GameBrowser-DailyChunks.sha256'
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($HashPath,"$hash  GameBrowser-DailyChunks.zip`r`n",$utf8NoBom)
    Write-Host "Packaged $($index.Count) compact curated Daily Chunk games."
    Write-Host "ZIP: $ZipPath"
    exit 0
}

$SourceRoot = Join-Path $RepoRoot '_curated\featured'
$IndexSourcePath = Join-Path $SourceRoot 'featured_game_index.json'
$featuredSource = Read-JsonArray $IndexSourcePath
if ($featuredSource.Count -eq 0) { throw 'featured_game_index.json contains no curated games.' }

$featured = @(New-CompactIndex $featuredSource $false)
$dupes = @($featured | Group-Object { Stable-Identity $_ } | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) { throw "Featured index contains $($dupes.Count) duplicate game identities." }

$platformCounts = @($featured | Group-Object { Platform-Of $_ } | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ platform=[string]$_.Name; featuredGames=[int]$_.Count }
})
$over50 = @($platformCounts | Where-Object { $_.featuredGames -gt 50 })
if ($over50.Count -gt 0) {
    $names = ($over50 | ForEach-Object { "$($_.platform)=$($_.featuredGames)" }) -join ', '
    throw "Featured exceeds the 50-per-platform ceiling: $names"
}

$IndexOut = Join-Path $OutRoot 'featured_game_index.json'
[IO.File]::WriteAllText($IndexOut,($featured | ConvertTo-Json -Depth 8 -Compress),$utf8NoBom)

$manifest = [ordered]@{
    format = 'gamebrowser-featured-v2'
    schemaVersion = 2
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    featuredGames = $featured.Count
    featuredPlatformCounts = $platformCounts
    selectionPolicy = 'hand-curated-only'
    indexSchema = 'source + id + title + rating + releaseDateEpoch'
    note = 'Publish-only package. GitHub strips all nonessential Featured metadata; ratings never select membership.'
}
$ManifestPath = Join-Path $OutRoot 'featured_manifest.json'
[IO.File]::WriteAllText($ManifestPath,($manifest | ConvertTo-Json -Depth 10),$utf8NoBom)

$ZipPath = Join-Path $OutRoot 'GameBrowser-Featured.zip'
Write-Zip $ZipPath @(
    @{Path=$IndexOut;Name='featured_game_index.json'},
    @{Path=$ManifestPath;Name='manifest.json'}
)
$HashPath = Join-Path $OutRoot 'GameBrowser-Featured.sha256'
$hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($HashPath,"$hash  GameBrowser-Featured.zip`r`n",$utf8NoBom)
Write-Host "Packaged $($featured.Count) compact hand-curated Featured games."
Write-Host "ZIP: $ZipPath"
