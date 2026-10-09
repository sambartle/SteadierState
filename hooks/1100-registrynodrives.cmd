@echo off

:setup
	setlocal enabledelayedexpansion
	if not "%~1"=="" set _phydrive=%~1
	if "%_phydrive%"=="" (
		echo No Physical Drive letter was passed; nothing to hide.
		goto :end
	)

:registrynodrives
	rem
	rem Hide the Physical Drive Partition from Explorer with the NoDrives
	rem policy. NoDrives is a bitmask: A=1, B=2, C=4, D=8 ... Z=2^25.
	rem (Fix: the old version wrote decimal numbers as hex DWORDs, which
	rem hid the wrong drive for E: and later.)
	rem
	echo.
	echo Adding Registry value to hide the Physical Drive Partition (%_phydrive%:)
	set "_letters=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	set _bit=-1
	for /l %%i in (0,1,25) do (
		if /i "!_letters:~%%i,1!"=="%_phydrive:~0,1%" set _bit=%%i
	)
	if %_bit%==-1 (
		echo "%_phydrive%" is not a drive letter.
		goto :badend
	)
	set /a "_regvalue=1<<%_bit%"
	reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoDrives /t REG_DWORD /d %_regvalue% /f
	if not %errorlevel%==0 goto :badend

:goodend
	echo.
	echo Hook appears to have completed successfully!
	goto :end

:badend
	echo.
	echo Please check the hook output and documentation, which might help you
	echo figure out what went wrong.

:end
	endlocal
	echo.
