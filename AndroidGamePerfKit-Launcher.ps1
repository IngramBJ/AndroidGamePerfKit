[CmdletBinding()]
param(
    [string]$Config,
    [ValidateSet('menu','preflight','quick','cleanup','smoke')]
    [string]$Action = 'menu'
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
Set-Location $PSScriptRoot

$script:MainScript=Join-Path $PSScriptRoot 'AndroidGamePerfKit.ps1'
$script:StateDir=Join-Path $PSScriptRoot '.state'
$script:RuntimeConfig=Join-Path $script:StateDir 'runtime-config.json'
$script:CurrentConfig=$null
$script:CurrentProfile=$null
$script:DeviceInfo=[pscustomobject]@{connected=$false;serial='';manufacturer='';model='';resolution='unknown';foregroundPackage='';message='not scanned'}

Import-Module (Join-Path $PSScriptRoot 'lib\AndroidGamePerfKit.Core.psm1') -Force

if(-not ('AndroidGamePerfKit.ConsoleCancel' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace AndroidGamePerfKit {
    public static class ConsoleCancel {
        private enum CtrlType : uint {
            CtrlC = 0,
            CtrlBreak = 1,
            CtrlClose = 2,
            CtrlLogoff = 5,
            CtrlShutdown = 6
        }

        private delegate bool HandlerRoutine(CtrlType ctrlType);
        private static HandlerRoutine handler;
        public static volatile bool Requested;

        [DllImport("Kernel32")]
        private static extern bool SetConsoleCtrlHandler(HandlerRoutine handler, bool add);

        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int virtualKey);

        private static bool HandleControl(CtrlType ctrlType) {
            if(ctrlType == CtrlType.CtrlC || ctrlType == CtrlType.CtrlBreak) {
                Requested = true;
                return true;
            }
            return false;
        }

        public static bool Install() {
            Requested = false;
            if(handler == null) handler = HandleControl;
            return SetConsoleCtrlHandler(handler, true);
        }

        public static bool IsCancellationRequested() {
            if(Requested) return true;
            bool controlDown = (GetAsyncKeyState(0x11) & 0x8000) != 0;
            bool cDown = (GetAsyncKeyState(0x43) & 0x8000) != 0;
            bool f12Down = (GetAsyncKeyState(0x7B) & 0x8000) != 0;
            return (controlDown && cDown) || f12Down;
        }

        public static void Uninstall() {
            if(handler != null) SetConsoleCtrlHandler(handler, false);
            Requested = false;
        }
    }
}
'@
}

function Write-LauncherHeader {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' AndroidGamePerfKit v1.4.0 - 运行时配置控制台' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    if($script:CurrentProfile){
        $deviceText=if($script:DeviceInfo.connected){"$($script:CurrentProfile.deviceLabel) [$($script:DeviceInfo.serial)]"}else{'未连接或尚未识别'}
        $packageText=if($script:CurrentProfile.packageName -eq 'com.example.game'){'未设置（请按 S 识别前台游戏）'}else{$script:CurrentProfile.packageName}
        $gameText=if($script:CurrentProfile.PSObject.Properties['gameName']){[string]$script:CurrentProfile.gameName}else{[string]$script:CurrentProfile.profileName}
        Write-Host (" 游戏名称 : {0}" -f $gameText) -ForegroundColor White
        Write-Host (" 设备     : {0}" -f $deviceText) -ForegroundColor White
        Write-Host (" 分辨率   : {0}" -f $script:DeviceInfo.resolution) -ForegroundColor Gray
        Write-Host (" 游戏包名 : {0}" -f $packageText) -ForegroundColor Gray
        Write-Host (" 目标FPS  : {0}" -f $script:CurrentProfile.targetFps) -ForegroundColor Gray
        $long=$script:CurrentProfile.cases.longrun
        Write-Host (" 长稳参数 : 单局{0}s，点击步骤{1}个" -f $long.automation.battleSeconds,@($long.automation.taps).Count) -ForegroundColor DarkGray
    }
    Write-Host '============================================================' -ForegroundColor DarkCyan
}

function Pause-Launcher {
    param([string]$Message='按 Enter 返回主菜单')
    [void](Read-Host $Message)
}

function Get-ConfigProfile {
    param([string]$Path)
    try{return Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}catch{throw "配置文件无法读取：$Path`n$($_.Exception.Message)"}
}

function Save-LauncherRuntimeProfile {
    New-Item -ItemType Directory -Force -Path $script:StateDir|Out-Null
    Write-GpkJson -Path $script:RuntimeConfig -Object $script:CurrentProfile
    $script:CurrentConfig=$script:RuntimeConfig
}

function Initialize-LauncherProfile {
    param([string]$Requested,[switch]$SkipDeviceScan)
    $source=$null
    if($Requested){$source=(Resolve-Path -LiteralPath $Requested).Path}
    elseif(Test-Path -LiteralPath $script:RuntimeConfig){$source=$script:RuntimeConfig}
    else{$source=Join-Path $PSScriptRoot 'configs\generic-example.json'}
    $script:CurrentProfile=Get-ConfigProfile $source
    $script:CurrentConfig=$source
    if($SkipDeviceScan){return}
    [void](Update-LauncherDeviceInfo -DetectForeground)
    Save-LauncherRuntimeProfile
}

function Update-LauncherDeviceInfo {
    param([switch]$DetectForeground)
    try{
        try{$serial=Select-GpkDevice -Config $script:CurrentProfile}catch{
            if($script:CurrentProfile.deviceSerial){$script:CurrentProfile.deviceSerial='';$serial=Select-GpkDevice -Config $script:CurrentProfile}else{throw}
        }
        $manufacturer=(Invoke-GpkShell -Config $script:CurrentProfile -Command 'getprop ro.product.manufacturer' -AllowFailure).Text.Trim()
        $model=(Invoke-GpkShell -Config $script:CurrentProfile -Command 'getprop ro.product.model' -AllowFailure).Text.Trim()
        $sizeText=(Invoke-GpkShell -Config $script:CurrentProfile -Command 'wm size' -AllowFailure).Text
        $resolution='unknown';if($sizeText -match '(\d{3,5}x\d{3,5})'){$resolution=$Matches[1]}
        $foreground=''
        if($DetectForeground){
            $activityText=(Invoke-GpkShell -Config $script:CurrentProfile -Command 'dumpsys activity activities' -AllowFailure).Text
            if($activityText -match '(?im)mResumedActivity.*?\s([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)/'){$foreground=$Matches[1]}
        }
        $label=(($manufacturer+' '+$model).Trim() -replace '\s+','-')
        if([string]::IsNullOrWhiteSpace($label) -or $label -match '^(OK-?)+$'){$label='Android-'+$serial}
        $script:DeviceInfo=[pscustomobject]@{connected=$true;serial=$serial;manufacturer=$manufacturer;model=$model;resolution=$resolution;foregroundPackage=$foreground;message='ready'}
        $script:CurrentProfile.deviceSerial=$serial
        $script:CurrentProfile.deviceLabel=$label
        return $true
    }catch{
        $script:DeviceInfo=[pscustomobject]@{connected=$false;serial='';manufacturer='';model='';resolution='unknown';foregroundPackage='';message=$_.Exception.Message}
        return $false
    }
}

function Read-LauncherInteger {
    param([string]$Prompt,[int]$Default,[int]$Minimum=0,[int]$Maximum=2147483647)
    while($true){
        $value=(Read-Host "$Prompt [$Default]").Trim();if(-not $value){return $Default}
        $parsed=0;if([int]::TryParse($value,[ref]$parsed) -and $parsed -ge $Minimum -and $parsed -le $Maximum){return $parsed}
        Write-Host "请输入 $Minimum 到 $Maximum 之间的整数。" -ForegroundColor Yellow
    }
}

function Read-LauncherNumber {
    param([string]$Prompt,[double]$Default,[double]$Minimum=0.1,[double]$Maximum=100000)
    while($true){
        $value=(Read-Host "$Prompt [$Default]").Trim();if(-not $value){return $Default}
        $parsed=0.0
        if([double]::TryParse($value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::CurrentCulture,[ref]$parsed) -or [double]::TryParse($value,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$parsed)){
            if($parsed -ge $Minimum -and $parsed -le $Maximum){return $parsed}
        }
        Write-Host "请输入 $Minimum 到 $Maximum 之间的数字。" -ForegroundColor Yellow
    }
}

function Read-LauncherYesNo {
    param([string]$Prompt,[bool]$Default=$true)
    $hint=if($Default){'Y/n'}else{'y/N'}
    while($true){$v=(Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant();if(-not $v){return $Default};if($v -in @('y','yes')){return $true};if($v -in @('n','no')){return $false}}
}

function Read-LauncherIntegerList {
    param([string]$Prompt,[int[]]$Default)
    $defaultText=($Default -join ',')
    while($true){
        $text=(Read-Host "$Prompt [$defaultText]").Trim();if(-not $text){return @($Default)}
        $values=@();$valid=$true
        foreach($part in @($text -split ',')){$n=0;if(-not [int]::TryParse($part.Trim(),[ref]$n) -or $n -lt 0){$valid=$false;break};$values+=$n}
        if($valid -and $values.Count -gt 0){return @($values|Sort-Object -Unique)}
        Write-Host '请输入逗号分隔的非负整数，例如 0,30,60,180。' -ForegroundColor Yellow
    }
}

function Read-LauncherPerfettoProfile {
    param([string]$Default='balanced')
    Write-Host 'Perfetto类型：[1] 综合  [2] CPU/卡顿  [3] 首次加载/I/O' -ForegroundColor Cyan
    $defaultChoice=switch($Default){'cpu-jank'{'2'}'load-io'{'3'}default{'1'}}
    while($true){
        $choice=(Read-Host "请选择 [$defaultChoice]").Trim();if(-not $choice){$choice=$defaultChoice}
        switch($choice){'1'{return 'balanced'}'2'{return 'cpu-jank'}'3'{return 'load-io'}default{Write-Host '请输入 1、2 或 3。' -ForegroundColor Yellow}}
    }
}

function Set-LauncherGameAndDevice {
    Write-LauncherHeader
    Write-Host '请先连接手机、解锁，并把目标游戏切换到前台。' -ForegroundColor Yellow
    Pause-Launcher '准备好后按 Enter 自动识别'
    if(-not(Update-LauncherDeviceInfo -DetectForeground)){
        Write-Host "识别失败：$($script:DeviceInfo.message)" -ForegroundColor Red;Pause-Launcher;return $false
    }
    $detected=$script:DeviceInfo.foregroundPackage
    $current=[string]$script:CurrentProfile.packageName
    if($detected){Write-Host "检测到前台包名：$detected" -ForegroundColor Green;$defaultPackage=$detected}else{$defaultPackage=$current;Write-Host '未能识别前台应用，可直接输入包名。' -ForegroundColor Yellow}
    $package=(Read-Host "游戏包名 [$defaultPackage]").Trim();if(-not $package){$package=$defaultPackage}
    if($package -notmatch '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$'){Write-Host '包名格式无效。' -ForegroundColor Red;Pause-Launcher;return $false}
    $fps=Read-LauncherNumber -Prompt '目标FPS' -Default ([double]$script:CurrentProfile.targetFps) -Minimum 1 -Maximum 240
    $defaultGameName=if($script:CurrentProfile.PSObject.Properties['gameName'] -and -not [string]::IsNullOrWhiteSpace([string]$script:CurrentProfile.gameName)){[string]$script:CurrentProfile.gameName}else{$package.Split('.')[-1]}
    $gameName=(Read-Host "游戏显示名称（用于结果目录） [$defaultGameName]").Trim();if(-not $gameName){$gameName=$defaultGameName}
    $script:CurrentProfile.packageName=$package;$script:CurrentProfile.activity='auto';$script:CurrentProfile.targetFps=$fps
    $script:CurrentProfile|Add-Member -NotePropertyName gameName -NotePropertyValue $gameName -Force
    $script:CurrentProfile.profileName="$gameName / $package / $($script:CurrentProfile.deviceLabel)"
    Save-LauncherRuntimeProfile
    Write-Host '设备与游戏信息已保存为本机运行时会话，无需编辑JSON。' -ForegroundColor Green
    Pause-Launcher
    return $true
}

function Test-LauncherTargetReady {
    if(-not $script:DeviceInfo.connected){[void](Update-LauncherDeviceInfo -DetectForeground)}
    if(-not $script:DeviceInfo.connected){Write-Host "设备未就绪：$($script:DeviceInfo.message)" -ForegroundColor Red;return $false}
    if($script:CurrentProfile.packageName -eq 'com.example.game'){Write-Host '尚未设置目标游戏，请先按 S 自动识别。' -ForegroundColor Yellow;return $false}
    Save-LauncherRuntimeProfile
    return $true
}

function ConvertTo-LauncherNativeArgument {
    param([string]$Value)
    return '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}

function Stop-LauncherProcessTree {
    param([System.Diagnostics.Process]$Process)
    if(-not $Process){return}
    try{$Process.Refresh()}catch{}
    try{if($Process.HasExited){return}}catch{return}
    $taskkill=Join-Path $env:SystemRoot 'System32\taskkill.exe'
    try{
        if(Test-Path -LiteralPath $taskkill){& $taskkill /PID $Process.Id /T /F 2>$null|Out-Null}
        else{$Process.Kill()}
    }catch{try{$Process.Kill()}catch{}}
    try{[void]$Process.WaitForExit(3000)}catch{}
}

function Invoke-KitChild {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('preflight','run','cleanup')][string]$Command,
        [string]$Case,
        [int]$DurationSec=0,
        [switch]$Perfetto,
        [string]$PerfettoProfile='balanced',
        [int]$PerfettoDurationSec=0,
        [switch]$Recovery
    )
    $childArgs=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$script:MainScript,'-Command',$Command,'-Config',$script:CurrentConfig)
    if($Case){$childArgs+=@('-Case',$Case)}
    if($DurationSec -gt 0){$childArgs+=@('-DurationSec',[string]$DurationSec)}
    if($Perfetto){$childArgs+=@('-Perfetto','-PerfettoProfile',$PerfettoProfile,'-PerfettoDurationSec',[string]$PerfettoDurationSec)}
    Write-Host ''
    if($Recovery){Write-Host '正在执行自动恢复...' -ForegroundColor Cyan}
    else{Write-Host '正在启动测试。测试过程中按 Ctrl+C（或 F12）可中止本轮并返回菜单。' -ForegroundColor Cyan}
    $quotedArgs=@($childArgs|ForEach-Object{ConvertTo-LauncherNativeArgument ([string]$_)})
    $argumentLine=$quotedArgs -join ' '
    $proc=$null;$exitCode=1;$cancelled=$false;$handlerInstalled=$false
    try{
        try{$handlerInstalled=[AndroidGamePerfKit.ConsoleCancel]::Install()}catch{$handlerInstalled=$false}
        $proc=Start-Process -FilePath 'powershell.exe' -ArgumentList $argumentLine -NoNewWindow -PassThru
        # Windows PowerShell 5.1 requires the native process handle to be materialized before ExitCode is reliable.
        $processHandle=$proc.Handle
        $testCancelDeadline=$null
        if($env:GPK_LAUNCHER_TEST_CANCEL_MS -match '^\d+$'){$testCancelDeadline=[DateTime]::UtcNow.AddMilliseconds([int]$env:GPK_LAUNCHER_TEST_CANCEL_MS)}
        while($true){
            $cancelKey=$false
            try{$cancelKey=[AndroidGamePerfKit.ConsoleCancel]::IsCancellationRequested()}catch{}
            if($cancelKey -or ($testCancelDeadline -and [DateTime]::UtcNow -ge $testCancelDeadline)){$cancelled=$true;break}
            if($proc.WaitForExit(100)){break}
            $proc.Refresh()
        }
        try{if([AndroidGamePerfKit.ConsoleCancel]::IsCancellationRequested()){$cancelled=$true}}catch{}
        if($cancelled){
            Write-Host ''
            Write-Host '已收到中止指令，正在终止本轮测试及其子进程...' -ForegroundColor Yellow
            Stop-LauncherProcessTree $proc
            $exitCode=130
        }else{
            $proc.WaitForExit()
            $exitCode=$proc.ExitCode
        }
    } finally {
        if($handlerInstalled){try{[AndroidGamePerfKit.ConsoleCancel]::Uninstall()}catch{}}
        if($proc){try{$proc.Dispose()}catch{}}
    }
    Write-Host ''
    if($cancelled){
        Write-Host '本轮测试已中止。' -ForegroundColor Yellow
        $activeState=Join-Path $PSScriptRoot '.state\active-run.json'
        if($Command -eq 'run' -and -not $Recovery -and (Test-Path -LiteralPath $activeState)){
            $cleanupCode=Invoke-KitChild -Command cleanup -Recovery
            if($cleanupCode -ne 0){Write-Host '自动恢复未完成，请连接设备后从菜单执行 [14] Cleanup恢复设备。' -ForegroundColor Red}
        }
    }elseif($exitCode -eq 0){Write-Host '本项执行完成。' -ForegroundColor Green}
    else{Write-Host "本项执行失败，退出码：$exitCode" -ForegroundColor Red}
    return $exitCode
}

function Invoke-SmokeTest {
    Write-Host '正在运行离线自检...' -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'tests\Run-SmokeTests.ps1') | Out-Host
    $exitCode=$LASTEXITCODE
    if($exitCode -eq 0){Write-Host '离线自检通过。' -ForegroundColor Green}else{Write-Host '离线自检失败，请先处理上方错误。' -ForegroundColor Red}
    return $exitCode
}

function Confirm-LauncherAction {
    param([string]$Prompt,[string]$Required='Y')
    Write-Host $Prompt -ForegroundColor Yellow
    $answer=(Read-Host "输入 $Required 确认，其他内容取消").Trim()
    return ($answer -eq $Required)
}

function Show-LatestResult {
    param([string]$Case)
    $resultsRoot=Join-Path $PSScriptRoot 'results'
    if(Test-Path -LiteralPath $resultsRoot){
        $zip=Get-ChildItem -LiteralPath $resultsRoot -Filter *.zip -File -Recurse|Where-Object{$_.Directory.Name -eq $Case}|Sort-Object LastWriteTime -Descending|Select-Object -First 1
        if($zip){Write-Host "最新结果：$($zip.FullName)" -ForegroundColor Green}
    }
}

function Show-LatestReport {
    $resultsRoot=Join-Path $PSScriptRoot 'results'
    if(-not(Test-Path -LiteralPath $resultsRoot)){Write-Host '尚未生成测试报告。' -ForegroundColor Yellow;Pause-Launcher;return}
    $report=Get-ChildItem -LiteralPath $resultsRoot -Filter report.html -File -Recurse|Sort-Object LastWriteTime -Descending|Select-Object -First 1
    if($report){Start-Process $report.FullName}else{Write-Host '尚未找到report.html。' -ForegroundColor Yellow;Pause-Launcher}
}

function Invoke-QuickValidation {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    Write-LauncherHeader
    Write-Host '一键核心验证将执行：preflight → 等待进入稳定战斗 → 10秒采集。' -ForegroundColor Cyan
    if((Invoke-KitChild -Command preflight) -ne 0){Pause-Launcher '预检失败，按 Enter 返回';return}
    Write-Host ''
    Write-Host '请在手机进入一场稳定战斗，等待资源加载完成。' -ForegroundColor Yellow
    Pause-Launcher '准备好后按 Enter 开始10秒采集'
    $runCode=Invoke-KitChild -Command run -Case 'battle-60s' -DurationSec 10
    if($runCode -eq 0){Show-LatestResult 'battle-60s'}
    Pause-Launcher
}

function Invoke-RuntimeBattle {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $default=[int]$script:CurrentProfile.cases.battle60s.durationSec
    $duration=Read-LauncherInteger -Prompt '本次战斗采集时长（秒）' -Default $default -Minimum 5 -Maximum 14400
    $script:CurrentProfile.cases.battle60s.durationSec=$duration;Save-LauncherRuntimeProfile
    Write-Host '请进入稳定战斗并等待资源加载完成。' -ForegroundColor Yellow;Pause-Launcher '准备好后按 Enter'
    $usePerfetto=Read-LauncherYesNo -Prompt '是否同时录制Perfetto诊断Trace' -Default $false
    if($usePerfetto){$profile=Read-LauncherPerfettoProfile -Default 'cpu-jank';$traceDuration=Read-LauncherInteger -Prompt 'Perfetto录制时长（秒）' -Default ([math]::Min($duration,30)) -Minimum 5 -Maximum ([math]::Min($duration,300))}
    $code=if($usePerfetto){Invoke-KitChild -Command run -Case 'battle-60s' -DurationSec $duration -Perfetto -PerfettoProfile $profile -PerfettoDurationSec $traceDuration}else{Invoke-KitChild -Command run -Case 'battle-60s' -DurationSec $duration}
    if($code -eq 0){Show-LatestResult 'battle-60s'};Pause-Launcher
}

function Invoke-RuntimeLongrun {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    Write-LauncherHeader
    $long=$script:CurrentProfile.cases.longrun;$auto=$long.automation
    $defaultMinutes=[math]::Round(([double]$long.durationSec)/60,2)
    $minutes=Read-LauncherNumber -Prompt '本次长稳总时长（分钟）' -Default $defaultMinutes -Minimum 0.17 -Maximum 240
    $duration=[int][math]::Round($minutes*60)
    $battleSeconds=Read-LauncherInteger -Prompt '每局战斗等待时间（秒）' -Default ([int]$auto.battleSeconds) -Minimum 1 -Maximum 3600
    $enabled=Read-LauncherYesNo -Prompt '是否自动点击重开下一局' -Default ([bool]$auto.enabled)
    $taps=@($auto.taps)
    if($enabled){
        Write-Host "当前分辨率：$($script:DeviceInfo.resolution)。坐标X从左到右，Y从上到下。" -ForegroundColor Cyan
        $reuse=$false;if($taps.Count -gt 0){$reuse=Read-LauncherYesNo -Prompt "复用上次的 $($taps.Count) 个点击步骤" -Default $true}
        if(-not $reuse){
            $count=Read-LauncherInteger -Prompt '一局结束后需要点击几次' -Default ([math]::Max(1,$taps.Count)) -Minimum 1 -Maximum 12
            $newTaps=@()
            $maxX=9999;$maxY=9999
            if($script:DeviceInfo.resolution -match '^(\d+)x(\d+)$'){$maxX=[int]$Matches[1]-1;$maxY=[int]$Matches[2]-1}
            for($i=1;$i -le $count;$i++){
                Write-Host "--- 点击步骤 $i/$count ---" -ForegroundColor Cyan
                $name=(Read-Host "步骤名称 [tap$i]").Trim();if(-not $name){$name="tap$i"}
                $x=Read-LauncherInteger -Prompt 'X坐标' -Default ([int]($maxX/2)) -Minimum 0 -Maximum $maxX
                $y=Read-LauncherInteger -Prompt 'Y坐标' -Default ([int]($maxY/2)) -Minimum 0 -Maximum $maxY
                $delay=Read-LauncherInteger -Prompt '点击后等待（毫秒）' -Default 1500 -Minimum 0 -Maximum 60000
                $newTaps+=,[pscustomobject][ordered]@{name=$name;x=$x;y=$y;delayMs=$delay}
            }
            $taps=@($newTaps)
        }
    }
    $long.durationSec=$duration;$auto.enabled=$enabled;$auto.battleSeconds=$battleSeconds;$auto.taps=@($taps);Save-LauncherRuntimeProfile
    Write-Host ''
    Write-Host ("本次参数：总时长{0}秒；每局{1}秒；自动点击={2}；步骤={3}。" -f $duration,$battleSeconds,$enabled,$taps.Count) -ForegroundColor Green
    Write-Host '请进入第一局稳定战斗。建议新坐标先测试5分钟以内。' -ForegroundColor Yellow
    Pause-Launcher '准备好后按 Enter 开始'
    [void](Invoke-KitChild -Command run -Case 'longrun' -DurationSec $duration);Pause-Launcher
}

function Invoke-RuntimeManualMarker {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.manualMarker
    $duration=Read-LauncherInteger -Prompt '总采集时长（秒）' -Default ([int]$cc.durationSec) -Minimum 2 -Maximum 14400
    while($true){$offsets=Read-LauncherIntegerList -Prompt '事件提示时间点（秒，逗号分隔）' -Default @($cc.offsetsSec);if(($offsets|Measure-Object -Maximum).Maximum -lt $duration){break};Write-Host '所有时间点必须小于总采集时长。' -ForegroundColor Yellow}
    $cc.durationSec=$duration;$cc.offsetsSec=@($offsets);Save-LauncherRuntimeProfile
    Write-Host '请停在马上可以触发目标事件的位置。' -ForegroundColor Yellow;Pause-Launcher '准备好后按 Enter'
    [void](Invoke-KitChild -Command run -Case 'manual-marker' -DurationSec $duration);Pause-Launcher
}

function Invoke-RuntimeFirstLoad {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.firstLoad
    $duration=Read-LauncherInteger -Prompt '总采集时长（秒）' -Default ([int]$cc.durationSec) -Minimum 5 -Maximum 600
    $first=Read-LauncherInteger -Prompt '首次触发提示时间（秒）' -Default ([int]$cc.firstMarkerSec) -Minimum 1 -Maximum ($duration-2)
    $second=Read-LauncherInteger -Prompt '第二次触发提示时间（秒）' -Default ([math]::Min([int]$cc.secondMarkerSec,$duration-1)) -Minimum ($first+1) -Maximum ($duration-1)
    $cc.durationSec=$duration;$cc.firstMarkerSec=$first;$cc.secondMarkerSec=$second;Save-LauncherRuntimeProfile
    Write-Host '请确保目标单位/特效在当前游戏进程中尚未出现。' -ForegroundColor Yellow;Pause-Launcher '准备好后按 Enter'
    $usePerfetto=Read-LauncherYesNo -Prompt '是否同时录制Perfetto诊断Trace' -Default $true
    if($usePerfetto){$traceDuration=Read-LauncherInteger -Prompt 'Perfetto录制时长（秒）' -Default ([math]::Min($duration,60)) -Minimum 5 -Maximum ([math]::Min($duration,300));[void](Invoke-KitChild -Command run -Case 'first-load' -DurationSec $duration -Perfetto -PerfettoProfile 'load-io' -PerfettoDurationSec $traceDuration)}
    else{[void](Invoke-KitChild -Command run -Case 'first-load' -DurationSec $duration)}
    Pause-Launcher
}

function Invoke-RuntimeColdStart {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    Write-Host '脚本会结束并重新启动游戏；按提示确认主页和首战。' -ForegroundColor Yellow
    $usePerfetto=Read-LauncherYesNo -Prompt '是否同时录制Perfetto诊断Trace' -Default $true
    if($usePerfetto){$traceDuration=Read-LauncherInteger -Prompt 'Perfetto录制时长（秒）' -Default 45 -Minimum 10 -Maximum 300}
    Pause-Launcher '确认后按 Enter'
    if($usePerfetto){[void](Invoke-KitChild -Command run -Case 'cold-start-first-battle' -Perfetto -PerfettoProfile 'load-io' -PerfettoDurationSec $traceDuration)}
    else{[void](Invoke-KitChild -Command run -Case 'cold-start-first-battle')}
    Pause-Launcher
}

function Invoke-RuntimePerfetto {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    Write-LauncherHeader
    Write-Host 'Perfetto专项诊断适合复现短时卡顿、加载或线程等待问题。' -ForegroundColor Cyan
    $profile=Read-LauncherPerfettoProfile -Default 'balanced'
    $duration=Read-LauncherInteger -Prompt '录制时长（秒）' -Default 30 -Minimum 5 -Maximum 300
    Write-Host '请停在马上可以复现问题的位置；开始后在手机执行目标操作。' -ForegroundColor Yellow
    Pause-Launcher '准备好后按 Enter 开始'
    $code=Invoke-KitChild -Command run -Case 'perfetto-trace' -DurationSec $duration -Perfetto -PerfettoProfile $profile -PerfettoDurationSec $duration
    if($code -eq 0){Show-LatestResult 'perfetto-trace'}
    Pause-Launcher
}

function Invoke-RuntimeMemoryRecovery {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.memoryRecovery
    $duration=Read-LauncherInteger -Prompt '战斗内存增长阶段时长（秒）' -Default ([int]$cc.durationSec) -Minimum 5 -Maximum 14400
    $nodes=Read-LauncherIntegerList -Prompt '返回主页后的PSS节点（秒）' -Default @($cc.recoveryNodesSec)
    $cc.durationSec=$duration;$cc.recoveryNodesSec=@($nodes);Save-LauncherRuntimeProfile
    Write-Host ("请进入稳定战斗。战斗${duration}秒后按提示返回主页。") -ForegroundColor Yellow;Pause-Launcher '准备好后按 Enter'
    [void](Invoke-KitChild -Command run -Case 'memory-recovery' -DurationSec $duration);Pause-Launcher
}

function Invoke-RuntimeBatterySaver {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.batterySaver
    $before=Read-LauncherInteger -Prompt '省电模式关闭阶段时长（秒）' -Default ([int]$cc.beforeSec) -Minimum 5 -Maximum 3600
    $after=Read-LauncherInteger -Prompt '省电模式开启阶段时长（秒）' -Default ([int]$cc.afterSec) -Minimum 5 -Maximum 3600
    $cc.beforeSec=$before;$cc.afterSec=$after;Save-LauncherRuntimeProfile
    if(Confirm-LauncherAction '将模拟拔电并切换Battery Saver；结束时自动恢复。'){[void](Invoke-KitChild -Command run -Case 'battery-saver')};Pause-Launcher
}

function Invoke-RuntimeBackgroundPressure {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.backgroundPressure;$current=@($cc.packages) -join ','
    $text=(Read-Host "后台应用包名（逗号分隔，可留空） [$current]").Trim();if(-not $text){$text=$current}
    $packages=@();if($text){$packages=@($text -split ','|ForEach-Object{$_.Trim()}|Where-Object{$_})}
    foreach($p in $packages){if($p -notmatch '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$'){Write-Host "无效包名：$p" -ForegroundColor Red;Pause-Launcher;return}}
    $duration=Read-LauncherInteger -Prompt '压力战斗时长（秒）' -Default ([int]$cc.durationSec) -Minimum 5 -Maximum 14400
    $settle=Read-LauncherInteger -Prompt '后台应用启动后稳定等待（秒）' -Default ([int]$cc.settleSec) -Minimum 0 -Maximum 600
    $mem=Read-LauncherInteger -Prompt '期望最大MemAvailable（MiB，仅用于判定）' -Default ([int]$cc.maxMemAvailableMiB) -Minimum 128 -Maximum 65536
    $cc.packages=@($packages);$cc.durationSec=$duration;$cc.settleSec=$settle;$cc.maxMemAvailableMiB=$mem;Save-LauncherRuntimeProfile
    if(Confirm-LauncherAction ("将启动后台应用："+($(if($packages.Count){$packages -join ', '}else{'无，仅记录当前内存压力'})))){[void](Invoke-KitChild -Command run -Case 'background-pressure' -DurationSec $duration)};Pause-Launcher
}

function Invoke-RuntimeStorage {
    if(-not(Test-LauncherTargetReady)){Pause-Launcher;return}
    $cc=$script:CurrentProfile.cases.storage5GB
    $target=Read-LauncherNumber -Prompt '目标剩余存储（GiB）' -Default ([double]$cc.targetFreeGb) -Minimum 1 -Maximum 1000
    $minimum=Read-LauncherNumber -Prompt '安全下限（GiB）' -Default ([double]$cc.minimumSafeFreeGb) -Minimum 1 -Maximum $target
    $cc.targetFreeGb=$target;$cc.minimumSafeFreeGb=$minimum;Save-LauncherRuntimeProfile
    if(Confirm-LauncherAction "高风险操作：将创建占位文件，把/data可用空间调整到约${target}GiB。" 'STORAGE'){[void](Invoke-KitChild -Command run -Case 'storage-5gb')};Pause-Launcher
}

function Invoke-MenuChoice {
    param([string]$Choice)
    switch($Choice.ToUpperInvariant()){
        '1' {if(Test-LauncherTargetReady){[void](Invoke-KitChild -Command preflight)};Pause-Launcher}
        '2' {Invoke-QuickValidation}
        '3' {Invoke-RuntimeBattle}
        '4' {Invoke-RuntimeManualMarker}
        '5' {Invoke-RuntimeFirstLoad}
        '6' {Invoke-RuntimeColdStart}
        '7' {Invoke-RuntimeMemoryRecovery}
        '8' {Invoke-RuntimeLongrun}
        '9' {Invoke-RuntimeBatterySaver}
        '10' {Invoke-RuntimeBackgroundPressure}
        '11' {Invoke-RuntimeStorage}
        '12' {[void](Invoke-KitChild -Command cleanup);Pause-Launcher}
        '13' {Invoke-SmokeTest;Pause-Launcher}
        '14' {if(Test-Path (Join-Path $PSScriptRoot 'results')){Start-Process explorer.exe (Join-Path $PSScriptRoot 'results')}else{Write-Host '尚未生成results目录。' -ForegroundColor Yellow;Pause-Launcher}}
        '15' {Invoke-RuntimePerfetto}
        '16' {Show-LatestReport}
        'S' {[void](Set-LauncherGameAndDevice)}
    }
}

try{
    Initialize-LauncherProfile -Requested $Config -SkipDeviceScan:($Action -eq 'smoke')
    switch($Action){
        'preflight'{$code=Invoke-KitChild -Command preflight;exit $code}
        'quick'{Invoke-QuickValidation;exit 0}
        'cleanup'{$code=Invoke-KitChild -Command cleanup;exit $code}
        'smoke'{$code=Invoke-SmokeTest;exit $code}
    }
    while($true){
        Write-LauncherHeader
        Write-Host ' [1] 设备与能力预检'
        Write-Host ' [2] 一键核心验证（预检 + 10秒战斗）' -ForegroundColor Green
        Write-Host ' [3] 战斗性能采集（现场设置时长）'
        Write-Host ' [4] 人工事件标记（现场设置时间点）'
        Write-Host ' [5] 首次单位/特效加载（现场设置）'
        Write-Host ' [6] 冷启动与首战加载'
        Write-Host ' [7] 内存恢复/PSS节点（现场设置）'
        Write-Host ' [8] 长稳自动战斗（现场设置总时长/单局/坐标）' -ForegroundColor Green
        Write-Host ' [9] Battery Saver对照（现场设置）'
        Write-Host ' [10] 后台竞争/低MemAvailable（现场设置）'
        Write-Host ' [11] 低存储测试（现场设置目标）' -ForegroundColor Yellow
        Write-Host ' [12] Cleanup恢复设备'
        Write-Host ' [13] 离线自检'
        Write-Host ' [14] 打开结果目录'
        Write-Host ' [15] Perfetto专项诊断（5～300秒）' -ForegroundColor Magenta
        Write-Host ' [16] 打开最新自动测试报告' -ForegroundColor Green
        Write-Host ' [S] 自动识别/更换设备与前台游戏' -ForegroundColor Cyan
        Write-Host ' [0] 退出'
        Write-Host ''
        $choice=(Read-Host '请选择').Trim()
        if($choice -eq '0'){break}
        Invoke-MenuChoice $choice
    }
}catch{
    Write-Host ''
    Write-Host "启动器错误：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
