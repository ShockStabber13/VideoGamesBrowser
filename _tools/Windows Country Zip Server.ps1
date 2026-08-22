param([int]$Port = 8766)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$AndroidRoot=Join-Path $Root '_android'
$Allowed=@('US','UK','GB','SG','CA','MY')
$Files=@{}
foreach($tag in $Allowed){
    $p=Join-Path $AndroidRoot ("GameBrowser-Windows-$tag.zip")
    if(Test-Path -LiteralPath $p){$Files["/GameBrowser-Windows-$tag.zip"]=$p}
}
$generic=Join-Path $AndroidRoot 'GameBrowser-Windows.zip'
if(Test-Path -LiteralPath $generic){$Files['/GameBrowser-Windows.zip']=$generic}
if($Files.Count -le 0){throw 'No GameBrowser-Windows country ZIPs found in _android.'}
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
$ips=@()
try {$ips=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {$_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred'} | Select-Object -ExpandProperty IPAddress -Unique)} catch {
    try {$ips=@([Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) | Where-Object {$_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.IPAddressToString -ne '127.0.0.1'} | ForEach-Object {$_.IPAddressToString})} catch {}
}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Any,$Port);$listener.Start()
Write-Host '';Write-Host 'GameBrowser Windows Country ZIP Server' -ForegroundColor Cyan
Write-Host 'Keep this window open while Android downloads a Windows package.' -ForegroundColor DarkGray;Write-Host ''
foreach($ip in $ips){ foreach($kv in $Files.GetEnumerator() | Sort-Object Key){ Write-Host ("{0}: http://${ip}:$Port{1}" -f ($kv.Key.Trim('/')),$kv.Key) -ForegroundColor Green } }
if($ips.Count -eq 0){ foreach($kv in $Files.GetEnumerator() | Sort-Object Key){ Write-Host ("{0}: http://YOUR-PC-IP:$Port{1}" -f ($kv.Key.Trim('/')),$kv.Key) -ForegroundColor Yellow } }
Write-Host '';Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray;Write-Host ''
try {
    while($true){
        $client=$listener.AcceptTcpClient()
        try{
            $client.ReceiveTimeout=15000;$stream=$client.GetStream();$reader=New-Object IO.StreamReader($stream,[Text.Encoding]::ASCII,$false,4096,$true)
            $line=$reader.ReadLine();if([string]::IsNullOrWhiteSpace($line)){continue};while($true){$h=$reader.ReadLine();if([string]::IsNullOrEmpty($h)){break}}
            $parts=$line.Split(' ');$method=$parts[0].ToUpperInvariant();$path=$parts[1].Split('?')[0]
            if($method -ne 'GET'){Send-Text $stream 405 'Method Not Allowed' 'GET only';continue}
            if($path -eq '/'){
                $body="GameBrowser Windows country ZIP server.`n" + (($Files.Keys | Sort-Object | ForEach-Object {$_}) -join "`n") + "`n"
                Send-Text $stream 200 'OK' $body; continue
            }
            if($Files.ContainsKey($path)){Send-File $stream $Files[$path] 'application/zip'}
            else{Send-Text $stream 404 'Not Found' 'Not found'}
        } catch {Write-Warning $_.Exception.Message} finally {try{$client.Close()}catch{}}
    }
} finally {$listener.Stop()}
