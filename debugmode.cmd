@echo off

:background
	rem ====================================================================
	rem					DEBUGMODE.CMD   (C:\srs\debugmode.cmd)
	rem
	rem Temporarily stops Steadier State rolling back on every reboot, so
	rem you can install drivers / debug across several reboots inside the
	rem snapshot. Run from an ELEVATED prompt in the deployed Windows.
	rem
	rem   debugmode on      reboots keep your changes (Delta behaviour)
	rem   debugmode off     back to normal; the NEXT reboot rolls back
	rem                     and throws away everything done while "on"
	rem   debugmode keep    back to normal, but MERGE the changes into
	rem                     image.vhd on the next reboot (permanent)
	rem   debugmode         show the current state
	rem ====================================================================
	setlocal

:admincheck
	whoami /groups | find "S-1-16-12288" >nul
	if %errorlevel%==0 goto :args
	echo Please run this from an elevated (Run as administrator) prompt.
	goto :end

:args
	if /i "%~1"=="on" goto :on
	if /i "%~1"=="off" goto :off
	if /i "%~1"=="keep" goto :keep
	goto :status

:on
	schtasks /Change /TN bcddefault /DISABLE >nul
	if not %errorlevel%==0 (
		echo Couldn't disable the bcddefault task. Is this a Steadier State PC?
		goto :end
	)
	rem the task already ran at this boot, so point the default back at
	rem the snapshot we are running from right now
	bcdedit /default {current} >nul
	echo.
	echo DEBUG MODE ON. Reboots now keep your changes in snapshot.vhd.
	echo When you're finished run:
	echo     debugmode off    to throw the changes away, or
	echo     debugmode keep   to make them permanent.
	goto :end

:off
	schtasks /Change /TN bcddefault /ENABLE >nul
	call "%~dp0bcddefault.cmd"
	echo.
	echo DEBUG MODE OFF. The next reboot ROLLS BACK and discards every
	echo change made since the last snapshot.
	goto :end

:keep
	call :findphy
	if not defined _phydrive (
		echo Can't find the Physical Drive letter, so I can't set automerge.
		echo Create \srsdirectives\automerge.txt on it yourself.
		goto :end
	)
	if not exist %_phydrive%:\srsdirectives md %_phydrive%:\srsdirectives
	echo.> %_phydrive%:\srsdirectives\automerge.txt
	schtasks /Change /TN bcddefault /ENABLE >nul
	call "%~dp0bcddefault.cmd"
	echo.
	echo DEBUG MODE OFF. The next reboot MERGES your changes into
	echo image.vhd, so they become the new baseline. This can't be undone.
	goto :end

:status
	schtasks /Query /TN bcddefault /FO LIST | find /i "Status"
	schtasks /Query /TN bcddefault /FO LIST | find /i "Disabled" >nul
	if %errorlevel%==0 (
		echo Debug mode is ON ^(reboots keep changes^).
	) else (
		echo Debug mode is OFF ^(reboots roll back^).
	)
	echo Usage: debugmode on ^| off ^| keep
	goto :end

:findphy
	set _phydrive=
	>"%temp%\srslv.txt" echo list volume
	>>"%temp%\srslv.txt" echo exit
	for /f "tokens=2-4" %%a in ('diskpart /s "%temp%\srslv.txt"') do (
		if "%%c"=="Physical_Dr" set _phydrive=%%b
	)
	exit /b

:end
	endlocal
	echo.
