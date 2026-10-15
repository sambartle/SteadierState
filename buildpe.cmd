@echo off

:background
	rem ====================================================================
	rem						BUILDPE.CMD
	rem
	rem Function: automates creating the USB stick or ISO used to deploy
	rem	Steadier State to a Windows 11 (UEFI, 64-bit) system.
	rem End product:  a bootable WinPE USB stick and/or ISO.
	rem
	rem Assumes:	Windows ADK for Windows 11 AND the separate
	rem		"Windows PE add-on for the ADK" installed in the default
	rem		location (both are required since ADK 1809).
	rem		Download page:
	rem		https://learn.microsoft.com/windows-hardware/get-started/adk-install
	rem
	rem Windows 11 notes:
	rem	- Windows 11 is 64-bit only and the Windows 11 ADK no longer
	rem	  ships an x86 WinPE, so only amd64 is built.
	rem	- WinPE-WMI and WinPE-SecureStartup are added so manage-bde is
	rem	  available in WinPE (used by cvt2vhd to detect BitLocker).
	rem	- Optionally builds media using the "Windows UEFI CA 2023"
	rem	  signed boot manager (MakeWinPEMedia /bootex) for PCs whose
	rem	  Secure Boot DBX has revoked the 2011 boot manager.
	rem
	echo.
	echo ===============================================================
	echo               B U I L D   U S B / I S O  T O O L
	echo                    (Windows 11 / UEFI edition)
	echo ===============================================================
	echo.
	echo This command file (buildpe.cmd) creates the bootable USB stick
	echo and/or ISO you need to get started with Steadier State, the
	echo free "Windows Rollback" tool for un-doing all changes to a
	echo Windows 11 system in a few minutes.
	echo.
	echo To stop this program, you can type the word "end" as the answer
	echo to any question.  Please type all responses in LOWERCASE!

:setup
	setlocal
	set _arch=amd64
	set "_adkbase=%programfiles(x86)%\Windows Kits\10\Assessment and Deployment Kit"
	set "_pebase=%_adkbase%\Windows Preinstallation Environment"
	set _logdir=%systemroot%\logs\buildpelogs
	set _buildpepath=%temp%\BuildPE
	set _adkcheckcount=0
	set _bootex=
	rem Current ADK + WinPE add-on download links (Windows 11 ADK).
	rem If Microsoft changes these, install manually from the page above.
	set "_adkurl=https://go.microsoft.com/fwlink/?linkid=2289980"
	set "_peurl=https://go.microsoft.com/fwlink/?linkid=2289981"
	if not exist %systemdrive%\srs md %systemdrive%\srs

:admincheck
	whoami /groups | find "S-1-16-12288" >nul
	if %errorlevel%==0 goto :logdir
	echo.
	echo I'm sorry, but you must be running from an elevated command
	echo prompt to run this command file. Right-click Terminal or Command
	echo Prompt, choose "Run as administrator" and accept the UAC prompt.
	goto :badend

:logdir
	rd "%_logdir%" /q /s 2>nul
	md "%_logdir%" 2>nul
	if not exist "%_logdir%" (
		set "_logdir=%temp%\buildpelogs"
		md "%temp%\buildpelogs" 2>nul
	)
	if not exist "%_logdir%" (
		echo.
		echo I can't create a log folder ^(tried %systemroot%\logs and %temp%^).
		goto :badend
	)

:adkcheck
	rem
	rem Both the ADK Deployment Tools and the separate WinPE add-on
	rem are needed.
	rem
	set _adkok=true
	if not exist "%_adkbase%\Deployment Tools\DandISetEnv.bat" set _adkok=false
	if not exist "%_pebase%\copype.cmd" set _adkok=false
	if not exist "%_pebase%\%_arch%\en-us\winpe.wim" set _adkok=false
	if %_adkok%==true (
		echo.
		echo Found Windows ADK and WinPE add-on at "%_adkbase%"
		goto :filessearch
	)
	if %_adkcheckcount%==0 goto :adkmissing
	echo.
	echo We tried to install the Windows ADK and WinPE add-on, but they
	echo still can't be found. Please install them manually from
	echo https://learn.microsoft.com/windows-hardware/get-started/adk-install
	goto :badend

:adkmissing
	echo.
	echo For this to work you MUST have BOTH the Windows ADK (Deployment
	echo Tools feature) AND the Windows PE add-on for the ADK installed in
	echo their default location. One or both were not found.
	echo Would you like me to download and install them now? This can
	echo take 30 minutes or more. Type 'y' and press Enter to install, or
	set /p _adkresp=anything else to stop.
	if '%_adkresp%'=='y' goto :adkinstall
	goto :badend

:adkinstall
	set _adkcheckcount=1
	where curl.exe >nul 2>&1
	if not %errorlevel%==0 (
		echo curl.exe not found; please install the ADK manually.
		goto :badend
	)
	echo.
	echo Downloading ADK setup...
	curl.exe -L --fail -o "%systemdrive%\srs\adksetup.exe" "%_adkurl%"
	if not %errorlevel%==0 goto :adkdownloadfail
	echo Downloading WinPE add-on setup...
	curl.exe -L --fail -o "%systemdrive%\srs\adkwinpesetup.exe" "%_peurl%"
	if not %errorlevel%==0 goto :adkdownloadfail
	echo.
	echo Installing ADK Deployment Tools (quiet). Please wait...
	start /wait "" "%systemdrive%\srs\adksetup.exe" /features OptionId.DeploymentTools /ceip off /norestart /q
	echo Installing WinPE add-on (quiet). Please wait...
	start /wait "" "%systemdrive%\srs\adkwinpesetup.exe" /features OptionId.WindowsPreinstallationEnvironment /ceip off /norestart /q
	goto :adkcheck

:adkdownloadfail
	echo.
	echo Download failed. Please install the ADK and WinPE add-on
	echo manually from
	echo https://learn.microsoft.com/windows-hardware/get-started/adk-install
	goto :badend

:filessearch
	rem
	rem The Steadier State files should sit beside this script.
	rem
	set "_srspath=%~dp0"
	if "%_srspath:~-1%"=="\" set "_srspath=%_srspath:~0,-1%"
	goto :filescheck

:filesquestion
	echo.
	echo ===============================================================
	echo Where are the Steadier State files?
	echo.
	echo Please enter the folder containing cvt2vhd.cmd, firstrun.cmd,
	echo listvolume.txt, prepnewpc.cmd, srsmgr.exe and startnethd.cmd,
	echo or type 'end' to exit.
	set /p _srspath=Folder:
	if /i "%_srspath%"=="end" goto :end

:filescheck
	echo.
	echo Checking for the files in folder "%_srspath%"...
	for %%f in (cvt2vhd.cmd firstrun.cmd listvolume.txt prepnewpc.cmd restore2disk.cmd srsmgr.exe startnethd.cmd hooks hooks-samples background\usb.jpg background\disk.jpg) do (
		if not exist "%_srspath%\%%f" (
			echo.
			echo -------- ERROR -----------
			echo %%f not found in %_srspath%.
			goto :filesquestion
		)
	)

:usbquestion
	echo.
	echo ===============================================================
	echo Do you want to prepare a USB stick?
	echo.
	echo     REMINDER: I'M GOING TO WIPE THAT DEVICE CLEAN!!!
	echo.
	echo Type "y" to set up a USB stick. Enter anything else to NOT
	set /p _usbresp=create a USB stick, or "end" to end this program.
	if '%_usbresp%'=='end' goto :end
	if not '%_usbresp%'=='y' goto :nousbstick
	echo.
	echo Here is the list of current volumes on your computer.
	for /f "delims={}" %%a in ('diskpart /s "%_srspath%\listvolume.txt"') do (echo %%a)
	echo What is that USB stick's drive letter? Enter just the letter,
	set /p _usbdrive=no colon. Then press Enter.
	if '%_usbdrive%'=='end' goto :end
	if '%_usbdrive%'=='' goto :usbquestion
	set _usbdrive=%_usbdrive:~0,1%
	if /i '%_usbdrive%'=='%systemdrive:~0,1%' (
		echo.
		echo -------- ERROR -----------
		echo %_usbdrive%: is your system drive. Let's try again.
		goto :usbquestion
	)
	if not exist %_usbdrive%:\ (
		echo.
		echo -------- ERROR -----------
		echo There doesn't seem to be a USB stick at %_usbdrive%:. Let's
		echo try again.
		goto :usbquestion
	)
	set _makeusb=true
	echo Found a device at %_usbdrive%:.
	goto :isoquestion

:nousbstick
	set _makeusb=false
	echo Okay, no need to create a bootable USB stick.

:isoquestion
	echo.
	echo ===============================================================
	echo Do you want to prepare an ISO File?
	echo.
	echo An ISO is useful for virtual machines or PCs where USB boot
	set /p _isoresp=is awkward. Type 'y' to create one, anything else to skip.
	if '%_isoresp%'=='end' goto :end
	if not '%_isoresp%'=='y' goto :noiso
	set _makeiso=true
	rem Documents may not exist locally when OneDrive manages it
	set "_isodir=%userprofile%\Documents"
	if not exist "%_isodir%\" md "%_isodir%" 2>nul
	if not exist "%_isodir%\" set "_isodir=%_srspath%"
	set "_isopath=%_isodir%\SrS64Inst-Win11.iso"
	echo Okay, I will create %_isopath%.
	goto :isousbcheck

:noiso
	set _makeiso=false
	echo Okay, I won't create an ISO file.

:isousbcheck
	if not '%_makeiso%%_makeusb%'=='falsefalse' goto :bootexquestion
	echo.
	echo You've selected neither a USB stick nor an ISO file, so there'd
	echo be no point in continuing.
	goto :badend

:bootexquestion
	rem
	rem Does this ADK's MakeWinPEMedia support /bootex (Windows UEFI
	rem CA 2023 signed boot manager)?
	rem
	findstr /i /c:"bootex" "%_pebase%\MakeWinPEMedia.cmd" >nul 2>&1
	if not %errorlevel%==0 (
		echo.
		echo Note: this ADK's MakeWinPEMedia does not support /bootex, so
		echo the media will use the standard 2011-signed boot manager.
		goto :confirm
	)
	echo.
	echo ===============================================================
	echo Secure Boot certificate choice
	echo.
	echo Your ADK can build media with the boot manager signed by the
	echo newer "Windows UEFI CA 2023" certificate. Only choose this if
	echo your target PCs have the 2023 certificate in their Secure Boot
	echo DB (e.g. they have had the BlackLotus / CVE-2023-24932
	echo mitigations applied). On PCs without it, 2023 media will NOT
	echo boot. If unsure, answer 'n'.
	set /p _bootexresp=Use the 2023-signed boot manager? (y/n)
	if '%_bootexresp%'=='end' goto :end
	if '%_bootexresp%'=='y' set _bootex=/bootex

:confirm
	echo.
	echo Now I'm ready to prepare your USB stick and/or ISO.
	echo Confirming, you chose:
	echo.
	echo ADK=%_adkbase%>"%_logdir%\startlog.txt"
	echo Steadier State files=%_srspath%>>"%_logdir%\startlog.txt"
	echo Architecture=amd64>>"%_logdir%\startlog.txt"
	echo Make USB=%_makeusb% %_usbdrive%>>"%_logdir%\startlog.txt"
	echo Make ISO=%_makeiso% %_isopath%>>"%_logdir%\startlog.txt"
	echo Boot manager switch=%_bootex%>>"%_logdir%\startlog.txt"
	type "%_logdir%\startlog.txt"
	echo Log directory=%_logdir%
	echo WinPE workspace=%_buildpepath% (deleted when finished)
	echo.
	echo Please type 'y' and Enter to confirm that you want to do
	set /p _confirmresp=this, or anything else and Enter to stop.
	if not '%_confirmresp%'=='y' goto :badend
	echo.
	echo Buildpe started. This may take about five to fifteen minutes.

:setenv
	echo Setting ADK environment variables>>"%_logdir%\startlog.txt"
	call "%_adkbase%\Deployment Tools\DandISetEnv.bat" >"%_logdir%\01setenv.txt"
	if not defined WinPERoot (
		echo.
		echo =============== ERROR: Setenv attempt failed ==================
		type "%_logdir%\01setenv.txt"
		goto :badend
	)

:prepareenv
	echo.
	echo Cleaning up any mess from previous BUILDPE runs.
	Dism /Cleanup-Mountpoints >"%_logdir%\02prepareenv.txt"
	if not %errorlevel%==0 (
		echo.
		echo ============= ERROR: Dism Cleanup attempt failed ==============
		echo A reboot may clear an incompletely dismounted previous run.
		type "%_logdir%\02prepareenv.txt"
		goto :badend
	)
	if exist "%_buildpepath%" rd "%_buildpepath%" /s /q >>"%_logdir%\02prepareenv.txt" 2>&1
	if '%_makeiso%'=='true' if exist "%_isopath%" del "%_isopath%" >>"%_logdir%\02prepareenv.txt" 2>&1

:copype
	echo.
	echo Creating WinPE workspace
	call copype %_arch% "%_buildpepath%" >"%_logdir%\03copype.txt"
	if not exist "%_buildpepath%\media\sources\boot.wim" (
		echo.
		echo =============== ERROR: CopyPE attempt failed ==================
		type "%_logdir%\03copype.txt"
		goto :badend
	)

:mountwim
	echo.
	echo Mounting boot.wim so the Steadier State files can be added.
	Dism /Mount-Image /ImageFile:"%_buildpepath%\media\sources\boot.wim" /index:1 /MountDir:"%_buildpepath%\mount" >"%_logdir%\04mountwim.txt"
	if not %errorlevel%==0 (
		echo.
		echo ============== ERROR: Dism mount attempt failed ===============
		type "%_logdir%\04mountwim.txt"
		goto :baddism
	)

:addpackages
	rem
	rem WinPE-WMI + WinPE-SecureStartup give us manage-bde in WinPE so
	rem we can detect (and refuse to image) BitLocker-encrypted drives.
	rem
	echo.
	echo Adding WinPE optional components (WMI, SecureStartup)...
	set "_ocs=%WinPERoot%\%_arch%\WinPE_OCs"
	for %%p in (WinPE-WMI WinPE-SecureStartup) do (
		Dism /Add-Package /Image:"%_buildpepath%\mount" /PackagePath:"%_ocs%\%%p.cab" >>"%_logdir%\04aaddpkg.txt"
		if exist "%_ocs%\en-us\%%p_en-us.cab" Dism /Add-Package /Image:"%_buildpepath%\mount" /PackagePath:"%_ocs%\en-us\%%p_en-us.cab" >>"%_logdir%\04aaddpkg.txt"
	)
	echo Optional components step finished (see 04aaddpkg.txt).

:wpebackground
	rem
	rem WinPE (Windows 10/11) shows Windows\System32\winpe.jpg as its
	rem desktop. It is owned by TrustedInstaller, so take ownership in
	rem the mounted image before replacing it. usb.jpg is used for the
	rem stick; disk.jpg rides along in \srs\background and prepnewpc
	rem installs it on the SrS_Tools partition.
	rem
	set "_bg=%_buildpepath%\mount\Windows\System32\winpe.jpg"
	if not exist "%_srspath%\background\usb.jpg" (
		echo No background\usb.jpg found; keeping the default WinPE background.
		goto :srscopy
	)
	echo.
	echo Setting the WinPE desktop background
	if exist "%_bg%" (
		takeown /f "%_bg%" /a >>"%_logdir%\04bbackground.txt" 2>&1
		icacls "%_bg%" /grant *S-1-5-32-544:F >>"%_logdir%\04bbackground.txt" 2>&1
	)
	copy /y "%_srspath%\background\usb.jpg" "%_bg%" >>"%_logdir%\04bbackground.txt" 2>&1
	if errorlevel 1 (
		echo WARNING: could not replace winpe.jpg - see 04bbackground.txt
	) else (
		echo Background set.
	)

:srscopy
	echo.
	echo Copying Steadier State scripts into the image...
	md "%_buildpepath%\mount\srs" >nul 2>&1
	for %%f in (firstrun.cmd listvolume.txt srsmgr.exe) do copy "%_srspath%\%%f" "%_buildpepath%\mount\srs" /y >nul
	for %%f in (cvt2vhd.cmd prepnewpc.cmd restore2disk.cmd startnethd.cmd) do copy "%_srspath%\%%f" "%_buildpepath%\mount" /y >nul
	md "%_buildpepath%\mount\srs\hooks" >nul 2>&1
	copy "%_srspath%\hooks\*.cmd" "%_buildpepath%\mount\srs\hooks" /y >nul
	md "%_buildpepath%\mount\srs\hooks-samples" >nul 2>&1
	copy "%_srspath%\hooks-samples\*.cmd" "%_buildpepath%\mount\srs\hooks-samples" /y >nul
	if exist "%_srspath%\background\disk.jpg" (
		md "%_buildpepath%\mount\srs\background" >nul 2>&1
		copy "%_srspath%\background\disk.jpg" "%_buildpepath%\mount\srs\background\winpe.jpg" /y >nul
	)
	set "_sn=%_buildpepath%\mount\windows\system32\startnet.cmd"
	>>"%_sn%" echo @cd \
	>>"%_sn%" echo @cls
	>>"%_sn%" echo @echo WinPE now booted from USB stick.
	>>"%_sn%" echo @ver
	>>"%_sn%" echo @echo.
	>>"%_sn%" echo @echo   prepnewpc - wipe a disk, install the on-disk WinPE and deploy image.vhd
	>>"%_sn%" echo @echo   cvt2vhd   - capture this PC's Windows 11 drive into image.vhd
	>>"%_sn%" echo @echo   restore2disk - put image.wim/.vhd back on a disk as normal Windows
	>>"%_sn%" echo @echo.
	>>"%_sn%" echo @echo Steadier State originally by Mark Minasi, www.steadierstate.com
	>>"%_sn%" echo @echo Windows 10 port: https://github.com/7heMC/SteadierState
	>>"%_sn%" echo @echo This copy has been updated for Windows 11 / UEFI.
	echo Copied Steadier State files.>>"%_logdir%\startlog.txt"

:unmountwim
	echo.
	echo Unmounting the image and committing changes
	Dism /Unmount-Image /MountDir:"%_buildpepath%\mount" /commit >"%_logdir%\05unmount.txt"
	if not %errorlevel%==0 (
		echo.
		echo ============= ERROR: Dism unmount attempt failed ==============
		type "%_logdir%\05unmount.txt"
		goto :baddism
	)
	echo Successfully copied files and unmounted boot.wim.
	set _madeusb=false
	set _madeiso=false

:makeiso
	rem
	rem Always build an ISO first (to a temp file if none was asked for).
	rem The USB stick is then made from the ISO's contents. This avoids
	rem MakeWinPEMedia /ufd, which fails with 0x80070057 (-2147024809)
	rem on sticks over 32GB because it formats the whole stick as FAT32.
	rem It also means /bootex (2023 boot manager) works for USB too.
	rem
	set "_mediaiso=%_isopath%"
	if not '%_makeiso%'=='true' set "_mediaiso=%_buildpepath%\usbmedia.iso"
	echo.
	echo Creating ISO with MakeWinPEMedia...
	call MakeWinPEMedia /iso /f %_bootex% "%_buildpepath%" "%_mediaiso%" >"%_logdir%\07makeiso.txt"
	if not %errorlevel%==0 (
		echo.
		echo =============== ERROR: MakeWinPEMedia /iso failed ===============
		type "%_logdir%\07makeiso.txt"
		goto :errorcheck
	)
	if '%_makeiso%'=='true' (
		echo Your ISO is in %_isopath%.
		set _madeiso=true
	)

:makeusb
	if not '%_makeusb%'=='true' goto :errorcheck
	echo.
	echo Preparing the USB stick %_usbdrive%: ...
	set _usbdisk=
	for /f %%a in ('powershell -NoProfile -Command "(Get-Partition -DriveLetter %_usbdrive%).DiskNumber"') do set _usbdisk=%%a
	if not defined _usbdisk (
		echo ERROR: couldn't find which disk %_usbdrive%: is on.
		goto :errorcheck
	)
	set _usbbus=
	set _usbboot=
	set _usbsys=
	set _usbmb=
	for /f "tokens=1-4" %%a in ('powershell -NoProfile -Command "$d=Get-Disk -Number %_usbdisk%; '{0} {1} {2} {3}' -f $d.BusType,$d.IsBoot,$d.IsSystem,[int64]($d.Size/1MB)"') do (
		set _usbbus=%%a
		set _usbboot=%%b
		set _usbsys=%%c
		set _usbmb=%%d
	)
	if not defined _usbmb (
		echo ERROR: couldn't read the details of disk %_usbdisk%.
		goto :errorcheck
	)
	echo   %_usbdrive%: is disk %_usbdisk%, bus=%_usbbus%, size=%_usbmb% MB
	if /i "%_usbboot%"=="True" goto :usbrefuse
	if /i "%_usbsys%"=="True" goto :usbrefuse
	if /i "%_usbbus%"=="USB" goto :usbsize
	echo.
	echo WARNING: disk %_usbdisk% is not on the USB bus (%_usbbus%).
	set _usbok=
	set /p _usbok=Type 'y' to wipe it anyway, anything else to skip the USB: 
	if /i not "%_usbok%"=="y" goto :errorcheck

:usbsize
	rem FAT32 (needed for UEFI boot) is limited to 32GB by Windows' format
	set _usbsize=
	if %_usbmb% GTR 32000 set _usbsize=size=32000
	set "_usbdp=%_buildpepath%\usbdisk.txt"
	>"%_usbdp%"  echo select disk %_usbdisk%
	>>"%_usbdp%" echo clean
	>>"%_usbdp%" echo convert mbr
	>>"%_usbdp%" echo create partition primary %_usbsize%
	>>"%_usbdp%" echo format quick fs=fat32 label="WINPE"
	>>"%_usbdp%" echo active
	>>"%_usbdp%" echo assign letter=%_usbdrive%
	>>"%_usbdp%" echo exit
	echo   Wiping and formatting disk %_usbdisk% ^(FAT32, label WINPE^)...
	diskpart /s "%_usbdp%" >"%_logdir%\06makeusb.txt"
	if not %errorlevel%==0 (
		echo.
		echo =============== ERROR: diskpart couldn't prepare the USB ===============
		type "%_logdir%\06makeusb.txt"
		goto :errorcheck
	)
	timeout /t 3 /nobreak >nul
	set _isoltr=
	for /f %%a in ('powershell -NoProfile -Command "(Mount-DiskImage -ImagePath '%_mediaiso%' -PassThru | Get-Volume).DriveLetter"') do set _isoltr=%%a
	if not defined _isoltr (
		echo ERROR: couldn't mount %_mediaiso%.
		goto :errorcheck
	)
	echo   Copying WinPE files from the ISO ^(%_isoltr%:^) to %_usbdrive%: ...
	robocopy %_isoltr%:\ %_usbdrive%:\ /E /R:1 /W:1 /NP /NFL /NDL >>"%_logdir%\06makeusb.txt"
	set _usbcopyrc=%errorlevel%
	powershell -NoProfile -Command "Dismount-DiskImage -ImagePath '%_mediaiso%'" >nul
	if %_usbcopyrc% GEQ 8 (
		echo.
		echo =============== ERROR: copying files to the USB failed ===============
		type "%_logdir%\06makeusb.txt"
		goto :errorcheck
	)
	if not exist %_usbdrive%:\EFI\Boot\bootx64.efi (
		echo ERROR: %_usbdrive%:\EFI\Boot\bootx64.efi missing after the copy.
		goto :errorcheck
	)
	echo USB drive at %_usbdrive%: now ready.
	set _madeusb=true
	goto :errorcheck

:usbrefuse
	echo.
	echo REFUSED: disk %_usbdisk% is this PC's boot/system disk. Not touching it.
	goto :errorcheck

:errorcheck
	if '%_madeiso%%_madeusb%'=='falsefalse' (
		echo Errors were encountered and BuildPE was unable to prepare a
		echo USB or create an ISO. Check %_logdir% for details.
		goto :badend
	)

:goodend
	echo.
	echo BuildPE finished successfully. Cleaning up...>>"%_logdir%\startlog.txt"
	call :cleanup
	echo.
	echo Done. Boot the reference PC from this media and run "cvt2vhd"
	echo to capture it, or boot a target PC and run "prepnewpc" to
	echo deploy. Remember: Secure Boot can stay ON, but BitLocker / Device
	echo Encryption must be OFF on the reference PC (see prepref.cmd).
	goto :end

:baddism
	echo.
	echo Forcing dism to unmount and clean any mount points
	Dism /Unmount-Image /MountDir:"%_buildpepath%\mount" /discard >"%_logdir%\08baddism.txt"
	Dism /Cleanup-Mountpoints >>"%_logdir%\08baddism.txt"

:badend
	echo.
	echo Buildpe failed. Look in %_logdir% for clues about what went
	echo wrong. Cleaning up temporary files...
	call :cleanup
	goto :end

:cleanup
	cd /d "%_logdir%" 2>nul
	if defined _buildpepath if exist "%_buildpepath%\" rd /s /q "%_buildpepath%"
	exit /b

:end
	endlocal
	echo.
	echo Steadier State for Windows 11 - based on
	echo https://github.com/7heMC/SteadierState
	echo Exiting...
	echo.
