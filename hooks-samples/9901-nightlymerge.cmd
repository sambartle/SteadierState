@echo off

:setup
	setlocal

:nightlymerge
	rem
	rem Merge the day's changes permanently every night at 03:00 and
	rem restart. "merge" goes into the intermediate if there is one (and
	rem autotarget isn't "base"), otherwise into image.vhd.
	rem Useful for PCs that should keep Windows Updates etc.
	rem
	echo.
	echo Creating a task to merge and restart every night at 03:00
	schtasks /Create /RU "NT AUTHORITY\SYSTEM" /SC DAILY /TN "Image-O-Tron nightly merge" /TR "%systemdrive%\srs\srsmgr.exe /schedule merge /now" /ST 03:00 /F

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
