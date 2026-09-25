@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File bot.ps1
pause
