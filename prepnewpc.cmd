@echo off

:background
	echo How and Why To Use PREPNEWPC in Steadier State (Windows 11 / UEFI)
	echo ------------------------------------------------------------------
	echo.
	echo Steadier State lets you create a "snapshot" of a Windows 11
	echo installation so that every reboot (or "Launch Image-O-Tron 11K") undoes
	echo every change made since the snapshot. PREPNEWPC prepares a PC:
	echo.
	echo  1. Wipes the disk you choose and lays out a GPT disk:
	echo       EFI System (260MB) - MSR (16MB) - SrS_Tools WinPE (3GB)
	echo       - Physical_Drive (rest of disk, holds image.vhd)
	echo  2. Installs WinPE onto SrS_Tools (the "Launch Image-O-Tron 11K" OS).
	echo  3. Copies image.vhd (made with CVT2VHD) from external storage.
	echo  4. Writes the UEFI boot files and BCD entries.
	echo.
	echo The PC must be booted in UEFI mode. Secure Boot may stay on.
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
	set _winload=\windows\system32\boot\winload.efi
	set _bootex=

:firmwarecheck
	wpeutil UpdateBootInfo >nul
	set _firmware=
	for /f "tokens=3" %%a in ('reg query HKLM\System\CurrentControlSet\Control /v PEFirmwareType 2^>nul') do (set _firmware=%%a)
	if '%_firmware%'=='0x2' (
		echo.
		echo The PC is booted in UEFI mode. Good.
		goto :extdrivequestion
	)
	echo.
	echo This PC is NOT booted in UEFI mode (PEFirmwareType=%_firmware%).
	echo Windows 11 requires UEFI. Turn off CSM/Legacy boot in the
	echo firmware setup, boot the USB stick in UEFI mode, and try again.
	goto :badend

:extdrivequestion
	echo.
	echo ===============================================================
	echo Where is the image stored?
	echo.
	for /f "delims={}" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (echo %%a)
	echo.
	echo What is the drive and folder where image.vhd is stored? For
	echo example E: or E:\images. You can also type 'end' to quit.
	set _extdrive=
	set /p _extdrive=What is your response?
	if /i "%_extdrive%"=="end" goto :end
	if "%_extdrive%"=="" goto :extdrivequestion
	if "%_extdrive:~-1%"=="\" set "_extdrive=%_extdrive:~0,-1%"
	if not exist "%_extdrive%\image.vhd" (
		echo.
		echo -------- ERROR -----------
		echo I can't find %_extdrive%\image.vhd. Let's try again.
		goto :extdrivequestion
	)
	if not exist "%_extdrive%\scratch" md "%_extdrive%\scratch"

:findusbdrive
	rem
	rem Find the boot media's "real" drive letter (label WINPE) so we can
	rem re-apply its \sources\boot.wim to the hard disk.
	rem
	set _usbdrive=
	set _usbguess=false
	for /f "tokens=3,4" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (if /i "%%b"=="WINPE" set _usbdrive=%%a:)
	if '%_usbdrive%'=='' (
		set _usbguess=true
		rem ISO media may not carry the WINPE label; look for boot.wim
		for %%a in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
			if not defined _usbdrive if exist %%a:\sources\boot.wim if exist %%a:\EFI\Boot\bootx64.efi set _usbdrive=%%a:
		)
	)
	if '%_usbdrive%'=='' (
		echo.
		echo Unable to find the Steadier State boot media ^(a volume labelled
		echo WINPE, or one holding \sources\boot.wim^). Please run this from
		echo media built by buildpe.cmd.
		goto :badend
	)
	if not exist %_usbdrive%\sources\boot.wim (
		echo.
		echo Found %_usbdrive% but no \sources\boot.wim on it. Make sure the
		echo Steadier State USB is the only drive labelled WINPE.
		goto :badend
	)
	echo The Steadier State boot media is %_usbdrive%.
	if not "%_usbguess%"=="true" goto :diskquestion
	rem found without the WINPE label (e.g. a Rufus/Ventoy stick): a Windows
	rem installer USB would match too, so make sure it's the right one
	echo.
	echo NOTE: %_usbdrive% has no WINPE label. Make sure it's the Steadier
	echo State stick made by buildpe, not a Windows installer USB.
	set _usbok=
	set /p _usbok=Use %_usbdrive% as the boot media? (y/n) 
	if /i not "%_usbok%"=="y" goto :end

:diskquestion
	rem
	rem On NVMe + USB systems the internal disk is not always disk 0, so
	rem ask instead of assuming, and refuse the disk holding the media
	rem or the image.
	rem
	echo.
	echo ===============================================================
	echo Which disk should I WIPE and install Steadier State on?
	echo.
	>%_actdrive%\listdisk.txt  echo list disk
	>>%_actdrive%\listdisk.txt echo exit
	diskpart /s %_actdrive%\listdisk.txt | find "Disk "
	echo.
	set _disknum=
	set /p _disknum=Enter the disk NUMBER (or 'end' to quit):
	if '%_disknum%'=='end' goto :end
	if '%_disknum%'=='' goto :diskquestion
	set /a _disktest=%_disknum% 2>nul
	if not '%_disktest%'=='%_disknum%' (
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
		echo.
		echo -------- REFUSED -----------
		echo Disk %_disknum% holds the Steadier State boot media. Pick another.
		goto :diskquestion
	)
	for /f "tokens=2,3" %%a in (%_actdrive%\detaildisk.out) do (
		if /i "%%b"=="%_extdrive:~0,1%" (
			echo.
			echo -------- REFUSED -----------
			echo Disk %_disknum% holds %_extdrive%, where image.vhd lives.
			goto :diskquestion
		)
		if /i "%%b"=="%_usbdrive:~0,1%" (
			echo.
			echo -------- REFUSED -----------
			echo Disk %_disknum% holds %_usbdrive%, the Steadier State boot media.
			goto :diskquestion
		)
	)
	echo.
	type %_actdrive%\detaildisk.out | find /v /i "DiskPart" | find /v "Copyright" | find /v "On computer"

:warnings
	echo.
	echo ===============================================================
	echo        W A R N I N G       W A R N I N G       W A R N I N G
	echo ===============================================================
	echo.
	echo This WIPES DISK %_disknum% (shown above) COMPLETELY and converts
	echo it to GPT. Every partition and file on it will be destroyed.
	echo.
	echo If you are sure, type the word "wipe" (lowercase) and press
	echo Enter. Type anything else to stop.
	set _wiperesponse=
	set /p _wiperesponse=Your response:
	if not '%_wiperesponse%'=='wipe' goto :end

:findletters
	rem
	rem Pick four free drive letters: EFI, SrS tools, physical, vhd
	rem
	for /f "tokens=3" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		set _volletter=%%a
		set _volletter=!_volletter:~0,1!
		call set _strletters=%%_strletters:!_volletter! =%%
	)
	set _efidrive=
	set _srsdrive=
	set _phydrive=
	set _vhddrive=
	for %%a in (%_strletters%) do (
		if not exist %%a:\ (
			if not defined _efidrive (
				set _efidrive=%%a
			) else if not defined _srsdrive (
				set _srsdrive=%%a
			) else if not defined _phydrive (
				set _phydrive=%%a
			) else if not defined _vhddrive (
				set _vhddrive=%%a
			)
		)
	)
	if not defined _vhddrive (
		echo.
		echo Error: I need four free drive letters in the range C-W,Y,Z and
		echo couldn't find them. I've got to stop.
		goto :badend
	)
	echo Using EFI=%_efidrive%: SrS_Tools=%_srsdrive%: Physical=%_phydrive%: VHD=%_vhddrive%:

:partition
	rem
	rem Windows 11 GPT layout. EFI is 260MB (minimum for 4Kn disks).
	rem SrS_Tools uses the Windows RE partition type + hidden/required
	rem attributes so Windows does not give it a letter.
	rem
	echo.
	echo Using diskpart to partition disk %_disknum%
	set "_dp=%_actdrive%\makedisk.txt"
	>"%_dp%"  echo select disk %_disknum%
	>>"%_dp%" echo clean
	>>"%_dp%" echo convert gpt
	>>"%_dp%" echo create partition efi size=260
	>>"%_dp%" echo format quick fs=fat32 label="SYSTEM_UEFI"
	>>"%_dp%" echo assign letter=%_efidrive%
	>>"%_dp%" echo create partition msr size=16
	>>"%_dp%" echo create partition primary size=3072
	>>"%_dp%" echo format quick fs=ntfs label="SrS_Tools"
	>>"%_dp%" echo assign letter=%_srsdrive%
	>>"%_dp%" echo set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
	>>"%_dp%" echo gpt attributes=0x8000000000000001
	>>"%_dp%" echo create partition primary
	>>"%_dp%" echo format quick fs=ntfs label="Physical_Drive"
	>>"%_dp%" echo assign letter=%_phydrive%
	>>"%_dp%" echo rescan
	>>"%_dp%" echo exit
	diskpart /s "%_dp%"
	if not %errorlevel%==0 (
		echo.
		echo Diskpart failed to partition disk %_disknum%. It's not safe to
		echo continue. Look at the diskpart output above and the script
		echo %_dp%.
		goto :badend
	)
	set _efidrive=%_efidrive%:
	set _srsdrive=%_srsdrive%:
	set _phydrive=%_phydrive%:
	echo All diskpart phases completed successfully.

:applywim
	echo.
	echo Installing WinPE on the SrS_Tools partition (%_srsdrive%).
	Dism /ScratchDir:"%_extdrive%\scratch" /Apply-Image /ImageFile:%_usbdrive%\sources\boot.wim /ApplyDir:%_srsdrive%\ /Index:1 /CheckIntegrity /Verify
	if not %errorlevel%==0 (
		echo.
		echo ERROR: Failed to apply boot.wim. Can't continue.
		goto :badend
	)
	rem
	rem Give the on-disk WinPE its own background so it is obvious which
	rem WinPE is running. robocopy /B (backup mode) gets past the
	rem TrustedInstaller ACL on winpe.jpg.
	rem
	if exist %_actdrive%\srs\background\winpe.jpg (
		robocopy %_actdrive%\srs\background %_srsdrive%\Windows\System32 winpe.jpg /B /IS /IT /R:1 /W:1 >nul
		if errorlevel 8 (
			echo Note: could not set the on-disk WinPE background ^(cosmetic only^).
		) else (
			echo On-disk WinPE background set.
		)
	)

:copyvhd
	echo.
	echo Using Robocopy to copy image.vhd from %_extdrive% to %_phydrive%
	robocopy "%_extdrive%" %_phydrive%\ image.vhd /J /R:2 /W:5
	rem robocopy: 0-7 = success / no failure, 8+ = failure
	if %errorlevel% GEQ 8 (
		echo.
		echo ERROR: Robocopy failed with return code %errorlevel%.
		goto :badend
	)

:attachvhd
	echo.
	echo Attaching image.vhd
	>%_actdrive%\attachvhd.txt  echo select vdisk file="%_phydrive%\image.vhd"
	>>%_actdrive%\attachvhd.txt echo attach vdisk
	>>%_actdrive%\attachvhd.txt echo exit
	diskpart /s %_actdrive%\attachvhd.txt
	if not %errorlevel%==0 (
		echo Diskpart failed to attach image.vhd.
		goto :badend
	)
	set _volnum=
	set _vhdltr=
	for /f "tokens=2-4" %%a in ('diskpart /s %_actdrive%\srs\listvolume.txt') do (
		if "%%b"=="Windows_SrS" set _volnum=%%a
		if "%%c"=="Windows_SrS" (
			set _volnum=%%a
			set _vhdltr=%%b
		)
	)
	if '%_volnum%'=='' (
		echo Unable to find the volume labelled "Windows_SrS" inside
		echo image.vhd. Was it made with cvt2vhd?
		goto :badend
	)
	rem WinPE may already have given the VHD volume a letter
	if defined _vhdltr (
		set _vhddrive=%_vhdltr%
		goto :vhdletterok
	)
	>%_actdrive%\mountvhd.txt  echo select volume %_volnum%
	>>%_actdrive%\mountvhd.txt echo assign letter=%_vhddrive%
	>>%_actdrive%\mountvhd.txt echo exit
	diskpart /s %_actdrive%\mountvhd.txt
	if not %errorlevel%==0 (
		echo Diskpart was unable to give image.vhd a drive letter.
		goto :badend
	)

:vhdletterok
	set _vhddrive=%_vhddrive%:
	if not exist %_vhddrive%\Windows\System32\winload.efi (
		echo %_vhddrive% doesn't look like a Windows installation.
		goto :badend
	)

:bootexquestion
	rem
	rem Offer the "Windows UEFI CA 2023" signed boot manager if both
	rem this bcdboot and the image support it.
	rem
	if not exist %_vhddrive%\Windows\Boot\EFI_EX\bootmgfw_EX.efi goto :copybcd
	bcdboot /? 2>nul | find /i "bootex" >nul
	if not %errorlevel%==0 goto :copybcd
	echo.
	echo This image includes the boot manager signed with the
	echo "Windows UEFI CA 2023" certificate. Use it ONLY if this PC's
	echo Secure Boot DB already trusts the 2023 CA. If unsure, say 'n'.
	set _bootexresp=
	set /p _bootexresp=Use the 2023-signed boot manager? (y/n)
	if '%_bootexresp%'=='y' set _bootex=/bootex

:copybcd
	echo.
	echo Writing UEFI boot files with BCDBoot from the image
	bcdboot %_vhddrive%\Windows /s %_efidrive% /f UEFI %_bootex%
	if not %errorlevel%==0 (
		echo.
		echo ERROR: BCDBoot failed. It's not safe to continue.
		goto :badend
	)
	set "_bcdstore=/store %_efidrive%\EFI\Microsoft\Boot\BCD"

:bcdconfig
	echo.
	echo Adding the "Launch Image-O-Tron 11K" (on-disk WinPE) boot entry
	rem fixed GUID so srsmgr finds it without parsing (language-independent)
	set _guid={5d0c6a10-1e5b-4c7e-9a7d-511f0a11b001}
	bcdedit %_bcdstore% /create %_guid% /d "Launch Image-O-Tron 11K" /application osloader
	if errorlevel 1 (
		echo Unable to create the Launch Image-O-Tron 11K entry with bcdedit
		goto :badend
	)
	echo on
	bcdedit %_bcdstore% /set %_guid% device partition=%_srsdrive%
	bcdedit %_bcdstore% /set %_guid% osdevice partition=%_srsdrive%
	bcdedit %_bcdstore% /set %_guid% path %_winload%
	bcdedit %_bcdstore% /set %_guid% systemroot \windows
	bcdedit %_bcdstore% /set %_guid% winpe yes
	bcdedit %_bcdstore% /set %_guid% detecthal yes
	bcdedit %_bcdstore% /displayorder %_guid% /addlast
	bcdedit %_bcdstore% /timeout 3
	@echo off
	rem
	rem bcdboot made the image.vhd (master) entry the store's {default}, so
	rem the first boot goes into the master image for firstrun.cmd. No
	rem parsing of (language-dependent) bcdedit output needed.
	rem
	bcdedit %_bcdstore% /set {default} description "Windows 11 (master image)"
	if errorlevel 1 (
		echo.
		echo Unable to find the image.vhd boot entry in %_bcdstore%
		goto :badend
	)
	echo The master image ^(image.vhd^) is the default boot entry.

:copysrs
	echo.
	echo Copying Steadier State files to the SrS_Tools WinPE and image.vhd
	robocopy %_actdrive%\srs %_srsdrive%\srs /E >nul
	copy %_actdrive%\startnethd.cmd %_srsdrive%\windows\system32\startnet.cmd /y
	md %_vhddrive%\srs 2>nul
	for %%f in (firstrun.cmd listvolume.txt srsmgr.exe) do copy %_actdrive%\srs\%%f %_vhddrive%\srs /y >nul
	md %_vhddrive%\srs\hooks 2>nul
	copy %_actdrive%\srs\hooks\* %_vhddrive%\srs\hooks /y >nul
	md %_vhddrive%\srs\hooks-samples 2>nul
	copy %_actdrive%\srs\hooks-samples\* %_vhddrive%\srs\hooks-samples /y >nul
	>%_actdrive%\detachvhd.txt  echo select vdisk file="%_phydrive%\image.vhd"
	>>%_actdrive%\detachvhd.txt echo detach vdisk
	>>%_actdrive%\detachvhd.txt echo exit
	diskpart /s %_actdrive%\detachvhd.txt >nul
	goto :goodend

:notwinpe
	echo.
	echo This command file only runs from a Steadier State WinPE USB/ISO.
	echo Build one with buildpe.cmd and boot from it.
	goto :end

:goodend
	echo.
	echo ===============================================================
	echo PREPNEWPC COMPLETED SUCCESSFULLY
	echo ===============================================================
	echo.
	echo Remove the USB stick and reboot. The PC boots into image.vhd
	echo (the master image). Finish OOBE, make any final changes, then
	echo run C:\srs\firstrun.cmd from an elevated prompt and reboot. The
	echo SrS_Tools WinPE will create snapshot.vhd and reboot into it.
	goto :end

:badend
	echo.
	echo Something went wrong and we were not able to prepare this
	echo computer for Steadier State. The disk may now be unbootable.
	echo Fix the problem shown above and run prepnewpc again.

:end
	endlocal
	echo.
	echo Steadier State for Windows 11 - based on
	echo https://github.com/7heMC/SteadierState
	echo Exiting...
