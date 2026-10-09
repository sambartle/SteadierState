@echo off

:setup
	setlocal

:win11vhdboot
	rem
	rem Windows 11 settings that native VHD boot needs:
	rem  - Stop automatic Device Encryption (BitLocker). It is not
	rem    supported on a native-boot VHD or on the volume hosting it,
	rem    and 24H2+ enables it automatically on many PCs.
	rem  - Turn off hibernation / Fast Startup (not supported from VHD).
	rem
	echo.
	echo Applying Windows 11 native-VHD-boot settings...
	reg add "HKLM\SYSTEM\CurrentControlSet\Control\BitLocker" /v PreventDeviceEncryption /t REG_DWORD /d 1 /f
	powercfg /hibernate off
	reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power" /v HiberbootEnabled /t REG_DWORD /d 0 /f
	echo.
	echo Current BitLocker status of %systemdrive%:
	manage-bde -status %systemdrive% | findstr /i /c:"Conversion Status" /c:"Protection Status"

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
