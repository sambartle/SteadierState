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
			echo need it ^(e.g. 1110-security^) will be skipped by those hooks.
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
	rem Make the next boot go to "Launch Image-O-Tron 11K" (on-disk WinPE)
	rem
	echo.
	echo Installing the Image-O-Tron service and app...
	if not exist "%_srsdir%\srsmgr.exe" (
		echo ERROR: %_srsdir%\srsmgr.exe is missing.
		goto :badend
	)
	rem The SYSTEM service runs %_srsdir%\srsmgr.exe, so ordinary users must
	rem not be able to change anything in that folder. C:\ lets Authenticated
	rem Users create/modify by default, so replace the inherited ACL first:
	rem SYSTEM + Administrators full, Users read/execute (to run the app).
	rem SIDs, not names, so this works on any display language.
	rem Set the ACL on the FOLDER only, then reset everything inside it to
	rem inherit from the folder. (Applying (OI)(CI) grants to each file with
	rem /T leaves files with an empty, deny-everyone ACL - that locked even
	rem Administrators out of firstrun.cmd and srsmgr.exe.)
	echo Locking down %_srsdir% ...
	icacls "%_srsdir%" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /C /Q
	if errorlevel 1 goto :aclfail
	icacls "%_srsdir%\*" /reset /T /C /Q
	if errorlevel 1 goto :aclfail
	rem sanity check: we must still be able to read our own files
	type "%_srsdir%\srsmgr.exe" >nul 2>&1 || goto :aclfail
	goto :aclok

:aclfail
	echo ERROR: couldn't set permissions on %_srsdir% ^(or they block access^).
	echo Repair with:  takeown /f "%_srsdir%" /r /d y  and  icacls "%_srsdir%" /reset /t
	goto :badend

:aclok
	if not defined _phydrive goto :installsvc
	rem The Physical Drive root normally lets Authenticated Users modify, so
	rem anyone could tamper with the VHD files. Lock it the same way, and
	rem remove the explicit Authenticated Users / Everyone grants on the root.
	echo Locking down %_phydrive%:\ ^(image.vhd, snapshots, settings^) ...
	icacls %_phydrive%:\ /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /C /Q
	icacls %_phydrive%:\ /remove:g *S-1-5-11 *S-1-1-0 /C /Q

:installsvc
	rem installs + starts the SrsMgr service, creates srs.ini (mode=gui)
	rem and makes the next boot go to the on-disk WinPE
	"%_srsdir%\srsmgr.exe" /install
	if errorlevel 1 (
		echo ERROR: srsmgr /install failed.
		goto :badend
	)
	echo Creating Start menu and desktop shortcuts...
	powershell -NoProfile -ExecutionPolicy Bypass -Command "$w=New-Object -ComObject WScript.Shell; foreach($d in @([Environment]::GetFolderPath('CommonDesktopDirectory'),[Environment]::GetFolderPath('CommonPrograms'))){ $s=$w.CreateShortcut((Join-Path $d 'Image-O-Tron 11,000.lnk')); $s.TargetPath='%_srsdir%\srsmgr.exe'; $s.Description='Steadier State rollback manager'; $s.Save() }"

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
	echo boot to the Image-O-Tron boot manager, create snapshot.vhd and
	echo start the protected Windows 11. From then on the boot manager
	echo appears on every boot ^(change this in the Image-O-Tron app^).
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
