@echo off
setlocal
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo ==========================================
echo   CompanyInventory - Full Cleanup
echo ==========================================
echo.
echo This will remove:
echo   - Scheduled task  : CompanyInventoryStandalone
echo   - Folder          : C:\ProgramData\CompanyInventory
echo   - Per-user folder : C:\Users\*\AppData\Local\CompanyInventoryStandalone
echo   - Temp artifacts  : %TEMP%\inv_*.ps1, hist_*.db, hist_*.db-wal, hist_*.db-shm
echo   - PATH entries    : any entry pointing to C:\ProgramData\CompanyInventory
echo.
echo Google Sheets data is NOT touched by this script.
echo For that, run cleanupInventoryReceiver() in Apps Script.
echo.
set "confirm="
set /p confirm="Proceed? Type YES (all caps): "
if /i not "%confirm%"=="YES" (
    echo Cancelled.
    pause
    exit /b 1
)

echo.
echo [1/6] Stopping and removing scheduled task...
schtasks /End    /TN "CompanyInventoryStandalone" >nul 2>&1
schtasks /Delete /TN "CompanyInventoryStandalone" /F >nul 2>&1
echo       Done.

echo [2/6] Killing any running agent processes...
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'CompanyInventory|Agent\.ps1|inv_payload|inv_[0-9a-f]{32}' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }" >nul 2>&1
echo       Done.

echo [3/6] Removing install directory...
if exist "C:\ProgramData\CompanyInventory" (
    attrib -h -s -r "C:\ProgramData\CompanyInventory\*" /S /D >nul 2>&1
    rmdir /s /q "C:\ProgramData\CompanyInventory" >nul 2>&1
)
echo       Done.

echo [4/6] Removing per-user state folders (all profiles)...
for /d %%U in (C:\Users\*) do (
    if exist "%%U\AppData\Local\CompanyInventoryStandalone" rmdir /s /q "%%U\AppData\Local\CompanyInventoryStandalone" >nul 2>&1
)
echo       Done.

echo [5/6] Cleaning temp artifacts (all profiles)...
del /q "%TEMP%\inv_*.ps1"        >nul 2>&1
del /q "%TEMP%\inv_payload.ps1"  >nul 2>&1
del /q "%TEMP%\hist_*.db"        >nul 2>&1
del /q "%TEMP%\hist_*.db-wal"    >nul 2>&1
del /q "%TEMP%\hist_*.db-shm"    >nul 2>&1
for /d %%U in (C:\Users\*) do (
    if exist "%%U\AppData\Local\Temp" (
        del /q "%%U\AppData\Local\Temp\inv_*.ps1"       >nul 2>&1
        del /q "%%U\AppData\Local\Temp\inv_payload.ps1" >nul 2>&1
        del /q "%%U\AppData\Local\Temp\hist_*.db"       >nul 2>&1
        del /q "%%U\AppData\Local\Temp\hist_*.db-wal"   >nul 2>&1
        del /q "%%U\AppData\Local\Temp\hist_*.db-shm"   >nul 2>&1
    )
)
echo       Done.

echo [6/6] Removing PATH entries...
powershell.exe -NoProfile -Command ^
  "$d='C:\ProgramData\CompanyInventory'; foreach($scope in 'Machine','User'){ $p=[Environment]::GetEnvironmentVariable('Path',$scope); if($p){ $n=(($p -split ';') | Where-Object { $_ -and $_ -ne $d }) -join ';'; if($n -ne $p){ [Environment]::SetEnvironmentVariable('Path',$n,$scope); Write-Host ('  cleaned '+$scope+' PATH') } } }"
echo       Done.

echo.
echo ==========================================
echo   Windows cleanup complete.
echo ==========================================
echo.
echo Next steps:
echo   1. Delete the CompanyInventory.cmd you double-clicked (on Desktop / Downloads).
echo   2. In Apps Script, add and run cleanupInventoryReceiver().
echo   3. Sign out and back in once so any explorer.exe / PATH caches refresh.
echo.
pauses