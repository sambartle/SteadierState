wpeinit
@echo off

:setup
	setlocal enabledelayedexpansion
	set "_strletters=C D E F G H I J K L M N O P Q R S T U V W Y Z"
	rem
	rem As we're (1) booting WinPE and (2) booting from a hard
	rem disk image rather than a RAMdisk, we can be sure that
	rem the System Reserved partition -- which contains WinPE --
	rem is running as X:.
	rem Use the drive letter %_actdrive% to stop people from running the
	rem script from Windows accidentally
	rem
	set _actdrive=%~d0
	if not '%_actdrive%'=='X:' goto :notwinpe
	%_actdrive%
	cd \
	if not exist %_actdrive%\windows\system32\Dism.exe (
		echo.
		echo Dism missing... please only run this from a system booted
		echo from a Steadier State USB stick/DVD.
		goto :notwinpe
	)
	set "path=%path%;X:\srs"
	echo Booted from local install of Windows PE.
	ver

:bioscheck
	rem
	rem Windows 11 edition: UEFI only.
	rem
	wpeutil UpdateBootInfo >nul
	set _firmware=
	for /f "tokens=1-3" %%a in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul') DO set _firmware=%%c
	if '%_firmware%'=='0x2' (
		echo The system was booted in UEFI mode.
		set _firmware=uefi
		set _winload=\windows\system32\boot\winload.efi
		goto :findphynum
	)
	echo.
	echo This system was not booted in UEFI mode ^(PEFirmwareType=%_firmware%^).
	echo The Windows 11 edition of Steadier State only supports UEFI.
	goto :badend

:findphynum
	rem
	rem listvolume.txt is the name of the script to find the volumes
	rem
	echo.
	echo Looking for the Physical Drive Partition
	for /f "tokens=2-4" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		if "%%b"=="Physical_Dr" (
			set _phynum=%%a
			echo.
			echo The Physical Drive Partition has not yet been assigned a drive
			echo letter. We will find one that's available and assign it.
			goto :findphydrive
		)
		if "%%c"=="Physical_Dr" (
			set _phydrive=%%b:
			echo.
			echo The Physical Drive Partition was automatically assigned a drive
			echo letter and is using %%b:
			goto :findefinum
		)
	)
	echo.
	echo Can't find the Physical Drive or its drive letter.  I can't fix
	echo this so I've got to exit. You can disregard this message if you
	echo don't care about hiding the Physical Drive.
	goto :badend

:findphydrive
	rem
	rem Find an available drive letter for the Physical Drive
	rem
	echo.
	echo Looking for an available drive letter to use for the Physical
	echo Drive Partition
	for /f "tokens=3" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		set _volletter=%%a
		set _volletter=!_volletter:~0,1!
		call set _strletters=%%_strletters:!_volletter! =%%
	)
	for %%a in (%_strletters%) do (
		if not exist %%a:\ (
			echo.
			echo Found %%a: as an available drive letter for the Physical
			echo Drive Partition.
			set _phydrive=%%a
			goto :phymount
		)
	)
	echo.
	echo Error:  I need a drive letter for the Physical Drive Partition,
	echo but could not find one in the following range D-W,Y,Z. I can't
	echo do the job without a free drive letter, so I've got to stop.
	goto :badend

:phymount
	rem
	rem Mount the Physical Drive Partition
	rem
	echo.
	echo Mounting the Physical Drive Partition
	echo select volume %_phynum% >%_actdrive%\mountphy.txt
	echo assign letter=%_phydrive% >>%_actdrive%\mountphy.txt
	echo rescan >>%_actdrive%\mountphy.txt
	echo exit >>%_actdrive%\mountphy.txt
	diskpart /s %_actdrive%\mountphy.txt
	set _mountphyrc=%errorlevel%
	if %_mountphyrc%==0 (
		echo Diskpart successfully mounted the Physical Drive Partition.
		echo using %_phydrive%:
		set _phydrive=%_phydrive%:
		del %_actdrive%\mountphy.txt
		goto :findefinum
	)
	echo.
	echo Diskpart failed to mount the Physical Drive Partition, return
	echo code %_mountphyrc%. It's not really safe to continue so I'm
	echo stopping here.  Look at what Diskpart just reported to see if
	echo there's a clue in there. You may also get a clue from the
	echo diskpart script: %_actdrive%\mountphy.txt.
	goto :badend

:findefinum
	rem
	rem Check for UEFI partition
	rem
	echo.
	echo Looking for the SYSTEM_UEFI partition
	for /f "tokens=2-4" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		if "%%b"=="SYSTEM_UEFI" (
			set _efinum=%%a
			echo.
			echo The SYSTEM_UEFI Partition has not yet been assigned a drive
			echo letter. We will find one that's available and assign it.
			goto :findefidrive
		)
		if "%%c"=="SYSTEM_UEFI" (
			echo The SYSTEM_UEFI Partition is already using %%b:
			set "_bcdstore=/store %%b:\EFI\Microsoft\Boot\BCD"
			set _efidrive=%%b:
			goto :vhdcheck
		)
	)
	set _efinumrc=%errorlevel%
	if '%_efinum%'=='' (
		echo.
		echo Unable to find any mounted volume name "System UEFI"
		goto :badend
	)
	echo.
	echo Can't find the SYSTEM_UEFI drive or its letter.  I can't fix
	echo this so I've got to exit. Please check the error message and
	echo try recreating steadier state from the beginning.
	goto :badend

:findefidrive
	rem
	rem Find an available drive letter for the SYSTEM_UEFI
	rem
	echo.
	echo Looking for an available drive letter to use for the Physical
	echo Drive Partition
	for /f "tokens=3" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		set _volletter=%%a
		set _volletter=!_volletter:~0,1!
		call set _strletters=%%_strletters:!_volletter! =%%
	)
	for %%a in (%_strletters%) do (
		if not exist %%a:\ (
			echo Found %%a: as an available drive letter for the SYSTEM_UEFI
			echo partition.
			set _efidrive=%%a
			goto :efimount
		)
	)
	echo.
	echo Error:  I need a drive letter for the UEFI System Partition,
	echo but could not find one in the following range D-W,Y,Z.
	echo I can't do the job without a free drive letter, so I've got to stop.
	echo.
	goto :badend

:efimount
	rem
	rem Mount the SYSTEM_UEFI Partition
	rem
	echo.
	echo Mounting the SYSTEM_UEFI Partition
	echo select volume %_efinum% >%_actdrive%\mountefi.txt
	echo assign letter=%_efidrive% >>%_actdrive%\mountefi.txt
	echo rescan >>%_actdrive%\mountefi.txt
	echo exit >>%_actdrive%\mountefi.txt
	diskpart /s %_actdrive%\mountefi.txt
	set _mountefirc=%errorlevel%
	if %_mountefirc%==0 (
		echo Diskpart successfully mounted SYSTEM_UEFI Partition.
		echo using %_efidrive%:
		set "_bcdstore=/store %_efidrive%:\EFI\Microsoft\Boot\BCD"
		set _efidrive=%_efidrive%:
		del %_actdrive%\mountefi.txt
		goto :vhdcheck
	)
	echo.
	echo Diskpart failed to create the UEFI System Partition, return code %_mountefirc%.
	echo It's not really safe to continue so I'm stopping here.  Look at what Diskpart
	echo just reported to see if there's a clue in there.  You may also get a clue from
	echo the diskpart script: %_actdrive%\mountefi.txt.
	goto :badend

:vhdcheck
	rem
	rem Everything from here on is done by the Image-O-Tron boot manager
	rem (X:\srs\srsmgr.exe): first snapshot, scheduled actions, the boot
	rem modes (GUI / auto-rollback / auto-merge / straight to Windows) and
	rem the boot entries. Settings: <Physical Drive>\srsdirectives\srs.ini
	rem
	if not exist %_phydrive%\image.vhd goto :noimage
	if not exist X:\srs\srsmgr.exe (
		echo.
		echo X:\srs\srsmgr.exe is missing - can't continue automatically.
		goto :shell
	)

:launch
	echo.
	echo Starting the Image-O-Tron boot manager...
	start "" /wait X:\srs\srsmgr.exe /pe /phy %_phydrive% /store "%_efidrive%\EFI\Microsoft\Boot\BCD"
	set _mgrrc=%errorlevel%
	if "%_mgrrc%"=="0" (
		wpeutil reboot
		goto :end
	)
	if "%_mgrrc%"=="1" (
		wpeutil shutdown
		goto :end
	)

:shell
	echo.
	echo ===============================================================
	echo  Image-O-Tron maintenance prompt
	echo ===============================================================
	echo  Physical Drive: %_phydrive%    EFI partition: %_efidrive%
	echo.
	echo  To reopen the boot manager:
	echo     X:\srs\srsmgr.exe /pe /phy %_phydrive% /store "%_efidrive%\EFI\Microsoft\Boot\BCD"
	echo  Type 'exit' to restart the PC.
	echo.
	goto :end

:noimage
	echo.
	echo image.vhd isn't on %_phydrive% yet. Boot the Steadier State USB
	echo stick and run prepnewpc to deploy an image.vhd made with cvt2vhd.
	goto :shell

:notwinpe
	echo.
	echo startnet.cmd for the on-disk Steadier State WinPE must run from X:.
	goto :end

:badend
	rem
	rem Something failed
	rem
	echo.
	echo Something went wrong and we were not able to prepare this
	echo computer for Steadier State. In its current state the computer
	echo may be unbootable. You should check the logs and see what went
	echo and try again.

:end
	rem
	rem Final message before exiting
	rem
	endlocal
	echo.
	echo This copy of SteadierState has been updated to work with
	echo Windows 11 / UEFI. Based on
	echo https://github.com/7heMC/SteadierState
	echo.
	echo Exiting...
