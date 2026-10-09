@echo off

:background
	echo ===============================================================
	echo How and Why To Use CVT2VHD in Steadier State (Windows 11)
	echo ===============================================================
	echo.
	echo CVT2VHD captures this PC's Windows 11 drive and rebuilds it as
	echo a file named image.vhd on external storage. PREPNEWPC then
	echo deploys that image.vhd to target PCs.
	echo.
	echo Before running this, on the reference PC you should have:
	echo   - run prepref.cmd (turns OFF BitLocker/Device Encryption,
	echo     hibernation and checks the edition), and
	echo   - optionally run Sysprep /generalize /oobe /shutdown.
	echo.
	echo Connect a large external or network drive to hold the image.
	pause

:setup
	setlocal enabledelayedexpansion
	set "_strletters=C D E F G H I J K L M N O P Q R S T U V W Y Z"
	set _actdrive=%~d0
	if not '%_actdrive%'=='X:' goto :notwinpe
	%_actdrive%
	cd \
	if not exist %_actdrive%\windows\system32\Dism.exe (
		echo.
		echo Dism missing... please only run this from a system booted from
		echo a Steadier State USB stick/ISO.
		goto :notwinpe
	)
	echo.
	echo Here is the list of current volumes on your computer.
	echo.
	for /f "delims={}" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (echo %%a)

:imgdrivequestion
	echo ===============================================================
	echo What drive will be imaged?
	echo.
	echo Enter the local drive holding the Windows folder you want to
	echo capture, including the colon (for example C:). Note WinPE may
	echo have given it a different letter than Windows does. 'end' quits.
	set _imgdrive=
	set /p _imgdrive=Drive:
	if '%_imgdrive%'=='end' goto :end
	if '%_imgdrive%'=='' goto :imgdrivequestion
	set _imgdrive=%_imgdrive:~0,2%
	if not exist %_imgdrive%\ (
		echo.
		echo Drive %_imgdrive% does not seem to exist, or it is locked by
		echo BitLocker. Let's try again.
		goto :imgdrivequestion
	)

:bitlockercheck
	rem
	rem Windows 11 24H2+ turns on Device Encryption automatically on many
	rem PCs. A BitLocker-protected volume can't be captured usefully, and
	rem native VHD boot does not support BitLocker on the host or VHD.
	rem
	where manage-bde.exe >nul 2>&1
	if not %errorlevel%==0 (
		echo.
		echo Note: manage-bde is not in this WinPE, so I can't check
		echo BitLocker status. Make sure BitLocker is fully OFF.
		goto :windowscheck
	)
	manage-bde -status %_imgdrive% >%_actdrive%\bde.txt 2>&1
	findstr /i /c:"Fully Decrypted" /c:"Fully decrypted" %_actdrive%\bde.txt >nul
	if %errorlevel%==0 goto :windowscheck
	findstr /i /c:"BitLocker Drive Encryption is not" %_actdrive%\bde.txt >nul
	if %errorlevel%==0 goto :windowscheck
	echo.
	echo -------- STOP -----------
	echo %_imgdrive% is (or may be) BitLocker encrypted:
	type %_actdrive%\bde.txt | findstr /i /c:"Conversion Status" /c:"Lock Status" /c:"Percentage" /c:"Protection Status"
	echo.
	echo Boot back into Windows, run prepref.cmd (or "manage-bde -off C:")
	echo and wait until it reports Fully Decrypted, then try again.
	goto :badend

:windowscheck
	if not exist %_imgdrive%\Windows\System32\config\SOFTWARE (
		echo.
		echo %_imgdrive% does not contain a Windows installation.
		goto :imgdrivequestion
	)
	set _edition=
	set _build=
	set _dispver=
	reg load HKLM\SRS_OFFSOFT %_imgdrive%\Windows\System32\config\SOFTWARE >nul 2>&1
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SRS_OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v EditionID 2^>nul ^| find "EditionID"') do set _edition=%%b
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SRS_OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild 2^>nul ^| find "CurrentBuild"') do set _build=%%b
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SRS_OFFSOFT\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul ^| find "DisplayVersion"') do set _dispver=%%b
	reg unload HKLM\SRS_OFFSOFT >nul 2>&1
	echo.
	echo Found Windows: edition=%_edition% build=%_build% version=%_dispver%
	if '%_build%'=='' goto :sysprepcheck
	if %_build% LSS 22000 (
		echo WARNING: build %_build% is not Windows 11. This version of
		echo Steadier State is only tested with Windows 11.
	)
	if /i '%_edition%'=='Core' goto :homeedition
	if /i '%_edition%'=='CoreSingleLanguage' goto :homeedition
	goto :sysprepcheck

:homeedition
	echo.
	echo -------- STOP -----------
	echo This is Windows 11 Home (%_edition%). Native boot from VHD is
	echo only supported on Pro, Enterprise and Education editions.
	goto :badend

:sysprepcheck
	set _imagestate=
	if exist %_imgdrive%\Windows\Setup\State\State.ini (
		for /f "tokens=2 delims==" %%a in ('find /i "ImageState" %_imgdrive%\Windows\Setup\State\State.ini') do set _imagestate=%%a
	)
	echo Image state: %_imagestate%
	if /i not '%_imagestate%'=='IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' (
		echo.
		echo Note: this Windows install has NOT been generalized with
		echo Sysprep. That's fine if you only deploy it back to this same
		echo PC, but for other PCs run Sysprep first (see the Sysprep folder).
	)

:extdrivequestion
	echo.
	echo ===============================================================
	echo Where will the image be stored?
	echo.
	echo Enter the drive and folder for image.vhd, for example E: or
	echo E:\images.
	set _extdrive=
	set /p _extdrive=What is your response?
	if '%_extdrive%'=='end' goto :end
	if '%_extdrive%'=='' goto :extdrivequestion
	if "%_extdrive:~-1%"=="\" set "_extdrive=%_extdrive:~0,-1%"
	set _extdriveletter=%_extdrive:~0,2%
	if not exist %_extdriveletter%\ (
		echo Drive %_extdriveletter% does not seem to exist. Let's try again.
		goto :extdrivequestion
	)
	if /i '%_extdriveletter%'=='%_imgdrive%' (
		echo You can't store the image on the drive being imaged.
		goto :extdrivequestion
	)
	if not exist "%_extdrive%\" md "%_extdrive%"
	if exist "%_extdrive%\image.vhd" (
		echo %_extdrive%\image.vhd already exists. Please enter a
		echo different location.
		goto :extdrivequestion
	)
	if not exist "%_extdrive%\scratch" md "%_extdrive%\scratch"

:vhdsizequestion
	echo.
	echo ===============================================================
	echo What is the maximum size of the vhd?
	echo.
	echo Enter the maximum VHD size in GB. Windows 11 needs at least 64GB;
	echo 100-128 is a sensible choice. The target PC's disk needs about
	echo 2.5x this size free, because native-boot VHDs expand to full size.
	set _vhdsize=
	set /p _vhdsize=Please enter just the number.
	if '%_vhdsize%'=='end' goto :end
	set /a _vhdtest=%_vhdsize% 2>nul
	if not '%_vhdtest%'=='%_vhdsize%' goto :vhdsizequestion
	if %_vhdsize% LSS 64 (
		echo Windows 11 needs at least 64GB. Let's try again.
		goto :vhdsizequestion
	)
	if %_vhdsize% GTR 2000 (
		echo The VHD format is limited to about 2TB. Let's try again.
		goto :vhdsizequestion
	)
	set /a _sizereq=(%_vhdsize%*2)+(%_vhdsize%/2)
	set /a _vhdmb=%_vhdsize%*1024
	echo You selected %_vhdsize% GB, so target disks need at least %_sizereq% GB.

:findvhddrive
	for /f "tokens=3" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		set _volletter=%%a
		set _volletter=!_volletter:~0,1!
		call set _strletters=%%_strletters:!_volletter! =%%
	)
	for %%a in (%_strletters%) do (
		if not exist %%a:\ (
			set _vhddrive=%%a
			goto :confirm
		)
	)
	echo.
	echo Error: I need a free drive letter for mounting the vhd but could
	echo not find one in the range C-W,Y,Z.
	goto :badend

:confirm
	echo.
	echo ================== Convert PC to VHD Routine ==================
	echo.
	echo Confirming, you chose:
	echo	Drive to convert to VHD=%_imgdrive% (%_edition% %_dispver%)
	echo	Drive/folder to store the image/VHD=%_extdrive%
	echo	Maximum "image.vhd" size=%_vhdsize%GB
	echo I will use drive %_vhddrive%: to mount the vhd.
	echo.
	set _confirm=
	set /p _confirm=Type 'y' and Enter to continue. Anything else to cancel.
	if not '%_confirm%'=='y' goto :end

:capturewim
	echo.
	echo Capturing %_imgdrive% to %_extdrive%\image.wim ...
	Dism /ScratchDir:"%_extdrive%\scratch" /Capture-Image /ImageFile:"%_extdrive%\image.wim" /CaptureDir:%_imgdrive%\ /Name:"SrS Windows 11 image" /Compress:fast /Verify
	if not %errorlevel%==0 (
		echo.
		echo ============= ERROR: Dism capture attempt failed ==============
		goto :badend
	)

:makevhd
	echo.
	echo Creating the image.vhd container
	>%_actdrive%\makevhd.txt  echo create vdisk file="%_extdrive%\image.vhd" type=expandable maximum=%_vhdmb%
	>>%_actdrive%\makevhd.txt echo select vdisk file="%_extdrive%\image.vhd"
	>>%_actdrive%\makevhd.txt echo attach vdisk
	>>%_actdrive%\makevhd.txt echo create partition primary
	>>%_actdrive%\makevhd.txt echo format fs=ntfs quick label="Windows_SrS"
	>>%_actdrive%\makevhd.txt echo assign letter=%_vhddrive%
	>>%_actdrive%\makevhd.txt echo exit
	type %_actdrive%\makevhd.txt
	diskpart /s %_actdrive%\makevhd.txt
	if not %errorlevel%==0 (
		echo.
		echo =========== ERROR: Diskpart make vhd attempt failed ===========
		goto :badend
	)
	set _vhddrive=%_vhddrive%:

:fillvhd
	echo.
	echo Applying image.wim into image.vhd ...
	Dism /ScratchDir:"%_extdrive%\scratch" /Apply-Image /ImageFile:"%_extdrive%\image.wim" /ApplyDir:%_vhddrive%\ /Index:1 /Verify
	if not %errorlevel%==0 (
		echo.
		echo ============== ERROR: Dism apply attempt failed ===============
		goto :badend
	)

:detachvhd
	echo.
	echo Detaching image.vhd
	>%_actdrive%\detachvhd.txt  echo select vdisk file="%_extdrive%\image.vhd"
	>>%_actdrive%\detachvhd.txt echo detach vdisk
	>>%_actdrive%\detachvhd.txt echo exit
	diskpart /s %_actdrive%\detachvhd.txt
	if not %errorlevel%==0 (
		echo.
		echo =========== ERROR: Diskpart detach vhd attempt failed =========
		goto :badend
	)
	echo.
	echo You can delete %_extdrive%\image.wim and %_extdrive%\scratch once
	echo you are happy with image.vhd.

:goodend
	echo.
	echo Completed creating %_extdrive%\image.vhd. To deploy it:
	echo  1) Boot the target PC (UEFI mode) from the Steadier State USB.
	echo  2) Run prepnewpc and point it at %_extdrive%. It wipes the disk
	echo     you choose, copies image.vhd and sets up booting.
	echo  3) Reboot, finish OOBE, run C:\srs\firstrun.cmd, reboot again.
	goto :end

:notwinpe
	echo.
	echo This command file only runs from a Steadier State WinPE USB/ISO.
	goto :end

:badend
	echo.
	echo Please check the errors listed above to see what happened.

:end
	endlocal
	echo.
	echo Steadier State for Windows 11 - based on
	echo https://github.com/7heMC/SteadierState
	echo Exiting...
