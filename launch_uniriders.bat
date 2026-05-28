@echo off
title UniRiders Launcher
color 0B
cls

:menu
echo ===================================================
echo               UNIRIDERS APP LAUNCHER               
echo       Vavuniya University Student Network          
echo ===================================================
echo.
echo  [1] Open Project in VS Code
echo  [2] Run App on Web (Google Chrome)
echo  [3] Run App on Connected Device/Emulator
echo  [4] Sync and Fetch dependencies (flutter pub get)
echo  [5] Exit
echo.
echo ===================================================
set /p choice="Enter your selection (1-5): "

if "%choice%"=="1" goto code
if "%choice%"=="2" goto chrome
if "%choice%"=="3" goto run
if "%choice%"=="4" goto pubget
if "%choice%"=="5" goto exit

echo.
echo [!] Invalid selection, please try again.
pause
goto menu

:code
echo.
echo [+] Opening UniRiders in VS Code...
cd /d "c:\src\uniriders"
code .
goto exit

:chrome
echo.
echo [+] Compiling and launching UniRiders on Google Chrome...
cd /d "c:\src\uniriders"
flutter run -d chrome
pause
goto menu

:run
echo.
echo [+] Launching UniRiders on your connected emulator or device...
cd /d "c:\src\uniriders"
flutter run
pause
goto menu

:pubget
echo.
echo [+] Running flutter pub get...
cd /d "c:\src\uniriders"
call flutter pub get
echo [+] Dependencies synchronized!
pause
goto menu

:exit
echo.
echo [+] Closing Launcher. Have a great day!
exit
