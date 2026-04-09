@echo off
setlocal

set "SERVER_NUMBER=139"
set "PS_PATH=C:\\Scripts\\Backup\\BackupScript.ps1"
set "LOG_FILE=C:\Scripts\Backup\logs\launcher_server_%SERVER_NUMBER%.log"

echo [%date% %time%] Triggering independent process for server %SERVER_NUMBER% >> "%LOG_FILE%"

wmic process call create "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%PS_PATH%\" -ServerNumber %SERVER_NUMBER%" >> "%LOG_FILE%" 2>&1

echo SERVER_%SERVER_NUMBER%_STARTED
echo [%date% %time%] SERVER_%SERVER_NUMBER%_STARTED >> "%LOG_FILE%"

endlocal
exit /b 0