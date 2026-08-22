param(
    [int]$Port = 8766,
    [ValidateSet('Both','Database','DailyChunks','Windows','All')]
    [string]$Mode = 'Both'
)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$AndroidRoot=Join-Path $Root '_android'
$DataZip=Join-Path $AndroidRoot 'GameBrowser-Data.zip'
$ChunksZip=Join-Path $AndroidRoot 'GameBrowser-DailyChunks.zip'
$WindowsZip=Join-Path $AndroidRoot 'GameBrowser-Windows.zip'
$DataManifest=Join-Path $AndroidRoot 'manifest.json'
$ChunksManifest=Join-Path $AndroidRoot 'daily_chunks_manifest.json'

$ServeData = ($Mode -eq 'Both' -or $Mode -eq 'Database' -or $Mode -eq 'All')
$ServeChunks = ($Mode -eq 'Both' -or $Mode -eq 'DailyChunks' -or $Mode -eq 'All')
$ServeWindows = ($Mode -eq 'Windows' -or $Mode -eq 'All')

if($ServeData -and !(Test-Path -LiteralPath $DataZip)){
    throw 'GameBrowser-Data.zip does not exist. Build the Database package first, or choose DailyChunks mode.'
}
if($ServeChunks -and !(Test-Path -LiteralPath $ChunksZip)){
    throw 'GameBrowser-DailyChunks.zip does not exist. Build the Daily Chunks package first, or choose Database mode.'
}
if($ServeWindows -and !(Test-Path -LiteralPath $WindowsZip)){
    throw 'GameBrowser-Windows.zip does not exist. Build the Windows index first, or choose another share mode.'
}

function Send-File($Stream,[string]$Path,[string]$ContentType){
    $fi=Get-Item -LiteralPath $Path
    $head="HTTP/1.1 200 OK`r`nContent-Type: $ContentType`r`nContent-Length: $($fi.Length)`r`nCache-Control: no-cache`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head);$Stream.Write($hb,0,$hb.Length)
    $f=[IO.File]::OpenRead($Path);try{$f.CopyTo($Stream)}finally{$f.Dispose()};$Stream.Flush()
}
function Send-Text($Stream,[int]$Code,[string]$Text,[string]$Body){
    $bytes=[Text.Encoding]::UTF8.GetBytes($Body)
    $head="HTTP/1.1 $Code $Text`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
    $hb=[Text.Encoding]::ASCII.GetBytes($head);$Stream.Write($hb,0,$hb.Length);$Stream.Write($bytes,0,$bytes.Length);$Stream.Flush()
}
function Not-Shared($Stream,[string]$Name){ Send-Text $Stream 404 'Not Found' "$Name is not shared in $Mode mode" }

$ips=@()
try {$ips=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'} | Select-Object -ExpandProperty IPAddress -Unique)} catch {
    try {$ips=@([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.IPAddressToString -ne '127.0.0.1'} | ForEach-Object {$_.IPAddressToString})} catch {}
}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Any,$Port);$listener.Start()
Write-Host '';Write-Host 'GameBrowser Android Package Server' -ForegroundColor Cyan
Write-Host ("Share mode: {0}" -f $Mode) -ForegroundColor Cyan
Write-Host 'Keep this window open while the Android device downloads an update.' -ForegroundColor DarkGray;Write-Host ''
foreach($ip in $ips){
    if($ServeData){Write-Host "Game Database: http://${ip}:$Port/GameBrowser-Data.zip" -ForegroundColor Green}
    if($ServeChunks){Write-Host "Daily Chunks:  http://${ip}:$Port/GameBrowser-DailyChunks.zip" -ForegroundColor Green}
    if($ServeWindows){Write-Host "Windows Index: http://${ip}:$Port/GameBrowser-Windows.zip" -ForegroundColor Green}
}
if($ips.Count -eq 0){
    if($ServeData){Write-Host "Game Database: http://YOUR-PC-IP:$Port/GameBrowser-Data.zip" -ForegroundColor Yellow}
    if($ServeChunks){Write-Host "Daily Chunks:  http://YOUR-PC-IP:$Port/GameBrowser-DailyChunks.zip" -ForegroundColor Yellow}
    if($ServeWindows){Write-Host "Windows Index: http://YOUR-PC-IP:$Port/GameBrowser-Windows.zip" -ForegroundColor Yellow}
}
Write-Host '';Write-Host 'Phone/tablet must be on the same network. Press Ctrl+C to stop.' -ForegroundColor DarkGray;Write-Host ''
try {
    while($true){
        $client=$listener.AcceptTcpClient()
        try{
            $client.ReceiveTimeout=15000;$stream=$client.GetStream();$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,4096,$true)
            $line=$reader.ReadLine();if([string]::IsNullOrWhiteSpace($line)){continue};while($true){$h=$reader.ReadLine();if([string]::IsNullOrEmpty($h)){break}}
            $parts=$line.Split(' ');$method=$parts[0].ToUpperInvariant();$path=$parts[1].Split('?')[0]
            if($method -ne 'GET'){Send-Text $stream 405 'Method Not Allowed' 'GET only';continue}
            switch($path){
                '/GameBrowser-Data.zip' {
                    if(!$ServeData){Not-Shared $stream 'Game database package'}
                    elseif(Test-Path $DataZip){Send-File $stream $DataZip 'application/zip'}
                    else{Send-Text $stream 404 'Not Found' 'Game database package not built'}
                }
                '/GameBrowser-DailyChunks.zip' {
                    if(!$ServeChunks){Not-Shared $stream 'Daily Chunk package'}
                    elseif(Test-Path $ChunksZip){Send-File $stream $ChunksZip 'application/zip'}
                    else{Send-Text $stream 404 'Not Found' 'Daily Chunk package not built'}
                }
                '/GameBrowser-Windows.zip' {
                    if(!$ServeWindows){Not-Shared $stream 'Windows Steam index package'}
                    elseif(Test-Path $WindowsZip){Send-File $stream $WindowsZip 'application/zip'}
                    else{Send-Text $stream 404 'Not Found' 'Windows Steam index package not built'}
                }
                '/manifest.json' {
                    if(!$ServeData){Not-Shared $stream 'Game database manifest'}
                    elseif(Test-Path $DataManifest){Send-File $stream $DataManifest 'application/json; charset=utf-8'}
                    else{Send-Text $stream 404 'Not Found' 'manifest missing'}
                }
                '/daily_chunks_manifest.json' {
                    if(!$ServeChunks){Not-Shared $stream 'Daily Chunk manifest'}
                    elseif(Test-Path $ChunksManifest){Send-File $stream $ChunksManifest 'application/json; charset=utf-8'}
                    else{Send-Text $stream 404 'Not Found' 'manifest missing'}
                }
                '/' {
                    $lines=New-Object 'System.Collections.Generic.List[string]'
                    [void]$lines.Add('GameBrowser package server.')
                    [void]$lines.Add("Mode: $Mode")
                    if($ServeData){[void]$lines.Add('/GameBrowser-Data.zip')}
                    if($ServeChunks){[void]$lines.Add('/GameBrowser-DailyChunks.zip')}
                    if($ServeWindows){[void]$lines.Add('/GameBrowser-Windows.zip')}
                    Send-Text $stream 200 'OK' (($lines.ToArray() -join "`n")+"`n")
                }
                default {Send-Text $stream 404 'Not Found' 'Not found'}
            }
        } catch {Write-Warning $_.Exception.Message} finally {try{$client.Close()}catch{}}
    }
} finally {$listener.Stop()}
