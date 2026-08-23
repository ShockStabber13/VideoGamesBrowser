param(
    [string]$OutputDirectory = '_android\igdb-platform-index'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-RequiredValue {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable $Name is missing."
    }
    return $value.Trim()
}

function Convert-UnixDate {
    param($Value, [switch]$DateOnly)
    if ($null -eq $Value) { return '' }
    $n = 0L
    if (-not [long]::TryParse([string]$Value, [ref]$n)) { return '' }
    if ($n -le 0) { return '' }
    $dt = [DateTimeOffset]::FromUnixTimeSeconds($n).UtcDateTime
    if ($DateOnly) { return $dt.ToString('yyyy-MM-dd') }
    return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Invoke-IgdbRequest {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $uri = "https://api.igdb.com/v4/$Endpoint"
    for ($attempt = 1; $attempt -le 7; $attempt++) {
        try {
            $result = Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers -Body $Body -ContentType 'text/plain; charset=utf-8' -TimeoutSec 120
            Start-Sleep -Milliseconds 350
            return @($result)
        }
        catch {
            if ($attempt -ge 7) { throw }
            $delay = [Math]::Min(20, [Math]::Pow(2, $attempt))
            Write-Warning "IGDB $Endpoint request failed (attempt $attempt/7): $($_.Exception.Message). Retrying in $delay second(s)..."
            Start-Sleep -Seconds $delay
        }
    }
}

$clientId = Get-RequiredValue 'IGDB_CLIENT_ID'
$clientSecret = Get-RequiredValue 'IGDB_CLIENT_SECRET'

Write-Host 'Requesting Twitch app access token...' -ForegroundColor Cyan
$tokenResponse = Invoke-RestMethod -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -Body @{
    client_id = $clientId
    client_secret = $clientSecret
    grant_type = 'client_credentials'
} -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 60

if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.access_token)) {
    throw 'Twitch returned no access token.'
}

$headers = @{
    'Client-ID' = $clientId
    'Authorization' = "Bearer $($tokenResponse.access_token)"
    'Accept' = 'application/json'
}

$OutputDirectory = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputDirectory))
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$csvPath = Join-Path $OutputDirectory 'igdb-games-platforms.csv'
$platformCsvPath = Join-Path $OutputDirectory 'igdb-platforms.csv'
$manifestPath = Join-Path $OutputDirectory 'manifest.json'
$zipPath = Join-Path (Split-Path $OutputDirectory -Parent) 'GameBrowser-IGDB-Platform-Index.zip'
$shaPath = "$zipPath.sha256"

foreach ($p in @($csvPath, $platformCsvPath, $manifestPath, $zipPath, $shaPath)) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
}

Write-Host 'Downloading IGDB platform table...' -ForegroundColor Cyan
$platformRows = New-Object System.Collections.Generic.List[object]
$platformById = @{}
$lastPlatformId = 0L
while ($true) {
    $body = "fields id,name,abbreviation,slug; where id > $lastPlatformId; sort id asc; limit 500;"
    $page = @(Invoke-IgdbRequest -Endpoint 'platforms' -Body $body -Headers $headers)
    if ($page.Count -eq 0) { break }

    foreach ($p in $page) {
        $pid = [long]$p.id
        $row = [pscustomobject][ordered]@{
            platform_id = $pid
            platform_name = [string]$p.name
            abbreviation = [string]$p.abbreviation
            slug = [string]$p.slug
        }
        $platformRows.Add($row)
        $platformById[[string]$pid] = $row
        if ($pid -gt $lastPlatformId) { $lastPlatformId = $pid }
    }
    if ($page.Count -lt 500) { break }
}

$platformRows | Export-Csv -LiteralPath $platformCsvPath -NoTypeInformation -Encoding utf8
Write-Host ("Platforms: {0:N0}" -f $platformRows.Count) -ForegroundColor Green

Write-Host 'Scanning all IGDB games with platform membership...' -ForegroundColor Cyan
$lastGameId = 0L
$gameCount = 0L
$rowCount = 0L
$pageNumber = 0
$headerWritten = $false
$started = [DateTimeOffset]::UtcNow

while ($true) {
    $body = @"
fields id,name,slug,game_type,version_parent,platforms,release_dates.platform,release_dates.date,first_release_date,updated_at;
where id > $lastGameId & platforms != null;
sort id asc;
limit 500;
"@

    $page = @(Invoke-IgdbRequest -Endpoint 'games' -Body $body -Headers $headers)
    if ($page.Count -eq 0) { break }

    $pageNumber++
    $pageRows = New-Object System.Collections.Generic.List[object]

    foreach ($g in $page) {
        $gid = [long]$g.id
        if ($gid -gt $lastGameId) { $lastGameId = $gid }
        $gameCount++

        $releaseByPlatform = @{}
        foreach ($rd in @($g.release_dates)) {
            if ($null -eq $rd) { continue }
            $pidText = [string]$rd.platform
            $dateText = [string]$rd.date
            if ([string]::IsNullOrWhiteSpace($pidText) -or [string]::IsNullOrWhiteSpace($dateText)) { continue }
            $dateValue = 0L
            if (-not [long]::TryParse($dateText, [ref]$dateValue)) { continue }
            if ($dateValue -le 0) { continue }
            if (-not $releaseByPlatform.ContainsKey($pidText) -or $dateValue -lt [long]$releaseByPlatform[$pidText]) {
                $releaseByPlatform[$pidText] = $dateValue
            }
        }

        $firstDate = Convert-UnixDate $g.first_release_date -DateOnly
        $firstYear = if ($firstDate.Length -ge 4) { $firstDate.Substring(0,4) } else { '' }
        $updatedAt = Convert-UnixDate $g.updated_at

        $seenPlatforms = @{}
        foreach ($pidRaw in @($g.platforms)) {
            if ($null -eq $pidRaw) { continue }
            $pid = [long]$pidRaw
            $pidText = [string]$pid
            if ($seenPlatforms.ContainsKey($pidText)) { continue }
            $seenPlatforms[$pidText] = $true

            $platform = $platformById[$pidText]
            $platformDate = ''
            if ($releaseByPlatform.ContainsKey($pidText)) {
                $platformDate = Convert-UnixDate $releaseByPlatform[$pidText] -DateOnly
            }
            $platformYear = if ($platformDate.Length -ge 4) { $platformDate.Substring(0,4) } else { '' }

            $pageRows.Add([pscustomobject][ordered]@{
                game_id = $gid
                title = [string]$g.name
                slug = [string]$g.slug
                platform_id = $pid
                platform_name = if ($null -ne $platform) { [string]$platform.platform_name } else { '' }
                platform_abbreviation = if ($null -ne $platform) { [string]$platform.abbreviation } else { '' }
                release_date = $platformDate
                release_year = $platformYear
                first_release_date = $firstDate
                first_release_year = $firstYear
                game_type_id = if ($null -ne $g.game_type) { [string]$g.game_type } else { '' }
                version_parent_id = if ($null -ne $g.version_parent) { [string]$g.version_parent } else { '' }
                updated_at = $updatedAt
            })
            $rowCount++
        }
    }

    if ($pageRows.Count -gt 0) {
        $lines = @($pageRows | ConvertTo-Csv -NoTypeInformation)
        if (-not $headerWritten) {
            $lines | Set-Content -LiteralPath $csvPath -Encoding utf8
            $headerWritten = $true
        }
        elseif ($lines.Count -gt 1) {
            $lines | Select-Object -Skip 1 | Add-Content -LiteralPath $csvPath -Encoding utf8
        }
    }

    $elapsed = [DateTimeOffset]::UtcNow - $started
    Write-Host ("Page {0:N0} | games {1:N0} | game-platform rows {2:N0} | last IGDB id {3:N0} | elapsed {4:hh\:mm\:ss}" -f $pageNumber,$gameCount,$rowCount,$lastGameId,$elapsed) -ForegroundColor DarkCyan

    if ($page.Count -lt 500) { break }
}

if (-not $headerWritten) {
    throw 'IGDB returned no games with platforms; index was not created.'
}

$generatedAt = [DateTimeOffset]::UtcNow
$manifest = [ordered]@{
    format = 'VideoGamesBrowser IGDB game-platform index v1'
    generated_at_utc = $generatedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    source = 'IGDB API v4'
    games_with_platforms = $gameCount
    game_platform_rows = $rowCount
    platform_count = $platformRows.Count
    files = @(
        'igdb-games-platforms.csv',
        'igdb-platforms.csv'
    )
    columns = @(
        'game_id','title','slug','platform_id','platform_name','platform_abbreviation',
        'release_date','release_year','first_release_date','first_release_year',
        'game_type_id','version_parent_id','updated_at'
    )
    notes = @(
        'One CSV row is emitted for each IGDB game/platform membership.',
        'release_date is the earliest platform-specific IGDB release date when available.',
        'first_release_date is the game-level first release date.',
        'No posters, screenshots, summaries, ratings or descriptions are included.'
    )
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host 'Packaging index...' -ForegroundColor Cyan
Compress-Archive -Path $csvPath,$platformCsvPath,$manifestPath -DestinationPath $zipPath -CompressionLevel Optimal -Force
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($zipPath))" | Set-Content -LiteralPath $shaPath -Encoding ascii

Write-Host ''
Write-Host 'IGDB platform index complete.' -ForegroundColor Green
Write-Host ("Games: {0:N0}" -f $gameCount)
Write-Host ("Game/platform rows: {0:N0}" -f $rowCount)
Write-Host ("Platforms: {0:N0}" -f $platformRows.Count)
Write-Host "ZIP: $zipPath"
Write-Host "SHA256: $shaPath"
