[CmdletBinding()]
param(
    [ValidateSet('list','preflight','run','cleanup','batch')]
    [string]$Command = 'list',

    [string]$Case,

    [string]$Config = (Join-Path $PSScriptRoot 'configs\generic-example.json'),

    [string]$GameName,

    [string]$ResultsRoot,

    [int]$DurationSec = 0,

    [switch]$Perfetto,

    [ValidateSet('balanced','cpu-jank','load-io')]
    [string]$PerfettoProfile = 'balanced',

    [int]$PerfettoDurationSec = 0,

    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'lib\AndroidGamePerfKit.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\AndroidGamePerfKit.Cases.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\AndroidGamePerfKit.Batch.psm1') -Force

try {
    switch ($Command) {
        'list' {
            Get-GpkCaseCatalog | Format-Table -AutoSize
        }
        'preflight' {
            $cfg = Read-GpkConfig -Path $Config
            if($GameName){$cfg.gameName=$GameName}
            $ctx = New-GpkRunContext -Config $cfg -CaseName 'preflight' -KitRoot $PSScriptRoot
            $report = Invoke-GpkPreflight -Context $ctx -WriteArtifacts
            Write-Host '[12/12] Packaging preflight artifacts...' -ForegroundColor Cyan
            Complete-GpkRun -Context $ctx -Summary $report
            Write-Host "Preflight complete: $($ctx.ZipPath)" -ForegroundColor Green
        }
        'cleanup' {
            $cfg = Read-GpkConfig -Path $Config
            if($GameName){$cfg.gameName=$GameName}
            Invoke-GpkCleanup -KitRoot $PSScriptRoot -Config $cfg -VerboseOutput
        }
        'batch' {
            [void](Invoke-GpkBatchReport -KitRoot $PSScriptRoot -ResultsRoot $ResultsRoot)
        }
        'run' {
            if ([string]::IsNullOrWhiteSpace($Case)) {
                throw 'Specify -Case. Run with -Command list to see available cases.'
            }
            $cfg = Read-GpkConfig -Path $Config
            if($GameName){$cfg.gameName=$GameName}
            if ($DurationSec -gt 0) {
                $cfg.defaults.durationSec = $DurationSec
                $cfg | Add-Member -NotePropertyName _durationOverrideSec -NotePropertyValue $DurationSec -Force
            }
            if($Perfetto){
                $traceDuration=$PerfettoDurationSec
                if($traceDuration -le 0){$traceDuration=if($DurationSec -gt 0){[math]::Min($DurationSec,60)}else{30}}
                if($traceDuration -lt 5 -or $traceDuration -gt 300){throw 'PerfettoDurationSec must be between 5 and 300 seconds.'}
                $cfg|Add-Member -NotePropertyName _perfettoEnabled -NotePropertyValue $true -Force
                $cfg|Add-Member -NotePropertyName _perfettoProfile -NotePropertyValue $PerfettoProfile -Force
                $cfg|Add-Member -NotePropertyName _perfettoDurationSec -NotePropertyValue $traceDuration -Force
            }
            Invoke-GpkCase -CaseName $Case -Config $cfg -KitRoot $PSScriptRoot -NonInteractive:$NonInteractive
        }
    }
}
catch {
    Write-Host ''
    Write-Host ("ERROR: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
