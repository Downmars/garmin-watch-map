# Build the ONLINE map app for one or more devices.
# Usage: pwsh -File tools\build_online.ps1 [-Devices fr255,venu441mm] [-Tag b1]
#
# Environment (optional):
#   CIQ_SDK   Connect IQ SDK directory (default: <repo>\appdata\Garmin\ConnectIQ\Sdks\<latest>)
#   CIQ_KEY   developer_key.der (default: <repo>\developer_key.der)
#
# Notes:
#   - online\manifest.xml is temporarily rewritten to list ONE product, then restored.
#   - java prints "Picked up _JAVA_OPTIONS" on stderr, which Windows PowerShell 5.1
#     turns into a terminating error under $ErrorActionPreference='Stop'; the native
#     call is therefore run with the preference relaxed and its output captured.

param(
    [string[]]$Devices = @('fr255', 'venu441mm', 'venu445mm'),
    [string]$Tag = 'b1'
)

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

$dist = Join-Path $root 'dist'
$logDir = Join-Path $root 'temp'
New-Item -ItemType Directory -Force $dist | Out-Null
New-Item -ItemType Directory -Force $logDir | Out-Null

$jdkBin = Join-Path $root 'tools\jdk17\jdk-17.0.2\bin'
if (Test-Path $jdkBin) { $env:PATH = $jdkBin + ';' + $env:PATH }
$env:APPDATA = Join-Path $root 'appdata'
$env:TEMP = $logDir
$env:TMP = $logDir
$env:_JAVA_OPTIONS = '-Xmx4g'

$manifest = Join-Path $root 'online\manifest.xml'
$bak = "$manifest.bak"
$mc = Join-Path $sdk 'bin\monkeyc.bat'
$jungle = Join-Path $root 'online\monkey.jungle'

Copy-Item $manifest $bak -Force
$template = Get-Content $bak -Raw
$fail = 0

try {
    foreach ($d in $Devices) {
        $m = $template -replace '<iq:product id="[^"]*"/>', ('<iq:product id="' + $d + '"/>')
        [System.IO.File]::WriteAllText($manifest, $m, (New-Object System.Text.UTF8Encoding($false)))

        $out = Join-Path $dist ("online_{0}_{1}.prg" -f $Tag, $d)
        $mcArgs = @('-f', $jungle, '-o', $out, '-d', $d, '-y', $key)

        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $log = (& $mc @mcArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
            $mcCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEA
        }
        Set-Content -Path (Join-Path $logDir "monkeyc_online_$d.log") -Value $log -Encoding UTF8

        if ($mcCode -eq 0 -and $log -match 'BUILD SUCCESSFUL') {
            $sz = (Get-Item $out).Length
            Write-Host ("{0,-12} OK    {1} bytes" -f $d, $sz)
        } else {
            $fail = $fail + 1
            $err = (($log -split "`n") | Select-String 'ERROR' | Select-Object -First 3).Line -join ' | '
            Write-Host ("{0,-12} FAIL  {1}" -f $d, $err)
        }
    }
} finally {
    Copy-Item $bak $manifest -Force
    Remove-Item $bak -Force
    Write-Host 'manifest restored'
}

exit $fail
