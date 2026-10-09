@echo off
	rem
	rem Steadier State command file \srs\merge.cmd
	rem
	rem FUNCTION:
	rem Merges snapshot.vhd into image.vhd, then creates a fresh empty
	rem snapshot.vhd. Called from startnet.cmd (startnethd.cmd), which
	rem sets _phydrive, _actdrive and _bcdstore.
	rem
	rem Windows 11 edition change: the old snapshot is only deleted if
	rem the merge actually succeeded. Previously a failed merge still
	rem deleted snapshot.vhd, silently losing the changes.
	rem
	echo.
	echo Found base image and snapshot files. Merging files... This can
	echo take a while; after Diskpart reports "100 percent" it may still
	echo need several minutes to finish.

:setup
	set _mergerc=99
	if not exist "%_phydrive%\image.vhd" (
		echo ERROR: %_phydrive%\image.vhd not found.
		goto :badend
	)
	if not exist "%_phydrive%\snapshot.vhd" (
		echo ERROR: %_phydrive%\snapshot.vhd not found.
		goto :badend
	)

:mergesnapshot
	echo.
	echo Merging snapshot.vhd into image.vhd
	>%_actdrive%\mergesnaps.txt  echo select vdisk file="%_phydrive%\snapshot.vhd"
	>>%_actdrive%\mergesnaps.txt echo merge vdisk depth=1
	>>%_actdrive%\mergesnaps.txt echo exit
	diskpart /s %_actdrive%\mergesnaps.txt
	set _mergedprc=%errorlevel%
	del %_actdrive%\mergesnaps.txt 2>nul
	if not %_mergedprc%==0 (
		echo.
		echo ERROR: Diskpart merge failed ^(rc=%_mergedprc%^). snapshot.vhd has
		echo been left in place so nothing is lost. Investigate before
		echo rebooting.
		goto :badend
	)

:deletesnapshot
	echo.
	echo Deleting old snapshot...
	del "%_phydrive%\snapshot.vhd"
	if exist "%_phydrive%\snapshot.vhd" (
		echo ERROR: could not delete the old snapshot.vhd.
		goto :badend
	)

:makesnapshot
	echo.
	echo Making a new snapshot.vhd
	>%_actdrive%\makesnapshot.txt  echo create vdisk file="%_phydrive%\snapshot.vhd" parent="%_phydrive%\image.vhd"
	>>%_actdrive%\makesnapshot.txt echo exit
	diskpart /s %_actdrive%\makesnapshot.txt
	set _makesnaprc=%errorlevel%
	del %_actdrive%\makesnapshot.txt 2>nul
	if not %_makesnaprc%==0 (
		echo ERROR: Diskpart couldn't create the new snapshot.vhd.
		goto :badend
	)

:bcdcheck
	echo.
	echo Setting the snapshot.vhd BCD entry as default
	for /f "delims=" %%a in ('bcdedit %_bcdstore% /enum /v') do (
		for /f "tokens=1,2" %%b in ("%%a") do (
			if "%%b"=="identifier" (
				set _guid=%%c
				bcdedit %_bcdstore% /enum !_guid! /v | find /i "snapshot.vhd" >nul
				if !errorlevel!==0 (
					bcdedit %_bcdstore% /default !_guid!
					goto :goodend
				)
			)
		)
	)
	echo.
	echo WARNING: no snapshot.vhd boot entry was found. Run "rollback" to
	echo create one before rebooting.
	goto :badend

:goodend
	echo.
	echo Complete. image.vhd now contains the old snapshot's changes, and
	echo they cannot be lost by a future rollback. It's safe to reboot now.
	set _mergerc=0
	goto :end

:badend
	set _mergerc=99
	goto :end

:end
	echo.
	echo Steadier State for Windows 11 - based on
	echo https://github.com/7heMC/SteadierState
	echo.
