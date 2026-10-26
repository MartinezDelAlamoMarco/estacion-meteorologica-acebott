@echo off
rem Haz doble clic aqui. Si no tienes permisos de administrador, los pide
rem y vuelve a abrirse solo. Despues lanza instalar.ps1.
net session >nul 2>&1
if %errorlevel% neq 0 (
  powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath '%~f0'"
  exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0instalar.ps1"
echo.
pause
