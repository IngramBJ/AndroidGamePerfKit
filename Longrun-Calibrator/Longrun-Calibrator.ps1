[CmdletBinding()]
param(
    [string]$Config,
    [ValidateSet('menu','calibrate','coordinates','timing')]
    [string]$Action='menu'
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0
$script:ToolRoot=Split-Path -Parent $PSScriptRoot
$script:ResultRoot=if($env:GPK_CALIBRATION_RESULT_ROOT){[IO.Path]::GetFullPath($env:GPK_CALIBRATION_RESULT_ROOT)}else{Join-Path $PSScriptRoot 'calibration-results'}
$script:Version=(Get-Content -LiteralPath (Join-Path $script:ToolRoot 'VERSION') -Raw).Trim()
$script:StartWithFirstTap=$false

Import-Module (Join-Path $script:ToolRoot 'lib\AndroidGamePerfKit.Core.psm1') -Force
Import-Module (Join-Path $script:ToolRoot 'lib\AndroidGamePerfKit.Calibration.psm1') -Force

function Read-CalInteger {
    param([string]$Prompt,[int]$Default,[int]$Minimum,[int]$Maximum)
    while($true){$value=(Read-Host "$Prompt [$Default]").Trim();if(-not $value){return $Default};$n=0;if([int]::TryParse($value,[ref]$n) -and $n -ge $Minimum -and $n -le $Maximum){return $n};Write-Host "请输入$Minimum到$Maximum之间的整数。" -ForegroundColor Yellow}
}

function Read-CalYesNo {
    param([string]$Prompt,[bool]$Default=$true)
    $hint=if($Default){'Y/n'}else{'y/N'}
    while($true){$value=(Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant();if(-not $value){return $Default};if($value -in @('y','yes')){return $true};if($value -in @('n','no')){return $false}}
}

function Get-CalContext {
    $path=$Config
    if(-not $path){$runtime=Join-Path $script:ToolRoot '.state\runtime-config.json';$path=if(Test-Path -LiteralPath $runtime){$runtime}else{Join-Path $script:ToolRoot 'configs\generic-example.json'}}
    $cfg=Read-GpkConfig -Path $path
    $serial=Select-GpkDevice -Config $cfg
    $manufacturer=(Invoke-GpkShell -Config $cfg -Command 'getprop ro.product.manufacturer' -AllowFailure).Text.Trim()
    $model=(Invoke-GpkShell -Config $cfg -Command 'getprop ro.product.model' -AllowFailure).Text.Trim()
    $display=Get-GpkDisplayInfo -Config $cfg
    $package=Get-GpkForegroundPackage -Config $cfg
    if(-not $package -or $package -match '^(?:com\.android|com\.huawei\.android\.launcher)'){$package=[string]$cfg.packageName}
    $gameName=[string]$cfg.gameName;if(-not $gameName -or $gameName -eq 'Generic-Game'){$gameName=if($package){($package -split '\.')[-1]}else{'Unknown-Game'}}
    $label=(($manufacturer+' '+$model).Trim() -replace '\s+','-');if(-not $label){$label='Android-'+$serial}
    $touch=$null;$touchMessage='ready';try{$touch=Get-GpkTouchCapabilities -Config $cfg}catch{$touchMessage=$_.Exception.Message}
    return [pscustomobject]@{config=$cfg;serial=$serial;manufacturer=$manufacturer;model=$model;deviceLabel=$label;display=$display;packageName=$package;gameName=$gameName;touch=$touch;touchMessage=$touchMessage}
}

function Write-CalHeader {
    param($Context)
    Clear-Host
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host " AndroidGamePerfKit v$script:Version - 长稳校准助手" -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor DarkCyan
    if($Context){
        Write-Host (" 游戏     : {0} ({1})" -f $Context.gameName,$Context.packageName)
        Write-Host (" 设备     : {0} [{1}]" -f $Context.deviceLabel,$Context.serial)
        Write-Host (" 当前屏幕 : {0}，rotation={1}" -f $Context.display.resolution,$Context.display.rotation)
        $touchText=if($Context.touch){"$($Context.touch.name) [$($Context.touch.devicePath)]"}else{"不可用：$($Context.touchMessage)"}
        Write-Host (" 自动取点 : {0}" -f $touchText) -ForegroundColor $(if($Context.touch){'Green'}else{'Yellow'})
    }
    Write-Host '============================================================' -ForegroundColor DarkCyan
}

function Read-ManualPoint {
    param($Context,[int]$Index)
    $x=Read-CalInteger -Prompt "第${Index}步X坐标" -Default ([int](($Context.display.logicalWidth-1)/2)) -Minimum 0 -Maximum ($Context.display.logicalWidth-1)
    $y=Read-CalInteger -Prompt "第${Index}步Y坐标" -Default ([int](($Context.display.logicalHeight-1)/2)) -Minimum 0 -Maximum ($Context.display.logicalHeight-1)
    return [pscustomobject]@{x=$x;y=$y;rawX=$null;rawY=$null;timestampSec=$null;source='manual'}
}

function New-CalSessionFolder {
    param($Context,[string]$Kind)
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $game=ConvertTo-GpkPathSegment $Context.gameName
    $device=ConvertTo-GpkPathSegment $Context.deviceLabel
    $folder=Join-Path $script:ResultRoot (Join-Path $game "${stamp}_${device}_${Kind}")
    New-Item -ItemType Directory -Force -Path $folder|Out-Null
    return $folder
}

function Initialize-CalTextLog {
    param($Context,[string]$Folder,[string]$Kind)
    $lines=@(
        'AndroidGamePerfKit Longrun Calibration Live Log',
        "ToolVersion=$script:Version",
        "GameName=$($Context.gameName)",
        "PackageName=$($Context.packageName)",
        "Device=$($Context.deviceLabel)",
        "DeviceSerial=$($Context.serial)",
        "Resolution=$($Context.display.resolution)",
        "Rotation=$($Context.display.rotation)",
        "Kind=$Kind",
        "StartedAt=$((Get-Date).ToString('o'))",
        '',
        '说明：每完成一次坐标或计时，工具都会立即追加到此文件。StepCopy可复制单步，CurrentPasteLine可直接粘贴到主工具。',
        ''
    )
    Set-Content -LiteralPath (Join-Path $Folder 'calibration-log.txt') -Value $lines -Encoding UTF8
}

function Add-CalCoordinateLog {
    param([string]$Folder,[object[]]$Taps)
    $tap=@($Taps)[-1]
    $paste=ConvertTo-GpkTapSequence -Taps $Taps
    $lines=@(
        ("[Coordinate {0}] Name={1} X={2} Y={3} DelayMs={4} Source={5}" -f $tap.step,$tap.name,$tap.x,$tap.y,$tap.delayMs,$tap.source),
        ("StepCopy={0},{1},{2}" -f $tap.x,$tap.y,$tap.delayMs),
        "CurrentPasteLine=$paste",
        "RecordedAt=$((Get-Date).ToString('o'))",
        ''
    )
    Add-Content -LiteralPath (Join-Path $Folder 'calibration-log.txt') -Value $lines -Encoding UTF8
}

function Add-CalTimingLog {
    param([string]$Folder,[int]$Round,[double]$Seconds,[double[]]$Durations)
    $recommended=Get-GpkRecommendedBattleSeconds -DurationsSec $Durations
    $lines=@(
        ("[Battle {0}] DurationSec={1}" -f $Round,$Seconds.ToString('0.000',[Globalization.CultureInfo]::InvariantCulture)),
        "CurrentBattleTimesSec=$(@($Durations) -join ',')",
        "CurrentRecommendedBattleSeconds=$recommended",
        "RecordedAt=$((Get-Date).ToString('o'))",
        ''
    )
    Add-Content -LiteralPath (Join-Path $Folder 'calibration-log.txt') -Value $lines -Encoding UTF8
}

function Invoke-CalCoordinateCollection {
    param($Context,[string]$SessionFolder)
    Write-CalHeader $Context
    $count=Read-CalInteger -Prompt '完成一局循环需要点击几次' -Default 2 -Minimum 1 -Maximum 12
    $script:StartWithFirstTap=Read-CalYesNo -Prompt '序列第1步是否为“开战”，并要求长稳开始时立即点击' -Default $true
    if($script:StartWithFirstTap){
        Write-Host '请先停在开战按钮页面，严格按“开战 → 战斗结束后的继续/下一步 → 进入下一关”顺序采集，直到回到下次开战前状态。' -ForegroundColor Yellow
    }else{
        Write-Host '请先让当前战斗运行，严格从结算后的第一个按钮开始采集；长稳会先等待一局，再执行这些步骤。' -ForegroundColor Yellow
    }
    Add-Content -LiteralPath (Join-Path $SessionFolder 'calibration-log.txt') -Value @("StartWithFirstTap=$($script:StartWithFirstTap)",'') -Encoding UTF8
    $useAuto=($null -ne $Context.touch)
    if($useAuto){$useAuto=Read-CalYesNo -Prompt '是否直接在手机上点击并自动取坐标' -Default $true}
    $taps=@()
    for($i=1;$i -le $count;$i++){
        Write-Host '';Write-Host "--- 点击步骤 $i/$count ---" -ForegroundColor Cyan
        $name=(Read-Host "步骤名称 [tap$i]").Trim();if(-not $name){$name="tap$i"}
        $point=$null
        if($useAuto){
            Write-Host '请在手机上点击目标按钮；Esc可取消本次等待。' -ForegroundColor Yellow
            try{
                $raw=Invoke-GpkSingleTouchCapture -Config $Context.config -DeviceSerial $Context.serial -Capabilities $Context.touch -TimeoutSec 60
                $mapped=ConvertTo-GpkDisplayPoint -RawX $raw.rawX -RawY $raw.rawY -Capabilities $Context.touch -Display $Context.display
                $point=[pscustomobject]@{x=$mapped.x;y=$mapped.y;rawX=$raw.rawX;rawY=$raw.rawY;timestampSec=$raw.timestampSec;source='getevent'}
                Write-Host ("已记录：X={0}, Y={1}" -f $point.x,$point.y) -ForegroundColor Green
            }catch{Write-Warning $_.Exception.Message;if(Read-CalYesNo -Prompt '是否改为手工输入这一点' -Default $true){$point=Read-ManualPoint $Context $i}else{throw}}
        }else{$point=Read-ManualPoint $Context $i}
        $delay=Read-CalInteger -Prompt '点击后等待（毫秒）' -Default 1500 -Minimum 0 -Maximum 60000
        $taps+=,[pscustomobject][ordered]@{step=$i;name=$name;x=[int]$point.x;y=[int]$point.y;delayMs=$delay;rawX=$point.rawX;rawY=$point.rawY;timestampSec=$point.timestampSec;source=$point.source}
        Add-CalCoordinateLog -Folder $SessionFolder -Taps $taps
        Write-Host "已实时写入：$(Join-Path $SessionFolder 'calibration-log.txt')" -ForegroundColor DarkGreen
    }
    return @($taps)
}

function Invoke-CalBattleTiming {
    param($Context,[string]$SessionFolder)
    Write-CalHeader $Context
    $rounds=Read-CalInteger -Prompt '计时局数' -Default 3 -Minimum 1 -Maximum 10
    Write-Host '计时方式：[1] 电脑Enter标记（通用） [2] 手机开始/结束各点击一次（战斗中不能触屏）' -ForegroundColor Cyan
    $default=if($Context.touch){'2'}else{'1'}
    while($true){$mode=(Read-Host "请选择 [$default]").Trim();if(-not $mode){$mode=$default};if($mode -in @('1','2')){break}}
    $durations=@()
    for($i=1;$i -le $rounds;$i++){
        Write-Host '';Write-Host "--- 第 $i/$rounds 局 ---" -ForegroundColor Cyan
        if($mode -eq '1'){
            [void](Read-Host '看到战斗正式开始时按 Enter')
            $sw=[Diagnostics.Stopwatch]::StartNew();[void](Read-Host '看到结算/胜负界面时按 Enter');$sw.Stop();$seconds=[math]::Round($sw.Elapsed.TotalSeconds,3)
        }else{
            if($null -eq $Context.touch){throw '当前设备不支持手机点击计时。'}
            Write-Host '请点击“开始战斗”按钮。' -ForegroundColor Yellow
            $start=Invoke-GpkSingleTouchCapture -Config $Context.config -DeviceSerial $Context.serial -Capabilities $Context.touch -TimeoutSec 120
            Write-Host '计时已开始。战斗结束后，请点击结算/继续按钮；期间不要触摸屏幕。' -ForegroundColor Yellow
            $end=Invoke-GpkSingleTouchCapture -Config $Context.config -DeviceSerial $Context.serial -Capabilities $Context.touch -TimeoutSec 3600
            $seconds=[math]::Round(([double]$end.timestampSec-[double]$start.timestampSec),3)
            if($seconds -le 0){throw '触摸时间戳无效，请改用Enter标记计时。'}
        }
        $durations+=[double]$seconds
        Add-CalTimingLog -Folder $SessionFolder -Round $i -Seconds $seconds -Durations $durations
        Write-Host ("第{0}局：{1:N3}秒（已实时写入文本）" -f $i,$seconds) -ForegroundColor Green
    }
    return @($durations)
}

function Save-CalResult {
    param($Context,[object[]]$Taps,[double[]]$Durations,[string]$Kind,[string]$Folder)
    $recommended=Get-GpkRecommendedBattleSeconds -DurationsSec $Durations
    $payload=[ordered]@{
        schemaVersion=1;toolVersion=$script:Version;kind=$Kind;createdAt=(Get-Date).ToString('o');gameName=$Context.gameName;packageName=$Context.packageName
        deviceLabel=$Context.deviceLabel;deviceSerial=$Context.serial;display=$Context.display;startWithFirstTap=$script:StartWithFirstTap
        touchDevice=if($Context.touch){$Context.touch}else{$null};taps=@($Taps);battleTimesSec=@($Durations);recommendedBattleSeconds=$recommended
    }
    $jsonPath=Join-Path $folder 'longrun-calibration.json';Write-GpkJson -Path $jsonPath -Object $payload
    if(@($Taps).Count -gt 0){$Taps|Export-Csv -LiteralPath (Join-Path $folder 'taps.csv') -NoTypeInformation -Encoding UTF8}
    if(@($Durations).Count -gt 0){$rows=@();for($i=0;$i -lt $Durations.Count;$i++){$rows+=,[pscustomobject]@{round=$i+1;durationSec=$Durations[$i]}};$rows|Export-Csv -LiteralPath (Join-Path $folder 'battle-times.csv') -NoTypeInformation -Encoding UTF8}
    $paste=if(@($Taps).Count){ConvertTo-GpkTapSequence -Taps $Taps}else{''}
    $lines=@(
        'AndroidGamePerfKit Longrun Calibration',"GameName=$($Context.gameName)","PackageName=$($Context.packageName)","Device=$($Context.deviceLabel)",
        "Resolution=$($Context.display.resolution)","Rotation=$($Context.display.rotation)","StartWithFirstTap=$($script:StartWithFirstTap.ToString().ToLowerInvariant())","PasteLine=$paste", "RecommendedBattleSeconds=$(if($null -ne $recommended){$recommended}else{''})"
    )
    if($Durations.Count){$lines+="BattleTimesSec=$($Durations -join ',')"}
    Set-Content -LiteralPath (Join-Path $folder 'coordinates.txt') -Value $lines -Encoding UTF8
    Add-Content -LiteralPath (Join-Path $folder 'calibration-log.txt') -Value @(
        'Status=completed',
        "FinalPasteLine=$paste",
        "FinalRecommendedBattleSeconds=$(if($null -ne $recommended){$recommended}else{''})",
        "CompletedAt=$((Get-Date).ToString('o'))"
    ) -Encoding UTF8
    if($paste){try{Set-Clipboard -Value $paste;Write-Host '点击序列已复制到Windows剪贴板。' -ForegroundColor Green}catch{}}
    Write-Host "校准结果：$folder" -ForegroundColor Green
    if($null -ne $recommended){Write-Host "建议每局等待：$recommended 秒" -ForegroundColor Green}
    return $folder
}

function Invoke-CalAction {
    param([string]$Name)
    $context=Get-CalContext
    $folder=New-CalSessionFolder -Context $context -Kind $Name
    Initialize-CalTextLog -Context $context -Folder $folder -Kind $Name
    Write-Host "本轮实时记录：$(Join-Path $folder 'calibration-log.txt')" -ForegroundColor Green
    try{
        switch($Name){
            'coordinates' {$taps=Invoke-CalCoordinateCollection $context $folder;[void](Save-CalResult $context $taps @() 'coordinates' $folder)}
            'timing' {$times=Invoke-CalBattleTiming $context $folder;[void](Save-CalResult $context @() $times 'timing' $folder)}
            'calibrate' {$taps=Invoke-CalCoordinateCollection $context $folder;$times=Invoke-CalBattleTiming $context $folder;[void](Save-CalResult $context $taps $times 'full' $folder)}
        }
    }catch{
        Add-Content -LiteralPath (Join-Path $folder 'calibration-log.txt') -Value @('Status=interrupted-or-error',"Message=$($_.Exception.Message)","StoppedAt=$((Get-Date).ToString('o'))") -Encoding UTF8
        Write-Warning "本轮未完整结束，但已记录的数据仍保存在：$(Join-Path $folder 'calibration-log.txt')"
        throw
    }
}

try{
    if($Action -ne 'menu'){Invoke-CalAction $Action;exit 0}
    while($true){
        $context=$null;try{$context=Get-CalContext}catch{}
        Write-CalHeader $context
        Write-Host ' [1] 一体化校准（坐标 + 多局计时）' -ForegroundColor Green
        Write-Host ' [2] 只采集点击坐标'
        Write-Host ' [3] 只采集战斗用时'
        Write-Host ' [4] 打开校准结果目录'
        Write-Host ' [0] 退出'
        $choice=(Read-Host '请选择').Trim()
        switch($choice){
            '1' {try{Invoke-CalAction 'calibrate'}catch{Write-Host $_.Exception.Message -ForegroundColor Red};[void](Read-Host '按 Enter 返回')}
            '2' {try{Invoke-CalAction 'coordinates'}catch{Write-Host $_.Exception.Message -ForegroundColor Red};[void](Read-Host '按 Enter 返回')}
            '3' {try{Invoke-CalAction 'timing'}catch{Write-Host $_.Exception.Message -ForegroundColor Red};[void](Read-Host '按 Enter 返回')}
            '4' {if(-not(Test-Path -LiteralPath $script:ResultRoot)){New-Item -ItemType Directory -Force -Path $script:ResultRoot|Out-Null};Start-Process explorer.exe $script:ResultRoot}
            '0' {break}
        }
        if($choice -eq '0'){break}
    }
}catch{Write-Error $_;exit 1}
