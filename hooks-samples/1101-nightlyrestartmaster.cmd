@echo off

:setup
	setlocal

:nightlyrestartmaster
	rem
	rem Every night at 01:00, boot the MASTER image (image.vhd) directly so
	rem it can pick up Windows/AV/domain updates, then roll back to a fresh
	rem snapshot on top of the updated master at 05:00.
	rem
	rem IMPORTANT: booting image.vhd changes the parent of intermediate.vhd
	rem and snapshot.vhd, which invalidates them. So BEFORE booting the
	rem master, a "rollback_base" is scheduled with the Image-O-Tron service:
	rem at the master's next restart, WinPE throws away the old snapshot and
	rem intermediate and builds a new snapshot on the updated master.
	rem Any intermediate is discarded every night with this hook.
	rem
	rem Steps written to %systemdrive%\srs\nightlyrestartmaster.cmd:
	rem   1. srsmgr /schedule rollback_base   (pending action, kept on the
	rem      Physical Drive, so it survives booting the master)
	rem   2. bcdedit /bootsequence {master}   (boot image.vhd once)
	rem   3. restart
	rem The master boot entry is the one whose device is image.vhd (bcdboot
	rem names it "Windows 11 (master image)"); found by parsing bcdedit's
	rem English output, as in the original sample.
	rem
	set "_f=%systemdrive%\srs\nightlyrestartmaster.cmd"
	echo Creating %_f%
	> "%_f%"  echo @echo off
	>>"%_f%" echo setlocal enabledelayedexpansion
	>>"%_f%" echo "%systemdrive%\srs\srsmgr.exe" /schedule rollback_base
	>>"%_f%" echo if errorlevel 1 exit /b 1
	>>"%_f%" echo set _master=
	>>"%_f%" echo for /f "tokens=1,2" %%%%a in ('bcdedit /enum osloader /v') do (
	>>"%_f%" echo   if "%%%%a"=="identifier" set _cur=%%%%b
	>>"%_f%" echo   if "%%%%a"=="device" set _d=%%%%b
	>>"%_f%" echo   if "%%%%a"=="device" if not "!_d:image.vhd=!"=="!_d!" set _master=!_cur!
	>>"%_f%" echo )
	>>"%_f%" echo if not defined _master exit /b 1
	>>"%_f%" echo bcdedit /bootsequence %%_master%%
	>>"%_f%" echo shutdown /r /t 60 /c "Nightly maintenance: restarting into the master image in 60 seconds."
	echo Creating the scheduled tasks
	schtasks /Create /RU "NT AUTHORITY\SYSTEM" /SC DAILY /TN "Image-O-Tron nightly master boot" /TR "%_f%" /ST 01:00 /F
	schtasks /Create /RU "NT AUTHORITY\SYSTEM" /SC DAILY /TN "Image-O-Tron nightly master restart" /TR "shutdown /r /t 60" /ST 05:00 /F

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
