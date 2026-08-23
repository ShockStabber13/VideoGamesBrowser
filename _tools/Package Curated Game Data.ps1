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

function Stable-Identity($row) {
    $platform = [string]$row.platform
    $steam = [string]$row.steamAppId
    $igdb = 0L
    try { $igdb = [long]$row.igdbId } catch { $igdb = 0L }
    if (![string]::IsNullOrWhiteSpace($steam)) { return "${platform}::steam::${steam}" }
    if ($igdb -gt 0) { return "${platform}::igdb::${igdb}" }
    return "${platform}::title::$([string]$row.title)"
}

if ($Package -eq 'DailyChunks') {
    $SourceRoot = Join-Path $RepoRoot '_curated\daily-chunks'
    $ChunksPath = Join-Path $SourceRoot 'daily_chunks.json'
    $SeriesPath = Join-Path $SourceRoot 'daily_chunk_series.json'
    $IndexPath  = Join-Path $SourceRoot 'daily_chunk_index.json'

    $chunks = Read-JsonArray $ChunksPath
    $series = Read-JsonArray $SeriesPath
    $index  = Read-JsonArray $IndexPath
    if ($chunks.Count -eq 0) { throw 'daily_chunks.json contains no curated games.' }
    if ($index.Count -eq 0)  { throw 'daily_chunk_index.json contains no curated games.' }

    $bad = @($index | Where-Object { ([string]$_.chunkSource) -notin @('game-specific','franchise') })
    if ($bad.Count -gt 0) {
        throw "Daily Chunk index contains $($bad.Count) non-curated/generic source entries. Allowed: game-specific, franchise."
    }

    $dupes = @($index | Group-Object { Stable-Identity $_ } | Where-Object { $_.Count -gt 1 })
    if ($dupes.Count -gt 0) { throw "Daily Chunk index contains $($dupes.Count) duplicate game identities." }

    $sourceCounts = @($index | Group-Object chunkSource | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ source=[string]$_.Name; games=[int]$_.Count }
    })
    $platformCounts = @($index | Group-Object platform | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ platform=[string]$_.Name; indexedGames=[int]$_.Count }
    })
    $manifest = [ordered]@{
        format = 'gamebrowser-daily-chunks-v3'
        schemaVersion = 3
        generatedAt = (Get-Date).ToUniversalTime().ToString('o')
        totalChunks = $chunks.Count
        directIndexGames = $index.Count
        gameSpecificRules = @($index | Where-Object { $_.chunkSource -eq 'game-specific' }).Count
        seriesRules = $series.Count
        chunkSourceCounts = $sourceCounts
        directIndexPlatformCounts = $platformCounts
        selectionPolicy = 'human-curated-only'
        note = 'Publish-only package. Membership and chunk text are curated before push; GitHub performs validation and packaging only. No generic/genre auto-fill.'
    }
    $ManifestPath = Join-Path $OutRoot 'daily_chunks_manifest.json'
    [IO.File]::WriteAllText($ManifestPath,($manifest | ConvertTo-Json -Depth 10),$utf8NoBom)

    $ZipPath = Join-Path $OutRoot 'GameBrowser-DailyChunks.zip'
    Write-Zip $ZipPath @(
        @{Path=$ChunksPath;Name='daily_chunks.json'},
        @{Path=$SeriesPath;Name='daily_chunk_series.json'},
        @{Path=$IndexPath;Name='daily_chunk_index.json'},
        @{Path=$ManifestPath;Name='manifest.json'}
    )
    $HashPath = Join-Path $OutRoot 'GameBrowser-DailyChunks.sha256'
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($HashPath,"$hash  GameBrowser-DailyChunks.zip`r`n",$utf8NoBom)
    Write-Host "Packaged $($index.Count) curated Daily Chunk games."
    Write-Host "ZIP: $ZipPath"
    exit 0
}

$SourceRoot = Join-Path $RepoRoot '_curated\featured'
$IndexPath = Join-Path $SourceRoot 'featured_game_index.json'
$featured = Read-JsonArray $IndexPath
if ($featured.Count -eq 0) { throw 'featured_game_index.json contains no curated games.' }

$dupes = @($featured | Group-Object { Stable-Identity $_ } | Where-Object { $_.Count -gt 1 })
if ($dupes.Count -gt 0) { throw "Featured index contains $($dupes.Count) duplicate game identities." }

$platformCounts = @($featured | Group-Object platform | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ platform=[string]$_.Name; featuredGames=[int]$_.Count }
})
$over50 = @($platformCounts | Where-Object { $_.featuredGames -gt 50 })
if ($over50.Count -gt 0) {
    $names = ($over50 | ForEach-Object { "$($_.platform)=$($_.featuredGames)" }) -join ', '
    throw "Featured exceeds the 50-per-platform ceiling: $names"
}

$manifest = [ordered]@{
    format = 'gamebrowser-featured-v1'
    schemaVersion = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    featuredGames = $featured.Count
    featuredPlatformCounts = $platformCounts
    selectionPolicy = 'hand-curated-only'
    note = 'Publish-only package. Featured membership is curated before push. GitHub does not select, rank, score, substitute or auto-fill games.'
}
$ManifestPath = Join-Path $OutRoot 'featured_manifest.json'
[IO.File]::WriteAllText($ManifestPath,($manifest | ConvertTo-Json -Depth 10),$utf8NoBom)

$ZipPath = Join-Path $OutRoot 'GameBrowser-Featured.zip'
Write-Zip $ZipPath @(
    @{Path=$IndexPath;Name='featured_game_index.json'},
    @{Path=$ManifestPath;Name='manifest.json'}
)
$HashPath = Join-Path $OutRoot 'GameBrowser-Featured.sha256'
$hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText($HashPath,"$hash  GameBrowser-Featured.zip`r`n",$utf8NoBom)
Write-Host "Packaged $($featured.Count) hand-curated Featured games."
Write-Host "ZIP: $ZipPath"
