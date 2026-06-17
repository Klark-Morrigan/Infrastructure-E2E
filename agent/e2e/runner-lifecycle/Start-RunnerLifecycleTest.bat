@echo off

set APP_ID=3552893
set RUNNERS_INSTALLATION_ID=128315873
set PRIVATE_KEY_PATH="C:\Users\Klark Morgan\Code\Infrastructure-E2E\infrastructure-e2e.2026-04-30.private-key.pem"
set OWNER="Klark-Morrigan"

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-RunnerLifecycleTest.ps1" ^
    -AppId                 %APP_ID% ^
    -RunnersInstallationId %RUNNERS_INSTALLATION_ID% ^
    -PrivateKeyPath        "%PRIVATE_KEY_PATH%" ^
    -Owner                 %OWNER%
pause
