@echo off

:setup
	setlocal

:pinfeatureupdate
	rem
	rem Windows 11 feature updates (e.g. 24H2 -> 25H2) cannot be
	rem installed on a native-boot VHD: setup refuses to install to a
	rem virtual drive. This hook pins the PC to its current feature
	rem release so Windows Update keeps delivering monthly cumulative
	rem updates but does not keep trying (and failing) the upgrade.
	rem To move to a new release, rebuild image.vhd with cvt2vhd.
	rem
	set _dispver=
	for /f "tokens=2,*" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion ^| find "DisplayVersion"') do set _dispver=%%b
	if "%_dispver%"=="" (
		echo Unable to read DisplayVersion; not pinning.
		goto :end
	)
	echo Pinning Windows 11 feature release to %_dispver%
	set "_wu=HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
	reg add "%_wu%" /v ProductVersion /t REG_SZ /d "Windows 11" /f
	reg add "%_wu%" /v TargetReleaseVersion /t REG_DWORD /d 1 /f
	reg add "%_wu%" /v TargetReleaseVersionInfo /t REG_SZ /d "%_dispver%" /f

:goodend
	echo.
	echo Hook appears to have completed successfully!

:end
	endlocal
	echo.
