Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:GpkBatchVersion=(Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'VERSION') -Raw).Trim()

function Get-GpkBatchProperty {
    param([AllowNull()]$Object,[string]$Name)
    if($null -eq $Object){return $null}
    if($Object -is [System.Collections.IDictionary]){if($Object.Contains($Name)){return $Object[$Name]};return $null}
    $property=$Object.PSObject.Properties[$Name]
    if($property){return $property.Value}
    return $null
}

function Get-GpkBatchNested {
    param([AllowNull()]$Object,[string[]]$Path)
    $value=$Object
    foreach($name in $Path){$value=Get-GpkBatchProperty -Object $value -Name $name;if($null -eq $value){return $null}}
    return $value
}

function ConvertTo-GpkBatchRelativePath {
    param([string]$BasePath,[string]$Path)
    $base=[IO.Path]::GetFullPath($BasePath).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($Path)
    if($full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){return $full.Substring($base.Length).Replace('\','/')}
    return $full.Replace('\','/')
}

function ConvertTo-GpkBatchHtml {
    param([AllowNull()]$Value)
    if($null -eq $Value){return ''}
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-GpkBatchAssessment {
    param([string]$CaseName,[string]$Status,[string]$DataQuality,[double]$TargetFps,[AllowNull()]$AverageFps,[AllowNull()]$P99Ms,[AllowNull()]$Over100Ms,[AllowNull()]$RssDeltaMiB,[string[]]$Warnings)
    $notes=New-Object Collections.Generic.List[string]
    if($CaseName -eq 'preflight'){
        if($Status -eq 'pass'){return [pscustomobject]@{result='pass';notes='预检通过'}}
        return [pscustomobject]@{result='fail';notes="预检状态=$Status"}
    }
    if($Status -ne 'completed'){$notes.Add("测试状态=$Status");return [pscustomobject]@{result='fail';notes=($notes -join '；')}}
    if($DataQuality -ne 'valid'){$notes.Add("数据质量=$DataQuality")}
    if($null -eq $AverageFps){$notes.Add('缺少平均FPS')}
    elseif($TargetFps -gt 0 -and [double]$AverageFps -lt $TargetFps*0.9){$notes.Add(("平均FPS {0}低于目标90%" -f $AverageFps))}
    elseif($TargetFps -gt 0 -and [double]$AverageFps -lt $TargetFps*0.98){$notes.Add(("平均FPS {0}低于目标" -f $AverageFps))}
    if($null -ne $P99Ms -and $TargetFps -gt 0 -and [double]$P99Ms -gt 2000/$TargetFps){$notes.Add(("P99={0}ms" -f $P99Ms))}
    if($null -ne $Over100Ms -and [int64]$Over100Ms -gt 0){$notes.Add((">100ms长帧={0}" -f $Over100Ms))}
    if($null -ne $RssDeltaMiB -and [double]$RssDeltaMiB -gt 200){$notes.Add(("RSS增加={0}MiB" -f $RssDeltaMiB))}
    if(@($Warnings).Count -gt 0){$notes.Add(("警告={0}条" -f @($Warnings).Count))}
    $result='pass'
    if($DataQuality -ne 'valid' -or $null -eq $AverageFps){$result='review'}
    elseif($TargetFps -gt 0 -and [double]$AverageFps -lt $TargetFps*0.9){$result='fail'}
    elseif($notes.Count -gt 0){$result='warn'}
    return [pscustomobject]@{result=$result;notes=($notes -join '；')}
}

function ConvertTo-GpkBatchRow {
    param([string]$KitRoot,[IO.FileInfo]$SummaryFile)
    $folder=$SummaryFile.Directory.FullName
    $metadataPath=Join-Path $folder 'metadata.json'
    $summary=$null;$metadata=$null;$parseError=''
    try{$summary=Get-Content -LiteralPath $SummaryFile.FullName -Raw -Encoding UTF8|ConvertFrom-Json}catch{$parseError="summary.json无法读取：$($_.Exception.Message)"}
    if(Test-Path -LiteralPath $metadataPath){try{$metadata=Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{if($parseError){$parseError+='；'};$parseError+="metadata.json无法读取：$($_.Exception.Message)"}}
    $caseName=[string](Get-GpkBatchProperty $metadata 'caseName');if(-not $caseName){$caseName=[string](Get-GpkBatchProperty $summary 'caseName')};if(-not $caseName){$caseName=$SummaryFile.Directory.Parent.Name}
    $status=[string](Get-GpkBatchProperty $summary 'status');if(-not $status){$status=if($parseError){'unreadable'}else{'unknown'}}
    $quality=[string](Get-GpkBatchProperty $summary 'dataQuality');if(-not $quality){$quality=if($caseName -eq 'preflight'){'not-applicable'}else{'unknown'}}
    $target=Get-GpkBatchProperty $summary 'targetFps';if($null -eq $target){$target=Get-GpkBatchProperty $metadata 'targetFps'};$targetNumber=0.0;if($null -ne $target){$targetNumber=[double]$target}
    $sf=Get-GpkBatchProperty $summary 'surfaceFlinger';$samples=Get-GpkBatchProperty $summary 'samples';$perfetto=Get-GpkBatchProperty $summary 'perfetto'
    $warnings=@(Get-GpkBatchProperty $summary 'warnings'|Where-Object{$null -ne $_ -and [string]$_})
    if($parseError){$warnings+=@($parseError)}
    $averageFps=Get-GpkBatchProperty $sf 'averageFps';$p99=Get-GpkBatchProperty $sf 'p99Ms';$over100=Get-GpkBatchProperty $sf 'over100Ms';$rssDelta=Get-GpkBatchProperty $samples 'rssDeltaMiB'
    $assessment=Get-GpkBatchAssessment -CaseName $caseName -Status $status -DataQuality $quality -TargetFps $targetNumber -AverageFps $averageFps -P99Ms $p99 -Over100Ms $over100 -RssDeltaMiB $rssDelta -Warnings $warnings
    $started=[string](Get-GpkBatchProperty $summary 'startedAt');if(-not $started){$started=[string](Get-GpkBatchProperty $summary 'checkedAt')}
    $finished=[string](Get-GpkBatchProperty $summary 'finishedAt')
    $duration=Get-GpkBatchProperty $samples 'durationSec'
    if($null -eq $duration -and $started -and $finished){try{$duration=[math]::Round(([datetime]$finished-[datetime]$started).TotalSeconds,3)}catch{}}
    $frameCount=Get-GpkBatchProperty $sf 'frameCount'
    $severeRate=$null;if($null -ne $frameCount -and [double]$frameCount -gt 0 -and $null -ne $over100){$severeRate=[math]::Round([double]$over100/[double]$frameCount,6)}
    $fpsVsTarget=$null;if($targetNumber -gt 0 -and $null -ne $averageFps){$fpsVsTarget=[math]::Round([double]$averageFps/$targetNumber,4)}
    $resultZip=Join-Path $SummaryFile.Directory.Parent.FullName ($SummaryFile.Directory.Name+'.zip')
    return [pscustomobject][ordered]@{
        runId=if($metadata){[string](Get-GpkBatchProperty $metadata 'timestamp')}else{$SummaryFile.Directory.Name}
        gameName=[string](Get-GpkBatchProperty $metadata 'gameName');packageName=[string](Get-GpkBatchProperty $metadata 'packageName')
        deviceLabel=[string](Get-GpkBatchProperty $metadata 'deviceLabel');deviceSerial=[string](Get-GpkBatchProperty $metadata 'deviceSerial')
        caseName=$caseName;startedAt=$started;finishedAt=$finished;durationSec=$duration;targetFps=$target
        status=$status;dataQuality=$quality;automaticResult=$assessment.result;riskNotes=$assessment.notes
        averageFps=$averageFps;fpsVsTargetPct=$fpsVsTarget;frameCount=$frameCount;p95Ms=(Get-GpkBatchProperty $sf 'p95Ms');p99Ms=$p99;maxMs=(Get-GpkBatchProperty $sf 'maxMs')
        over50Ms=(Get-GpkBatchProperty $sf 'over50Ms');over66_7Ms=(Get-GpkBatchProperty $sf 'over66_7Ms');over100Ms=$over100;over100Rate=$severeRate
        sampleCount=(Get-GpkBatchProperty $samples 'sampleCount');processCpuAvgPct=(Get-GpkBatchProperty $samples 'processCpuAvgPct');unityMainCpuAvgPct=(Get-GpkBatchProperty $samples 'unityMainCpuAvgPct')
        rssAvgMiB=(Get-GpkBatchProperty $samples 'rssAvgMiB');rssPeakMiB=(Get-GpkBatchProperty $samples 'rssPeakMiB');rssDeltaMiB=$rssDelta
        memAvailableMinMiB=(Get-GpkBatchProperty $samples 'memAvailableMinMiB');swapUsedPeakMiB=(Get-GpkBatchProperty $samples 'swapUsedPeakMiB');thermalMaxC=(Get-GpkBatchProperty $samples 'thermalMaxC')
        perfettoRequested=(Get-GpkBatchProperty $perfetto 'requested');perfettoCompleted=(Get-GpkBatchProperty $perfetto 'captureCompleted');perfettoProfile=(Get-GpkBatchProperty $perfetto 'profile');traceSizeBytes=(Get-GpkBatchProperty $perfetto 'traceSizeBytes')
        warningCount=@($warnings).Count;warnings=($warnings -join ' | ')
        resultPath=(ConvertTo-GpkBatchRelativePath -BasePath $KitRoot -Path $folder);resultZip=if(Test-Path -LiteralPath $resultZip){ConvertTo-GpkBatchRelativePath -BasePath $KitRoot -Path $resultZip}else{''}
    }
}

function Write-GpkBatchHtmlReport {
    param([object[]]$Rows,[string]$Path,[string]$GeneratedAt)
    $counts=[ordered]@{total=@($Rows).Count;pass=@($Rows|Where-Object automaticResult -eq 'pass').Count;warn=@($Rows|Where-Object automaticResult -eq 'warn').Count;review=@($Rows|Where-Object automaticResult -eq 'review').Count;fail=@($Rows|Where-Object automaticResult -eq 'fail').Count}
    $body=New-Object Text.StringBuilder
    foreach($row in $Rows){
        $class=ConvertTo-GpkBatchHtml $row.automaticResult
        $values=@($row.runId,$row.gameName,$row.deviceLabel,$row.caseName,$row.startedAt,$row.status,$row.dataQuality,$row.automaticResult,$row.averageFps,$row.p95Ms,$row.p99Ms,$row.over100Ms,$row.processCpuAvgPct,$row.unityMainCpuAvgPct,$row.rssDeltaMiB,$row.thermalMaxC,$row.riskNotes)
        [void]$body.Append("<tr class=`"$class`">")
        foreach($value in $values){[void]$body.Append('<td>'+(ConvertTo-GpkBatchHtml $value)+'</td>')}
        [void]$body.AppendLine('</tr>')
    }
    $html=@"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AndroidGamePerfKit 批量汇总</title>
<style>body{font-family:"Microsoft YaHei",Segoe UI,sans-serif;margin:0;background:#f4f6f8;color:#17212b}.wrap{max-width:1500px;margin:24px auto;padding:0 18px}.card{background:#fff;border:1px solid #dfe4ea;border-radius:12px;padding:18px;margin:12px 0;box-shadow:0 3px 14px #16202a0c}.cards{display:grid;grid-template-columns:repeat(5,minmax(100px,1fr));gap:10px}.metric{padding:14px;border-radius:9px;background:#f7f9fb}.metric b{font-size:24px;display:block}.table-wrap{overflow:auto;max-height:72vh}table{border-collapse:collapse;width:100%;font-size:13px;white-space:nowrap}th,td{padding:8px 10px;border-bottom:1px solid #e8edf1;text-align:left}th{position:sticky;top:0;background:#eef2f5;z-index:1}.fail{background:#fff0ef}.review{background:#fff8e4}.warn{background:#fffbea}.pass{background:#f1faf4}input{padding:9px 12px;width:min(460px,90%);border:1px solid #cbd3db;border-radius:7px}.muted{color:#68737f}@media(max-width:800px){.cards{grid-template-columns:repeat(2,1fr)}}</style></head><body><main class="wrap">
<section class="card"><h1>AndroidGamePerfKit 批量测试汇总</h1><div class="muted">生成时间：$(ConvertTo-GpkBatchHtml $GeneratedAt)；只读取 metadata.json 和 summary.json。</div></section>
<section class="cards"><div class="metric"><span>全部</span><b>$($counts.total)</b></div><div class="metric pass"><span>通过</span><b>$($counts.pass)</b></div><div class="metric warn"><span>警告</span><b>$($counts.warn)</b></div><div class="metric review"><span>待复核</span><b>$($counts.review)</b></div><div class="metric fail"><span>失败</span><b>$($counts.fail)</b></div></section>
<section class="card"><input id="filter" placeholder="搜索游戏、设备、用例、RUN或风险"><div class="table-wrap"><table id="runs"><thead><tr><th>RUN</th><th>游戏</th><th>设备</th><th>用例</th><th>开始时间</th><th>状态</th><th>质量</th><th>判定</th><th>平均FPS</th><th>P95</th><th>P99</th><th>&gt;100ms</th><th>CPU%</th><th>UnityMain%</th><th>RSS变化</th><th>最高温度</th><th>风险说明</th></tr></thead><tbody>$($body.ToString())</tbody></table></div></section>
<section class="card muted">完整字段、数值精度和结果目录映射见同目录 batch-summary.csv / batch-summary.json。自动判定用于初筛，不替代原始记录核对。</section></main><script>const q=document.getElementById('filter');q.addEventListener('input',()=>{const s=q.value.toLowerCase();document.querySelectorAll('#runs tbody tr').forEach(r=>r.style.display=r.innerText.toLowerCase().includes(s)?'':'none')});</script></body></html>
"@
    [IO.File]::WriteAllText($Path,$html,(New-Object Text.UTF8Encoding($false)))
}

function Invoke-GpkBatchReport {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$KitRoot,[string]$ResultsRoot)
    $kit=[IO.Path]::GetFullPath($KitRoot)
    if(-not $ResultsRoot){$ResultsRoot=Join-Path $kit 'results'}
    $results=[IO.Path]::GetFullPath($ResultsRoot)
    if(-not(Test-Path -LiteralPath $results)){throw "Results directory does not exist: $results"}
    $summaryFiles=@(Get-ChildItem -LiteralPath $results -Recurse -File -Filter summary.json|Sort-Object FullName)
    if($summaryFiles.Count -eq 0){throw "No summary.json files were found under: $results"}
    $rows=@();foreach($file in $summaryFiles){$rows+=,(ConvertTo-GpkBatchRow -KitRoot $kit -SummaryFile $file)}
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$root=Join-Path $kit 'batch-reports';$folder=Join-Path $root $stamp
    New-Item -ItemType Directory -Force -Path $folder|Out-Null
    $csv=Join-Path $folder 'batch-summary.csv';$json=Join-Path $folder 'batch-summary.json';$html=Join-Path $folder 'batch-report.html';$anomalies=Join-Path $folder 'anomalies.txt'
    $rows|Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $counts=[ordered]@{total=$rows.Count;pass=@($rows|Where-Object automaticResult -eq 'pass').Count;warn=@($rows|Where-Object automaticResult -eq 'warn').Count;review=@($rows|Where-Object automaticResult -eq 'review').Count;fail=@($rows|Where-Object automaticResult -eq 'fail').Count}
    $generated=(Get-Date).ToString('o');Write-GpkJson -Path $json -Object ([ordered]@{schemaVersion=1;toolVersion=$script:GpkBatchVersion;generatedAt=$generated;sourceRoot=(ConvertTo-GpkBatchRelativePath -BasePath $kit -Path $results);counts=$counts;rows=@($rows)})
    Write-GpkBatchHtmlReport -Rows $rows -Path $html -GeneratedAt $generated
    $anomalyRows=@($rows|Where-Object automaticResult -ne 'pass')
    $lines=@('AndroidGamePerfKit Batch Anomalies',"GeneratedAt=$generated","Total=$($rows.Count)","NonPass=$($anomalyRows.Count)",'')
    foreach($row in $anomalyRows){$lines+=("[{0}] {1} | {2} | {3} | {4} | {5}" -f $row.automaticResult.ToUpperInvariant(),$row.runId,$row.gameName,$row.deviceLabel,$row.caseName,$row.riskNotes)}
    Set-Content -LiteralPath $anomalies -Value $lines -Encoding UTF8
    $zip=Join-Path $root "$stamp.zip";Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zip -Force
    Write-Host "Batch rows: $($rows.Count) (pass=$($counts.pass), warn=$($counts.warn), review=$($counts.review), fail=$($counts.fail))" -ForegroundColor Green
    Write-Host "Batch report: $html" -ForegroundColor Green
    Write-Host "Small sharing ZIP: $zip" -ForegroundColor Green
    return [pscustomobject]@{folder=$folder;zip=$zip;html=$html;csv=$csv;json=$json;anomalies=$anomalies;rowCount=$rows.Count;counts=$counts}
}

Export-ModuleMember -Function Invoke-GpkBatchReport
