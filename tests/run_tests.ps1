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

$failed = 0
& $GodotExe --headless --path $repoRoot --script res://tests/test_enum_conversions.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_array_variable_setters.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_map_variable_accessors.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_modulo_nodes.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_character_interpolation.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_dialogue_tags.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_import_hardening.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_reset_in_place.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_dialogue_in_loop_body.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_data_asset_store.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_data_asset_degraded.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_data_asset_nodes.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_data_asset_host_api.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_character_index.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_character_resolution.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_character_host_surface.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_save_legacy_shape.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
& $GodotExe --headless --path $repoRoot --script res://tests/test_save_unified.gd
if ($LASTEXITCODE -ne 0) { $failed = 1 }
exit $failed
