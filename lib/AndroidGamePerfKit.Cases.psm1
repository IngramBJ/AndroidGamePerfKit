Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-GpkCaseCatalog {
    @(
        [pscustomobject]@{ Case='battle-60s'; Purpose='Stable battle baseline / pressure window' }
        [pscustomobject]@{ Case='longrun'; Purpose='Long stability run, optionally with configured tap automation' }
        [pscustomobject]@{ Case='memory-recovery'; Purpose='Battle memory growth and PSS recovery nodes' }
        [pscustomobject]@{ Case='battery-saver'; Purpose='Before/after Battery Saver with dumpsys power verification' }
        [pscustomobject]@{ Case='storage-5gb'; Purpose='Low-storage cold start and first-battle flow' }
        [pscustomobject]@{ Case='first-load'; Purpose='First vs second unit/effect trigger markers' }
        [pscustomobject]@{ Case='manual-marker'; Purpose='Generic timed manual-event capture' }
        [pscustomobject]@{ Case='background-pressure'; Purpose='Configured background-app and low-MemAvailable competition' }
        [pscustomobject]@{ Case='cold-start-first-battle'; Purpose='Cold launch, home-ready, and first-battle loading' }
        [pscustomobject]@{ Case='perfetto-trace'; Purpose='Short targeted Perfetto diagnosis window' }
    )
}

function Get-GpkCaseConfig {
    param($Config,[string]$Name)
    $prop=$Config.cases.PSObject.Properties[$Name]
    if($prop){return $prop.Value}
    return $null
}

function Get-GpkDuration {
    param($Config,[string]$CaseName)
    if($Config.PSObject.Properties['_durationOverrideSec']){return [int]$Config._durationOverrideSec}
    $cc=Get-GpkCaseConfig $Config $CaseName
    if($cc -and $cc.durationSec){return [int]$cc.durationSec}
    return [int]$Config.defaults.durationSec
}

function Wait-GpkDuration {
    param([int]$Seconds,[string]$Activity='Collecting')
    if($Seconds -le 0){return}
    $reportEvery=1
    if($Seconds -gt 15){$reportEvery=10}
    if($Seconds -gt 120){$reportEvery=30}
    if($Seconds -gt 600){$reportEvery=60}
    Write-Host ("[Progress] {0}: 0/{1}s" -f $Activity,$Seconds) -ForegroundColor DarkGray
    for($i=0;$i -lt $Seconds;$i++){
        Start-Sleep -Seconds 1
        $elapsed=$i+1
        if(($elapsed % $reportEvery) -eq 0 -or $elapsed -eq $Seconds){
            Write-Host ("[Progress] {0}: {1}/{2}s" -f $Activity,$elapsed,$Seconds) -ForegroundColor DarkGray
        }
    }
}

function Invoke-GpkBeep {
    try{[console]::Beep(900,250)}catch{}
}

function Save-GpkPssNode {
    param($Context,[string]$Name,[System.Collections.ArrayList]$Rows)
    $file=Join-Path $Context.RawRoot ("pss-$Name.txt")
    $r=Invoke-GpkShell -Config $Context.Config -Command "dumpsys meminfo $($Context.Config.packageName)" -AllowFailure -OutFile $file
    $pssKb=$null;$rssKb=$null
    if($r.Text -match '(?im)^\s*TOTAL PSS:\s*(\d+)'){$pssKb=[int64]$Matches[1]}
    elseif($r.Text -match '(?im)^\s*TOTAL\s+(\d+)\s+\d+'){$pssKb=[int64]$Matches[1]}
    if($r.Text -match '(?im)^\s*TOTAL RSS:\s*(\d+)'){$rssKb=[int64]$Matches[1]}
    [void]$Rows.Add([pscustomobject]@{node=$Name;hostTime=(Get-Date).ToUniversalTime().ToString('o');pssMiB=if($null-ne$pssKb){[math]::Round($pssKb/1024,2)}else{$null};rssMiB=if($null-ne$rssKb){[math]::Round($rssKb/1024,2)}else{$null}})
}

function Invoke-GpkBattleWindow {
    param($Context,[int]$DurationSec)
    Write-Host "Keep the game in the intended stable battle for $DurationSec seconds." -ForegroundColor Cyan
    Add-GpkMarker $Context 'battle_window_start'
    Wait-GpkDuration -Seconds $DurationSec -Activity 'Battle performance collection'
    Add-GpkMarker $Context 'battle_window_end'
}

function Invoke-GpkLongrunCase {
    param($Context,[switch]$NonInteractive)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'longrun';$duration=Get-GpkDuration $cfg 'longrun'
    $enabled=$false
    if($cc -and $cc.automation){$enabled=[bool]$cc.automation.enabled}
    Add-GpkMarker $Context 'longrun_start'
    if(-not $enabled){
        Write-Host 'Longrun automation is disabled in config; collect while you operate the game manually.' -ForegroundColor Yellow
        Wait-GpkDuration -Seconds $duration -Activity 'Longrun collection'
    } else {
        $battleSec=[int]$cc.automation.battleSeconds;$deadline=(Get-Date).AddSeconds($duration);$round=0
        while((Get-Date) -lt $deadline){
            $remain=[int][math]::Floor(($deadline-(Get-Date)).TotalSeconds)
            $wait=[math]::Min($battleSec,[math]::Max(0,$remain));if($wait -gt 0){Wait-GpkDuration -Seconds $wait -Activity "Longrun round $($round+1)"}
            if((Get-Date) -ge $deadline){break}
            foreach($tap in @($cc.automation.taps)){
                $x=[int]$tap.x;$y=[int]$tap.y
                Invoke-GpkShell -Config $cfg -Command "input tap $x $y" -AllowFailure|Out-Null
                if($tap.delayMs){Start-Sleep -Milliseconds ([int]$tap.delayMs)}
            }
            $round++;Add-GpkMarker $Context 'round_restart' "round=$round"
        }
    }
    Add-GpkMarker $Context 'longrun_end'
}

function Invoke-GpkMemoryRecoveryCase {
    param($Context,[switch]$NonInteractive)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'memoryRecovery';$duration=Get-GpkDuration $cfg 'memoryRecovery';$rows=New-Object System.Collections.ArrayList
    Save-GpkPssNode $Context 'T0-baseline' $rows
    Add-GpkMarker $Context 'memory_battle_start'
    Wait-GpkDuration -Seconds $duration -Activity 'Memory growth battle window'
    Save-GpkPssNode $Context 'Tend-battle' $rows
    if(-not $NonInteractive){
        [void](Read-Host 'Return to the configured recovery/home state, then press Enter')
    } else {
        $delay=5;if($cc -and $cc.nonInteractiveExitDelaySec){$delay=[int]$cc.nonInteractiveExitDelaySec};Wait-GpkDuration -Seconds $delay -Activity 'Waiting for recovery state'
    }
    Add-GpkMarker $Context 'memory_recovery_start'
    $nodes=@(0,30,60,180);if($cc -and $cc.recoveryNodesSec){$nodes=@($cc.recoveryNodesSec|ForEach-Object{[int]$_})}
    $elapsed=0
    foreach($n in $nodes){$wait=$n-$elapsed;if($wait -gt 0){Wait-GpkDuration -Seconds $wait -Activity "PSS recovery node ${n}s"};Save-GpkPssNode $Context "R${n}s" $rows;$elapsed=$n}
    $rows|Export-Csv -LiteralPath (Join-Path $Context.ResultRoot 'pss-nodes.csv') -NoTypeInformation -Encoding UTF8
}

function Invoke-GpkBatterySaverCase {
    param($Context,$State)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'batterySaver';$before=20;$after=20
    if($cc -and $cc.beforeSec){$before=[int]$cc.beforeSec};if($cc -and $cc.afterSec){$after=[int]$cc.afterSec}
    Invoke-GpkShell -Config $cfg -Command 'settings put global low_power 0'|Out-Null
    Invoke-GpkShell -Config $cfg -Command 'dumpsys battery unplug'|Out-Null
    $State.batteryUnplugged=$true;Save-GpkState $Context $State
    $offPower=(Invoke-GpkShell -Config $cfg -Command 'dumpsys power' -OutFile (Join-Path $Context.RawRoot 'power-before.txt')).Text
    $offState=Get-GpkBatterySaverState -Config $cfg -PowerText $offPower
    if($offState -ne 'off'){throw "Battery Saver baseline could not be verified OFF via dumpsys power (state=$offState)."}
    Add-GpkMarker $Context 'battery_saver_before_start'
    Wait-GpkDuration -Seconds $before -Activity 'Battery Saver OFF phase'
    Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -dump' -AllowFailure -OutFile (Join-Path $Context.RawRoot 'surfaceflinger-before-saver.txt')|Out-Null
    Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -clear' -AllowFailure|Out-Null
    Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -enable' -AllowFailure|Out-Null
    Invoke-GpkShell -Config $cfg -Command 'settings put global low_power 1'|Out-Null
    Start-Sleep -Milliseconds 800
    $onPower=(Invoke-GpkShell -Config $cfg -Command 'dumpsys power' -OutFile (Join-Path $Context.RawRoot 'power-after-enable.txt')).Text
    $onState=Get-GpkBatterySaverState -Config $cfg -PowerText $onPower
    if($onState -notin @('on','on-inferred')){throw "low_power was written, but dumpsys power did not verify Battery Saver ON (state=$onState). This run is invalid."}
    if($onState -eq 'on-inferred'){Add-GpkWarning $Context 'OEM power dump lacks the canonical ON line; ON was inferred from dumpsys power flags, not from settings.'}
    Add-GpkMarker $Context 'battery_saver_on_verified' $onState
    Wait-GpkDuration -Seconds $after -Activity 'Battery Saver ON phase'
    Invoke-GpkShell -Config $cfg -Command 'dumpsys SurfaceFlinger --timestats -dump' -AllowFailure -OutFile (Join-Path $Context.RawRoot 'surfaceflinger-after-saver.txt')|Out-Null
}

function Get-GpkDataAvailableKb {
    param($Config)
    $r=Invoke-GpkShell -Config $Config -Command 'df -k /data'
    $lines=@($r.Lines|Where-Object{$_ -match '\d'});if($lines.Count -eq 0){throw 'Could not parse df -k /data.'}
    $parts=@($lines[-1].Trim() -split '\s+')
    if($parts.Count -lt 4){throw "Unexpected df output: $($lines[-1])"}
    return [int64]$parts[3]
}

function New-GpkStorageFiller {
    param($Context,$State)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'storage5GB';$target=5.0;$minimum=3.5
    if($cc -and $cc.targetFreeGb){$target=[double]$cc.targetFreeGb};if($cc -and $cc.minimumSafeFreeGb){$minimum=[double]$cc.minimumSafeFreeGb}
    $avail=Get-GpkDataAvailableKb $cfg;$targetKb=[int64]($target*1024*1024);$minKb=[int64]($minimum*1024*1024)
    if($targetKb -lt $minKb){throw "targetFreeGb ($target) is lower than minimumSafeFreeGb ($minimum)."}
    if($avail -le $targetKb){Add-GpkWarning $Context "Device already has only $([math]::Round($avail/1024/1024,2)) GiB free; no filler was created.";return}
    if(-not(Test-GpkCommand $cfg 'fallocate')){throw 'storage-5gb requires fallocate; preflight reported it unavailable. The toolkit will not fall back to high-write dd.'}
    $fillKb=$avail-$targetKb;$path="/data/local/tmp/gpk_storage_filler_$($Context.Timestamp).bin"
    $State.fillerPath=$path;Save-GpkState $Context $State
    Invoke-GpkShell -Config $cfg -Command "fallocate -l ${fillKb}K $path"|Out-Null
    Start-Sleep -Seconds 1
    $after=Get-GpkDataAvailableKb $cfg
    Add-GpkMarker $Context 'storage_target_ready' "freeGiB=$([math]::Round($after/1024/1024,3))"
    Invoke-GpkShell -Config $cfg -Command 'df -k /data' -OutFile (Join-Path $Context.RawRoot 'storage-after-filler.txt')|Out-Null
}

function Invoke-GpkColdStartFlow {
    param($Context,[switch]$NonInteractive)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'coldStartFirstBattle';$activity=Get-GpkActivity $cfg
    if(-not $activity){throw 'Could not resolve launcher Activity. Set activity explicitly in config.'}
    Invoke-GpkShell -Config $cfg -Command "am force-stop $($cfg.packageName)"|Out-Null
    Start-Sleep -Seconds 2
    Add-GpkMarker $Context 'cold_start_command'
    Invoke-GpkShell -Config $cfg -Command "am start -W -n $activity" -OutFile (Join-Path $Context.RawRoot 'am-start-W.txt')|Out-Null
    Add-GpkMarker $Context 'activity_start_returned'
    if(-not $NonInteractive){
        [void](Read-Host 'When the home screen is fully usable, press Enter')
        Add-GpkMarker $Context 'home_ready_manual'
        [void](Read-Host 'Enter the fixed first battle now; press Enter when the battle is fully active')
        Add-GpkMarker $Context 'first_battle_ready_manual'
    } else {
        $home=12;$battle=8;if($cc -and $cc.nonInteractiveHomeDelaySec){$home=[int]$cc.nonInteractiveHomeDelaySec};if($cc -and $cc.nonInteractiveBattleDelaySec){$battle=[int]$cc.nonInteractiveBattleDelaySec}
        Wait-GpkDuration -Seconds $home -Activity 'Noninteractive home wait';Add-GpkMarker $Context 'home_ready_assumed'
        Wait-GpkDuration -Seconds $battle -Activity 'Noninteractive first-battle wait';Add-GpkMarker $Context 'first_battle_ready_assumed'
    }
}

function Invoke-GpkFirstLoadCase {
    param($Context)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'firstLoad';$duration=Get-GpkDuration $cfg 'firstLoad';$first=6;$second=18
    if($cc -and $cc.firstMarkerSec){$first=[int]$cc.firstMarkerSec};if($cc -and $cc.secondMarkerSec){$second=[int]$cc.secondMarkerSec}
    Write-Host 'Prepare the scene so the target unit/effect has not appeared in this process.' -ForegroundColor Cyan
    Wait-GpkDuration -Seconds $first -Activity 'First-load stable baseline';Invoke-GpkBeep;Add-GpkMarker $Context 'first_trigger_prompt';Write-Host 'TRIGGER THE TARGET FOR THE FIRST TIME NOW.' -ForegroundColor Green
    $wait2=$second-$first;if($wait2 -gt 0){Wait-GpkDuration -Seconds $wait2 -Activity 'Waiting for second comparison'}
    Invoke-GpkBeep;Add-GpkMarker $Context 'second_trigger_prompt';Write-Host 'TRIGGER THE SAME TARGET A SECOND TIME NOW (if possible).' -ForegroundColor Yellow
    $tail=$duration-$second;if($tail -gt 0){Wait-GpkDuration -Seconds $tail -Activity 'First-load tail window'}
}

function Invoke-GpkManualMarkerCase {
    param($Context)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'manualMarker';$duration=Get-GpkDuration $cfg 'manualMarker';$offsets=@(5,15)
    if($cc -and $cc.offsetsSec){$offsets=@($cc.offsetsSec|ForEach-Object{[int]$_})}
    $last=0;$idx=0
    foreach($n in $offsets){$wait=$n-$last;if($wait -gt 0){Wait-GpkDuration -Seconds $wait -Activity "Manual marker at ${n}s"};$idx++;Invoke-GpkBeep;Add-GpkMarker $Context "manual_marker_$idx" "scheduledSec=$n";Write-Host "MARKER ${idx}: perform the intended action now." -ForegroundColor Green;$last=$n}
    if($duration-$last -gt 0){Wait-GpkDuration -Seconds ($duration-$last) -Activity 'Manual marker tail window'}
}

function Invoke-GpkPerfettoTraceCase {
    param($Context)
    if(-not $Context.Config.PSObject.Properties['_perfettoEnabled'] -or -not [bool]$Context.Config._perfettoEnabled){throw 'The perfetto-trace case requires -Perfetto.'}
    $duration=[int]$Context.Config._perfettoDurationSec
    Write-Host "Perform the target action during this ${duration}-second Perfetto diagnosis window." -ForegroundColor Cyan
    Add-GpkMarker $Context 'perfetto_diagnosis_window_start'
    Wait-GpkDuration -Seconds $duration -Activity 'Perfetto diagnosis'
    Add-GpkMarker $Context 'perfetto_diagnosis_window_end'
}

function Invoke-GpkBackgroundPressureCase {
    param($Context,$State)
    $cfg=$Context.Config;$cc=Get-GpkCaseConfig $cfg 'backgroundPressure';$packages=@();$settle=10
    if($cc -and $cc.packages){$packages=@($cc.packages)};if($cc -and $cc.settleSec){$settle=[int]$cc.settleSec}
    foreach($p in $packages){
        if([string]$p -notmatch '^[A-Za-z0-9_.]+$'){throw "Invalid background package name: $p"}
        Invoke-GpkShell -Config $cfg -Command "monkey -p $p 1" -AllowFailure|Out-Null
        $State.backgroundPackages+=@([string]$p);Save-GpkState $Context $State
    }
    $activity=Get-GpkActivity $cfg
    if($activity){Invoke-GpkShell -Config $cfg -Command "am start -n $activity" -AllowFailure|Out-Null}
    Add-GpkMarker $Context 'background_apps_started' ($packages -join ',')
    Wait-GpkDuration -Seconds $settle -Activity 'Background competition settling'
    $mem=(Invoke-GpkShell -Config $cfg -Command 'cat /proc/meminfo' -OutFile (Join-Path $Context.RawRoot 'meminfo-before-pressure-window.txt')).Text
    if($cc -and $cc.maxMemAvailableMiB -and $mem -match '(?m)^MemAvailable:\s+(\d+)'){
        $miB=[math]::Round(([double]$Matches[1])/1024,1);if($miB -gt [double]$cc.maxMemAvailableMiB){Add-GpkWarning $Context "MemAvailable is $miB MiB, above configured low-memory target $($cc.maxMemAvailableMiB) MiB; treat this run as background competition only."}
    }
    Invoke-GpkBattleWindow $Context (Get-GpkDuration $cfg 'backgroundPressure')
}

function Invoke-GpkCase {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$CaseName,[Parameter(Mandatory=$true)]$Config,[Parameter(Mandatory=$true)][string]$KitRoot,[switch]$NonInteractive)
    $valid=@((Get-GpkCaseCatalog).Case);$normalized=$CaseName.ToLowerInvariant()
    if($normalized -notin $valid){throw "Unknown case '$CaseName'. Valid cases: $($valid -join ', ')"}
    $ctx=New-GpkRunContext -Config $Config -CaseName $normalized -KitRoot $KitRoot;$state=$null;$status='completed';$failure=$null
    try{
        $preflight=Invoke-GpkPreflight -Context $ctx -WriteArtifacts
        $state=Get-GpkInitialState $ctx;Save-GpkState $ctx $state
        Start-GpkLogcat $ctx;Save-GpkSnapshot $ctx 'start';Start-GpkSurfaceStats $ctx|Out-Null;Start-GpkCollector $ctx|Out-Null
        $state.remoteSamplerPid=$ctx.Collector.Pid;$state.remoteStopFile=$ctx.Collector.RemoteStop;$state.remoteFiles=@($ctx.Collector.RemoteScript,$ctx.Collector.RemoteOut,$ctx.Collector.RemoteStop,$ctx.Collector.RemoteLog);$state.surfaceFlingerEnabled=$ctx.SurfaceEnabled;Save-GpkState $ctx $state
        Start-GpkPerfetto $ctx|Out-Null
        if($ctx.Perfetto){$state.perfettoPid=$ctx.Perfetto.Pid;$state.perfettoFiles=@($ctx.Perfetto.RemoteConfig,$ctx.Perfetto.RemoteTrace,$ctx.Perfetto.RemoteExport);Save-GpkState $ctx $state}
        switch($normalized){
            'battle-60s'{Invoke-GpkBattleWindow $ctx (Get-GpkDuration $Config 'battle60s')}
            'longrun'{Invoke-GpkLongrunCase $ctx -NonInteractive:$NonInteractive}
            'memory-recovery'{Invoke-GpkMemoryRecoveryCase $ctx -NonInteractive:$NonInteractive}
            'battery-saver'{Invoke-GpkBatterySaverCase $ctx $state}
            'storage-5gb'{New-GpkStorageFiller $ctx $state;Invoke-GpkColdStartFlow $ctx -NonInteractive:$NonInteractive}
            'first-load'{Invoke-GpkFirstLoadCase $ctx}
            'manual-marker'{Invoke-GpkManualMarkerCase $ctx}
            'background-pressure'{Invoke-GpkBackgroundPressureCase $ctx $state}
            'cold-start-first-battle'{Invoke-GpkColdStartFlow $ctx -NonInteractive:$NonInteractive}
            'perfetto-trace'{Invoke-GpkPerfettoTraceCase $ctx}
        }
    } catch {
        $status='failed';$failure=$_.Exception.Message;Add-GpkWarning $ctx $failure
    } finally {
        try{Stop-GpkPerfetto $ctx}catch{Add-GpkWarning $ctx "Perfetto finalization failed: $($_.Exception.Message)"}
        try{Stop-GpkCollector $ctx}catch{Add-GpkWarning $ctx "Collector finalization failed: $($_.Exception.Message)"}
        try{Stop-GpkSurfaceStats $ctx}catch{Add-GpkWarning $ctx "SurfaceFlinger finalization failed: $($_.Exception.Message)"}
        try{Stop-GpkLogcat $ctx}catch{Add-GpkWarning $ctx "Logcat export failed: $($_.Exception.Message)"}
        try{Save-GpkSnapshot $ctx 'end'}catch{Add-GpkWarning $ctx "End snapshot failed: $($_.Exception.Message)"}
        if($state){try{Invoke-GpkCleanup -KitRoot $KitRoot -Config $Config;$ctx.CleanupSucceeded=$true}catch{Add-GpkWarning $ctx "Cleanup failed: $($_.Exception.Message)"}}
        try{
            $cleanupDir=Join-Path $ctx.RawRoot 'cleanup';New-Item -ItemType Directory -Force -Path $cleanupDir|Out-Null
            Invoke-GpkShell -Config $Config -Command 'settings get global low_power' -AllowFailure -OutFile (Join-Path $cleanupDir 'low-power.txt')|Out-Null
            Invoke-GpkShell -Config $Config -Command 'dumpsys power' -AllowFailure -OutFile (Join-Path $cleanupDir 'power.txt')|Out-Null
            Invoke-GpkShell -Config $Config -Command 'dumpsys battery' -AllowFailure -OutFile (Join-Path $cleanupDir 'battery.txt')|Out-Null
            Invoke-GpkShell -Config $Config -Command 'df -k /data' -AllowFailure -OutFile (Join-Path $cleanupDir 'storage.txt')|Out-Null
        }catch{Add-GpkWarning $ctx "Cleanup verification failed: $($_.Exception.Message)"}
        $extra=[ordered]@{failure=$failure}
        if($normalized -eq 'battery-saver'){
            $extra.batterySaver=[ordered]@{
                before=(Get-GpkSurfaceSummary -Path (Join-Path $ctx.RawRoot 'surfaceflinger-before-saver.txt') -PackageName $Config.packageName)
                after=(Get-GpkSurfaceSummary -Path (Join-Path $ctx.RawRoot 'surfaceflinger-after-saver.txt') -PackageName $Config.packageName)
            }
        }
        if($normalized -in @('storage-5gb','cold-start-first-battle')){
            $launchPath=Join-Path $ctx.RawRoot 'am-start-W.txt';$launch=[ordered]@{thisTimeMs=$null;totalTimeMs=$null;waitTimeMs=$null}
            if(Test-Path -LiteralPath $launchPath){$lt=Get-Content -LiteralPath $launchPath -Raw;if($lt-match '(?im)^ThisTime:\s*(\d+)'){$launch.thisTimeMs=[int]$Matches[1]};if($lt-match '(?im)^TotalTime:\s*(\d+)'){$launch.totalTimeMs=[int]$Matches[1]};if($lt-match '(?im)^WaitTime:\s*(\d+)'){$launch.waitTimeMs=[int]$Matches[1]}}
            $extra.launch=$launch
        }
        $summary=New-GpkSummary -Context $ctx -Status $status -Extra $extra
        Complete-GpkRun -Context $ctx -Summary $summary
        Write-Host "Result directory: $($ctx.ResultRoot)" -ForegroundColor Green
        Write-Host "ZIP: $($ctx.ZipPath)" -ForegroundColor Green
    }
    if($status -eq 'failed'){throw $failure}
}

Export-ModuleMember -Function Get-GpkCaseCatalog,Invoke-GpkCase
