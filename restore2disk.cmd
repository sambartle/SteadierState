@echo off

:background
	rem ====================================================================
	rem					RESTORE2DISK.CMD
	rem
	rem The reverse of cvt2vhd + prepnewpc. Run from the Steadier State
	rem USB stick (WinPE). WIPES a disk you choose and puts a Steadier State
	rem master image back onto it as a normal Windows install (no VHD).
	rem Useful for debugging things that might behave differently under
	rem native VHD boot, e.g. video drivers.
	rem
	rem Source (on an EXTERNAL drive, NOT the disk being wiped):
	rem   image.wim  - left behind by cvt2vhd (preferred, quickest), or
	rem   image.vhd  - the master image (it's captured to a wim first)
	rem
	rem Result (GPT): EFI 260MB, MSR 16MB, Windows (rest of the disk).
	rem ====================================================================
	echo ===============================================================
	echo   RESTORE2DISK - put a Steadier State image back on bare metal
	echo ===============================================================
	echo.
	echo This WIPES the disk you choose and installs the image on it as
	echo a normal Windows installation. Steadier State will be gone from
	echo that disk. The source image must be on a DIFFERENT drive.
	pause

:setup
	setlocal enabledelayedexpansion
	set "_strletters=C D E F G H I J K L M N O P Q R S T U V W Y Z"
	set _actdrive=%~d0
	if not '%_actdrive%'=='X:' goto :notwinpe
	X:
	cd \
	wpeutil UpdateBootInfo >nul
	set _firmware=
	for /f "tokens=3" %%a in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul') do set _firmware=%%a
	if not "%_firmware%"=="0x2" (
		echo This PC is not booted in UEFI mode. Boot the stick in UEFI mode.
		goto :badend
	)
	set _vhdattached=false

:sourcequestion
	echo.
	for /f "delims={}" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (echo %%a)
	echo.
	echo Enter the FULL path of image.wim or image.vhd on your external
	echo drive, e.g. E:\images\image.wim  (or 'end' to quit)
	set _src=
	set /p _src=Path: 
	if /i "%_src%"=="end" goto :end
	if "%_src%"=="" goto :sourcequestion
	if not exist "%_src%" (
		echo File not found. Let's try again.
		goto :sourcequestion
	)
	for %%f in ("%_src%") do (
		set "_srcext=%%~xf"
		set "_srcdir=%%~dpf"
		set "_srcdrv=%%~df"
	)
	if "%_srcdir:~-1%"=="\" set "_srcdir=%_srcdir:~0,-1%"
	if /i "%_srcext%"==".wim" goto :diskquestion
	if /i "%_srcext%"==".vhd" goto :diskquestion
	if /i "%_srcext%"==".vhdx" goto :diskquestion
	echo The file must be a .wim or .vhd. Let's try again.
	goto :sourcequestion

:diskquestion
	echo.
	echo ===============================================================
	echo Which disk should I WIPE and restore Windows onto?
	echo.
	>%_actdrive%\listdisk.txt  echo list disk
	>>%_actdrive%\listdisk.txt echo exit
	diskpart /s %_actdrive%\listdisk.txt | find "Disk "
	echo.
	set _disknum=
	set /p _disknum=Enter the disk NUMBER (or 'end' to quit): 
	if /i "%_disknum%"=="end" goto :end
	if "%_disknum%"=="" goto :diskquestion
	set /a _disktest=%_disknum% 2>nul
	if not "%_disktest%"=="%_disknum%" (
		echo That isn't a number. Let's try again.
		goto :diskquestion
	)
	>%_actdrive%\detaildisk.txt  echo select disk %_disknum%
	>>%_actdrive%\detaildisk.txt echo detail disk
	>>%_actdrive%\detaildisk.txt echo exit
	diskpart /s %_actdrive%\detaildisk.txt >%_actdrive%\detaildisk.out
	set _baddisk=false
	find /i "no disk selected" %_actdrive%\detaildisk.out >nul
	if %errorlevel%==0 set _baddisk=true
	find /i "is not valid" %_actdrive%\detaildisk.out >nul
	if %errorlevel%==0 set _baddisk=true
	if %_baddisk%==true (
		echo Disk %_disknum% doesn't exist. Let's try again.
		goto :diskquestion
	)
	find /i " WINPE " %_actdrive%\detaildisk.out >nul
	if %errorlevel%==0 (
		echo -------- REFUSED: disk %_disknum% holds the boot media.
		goto :diskquestion
	)
	for /f "tokens=2,3" %%a in (%_actdrive%\detaildisk.out) do (
		if /i "%%b"=="%_srcdrv:~0,1%" (
			echo -------- REFUSED: disk %_disknum% holds %_srcdrv%, where the source image is.
			goto :diskquestion
		)
	)
	echo.
	type %_actdrive%\detaildisk.out | find /v /i "DiskPart" | find /v "Copyright" | find /v "On computer"
	echo.
	echo ===============================================================
	echo   W A R N I N G :  DISK %_disknum% WILL BE COMPLETELY ERASED
	echo ===============================================================
	echo Type the word "wipe" and press Enter to continue, anything else
	set _wipe=
	set /p _wipe=to stop: 
	if not "%_wipe%"=="wipe" goto :end

:letters
	for /f "tokens=3" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		set _volletter=%%a
		set _volletter=!_volletter:~0,1!
		call set _strletters=%%_strletters:!_volletter! =%%
	)
	set _efi=
	set _win=
	set _vhd=
	for %%a in (%_strletters%) do (
		if not exist %%a:\ (
			if not defined _efi (
				set _efi=%%a
			) else if not defined _win (
				set _win=%%a
			) else if not defined _vhd (
				set _vhd=%%a
			)
		)
	)
	if not defined _vhd (
		echo Not enough free drive letters.
		goto :badend
	)

:prepsource
	rem
	rem A .vhd has to be captured to a .wim first (DISM can't apply a
	rem VHD's volume directly). It's mounted read-only.
	rem
	set "_wim=%_src%"
	if /i "%_srcext%"==".wim" goto :partition
	set "_wim=%_srcdir%\restore-temp.wim"
	if exist "%_wim%" del "%_wim%"
	echo.
	echo Attaching %_src% read-only...
	>%_actdrive%\attach.txt  echo select vdisk file="%_src%"
	>>%_actdrive%\attach.txt echo attach vdisk readonly
	>>%_actdrive%\attach.txt echo exit
	diskpart /s %_actdrive%\attach.txt
	if not %errorlevel%==0 (
		echo Couldn't attach the VHD.
		goto :badend
	)
	set _vhdattached=true
	set _volnum=
	set _vhdltr=
	for /f "tokens=2-4" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		if "%%b"=="Windows_SrS" set _volnum=%%a
		if "%%c"=="Windows_SrS" (
			set _volnum=%%a
			set _vhdltr=%%b
		)
	)
	if not defined _volnum (
		echo Couldn't find the Windows_SrS volume inside the VHD.
		goto :badend
	)
	if not defined _vhdltr (
		>%_actdrive%\vhdltr.txt  echo select volume %_volnum%
		>>%_actdrive%\vhdltr.txt echo assign letter=%_vhd%
		>>%_actdrive%\vhdltr.txt echo exit
		diskpart /s %_actdrive%\vhdltr.txt >nul
		set _vhdltr=%_vhd%
	)
	if not exist %_vhdltr%:\Windows\System32 (
		echo The VHD volume doesn't contain Windows.
		goto :badend
	)
	if not exist "%_srcdir%\scratch" md "%_srcdir%\scratch"
	echo.
	echo Capturing the VHD's Windows to %_wim% (this takes a while)...
	Dism /ScratchDir:"%_srcdir%\scratch" /Capture-Image /ImageFile:"%_wim%" /CaptureDir:%_vhdltr%:\ /Name:"Restore" /Compress:fast
	if not %errorlevel%==0 (
		echo DISM capture failed.
		goto :badend
	)
	call :detachvhd

:partition
	echo.
	echo Partitioning disk %_disknum% ...
	set "_dp=%_actdrive%\restoredisk.txt"
	>"%_dp%"  echo select disk %_disknum%
	>>"%_dp%" echo clean
	>>"%_dp%" echo convert gpt
	>>"%_dp%" echo create partition efi size=260
	>>"%_dp%" echo format quick fs=fat32 label="System"
	>>"%_dp%" echo assign letter=%_efi%
	>>"%_dp%" echo create partition msr size=16
	>>"%_dp%" echo create partition primary
	>>"%_dp%" echo format quick fs=ntfs label="Windows"
	>>"%_dp%" echo assign letter=%_win%
	>>"%_dp%" echo exit
	diskpart /s "%_dp%"
	if not %errorlevel%==0 (
		echo Diskpart failed.
		goto :badend
	)

:apply
	echo.
	echo Applying the image to %_win%: ...
	if not exist "%_srcdir%\scratch" md "%_srcdir%\scratch"
	Dism /ScratchDir:"%_srcdir%\scratch" /Apply-Image /ImageFile:"%_wim%" /Index:1 /ApplyDir:%_win%:\
	if not %errorlevel%==0 (
		echo DISM apply failed.
		goto :badend
	)

:cleanup
	rem
	rem Remove Steadier State leftovers that matter on a normal install:
	rem the NoDrives policy (could hide a drive) and the C:\srs folder.
	rem The bcddefault scheduled task (only present if firstrun ran in
	rem this image) is harmless: it looks for "Roll Back Windows", finds
	rem nothing and does nothing. Delete it after boot if you like.
	rem
	reg load HKLM\SRS_RST %_win%:\Windows\System32\config\SOFTWARE >nul 2>&1
	if %errorlevel%==0 (
		reg delete "HKLM\SRS_RST\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoDrives /f >nul 2>&1
		reg unload HKLM\SRS_RST >nul 2>&1
	)
	if exist %_win%:\srs rd /s /q %_win%:\srs

:boot
	echo.
	echo Writing UEFI boot files...
	bcdboot %_win%:\Windows /s %_efi%: /f UEFI
	if not %errorlevel%==0 (
		echo BCDBoot failed.
		goto :badend
	)
	if /i not "%_srcext%"==".wim" if exist "%_wim%" del "%_wim%"

:goodend
	echo.
	echo ===============================================================
	echo RESTORE COMPLETE
	echo ===============================================================
	echo Remove the USB stick and reboot. Windows now runs directly from
	echo disk %_disknum% (no VHD). If the image was sysprepped it will go
	echo through OOBE first.
	echo After boot you can optionally run (elevated):
	echo     schtasks /Delete /TN bcddefault /F
	goto :end

:detachvhd
	if not "%_vhdattached%"=="true" exit /b
	>%_actdrive%\detach.txt  echo select vdisk file="%_src%"
	>>%_actdrive%\detach.txt echo detach vdisk
	>>%_actdrive%\detach.txt echo exit
	diskpart /s %_actdrive%\detach.txt >nul
	set _vhdattached=false
	exit /b

:notwinpe
	echo This only runs from the Steadier State WinPE USB stick.
	goto :end

:badend
	call :detachvhd
	echo.
	echo Restore failed - see the messages above.

:end
	endlocal
	echo.
