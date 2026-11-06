param(
    [double]$Lat = 34.5000,
    [double]$Lon = 109.5000,
    [double]$Km = 20,
    [int]$Zoom = 15,
    [switch]$CompileOnly,
    [switch]$Direct,
    [switch]$TestBuild,
    [string]$OutFile = 'dist\weinan-fr255.prg'
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
        if ($Zoom -ne 15) { throw 'The two-level build uses z15 and z13; omit -Zoom or use 15.' }
        $mapArgs = @('tools\make_multilevel_pack.py', '--lat', $Lat, '--lon', $Lon,
            '--km', $Km, '--outdir', 'maps\weinan-multilevel')
        if ($Direct) { $mapArgs += '--direct' }
        & $pythonExe @mapArgs
        if ($LASTEXITCODE -ne 0) { throw 'Map generation failed; rerun to resume cached downloads.' }
    }
    if (-not (Test-Path 'app\source\MapData.mc')) { throw 'No generated map. Run without -CompileOnly first.' }
    if (-not (Test-Path 'app\source\MapLayers.mc')) { throw 'No generated map levels. Run without -CompileOnly first.' }
    $jungle = if ($TestBuild) { 'test.jungle' } else { 'app\monkey.jungle' }
    $compileArgs = @('-Xmx4g', '-Dfile.encoding=UTF-8', '-jar', (Join-Path $sdkRoot 'bin\monkeybrains.jar'),
        '-f', $jungle, '-o', $OutFile, '-d', 'fr255', '-y', $keyFile, '-w')
    if ($TestBuild) { $compileArgs += '-t' }
    & $javaExe @compileArgs
    if ($LASTEXITCODE -ne 0) { throw 'Garmin compilation failed.' }
    Get-Item $OutFile | Select-Object FullName, Length
} finally {
    Pop-Location
    $env:TEMP = $savedTemp
    $env:TMP = $savedTmp
    $env:PYTHONUTF8 = $savedUtf8
}
