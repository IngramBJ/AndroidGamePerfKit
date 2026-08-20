Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:GpkVersion = '1.4.6'
$script:AdbExe = $null
$script:DeviceSerial = $null

function ConvertTo-GpkHashtable {
    param([Parameter(Mandatory=$true)]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-GpkHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [pscustomobject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-GpkHashtable $p.Value }
        return $h
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $a = @()
        foreach ($i in $InputObject) { $a += ,(ConvertTo-GpkHashtable $i) }
        return ,$a
    }
    return $InputObject
}

function Read-GpkConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $cfg = Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.packageName -or $cfg.packageName -notmatch '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$') {
        throw "Invalid packageName in config: $($cfg.packageName)"
    }
    if (-not $cfg.targetFps -or [double]$cfg.targetFps -le 0) { throw 'targetFps must be greater than zero.' }
    if (-not $cfg.defaults) { throw 'Config is missing defaults.' }
    if (-not $cfg.defaults.durationSec -or [int]$cfg.defaults.durationSec -le 0) { throw 'defaults.durationSec must be greater than zero.' }
    if (-not $cfg.defaults.sampleIntervalSec -or [double]$cfg.defaults.sampleIntervalSec -lt 0.5) { throw 'defaults.sampleIntervalSec must be at least 0.5.' }
    if (-not $cfg.deviceLabel) { $cfg | Add-Member -NotePropertyName deviceLabel -NotePropertyValue 'unlabelled-device' }
    if (-not $cfg.PSObject.Properties['gameName'] -or [string]::IsNullOrWhiteSpace([string]$cfg.gameName)) {
        $fallbackGameName=if($cfg.PSObject.Properties['profileName'] -and -not [string]::IsNullOrWhiteSpace([string]$cfg.profileName)){[string]$cfg.profileName}else{[string]$cfg.packageName}
        $cfg | Add-Member -NotePropertyName gameName -NotePropertyValue $fallbackGameName -Force
    }
    $cfg | Add-Member -NotePropertyName _configPath -NotePropertyValue $resolved -Force
    return $cfg
}

function ConvertTo-GpkPathSegment {
    param([AllowNull()][string]$Value,[string]$Fallback='unknown')
    $text=if([string]::IsNullOrWhiteSpace($Value)){$Fallback}else{$Value.Trim()}
    $text=$text -replace '[\x00-\x1f<>:"/\\|?*]','-'
    $text=$text -replace '\s+','-'
    $text=$text -replace '-{2,}','-'
    $text=$text.Trim(' ','.','-')
    if([string]::IsNullOrWhiteSpace($text)){$text=$Fallback}
    if($text.Length -gt 64){$text=$text.Substring(0,64).Trim(' ','.','-')}
    return $text
}

function Resolve-GpkAdb {
    param($Config)
    if ($script:AdbExe) { return $script:AdbExe }
    $candidate = $null
    if ($Config.adbPath) {
        if (Test-Path -LiteralPath ([string]$Config.adbPath)) { $candidate = (Resolve-Path -LiteralPath ([string]$Config.adbPath)).Path }
    }
    if (-not $candidate) {
        $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
        if ($cmd) { $candidate = $cmd.Source }
    }
    if (-not $candidate) { throw 'adb.exe was not found. Install Android Platform Tools or set adbPath in config.' }
    $script:AdbExe = $candidate
    return $candidate
}

function Invoke-GpkAdb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [string]$OutFile,
        [int]$TimeoutSec = 30
    )
    $adb = Resolve-GpkAdb $Config
    $all = @()
    if ($script:DeviceSerial) { $all += @('-s', $script:DeviceSerial) }
    $all += $Arguments
    $lines=@();$exitCode=0
    if([IO.Path]::GetExtension($adb) -eq '.ps1'){
        # Test/development adapter. Production adb.exe uses the process path below.
        $lines=@(& $adb @all 2>&1|ForEach-Object{$_.ToString()});$exitCode=$LASTEXITCODE
    } else {
        # Do not let Windows PowerShell 5.1 turn ADB's normal stderr progress into NativeCommandError.
        $tempBase=Join-Path ([IO.Path]::GetTempPath()) ("gpk-adb-"+[guid]::NewGuid().ToString('N'))
        $stdoutFile="$tempBase.stdout";$stderrFile="$tempBase.stderr"
        $proc=$null
        try{
            $quoted=@($all|ForEach-Object{if($_ -match '[\s"]'){'"'+($_ -replace '"','\"')+'"'}else{$_}})
            $proc=Start-Process -FilePath $adb -ArgumentList ($quoted -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            # Windows PowerShell 5.1 only populates ExitCode after the native handle is materialized.
            $processHandle=$proc.Handle
            $deadline=[DateTime]::UtcNow.AddSeconds([math]::Max(1,$TimeoutSec))
            while(-not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline){
                # A short PowerShell sleep gives the host a chance to process Ctrl+C.
                Start-Sleep -Milliseconds 100
                $proc.Refresh()
            }
            if(-not $proc.HasExited){
                try{$proc.Kill()}catch{}
                try{$proc.WaitForExit(2000)}catch{}
                $exitCode=124
                $lines+=@("ADB timed out after $TimeoutSec seconds: adb $($all -join ' ')")
            }else{$proc.WaitForExit();$exitCode=$proc.ExitCode}
            if(Test-Path -LiteralPath $stdoutFile){$lines+=@(Get-Content -LiteralPath $stdoutFile -Encoding UTF8)}
            if(Test-Path -LiteralPath $stderrFile){$lines+=@(Get-Content -LiteralPath $stderrFile -Encoding UTF8)}
        } finally {
            # Also runs for Ctrl+C / pipeline cancellation, preventing an orphaned adb.exe client.
            if($proc){
                try{if(-not $proc.HasExited){$proc.Kill();$proc.WaitForExit(2000)}}catch{}
                try{$proc.Dispose()}catch{}
            }
            Remove-Item -LiteralPath $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
        }
    }
    $text = ($lines -join [Environment]::NewLine)
    if ($OutFile) {
        $parent = Split-Path -Parent $OutFile
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Set-Content -LiteralPath $OutFile -Value $text -Encoding UTF8
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "ADB failed (exit=$exitCode): adb $($all -join ' ')`n$text"
    }
    return [pscustomobject]@{ ExitCode=$exitCode; Text=$text; Lines=$lines }
}

function Invoke-GpkShell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$Command,
        [switch]$AllowFailure,
        [string]$OutFile,
        [int]$TimeoutSec = 30
    )
    return Invoke-GpkAdb -Config $Config -Arguments @('shell', $Command) -AllowFailure:$AllowFailure -OutFile $OutFile -TimeoutSec $TimeoutSec
}

function Select-GpkDevice {
    param($Config)
    Resolve-GpkAdb $Config | Out-Null
    $script:DeviceSerial = $null
    $r = Invoke-GpkAdb -Config $Config -Arguments @('devices')
    $devices = @()
    foreach ($line in $r.Lines) {
        if ($line -match '^([^\s]+)\s+(device|unauthorized|offline)$') {
            $devices += [pscustomobject]@{ serial=$Matches[1]; state=$Matches[2] }
        }
    }
    if ($Config.deviceSerial) {
        $chosen = $devices | Where-Object { $_.serial -eq [string]$Config.deviceSerial } | Select-Object -First 1
        if (-not $chosen) { throw "Configured deviceSerial '$($Config.deviceSerial)' was not found." }
    } else {
        $ready = @($devices | Where-Object { $_.state -eq 'device' })
        if ($ready.Count -eq 0) {
            $unauthorized=@($devices|Where-Object{$_.state -eq 'unauthorized'})
            $offline=@($devices|Where-Object{$_.state -eq 'offline'})
            if($unauthorized.Count -gt 0){throw 'No authorized Android device is ready. Unlock the phone and accept the USB debugging authorization prompt.'}
            if($offline.Count -gt 0){throw 'The Android device is offline. Reconnect USB, restart ADB, and try again.'}
            throw 'No Android device is connected. Connect and authorize one phone, then run preflight again.'
        }
        if ($ready.Count -gt 1) { throw "Multiple authorized devices were found ($($ready.Count)). Set deviceSerial in config." }
        $chosen = $ready[0]
    }
    if ($chosen.state -ne 'device') { throw "Device $($chosen.serial) is $($chosen.state), not authorized and ready." }
    $script:DeviceSerial = $chosen.serial
    return $chosen.serial
}

function New-GpkRunContext {
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$CaseName,
        [Parameter(Mandatory=$true)][string]$KitRoot
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeCase = ConvertTo-GpkPathSegment -Value $CaseName.ToLowerInvariant() -Fallback 'unknown-case'
    $safeGame = ConvertTo-GpkPathSegment -Value ([string]$Config.gameName) -Fallback ([string]$Config.packageName)
    $safeDevice = ConvertTo-GpkPathSegment -Value ([string]$Config.deviceLabel) -Fallback 'unlabelled-device'
    $leafName="${stamp}_${safeDevice}"
    $caseRoot=Join-Path $KitRoot "results\$safeGame\$safeCase"
    $root = Join-Path $caseRoot $leafName
    New-Item -ItemType Directory -Force -Path $root,(Join-Path $root 'raw\start'),(Join-Path $root 'raw\end'),(Join-Path $root 'raw\preflight') | Out-Null
    return [pscustomobject]@{
        Config=$Config; CaseName=$safeCase; Timestamp=$stamp; KitRoot=$KitRoot; ResultRoot=$root
        RawRoot=(Join-Path $root 'raw'); StatePath=(Join-Path $KitRoot '.state\active-run.json')
        GameName=[string]$Config.gameName; SafeGameName=$safeGame
        ZipPath=(Join-Path $caseRoot "$leafName.zip"); Warnings=(New-Object System.Collections.ArrayList)
        StartedAt=(Get-Date).ToUniversalTime().ToString('o'); Collector=$null; Perfetto=$null; SurfaceEnabled=$false; CleanupSucceeded=$false; Markers=(New-Object System.Collections.ArrayList)
    }
}

function Add-GpkWarning {
    param($Context,[string]$Message)
    [void]$Context.Warnings.Add($Message)
    Write-Warning $Message
}

function ConvertTo-GpkJsonString {
    param([AllowNull()][string]$Value)
    if($null -eq $Value){return 'null'}
    $builder=New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach($character in $Value.ToCharArray()){
        $code=[int][char]$character
        if($code -eq 8){[void]$builder.Append('\b')}
        elseif($code -eq 9){[void]$builder.Append('\t')}
        elseif($code -eq 10){[void]$builder.Append('\n')}
        elseif($code -eq 12){[void]$builder.Append('\f')}
        elseif($code -eq 13){[void]$builder.Append('\r')}
        elseif($code -eq 34){[void]$builder.Append('\"')}
        elseif($code -eq 92){[void]$builder.Append('\\')}
        elseif($code -lt 32){[void]$builder.Append('\u'+$code.ToString('x4'))}
        else{[void]$builder.Append($character)}
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-GpkJsonValue {
    param([AllowNull()]$Value,[int]$Depth=0)
    if($Depth -gt 20){throw 'JSON object exceeds the supported depth of 20.'}
    if($null -eq $Value){return 'null'}
    if($Value -is [string] -or $Value -is [char] -or $Value -is [datetime] -or $Value -is [guid]){
        $text=if($Value -is [datetime]){$Value.ToUniversalTime().ToString('o')}else{[string]$Value}
        return ConvertTo-GpkJsonString $text
    }
    if($Value -is [bool]){if($Value){return 'true'}else{return 'false'}}
    if($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
       $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or
       $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]){
        if(($Value -is [double] -or $Value -is [single]) -and ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value))){return 'null'}
        return ([System.IFormattable]$Value).ToString($null,[Globalization.CultureInfo]::InvariantCulture)
    }
    if($Value -is [System.Collections.IDictionary]){
        $members=New-Object System.Collections.Generic.List[string]
        foreach($key in $Value.Keys){
            $name=ConvertTo-GpkJsonString ([string]$key)
            $encoded=ConvertTo-GpkJsonValue -Value $Value[$key] -Depth ($Depth+1)
            $members.Add($name+':'+$encoded)
        }
        return '{'+($members -join ',')+'}'
    }
    if($Value -is [pscustomobject]){
        $members=New-Object System.Collections.Generic.List[string]
        foreach($property in $Value.PSObject.Properties){
            $name=ConvertTo-GpkJsonString $property.Name
            $encoded=ConvertTo-GpkJsonValue -Value $property.Value -Depth ($Depth+1)
            $members.Add($name+':'+$encoded)
        }
        return '{'+($members -join ',')+'}'
    }
    if(($Value -is [System.Collections.IEnumerable]) -and -not($Value -is [string])){
        $items=New-Object System.Collections.Generic.List[string]
        foreach($item in $Value){$items.Add((ConvertTo-GpkJsonValue -Value $item -Depth ($Depth+1)))}
        return '['+($items -join ',')+']'
    }
    return ConvertTo-GpkJsonString ([string]$Value)
}

function Write-GpkJson {
    param([string]$Path,[AllowNull()]$Object)
    $parent=Split-Path -Parent $Path
    if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null}
    $json=ConvertTo-GpkJsonValue -Value $Object
    $utf8=New-Object System.Text.UTF8Encoding($false)
    $temporary=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
    try{
        [IO.File]::WriteAllText($temporary,$json,$utf8)
        if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Force}
        [IO.File]::Move($temporary,$Path)
    }finally{
        if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
    }
}

function Get-GpkActivity {
    param($Config)
    if ($Config.activity -and [string]$Config.activity -ne 'auto') { return [string]$Config.activity }
    $pkg = [string]$Config.packageName
    $r = Invoke-GpkShell -Config $Config -Command "cmd package resolve-activity --brief $pkg" -AllowFailure
    $lines = @($r.Lines | Where-Object { $_ -match '/' -and $_ -notmatch 'No activity' })
    if ($lines.Count -gt 0) { return $lines[-1].Trim() }
    $r = Invoke-GpkShell -Config $Config -Command "monkey -p $pkg -c android.intent.category.LAUNCHER 0" -AllowFailure
    return $null
}

function Get-GpkBatterySaverState {
    param($Config,[string]$PowerText)
    if (-not $PowerText) { $PowerText = (Invoke-GpkShell -Config $Config -Command 'dumpsys power' -AllowFailure).Text }
    if ($PowerText -match '(?im)Battery Saver is currently:\s*ON\b') { return 'on' }
    if ($PowerText -match '(?im)Battery Saver is currently:\s*OFF\b') { return 'off' }
    if ($PowerText -match '(?im)^\s*(?:mFullEnabled|full|Enabled)\s*=\s*true\s*$' -and $PowerText -notmatch '(?im)^\s*(?:mFullEnabled|full|Enabled)\s*=\s*false\s*$') { return 'on-inferred' }
    return 'unknown'
}

function Test-GpkCommand {
    param($Config,[string]$Name)
    $r = Invoke-GpkShell -Config $Config -Command "command -v $Name" -AllowFailure
    return ($r.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Text))
}

function Invoke-GpkPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Context,[switch]$WriteArtifacts)
    $cfg = $Context.Config
    Write-Host '[1/12] Checking ADB and device authorization...' -ForegroundColor Cyan
    $serial = Select-GpkDevice $cfg
    $raw = Join-Path $Context.RawRoot 'preflight'
    $pkg = [string]$cfg.packageName

    Write-Host '[2/12] Reading ADB version and device properties...' -ForegroundColor Cyan
    $adbVersion = Invoke-GpkAdb -Config $cfg -Arguments @('version')
    $props = Invoke-GpkShell -Config $cfg -Command 'getprop' -OutFile (Join-Path $raw 'getprop.txt')
    Write-Host '[3/12] Checking package and PID...' -ForegroundColor Cyan
    $package = Invoke-GpkShell -Config $cfg -Command "pm path $pkg" -AllowFailure -OutFile (Join-Path $raw 'package.txt')
    $pid = Invoke-GpkShell -Config $cfg -Command "pidof $pkg" -AllowFailure -OutFile (Join-Path $raw 'pid.txt')
    Write-Host '[4/12] Reading RAM and storage...' -ForegroundColor Cyan
    $mem = Invoke-GpkShell -Config $cfg -Command 'cat /proc/meminfo' -OutFile (Join-Path $raw 'meminfo.txt')
    $storage = Invoke-GpkShell -Config $cfg -Command 'df -k /data' -OutFile (Join-Path $raw 'storage.txt')
    Write-Host '[5/12] Reading battery and power state...' -ForegroundColor Cyan
    $battery = Invoke-GpkShell -Config $cfg -Command 'dumpsys battery' -OutFile (Join-Path $raw 'battery.txt')
    $power = Invoke-GpkShell -Config $cfg -Command 'dumpsys power' -AllowFailure -OutFile (Join-Path $raw 'power.txt')
    Write-Host '[6/12] Probing thermal service (15s timeout)...' -ForegroundColor Cyan
    $thermal = Invoke-GpkShell -Config $cfg -Command 'dumpsys thermalservice' -AllowFailure -OutFile (Join-Path $raw 'thermalservice.txt') -TimeoutSec 15
    Write-Host '[7/12] Probing SurfaceFlinger timestats (15s timeout)...' -ForegroundColor Cyan
    $sf = Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -dump' -AllowFailure -OutFile (Join-Path $raw 'surfaceflinger-timestats.txt') -TimeoutSec 15
    Write-Host '[8/12] Resolving launcher Activity...' -ForegroundColor Cyan
    $activity = Get-GpkActivity $cfg
    Set-Content -LiteralPath (Join-Path $raw 'resolved-activity.txt') -Value $activity -Encoding UTF8

    Write-Host '[9/12] Probing device shell tools...' -ForegroundColor Cyan
    $androidSdk=0
    $sdkResult=Invoke-GpkShell -Config $cfg -Command 'getprop ro.build.version.sdk' -AllowFailure -OutFile (Join-Path $raw 'android-sdk.txt')
    [int]::TryParse($sdkResult.Text.Trim(),[ref]$androidSdk)|Out-Null
    $perfettoCommand=Test-GpkCommand $cfg 'perfetto'
    if($perfettoCommand){Invoke-GpkShell -Config $cfg -Command 'perfetto --help' -AllowFailure -OutFile (Join-Path $raw 'perfetto-help.txt') -TimeoutSec 5|Out-Null}
    $caps = [ordered]@{
        adb=$true; authorized=$true; packageInstalled=($package.Text -match '^package:')
        processRunning=(-not [string]::IsNullOrWhiteSpace($pid.Text)); resolvedActivity=(-not [string]::IsNullOrWhiteSpace($activity))
        surfaceFlingerTimestats=($sf.ExitCode -eq 0 -and $sf.Text -notmatch '(?i)unknown option|not found|permission denial')
        fallocate=(Test-GpkCommand $cfg 'fallocate'); unzip=(Test-GpkCommand $cfg 'unzip'); awk=(Test-GpkCommand $cfg 'awk')
        perfetto=$perfettoCommand; perfettoTextConfig=($perfettoCommand -and $androidSdk -ge 29)
        batterySaverState=(Get-GpkBatterySaverState -Config $cfg -PowerText $power.Text)
        thermalService=($thermal.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($thermal.Text))
    }
    if (-not $caps.packageInstalled) { throw "Package '$pkg' is not installed on $serial." }
    if (-not $caps.awk) { throw 'Device capability missing: awk is required by the light sampler.' }

    $memTotalKb = 0; $memAvailKb = 0
    if ($mem.Text -match '(?m)^MemTotal:\s+(\d+)') { $memTotalKb = [int64]$Matches[1] }
    if ($mem.Text -match '(?m)^MemAvailable:\s+(\d+)') { $memAvailKb = [int64]$Matches[1] }
    $storageAvailKb=0
    $storageLines=@($storage.Lines|Where-Object{$_ -match '\d'})
    if($storageLines.Count -gt 0){$storageParts=@($storageLines[-1].Trim() -split '\s+');if($storageParts.Count -ge 4){[int64]::TryParse($storageParts[3],[ref]$storageAvailKb)|Out-Null}}
    $batteryLevel=$null;$batteryTempC=$null
    if($battery.Text -match '(?im)^\s*level:\s*(\d+)'){$batteryLevel=[int]$Matches[1]}
    if($battery.Text -match '(?im)^\s*temperature:\s*(\d+)'){$batteryTempC=[math]::Round(([double]$Matches[1])/10,1)}
    $report = [ordered]@{
        status='pass'; kitVersion=$script:GpkVersion; checkedAt=(Get-Date).ToUniversalTime().ToString('o')
        adbVersion=($adbVersion.Lines | Select-Object -First 1); serial=$serial; deviceLabel=$cfg.deviceLabel; androidSdk=$androidSdk
        packageName=$pkg; pid=$pid.Text.Trim(); activity=$activity
        ram=[ordered]@{ totalMiB=[math]::Round($memTotalKb/1024,1); availableMiB=[math]::Round($memAvailKb/1024,1) }
        storage=[ordered]@{ dataAvailableGiB=[math]::Round($storageAvailKb/1024/1024,2) }
        battery=[ordered]@{ levelPct=$batteryLevel; temperatureC=$batteryTempC; saverState=$caps.batterySaverState }
        capabilities=$caps
    }
    if (-not $caps.processRunning) { Add-GpkWarning $Context 'Game process is not currently running; cold-start cases can still proceed.' }
    if (-not $caps.surfaceFlingerTimestats) { Add-GpkWarning $Context 'SurfaceFlinger timestats is unavailable; FPS percentiles will be unavailable.' }
    Write-Host '[10/12] Serializing preflight report...' -ForegroundColor Cyan
    if ($WriteArtifacts) { Write-GpkJson -Path (Join-Path $Context.ResultRoot 'preflight.json') -Object $report }
    Write-Host '[11/12] Preflight report written.' -ForegroundColor Cyan
    return $report
}

function Save-GpkState {
    param($Context,$State)
    $dir = Split-Path -Parent $Context.StatePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-GpkJson -Path $Context.StatePath -Object $State
}

function Get-GpkInitialState {
    param($Context)
    $cfg=$Context.Config
    $low=(Invoke-GpkShell -Config $cfg -Command 'settings get global low_power' -AllowFailure).Text.Trim()
    return [ordered]@{
        serial=$script:DeviceSerial; packageName=$cfg.packageName; lowPowerBefore=$low; batteryUnplugged=$false
        fillerPath=$null; remoteSamplerPid=$null; remoteStopFile=$null; remoteFiles=@(); surfaceFlingerEnabled=$false
        perfettoPid=$null; perfettoFiles=@()
        backgroundPackages=@(); resultRoot=$Context.ResultRoot; createdAt=(Get-Date).ToUniversalTime().ToString('o')
    }
}

function Save-GpkSnapshot {
    param($Context,[ValidateSet('start','end')][string]$Phase)
    $cfg=$Context.Config; $dir=Join-Path $Context.RawRoot $Phase; $pkg=[string]$cfg.packageName
    $commands=[ordered]@{
        'battery.txt'='dumpsys battery'; 'power.txt'='dumpsys power'; 'thermalservice.txt'='dumpsys thermalservice'
        'meminfo-system.txt'='cat /proc/meminfo'; 'meminfo-game.txt'="dumpsys meminfo $pkg"; 'storage.txt'='df -k /data'
        'process.txt'="ps -A -o USER,PID,PPID,NAME,ARGS | grep $pkg"; 'surfaceflinger.txt'='dumpsys SurfaceFlinger --timestats -dump'
        'gfxinfo.txt'="dumpsys gfxinfo $pkg"
    }
    foreach($name in $commands.Keys){ Invoke-GpkShell -Config $cfg -Command $commands[$name] -AllowFailure -OutFile (Join-Path $dir $name) | Out-Null }
}

function Start-GpkSurfaceStats {
    param($Context)
    $cfg=$Context.Config
    $a=Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -disable' -AllowFailure
    $b=Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -clear' -AllowFailure
    $c=Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -enable' -AllowFailure
    if ($c.ExitCode -eq 0 -and $c.Text -notmatch '(?i)unknown option|permission denial') { $Context.SurfaceEnabled=$true; return $true }
    Add-GpkWarning $Context 'Could not enable SurfaceFlinger timestats.'
    return $false
}

function Stop-GpkSurfaceStats {
    param($Context,[string]$Name='surfaceflinger-final.txt')
    $cfg=$Context.Config
    Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -dump' -AllowFailure -OutFile (Join-Path $Context.RawRoot $Name) | Out-Null
    if($Context.SurfaceEnabled){Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -disable' -AllowFailure | Out-Null}
    $Context.SurfaceEnabled=$false
}

function Start-GpkLogcat {
    param($Context)
    Invoke-GpkAdb -Config $Context.Config -Arguments @('logcat','-c') -AllowFailure | Out-Null
}

function Stop-GpkLogcat {
    param($Context)
    Invoke-GpkAdb -Config $Context.Config -Arguments @('logcat','-d','-v','threadtime') -AllowFailure -OutFile (Join-Path $Context.RawRoot 'logcat.txt') | Out-Null
}

function Start-GpkCollector {
    param($Context)
    $cfg=$Context.Config; $tag=($Context.Timestamp -replace '[^0-9]','')
    $remoteScript="/data/local/tmp/gpk_sampler_$tag.sh"; $remoteOut="/data/local/tmp/gpk_samples_$tag.tsv"
    $remoteStop="/data/local/tmp/gpk_stop_$tag"; $remoteLog="/data/local/tmp/gpk_sampler_$tag.log"
    $localScript=Join-Path $Context.KitRoot 'device\gameperf_sampler.sh'
    Invoke-GpkAdb -Config $cfg -Arguments @('push',$localScript,$remoteScript) | Out-Null
    Invoke-GpkShell -Config $cfg -Command "chmod 700 $remoteScript; rm -f $remoteOut $remoteStop $remoteLog" | Out-Null
    $interval=[string]([double]$cfg.defaults.sampleIntervalSec).ToString([Globalization.CultureInfo]::InvariantCulture)
    $maxCollectorSec=14400
    if($cfg.defaults.PSObject.Properties['maxCollectorSec']){$maxCollectorSec=[int]$cfg.defaults.maxCollectorSec}
    $cmd="sh $remoteScript $($cfg.packageName) $interval $remoteOut $remoteStop $maxCollectorSec >$remoteLog 2>&1 & echo `$!"
    $started=Invoke-GpkShell -Config $cfg -Command $cmd
    $samplerPid=($started.Lines | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
    $Context.Collector=[pscustomobject]@{ RemoteScript=$remoteScript; RemoteOut=$remoteOut; RemoteStop=$remoteStop; RemoteLog=$remoteLog; Pid=$samplerPid }
    return $Context.Collector
}

function Stop-GpkCollector {
    param($Context)
    if (-not $Context.Collector) { return }
    $cfg=$Context.Config; $c=$Context.Collector
    Invoke-GpkShell -Config $cfg -Command "touch $($c.RemoteStop)" -AllowFailure | Out-Null
    Start-Sleep -Milliseconds 1200
    if ($c.Pid) { Invoke-GpkShell -Config $cfg -Command "kill $($c.Pid) 2>/dev/null" -AllowFailure | Out-Null }
    Invoke-GpkAdb -Config $cfg -Arguments @('pull',$c.RemoteOut,(Join-Path $Context.RawRoot 'device-samples.tsv')) -AllowFailure | Out-Null
    Invoke-GpkAdb -Config $cfg -Arguments @('pull',$c.RemoteLog,(Join-Path $Context.RawRoot 'device-sampler.log')) -AllowFailure | Out-Null
    Convert-GpkSamples -Context $Context
    Invoke-GpkShell -Config $cfg -Command "rm -f $($c.RemoteScript) $($c.RemoteOut) $($c.RemoteStop) $($c.RemoteLog)" -AllowFailure | Out-Null
    $Context.Collector=$null
}

function Start-GpkPerfetto {
    param($Context)
    $cfg=$Context.Config
    if(-not $cfg.PSObject.Properties['_perfettoEnabled'] -or -not [bool]$cfg._perfettoEnabled){return $null}
    $profile='balanced';if($cfg.PSObject.Properties['_perfettoProfile']){$profile=[string]$cfg._perfettoProfile}
    if($profile -notin @('balanced','cpu-jank','load-io')){throw "Unsupported Perfetto profile: $profile"}
    $duration=30;if($cfg.PSObject.Properties['_perfettoDurationSec']){$duration=[int]$cfg._perfettoDurationSec}
    if($duration -lt 5 -or $duration -gt 300){throw 'Perfetto duration must be between 5 and 300 seconds.'}
    $probe=Invoke-GpkShell -Config $cfg -Command 'command -v perfetto' -AllowFailure
    if($probe.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probe.Text)){throw 'Perfetto was requested, but the device does not provide the perfetto command.'}
    $sdkText=(Invoke-GpkShell -Config $cfg -Command 'getprop ro.build.version.sdk' -AllowFailure).Text.Trim();$sdk=0
    [int]::TryParse($sdkText,[ref]$sdk)|Out-Null
    if($sdk -lt 29){throw "Perfetto text-config capture requires Android 10/API 29 or newer; device API is $sdk."}

    $templatePath=Join-Path $Context.KitRoot "perfetto\profiles\$profile.pbtxt"
    if(-not(Test-Path -LiteralPath $templatePath)){throw "Perfetto profile template is missing: $templatePath"}
    $dir=Join-Path $Context.RawRoot 'perfetto';New-Item -ItemType Directory -Force -Path $dir|Out-Null
    $configPath=Join-Path $dir 'effective-config.pbtxt'
    $durationMs=$duration*1000
    $configText=(Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8).Replace('{{DURATION_MS}}',[string]$durationMs).Replace('{{PACKAGE_NAME}}',[string]$cfg.packageName)
    # Windows PowerShell 5.1 writes a BOM with -Encoding UTF8; protobuf text
    # configs are written explicitly as UTF-8 without BOM for OEM parsers.
    [IO.File]::WriteAllText($configPath,$configText,(New-Object System.Text.UTF8Encoding($false)))
    $tag=($Context.Timestamp -replace '[^0-9]','')
    $remoteConfig="/data/local/tmp/gpk_perfetto_$tag.pbtxt"
    $remoteTrace="/data/misc/perfetto-traces/gpk_$tag.perfetto-trace"
    $remoteExport="/data/local/tmp/gpk_perfetto_$tag.perfetto-trace"
    Invoke-GpkAdb -Config $cfg -Arguments @('push',$configPath,$remoteConfig)|Out-Null
    $started=Invoke-GpkShell -Config $cfg -Command "cat $remoteConfig | perfetto --txt -c - -o $remoteTrace --background" -AllowFailure -TimeoutSec 15
    Set-Content -LiteralPath (Join-Path $dir 'capture.log') -Value $started.Text -Encoding UTF8
    $pid=($started.Lines|Where-Object{$_ -match '^\s*\d+\s*$'}|Select-Object -Last 1)
    if($started.ExitCode -ne 0 -or -not $pid){
        Invoke-GpkShell -Config $cfg -Command "rm -f $remoteConfig $remoteTrace $remoteExport" -AllowFailure|Out-Null
        throw "Perfetto did not return a background PID. Device output: $($started.Text)"
    }
    $Context.Perfetto=[pscustomobject]@{
        Profile=$profile;DurationSec=$duration;Pid=$pid.Trim();RemoteConfig=$remoteConfig;RemoteTrace=$remoteTrace;RemoteExport=$remoteExport
        LocalTrace=(Join-Path $dir 'trace.perfetto-trace');CaptureCompleted=$false;StartedAt=(Get-Date).ToUniversalTime().ToString('o')
    }
    Add-GpkMarker $Context 'perfetto_start' "profile=$profile;durationSec=$duration"
    Write-Host "Perfetto recording started: profile=$profile, duration=${duration}s" -ForegroundColor Cyan
    return $Context.Perfetto
}

function Stop-GpkPerfetto {
    param($Context)
    if(-not $Context.Perfetto){return}
    $cfg=$Context.Config;$p=$Context.Perfetto;$dir=Split-Path -Parent $p.LocalTrace
    if($p.Pid){Invoke-GpkShell -Config $cfg -Command "if test -r /proc/$($p.Pid)/cmdline && grep -aq perfetto /proc/$($p.Pid)/cmdline; then kill -2 $($p.Pid) 2>/dev/null; fi" -AllowFailure|Out-Null}
    Start-Sleep -Milliseconds 1000
    $check=$null
    for($i=0;$i -lt 10;$i++){
        $check=Invoke-GpkShell -Config $cfg -Command "test -s $($p.RemoteTrace)" -AllowFailure
        if($check.ExitCode -eq 0){break}
        Start-Sleep -Milliseconds 500
    }
    $pull=$null
    if($check.ExitCode -eq 0){$pull=Invoke-GpkAdb -Config $cfg -Arguments @('pull',$p.RemoteTrace,$p.LocalTrace) -AllowFailure -TimeoutSec 60}
    if((-not $pull -or $pull.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $p.LocalTrace))){
        $copied=Invoke-GpkShell -Config $cfg -Command "cp $($p.RemoteTrace) $($p.RemoteExport)" -AllowFailure
        if($copied.ExitCode -eq 0){$pull=Invoke-GpkAdb -Config $cfg -Arguments @('pull',$p.RemoteExport,$p.LocalTrace) -AllowFailure -TimeoutSec 60}
    }
    $size=0L;if(Test-Path -LiteralPath $p.LocalTrace){$size=(Get-Item -LiteralPath $p.LocalTrace).Length}
    $p.CaptureCompleted=($size -gt 0)
    $p|Add-Member -NotePropertyName SizeBytes -NotePropertyValue $size -Force
    $p|Add-Member -NotePropertyName FinishedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Add-Content -LiteralPath (Join-Path $dir 'capture.log') -Value "`nfinished=$($p.FinishedAt)`nsizeBytes=$size`npullExit=$($(if($pull){$pull.ExitCode}else{'not-attempted'}))" -Encoding UTF8
    Invoke-GpkShell -Config $cfg -Command "rm -f $($p.RemoteConfig) $($p.RemoteTrace) $($p.RemoteExport)" -AllowFailure|Out-Null
    Add-GpkMarker $Context 'perfetto_stop' "captured=$($p.CaptureCompleted);sizeBytes=$size"
    if(-not $p.CaptureCompleted){throw 'Perfetto recording ended, but no non-empty trace could be pulled from the device.'}
}

function Get-GpkPerfettoSummary {
    param($Context)
    $requested=($Context.Config.PSObject.Properties['_perfettoEnabled'] -and [bool]$Context.Config._perfettoEnabled)
    $o=[ordered]@{requested=$requested;captureCompleted=$false;profile=$null;durationSec=$null;traceFile=$null;sizeMiB=$null}
    if(-not $Context.Perfetto){return $o}
    $p=$Context.Perfetto;$o.profile=$p.Profile;$o.durationSec=$p.DurationSec;$o.captureCompleted=[bool]$p.CaptureCompleted
    if(Test-Path -LiteralPath $p.LocalTrace){$o.traceFile='raw/perfetto/trace.perfetto-trace';$o.sizeMiB=[math]::Round((Get-Item -LiteralPath $p.LocalTrace).Length/1MB,2)}
    return $o
}

function Convert-GpkSamples {
    param($Context)
    $src=Join-Path $Context.RawRoot 'device-samples.tsv'; $dst=Join-Path $Context.ResultRoot 'samples.csv'
    if (-not (Test-Path -LiteralPath $src)) { Set-Content -LiteralPath $dst -Value 'time_s,pid,process_cpu_pct,main_cpu_pct,unitymain_cpu_pct,gfx_cpu_pct,job_cpu_pct,rss_mib,mem_available_mib,swap_used_mib,cpu_freq_avg_mhz,thermal_max_c,battery_pct' -Encoding UTF8; return }
    $rows=@(Import-Csv -LiteralPath $src -Delimiter "`t")
    $out=@(); $prev=$null; $base=$null
    foreach($r in $rows){
        $u=0.0; [double]::TryParse([string]$r.uptime_s,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$u)|Out-Null
        if ($null -eq $base) { $base=$u }
        $procPct=$null;$mainPct=$null;$unityPct=$null;$gfxPct=$null;$jobPct=$null
        if ($prev -and $r.pid -eq $prev.pid) {
            $pu=[double]$prev.uptime_s; $dt=$u-$pu
            if($dt -gt 0){
                $clockTicks=100.0;if($r.PSObject.Properties['clock_ticks_per_sec'] -and [double]$r.clock_ticks_per_sec -gt 0){$clockTicks=[double]$r.clock_ticks_per_sec}
                foreach($pair in @(@('proc_ticks','procPct'),@('main_ticks','mainPct'),@('unity_ticks','unityPct'),@('gfx_ticks','gfxPct'),@('job_ticks','jobPct'))){
                    $a=[double]$prev.($pair[0]);$b=[double]$r.($pair[0]);$v=[math]::Round((($b-$a)/$clockTicks)/$dt*100.0,2)
                    Set-Variable -Name $pair[1] -Value $v
                }
            }
        }
        $swapUsed=[math]::Max(0,([double]$r.swap_total_kb-[double]$r.swap_free_kb)/1024.0)
        $out += [pscustomobject][ordered]@{
            time_s=[math]::Round($u-$base,3); pid=$r.pid; process_cpu_pct=$procPct; main_cpu_pct=$mainPct; unitymain_cpu_pct=$unityPct
            gfx_cpu_pct=$gfxPct; job_cpu_pct=$jobPct; rss_mib=[math]::Round(([double]$r.rss_kb)/1024,2)
            mem_available_mib=[math]::Round(([double]$r.mem_available_kb)/1024,2); swap_used_mib=[math]::Round($swapUsed,2)
            cpu_freq_avg_mhz=[math]::Round(([double]$r.cpu_freq_avg_khz)/1000,1); thermal_max_c=[math]::Round(([double]$r.thermal_max_mc)/1000,1)
            battery_pct=$r.battery_pct
        }
        $prev=$r
    }
    $out | Export-Csv -LiteralPath $dst -NoTypeInformation -Encoding UTF8
}

function Add-GpkMarker {
    param($Context,[string]$Name,[string]$Note='')
    $uptime=(Invoke-GpkShell -Config $Context.Config -Command 'cat /proc/uptime' -AllowFailure).Text.Split(' ')[0]
    [void]$Context.Markers.Add([pscustomobject]@{ name=$Name; hostTime=(Get-Date).ToUniversalTime().ToString('o'); deviceUptimeSec=$uptime; note=$Note })
}

function Save-GpkMarkers {
    param($Context)
    $path=Join-Path $Context.RawRoot 'markers.csv'
    if($Context.Markers.Count -gt 0){$Context.Markers|Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8}else{Set-Content -LiteralPath $path -Value 'name,hostTime,deviceUptimeSec,note' -Encoding UTF8}
}

function Get-GpkSurfaceSummary {
    param([string]$Path,[string]$PackageName)
    $result=[ordered]@{ available=$false; averageFps=$null; frameCount=$null; p95Ms=$null; p99Ms=$null; maxMs=$null; over50Ms=$null; over66_7Ms=$null; over100Ms=$null }
    if(-not(Test-Path -LiteralPath $Path)){return $result}
    $text=Get-Content -LiteralPath $Path -Raw
    $pos=$text.IndexOf($PackageName,[StringComparison]::OrdinalIgnoreCase)
    if($pos -lt 0){return $result}
    $next=$text.IndexOf('layerName',$pos+10,[StringComparison]::OrdinalIgnoreCase);if($next -lt 0){$next=[math]::Min($text.Length,$pos+20000)}
    $section=$text.Substring($pos,$next-$pos)
    if($section -match '(?im)averageFPS\s*=\s*([0-9.]+)'){$result.averageFps=[math]::Round([double]$Matches[1],3);$result.available=$true}
    if($section -match '(?im)totalFrames\s*=\s*(\d+)'){$result.frameCount=[int64]$Matches[1]}
    # AOSP commonly writes "presentToPresentHistogram = 16: 10, ..." while
    # Huawei/HarmonyOS writes "present2present histogram:" followed by
    # one or more "16ms=10" lines. Parse the contiguous bucket block after
    # either header so that a later histogram in the same layer is not mixed in.
    $buckets=@()
    $histHeader=[regex]::Match($section,'(?im)(?:presentToPresentHistogram|present2present\s+histogram)\s*(?:is\s+as\s+below\s*)?[:=]\s*')
    if($histHeader.Success){
        $histTail=$section.Substring($histHeader.Index+$histHeader.Length)
        $foundBucket=$false
        foreach($line in ($histTail -split '\r?\n')){
            $lineBuckets=[regex]::Matches($line,'(?i)(\d+(?:\.\d+)?)\s*(?:ms)?\s*[:=]\s*(\d+)')
            if($lineBuckets.Count -gt 0){
                $foundBucket=$true
                foreach($m in $lineBuckets){$buckets += [pscustomobject]@{ms=[double]$m.Groups[1].Value;count=[int64]$m.Groups[2].Value}}
            }elseif($foundBucket -and -not [string]::IsNullOrWhiteSpace($line)){
                break
            }
        }
    }
    if($buckets.Count -gt 0){
        $total=($buckets|Measure-Object count -Sum).Sum;$cum=0;$p95=$null;$p99=$null
        foreach($b in ($buckets|Sort-Object ms)){$cum+=$b.count;if($null-eq$p95-and$cum-ge$total*.95){$p95=$b.ms};if($null-eq$p99-and$cum-ge$total*.99){$p99=$b.ms}}
        $result.p95Ms=$p95;$result.p99Ms=($p99);$result.maxMs=(($buckets|Where-Object count -gt 0|Measure-Object ms -Maximum).Maximum)
        $over50=0L;$over667=0L;$over100=0L
        foreach($b in $buckets){if($b.ms -gt 50){$over50+=$b.count};if($b.ms -gt 66.7){$over667+=$b.count};if($b.ms -gt 100){$over100+=$b.count}}
        $result.over50Ms=$over50;$result.over66_7Ms=$over667;$result.over100Ms=$over100
    }
    return $result
}

function Get-GpkSampleSummary {
    param($Context)
    $path=Join-Path $Context.ResultRoot 'samples.csv'
    $r=@();if(Test-Path -LiteralPath $path){$r=@(Import-Csv -LiteralPath $path)}
    $o=[ordered]@{sampleCount=$r.Count;durationSec=0;processCpuAvgPct=$null;unityMainCpuAvgPct=$null;rssAvgMiB=$null;rssPeakMiB=$null;rssDeltaMiB=$null;memAvailableMinMiB=$null;swapUsedPeakMiB=$null;thermalMaxC=$null}
    if($r.Count -eq 0){return $o}
    $o.durationSec=[double]$r[-1].time_s
    foreach($spec in @(@('process_cpu_pct','processCpuAvgPct','Average'),@('unitymain_cpu_pct','unityMainCpuAvgPct','Average'),@('rss_mib','rssAvgMiB','Average'),@('rss_mib','rssPeakMiB','Maximum'),@('mem_available_mib','memAvailableMinMiB','Minimum'),@('swap_used_mib','swapUsedPeakMiB','Maximum'),@('thermal_max_c','thermalMaxC','Maximum'))){
        $vals=@($r|Where-Object{$_.$($spec[0]) -ne ''}|ForEach-Object{[double]$_.$($spec[0])})
        if($vals.Count){
            $measureArgs=@{}
            $measureArgs[$spec[2]]=$true
            $m=$vals|Measure-Object @measureArgs
            $v=$m.$($spec[2]);$o[$spec[1]]=[math]::Round([double]$v,2)
        }
    }
    $o.rssDeltaMiB=[math]::Round(([double]$r[-1].rss_mib-[double]$r[0].rss_mib),2)
    return $o
}

function New-GpkSummary {
    param($Context,[string]$Status='completed',$Extra=@{})
    $sf=Get-GpkSurfaceSummary -Path (Join-Path $Context.RawRoot 'surfaceflinger-final.txt') -PackageName $Context.Config.packageName
    $samples=Get-GpkSampleSummary -Context $Context
    $perfetto=Get-GpkPerfettoSummary -Context $Context
    $quality='valid';if(-not $sf.available){$quality='partial'};if($samples.sampleCount -lt 2){$quality='partial'};if($perfetto.requested -and -not $perfetto.captureCompleted){$quality='partial'}
    return [ordered]@{
        schemaVersion=1;status=$Status;dataQuality=$quality;caseName=$Context.CaseName;targetFps=[double]$Context.Config.targetFps
        startedAt=$Context.StartedAt;finishedAt=(Get-Date).ToUniversalTime().ToString('o');surfaceFlinger=$sf;samples=$samples;perfetto=$perfetto
        warnings=@($Context.Warnings);extra=$Extra
    }
}

function Get-GpkPropertyValue {
    param($Object,[string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [System.Collections.IDictionary]){
        if($Object.Contains($Name)){return $Object[$Name]}
        return $null
    }
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}

function ConvertTo-GpkHtml {
    param([AllowNull()]$Value)
    if($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)){return '<span class="muted">无数据</span>'}
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-GpkReportRow {
    param([string]$Label,[AllowNull()]$Value,[string]$Unit='')
    $display=ConvertTo-GpkHtml $Value
    if($display -notmatch '^<span' -and $Unit){$display+=[System.Net.WebUtility]::HtmlEncode($Unit)}
    return "<tr><th>$([System.Net.WebUtility]::HtmlEncode($Label))</th><td>$display</td></tr>"
}

function Write-GpkHtmlReport {
    param($Context,$Summary,$Metadata)
    $sf=Get-GpkPropertyValue $Summary 'surfaceFlinger'
    $samples=Get-GpkPropertyValue $Summary 'samples'
    $perfetto=Get-GpkPropertyValue $Summary 'perfetto'
    $status=Get-GpkPropertyValue $Summary 'status'
    $quality=Get-GpkPropertyValue $Summary 'dataQuality'
    $target=[double]$Context.Config.targetFps
    $findings=New-Object System.Collections.ArrayList
    if($status -and $status -ne 'completed'){[void]$findings.Add(@('bad',"测试状态为 $status，请先检查原始记录和错误信息。"))}
    if($quality -eq 'partial'){[void]$findings.Add(@('warn','本轮数据质量为部分有效：部分采集通道缺失，结论应结合原始文件。'))}
    if($sf){
        $fps=Get-GpkPropertyValue $sf 'averageFps'
        if($null -ne $fps){
            if([double]$fps -lt $target*0.9){[void]$findings.Add(@('bad',("平均FPS {0}，低于目标FPS的90%。" -f $fps)))}
            elseif([double]$fps -lt $target*0.98){[void]$findings.Add(@('warn',("平均FPS {0}，略低于目标 {1}。" -f $fps,$target)))}
            else{[void]$findings.Add(@('ok',("平均FPS {0}，接近目标 {1}。" -f $fps,$target)))}
        }else{[void]$findings.Add(@('warn','SurfaceFlinger未给出平均FPS。'))}
        $p95=Get-GpkPropertyValue $sf 'p95Ms';if($null -ne $p95 -and [double]$p95 -gt (2000/$target)){[void]$findings.Add(@('warn',("P95帧时间 {0}ms，已超过目标帧时长的2倍。" -f $p95)))}
        $over100=Get-GpkPropertyValue $sf 'over100Ms';if($null -ne $over100 -and [int64]$over100 -gt 0){[void]$findings.Add(@('warn',("发现 {0} 个大于100ms的严重长帧。" -f $over100)))}
    }
    if($samples){
        $sampleCount=Get-GpkPropertyValue $samples 'sampleCount'
        if($null -ne $sampleCount -and [int]$sampleCount -lt 2){[void]$findings.Add(@('bad','系统采样点不足2个，CPU/内存/温度趋势不可判定。'))}
        $rssDelta=Get-GpkPropertyValue $samples 'rssDeltaMiB';if($null -ne $rssDelta -and [double]$rssDelta -gt 200){[void]$findings.Add(@('warn',("测试窗口内RSS增加 {0}MiB，建议做内存恢复节点复测。" -f $rssDelta)))}
    }
    if($perfetto -and (Get-GpkPropertyValue $perfetto 'requested')){
        if(Get-GpkPropertyValue $perfetto 'captureCompleted'){[void]$findings.Add(@('ok','Perfetto trace已成功封装，可用Perfetto UI进行线程级分析。'))}
        else{[void]$findings.Add(@('bad','已请求Perfetto，但trace未完整生成。'))}
    }
    foreach($warning in @(Get-GpkPropertyValue $Summary 'warnings')){if($warning){[void]$findings.Add(@('warn',[string]$warning))}}
    if($findings.Count -eq 0){[void]$findings.Add(@('ok','本轮未触发自动风险规则；请结合实际操作和原始记录确认。'))}

    $identityRows=@(
        (New-GpkReportRow '游戏名称' $Context.GameName),(New-GpkReportRow '包名' $Context.Config.packageName),
        (New-GpkReportRow '测试用例' $Context.CaseName),(New-GpkReportRow '设备标签' $Context.Config.deviceLabel),
        (New-GpkReportRow '设备序列号' $script:DeviceSerial),(New-GpkReportRow '目标FPS' $target),
        (New-GpkReportRow '开始时间(UTC)' $Context.StartedAt),(New-GpkReportRow '数据质量' $quality)
    ) -join "`n"
    $metricRows=New-Object System.Collections.ArrayList
    if($sf){
        foreach($spec in @(@('平均FPS','averageFps',''),@('帧数','frameCount',''),@('P95帧时间','p95Ms',' ms'),@('P99帧时间','p99Ms',' ms'),@('最大帧时间','maxMs',' ms'),@('>100ms长帧','over100Ms',''))){[void]$metricRows.Add((New-GpkReportRow $spec[0] (Get-GpkPropertyValue $sf $spec[1]) $spec[2]))}
    }
    if($samples){
        foreach($spec in @(@('系统采样数','sampleCount',''),@('采样时长','durationSec',' s'),@('进程CPU平均','processCpuAvgPct','%'),@('UnityMain CPU平均','unityMainCpuAvgPct','%'),@('RSS平均','rssAvgMiB',' MiB'),@('RSS峰值','rssPeakMiB',' MiB'),@('RSS变化','rssDeltaMiB',' MiB'),@('最低可用内存','memAvailableMinMiB',' MiB'),@('最高温度','thermalMaxC',' °C'))){[void]$metricRows.Add((New-GpkReportRow $spec[0] (Get-GpkPropertyValue $samples $spec[1]) $spec[2]))}
    }
    if($perfetto -and (Get-GpkPropertyValue $perfetto 'requested')){
        foreach($spec in @(@('Perfetto类型','profile',''),@('Trace完整','captureCompleted',''),@('Trace大小','traceSizeBytes',' bytes'))){[void]$metricRows.Add((New-GpkReportRow $spec[0] (Get-GpkPropertyValue $perfetto $spec[1]) $spec[2]))}
    }
    if($metricRows.Count -eq 0){[void]$metricRows.Add((New-GpkReportRow '说明' '本用例主要生成设备预检或原始能力记录。'))}
    $findingHtml=($findings|ForEach-Object{'<li class="{0}">{1}</li>' -f $_[0],[System.Net.WebUtility]::HtmlEncode([string]$_[1])}) -join "`n"
    $generated=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $html=@"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AndroidGamePerfKit - $([System.Net.WebUtility]::HtmlEncode($Context.GameName)) - $([System.Net.WebUtility]::HtmlEncode($Context.CaseName))</title>
<style>body{font-family:"Microsoft YaHei",Segoe UI,sans-serif;margin:0;background:#f4f6f8;color:#18212b}.wrap{max-width:980px;margin:28px auto;padding:0 18px}.card{background:#fff;border:1px solid #dfe4ea;border-radius:12px;padding:20px;margin:14px 0;box-shadow:0 3px 14px #16202a0c}h1{font-size:25px;margin:0 0 6px}h2{font-size:18px;margin:0 0 12px}.sub,.muted{color:#68737f}table{width:100%;border-collapse:collapse}th,td{padding:9px 12px;border-bottom:1px solid #edf0f2;text-align:left}th{width:42%;color:#53606c;font-weight:500}ul{padding-left:22px}li{padding:6px 8px;margin:5px 0;border-radius:6px}.ok{background:#eaf7ef;color:#176b3a}.warn{background:#fff6dc;color:#795800}.bad{background:#fdeceb;color:#9c2d26}.foot{font-size:13px;color:#68737f}</style></head><body><main class="wrap">
<div class="card"><h1>AndroidGamePerfKit 自动测试报告</h1><div class="sub">$([System.Net.WebUtility]::HtmlEncode($Context.GameName)) · $([System.Net.WebUtility]::HtmlEncode($Context.CaseName)) · $([System.Net.WebUtility]::HtmlEncode($Context.Timestamp))</div></div>
<section class="card"><h2>测试身份</h2><table>$identityRows</table></section>
<section class="card"><h2>自动判读</h2><ul>$findingHtml</ul></section>
<section class="card"><h2>核心指标</h2><table>$($metricRows -join "`n")</table></section>
<section class="card foot">报告生成时间：$generated。本报告用于离线初筛，不替代对游戏操作、logcat及Perfetto时间线的人工核对。详细数据见同目录 metadata.json、summary.json、samples.csv 和 raw。</section>
</main></body></html>
"@
    [System.IO.File]::WriteAllText((Join-Path $Context.ResultRoot 'report.html'),$html,(New-Object System.Text.UTF8Encoding($false)))
}

function Complete-GpkRun {
    param($Context,$Summary)
    Save-GpkMarkers $Context
    $cfgCopy=ConvertTo-GpkHashtable $Context.Config;$cfgCopy.Remove('_configPath');$cfgCopy.Remove('_durationOverrideSec')
    $meta=[ordered]@{
        schemaVersion=1;kit='AndroidGamePerfKit';kitVersion=$script:GpkVersion;gameName=$Context.GameName;caseName=$Context.CaseName
        timestamp=$Context.Timestamp;deviceLabel=$Context.Config.deviceLabel;deviceSerial=$script:DeviceSerial;packageName=$Context.Config.packageName
        targetFps=$Context.Config.targetFps;config=$cfgCopy;host=[ordered]@{computer=$env:COMPUTERNAME;powerShell=$PSVersionTable.PSVersion.ToString();os=[Environment]::OSVersion.VersionString}
    }
    Write-GpkJson -Path (Join-Path $Context.ResultRoot 'metadata.json') -Object $meta
    Write-GpkJson -Path (Join-Path $Context.ResultRoot 'summary.json') -Object $Summary
    if(-not(Test-Path -LiteralPath (Join-Path $Context.ResultRoot 'samples.csv'))){Set-Content -LiteralPath (Join-Path $Context.ResultRoot 'samples.csv') -Value 'time_s,pid,process_cpu_pct,main_cpu_pct,unitymain_cpu_pct,gfx_cpu_pct,job_cpu_pct,rss_mib,mem_available_mib,swap_used_mib,cpu_freq_avg_mhz,thermal_max_c,battery_pct' -Encoding UTF8}
    Write-GpkHtmlReport -Context $Context -Summary $Summary -Metadata $meta
    if(Test-Path -LiteralPath $Context.ZipPath){Remove-Item -LiteralPath $Context.ZipPath -Force}
    Compress-Archive -Path (Join-Path $Context.ResultRoot '*') -DestinationPath $Context.ZipPath -Force
    Write-Host "Report: $(Join-Path $Context.ResultRoot 'report.html')" -ForegroundColor Green
    if($Context.CleanupSucceeded -and (Test-Path -LiteralPath $Context.StatePath)){Remove-Item -LiteralPath $Context.StatePath -Force -ErrorAction SilentlyContinue}
}

function Invoke-GpkCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$KitRoot,[Parameter(Mandatory=$true)]$Config,[switch]$VerboseOutput)
    try{Select-GpkDevice $Config|Out-Null}catch{if($VerboseOutput){Write-Warning $_};return}
    $statePath=Join-Path $KitRoot '.state\active-run.json';$state=$null
    if(Test-Path -LiteralPath $statePath){try{$state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json}catch{}}
    $verified=$true
    if($state){
        if($state.PSObject.Properties['perfettoPid'] -and $state.perfettoPid){Invoke-GpkShell -Config $Config -Command "if test -r /proc/$($state.perfettoPid)/cmdline && grep -aq perfetto /proc/$($state.perfettoPid)/cmdline; then kill -2 $($state.perfettoPid) 2>/dev/null; fi" -AllowFailure|Out-Null;Start-Sleep -Milliseconds 800}
        if($state.remoteStopFile){Invoke-GpkShell -Config $Config -Command "touch $($state.remoteStopFile)" -AllowFailure|Out-Null}
        if($state.remoteSamplerPid){Invoke-GpkShell -Config $Config -Command "kill $($state.remoteSamplerPid) 2>/dev/null" -AllowFailure|Out-Null}
        foreach($f in @($state.remoteFiles)){if($f -and $f -like '/data/local/tmp/gpk_*'){Invoke-GpkShell -Config $Config -Command "rm -f $f" -AllowFailure|Out-Null}}
        if($state.PSObject.Properties['perfettoFiles']){
            foreach($f in @($state.perfettoFiles)){
                if($f -and ($f -like '/data/local/tmp/gpk_perfetto_*' -or $f -like '/data/misc/perfetto-traces/gpk_*.perfetto-trace')){Invoke-GpkShell -Config $Config -Command "rm -f $f" -AllowFailure|Out-Null}
            }
        }
        if($state.fillerPath -and $state.fillerPath -like '/data/local/tmp/gpk_storage_filler_*'){
            Invoke-GpkShell -Config $Config -Command "rm -f $($state.fillerPath)" -AllowFailure|Out-Null
            $fillerCheck=Invoke-GpkShell -Config $Config -Command "test ! -e $($state.fillerPath)" -AllowFailure
            if($fillerCheck.ExitCode -ne 0){$verified=$false}
        }
        foreach($p in @($state.backgroundPackages)){if($p -match '^[A-Za-z0-9_.]+$'){Invoke-GpkShell -Config $Config -Command "am force-stop $p" -AllowFailure|Out-Null}}
        if($state.batteryUnplugged){Invoke-GpkShell -Config $Config -Command 'dumpsys battery reset' -AllowFailure|Out-Null}
        if($state.lowPowerBefore -match '^[01]$'){Invoke-GpkShell -Config $Config -Command "settings put global low_power $($state.lowPowerBefore)" -AllowFailure|Out-Null}else{Invoke-GpkShell -Config $Config -Command 'settings put global low_power 0' -AllowFailure|Out-Null}
        if($state.lowPowerBefore -match '^[01]$'){
            $restoredLow=(Invoke-GpkShell -Config $Config -Command 'settings get global low_power' -AllowFailure).Text.Trim()
            if($restoredLow -ne [string]$state.lowPowerBefore){$verified=$false}
        }
    } else {
        Invoke-GpkShell -Config $Config -Command 'settings put global low_power 0' -AllowFailure|Out-Null
        Invoke-GpkShell -Config $Config -Command 'dumpsys battery reset' -AllowFailure|Out-Null
        Invoke-GpkShell -Config $Config -Command "rm -f /data/local/tmp/gpk_stop_* /data/local/tmp/gpk_sampler_* /data/local/tmp/gpk_samples_* /data/local/tmp/gpk_storage_filler_*" -AllowFailure|Out-Null
    }
    # Always sweep only the toolkit-owned namespace. This covers a host crash in
    # the small window before active-run.json was updated with the Perfetto PID.
    Invoke-GpkShell -Config $Config -Command 'rm -f /data/local/tmp/gpk_perfetto_* /data/misc/perfetto-traces/gpk_*.perfetto-trace' -AllowFailure|Out-Null
    Invoke-GpkShell -Config $Config -Command 'dumpsys SurfaceFlinger --timestats -disable' -AllowFailure|Out-Null
    if($verified){if(Test-Path -LiteralPath $statePath){Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue}}
    else{throw "Cleanup verification failed. State was preserved at $statePath; reconnect the device and run -Command cleanup again."}
    if($VerboseOutput){Write-Host 'Cleanup complete. Battery simulation, Battery Saver, filler files, collectors, and toolkit-started background apps were restored/removed.' -ForegroundColor Green}
}

Export-ModuleMember -Function *-Gpk*
