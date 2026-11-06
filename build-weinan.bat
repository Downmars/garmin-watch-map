@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-weinan.ps1" %*
exit /b %ERRORLEVEL%
