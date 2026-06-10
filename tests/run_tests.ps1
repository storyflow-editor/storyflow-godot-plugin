# Runs the StoryFlow plugin headless test suite.
#
# Usage:
#   powershell -File tests/run_tests.ps1 -GodotExe "C:\path\to\Godot_v4.3-stable_win64_console.exe"
# or set the GODOT_BIN environment variable and run without arguments.
param(
    [string]$GodotExe = $env:GODOT_BIN
)

if (-not $GodotExe) {
    Write-Host "ERROR: Pass -GodotExe or set GODOT_BIN to a Godot 4.3+ executable." -ForegroundColor Red
    exit 2
}

$repoRoot = Split-Path -Parent $PSScriptRoot

# First pass imports resources and builds the script class cache headless
# tests depend on. Safe to run repeatedly.
& $GodotExe --headless --path $repoRoot --import | Out-Null

& $GodotExe --headless --path $repoRoot --script res://tests/test_enum_conversions.gd
exit $LASTEXITCODE
