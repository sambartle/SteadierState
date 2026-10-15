@echo off

:background
	rem ====================================================================
	rem					SETBACKGROUND.CMD
	rem
	rem Run in normal Windows from an ELEVATED prompt. Applies the WinPE
	rem desktop backgrounds in .\background\ to things that already exist,
	rem so you don't have to rebuild or redeploy:
	rem
	rem   1) This PC's on-disk WinPE ("Launch Image-O-Tron 11K", the hidden
	rem      SrS_Tools partition)  <- background\disk.jpg
	rem   2) An existing Steadier State USB stick (patches
	rem      \sources\boot.wim)     <- background\usb.jpg (+ disk.jpg is
	rem      stored inside it for future prepnewpc runs)
	rem
	rem Uses only tools built into Windows 10/11 (diskpart, dism, robocopy,
	rem takeown, icacls). No ADK needed.
	rem ====================================================================
	setlocal enabledelayedexpansion
	set "_bgdir=%~dp0background"
	set "_logdir=%temp%\srs-setbackground"
	md "%_logdir%" 2>nul
	echo.
	echo ===============================================================
	echo   Steadier State - apply WinPE backgrounds
	echo ===============================================================

:admincheck
	whoami /groups | find "S-1-16-12288" >nul
	if %errorlevel%==0 goto :menu
	echo.
	echo Please run this from an elevated (Run as administrator) prompt.
	goto :end

:menu
	echo.
	echo   1  This PC's on-disk WinPE (SrS_Tools partition)   uses disk.jpg
	echo   2  A Steadier State USB stick                       uses usb.jpg
	echo   3  Both
	echo.
	set _choice=
	set /p _choice=Choose 1, 2 or 3 (anything else quits): 
	if "%_choice%"=="1" goto :disk
	if "%_choice%"=="2" goto :usb
	if "%_choice%"=="3" goto :disk
	goto :end

rem ====================================================================
:disk
	echo.
	echo ---- On-disk WinPE ----
	if not exist "%_bgdir%\disk.jpg" (
		echo %_bgdir%\disk.jpg not found.
		goto :diskdone
	)
	>"%_logdir%\lv.txt" echo list volume
	>>"%_logdir%\lv.txt" echo exit
	set _srsvol=
	set _srsltr=
	for /f "tokens=2-4" %%a in ('diskpart /s "%_logdir%\lv.txt"') do (
		if /i "%%b"=="SrS_Tools" set _srsvol=%%a
		if /i "%%c"=="SrS_Tools" (
			set _srsvol=%%a
			set _srsltr=%%b
		)
	)
	if not defined _srsvol (
		echo No volume labelled SrS_Tools found - this PC doesn't look
		echo like a Steadier State deployment.
		goto :diskdone
	)
	set _assigned=false
	if defined _srsltr goto :diskcopy
	rem pick a free letter
	for %%l in (S T U V W R Q P O N M L K J I H G) do (
		if not defined _srsltr if not exist %%l:\ set _srsltr=%%l
	)
	if not defined _srsltr (
		echo No free drive letter available.
		goto :diskdone
	)
	>"%_logdir%\assign.txt" echo select volume %_srsvol%
	>>"%_logdir%\assign.txt" echo assign letter=%_srsltr%
	>>"%_logdir%\assign.txt" echo exit
	diskpart /s "%_logdir%\assign.txt" >"%_logdir%\assign.out"
	if not exist %_srsltr%:\Windows\System32 (
		echo Couldn't mount SrS_Tools as %_srsltr%: - see %_logdir%\assign.out
		goto :diskdone
	)
	set _assigned=true

:diskcopy
	echo SrS_Tools is mounted as %_srsltr%:
	rem keep the background prepnewpc would have installed in sync too
	md %_srsltr%:\srs\background 2>nul
	copy /y "%_bgdir%\disk.jpg" %_srsltr%:\srs\background\winpe.jpg >nul
	rem robocopy /B = backup mode, gets past the TrustedInstaller ACL
	md "%_logdir%\stage" 2>nul
	copy /y "%_bgdir%\disk.jpg" "%_logdir%\stage\winpe.jpg" >nul
	robocopy "%_logdir%\stage" %_srsltr%:\Windows\System32 winpe.jpg /B /IS /IT /R:1 /W:1 >"%_logdir%\robocopy.txt"
	if errorlevel 8 (
		echo FAILED to replace winpe.jpg - see %_logdir%\robocopy.txt
	) else (
		echo On-disk WinPE background updated.
	)
	if "%_assigned%"=="true" (
		>"%_logdir%\remove.txt" echo select volume %_srsvol%
		>>"%_logdir%\remove.txt" echo remove letter=%_srsltr%
		>>"%_logdir%\remove.txt" echo exit
		diskpart /s "%_logdir%\remove.txt" >nul
		echo SrS_Tools hidden again.
	)

:diskdone
	if "%_choice%"=="3" goto :usb
	goto :end

rem ====================================================================
:usb
	echo.
	echo ---- USB stick ----
	if not exist "%_bgdir%\usb.jpg" (
		echo %_bgdir%\usb.jpg not found.
		goto :end
	)
	set _usb=
	for %%l in (D E F G H I J K L M N O P Q R S T U V W Y Z) do (
		if not defined _usb if exist %%l:\sources\boot.wim if exist %%l:\EFI\Boot\bootx64.efi set _usb=%%l
	)
	if defined _usb (
		set _resp=
		set /p _resp=Found WinPE media on !_usb!: - use it? ^(y/n^) 
		if /i not "!_resp!"=="y" set _usb=
	)
	if not defined _usb (
		set /p _usb=Enter the USB stick's drive letter ^(no colon^): 
	)
	set _usb=%_usb:~0,1%
	if not exist %_usb%:\sources\boot.wim (
		echo %_usb%:\sources\boot.wim not found.
		goto :end
	)
	set "_mnt=%_logdir%\mount"
	echo Cleaning up any old mounts...
	dism /Cleanup-Mountpoints >nul 2>&1
	if exist "%_mnt%" rd /s /q "%_mnt%" 2>nul
	md "%_mnt%"
	rem files copied from an ISO are read-only; DISM can't mount those for writing
	attrib -r %_usb%:\sources\boot.wim
	echo Mounting %_usb%:\sources\boot.wim (takes a minute)...
	dism /Mount-Image /ImageFile:%_usb%:\sources\boot.wim /Index:1 /MountDir:"%_mnt%" >"%_logdir%\mount.txt"
	if not %errorlevel%==0 (
		echo DISM mount failed - see %_logdir%\mount.txt
		echo ^(Is the stick write-protected, or is boot.wim read-only?^)
		goto :end
	)
	set "_bg=%_mnt%\Windows\System32\winpe.jpg"
	if exist "%_bg%" (
		takeown /f "%_bg%" /a >"%_logdir%\usbacl.txt" 2>&1
		icacls "%_bg%" /grant *S-1-5-32-544:F >>"%_logdir%\usbacl.txt" 2>&1
	)
	copy /y "%_bgdir%\usb.jpg" "%_bg%" >nul
	set _usbrc=%errorlevel%
	if exist "%_bgdir%\disk.jpg" (
		md "%_mnt%\srs\background" 2>nul
		copy /y "%_bgdir%\disk.jpg" "%_mnt%\srs\background\winpe.jpg" >nul
	)
	if not "%_usbrc%"=="0" (
		echo Couldn't replace winpe.jpg - discarding changes.
		dism /Unmount-Image /MountDir:"%_mnt%" /Discard >nul
		goto :end
	)
	echo Saving boot.wim...
	dism /Unmount-Image /MountDir:"%_mnt%" /Commit >"%_logdir%\unmount.txt"
	if not %errorlevel%==0 (
		echo DISM commit failed - see %_logdir%\unmount.txt
		dism /Unmount-Image /MountDir:"%_mnt%" /Discard >nul 2>&1
		goto :end
	)
	echo USB stick background updated. Eject the stick safely before
	echo unplugging it.

:end
	endlocal
	echo.
