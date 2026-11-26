@echo off
setlocal enabledelayedexpansion

REM ============================================================
REM ChameleonConsole (CLAP channelstrip) - Multi-Target Build
REM Produces a .clap (+ optional VST3) per target and a proper
REM version-stamped distribution package per target:
REM   linux-x64  -> .tar.gz (two-pass, exec bit forced)
REM   macos-*    -> .zip via tools/zip_app.py (Unix modes)
REM   win64      -> .zip + Inno Setup installer (installer.iss)
REM Assets are staged next to the plugin so the GUI finds them.
REM ============================================================

set "ROOT=%CD%"
set "ORIG_PATH=%PATH%"

if not defined FPC_DIR set "FPC_DIR=C:\fpcupdeluxe\fpc\bin\i386-win32"
if not defined CROSS_BIN_DIR set "CROSS_BIN_DIR=C:\fpcupdeluxe\cross\bin"
if not defined ISCC set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
set "FPC=%FPC_DIR%\fpc.exe"
set "OUT_ROOT=%ROOT%\dist"

set "LIB_NAME=clap_skeleton"
if exist "%ROOT%\NAME" set /p LIB_NAME=< "%ROOT%\NAME"
set "LPR_FILE=%LIB_NAME%.lpr"
set "APP_NAME=ChameleonConsole"

REM --- Version (Assets/version.txt, patch bumps each build) ---
set "MAJOR=1"
set "MINOR=0"
set "PATCH=0"
if exist "%ROOT%\Assets\version.txt" (
    for /f "usebackq tokens=1,2,3 delims=." %%a in ("%ROOT%\Assets\version.txt") do (
        set "MAJOR=%%a"
        set "MINOR=%%b"
        set "PATCH=%%c"
    )
)
if not defined NO_VERSION_BUMP set /a PATCH=%PATCH% + 1
set "DETECTED_VERSION=!MAJOR!.!MINOR!.!PATCH!"
if not defined NO_VERSION_BUMP if not exist "%ROOT%\Assets" mkdir "%ROOT%\Assets"
if not defined NO_VERSION_BUMP echo !MAJOR!.!MINOR!.!PATCH!>"%ROOT%\Assets\version.txt"
echo Build version: !DETECTED_VERSION!

REM --- Clean previous output ---
if exist "%ROOT%\dist" rmdir /s /q "%ROOT%\dist"
del /q "%ROOT%\*.o" "%ROOT%\*.ppu" "%ROOT%\*.dll" "%ROOT%\*.so" "%ROOT%\*.dylib" 2>nul

call :verify_tools
if errorlevel 1 exit /b 1

if /i "%~1"=="--check" (
    echo.
    echo All required tools found - ready to build.
    exit /b 0
)

if not exist "%OUT_ROOT%" mkdir "%OUT_ROOT%"

call :do_target "win64"        "win64"  "x86_64"  ""           ""
call :do_target "linux-x64"    "linux"  "x86_64"  ""           "-XPx86_64-linux-gnu-"
call :do_target "macos-intel"  "darwin" "x86_64"  ""           "-XPx86_64-apple-darwin19-"
call :do_target "macos-aarch64" "darwin" "aarch64" ""          "-XPaarch64-apple-darwin19-"

call :wrap
call :package_all
call :deploy

echo.
echo ==================================================
echo  ALL BUILD ATTEMPTS COMPLETE
echo ==================================================
echo Output root: %OUT_ROOT%
call :print_summary
echo.
if !SUMMARY_FAIL! GTR 0 (
    echo Build finished with !SUMMARY_FAIL! failed target^(s^).
    exit /b 1
)
exit /b 0

REM ============================================================
:do_target
set "T_NAME=%~1"
set "T_OS=%~2"
set "T_CPU=%~3"
set "EXTRA_FLAGS=%~4"
set "XP_PREFIX=%~5"
set "TD=%OUT_ROOT%\%T_NAME%"
if not exist "%TD%" mkdir "%TD%"

echo.
echo ==================================================
echo  Target: %T_NAME%  (%T_OS% %T_CPU%)
echo ==================================================

if "%T_OS%"=="win64" (
    set "CC=%FPC_DIR%\ppcrossx64.exe"
    set "CC_FLAGS=-Twin64 -Px86_64 -O2 -Mdelphi"
) else (
    if "%T_CPU%"=="x86_64" (
        set "CC=%FPC_DIR%\ppcrossx64.exe"
    ) else if "%T_CPU%"=="aarch64" (
        set "CC=%FPC_DIR%\ppcrossa64.exe"
    ) else if "%T_CPU%"=="arm" (
        set "CC=%FPC_DIR%\ppcrossarm.exe"
    ) else (
        set "CC=%FPC_DIR%\ppcross%T_CPU%.exe"
    )
    set "CC_FLAGS=-T%T_OS% -P%T_CPU% -O2 -Mdelphi %XP_PREFIX% %EXTRA_FLAGS%"
    if "%T_OS%"=="darwin" set "PATH=%CROSS_BIN_DIR%\all-apple\bin;%PATH%"
    if "%T_OS%"=="linux" set "PATH=%CROSS_BIN_DIR%\%T_OS%-%T_CPU%;%PATH%"
)

REM --- Stage the ELF dynamic linker for the Windows-hosted cross link ---
if "%T_OS%"=="linux" (
    set "CROSSLIB=%CROSS_BIN_DIR%\..\lib\%T_CPU%-%T_OS%"
    set "DRV=%ROOT:~0,2%"
    if not exist "!DRV!\lib64" mkdir "!DRV!\lib64"
    copy /y "!CROSSLIB!\lib64\ld-linux-x86-64.so.2" "!DRV!\lib64\ld-linux-x86-64.so.2" >nul
)

echo [Lib] Compiling %LPR_FILE%...
pushd "%ROOT%"
if errorlevel 1 goto :target_failed
"%CC%" %CC_FLAGS% -Fu"%ROOT%" -FE"%ROOT%" %LPR_FILE%
if errorlevel 1 (
    echo   ERROR: %T_NAME% library build failed
    popd
    goto :target_failed
)
popd
echo   OK

if "%T_OS%"=="darwin" (
    call :package_clap_bundle "%T_NAME%"
) else (
    call :package_clap_flat "%T_NAME%"
)
if errorlevel 1 goto :target_failed

REM --- Stage assets next to the plugin ---
if "%T_OS%"=="darwin" (
    call :stage_assets "%T_NAME%" bundle
) else (
    call :stage_assets "%T_NAME%" flat
)
if errorlevel 1 goto :target_failed

REM --- README next to the plugin ---
if exist "%ROOT%\README.md" copy /y "%ROOT%\README.md" "%TD%\README.md" >nul

echo [%T_NAME%] complete.
set "RESULT_%T_NAME%=OK"
call :cleanup_linux_loader
goto :eof

:target_failed
echo.
echo *** TARGET %T_NAME% FAILED ***
set "RESULT_%T_NAME%=FAIL"
popd 2>nul
call :cleanup_linux_loader
goto :eof

REM ============================================================
:package_clap_flat
set "TD=%OUT_ROOT%\%~1"
set "SRC="
if exist "%ROOT%\%LIB_NAME%.dll" set "SRC=%ROOT%\%LIB_NAME%.dll"
if exist "%ROOT%\%LIB_NAME%.so" set "SRC=%ROOT%\%LIB_NAME%.so"
if exist "%ROOT%\lib%LIB_NAME%.so" set "SRC=%ROOT%\lib%LIB_NAME%.so"
if not defined SRC (
    echo   ERROR: no library binary produced for %~1
    exit /b 1
)
copy /y "!SRC!" "%TD%\%LIB_NAME%.clap" >nul
if errorlevel 1 ( echo   ERROR: failed to stage .clap & exit /b 1 )
echo   OK: %LIB_NAME%.clap
exit /b 0

:package_clap_bundle
set "TD=%OUT_ROOT%\%~1"
set "SRC="
if exist "%ROOT%\lib%LIB_NAME%.dylib" set "SRC=%ROOT%\lib%LIB_NAME%.dylib"
if exist "%ROOT%\%LIB_NAME%.dylib" set "SRC=%ROOT%\%LIB_NAME%.dylib"
if not defined SRC (
    echo   ERROR: no dylib produced for %~1
    exit /b 1
)
set "BUNDLE=%TD%\%LIB_NAME%.clap"
if exist "!BUNDLE!" rmdir /s /q "!BUNDLE!"
mkdir "!BUNDLE!\Contents\MacOS" 2>nul
mkdir "!BUNDLE!\Contents\Resources" 2>nul
copy /y "!SRC!" "!BUNDLE!\Contents\MacOS\%LIB_NAME%" >nul
echo   OK: %LIB_NAME%.clap bundle
exit /b 0

REM ============================================================
REM :stage_assets - copy Assets next to the plugin
REM %1 = target name, %2 = flat|bundle
REM ============================================================
:stage_assets
set "TD=%OUT_ROOT%\%~1"
if not exist "%ROOT%\Assets" ( echo   WARNING: no Assets folder & exit /b 0 )
if "%~2"=="bundle" (
    set "DEST=%TD%\%LIB_NAME%.clap\Contents\Resources\Assets"
) else (
    set "DEST=%TD%\Assets"
)
if exist "!DEST!" rmdir /s /q "!DEST!"
xcopy /y /e /i "%ROOT%\Assets" "!DEST!" >nul
if errorlevel 1 ( echo   ERROR: failed to stage Assets & exit /b 1 )
echo   OK: Assets staged
exit /b 0

REM ============================================================
REM :package_all - build a distribution package per built target
REM ============================================================
:package_all
for %%T in (win64 linux-x64 macos-intel macos-aarch64) do (
    if "!RESULT_%%T!"=="OK" (
        if "%%T"=="win64" (call :package_target "%%T" "win64") else if "%%T"=="linux-x64" (call :package_target "%%T" "linux") else (call :package_target "%%T" "darwin")
    )
)
exit /b 0

REM ============================================================
REM :package_target - version-stamped distribution package
REM %1 = target name, %2 = OS
REM ============================================================
:package_target
set "T_NAME=%~1"
set "T_OS=%~2"
set "TD=%OUT_ROOT%\%T_NAME%"
set "PKG=%OUT_ROOT%\%APP_NAME%!DETECTED_VERSION!-%T_NAME%"

if "%T_OS%"=="linux" (
    echo [Pkg] Creating Linux .tar.gz...
    pushd "%OUT_ROOT%"
    if errorlevel 1 ( echo   ERROR: pushd failed & exit /b 1 )
    set "TARBALL=mytmp_%T_NAME%.tar"
    tar -cf "!TARBALL!" --exclude="%T_NAME%/%LIB_NAME%.clap" "%T_NAME%"
    if errorlevel 1 ( echo   ERROR: tar packaging failed & popd & exit /b 1 )
    tar -rf "!TARBALL!" --mode='u=rwx,go=rx' "%T_NAME%/%LIB_NAME%.clap"
    if errorlevel 1 ( rm -f "!TARBALL!" & popd & exit /b 1 )
    gzip -f "!TARBALL!"
    if errorlevel 1 ( rm -f "!TARBALL!.gz" & popd & exit /b 1 )
    cp -f "!TARBALL!.gz" "!PKG!.tar.gz"
    if errorlevel 1 ( rm -f "!TARBALL!.gz" & popd & exit /b 1 )
    rm -f "!TARBALL!.gz"
    popd
    echo   OK: %APP_NAME%!DETECTED_VERSION!-%T_NAME%.tar.gz
    exit /b 0
)

if "%T_OS%"=="darwin" (
    echo [Pkg] Creating macOS .zip...
    python "%ROOT%\tools\zip_app.py" "%TD%\%LIB_NAME%.clap" "!PKG!.zip"
    if errorlevel 1 ( echo   ERROR: zip failed & exit /b 1 )
    echo   OK: %APP_NAME%!DETECTED_VERSION!-%T_NAME%.zip
    exit /b 0
)

if "%T_OS%"=="win64" (
    echo [Pkg] Creating Windows .zip...
    python "%ROOT%\tools\zip_dir.py" "%TD%" "!PKG!.zip"
    if errorlevel 1 ( echo   ERROR: zip failed & exit /b 1 )
    echo   OK: %APP_NAME%!DETECTED_VERSION!-%T_NAME%.zip
    if exist "%ISCC%" (
        echo [Pkg] Building Windows installer...
        copy /y "%TD%\%LIB_NAME%.clap" "%ROOT%\%LIB_NAME%.clap" >nul 2>&1
        pushd "%ROOT%\installer"
        if errorlevel 1 ( echo   ERROR: pushd installer failed & exit /b 1 )
        "%ISCC%" /Q /dMyAppVersion="!DETECTED_VERSION!" installer.iss
        if errorlevel 1 ( echo   ERROR: Inno Setup failed & popd & exit /b 1 )
        popd
        if exist "%ROOT%\%APP_NAME%_Setup_!DETECTED_VERSION!.exe" (
            copy /y "%ROOT%\%APP_NAME%_Setup_!DETECTED_VERSION!.exe" "!PKG!-setup.exe" >nul
            del /q "%ROOT%\%APP_NAME%_Setup_!DETECTED_VERSION!.exe" 2>nul
            del /q "%ROOT%\%LIB_NAME%.clap" "%ROOT%\%LIB_NAME%.vst3" 2>nul
            echo   OK: %APP_NAME%!DETECTED_VERSION!-%T_NAME%-setup.exe
        )
    ) else (
        echo   SKIP: Inno Setup not found ^(set ISCC or install Inno Setup 6^)
    )
    exit /b 0
)
exit /b 0

REM ============================================================
REM :wrap - OPTIONAL native VST3 from the CLAP via clap-wrapper
REM ============================================================
:wrap
echo.
echo [Wrap] clap-wrapper (native VST3)...
set "PATH=%ORIG_PATH%"
for /f "delims=" %%G in ('where gcc') do set "NATIVE_CC=%%G"
for /f "delims=" %%G in ('where g++') do set "NATIVE_CXX=%%G"
if not defined CLAP_WRAPPER_DIR set "CLAP_WRAPPER_DIR=%ROOT%\deps\clap-wrapper"
if not defined CLAP_SDK_ROOT set "CLAP_SDK_ROOT=%ROOT%\deps\clap"
if not defined VST3_SDK_ROOT set "VST3_SDK_ROOT=%ROOT%\deps\vst3sdk"
if not exist "%CLAP_WRAPPER_DIR%\CMakeLists.txt" ( echo   SKIP: clap-wrapper not found ^(clone into deps\ or set CLAP_WRAPPER_DIR^) & exit /b 0 )
where cmake >nul 2>&1
if errorlevel 1 ( echo   SKIP: cmake not found & exit /b 0 )

set "WRAP_BUILD=%OUT_ROOT%\wrapper"
if exist "!WRAP_BUILD!" rmdir /s /q "!WRAP_BUILD!"
cmake -B "!WRAP_BUILD!" -S "%CLAP_WRAPPER_DIR%" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-Wno-deprecated-declarations -DCMAKE_C_COMPILER="!NATIVE_CC!" -DCMAKE_CXX_COMPILER="!NATIVE_CXX!" -DCLAP_SDK_ROOT="%CLAP_SDK_ROOT%" -DVST3_SDK_ROOT="%VST3_SDK_ROOT%" -DCLAP_WRAPPER_OUTPUT_NAME="%LIB_NAME%"
if errorlevel 1 ( echo   ERROR: cmake configure failed & exit /b 1 )
cmake --build "!WRAP_BUILD!"
if errorlevel 1 ( echo   ERROR: wrapper build failed & exit /b 1 )

set "VST3_FOUND="
for /f "delims=" %%F in ('dir /b /s "!WRAP_BUILD!\*.vst3" 2^>nul') do set "VST3_FOUND=%%F"
if not defined VST3_FOUND ( echo   WARNING: no .vst3 produced & exit /b 0 )
if not exist "%OUT_ROOT%\win64" mkdir "%OUT_ROOT%\win64"
copy /y "!VST3_FOUND!" "%OUT_ROOT%\win64\%LIB_NAME%.vst3" >nul
if errorlevel 1 ( echo   ERROR: failed to stage VST3 & exit /b 1 )
echo   OK: win64 VST3
copy /y "%OUT_ROOT%\win64\%LIB_NAME%.vst3" "%ROOT%\%LIB_NAME%.vst3" >nul 2>&1
exit /b 0

REM ============================================================
REM :deploy - copy version-stamped packages to Deploy\
REM ============================================================
:deploy
echo.
echo [Deploy] Collecting version-stamped packages...
if not exist "%ROOT%\Deploy" mkdir "%ROOT%\Deploy"
for %%F in ("%OUT_ROOT%\%APP_NAME%!DETECTED_VERSION!-*.tar.gz" "%OUT_ROOT%\%APP_NAME%!DETECTED_VERSION!-*.zip" "%OUT_ROOT%\%APP_NAME%!DETECTED_VERSION!-*-setup.exe") do (
    if exist "%%~F" (
        copy /y "%%~F" "%ROOT%\Deploy\%%~nxF" >nul
        echo   OK: %%~nxF
    )
)
if exist "%OUT_ROOT%\win64\%LIB_NAME%.vst3" (
    copy /y "%OUT_ROOT%\win64\%LIB_NAME%.vst3" "%ROOT%\Deploy\%APP_NAME%!DETECTED_VERSION!-win64.vst3" >nul
    echo   OK: %APP_NAME%!DETECTED_VERSION!-win64.vst3
)
exit /b 0

REM ============================================================
:cleanup_linux_loader
if not "%T_OS%"=="linux" goto :eof
if defined DRV (
    del /q "!DRV!\lib64\ld-linux-x86-64.so.2" 2>nul
    rmdir "!DRV!\lib64" 2>nul
)
goto :eof

:verify_tools
echo [Check] Verifying toolchain...
if not exist "%FPC%" ( echo   ERROR: fpc not found: %FPC% & exit /b 1 )
if not exist "%CROSS_BIN_DIR%" ( echo   ERROR: cross bin dir not found: %CROSS_BIN_DIR% & exit /b 1 )
echo   OK
exit /b 0

:print_summary
echo.
echo ==================================================
echo  BUILD SUMMARY
echo ==================================================
set "SUMMARY_FAIL=0"
for %%T in (win64 linux-x64 macos-intel macos-aarch64) do (
    if "!RESULT_%%T!"=="OK" (
        echo   [OK]   %%T
    ) else if "!RESULT_%%T!"=="FAIL" (
        echo   [FAIL] %%T
        set /a SUMMARY_FAIL+=1
    ) else (
        echo   [SKIP] %%T
    )
)
exit /b 0