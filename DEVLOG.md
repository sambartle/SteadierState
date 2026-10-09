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
| `prepnewpc.cmd` | UEFI only (exits with an explanation on BIOS). **Asks for the disk number**, shows `detail disk`, and refuses the disk holding the WINPE media or image.vhd. Single GPT diskpart script: EFI 260MB (4Kn minimum), MSR 16MB, SrS_Tools 1GB (RE type, hidden), Physical_Drive rest. Checks that image.vhd exists before wiping. Robocopy success is now any rc < 8 (it used to accept only rc==1), with `/J` unbuffered copy. Checks the mounted VHD contains Windows. `bcdboot /f UEFI`, optional `/bootex`. Master entry renamed "Windows 11 (master image)". Detaches the VHD at the end. Fixed `if not %_wiperesponse%==wipe`, which crashed on empty input. |
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
