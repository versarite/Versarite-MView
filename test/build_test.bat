@echo off
rem Builds and runs the MView tests (TestNavigation.lpr, TestExif.lpr,
rem TestMouse.lpr, TestSort.lpr, TestFilters.lpr, TestGif.lpi).
rem Double-click this file, or run it from a command prompt.
rem It uses the Free Pascal compiler that comes with Lazarus, so fpc
rem does not need to be on the PATH.

setlocal
set FPC=C:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe
rem TestGif needs BGRABitmap, so it is built by lazbuild (packages).
set LAZBUILD=C:\lazarus\lazbuild.exe

rem Work in the folder this .bat file is in (test\).
cd /d "%~dp0"

if not exist "%FPC%" (
  echo Free Pascal compiler not found at:
  echo   %FPC%
  echo Edit the FPC line at the top of this file to point to your fpc.exe.
  pause
  exit /b 1
)

echo Compiling TestNavigation.lpr ...
"%FPC%" -FU. -Fu..\source\core -Fu..\source\imaging -Fu..\source\utility TestNavigation.lpr
if errorlevel 1 goto failed

echo Compiling TestExif.lpr ...
"%FPC%" -FU. -Fu..\source\imaging TestExif.lpr
if errorlevel 1 goto failed

echo Compiling TestMouse.lpr ...
"%FPC%" -FU. -Fu..\source\mouse -Fu..\source\core TestMouse.lpr
if errorlevel 1 goto failed

echo Compiling TestSort.lpr ...
"%FPC%" -FU. -Fu..\source\utility -Fu..\source\config TestSort.lpr
if errorlevel 1 goto failed

echo Compiling TestFilters.lpr ...
"%FPC%" -FU. -Fu..\source\utility TestFilters.lpr
if errorlevel 1 goto failed

set GIFTEST=0
if exist "%LAZBUILD%" (
  echo Building TestGif.lpi with lazbuild ...
  "%LAZBUILD%" -q TestGif.lpi
  if errorlevel 1 goto failed
  set GIFTEST=1
) else (
  echo lazbuild not found at %LAZBUILD%: TestGif skipped.
  echo Edit the LAZBUILD line at the top of this file, or build TestGif.lpi in Lazarus.
)

echo.
TestNavigation.exe
echo.
TestExif.exe
echo.
TestMouse.exe
echo.
TestSort.exe
echo.
TestFilters.exe
echo.
if "%GIFTEST%"=="1" TestGif.exe
echo.
pause
exit /b 0

:failed
echo.
echo Compilation failed, see the messages above.
pause
exit /b 1
