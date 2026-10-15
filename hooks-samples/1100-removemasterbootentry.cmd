@echo off

:setup
	setlocal enabledelayedexpansion

:dropmasterentry
	rem
	rem Remove the boot menu entry that boots image.vhd directly (the
	rem "master image" entry bcdboot created). Users then only see the
	rem snapshot entry and "Roll Back Windows".
	rem
	rem Windows 11 change: the old sample matched the text "Windows 10",
	rem which no longer matches on Windows 11 and would also have matched
	rem the snapshot entry. We now match the entry whose device is
	rem image.vhd instead.
	rem
	rem Do NOT combine this with
	rem the 1101-nightlyrestartmaster sample, which needs the master entry.
	rem
	echo Dropping the image.vhd (master image) boot entry.
	echo.
	for /f "delims=" %%a in ('bcdedit /enum /v') do (
		for /f "tokens=1,2" %%b in ("%%a") do (
			if "%%b"=="identifier" (
				set guid=%%c
				bcdedit /enum !guid! /v | find /i "image.vhd" >nul
				if !errorlevel!==0 (
					bcdedit /delete !guid!
					echo Master image boot entry !guid! has been dropped.
				)
			)
		)
	)

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
