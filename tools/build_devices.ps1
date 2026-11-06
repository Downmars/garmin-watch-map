# Build the offline map app for every installed device profile.
# Usage:  pwsh -File tools\build_devices.ps1 [fr255 venu441mm ...]
# Without arguments it builds every device profile found under the SDK.
#
# Environment (optional):
#   CIQ_SDK   Connect IQ SDK directory (default: <repo>\appdata\Garmin\ConnectIQ\Sdks\<latest>)
#   CIQ_KEY   developer_key.der (default: <repo>\developer_key.der)

param([string[]]$Devices)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$sdk = $env:CIQ_SDK
if (-not $sdk) {
    $candidates = Get-ChildItem (Join-Path $root 'appdata\Garmin\ConnectIQ\Sdks') -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
    if ($candidates) { $sdk = $candidates[0].FullName }
}
if (-not $sdk -or -not (Test-Path (Join-Path $sdk 'bin\monkeyc.bat'))) {
    Write-Host '[ERROR] Connect IQ SDK not found. Set CIQ_SDK to the SDK directory.'
    exit 1
}

$key = $env:CIQ_KEY
if (-not $key) { $key = Join-Path $root 'developer_key.der' }
if (-not (Test-Path $key)) {
    Write-Host "[ERROR] developer key not found: $key"
    exit 1
}

$devDir = Join-Path $sdk 'Devices'
$manifest = Join-Path $root 'app\manifest.xml'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$logDir = Join-Path $root 'temp'
New-Item -ItemType Directory -Force $logDir | Out-Null

$jdkBin = Join-Path $root 'tools\jdk17\jdk-17.0.2\bin'
if (Test-Path $jdkBin) { $env:PATH = $jdkBin + ';' + $env:PATH }
$env:APPDATA = Join-Path $root 'appdata'
$env:TEMP = $logDir
$env:TMP = $logDir
$env:_JAVA_OPTIONS = '-Xmx4g'

if (-not $Devices -and (Test-Path $devDir)) {
    $Devices = Get-ChildItem $devDir -Directory | Select-Object -ExpandProperty Name
}
if (-not $Devices) { Write-Host 'No device profiles found.'; exit 1 }

Copy-Item $manifest "$manifest.bak" -Force
$template = Get-Content "$manifest.bak" -Raw
$results = @()

try {
    foreach ($d in $Devices) {
        if ((Test-Path $devDir) -and -not (Test-Path (Join-Path $devDir $d))) {
            Write-Host ("{0,-12} skipped (profile not installed)" -f $d)
            continue
        }
        $m = $template -replace '<iq:product id="[^"]*"/>', ('<iq:product id="' + $d + '"/>')
        [System.IO.File]::WriteAllText($manifest, $m, (New-Object System.Text.UTF8Encoding($false)))

        # java prints "Picked up _JAVA_OPTIONS" on stderr, which Windows PowerShell 5.1
        # turns into a terminating error under $ErrorActionPreference='Stop'.
        $mc = Join-Path $sdk 'bin\monkeyc.bat'
        $out = Join-Path $dist "map_$d.prg"
        $mcArgs = @('-f', (Join-Path $root 'app\monkey.jungle'), '-o', $out, '-d', $d, '-y', $key)
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $log = (& $mc @mcArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $mcCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEA
        }
        Set-Content -Path (Join-Path $logDir "monkeyc_$d.log") -Value $log -Encoding UTF8

        if ($mcCode -eq 0 -and $log -match 'BUILD SUCCESSFUL') {
            $sz = (Get-Item $out).Length
            Write-Host ("{0,-12} OK    {1:N1} MB" -f $d, ($sz / 1MB))
            $results += [pscustomobject]@{ Device = $d; SizeMB = [math]::Round($sz / 1MB, 1) }
        } else {
            $err = (($log -split "`n") | Select-String 'ERROR' | Select-Object -First 3).Line -join ' | '
            Write-Host ("{0,-12} FAIL  {1}" -f $d, $err)
        }
    }
} finally {
    Copy-Item "$manifest.bak" $manifest -Force
    Remove-Item "$manifest.bak" -Force
    Write-Host 'manifest restored'
}

$results | Format-Table -AutoSize
