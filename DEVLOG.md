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
6. Make a change, reboot, and confirm it is rolled back. *(Updated: test the Image-O-Tron modes, actions and scheduling instead of the removed noauto/automerge directives; see the Image-O-Tron entries below.)* Test that a forced merge failure keeps snapshot.vhd.
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

## 2026-10-15 - Fix: buildpe "Failed to format F:; DiskPart errorlevel -2147024809"

**Reported by Sam:** `MakeWinPEMedia /ufd` failed with `ERROR: Failed to format "F:"; DiskPart errorlevel -2147024809`.
**Cause:** -2147024809 = 0x80070057 (invalid parameter). MakeWinPEMedia /ufd formats the whole stick as FAT32, and Windows' format refuses FAT32 on volumes over 32GB, so most modern sticks fail.
**Fix (buildpe.cmd):** MakeWinPEMedia /ufd is no longer used.
1. `:makeiso` always runs first. It builds the requested ISO, or a temporary `%_buildpepath%\usbmedia.iso` (honouring `/bootex`).
2. `:makeusb` uses PowerShell (Get-Partition/Get-Disk) to find the stick's disk number, bus type and size. It **refuses** the boot/system disk, and asks before wiping a disk that isn't on the USB bus.
3. diskpart then runs clean, convert mbr, `create partition primary size=32000` (capped only when the stick is over 32000MB), format fat32 label WINPE (prepnewpc looks for that label), active, and assigns the same letter.
4. The ISO is mounted (Mount-DiskImage) and robocopied to the stick, then dismounted. Robocopy rc < 8 counts as success, and it checks that `\EFI\Boot\bootx64.efi` exists.
Note: the whole USB disk is wiped (all partitions), not just the selected volume. Any space beyond 32GB is left unallocated.

## 2026-10-15 - Image-O-Tron 11,000 rollback manager (srsmgr.exe)

**Request (Sam):** a small GUI app at boot (WinPE) and on the desktop to choose rollback / continue / merge, plus a new "intermediate" snapshot level; desktop version schedules actions for the next boot; a mode that always auto-rolls back with no GUI.

**Decisions (agreed with Sam before building):**
| Topic | Choice |
|---|---|
| Technology | Native Win32 C (single exe, no runtime dependencies; MinGW-w64) |
| Snapshot depth | One intermediate level: image.vhd <- intermediate.vhd <- snapshot.vhd |
| Boot screen timeout | Countdown then Continue; countdown configurable (default 15 s, 0 = wait forever) |
| Who can use the desktop app | Anyone, via a SYSTEM service (named pipe, Authenticated Users read/write) |
| Modes | gui (default after firstrun), autorollback, automerge, direct (skip WinPE) |
| Auto target | Configurable: intermediate (default, if present) or base |
| WinPE extras | Command prompt button, chain sizes/dates, shut-down-after option, history log |
| Old noauto/automerge/debugmode/bcddefault | Removed |
| Branding | Image-O-Tron 11,000 banners: red in WinPE, blue on the desktop |

**Files:**
- `srsmgr\srsmgr.c` (source), `srsmgr.rc`, `resource.h`, `srsmgr.manifest` (asInvoker, dpiAware, no comctl32 v6 dependency so it always starts in WinPE), `styles.manifest` (comctl32 v6, activated at runtime only if present), `banner_blue.bmp`/`banner_red.bmp` (760x170 crops of Sam's logos), `srsmgr.ico`, `build.sh`.
- `srsmgr.exe` (built, about 1MB, mostly the banners). Imports only ADVAPI32, COMCTL32, GDI32, KERNEL32, msvcrt, SHELL32 and USER32, all of which are present in WinPE.
- **Removed:** bcddefault.cmd, rollback.cmd, merge.cmd, debugmode.cmd, hooks\1000-rollback.cmd (the bcddefault scheduled task).
- **startnethd.cmd:** keeps the drive-letter discovery; everything after `:vhdcheck` now runs `start /wait X:\srs\srsmgr.exe /pe /phy <P:> /store "<EFI>\EFI\Microsoft\Boot\BCD"`. Exit code 0 = `wpeutil reboot`, 1 = `wpeutil shutdown`, anything else = maintenance prompt (also used if the exe is missing or crashes).
- **firstrun.cmd:** runs `srsmgr /install` (installs and starts the service, creates srs.ini with mode=gui, sets the boot entries) and creates "Image-O-Tron 11,000" shortcuts on the Public Desktop and in the Start menu.
- **buildpe / prepnewpc:** copy srsmgr.exe into the stick's and the VHD's \srs.
- **restore2disk:** also deletes the SrsMgr service from the offline SYSTEM hive.
- **hooks-samples 9900/9901:** now `srsmgr /schedule rollback|merge /now` as SYSTEM scheduled tasks.
- **README:** Image-O-Tron section (chain, actions, modes, settings/logs, CLI, boot-entry logic). The Directives and Operating Modes sections are removed.

**Boot-entry logic:** the default is "Roll Back Windows" in every mode except direct. After an action, WinPE sets a one-time `bootsequence` into the snapshot entry, so crashes and power cuts return to the boot manager. In direct mode the default is the snapshot, and scheduling sets a one-time bootsequence into WinPE. The service re-applies this at every Windows start (replacing the old bcddefault task). The snapshot entry is created by WinPE if it's missing.

**Actions (WinPE, diskpart):** files are only deleted after the preceding merge/create succeeded. promote = rename snapshot->intermediate, then create a new snapshot (the rename is undone if the create fails). merge_base with an intermediate = merge snapshot->intermediate, then intermediate->image, then recreate. A scheduled action that fails is cleared (and logged) so it isn't retried on every boot.

**Testing done here (Wine 9 + Xvfb, with stand-in diskpart.exe/bcdedit.exe that log calls and create files):**
- PE screen and desktop screen render correctly (screenshots checked).
- Scenarios pass: initial snapshot, promote, merge_base with intermediate + shutdown (exit 1), autorollback to intermediate, autorollback to base, automerge, direct/continue, invalid pending (fails safely). Simulated diskpart failures leave all files intact; a failed promote restores the snapshot name.
- Service install/start under Wine's SCM, pipe STATUS/SCHEDULE/SET/CANCEL, the CLI, and validation of bad values.
- Found and fixed during testing: Wine can't open files via `\\?\Volume{}` paths, so the service now prefers the volume's drive letter (real Windows supports both); a failed pending action was retried on every boot (fixed); the desktop window was clipped (fixed).

**Not testable here:** real diskpart/bcdedit, native VHD boot, WinPE itself, UAC/SmartScreen. The exe is unsigned. bcdedit output is parsed in English (identifier/description/device); a non-English Windows display language would need the parser extended.

**Upgrade path for an already-deployed PC:** easiest is to rebuild the stick and redeploy. Otherwise (elevated, in Windows): copy srsmgr.exe to C:\srs, delete the old `bcddefault` scheduled task, run `C:\srs\srsmgr.exe /install`, then copy srsmgr.exe and the new startnethd.cmd (as Windows\System32\startnet.cmd) onto the SrS_Tools partition. Merge so the change sticks.

## 2026-10-15 - srsmgr UI fixes from Sam's first real-Windows run

**Reported (screenshot from Sam's PC):** button labels clipped ("Merge snapshot into intermediat"), the third disk-chain row cut off with a scrollbar, and the status message truncated with "...". Real Segoe UI is wider, and real ListView rows are taller, than in the Wine test.
**Fix (srsmgr.c):** button font 15 -> 13 px semibold; disk-chain list 86 -> 104 px (group 118 -> 136); status text wraps over two lines instead of being ellipsised; windows 20 px taller (PE 592, desktop 620).
The "(none)" chain and the "service isn't running and this program isn't elevated" message are expected on a PC without Steadier State deployed.

## 2026-10-15 - Whole-project review: fixes

**Request (Sam):** scan the whole project for issues, then fix them all. Three independent reviewers covered srsmgr.c, the WinPE/deploy scripts, and the Windows-side scripts/hooks/docs; the main claims were checked against the code before fixing.

### srsmgr.c
| Issue | Fix |
|---|---|
| Pipe reachable from the network (any domain user could force a rollback + restart) | `PIPE_REJECT_REMOTE_CLIENTS`; SDDL now denies Network (NU) and allows Interactive users (IU) instead of Authenticated Users; restart no longer force-closes apps (15 s, `bForceAppsClosed=FALSE`) |
| diskpart/bcdedit started without a path from a SYSTEM service (exe-folder hijack) | Always `GetSystemDirectory()\tool.exe` (also cmd, notepad) |
| One silent client could block the service; pipe name could be squatted | Pipe created first at service start with `FILE_FLAG_FIRST_PIPE_INSTANCE`, kept open and reused; overlapped I/O with a 5 s read timeout; stop event. Client checks `GetNamedPipeServerProcessId` == the SrsMgr service PID (SQOS identification) |
| Boot entries found by parsing English bcdedit output | Fixed GUIDs: Roll Back Windows `{5d0c6a10-1e5b-4c7e-9a7d-511f0a11b001}` (prepnewpc), snapshot `{...b002}` (srsmgr). Found with `bcdedit /enum {guid}` exit code. Parsing kept only as a fallback for older deployments |
| Physical Drive chosen by label only (a USB stick labelled Physical_Drive would be used) | Prefer the volume hosting the running VHD (`GetStorageDependencyInformation`, loaded dynamically from virtdisk.dll); else the first FIXED volume with the label. Refuse `\srsdirectives` if it's a reparse point |
| srs.ini deleted then rewritten on every boot (power cut = lost settings) | Temp file + `MoveFileEx(REPLACE_EXISTING, WRITE_THROUGH)`; WinPE only rewrites when a pending action has to be cleared |
| merge_base in two steps could leave the intermediate half-changed | Single `merge vdisk depth=2` (depth=1 without an intermediate) |
| "No files have been deleted" shown even after a snapshot was deleted | Tracks deletions; tells the user to roll back to rebuild the snapshot |
| Snapshot boot entry set-up errors ignored (half-built entry as default, no menu) | Every `/set` checked; entry deleted on failure; `bcd_apply` returns success; WinPE won't restart if the boot entries couldn't be set; Straight to Windows uses a 2 s boot menu |
| Strings could be left unterminated | All formatting via `sfmt()` / `scpy()` (always NUL-terminated); config zeroed |
| Non-numeric countdown silently meant "wait forever" | Validated (digits, 0-600) in the service, the PE settings and srs.ini |
| Hand-edited `pending=initial`/`continue` accepted | `is_schedulable()` everywhere; unknown mode/autotarget/after values fall back to defaults |
| Window taller than small/scaled screens | Layout scales down to the work area |
| `/install` returned success when the service didn't start, the drive wasn't found or the boot entries weren't set | Returns 1 in all those cases, so firstrun stops |

### Scripts
- **buildpe:** removed the leftover duplicate `:errorcheck` block (it ran a second, failing ISO build every time); renamed the duplicate `:background` label; log folder falls back to %TEMP% (it used to "continue anyway" and then fail); ISO folder created if OneDrive moved Documents; files check now includes restore2disk.cmd and the background JPGs.
- **prepnewpc:** refuses the disk holding the boot media by drive letter (it used to check only the WINPE label); asks for confirmation when the media was found without a WINPE label; handles a VHD volume WinPE already gave a letter; creates Roll Back Windows with the fixed GUID; sets the master entry via `{default}` instead of parsing.
- **restore2disk:** detects the boot media and refuses its disk.
- **cvt2vhd:** empty VHD-size answer no longer crashes; offers to delete a leftover image.wim; detaches a half-made image.vhd on failure.
- **firstrun:** locks `C:\srs` (SYSTEM + Administrators full, Users read/execute, by SID) **before** `srsmgr /install`, and locks the Physical Drive root (removes Authenticated Users/Everyone).
- **hooks/1110-security:** SIDs instead of English names; keeps Users read/execute on C:\srs; srsdirectives SYSTEM + Administrators only; rewritten without icacls inside ( ) blocks.
- **hooks-samples/1101-nightlyrestartmaster:** rewritten to schedule `rollback_base` before booting the master (booting image.vhd invalidates the children). **9902-bcddefaultmaster removed** (it could corrupt the chain). 1100's comment updated.
- **setbackground:** `attrib -r` on boot.wim before mounting (copied from the ISO as read-only).
- **prepref:** empty build guard; `/i` for y/n answers; BitLocker state via `Get-BitLockerVolume` (language-independent).
- **README:** Phase 0 wording, English-language note (only older deployments and the 1101 sample), CLI `start /wait` note, `/install`/`/uninstall`, new Security section, hooks text. background\README mentions setbackground.cmd. DEVLOG test plan updated.

### Tested here (Wine + stand-in diskpart/bcdedit)
- Regression suite passes: initial (old random GUIDs, and a new fixed-GUID entry with every `/set` checked), promote, merge_base with intermediate via depth=2 + shutdown, autorollback to intermediate and to base, automerge, direct (timeout 2), merge_inter. Hand-edited `pending=initial` is ignored; bad mode/countdown values fall back to defaults; a boot-entry failure after an action keeps the PC on screen instead of restarting.
- Service: install/status/schedule/set/cancel through the hardened pipe; server-PID check passes; bad countdown and `initial` rejected; atomic settings save; a silent client only delays others by the 5 s timeout.
- Window scales to fit a 1024x600 screen.
- All scripts: no missing/duplicate labels, balanced brackets, no unescaped `)` in block echoes, no `(OI)(CI)` inside blocks, CRLF.

**Still only testable on real hardware:** real diskpart/bcdedit/native VHD boot, `GetStorageDependencyInformation` on a VHD-booted system, the pipe ACL with real interactive/RDP logons, icacls on a real Physical Drive.
