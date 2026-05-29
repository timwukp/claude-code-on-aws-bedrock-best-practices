@echo off
REM Enterprise Claude Code wrapper — blocks bypass flags (Windows)
REM Deploy at: C:\Program Files\ClaudeCode\claude.cmd
REM Real binary at: C:\Program Files\ClaudeCode\bin\claude.exe (not on user PATH)

setlocal enabledelayedexpansion
set "BLOCKED="
set "NEXT_IS_MODE=0"

for %%A in (%*) do (
    if "%%A"=="--dangerously-skip-permissions" set "BLOCKED=%%A"
    if "%%A"=="--allow-dangerously-skip-permissions" set "BLOCKED=%%A"
    if "%%A"=="--bare" set "BLOCKED=%%A"
    if "!NEXT_IS_MODE!"=="1" (
        if "%%A"=="bypassPermissions" set "BLOCKED=--permission-mode %%A"
        if "%%A"=="auto" set "BLOCKED=--permission-mode %%A"
        set "NEXT_IS_MODE=0"
    )
    if "%%A"=="--permission-mode" set "NEXT_IS_MODE=1"
)

if defined BLOCKED (
    echo Refused: "%BLOCKED%" is disabled by enterprise policy. >&2
    exit /b 1
)

REM Block `claude mcp add`
if "%~1"=="mcp" if "%~2"=="add" (
    echo Refused: "claude mcp add" is disabled by enterprise policy. Contact IT. >&2
    exit /b 1
)

"C:\Program Files\ClaudeCode\bin\claude.exe" %*
