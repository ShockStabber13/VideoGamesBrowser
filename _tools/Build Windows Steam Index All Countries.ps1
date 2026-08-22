param(
    [switch]$ForceRebuild,
    [int]$BatchSize = 500,
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Tools = Join-Path $Root '_tools'
$Android = Join-Path $Root '_android'
$CacheRoot = Join-Path $Root '_cache\windows-steam-index'
$SteamConfigPath = Join-Path $Root 'steam-config.json'
$BuilderScript = Join-Path $Tools 'Build Windows Steam Index.ps1'
$GenericZip = Join-Path $Android 'GameBrowser-Windows.zip'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

$Countries = @(
    [pscustomobject]@{ Label='US'; SteamCode='US'; FileTag='US'; Display='United States' },
    [pscustomobject]@{ Label='UK'; SteamCode='GB'; FileTag='UK'; Display='United Kingdom' },
    [pscustomobject]@{ Label='SG'; SteamCode='SG'; FileTag='SG'; Display='Singapore' },
    [pscustomobject]@{ Label='CA'; SteamCode='CA'; FileTag='CA'; Display='Canada' },
    [pscustomobject]@{ Label='MY'; SteamCode='MY'; FileTag='MY'; Display='Malaysia' }
)

function Write-AtomicText([string]$Path,[string]$Text){
    $dir=Split-Path -Parent $Path
    if($dir -and !(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir | Out-Null}
    $tmp=$Path+'.tmp'
    [IO.File]::WriteAllText($tmp,$Text,$Utf8NoBom)
    if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
function Read-JsonFile([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){return $null}
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}
function Set-SteamCountry([string]$CountryCode){
    $obj = Read-JsonFile $SteamConfigPath
    $hash = [ordered]@{}
    if($null -ne $obj){
        foreach($p in $obj.PSObject.Properties){ $hash[$p.Name] = $p.Value }
    }
    $hash['CountryCode'] = $CountryCode
    Write-AtomicText $SteamConfigPath ($hash | ConvertTo-Json -Depth 8)
}
function Zip-Info([string]$Path){
    if(!(Test-Path -LiteralPath $Path)){ return $null }
    $hash=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return [pscustomobject]@{Path=$Path; SizeMB=[Math]::Round((Get-Item -LiteralPath $Path).Length/1MB,1); Sha256=$hash}
}

if(!(Test-Path -LiteralPath $BuilderScript)){
    throw "Required script not found: $BuilderScript"
}
New-Item -ItemType Directory -Force -Path $Android,$CacheRoot | Out-Null

# Preserve the user's current steam-config.json exactly. If it did not exist, delete our temporary file at the end.
$hadSteamConfig = Test-Path -LiteralPath $SteamConfigPath
$originalSteamConfigText = $null
if($hadSteamConfig){ $originalSteamConfigText = Get-Content -LiteralPath $SteamConfigPath -Raw -Encoding UTF8 }

if($Only -and $Only.Count -gt 0){
    $wanted = @{}
    foreach($o in $Only){ if($o){ $wanted[$o.Trim().ToUpperInvariant()] = $true } }
    $Countries = @($Countries | Where-Object { $wanted.ContainsKey($_.Label) -or $wanted.ContainsKey($_.SteamCode) -or $wanted.ContainsKey($_.FileTag) })
    if($Countries.Count -eq 0){ throw ('No matching countries found for: ' + ($Only -join ', ')) }
}

$results = New-Object 'System.Collections.Generic.List[object]'
$started = (Get-Date).ToUniversalTime().ToString('o')

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '        WINDOWS STEAM INDEX - COUNTRY PACKAGE BUILD' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ('Countries : {0}' -f (($Countries | ForEach-Object { if($_.SteamCode -eq 'GB'){'UK/GB'}else{$_.SteamCode} }) -join ', '))
Write-Host 'Source    : existing Build Windows Steam Index.ps1 / StoreQuery'
Write-Host 'Resume    : per-country cache/checkpoint'
Write-Host ''

try {
    foreach($c in $Countries){
        Write-Host ''
        Write-Host ('==================== {0} ({1}) ====================' -f $c.Label,$c.SteamCode) -ForegroundColor Yellow
        Set-SteamCountry $c.SteamCode

        # Important: the underlying builder always writes GameBrowser-Windows.zip.
        # Delete the generic file before each run so completed country caches are repackaged for the correct country.
        if(Test-Path -LiteralPath $GenericZip){Remove-Item -LiteralPath $GenericZip -Force}

        $args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$BuilderScript,'-BatchSize',[string]$BatchSize)
        if($ForceRebuild){$args += '-ForceRebuild'}
        & powershell.exe @args
        if($LASTEXITCODE -ne 0){ throw "Build Windows Steam Index.ps1 failed for $($c.Label) / $($c.SteamCode) with exit code $LASTEXITCODE" }
        if(!(Test-Path -LiteralPath $GenericZip)){ throw "Expected package was not created for $($c.Label): $GenericZip" }

        $countryZip = Join-Path $Android ('GameBrowser-Windows-{0}.zip' -f $c.FileTag)
        Copy-Item -LiteralPath $GenericZip -Destination $countryZip -Force

        # UK uses Steam country code GB. Create a GB alias too, for code-oriented Android builds/tools.
        if($c.SteamCode -eq 'GB'){
            $gbAlias = Join-Path $Android 'GameBrowser-Windows-GB.zip'
            Copy-Item -LiteralPath $GenericZip -Destination $gbAlias -Force
        }

        $info=Zip-Info $countryZip
        $results.Add([pscustomobject]@{Country=$c.Label;SteamCode=$c.SteamCode;File=(Split-Path -Leaf $countryZip);SizeMB=$info.SizeMB;Sha256=$info.Sha256}) | Out-Null
        Write-Host ('Created: {0} ({1:N1} MB)' -f $countryZip,$info.SizeMB) -ForegroundColor Green
    }

    # Keep old Android builds compatible: make the generic GameBrowser-Windows.zip the SG package if SG was built or already exists.
    $sgZip = Join-Path $Android 'GameBrowser-Windows-SG.zip'
    if(Test-Path -LiteralPath $sgZip){
        Copy-Item -LiteralPath $sgZip -Destination $GenericZip -Force
    }

    $completed = (Get-Date).ToUniversalTime().ToString('o')
    $report = Join-Path $Android 'GameBrowser-Windows-Country-Packages-Report.txt'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add('GAMEBROWSER WINDOWS COUNTRY PACKAGE BUILD REPORT')
    [void]$lines.Add("Started UTC:   $started")
    [void]$lines.Add("Completed UTC: $completed")
    [void]$lines.Add('')
    foreach($r in @($results.ToArray())){
        [void]$lines.Add(('{0} ({1}) -> {2} | {3:N1} MB | {4}' -f $r.Country,$r.SteamCode,$r.File,$r.SizeMB,$r.Sha256))
    }
    [void]$lines.Add('')
    [void]$lines.Add('Generic compatibility copy: GameBrowser-Windows.zip = GameBrowser-Windows-SG.zip when SG package exists')
    Write-AtomicText $report (($lines.ToArray() -join "`r`n") + "`r`n")

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host 'WINDOWS COUNTRY PACKAGES READY' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    foreach($r in @($results.ToArray())){ Write-Host ('{0} ({1}) -> {2}' -f $r.Country,$r.SteamCode,$r.File) -ForegroundColor Green }
    Write-Host ''
    Write-Host ('Report: {0}' -f $report) -ForegroundColor Cyan
} finally {
    if($hadSteamConfig){
        Write-AtomicText $SteamConfigPath $originalSteamConfigText
    } elseif(Test-Path -LiteralPath $SteamConfigPath){
        Remove-Item -LiteralPath $SteamConfigPath -Force
    }
}
