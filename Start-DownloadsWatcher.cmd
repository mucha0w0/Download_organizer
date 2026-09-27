@echo off
REM Launch Downloads sorter watcher hidden (for Startup / Task Scheduler)
start "" /MIN powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Watch-Downloads.ps1"
