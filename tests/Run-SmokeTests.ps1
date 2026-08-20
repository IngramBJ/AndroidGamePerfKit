$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$root=Split-Path -Parent $PSScriptRoot

$files=@(
    (Join-Path $root 'AndroidGamePerfKit.ps1'),
    (Join-Path $root 'AndroidGamePerfKit-Launcher.ps1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1'),
    (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1')
)
foreach($file in $files){
    $tokens=$null;$errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if($errors.Count -gt 0){throw "Syntax error in $file : $($errors[0].Message)"}
}
if(-not(Test-Path -LiteralPath (Join-Path $root 'Start-AndroidGamePerfKit.cmd'))){throw 'One-click launcher CMD is missing.'}
$launcherSource=Get-Content -LiteralPath (Join-Path $root 'AndroidGamePerfKit-Launcher.ps1') -Raw
foreach($requiredText in @('Update-LauncherDeviceInfo','Set-LauncherGameAndDevice','Invoke-RuntimeLongrun','Show-LatestReport','runtime-config.json','gameName')){
    if($launcherSource -notmatch [regex]::Escape($requiredText)){throw "Runtime launcher capability is missing: $requiredText"}
}
if($launcherSource -match 'Select-LauncherConfig|RememberedConfig'){throw 'Launcher must not require users to select a JSON profile.'}
$caseSource=Get-Content -LiteralPath (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1') -Raw
if($caseSource -match '\bWrite-Progress\b'){throw 'Dynamic Write-Progress rendering must stay disabled to protect the Chinese menu layout.'}

Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Core.psm1') -Force
Import-Module (Join-Path $root 'lib\AndroidGamePerfKit.Cases.psm1') -Force
$cfg=Read-GpkConfig -Path (Join-Path $root 'configs\generic-example.json')
if($cfg.packageName -ne 'com.example.game'){throw 'Config smoke test failed.'}
$emptyArrayTest=ConvertTo-GpkHashtable ([pscustomobject]@{items=@()})
if($null -eq $emptyArrayTest.items -or @($emptyArrayTest.items).Count -ne 0){throw 'Empty arrays must remain arrays in metadata.'}
if((ConvertTo-GpkPathSegment '游戏 A:测试/版本') -ne '游戏-A-测试-版本'){throw 'Result path sanitizer smoke test failed.'}

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
} finally {
    if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Recurse -Force}
}

Write-Host 'AndroidGamePerfKit smoke tests passed.' -ForegroundColor Green
