@echo off

:background
	rem ====================================================================
	rem						PREPREF.CMD   (new for Windows 11)
	rem
	rem Run this INSIDE the Windows 11 reference PC, from an elevated
	rem prompt, before booting the Steadier State USB and running cvt2vhd.
	rem It checks and fixes the things that stop Windows 11 working as a
	rem native-boot VHD:
	rem   1. Firmware must be UEFI.
	rem   2. Edition must be Pro / Enterprise / Education (not Home).
	rem   3. BitLocker / Device Encryption must be fully OFF, and must be
	rem      prevented from turning itself back on.
	rem   4. Hibernation and Fast Startup must be off.
	rem   5. Optionally runs Sysprep /generalize /oobe /shutdown.
	rem ====================================================================
	echo.
	echo ===============================================================
	echo    Steadier State - prepare Windows 11 reference PC (prepref)
	echo ===============================================================
	setlocal
	set "_here=%~dp0"
	set _problems=0

:admincheck
	whoami /groups | find "S-1-16-12288" >nul
	if %errorlevel%==0 goto :uefi
	echo.
	echo Please run prepref.cmd from an elevated (Run as administrator)
	echo command prompt.
	goto :end

:uefi
	echo.
	echo [1/5] Firmware type
	bcdedit /enum {current} | find /i "winload.efi" >nul
	if %errorlevel%==0 (
		echo       UEFI - OK
	) else (
		echo       NOT UEFI. Windows 11 Steadier State requires UEFI boot.
		set /a _problems+=1
	)

:edition
	echo.
	echo [2/5] Windows edition / build
	set _edition=
	set _build=
	set _dispver=
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v EditionID ^| find "EditionID"') do set _edition=%%b
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild ^| find "CurrentBuild"') do set _build=%%b
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion ^| find "DisplayVersion"') do set _dispver=%%b
	echo       %_edition% build %_build% (%_dispver%)
	if /i "%_edition%"=="Core" goto :home
	if /i "%_edition%"=="CoreSingleLanguage" goto :home
	if defined _build if %_build% LSS 22000 echo       WARNING: this is not Windows 11.
	goto :bitlocker

:home
	echo       Windows 11 Home cannot native-boot from VHD. Upgrade to Pro,
	echo       Enterprise or Education first.
	set /a _problems+=1

:bitlocker
	echo.
	echo [3/5] BitLocker / Device Encryption on %systemdrive%
	reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f >nul
	echo       PreventDeviceEncryption set (stops it re-enabling itself).
	powershell -NoProfile -Command "if((Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus -eq 'FullyDecrypted'){exit 0}else{exit 1}" >nul 2>&1
	if %errorlevel%==0 (
		echo       Fully Decrypted - OK
		goto :hibernate
	)
	manage-bde -status %systemdrive% | findstr /i /c:"Conversion Status" /c:"Percentage" /c:"Protection Status"
	echo.
	echo       %systemdrive% is encrypted (or decrypting). It must be fully
	echo       decrypted before capture. Make sure you have your recovery key
	echo       saved somewhere safe first.
	set _bderesp=
	set /p _bderesp=      Decrypt %systemdrive% now? (y/n) 
	if /i not "%_bderesp%"=="y" (
		set /a _problems+=1
		goto :hibernate
	)
	manage-bde -off %systemdrive%
	if not %errorlevel%==0 (
		echo       manage-bde -off failed. Remove auto-unlock keys / resume
		echo       BitLocker, or decrypt from Settings, then run this again.
		set /a _problems+=1
		goto :hibernate
	)
	set _bdeloops=0

:bdewait
	timeout /t 30 /nobreak >nul
	set /a _bdeloops+=1
	if %_bdeloops% GTR 720 (
		echo       Still not decrypted after 6 hours - giving up. Check
		echo       "manage-bde -status" and run prepref.cmd again later.
		set /a _problems+=1
		goto :hibernate
	)
	powershell -NoProfile -Command "if((Get-BitLockerVolume -MountPoint $env:SystemDrive).VolumeStatus -eq 'FullyDecrypted'){exit 0}else{exit 1}" >nul 2>&1
	if %errorlevel%==0 (
		echo       Fully Decrypted - OK
		goto :hibernate
	)
	for /f "tokens=*" %%a in ('manage-bde -status %systemdrive% ^| find /i "Percentage"') do echo       %%a
	goto :bdewait

:hibernate
	echo.
	echo [4/5] Hibernation and Fast Startup
	powercfg /hibernate off
	reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f >nul
	echo       Off - OK

:summary
	echo.
	if not %_problems%==0 (
		echo ===============================================================
		echo %_problems% problem^(s^) must be fixed before this PC can be
		echo captured. Fix them and run prepref.cmd again.
		echo ===============================================================
		goto :end
	)
	echo All checks passed.

:sysprep
	echo.
	echo [5/5] Sysprep (optional)
	echo       Generalizing lets image.vhd be deployed to OTHER PCs. Skip it
	echo       if you will only deploy back to this same PC.
	set _spresp=
	set /p _spresp=      Run Sysprep /generalize /oobe /shutdown now? (y/n) 
	if /i not "%_spresp%"=="y" goto :next
	set "_unattend=%_here%Sysprep\unattend-win11.xml"
	if exist "%_unattend%" (
		"%windir%\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /unattend:"%_unattend%"
	) else (
		"%windir%\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown
	)
	echo.
	echo If Sysprep reported an error, the usual Windows 11 cause is a
	echo Store app installed for one user but not provisioned. Details:
	echo   %windir%\System32\Sysprep\Panther\setuperr.log
	echo Look for "SYSPRP Package ... was installed for a user" and remove
	echo that app with:  powershell "Get-AppxPackage -AllUsers *Name* | Remove-AppxPackage -AllUsers"
	goto :end

:next
	echo.
	echo Next: shut down, boot this PC from the Steadier State USB stick
	echo and run cvt2vhd.
	echo DO NOT let Windows boot again after Sysprep - boot the USB stick.

:end
	endlocal
	echo.
