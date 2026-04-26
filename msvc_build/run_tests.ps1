# run_tests.ps1 - Run libffi.call tests against the MSVC-built library
#
# Usage:
#   .\run_tests.ps1                             # x64 MT
#   .\run_tests.ps1 -Platform x64 -Config MT
#   .\run_tests.ps1 -Platform Win32 -Config MT  # 32-bit
#   .\run_tests.ps1 -Platform ARM64 -Config MT  # requires ARM64 Windows
#   .\run_tests.ps1 -Filter strlen              # Run only matching tests

param(
    [ValidateSet("x64","Win32","ARM64")]
    [string]$Platform = "x64",
    [ValidateSet("MT","MTd","MD","MDd")]
    [string]$Config   = "MT",
    [string]$Filter   = ""
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path "$ScriptDir\.."

$hostArch = if ($env:PROCESSOR_ARCHITEW6432) {
    $env:PROCESSOR_ARCHITEW6432
} else {
    $env:PROCESSOR_ARCHITECTURE
}

if ($Platform -eq "ARM64" -and $hostArch -ne "ARM64") {
    Write-Error "ARM64 test execution requires an ARM64 Windows host. Current host architecture: $hostArch"
    exit 1
}

# -------------------------------------------------------------------------
# Locate Visual Studio and set up the MSVC environment
# -------------------------------------------------------------------------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found. Please install Visual Studio."
    exit 1
}

$requiredToolset = if ($Platform -eq "ARM64") {
    "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
} else {
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
}

$vsPath = & $vswhere -latest -products * `
    -requires $requiredToolset `
    -property installationPath 2>$null
if (-not $vsPath) {
    Write-Error "No Visual Studio installation with required C++ tools found: $requiredToolset"
    exit 1
}

$vcvarsall = "$vsPath\VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcvarsall)) {
    Write-Error "vcvarsall.bat not found at: $vcvarsall"
    exit 1
}

Write-Host "Using Visual Studio: $vsPath"

# vcvarsall.bat uses "x86" for Win32, "x64" for x64, "arm64" for ARM64
$vcvarsArch = switch ($Platform) {
    "Win32" { "x86" }
    "x64"   { "x64" }
    "ARM64" { "arm64" }
}

# Import MSVC environment variables into this PowerShell session
$envScript = "`"$vcvarsall`" $vcvarsArch > NUL 2>&1 && set"
$envLines  = cmd /c $envScript
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        Set-Item -Force "Env:$($Matches[1])" $Matches[2]
    }
}

# -------------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------------
$winInclude  = "$ScriptDir\aarch64\win_include"          # ffi.h, fficonfig.h
$libInclude  = "$RepoRoot\include"                        # ffi_common.h, tramp.h
$srcX86      = "$RepoRoot\src\x86"                        # ffitarget.h (x64/Win32 target)
$srcAArch64  = "$RepoRoot\src\aarch64"
$testSrcDir  = "$RepoRoot\testsuite\libffi.call"          # ffitest.h + tests

$targetSrcDir = if ($Platform -eq "ARM64") { $srcAArch64 } else { $srcX86 }

# Library output directories differ by platform:
#   Win32  -> aarch64\{Config}\          (no platform subdirectory)
#   x64    -> aarch64\x64\{Config}\
#   ARM64  -> aarch64\ARM64\{Config}\
$libFile = switch ($Platform) {
    "Win32" { "$ScriptDir\aarch64\$Config\libffi_static.lib" }
    "x64"   { "$ScriptDir\aarch64\x64\$Config\libffi_static.lib" }
    "ARM64" { "$ScriptDir\aarch64\ARM64\$Config\libffi_static.lib" }
}
if (-not (Test-Path $libFile)) {
    Write-Error "Library not found: $libFile"
    Write-Error "Build the library first with one of: MT, MTd, MD, MDd"
    Write-Error "Open aarch64\libffi_static.sln in Visual Studio"
    exit 1
}

$outDir = "$ScriptDir\test_output\$Platform\$Config"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null  # for .exe / .obj output

# -------------------------------------------------------------------------
# MSVC compiler flags (from testsuite/libffi.call/call.exp)
# -------------------------------------------------------------------------
$clFlags = @(
    "/nologo",
    "/W3",
    "/EHsc",
    "/Zi",
    "/wd4005"   # macro redefinition
)

# Match CRT linkage to the library configuration
switch ($Config) {
    "MT"  { $clFlags += "/MT" }
    "MTd" { $clFlags += "/MTd" }
    "MD"  { $clFlags += "/MD" }
    "MDd" { $clFlags += "/MDd" }
}

# -------------------------------------------------------------------------
# Collect and filter test files
# -------------------------------------------------------------------------
$testFiles = Get-ChildItem "$testSrcDir\*.c" | Sort-Object Name
if ($Filter) {
    $testFiles = $testFiles | Where-Object { $_.BaseName -like "*$Filter*" }
    if (-not $testFiles) {
        Write-Error "No tests match filter: $Filter"
        exit 1
    }
}

# -------------------------------------------------------------------------
# Compile and run each test
# -------------------------------------------------------------------------
$passed  = 0
$failed  = 0
$errored = 0

Write-Host ""
Write-Host "Platform: $Platform  Config: $Config  Library: $libFile"
Write-Host ("=" * 70)

foreach ($testFile in $testFiles) {
    $name   = $testFile.BaseName
    $outExe = "$outDir\$name.exe"
    $outObj = "$outDir\$name.obj"

    Write-Host ""
    Write-Host "--- $name ---" -ForegroundColor Cyan

    # Compile
    $clArgs = $clFlags + @(
        "/I$winInclude",
        "/I$libInclude",
        "/I$targetSrcDir",
        "/I$testSrcDir",
        "/Fo$outObj",
        "/Fe$outExe",
        "$testFile",
        "$libFile",
        "/link", "/LTCG"
    )

    & cl.exe @clArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR  $name" -ForegroundColor Yellow
        $errored++
        continue
    }

    # Run
    & $outExe
    if ($LASTEXITCODE -eq 0) {
        Write-Host "PASS   $name" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "FAIL   $name  (exit $LASTEXITCODE)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ("=" * 70)
Write-Host "Results: $passed passed, $failed failed, $errored compile errors  (of $($testFiles.Count) tests)"

exit ($failed + $errored)
