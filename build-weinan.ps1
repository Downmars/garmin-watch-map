param(
    [double]$Lat = 34.5000,
    [double]$Lon = 109.5000,
    [double]$Km = 20,
    [int]$Zoom = 15,
    [switch]$CompileOnly,
    [switch]$Direct
)
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
$taskRoot = Split-Path (Split-Path $repoRoot -Parent) -Parent
$pythonExe = if ($env:CIQ_PY) { $env:CIQ_PY } else { Join-Path $taskRoot 'work\venv\Scripts\python.exe' }
$sdkRoot = if ($env:CIQ_SDK) { $env:CIQ_SDK } else { Join-Path $taskRoot 'work\connectiq-sdk' }
$keyFile = if ($env:CIQ_KEY) { $env:CIQ_KEY } else { Join-Path $repoRoot 'developer_key.der' }
$javaExe = if ($env:CIQ_JAVA) { $env:CIQ_JAVA } else {
    $bundledJava = Get-ChildItem (Join-Path $taskRoot 'work\jdk17') -Filter java.exe -Recurse | Select-Object -First 1
    if ($bundledJava) { $bundledJava.FullName } else { (Get-Command java).Source }
}
foreach ($requiredFile in @($pythonExe, $keyFile, (Join-Path $sdkRoot 'bin\monkeybrains.jar'), $javaExe)) {
    if (-not (Test-Path -LiteralPath $requiredFile)) { throw "Missing build dependency: $requiredFile" }
}
$savedTemp = $env:TEMP
$savedTmp = $env:TMP
$savedUtf8 = $env:PYTHONUTF8
Push-Location $repoRoot
try {
    New-Item -ItemType Directory -Force -Path 'temp', 'dist' | Out-Null
    $env:TEMP = Join-Path $repoRoot 'temp'
    $env:TMP = $env:TEMP
    $env:PYTHONUTF8 = '1'
    if (-not $CompileOnly) {
        $mapArgs = @('tools\make_city_pack.py', '--name', 'weinan', '--lat', $Lat, '--lon', $Lon,
            '--km', $Km, '--zoom', $Zoom, '--outdir', 'maps\weinan', '--tiles-only')
        if ($Direct) { $mapArgs += '--direct' }
        & $pythonExe @mapArgs
        if ($LASTEXITCODE -ne 0) { throw 'Map generation failed; rerun to resume cached downloads.' }
    }
    if (-not (Test-Path 'app\source\MapData.mc')) { throw 'No generated map. Run without -CompileOnly first.' }
    & $javaExe '-Xmx4g' '-Dfile.encoding=UTF-8' '-jar' (Join-Path $sdkRoot 'bin\monkeybrains.jar') `
        '-f' 'app\monkey.jungle' '-o' 'dist\weinan-fr255.prg' '-d' 'fr255' '-y' $keyFile
    if ($LASTEXITCODE -ne 0) { throw 'Garmin compilation failed.' }
    Get-Item 'dist\weinan-fr255.prg' | Select-Object FullName, Length
} finally {
    Pop-Location
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    $env:PYTHONUTF8 = $savedUtf8
}
