param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Database','DailyChunks','Windows','Both','All')]
    [string]$Target,
    [switch]$Build,
    [switch]$Share,
    [int]$Port = 8766
)

$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$Tools=Join-Path $Root '_tools'
$Android=Join-Path $Root '_android'
$DataZip=Join-Path $Android 'GameBrowser-Data.zip'
$ChunksZip=Join-Path $Android 'GameBrowser-DailyChunks.zip'
$WindowsZip=Join-Path $Android 'GameBrowser-Windows.zip'

if(!$Build -and !$Share){
    throw 'Nothing selected. Choose Build, Share, or both.'
}

function Run-PS([string]$Script,[string[]]$Arguments=@()) {
    $path=Join-Path $Tools $Script
    if(!(Test-Path -LiteralPath $path)){throw "Required tool not found: $path"}
    $all=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$path)+$Arguments
    & powershell.exe @all
    if($LASTEXITCODE -ne 0){throw "$Script failed with exit code $LASTEXITCODE"}
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '              GAMEBROWSER PACKAGE ACTION' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("Target : {0}" -f $Target)
Write-Host ("Build  : {0}" -f $(if($Build){'YES'}else{'NO'}))
Write-Host ("Share  : {0}" -f $(if($Share){'YES'}else{'NO'}))
Write-Host ''

if($Build){
    if($Target -eq 'Database' -or $Target -eq 'Both' -or $Target -eq 'All'){
        Write-Host '[DATABASE] Refreshing DAT-backed IGDB + DAT catalogs...' -ForegroundColor Cyan
        Run-PS 'Local Web Server.ps1' @('-BuildStaticCache')
        Write-Host '[DATABASE] Packaging GameBrowser-Data.zip...' -ForegroundColor Cyan
        Run-PS 'Build Android Database.ps1'
    }
    if($Target -eq 'DailyChunks' -or $Target -eq 'Both' -or $Target -eq 'All'){
        Write-Host '[DAILY CHUNKS] Building GameBrowser-DailyChunks.zip...' -ForegroundColor Cyan
        Run-PS 'Build Daily Chunks.ps1'
    }
    if($Target -eq 'Windows' -or $Target -eq 'All'){
        Write-Host '[WINDOWS] Building/resuming GameBrowser-Windows.zip from Steam StoreQuery...' -ForegroundColor Cyan
        Run-PS 'Build Windows Steam Index.ps1'
    }
}

if(!$Build){
    Write-Host 'NO BUILD selected: existing package files will not be changed.' -ForegroundColor Yellow
}

if($Share){
    if(($Target -eq 'Database' -or $Target -eq 'Both' -or $Target -eq 'All') -and !(Test-Path -LiteralPath $DataZip)){
        throw 'Cannot share Database: _android\GameBrowser-Data.zip does not exist.'
    }
    if(($Target -eq 'DailyChunks' -or $Target -eq 'Both' -or $Target -eq 'All') -and !(Test-Path -LiteralPath $ChunksZip)){
        throw 'Cannot share Daily Chunks: _android\GameBrowser-DailyChunks.zip does not exist.'
    }
    if(($Target -eq 'Windows' -or $Target -eq 'All') -and !(Test-Path -LiteralPath $WindowsZip)){
        throw 'Cannot share Windows index: _android\GameBrowser-Windows.zip does not exist.'
    }
    Write-Host ''
    Write-Host '[SHARE] Starting LAN server. Press Ctrl+C when finished.' -ForegroundColor Green
    Run-PS 'Android Database Server.ps1' @('-Port',[string]$Port,'-Mode',$Target)
} else {
    Write-Host ''
    Write-Host 'NO SHARE selected: no LAN server was started.' -ForegroundColor Yellow
    Write-Host 'Requested build action is complete.' -ForegroundColor Green
}
