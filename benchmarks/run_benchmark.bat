@echo off
chcp 65001 >nul
echo ============================================================
echo   LuaOOP Benchmark Runner
echo ============================================================
echo.

set LUA=C:\SoftInstall\lua-5.4.0_Win64_bin\lua54.exe
set ROOT=%~dp0..

if not exist "%LUA%" (
    echo ERROR: Lua runtime not found at %LUA%
    echo Please update the LUA variable in this script.
    exit /b 1
)

echo [1/2] suite/oop_benchmark.lua ...
echo ------------------------------------------------------------
"%LUA%" "%ROOT%\benchmarks\suite\oop_benchmark.lua"
if errorlevel 1 goto :failed

echo.
echo [2/2] suite/oop_features_profile.lua ...
echo ------------------------------------------------------------
"%LUA%" "%ROOT%\benchmarks\suite\oop_features_profile.lua"
if errorlevel 1 goto :failed

echo.
echo ============================================================
echo   All suite benchmarks completed successfully!
echo ============================================================
echo.
echo   专项排查脚本请按需单独运行，见 benchmarks\README.md
echo.
pause
exit /b 0

:failed
echo.
echo ERROR: benchmark failed!
exit /b 1