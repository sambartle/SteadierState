# DEVLOG - SteadierState Windows 11 port

## 2026-10-09 - Windows 11 / UEFI port (branch `windows11`)

**Goal:** make 7heMC/SteadierState (Windows 10 port of Mark Minasi's Steadier State) work with Windows 11.
**Scope decision (Sam):** Windows 11 / UEFI / 64-bit only. BIOS, 32-bit and Win7/8 code paths removed.
**Base commit:** `bf13229` ("Correct spelling") of https://github.com/7heMC/SteadierState

**Testing status:** NOT yet tested on hardware. The scripts were checked statically (every goto/call label exists, brackets balance). The first real test should be in a Hyper-V Gen 2 VM (UEFI + Secure Boot + vTPM) before trying physical PCs. See "Test plan" below.

### Why the Win10 version breaks on Windows 11

1. **ADK changes.** WinPE is a separate "WinPE add-on" installer (since ADK 1809). The old script only checked the ADK folder and downloaded a 2015-era Win10 ADK link using `bitsadmin`. There is no x86 WinPE in the Windows 11 ADK.
2. **Automatic Device Encryption (24H2+).** Clean Windows 11 installs on modern hardware turn BitLocker on by themselves. WinPE can't capture a locked volume. BitLocker is also not supported for a native-boot VHD or the volume hosting it, and if Windows encrypted the Physical_Drive host volume it would stop booting.
3. **Edition.** Native VHD boot isn't available on Windows 11 Home.
4. **UEFI-only OS.** Windows 11 requires UEFI, so the BIOS paths were dead code.
5. **Feature updates** can't install on a native-boot VHD ("can't install to a virtual drive").
6. **Disk numbering.** On NVMe PCs, WinPE can list the USB stick as disk 0. The old prepnewpc *always* wiped disk 0.
7. **Secure Boot CA rollover.** The 2011 Microsoft boot signing certificates are being replaced by "Windows UEFI CA 2023". PCs with the BlackLotus DBX revocation applied won't boot media signed only with the 2011 certificate.

### Changes by file

| File | Change |
|---|---|
| `buildpe.cmd` | amd64 only. Checks the ADK **and** the WinPE add-on. Downloads/installs both with `curl.exe` (silent) if missing. Admin check uses the High Mandatory SID (S-1-16-12288), which doesn't depend on the language. Adds WinPE-WMI + WinPE-SecureStartup (so `manage-bde` works in PE). Optional `/bootex` (2023-signed boot manager), only offered if this ADK's MakeWinPEMedia supports it. Refuses the system drive as the USB target. Quoted paths throughout. Removed the 32/64 question. |
| `prepnewpc.cmd` | UEFI only (exits with an explanation on BIOS). **Asks for the disk number**, shows `detail disk`, and refuses the disk holding the WINPE media or image.vhd. Single GPT diskpart script: EFI 260MB (4Kn minimum), MSR 16MB, SrS_Tools 3GB (RE type, hidden; was 1GB, too small for Win11 WinPE), Physical_Drive rest. Checks that image.vhd exists before wiping. Robocopy success is now any rc < 8 (it used to accept only rc==1), with `/J` unbuffered copy. Checks the mounted VHD contains Windows. `bcdboot /f UEFI`, optional `/bootex`. Master entry renamed "Windows 11 (master image)". Detaches the VHD at the end. Fixed `if not %_wiperesponse%==wipe`, which crashed on empty input. |
| `cvt2vhd.cmd` | BitLocker check with manage-bde (stops if not Fully Decrypted). Reads the offline registry for edition/build/version and refuses Home. Warns if not generalized (State.ini). Minimum 64GB / maximum 2000GB VHD size, converted correctly to MB (it used to append "000"). Refuses to store the image on the drive being captured. Temp diskpart scripts go on X:\ rather than the current directory. `/Compress:fast` capture. |
| `startnethd.cmd` | UEFI only. Handles an EFI partition that already has a drive letter. Added the missing `:notwinpe` label (old bug). Quoted comparisons on FOR tokens so an empty token can't crash the script. Safe deletion of noauto.txt. |
| `rollback.cmd` | Checks the old snapshot was actually deleted. New BCD entry description "Windows 11 (Steadier State)". Removed a stray tab. |
| `merge.cmd` | **Data-loss fix:** it used to delete snapshot.vhd even if the diskpart merge failed, and always returned success. Now each step is checked and `_mergerc=99` is returned on failure, so startnet won't auto-reboot. |
| `firstrun.cmd` | Elevation check. Hooks run from `%~dp0hooks\*.cmd` (it used to be the relative path `hooks\*`, which broke unless the current directory was C:\srs). Still runs when the Physical Drive has no letter. |
| `hooks/1050-win11-vhdboot.cmd` | **New.** PreventDeviceEncryption=1, `powercfg /h off`, HiberbootEnabled=0, prints the BitLocker status. |
| `hooks/1100-registrynodrives.cmd` | **Bug fix:** the NoDrives value was written as decimal digits inside a hex DWORD (E: = `dword:00000016` = 22, which hides B, C and E). Now computed as `1 << n` with `reg add`. |
| `hooks/1110-security.cmd` | Uses `%systemdrive%\srs` (it used to be a relative `\srs`). Skips srsdirectives if there is no Physical Drive letter. |
| `hooks-samples/1100-removemasterbootentry.cmd` | Replaces `1100-removewindows10bootentry.cmd`. Matches the `image.vhd` device rather than the text "Windows 10" (which also risked matching the snapshot entry). |
| `hooks-samples/1200-pinfeatureupdate.cmd` | **New.** Pins TargetReleaseVersionInfo to the current DisplayVersion. |
| `prepref.cmd` | **New.** Single script for the reference PC: UEFI, edition, BitLocker decrypt and wait, PreventDeviceEncryption, hibernation, optional Sysprep with tips on Appx errors. |
| `Sysprep/unattend-win11.xml` | Replaces skiprearm32/64.xml. amd64 SkipRearm plus PreventDeviceEncryption in specialize. Removed the Win7 offlineImage reference. |
| `README.md` | Windows 11 requirements, Phase 0, disk layout, hooks table, limitations. |
| all | CRLF line endings kept. |

### Known limitations / open questions

- **Not hardware-tested yet.**
- The ADK fwlinks in buildpe.cmd (`linkid=2289980` ADK, `2289981` WinPE add-on) are the Windows 11 24H2 ADK links as far as I know. If Microsoft retires them, the script tells you to install manually.
- `/bootex` support: detected by searching MakeWinPEMedia.cmd for "bootex" and by checking for `Windows\Boot\EFI_EX\bootmgfw_EX.efi` in the image. The on-disk "Roll Back Windows" entry uses WinPE's own winload.efi. On a PC where the **2011 PCA is fully revoked**, check that this WinPE winload still loads (needs the 2023-signed ADK/WinPE build).
- Still uses `.vhd`, not `.vhdx`. VHDX would handle power loss better. It's a possible follow-up, since the filename is hard-coded in every script.
- WinPE language packs: only en-us optional component language CABs are added.

### Test plan (suggested)

1. Hyper-V Gen 2 VM, Secure Boot on (Microsoft Windows template), vTPM on, 2 x 150GB disks. Install Windows 11 Pro 24H2/25H2.
2. Run `prepref.cmd` and confirm it reports Device Encryption and decrypts. Then Sysprep.
3. On a Win11 admin PC run `buildpe.cmd` and build the ISO. Boot the VM from it and run `cvt2vhd` to the second disk.
4. Boot again and run `prepnewpc`, picking disk 0 (the first VHDX). Check it refuses disk 1 (holds image.vhd).
5. Boot the master, finish OOBE, run `C:\srs\firstrun.cmd` and reboot. Check snapshot.vhd is created and Windows boots from it.
6. Make a change, reboot, and confirm it is rolled back. Test the `noauto` and `automerge` directives. Test that a forced merge failure keeps snapshot.vhd.
7. Repeat on one physical NVMe PC with USB boot.

## 2026-10-09 - Review pass (independent static review of the batch files)

Fixed:
- **prepnewpc.cmd:** `echo select disk 1>file` was read as a handle-1 redirect, so disks 0-9 were always "not found". The redirect now goes before `echo` (same for the list disk script).
- **cvt2vhd.cmd / firstrun.cmd:** an unescaped `)` in an `echo` inside an `if` block ended the block early, so the script stopped with a syntax error on every run. Escaped as `^(` `^)`.
- **buildpe.cmd:** cleanup crashed if %TEMP% had a space in it. It now uses `if defined` and quotes.
- Typed path answers are now compared in double quotes, so paths with spaces don't crash the script (prepnewpc, cvt2vhd, buildpe).
- **prepnewpc.cmd:** an ISO boot may have no WINPE label, so if none is found it falls back to any volume with `\sources\boot.wim` + `\EFI\Boot\bootx64.efi`.
- **prepnewpc.cmd:** the Windows_SrS volume lookup now works whether or not WinPE gave the VHD volume a letter (tokens 2-4).
- **prepref.cmd:** checks the manage-bde -off result and stops waiting for decryption after 6 hours. The PowerShell hint no longer prints a literal `^|`.
- Removed `!` from echo text in the scripts that use delayed expansion (it was being swallowed).

Added a static checker (run locally in the session, not committed): every goto/call target exists, brackets balance, and no echo inside a block has an unescaped `)`.

## 2026-10-14 - Fix: "findstr is not recognized" in WinPE

**Reported by Sam:** prepnewpc stopped with `'findstr' is not recognized as an internal or external command`.
**Cause:** WinPE ships `find.exe` but not `findstr.exe`. The Windows 11 port used findstr in the two scripts that run in WinPE (prepnewpc.cmd, cvt2vhd.cmd).
**Fix:**
- prepnewpc.cmd: disk list, the invalid-disk check (now two `find` calls feeding a flag), the WINPE-volume refusal and the detail-disk display all use `find`.
- cvt2vhd.cmd: the BitLocker status checks use `find`. `where manage-bde.exe` (where.exe isn't guaranteed in WinPE either) is replaced with `if exist %windir%\System32\manage-bde.exe`.
- Checked every command the WinPE-side scripts call (prepnewpc, cvt2vhd, startnethd, rollback, merge). All are in WinPE: bcdboot, bcdedit, diskpart, find, reg, robocopy, wpeutil, and manage-bde (only with the WinPE-SecureStartup component, and the script checks for it first).
- buildpe.cmd, prepref.cmd and the hooks run in full Windows, so findstr is fine there.
**Action needed:** the scripts live inside boot.wim on the USB stick, so re-run buildpe.cmd to rebuild the stick.

## 2026-10-14 - Fix: "not enough space" applying boot.wim

**Reported by Sam:** prepnewpc failed at :applywim with "There is not enough space on the disk". He had a 175GB VHD and a 446GB disk.
**Cause:** the SrS_Tools partition was 1024MB (carried over from the Win10 version). The Windows 11 ADK WinPE, plus WinPE-WMI and WinPE-SecureStartup, is bigger than that once expanded. The VHD size has nothing to do with this step.
**Fix:** SrS_Tools is now 3072MB (3GB). Banner and README updated.
**Live workaround:** edit `size=1024` to `size=3072` in X:\prepnewpc.cmd and re-run it. It re-partitions the disk, which is fine because nothing has been deployed to it yet.
**To check:** `dism /Get-ImageInfo /ImageFile:<usb>:\sources\boot.wim /Index:1`. The "Size" field is the expanded size and must be under 3GB.

## 2026-10-14 - WinPE desktop backgrounds

**Request (Sam):** set the WinPE desktop background on the stick and in the on-disk WinPE, using the supplied "Image-O-Tron 11,000 - Powered by SteadierState" logo for both.
- New `background\usb.jpg` and `background\disk.jpg`, both made from Sam's logo (1024x572). Each has a small caption at the bottom saying which WinPE is running (USB vs on-disk "Roll Back Windows"). The original project's winpe.bmp/winpe1.bmp did the same; the Win10 buildpe never installed them.
- buildpe.cmd (new `:background` step): takes ownership of `Windows\System32\winpe.jpg` in the mounted boot.wim (takeown /a, then icacls grant to Administrators by SID) and copies usb.jpg over it. It copies disk.jpg to `\srs\background\winpe.jpg` inside the image. Log: `04bbackground.txt`.
- prepnewpc.cmd: after applying boot.wim to SrS_Tools, it uses `robocopy /B` (backup mode, which gets past the TrustedInstaller ACL from WinPE) to put disk.jpg in place as the on-disk WinPE's winpe.jpg. If this fails it just notes it (cosmetic) and carries on.
- If a JPG is missing, WinPE keeps its default background.
- Not tested on hardware yet. If WinPE ignores it, check the takeown/icacls output in `04bbackground.txt`.

## 2026-10-14 - setbackground.cmd (apply backgrounds without rebuilding)

**Request (Sam):** apply the new backgrounds to an existing stick and an already-deployed PC.
New `setbackground.cmd`. Run it in normal Windows, elevated. It only uses built-in tools, so no ADK is needed. Menu:
1. **On-disk WinPE:** finds the volume labelled SrS_Tools, gives it a temporary letter with diskpart if it has none, copies disk.jpg into `Windows\System32\winpe.jpg` with `robocopy /B` (backup mode gets past the TrustedInstaller ACL) and into `\srs\background\`, then removes the letter again. SrS_Tools is a physical partition, not part of snapshot.vhd, so a rollback doesn't undo this.
2. **USB stick:** finds a drive with `\sources\boot.wim` + `\EFI\Boot\bootx64.efi` and confirms it, or asks for the letter. Then it runs `dism /Mount-Image` on index 1, takes ownership of winpe.jpg, copies in usb.jpg (and disk.jpg to `\srs\background`) and runs `/Unmount-Image /Commit`. On failure it discards the changes.
3. **Both.**
Logs go to `%TEMP%\srs-setbackground\`. Statically checked (labels, brackets). Not run on hardware yet.

## 2026-10-14 - Fix: "rollback.cmd is not recognized" / "goto was unexpected" on first WinPE boot

**Reported by Sam:** after running firstrun and rebooting, the on-disk WinPE printed "Creating initial snapshot file", then "'rollback.cmd' is not recognized..." and then "goto was unexpected at this time".
**Cause:** an inherited bug in startnethd.cmd. `set path=%path%X:\srs;` adds X:\srs to the PATH without a `;` before it, so it gets glued onto the last PATH entry and rollback.cmd/merge.cmd can't be found. Because the call failed, `_rollbackrc` was never set, so `if %_rollbackrc%==0 goto ...` expanded to `if ==0 goto ...`, which is a syntax error.
**Fix (startnethd.cmd):**
- `set "path=%path%;X:\srs"`
- All calls use full paths: `call X:\srs\rollback.cmd` and `call X:\srs\merge.cmd`.
- `_rollbackrc` and `_mergerc` are set to 99 before each call and compared in quotes, so a failed call can never crash the script or be taken as success.
**Live fix on a deployed PC:** the on-disk WinPE's startnet.cmd is X:\Windows\System32\startnet.cmd on the SrS_Tools partition, so edits made there in Notepad persist across reboots.

## 2026-10-14 - Fix: manual rollback prompt mentioned merging

**Reported by Sam:** with noauto, choosing `rollback` showed a confirmation telling you to press 'y' "to merge".
**Cause:** the merge prompt's wording had been copied into the rollback prompt in the original project. The behaviour was already correct: 'y' at that prompt runs rollback.cmd.
**Fix:** reworded the rollback confirmation in startnethd.cmd. It now says the snapshot's changes are discarded and that 'y' means ROLL BACK. The merge prompt was checked and is correct.

## 2026-10-14 - debugmode.cmd and restore2disk.cmd (video driver debugging)

**Request (Sam):** a way to undo cvt2vhd / get the image back onto the machine to debug its video driver. Chose **both** an in-place option and a full restore, restoring the **master image** (image.wim/.vhd).

**debugmode.cmd** (new; goes in C:\srs inside the image and in \srs on the stick):
- `on`: disables the `bcddefault` ONSTART task and runs `bcdedit /default {current}` (the task already pointed this boot's default at Roll Back Windows). Reboots then stay in the snapshot with changes kept.
- `off`: re-enables the task and runs bcddefault.cmd, so the next reboot rolls back.
- `keep`: writes `\srsdirectives\automerge.txt` on the Physical Drive and re-enables the task, so the next reboot merges.
- no argument: shows the current state.

**restore2disk.cmd** (new; WinPE, root of the stick, the reverse of cvt2vhd + prepnewpc):
- The source is image.wim or image.vhd on an external drive. A VHD is attached read-only and its Windows_SrS volume captured to a temporary restore-temp.wim next to it, which is deleted afterwards.
- It uses the same disk selection and refusals as prepnewpc (won't wipe the boot media's disk or the source's disk) and the same "wipe" confirmation. It only uses `find`, not findstr.
- GPT layout: EFI 260MB, MSR 16MB, Windows on the rest of the disk. Then DISM apply and `bcdboot /f UEFI`.
- Clean-up: deletes the NoDrives policy from the offline SOFTWARE hive and removes \srs. The bcddefault task (if present) is harmless and the script prints the command to delete it.
- WinRE isn't recreated. That's fine for debugging.

Both are wired into buildpe.cmd (copy lists and startnet banner) and prepnewpc.cmd (debugmode is copied into the VHD's \srs). The README is updated. Statically checked (labels, brackets, no findstr). Not run on hardware yet.

**Note for Sam's current PC:** it was deployed before these existed. Copy debugmode.cmd into C:\srs by hand. If the PC is rolling back, it also needs to go into image.vhd (via `debugmode keep` or a merge), or it'll vanish on the next rollback.

## 2026-10-14 - Removed unused background images

**Request (Sam):** remove the watercolor and orange moon backgrounds if they're unused.
Checked with grep: nothing in any .cmd, .md, .txt or .xml file refers to them. Removed:
- `watercolor/` (3 BMPs) and `orange moon winpe background/` (3 BMPs)
- root `winpe.bmp` and `winpe1.bmp` (byte-for-byte the same as watercolor/winpe*.bmp; the build now uses `background\usb.jpg` and `disk.jpg`)
This saves about 17MB. They're still in git history (commit bf13229) if they're ever wanted.
Kept: `Rebuilding Steady State.pptx` (the original project's presentation; documentation, not referenced by any script).

## 2026-10-14 - Red background for the on-disk WinPE

**Request (Sam):** replace disk.jpg with the red version of the Image-O-Tron logo.
`background\disk.jpg` is now the red logo (1024x572) with the same "Booted from on-disk WinPE - Roll Back Windows" caption. usb.jpg stays blue, so the two WinPEs are easy to tell apart by colour. background\README.txt updated.
To apply it to an already-deployed PC without redeploying, run `setbackground.cmd`, option 1.
