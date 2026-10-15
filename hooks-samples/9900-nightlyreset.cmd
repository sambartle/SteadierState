@echo off

:setup
	setlocal

:nightlyreset
	rem
	rem Roll the PC back every night at 01:00, whatever the boot mode.
	rem Uses the Image-O-Tron service: "rollback" goes to the intermediate
	rem if there is one (and autotarget isn't "base"), otherwise to the base.
	rem Nightly restarts also help keep the domain relationship and Windows
	rem Update healthy.
	rem
	echo.
	echo Creating a task to roll back and restart every night at 01:00
	schtasks /Create /RU "NT AUTHORITY\SYSTEM" /SC DAILY /TN "Image-O-Tron nightly rollback" /TR "%systemdrive%\srs\srsmgr.exe /schedule rollback /now" /ST 01:00 /F

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
