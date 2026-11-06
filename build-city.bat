@echo off
rem ============================================================
rem  build-city.bat - one-click city offline tile pack builder
rem
rem  Usage:
rem    build-city.bat --name qingdao --lat 36.10 --lon 120.43 --km 24 --zoom 15
rem
rem  Required environment (set once, or edit the defaults below):
rem    CIQ_SDK   path to the Connect IQ SDK directory
rem              (the folder containing bin\monkeyc.bat)
rem    CIQ_KEY   path to your developer_key.der
rem    CIQ_PY    optional: python executable (default: python on PATH)
rem
rem  See docs\BUILD.md for how to obtain the SDK and a developer key.
rem ============================================================
setlocal

set ROOT=%~dp0
rem run from the repo root so relative paths (app, dist, maps) resolve
cd /d "%ROOT%"

rem --- python ---
set PY=%CIQ_PY%
if "%PY%"=="" set PY=python

rem --- Connect IQ SDK ---
set SDK=%CIQ_SDK%
if "%SDK%"=="" set SDK=%ROOT%appdata\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.3.0-2026-10-20-95888f262

rem --- developer key ---
set KEY=%CIQ_KEY%
if "%KEY%"=="" set KEY=%ROOT%developer_key.der

if not exist "%SDK%\bin\monkeyc.bat" (
  echo [ERROR] Connect IQ SDK not found at:
  echo         %SDK%
  echo         Set CIQ_SDK to the SDK directory, e.g.
  echo         set CIQ_SDK=C:\path\to\connectiq-sdk-win-x.y.z
  exit /b 1
)
if not exist "%KEY%" (
  echo [ERROR] Developer key not found at:
  echo         %KEY%
  echo         Set CIQ_KEY to your developer_key.der
  exit /b 1
)

rem --- scratch dirs ----------------------------------------------------------
rem monkeyc writes its resource cache under %TEMP%; the directory must exist,
rem otherwise every bitmap fails with "Can't create cache file".
if not exist "%ROOT%temp" mkdir "%ROOT%temp"
set TEMP=%ROOT%temp
set TMP=%TEMP%

rem --- JDK if bundled, otherwise rely on java on PATH ---
if exist "%ROOT%tools\jdk17\jdk-17.0.2\bin" set PATH=%ROOT%tools\jdk17\jdk-17.0.2\bin;%PATH%

"%PY%" "%ROOT%tools\make_city_pack.py" %* --sdk "%SDK%" --key "%KEY%"
exit /b %ERRORLEVEL%
