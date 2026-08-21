$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0

function ConvertFrom-GpkGetEventCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Text)
    $devices=@()
    $blocks=@([regex]::Split($Text,'(?m)(?=^add device\s+\d+:\s+)')|Where-Object{$_ -match '(?m)^add device\s+\d+:'})
    foreach($block in $blocks){
        if($block -notmatch '(?m)^add device\s+\d+:\s*(/dev/input/event\d+)'){continue}
        $path=$Matches[1]
        $name='unknown';if($block -match '(?m)^\s*name:\s*"([^"]+)"'){$name=$Matches[1]}
        $x=$null;$y=$null;$xCode='';$yCode=''
        foreach($candidate in @(
            [pscustomobject]@{axis='x';code='ABS_MT_POSITION_X';pattern='(?im)ABS_MT_POSITION_X\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'},
            [pscustomobject]@{axis='y';code='ABS_MT_POSITION_Y';pattern='(?im)ABS_MT_POSITION_Y\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'},
            [pscustomobject]@{axis='x';code='ABS_MT_POSITION_X';pattern='(?im)^\s*0035\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'},
            [pscustomobject]@{axis='y';code='ABS_MT_POSITION_Y';pattern='(?im)^\s*0036\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'},
            [pscustomobject]@{axis='x';code='ABS_X';pattern='(?im)^\s*ABS_X\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'},
            [pscustomobject]@{axis='y';code='ABS_Y';pattern='(?im)^\s*ABS_Y\s*:\s*value[^\r\n]*?min\s+(-?\d+)[^\r\n]*?max\s+(-?\d+)'}
        )){
            $m=[regex]::Match($block,$candidate.pattern)
            if(-not $m.Success){continue}
            $range=[pscustomobject]@{minimum=[int]$m.Groups[1].Value;maximum=[int]$m.Groups[2].Value}
            if($candidate.axis -eq 'x' -and $null -eq $x){$x=$range;$xCode=$candidate.code}
            if($candidate.axis -eq 'y' -and $null -eq $y){$y=$range;$yCode=$candidate.code}
        }
        if($null -eq $x -or $null -eq $y -or $x.maximum -le $x.minimum -or $y.maximum -le $y.minimum){continue}
        $score=10
        if($xCode -like 'ABS_MT*' -and $yCode -like 'ABS_MT*'){$score+=20}
        if($name -match '(?i)touch|screen|digitizer|\bts\b|\btp\b'){$score+=20}
        $devices+=,[pscustomobject][ordered]@{
            devicePath=$path;name=$name;xMinimum=$x.minimum;xMaximum=$x.maximum;yMinimum=$y.minimum;yMaximum=$y.maximum
            xCode=$xCode;yCode=$yCode;score=$score
        }
    }
    return @($devices|Sort-Object -Property @{Expression='score';Descending=$true},devicePath)
}

function Convert-GpkGetEventHexValue {
    param([string]$Value)
    $clean=($Value.Trim() -replace '^0x','')
    if($clean -notmatch '^[0-9a-fA-F]{1,16}$'){throw "Invalid getevent value: $Value"}
    return [Convert]::ToInt64($clean,16)
}

function ConvertFrom-GpkGetEventTaps {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Text)
    $taps=@();$x=$null;$y=$null;$timestamp=0.0;$fingerDown=$false
    foreach($line in @($Text -split "`r?`n")){
        if($line -match '\[\s*([0-9]+(?:\.[0-9]+)?)\]'){$timestamp=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}
        if($line -match '(?i)(?:ABS_MT_POSITION_X|\b0035\b)\s+(?:value\s+)?([0-9a-f]{1,16})\s*$'){$x=[int64](Convert-GpkGetEventHexValue $Matches[1]);$fingerDown=$true;continue}
        if($line -match '(?i)(?:ABS_MT_POSITION_Y|\b0036\b)\s+(?:value\s+)?([0-9a-f]{1,16})\s*$'){$y=[int64](Convert-GpkGetEventHexValue $Matches[1]);$fingerDown=$true;continue}
        if($line -match '(?i)(?:ABS_X|\b0000\b)\s+(?:value\s+)?([0-9a-f]{1,16})\s*$'){$x=[int64](Convert-GpkGetEventHexValue $Matches[1]);$fingerDown=$true;continue}
        if($line -match '(?i)(?:ABS_Y|\b0001\b)\s+(?:value\s+)?([0-9a-f]{1,16})\s*$'){$y=[int64](Convert-GpkGetEventHexValue $Matches[1]);$fingerDown=$true;continue}
        $released=($line -match '(?i)(?:ABS_MT_TRACKING_ID|\b0039\b)\s+(?:value\s+)?f{8,16}\s*$') -or ($line -match '(?i)BTN_TOUCH\s+(?:UP|00000000)\s*$')
        if($released -and $fingerDown -and $null -ne $x -and $null -ne $y){
            $taps+=,[pscustomobject][ordered]@{rawX=[int64]$x;rawY=[int64]$y;timestampSec=[double]$timestamp}
            $x=$null;$y=$null;$fingerDown=$false
        }
    }
    return @($taps)
}

function ConvertTo-GpkDisplayPoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][int64]$RawX,
        [Parameter(Mandatory=$true)][int64]$RawY,
        [Parameter(Mandatory=$true)]$Capabilities,
        [Parameter(Mandatory=$true)]$Display
    )
    $nx=([double]$RawX-[double]$Capabilities.xMinimum)/([double]$Capabilities.xMaximum-[double]$Capabilities.xMinimum)
    $ny=([double]$RawY-[double]$Capabilities.yMinimum)/([double]$Capabilities.yMaximum-[double]$Capabilities.yMinimum)
    $nx=[math]::Max(0.0,[math]::Min(1.0,$nx));$ny=[math]::Max(0.0,[math]::Min(1.0,$ny))
    $rotation=[int]$Display.rotation;$width=[int]$Display.logicalWidth;$height=[int]$Display.logicalHeight
    switch($rotation){
        1 {$px=(1-$ny)*($width-1);$py=$nx*($height-1)}
        2 {$px=(1-$nx)*($width-1);$py=(1-$ny)*($height-1)}
        3 {$px=$ny*($width-1);$py=(1-$nx)*($height-1)}
        default {$px=$nx*($width-1);$py=$ny*($height-1)}
    }
    return [pscustomobject][ordered]@{x=[int][math]::Round($px);y=[int][math]::Round($py)}
}

function ConvertTo-GpkTapSequence {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][object[]]$Taps)
    return (@($Taps|ForEach-Object{"$([int]$_.x),$([int]$_.y),$([int]$_.delayMs)"}) -join ';')
}

function ConvertFrom-GpkTapSequence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [int]$MaximumX=99999,
        [int]$MaximumY=99999,
        [int]$MaximumSteps=12
    )
    $value=$Text.Trim()
    if($value -match '(?im)^\s*PasteLine\s*=\s*(.+)$'){$value=$Matches[1].Trim()}
    if([string]::IsNullOrWhiteSpace($value)){throw '点击序列为空。'}
    $parts=@($value -split ';'|ForEach-Object{$_.Trim()}|Where-Object{$_})
    if($parts.Count -lt 1 -or $parts.Count -gt $MaximumSteps){throw "点击步骤必须为1到$MaximumSteps个。"}
    $result=@();$index=0
    foreach($part in $parts){
        $index++;$fields=@($part -split ','|ForEach-Object{$_.Trim()})
        if($fields.Count -notin @(2,3)){throw "第$index步格式错误，应为 X,Y 或 X,Y,等待毫秒。"}
        $x=0;$y=0;$delay=1500
        if(-not [int]::TryParse($fields[0],[ref]$x) -or -not [int]::TryParse($fields[1],[ref]$y)){throw "第$index步坐标不是整数。"}
        if($fields.Count -eq 3 -and -not [int]::TryParse($fields[2],[ref]$delay)){throw "第$index步等待时间不是整数。"}
        if($x -lt 0 -or $x -gt $MaximumX -or $y -lt 0 -or $y -gt $MaximumY){throw "第$index步坐标超出当前屏幕范围。"}
        if($delay -lt 0 -or $delay -gt 60000){throw "第$index步等待时间必须为0到60000毫秒。"}
        $result+=,[pscustomobject][ordered]@{name="tap$index";x=$x;y=$y;delayMs=$delay}
    }
    return @($result)
}

function Get-GpkRecommendedBattleSeconds {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][double[]]$DurationsSec)
    if($DurationsSec.Count -eq 0){return $null}
    $maximum=[double](($DurationsSec|Measure-Object -Maximum).Maximum)
    return [int][math]::Ceiling($maximum+[math]::Max(5,$maximum*0.10))
}

function Get-GpkDisplayInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Config)
    $sizeText=(Invoke-GpkShell -Config $Config -Command 'wm size' -AllowFailure).Text
    $sizes=[regex]::Matches($sizeText,'(?i)(\d{3,5})x(\d{3,5})')
    if($sizes.Count -eq 0){throw "无法从 wm size 读取屏幕分辨率：$sizeText"}
    $size=$sizes[$sizes.Count-1];$physicalWidth=[int]$size.Groups[1].Value;$physicalHeight=[int]$size.Groups[2].Value
    $rotation=0
    $rotationText=((Invoke-GpkShell -Config $Config -Command 'dumpsys input' -AllowFailure -TimeoutSec 10).Text+"`n"+(Invoke-GpkShell -Config $Config -Command 'dumpsys display' -AllowFailure -TimeoutSec 10).Text)
    if($rotationText -match '(?im)(?:SurfaceOrientation|mCurrentOrientation|mRotation|rotation)\s*[:=]?\s*(?:ROTATION_)?([0-3])'){$rotation=[int]$Matches[1]}
    else{
        $setting=(Invoke-GpkShell -Config $Config -Command 'settings get system user_rotation' -AllowFailure).Text.Trim()
        if($setting -match '^[0-3]$'){$rotation=[int]$setting}
    }
    $logicalWidth=$physicalWidth;$logicalHeight=$physicalHeight
    if($rotation % 2 -eq 1){$logicalWidth=$physicalHeight;$logicalHeight=$physicalWidth}
    return [pscustomobject][ordered]@{
        physicalWidth=$physicalWidth;physicalHeight=$physicalHeight;logicalWidth=$logicalWidth;logicalHeight=$logicalHeight
        resolution="${logicalWidth}x${logicalHeight}";rotation=$rotation
    }
}

function Get-GpkTouchCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Config)
    $tool=(Invoke-GpkShell -Config $Config -Command 'command -v getevent' -AllowFailure -TimeoutSec 10)
    if($tool.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($tool.Text)){throw '设备不提供可用的 getevent 命令。'}
    $probe=Invoke-GpkShell -Config $Config -Command 'getevent -lp' -AllowFailure -TimeoutSec 15
    $devices=@(ConvertFrom-GpkGetEventCapabilities -Text $probe.Text)
    if($devices.Count -eq 0){throw '未发现同时提供X/Y坐标的触摸输入设备。'}
    return $devices[0]
}

function Invoke-GpkSingleTouchCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Config,
        [Parameter(Mandatory=$true)][string]$DeviceSerial,
        [Parameter(Mandatory=$true)]$Capabilities,
        [int]$TimeoutSec=60
    )
    $adb=Resolve-GpkAdb $Config
    $tempBase=Join-Path ([IO.Path]::GetTempPath()) ('gpk-touch-'+[guid]::NewGuid().ToString('N'))
    $stdoutFile="$tempBase.stdout";$stderrFile="$tempBase.stderr";$proc=$null;$tap=$null
    try{
        $arguments=@();if($DeviceSerial){$arguments+=@('-s',$DeviceSerial)};$arguments+=@('shell','getevent','-lt',[string]$Capabilities.devicePath)
        if([IO.Path]::GetExtension($adb) -eq '.ps1'){$launchFile='powershell.exe';$arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$adb)+$arguments}else{$launchFile=$adb}
        $quoted=@($arguments|ForEach-Object{if($_ -match '[\s"]'){'"'+($_ -replace '"','\"')+'"'}else{$_}})
        $proc=Start-Process -FilePath $launchFile -ArgumentList ($quoted -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $handle=$proc.Handle;$deadline=[DateTime]::UtcNow.AddSeconds([math]::Max(1,$TimeoutSec))
        while(-not $proc.HasExited -and [DateTime]::UtcNow -lt $deadline){
            Start-Sleep -Milliseconds 100;$proc.Refresh()
            if(Test-Path -LiteralPath $stdoutFile){
                try{$text=Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction Stop}catch{$text=''}
                if($text){$captured=@(ConvertFrom-GpkGetEventTaps -Text $text);if($captured.Count -gt 0){$tap=$captured[$captured.Count-1];break}}
            }
            try{
                if([Console]::KeyAvailable){$key=[Console]::ReadKey($true);if($key.Key -eq [ConsoleKey]::Escape){throw [OperationCanceledException]::new('用户取消了触摸采集。')}}
            }catch [InvalidOperationException]{}
        }
        if($null -eq $tap -and (Test-Path -LiteralPath $stdoutFile)){
            try{$finalText=Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction Stop}catch{$finalText=''}
            if($finalText){$captured=@(ConvertFrom-GpkGetEventTaps -Text $finalText);if($captured.Count -gt 0){$tap=$captured[$captured.Count-1]}}
        }
        if($null -eq $tap){if($proc.HasExited){throw 'getevent在捕获点击前退出。'}else{throw "等待手机点击超时（${TimeoutSec}秒）。"}}
        return $tap
    } finally {
        if($proc){try{if(-not $proc.HasExited){$proc.Kill();[void]$proc.WaitForExit(2000)}}catch{};try{$proc.Dispose()}catch{}}
        Remove-Item -LiteralPath $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Read-GpkLongrunCalibrationFile {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=(Resolve-Path -LiteralPath $Path).Path
    if([IO.Path]::GetExtension($full) -eq '.json'){
        $data=Get-Content -LiteralPath $full -Raw -Encoding UTF8|ConvertFrom-Json
        $taps=@($data.taps)
        $recommended=if($data.PSObject.Properties['recommendedBattleSeconds']){[int]$data.recommendedBattleSeconds}else{0}
        $startWithFirstTap=if($data.PSObject.Properties['startWithFirstTap']){[bool]$data.startWithFirstTap}else{$null}
        $display=if($data.PSObject.Properties['display']){$data.display}else{$null}
        return [pscustomobject]@{path=$full;taps=$taps;recommendedBattleSeconds=$recommended;startWithFirstTap=$startWithFirstTap;display=$display;source='json'}
    }
    $text=Get-Content -LiteralPath $full -Raw -Encoding UTF8
    if($text -notmatch '(?im)^\s*PasteLine\s*=\s*(.+)$'){throw 'TXT中没有找到 PasteLine= 点击序列。'}
    $taps=@(ConvertFrom-GpkTapSequence -Text $Matches[1])
    $recommended=0;if($text -match '(?im)^\s*RecommendedBattleSeconds\s*=\s*(\d+)\s*$'){$recommended=[int]$Matches[1]}
    $display=$null
    if($text -match '(?im)^\s*Resolution\s*=\s*(\d+x\d+)\s*$'){$display=[pscustomobject]@{resolution=$Matches[1];rotation=0};if($text -match '(?im)^\s*Rotation\s*=\s*([0-3])\s*$'){$display.rotation=[int]$Matches[1]}}
    $startWithFirstTap=$null;if($text -match '(?im)^\s*StartWithFirstTap\s*=\s*(true|false)\s*$'){$startWithFirstTap=($Matches[1] -eq 'true')}
    return [pscustomobject]@{path=$full;taps=$taps;recommendedBattleSeconds=$recommended;startWithFirstTap=$startWithFirstTap;display=$display;source='txt'}
}

Export-ModuleMember -Function *-Gpk*
