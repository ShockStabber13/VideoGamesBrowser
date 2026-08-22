param(
    [Parameter(Mandatory=$true)][string]$Country,
    [switch]$ForceRebuild,
    [int]$BatchSize = 500
)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script=Join-Path $PSScriptRoot 'Build Windows Steam Index All Countries.ps1'
$args=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$script,'-Only',$Country,'-BatchSize',[string]$BatchSize)
if($ForceRebuild){$args += '-ForceRebuild'}
& powershell.exe @args
exit $LASTEXITCODE
