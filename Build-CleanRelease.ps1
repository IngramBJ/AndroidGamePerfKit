[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$SkipTests,
    [switch]$Force
)

$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version 2.0

$kitRoot=$PSScriptRoot
$version=(Get-Content -LiteralPath (Join-Path $kitRoot 'VERSION') -Raw).Trim()
if([string]::IsNullOrWhiteSpace($Destination)){
    $Destination=Join-Path (Split-Path -Parent $kitRoot) "AndroidGamePerfKit-v$version-clean.zip"
}
$destinationFull=[IO.Path]::GetFullPath($Destination)
if((Test-Path -LiteralPath $destinationFull) -and -not $Force){throw "Release ZIP already exists: $destinationFull (use -Force to replace this exact release file)"}

if(-not $SkipTests){
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $kitRoot 'tests\Run-SmokeTests.ps1')
    if($LASTEXITCODE -ne 0){throw "Smoke tests failed with exit code $LASTEXITCODE."}
}

$excludedRelative=@(
    '.state\',
    'results\',
    'batch-reports\',
    'Longrun-Calibrator\calibration-results\'
)
$excludedFiles=@(
    'configs\config-artofwar.json'
)
$files=@(Get-ChildItem -LiteralPath $kitRoot -Recurse -File|Where-Object{
    $relative=$_.FullName.Substring($kitRoot.Length+1)
    $excluded=$false
    foreach($prefix in $excludedRelative){if($relative.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){$excluded=$true;break}}
    if($relative -in $excludedFiles){$excluded=$true}
    if($_.Extension -in @('.zip','.trace','.perfetto-trace')){$excluded=$true}
    -not $excluded
})

foreach($file in $files|Where-Object{$_.Extension -in @('.ps1','.psm1','.cmd','.vbs','.json','.md','.txt','.pbtxt','.sh')}){
    $text=Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
    if($text -match '(?i)[A-Z]:\\Users\\[^\\\r\n]+' ){throw "Possible absolute user path remains in: $($file.FullName)"}
    foreach($match in [regex]::Matches($text,'(?i)"deviceSerial"\s*:\s*"([^"\s]+)"')){
        $serial=$match.Groups[1].Value
        if($serial -notmatch '^(?:MOCK|TEST|DEMO)'){throw "A non-empty deviceSerial remains in: $($file.FullName)"}
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fileMode=if($Force){[IO.FileMode]::Create}else{[IO.FileMode]::CreateNew}
$stream=[IO.File]::Open($destinationFull,$fileMode)
try{
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try{
        foreach($file in $files){
            $relative=$file.FullName.Substring($kitRoot.Length+1).Replace('\','/')
            $entry=$archive.CreateEntry("AndroidGamePerfKit/$relative",[IO.Compression.CompressionLevel]::Optimal)
            $entryStream=$entry.Open()
            try{
                $input=[IO.File]::OpenRead($file.FullName)
                try{$input.CopyTo($entryStream)}finally{$input.Dispose()}
            }finally{$entryStream.Dispose()}
        }
    }finally{$archive.Dispose()}
}finally{$stream.Dispose()}

$required=@(
    'AndroidGamePerfKit/Start-AndroidGamePerfKit.vbs',
    'AndroidGamePerfKit/Start-Longrun-Calibrator.vbs',
    'AndroidGamePerfKit/Longrun-Calibrator/Longrun-Calibrator.ps1',
    'AndroidGamePerfKit/configs/generic-example.json',
    'AndroidGamePerfKit/lib/AndroidGamePerfKit.Core.psm1',
    'AndroidGamePerfKit/lib/AndroidGamePerfKit.Batch.psm1',
    'AndroidGamePerfKit/lib/AndroidGamePerfKit.Calibration.psm1',
    'AndroidGamePerfKit/perfetto/profiles/balanced.pbtxt'
)
$read=[IO.Compression.ZipFile]::OpenRead($destinationFull)
try{
    $names=@($read.Entries|ForEach-Object FullName)
    foreach($name in $required){if($name -notin $names){throw "Release ZIP is missing: $name"}}
    if($names|Where-Object{$_ -match '/(?:results|batch-reports|\.state|calibration-results)/'}){throw 'Release ZIP unexpectedly contains runtime data.'}
}finally{$read.Dispose()}

Write-Host "Clean release created: $destinationFull" -ForegroundColor Green
Write-Host "Files: $($files.Count)" -ForegroundColor Green
