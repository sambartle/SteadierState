@echo off

:setup
	setlocal

:security
	rem
	rem Set permissions on the srs folder for tighter security and
	rem the _phydrive\srsdirectives folder. If the _phydrive\srsdirectives
	rem folder does not exist then we will create it before attempting to set
	rem permissions.
	rem
	rem This hook expects the first param passed to be the _phydrive for
	rem install.
	rem
	rem First set set a local variable to hold the drive letter passed
	set _phydrivepassed=%~1
	if "%_phydrivepassed%"=="" set _phydrivepassed=%_phydrive%
	echo.
	echo Attempting to set some security on %systemdrive%\srs and %_phydrivepassed%:\srsdirectives.
	rem SIDs, not names, so this works on any display language:
	rem   S-1-5-18 SYSTEM, S-1-5-32-544 Administrators, S-1-5-32-545 Users
	rem C:\srs: Users keep read/execute so anyone can run the Image-O-Tron app
	rem (firstrun already set this before installing the service; re-applied
	rem here in case the hook is run on its own).
	icacls %systemdrive%\srs /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /T /C /Q
	echo.
	if "%_phydrivepassed%"=="" goto :nophy
	if not exist %_phydrivepassed%:\srsdirectives md %_phydrivepassed%:\srsdirectives
	if not exist %_phydrivepassed%:\srsdirectives goto :nodir
	rem srsdirectives (settings, logs): SYSTEM + Administrators only. The
	rem SrsMgr service (SYSTEM) does the work for ordinary users.
	icacls %_phydrivepassed%:\srsdirectives /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /T /C /Q
	goto :goodend

:nophy
	echo No Physical Drive letter available; skipping srsdirectives.
	goto :goodend

:nodir
	echo The %_phydrivepassed%:\srsdirectives folder doesn't exist and couldn't be created.
	goto :badend

:goodend
	rem
	rem Success
	rem
	echo.
	echo Hook appears to have completed successfully!
	goto :end

:badend
	rem
	rem Something failed
	rem
	echo.
	echo Please check the hook output and documentation, which might help you
	echo figure out what went wrong.

:end
	rem
	rem Final message before exiting hook
	rem
	endlocal
	echo.
