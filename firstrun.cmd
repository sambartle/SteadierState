@echo off

:setup
	setlocal
	set "_srsdir=%~dp0"
	if "%_srsdir:~-1%"=="\" set "_srsdir=%_srsdir:~0,-1%"

:admincheck
	whoami /groups | find "S-1-16-12288" >nul
	if %errorlevel%==0 goto :findphynum
	echo.
	echo firstrun.cmd must be run from an elevated (Run as administrator)
	echo command prompt.
	goto :badend

:findphynum
	rem
	rem listvolume.txt is the name of the script to find the volumes
	rem
	echo.
	echo Looking for the Physical Drive Partition
	set _phydrive=
	for /f "tokens=2-4" %%a in ('diskpart /s "%_srsdir%\listvolume.txt"') do (
		if "%%b"=="Physical_Dr" (
			echo.
			echo The Physical Drive Partition has no drive letter. Hooks that
			echo need it (e.g. 1110-security) will be skipped by those hooks.
			goto :bcdtask
		)
		if "%%c"=="Physical_Dr" (
			echo.
			echo The Physical Drive Partition is using %%b:
			set _phydrive=%%b
			goto :bcdtask
		)
	)
	echo.
	echo Can't find the Physical Drive or its drive letter. I can't fix
	echo this so I've got to exit.
	goto :badend

:bcdtask
	rem
	rem Make the next boot go to "Roll Back Windows" (on-disk WinPE)
	rem
	echo.
	echo Changing the boot order for the next reboot
	call "%_srsdir%\bcddefault.cmd"

:runhooks
	echo Attempting to run hooks from %_srsdir%\hooks ...
	set hookinfo=false
	for %%i in ("%_srsdir%\hooks\*.cmd") do (
		set hookinfo=true
		echo Attempting to run hook %%~nxi
		call "%%~fi" %%_phydrive%%
		echo Completed attempt on hook %%~nxi.
	)
	if %hookinfo%==false (
		echo No hooks were found for running.
	) else (
		echo ...done running hooks.
	)

:goodend
	echo.
	echo Everything completed successfully! Please reboot. The PC will
	echo boot to "Roll Back Windows", create snapshot.vhd and reboot into
	echo the protected Windows 11.
	goto :end

:badend
	echo.
	echo Please check the output above and the documentation, which might
	echo help you figure out what went wrong.

:end
	endlocal
	echo.
	echo Steadier State for Windows 11 - based on
	echo https://github.com/7heMC/SteadierState
	echo.
