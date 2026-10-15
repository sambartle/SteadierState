@echo off
rem ====================================================================
rem  srs-update.cmd - install a new srsmgr.exe on a deployed PC
rem  Run in Windows from an ELEVATED prompt, with the new srsmgr.exe in
rem  the same folder as this script. It updates both copies:
rem    1. C:\srs\srsmgr.exe              (desktop app + SrsMgr service)
rem    2. <SrS_Tools>\srs\srsmgr.exe     (the WinPE boot screen)
rem  then offers to merge, so the C:\srs copy survives rollbacks.
rem ====================================================================
setlocal
set "NEW=%~dp0srsmgr.exe"
set "LOG=%TEMP%\srs-update"
md "%LOG%" 2>nul

whoami /groups | find "S-1-16-12288" >nul || (echo Please run this from an elevated prompt. & goto :fail)
if not exist "%NEW%" (echo %NEW% not found - put the new srsmgr.exe next to this script. & goto :fail)

echo.
echo === 1/3  Updating C:\srs\srsmgr.exe
sc stop SrsMgr >nul 2>&1
timeout /t 3 /nobreak >nul
copy /y "%NEW%" C:\srs\srsmgr.exe >nul || (echo Couldn't copy to C:\srs. & sc start SrsMgr >nul & goto :fail)
sc start SrsMgr >nul
echo Done.

echo.
echo === 2/3  Updating the WinPE copy on the SrS_Tools partition
>"%LOG%\lv.txt" echo list volume
>>"%LOG%\lv.txt" echo exit
set _vol=
set _ltr=
for /f "tokens=2-4" %%a in ('diskpart /s "%LOG%\lv.txt"') do (
	if /i "%%b"=="SrS_Tools" set _vol=%%a
	if /i "%%c"=="SrS_Tools" (
		set _vol=%%a
		set _ltr=%%b
	)
)
if not defined _vol (echo No SrS_Tools volume found. & goto :fail)
set _assigned=false
if defined _ltr goto :copype
for %%l in (S T U V W R Q P O N M L K J I H) do (
	if not defined _ltr if not exist %%l:\ set _ltr=%%l
)
>"%LOG%\as.txt" echo select volume %_vol%
>>"%LOG%\as.txt" echo assign letter=%_ltr%
>>"%LOG%\as.txt" echo exit
diskpart /s "%LOG%\as.txt" >nul
set _assigned=true

:copype
if not exist %_ltr%:\srs\ (echo Couldn't open SrS_Tools as %_ltr%:. & goto :unmount)
copy /y "%NEW%" %_ltr%:\srs\srsmgr.exe >nul
if errorlevel 1 (
	md "%LOG%\stage" 2>nul
	copy /y "%NEW%" "%LOG%\stage\srsmgr.exe" >nul
	robocopy "%LOG%\stage" %_ltr%:\srs srsmgr.exe /B /IS /IT /R:1 /W:1 >nul
)
fc /b "%NEW%" %_ltr%:\srs\srsmgr.exe >nul && echo Done. || echo WARNING: the WinPE copy didn't update.

:unmount
if "%_assigned%"=="true" (
	>"%LOG%\rm.txt" echo select volume %_vol%
	>>"%LOG%\rm.txt" echo remove letter=%_ltr%
	>>"%LOG%\rm.txt" echo exit
	diskpart /s "%LOG%\rm.txt" >nul
)

echo.
echo === 3/3  Keep the update
echo C:\srs is inside the snapshot, so a rollback would undo step 1.
echo Merging puts it (and anything else changed since the snapshot was
echo made) permanently into the image.
set _m=
set /p _m=Merge on the next restart? (y/n) 
if /i not "%_m%"=="y" goto :done
C:\srs\srsmgr.exe /schedule merge
if errorlevel 1 (echo Scheduling the merge failed. & goto :fail)
echo Merge scheduled for the next restart.

:done
echo.
echo All done. Restart when you're ready.
goto :end

:fail
echo.
echo FAILED - see above.
exit /b 1

:end
endlocal
