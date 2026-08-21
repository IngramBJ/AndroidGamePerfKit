$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot

$files=@(
    (Join-Path $root 'AndroidGamePerfKit.ps1'),
    (Join-Path $root 'AndroidGamePerfKit-Launcher.ps1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Batch.psm1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Calibration.psm1'),
    (Join-Path $root 'Longrun-Calibrator\Longrun-Calibrator.ps1')
)
foreach($file in $files){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw "Syntax error in $file : $($errors[0].Message)"}
}
$cmdPath=Join-Path $root 'Start-AndroidGamePerfKit.cmd'
if(Test-Path -LiteralPath $cmdPath){throw 'CMD launcher must not be distributed because double-clicking a batch file always creates a console flash.'}
$vbsPath=Join-Path $root 'Start-AndroidGamePerfKit.vbs'
if(-not(Test-Path -LiteralPath $vbsPath)){throw 'No-flash VBS launcher is missing.'}
$vbsSource=Get-Content -LiteralPath $vbsPath -Raw
foreach($requiredVbsText in @('WScript.Shell','CurrentDirectory','powershell.exe','-ExecutionPolicy Bypass','AndroidGamePerfKit-Launcher.ps1','shell.Run command, 1, False')){if($vbsSource -notmatch [regex]::Escape($requiredVbsText)){throw "VBS launcher capability is missing: $requiredVbsText"}}
$calibratorVbsPath=Join-Path $root 'Start-Longrun-Calibrator.vbs'
if(-not(Test-Path -LiteralPath $calibratorVbsPath)){throw 'Longrun calibrator VBS launcher is missing.'}
$calibratorVbsSource=Get-Content -LiteralPath $calibratorVbsPath -Raw
foreach($requiredVbsText in @('WScript.Shell','CurrentDirectory','powershell.exe','-ExecutionPolicy Bypass','Longrun-Calibrator\Longrun-Calibrator.ps1','shell.Run command, 1, False')){if($calibratorVbsSource -notmatch [regex]::Escape($requiredVbsText)){throw "Longrun calibrator VBS capability is missing: $requiredVbsText"}}
$calibratorSource=Get-Content -LiteralPath (Join-Path $root 'Longrun-Calibrator\Longrun-Calibrator.ps1') -Raw
foreach($requiredCalibratorText in @('New-CalSessionFolder','Initialize-CalTextLog','Add-CalCoordinateLog','Add-CalTimingLog','calibration-log.txt','StepCopy=','CurrentPasteLine=','Status=interrupted-or-error')){
    if($calibratorSource -notmatch [regex]::Escape($requiredCalibratorText)){throw "Incremental calibration text log capability is missing: $requiredCalibratorText"}
}
$launcherSource=Get-Content -LiteralPath (Join-Path $root 'AndroidGamePerfKit-Launcher.ps1') -Raw
foreach($requiredText in @('Update-LauncherDeviceInfo','Set-LauncherGameAndDevice','Invoke-RuntimeLongrun','Read-LauncherCalibrationImport','Read-LauncherPastedTapSteps','Show-LatestReport','Invoke-RuntimeBatchReport','batch-reports','runtime-config.json','gameName')){
    if($launcherSource -notmatch [regex]::Escape($requiredText)){throw "Runtime launcher capability is missing: $requiredText"}
}
foreach($cancelGuard in @('HotkeyCancel','IsStopKeyPhysicallyDown','Reset-LauncherStopKey','Wait-LauncherProcess','0x1B','0x0001','KeyAvailable')){
    if($launcherSource -notmatch [regex]::Escape($cancelGuard)){throw "Controlled Esc guard is missing: $cancelGuard"}
}
$smokeFunction=[regex]::Match($launcherSource,'(?s)function Invoke-SmokeTest \{.*?\n\}').Value
if($smokeFunction -notmatch 'Wait-LauncherProcess' -or $smokeFunction -match '&\s*powershell\.exe'){throw 'Offline smoke tests must use the same controlled Esc process monitor.'}
foreach($forbiddenCtrlCHandler in @('TreatControlCAsInput','SetConsoleCtrlHandler','controlDown && cDown','0x7B')){
    if($launcherSource -match [regex]::Escape($forbiddenCtrlCHandler)){throw "Ctrl+C must remain native and unhandled: $forbiddenCtrlCHandler"}
}
if($launcherSource -match 'Select-LauncherConfig|RememberedConfig'){throw 'Launcher must not require users to select a JSON profile.'}
$caseSource=Get-Content -LiteralPath (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1') -Raw
if($caseSource -match '\bWrite-Progress\b'){throw 'Dynamic Write-Progress rendering must stay disabled to protect the Chinese menu layout.'}

Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1') -Force
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1') -Force
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Calibration.psm1') -Force
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Batch.psm1') -Force
$cfg=Read-GpkConfig -Path (Join-Path $root 'configs\generic-example.json')
if($cfg.packageName -ne 'com.example.game'){throw 'Config smoke test failed.'}
$emptyArrayTest=ConvertTo-GpkHashtable ([pscustomobject]@{items=@()})
if($null -eq $emptyArrayTest.items -or @($emptyArrayTest.items).Count -ne 0){throw 'Empty arrays must remain arrays in metadata.'}
if((ConvertTo-GpkPathSegment '游戏 A:测试/版本') -ne '游戏-A-测试-版本'){throw 'Result path sanitizer smoke test failed.'}

$foregroundSamples=[ordered]@{
    'topResumedActivity=ActivityRecord{123 u0 com.demo.top/.MainActivity t10}'='com.demo.top'
    'mResumedActivity: ActivityRecord{456 u0 net.demo.resumed/com.demo.Main t11}'='net.demo.resumed'
    'mCurrentFocus=Window{789 u0 org.demo.window/.GameActivity}'='org.demo.window'
    'mFocusedApp=ActivityRecord{abc u0 io.demo.focused/.Entry t12}'='io.demo.focused'
    'ComponentInfo{games.demo.component/.Launcher}'='games.demo.component'
    'ACTIVITY app.demo.activity/.Main 123 pid=1000'='app.demo.activity'
    'sample.demo.command/.MainActivity'='sample.demo.command'
}
foreach($sample in $foregroundSamples.Keys){
    $actual=ConvertFrom-GpkForegroundPackageText -Text $sample
    if($actual -ne $foregroundSamples[$sample]){throw "Foreground package parser failed: expected $($foregroundSamples[$sample]), got $actual, sample=$sample"}
}
if((ConvertFrom-GpkForegroundPackageText -Text 'mTopFocusedDisplayId=0') -ne ''){throw 'Foreground package parser must return empty for unrelated window state.'}

$jsonTestPath=Join-Path $env:TEMP ('gpk-json-'+[guid]::NewGuid().ToString('N')+'.json')
try{
    $jsonTest=[ordered]@{name='中文测试';empty=$null;enabled=$true;values=@(1,2.5,'x');nested=[ordered]@{line="a`nb"}}
    Write-GpkJson -Path $jsonTestPath -Object $jsonTest
    $jsonRoundTrip=Get-Content -LiteralPath $jsonTestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($jsonRoundTrip.name -ne '中文测试' -or $null -ne $jsonRoundTrip.empty -or -not $jsonRoundTrip.enabled -or $jsonRoundTrip.values.Count -ne 3 -or $jsonRoundTrip.nested.line -ne "a`nb"){
        throw 'Built-in JSON encoder round-trip smoke test failed.'
    }
}finally{Remove-Item -LiteralPath $jsonTestPath -Force -ErrorAction SilentlyContinue}

$nativeCfg=Read-GpkConfig -Path (Join-Path $root 'configs\generic-example.json')
$nativeCfg.adbPath='C:\Windows\System32\cmd.exe'
$nativeResult=Invoke-GpkAdb -Config $nativeCfg -Arguments @('/c','exit /b 0')
if($nativeResult.ExitCode -ne 0){throw "Native process exit-code smoke test failed: $($nativeResult.ExitCode)"}

Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1') -Force
$noDeviceCfg=Read-GpkConfig -Path (Join-Path $root 'configs\generic-example.json')
$noDeviceCfg.adbPath=Join-Path $PSScriptRoot 'mock-adb-no-device.ps1'
$noDeviceMessage=$null
try{Select-GpkDevice -Config $noDeviceCfg|Out-Null}catch{$noDeviceMessage=$_.Exception.Message}
if($noDeviceMessage -ne 'No Android device is connected. Connect and authorize one phone, then run preflight again.'){
    throw "No-device message smoke test failed: $noDeviceMessage"
}
# Reset the module-scoped executable cache before the mock ADB end-to-end run.
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1') -Force
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1') -Force

$sf=Get-GpkSurfaceSummary -Path (Join-Path $PSScriptRoot 'fixtures\surfaceflinger-sample.txt') -PackageName 'com.example.game'
if(-not $sf.available -or $sf.averageFps -ne 30 -or $sf.frameCount -ne 1800){throw 'SurfaceFlinger summary smoke test failed.'}
if($sf.p95Ms -ne 50 -or $sf.p99Ms -ne 67 -or $sf.over100Ms -ne 5){throw "Histogram smoke test failed: $($sf|ConvertTo-Json -Compress)"}
$huaweiSf=Get-GpkSurfaceSummary -Path (Join-Path $PSScriptRoot 'fixtures\surfaceflinger-huawei-sample.txt') -PackageName 'com.example.huawei.game'
if(-not $huaweiSf.available -or $huaweiSf.averageFps -ne 15.092 -or $huaweiSf.frameCount -ne 310){throw "Huawei SurfaceFlinger summary smoke test failed: $($huaweiSf|ConvertTo-Json -Compress)"}
if($huaweiSf.p95Ms -ne 134 -or $huaweiSf.p99Ms -ne 1000 -or $huaweiSf.maxMs -ne 1000 -or $huaweiSf.over50Ms -ne 52 -or $huaweiSf.over66_7Ms -ne 38 -or $huaweiSf.over100Ms -ne 35){
    throw "Huawei histogram smoke test failed: $($huaweiSf|ConvertTo-Json -Compress)"
}
if((Get-GpkBatterySaverState -Config $cfg -PowerText 'Battery Saver is currently: ON') -ne 'on'){throw 'Battery Saver ON parser failed.'}
if((Get-GpkBatterySaverState -Config $cfg -PowerText 'setting=1`nBattery Saver is currently: OFF') -ne 'off'){throw 'Battery Saver fail-closed parser failed.'}

$touchCaps=@(ConvertFrom-GpkGetEventCapabilities -Text (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\getevent-lp-sample.txt') -Raw))
if($touchCaps.Count -ne 1 -or $touchCaps[0].devicePath -ne '/dev/input/event6' -or $touchCaps[0].xMaximum -ne 1079 -or $touchCaps[0].yMaximum -ne 2399){throw 'Touch capability parser smoke test failed.'}
$touches=@(ConvertFrom-GpkGetEventTaps -Text (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\getevent-taps-sample.txt') -Raw))
if($touches.Count -ne 2 -or $touches[0].rawX -ne 540 -or $touches[0].rawY -ne 1200 -or $touches[1].rawX -ne 768){throw 'Touch event parser smoke test failed.'}
$portrait=ConvertTo-GpkDisplayPoint -RawX $touches[0].rawX -RawY $touches[0].rawY -Capabilities $touchCaps[0] -Display ([pscustomobject]@{logicalWidth=1080;logicalHeight=2400;rotation=0})
if($portrait.x -ne 540 -or $portrait.y -ne 1200){throw "Portrait touch mapping failed: $($portrait|ConvertTo-Json -Compress)"}
$landscape=ConvertTo-GpkDisplayPoint -RawX $touches[0].rawX -RawY $touches[0].rawY -Capabilities $touchCaps[0] -Display ([pscustomobject]@{logicalWidth=2400;logicalHeight=1080;rotation=1})
if($landscape.x -ne 1199 -or $landscape.y -ne 540){throw "Landscape touch mapping failed: $($landscape|ConvertTo-Json -Compress)"}
$sequence=ConvertTo-GpkTapSequence -Taps @([pscustomobject]@{x=10;y=20;delayMs=1500},[pscustomobject]@{x=30;y=40;delayMs=500})
$sequenceTaps=@(ConvertFrom-GpkTapSequence -Text $sequence -MaximumX 100 -MaximumY 100)
if($sequence -ne '10,20,1500;30,40,500' -or $sequenceTaps.Count -ne 2 -or $sequenceTaps[1].delayMs -ne 500){throw 'Tap sequence round-trip smoke test failed.'}
if((Get-GpkRecommendedBattleSeconds -DurationsSec @(64.2,66.8,65.5)) -ne 74){throw 'Battle duration recommendation smoke test failed.'}
$startFirstCalibration=Read-GpkLongrunCalibrationFile -Path (Join-Path $PSScriptRoot 'fixtures\longrun-calibration-start-first.json')
if(-not $startFirstCalibration.startWithFirstTap -or @($startFirstCalibration.taps).Count -ne 3 -or $startFirstCalibration.recommendedBattleSeconds -ne 22){throw 'Start-with-first-tap calibration import smoke test failed.'}

Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1') -Force
$calibrationCfg=Read-GpkConfig -Path (Join-Path $root 'configs\generic-example.json')
$calibrationCfg.adbPath=Join-Path $PSScriptRoot 'mock-adb.ps1';$calibrationCfg.deviceSerial='MOCK123'
[void](Select-GpkDevice -Config $calibrationCfg)
$mockDisplay=Get-GpkDisplayInfo -Config $calibrationCfg
$mockTouch=Get-GpkTouchCapabilities -Config $calibrationCfg
if($mockDisplay.resolution -ne '1080x2400' -or $mockDisplay.rotation -ne 0 -or $mockTouch.devicePath -ne '/dev/input/event6'){throw 'Mock calibration capability probe failed.'}
$mockCaptured=Invoke-GpkSingleTouchCapture -Config $calibrationCfg -DeviceSerial 'MOCK123' -Capabilities $mockTouch -TimeoutSec 5
if($mockCaptured.rawX -ne 540 -or $mockCaptured.rawY -ne 1200){throw "Mock live touch capture failed: $($mockCaptured|ConvertTo-Json -Compress)"}

$tmp=Join-Path $env:TEMP ("AndroidGamePerfKit-smoke-"+[guid]::NewGuid().ToString('N'))
try{
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'device'),(Join-Path $tmp 'perfetto\profiles')|Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'device\gameperf_sampler.sh') -Destination (Join-Path $tmp 'device\gameperf_sampler.sh')
    Copy-Item -Path (Join-Path $root 'perfetto\profiles\*.pbtxt') -Destination (Join-Path $tmp 'perfetto\profiles')
    $mockCfg=Get-Content -LiteralPath (Join-Path $root 'configs\generic-example.json') -Raw|ConvertFrom-Json
    $mockCfg.adbPath=(Join-Path $PSScriptRoot 'mock-adb.ps1')
    $mockCfg.deviceSerial='MOCK123'
    $mockCfg.gameName='Mock Game'
    $mockCfg.defaults.durationSec=2
    $mockCfg|Add-Member -NotePropertyName _durationOverrideSec -NotePropertyValue 2 -Force
    Invoke-GpkCase -CaseName 'battle-60s' -Config $mockCfg -KitRoot $tmp -NonInteractive
    $caseRoot=Join-Path $tmp 'results\Mock-Game\battle-60s'
    $summaryFile=Get-ChildItem -LiteralPath $caseRoot -Recurse -Filter summary.json|Select-Object -First 1
    if(-not $summaryFile){throw 'End-to-end mock run did not create summary.json.'}
    $summary=Get-Content -LiteralPath $summaryFile.FullName -Raw|ConvertFrom-Json
    if($summary.status -ne 'completed' -or $summary.samples.sampleCount -ne 3){throw "End-to-end mock summary failed: $($summary|ConvertTo-Json -Compress)"}
    $zip=Get-ChildItem -LiteralPath $caseRoot -Filter *.zip|Select-Object -First 1
    if(-not $zip){throw 'End-to-end mock run did not create ZIP.'}
    $expanded=Join-Path $tmp 'expanded';Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
    foreach($required in @('metadata.json','summary.json','samples.csv','report.html','raw\logcat.txt','raw\surfaceflinger-final.txt')){
        if(-not(Test-Path -LiteralPath (Join-Path $expanded $required))){throw "ZIP is missing required artifact: $required"}
    }
    $reportText=Get-Content -LiteralPath (Join-Path $expanded 'report.html') -Raw -Encoding UTF8
    if($reportText -notmatch 'Mock Game' -or $reportText -notmatch '自动判读'){throw 'Offline HTML report smoke test failed.'}
    $metadata=Get-Content -LiteralPath (Join-Path $expanded 'metadata.json') -Raw|ConvertFrom-Json
    if($metadata.gameName -ne 'Mock Game'){throw 'metadata.json is missing gameName.'}

    $mockCfg|Add-Member -NotePropertyName _durationOverrideSec -NotePropertyValue 2 -Force
    $mockCfg.cases.longrun.durationSec=2
    $mockCfg.cases.longrun.automation.enabled=$true
    $mockCfg.cases.longrun.automation.battleSeconds=1
    $mockCfg.cases.longrun.automation.taps=@(
        [pscustomobject]@{name='start battle';x=540;y=2000;delayMs=100},
        [pscustomobject]@{name='continue';x=520;y=1900;delayMs=100},
        [pscustomobject]@{name='enter stage';x=530;y=1950;delayMs=100}
    )
    $mockCfg.cases.longrun.automation|Add-Member -NotePropertyName startWithFirstTap -NotePropertyValue $true -Force
    Invoke-GpkCase -CaseName 'longrun' -Config $mockCfg -KitRoot $tmp -NonInteractive
    $longrunMarkersFile=Get-ChildItem -LiteralPath (Join-Path $tmp 'results\Mock-Game\longrun') -Recurse -Filter markers.csv|Select-Object -First 1
    if(-not $longrunMarkersFile){throw 'Start-with-first-tap longrun did not create markers.csv.'}
    $longrunTapMarkers=@(Import-Csv -LiteralPath $longrunMarkersFile.FullName|Where-Object{$_.name -eq 'automation_tap'})
    if($longrunTapMarkers.Count -lt 3 -or $longrunTapMarkers[0].note -notmatch 'step=1;name=start battle' -or $longrunTapMarkers[1].note -notmatch 'step=2;name=continue'){
        throw "Start-with-first-tap longrun order failed: $($longrunTapMarkers|ConvertTo-Json -Compress)"
    }

    $mockCfg|Add-Member -NotePropertyName _durationOverrideSec -NotePropertyValue 5 -Force
    $mockCfg|Add-Member -NotePropertyName _perfettoEnabled -NotePropertyValue $true -Force
    $mockCfg|Add-Member -NotePropertyName _perfettoProfile -NotePropertyValue 'load-io' -Force
    $mockCfg|Add-Member -NotePropertyName _perfettoDurationSec -NotePropertyValue 5 -Force
    Invoke-GpkCase -CaseName 'perfetto-trace' -Config $mockCfg -KitRoot $tmp -NonInteractive
    $perfettoZip=Get-ChildItem -LiteralPath (Join-Path $tmp 'results\Mock-Game\perfetto-trace') -Filter *.zip|Select-Object -First 1
    if(-not $perfettoZip){throw 'Perfetto mock run did not create ZIP.'}
    $perfettoExpanded=Join-Path $tmp 'perfetto-expanded';Expand-Archive -LiteralPath $perfettoZip.FullName -DestinationPath $perfettoExpanded
    foreach($required in @('raw\perfetto\trace.perfetto-trace','raw\perfetto\effective-config.pbtxt','raw\perfetto\capture.log')){
        $artifact=Join-Path $perfettoExpanded $required
        if(-not(Test-Path -LiteralPath $artifact) -or (Get-Item -LiteralPath $artifact).Length -eq 0){throw "Perfetto ZIP artifact is missing or empty: $required"}
    }
    $perfettoSummary=Get-Content -LiteralPath (Join-Path $perfettoExpanded 'summary.json') -Raw|ConvertFrom-Json
    if(-not $perfettoSummary.perfetto.requested -or -not $perfettoSummary.perfetto.captureCompleted -or $perfettoSummary.perfetto.profile -ne 'load-io'){
        throw "Perfetto summary smoke test failed: $($perfettoSummary.perfetto|ConvertTo-Json -Compress)"
    }
    $batch=Invoke-GpkBatchReport -KitRoot $tmp
    if($batch.rowCount -ne 3){throw "Batch summary expected 3 rows, got $($batch.rowCount)."}
    foreach($required in @('batch-summary.csv','batch-summary.json','batch-report.html','anomalies.txt')){
        if(-not(Test-Path -LiteralPath (Join-Path $batch.folder $required))){throw "Batch report is missing: $required"}
    }
    $batchRows=@(Import-Csv -LiteralPath $batch.csv)
    if($batchRows.Count -ne 3 -or @($batchRows|Where-Object caseName -eq 'longrun').Count -ne 1){throw 'Batch CSV row mapping failed.'}
    $batchJson=Get-Content -LiteralPath $batch.json -Raw -Encoding UTF8|ConvertFrom-Json
    if($batchJson.counts.total -ne 3 -or @($batchJson.rows).Count -ne 3){throw 'Batch JSON counts failed.'}
    $batchHtml=Get-Content -LiteralPath $batch.html -Raw -Encoding UTF8
    if($batchHtml -notmatch 'AndroidGamePerfKit 批量测试汇总' -or $batchHtml -notmatch 'Mock Game'){throw 'Batch HTML content failed.'}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $batchArchive=[IO.Compression.ZipFile]::OpenRead($batch.zip)
    try{$batchNames=@($batchArchive.Entries|ForEach-Object FullName)}finally{$batchArchive.Dispose()}
    if('batch-summary.csv' -notin $batchNames -or @($batchNames|Where-Object{$_ -match '(?i)logcat|perfetto-trace|samples\.csv'}).Count -gt 0){throw 'Small batch ZIP contains missing or oversized artifacts.'}
} finally {
    if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force}
}

Write-Host 'AndroidGamePerfKit smoke tests passed.' -ForegroundColor Green
