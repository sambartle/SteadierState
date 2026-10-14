WinPE desktop backgrounds for Steadier State (Windows 11 edition)

  usb.jpg   - shown when booted from the Steadier State USB stick / ISO
  disk.jpg  - shown when booted into the on-disk WinPE ("Roll Back Windows")

usb.jpg uses the blue "Image-O-Tron 11,000" logo and disk.jpg the red one,
each with a small caption at the bottom saying which WinPE is running.

Replace either file with any JPG of your own, keeping the same name.
1920x1080 (or your screens' native resolution) works best. Then re-run
buildpe.cmd. usb.jpg is built into the stick; disk.jpg is carried on the
stick and installed onto the SrS_Tools partition by prepnewpc.cmd.

If a file is missing, WinPE keeps its default background.
