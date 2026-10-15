# SteadierState (Windows 11 / UEFI edition)
This is a modified version of Steadier State, updated for **Windows 11** on **64-bit UEFI** PCs. It is based on the Windows 10 port at https://github.com/7heMC/SteadierState, which in turn is based on the original work by Mark Minasi (steadierstate.com).

Steadier State boots Windows from a differencing VHD (`snapshot.vhd`) whose parent is a read-only master (`image.vhd`). Rolling back simply throws the snapshot away and makes a new empty one from WinPE on a small hidden partition.

## Windows 11 requirements (read first)

| Requirement | Why |
|---|---|
| UEFI boot (CSM/Legacy off) | This edition is UEFI/GPT only. Secure Boot can stay **on**. |
| Windows 11 **Pro, Enterprise or Education** | Native boot from VHD is not available on Home. `cvt2vhd` refuses Home images. |
| BitLocker / Device Encryption **fully off** on the reference PC | 24H2+ turns Device Encryption on automatically. Encrypted drives can't be captured, and BitLocker isn't supported for a native-boot VHD or the volume that hosts it. `prepref.cmd` decrypts and sets `PreventDeviceEncryption`. |
| Hibernation / Fast Startup off | Not supported when booting from a VHD. |
| Windows ADK for Windows 11 **plus** the separate WinPE add-on | Needed by `buildpe.cmd`. 64-bit only (the current ADK has no x86 WinPE). |
| Target disk free space of about 2.5x the VHD maximum size | Native-boot VHDs expand to their full size at boot. |
| English display language (only for PCs deployed **before** the Image-O-Tron fixed boot-entry IDs, and for the 1101 sample hook) | Those find boot entries by reading `bcdedit`'s English output. Everything else uses fixed IDs or language-independent checks. |

**Known limitation: feature updates.** Windows 11 feature updates (for example 24H2 to 25H2) won't install on a native-boot VHD. Monthly cumulative updates work. To move to a new release, update the reference PC and rebuild `image.vhd`. The sample hook `hooks-samples/1200-pinfeatureupdate.cmd` pins the release so Windows Update stops retrying the upgrade.

**Secure Boot certificates (2011 vs 2023 CA).** By default the media and the disk use the standard boot manager signed with the 2011 certificate. If your PCs have had the BlackLotus (CVE-2023-24932) revocations applied, `buildpe.cmd` and `prepnewpc.cmd` offer to use the boot manager signed with "Windows UEFI CA 2023" (`/bootex`) when your ADK and image support it. Only choose that on PCs that already trust the 2023 CA.

## Instructions
There are five phases (phase 0 is new for Windows 11):

### Phase 0 -- Prepare the Windows 11 reference PC.
  1. Set up the reference PC with Windows 11 Pro/Enterprise/Education, apps and settings the way you want them.
  2. Copy this repository to it, open a Command Prompt **as an Administrator** and run `prepref.cmd`.
  3. `prepref.cmd` checks for UEFI and a supported edition, turns BitLocker/Device Encryption off (and stops it coming back), turns off hibernation and Fast Startup, and then offers to run Sysprep with `Sysprep\unattend-win11.xml`. Sysprep is only needed if you will deploy to *other* PCs.
  4. After Sysprep shuts the PC down, **don't** let it boot Windows again. Build the USB stick (Phase 1) if you haven't already, then go to Phase 2 and boot the stick.

### Phase 1 -- Install and build the SteadierState live media toolchain.
  Note: This phase requires a usb flashdrive. **Warning: All data on the usb flashdrive used with this phase will be lost!**

  1. Clone the SteadierState repository **or** Download and Extract zip file from the github.com repository.
  2. Open a Command Prompt window **as an Administrator**.
  3. Change to the directory where you "*Clone **or** Download and Extract zip file*" in step 1.
  4. Initiate the toolchain build by running the `buildpe.cmd` command. Upon running the `buildpe.cmd` command you will be prompted for input to produce a bootable usb key (and if desired an .iso file).
  5. When the `buildpe.cmd` has completed, if all went well, you will have a bootable usb key (and if requested an .iso file).
  6. Should something go wrong during the `buildpe.cmd` execution, follow the suggestions offered by the error message.

### Phase 2 -- Create a SteadierState installable setup.
  Note: This phase requires an external drive or network drive to hold deployment files.

  1. Boot the live media created in **Phase 1** (in UEFI mode) on the reference PC prepared in **Phase 0**.
  2. Initiate the creation of the SteadierState installable setup with the `cvt2vhd.cmd` command. Upon running the `cvt2vhd.cmd` command you will be prompted for input to produce the everything needed for deployment.
  3. Should something go wrong during the `cvt2vhd.cmd` execution, follow the suggestions offered by the error message.
  3. Reboot the computer by typing `exit`.

### Phase 3 -- Deploy SteadierState to a PC.
  Note: **Warning: This phase will erase all files on the disk you choose on the target PC!** `prepnewpc.cmd` lists the disks and asks for the disk number (it no longer assumes disk 0, which on NVMe PCs can be the USB stick). It refuses the disk holding the boot media or `image.vhd`.

  1. Boot the live media created in **Phase 1** (in UEFI mode) on a PC you wish to deploy with SteadierState.
  2. Initiate the deployment of SteadierState to the PC with the `prepnewpc.cmd` command. Upon running the `prepnewpc.cmd` command you will be prompted for input to perform the installation of SteadierState to the PC.
  3. Should something go wrong during the `prepnewpc.cmd` execution, follow the suggestions offered by the error message.
  3. Reboot the computer by typing `exit`.

### Phase 4 -- Finalize the SteadierState deployment on the PC.

  1. Boot the PC which you deployed with SteadierState in **Phase 3**.
  2. Customize and make any further desired changes on the PC (see **Image-O-Tron** and **Hooks** below).
  3. Open a Command Prompt window **as an Administrator**.
  4. In the Command Prompt window opened in **step 3.**, initiate the SteadierState rollback point with the `c:\srs\firstrun.cmd` command.
  3. Should something go wrong during the `C:\srs\firstrun.cmd` execution, follow the suggestions offered by the error message.
  5. Reboot. `firstrun` has installed the Image-O-Tron service and app, so the next boot goes to the on-disk WinPE, which creates `snapshot.vhd` and its boot entry and starts Windows. From then on the Image-O-Tron boot screen appears on every boot (the default mode).

## Image-O-Tron 11,000 (rollback manager)

`srsmgr.exe` replaces the old `noauto.txt` / `automerge.txt` directives, `rollback.cmd`, `merge.cmd`, `bcddefault.cmd` and `debugmode.cmd`. It's a single native program (source in `srsmgr\`, build with `srsmgr\build.sh`) that runs in three places:

| Where | Look | What it does |
|---|---|---|
| On-disk WinPE, every boot (launched by `startnet.cmd`) | Red banner | Shows the disk chain, counts down, and runs the chosen action |
| Windows desktop (shortcut "Image-O-Tron 11,000") | Blue banner | Schedules an action for the next boot, changes the boot mode, shows history |
| `SrsMgr` Windows service (installed by `firstrun`) | - | Does the privileged parts for the desktop app, so **any user** can use it, and keeps the boot entries in step with the mode at every start |

### The disk chain

`image.vhd` (base) &larr; `intermediate.vhd` (optional, one level) &larr; `snapshot.vhd` (what Windows runs on)

| Action | Effect |
|---|---|
| Continue | Boot the snapshot unchanged (WinPE only) |
| Roll back to intermediate | Discard the snapshot, new empty snapshot on the intermediate |
| Roll back to base | Discard the snapshot **and** the intermediate, new empty snapshot on image.vhd |
| Merge snapshot into intermediate | Keep the changes permanently in intermediate.vhd |
| Merge all into base | Keep everything permanently in image.vhd (intermediate too) |
| Make snapshot the intermediate | The current snapshot becomes the intermediate baseline, with a fresh snapshot on top (only when there's no intermediate yet) |

Merges and rollbacks ask for confirmation. If a step fails, no files are deleted and the error is shown (and logged).

### Boot modes

| Mode | Every boot... |
|---|---|
| **Show this screen on every boot** (default) | WinPE shows the boot screen; after the countdown (default 15 s, configurable, 0 = wait forever) it continues into Windows unchanged |
| **Always roll back automatically** | Rolls back silently (the original Steadier State behaviour) |
| **Always merge automatically** | Keeps the changes silently |
| **Straight to Windows** | Skips WinPE entirely (fastest boot). Actions scheduled from the desktop app still run on the next boot. Good for debugging drivers etc. |

"Automatic modes act on": **Intermediate** (if there is one, else the base) or always **Base**. A scheduled action always runs silently on the next boot, whatever the mode, and can be followed by a shutdown instead of starting Windows.

### Settings and logs (on the Physical Drive)

* `\srsdirectives\srs.ini`: mode, autotarget, countdown, pending action. Edited by the app; commented if you want to edit it by hand.
* `\srsdirectives\history.log`: every action, when, where and the result ("History" button in both versions).
* `\srsdirectives\srsmgr-last.log`: the full diskpart/bcdedit output of the last operation, for troubleshooting.

### Command line (scripts, hooks, scheduled tasks)

```
C:\srs\srsmgr.exe /status
C:\srs\srsmgr.exe /schedule <rollback|merge|rollback_inter|rollback_base|merge_inter|merge_base|promote> [/shutdown] [/now]
C:\srs\srsmgr.exe /cancel
C:\srs\srsmgr.exe /set mode <gui|autorollback|direct|automerge>
C:\srs\srsmgr.exe /set autotarget <intermediate|base>
C:\srs\srsmgr.exe /set countdown <seconds 0-600, 0 = wait forever>
C:\srs\srsmgr.exe /install | /uninstall      (elevated)
```

`rollback` and `merge` go to the intermediate if there is one (and autotarget isn't `base`), otherwise to the base. `/now` restarts straight away (other users get 15 seconds and the chance to save).

`srsmgr.exe` is a Windows (GUI) program, so at an **interactive** command prompt use `start /wait C:\srs\srsmgr.exe /status` to see its output and exit code. In batch files and scheduled tasks it works directly.

### Security

* The SrsMgr service only accepts **local** connections from interactively signed-in users (console or RDP); network connections are refused. The app checks it's talking to the real service process.
* `firstrun` makes `C:\srs` and the Physical Drive root writable by SYSTEM and Administrators only (Users can read and run), *before* installing the service, so nobody can swap the exe the service runs. Permissions use SIDs, so they work on any display language.
* The service only uses the volume that hosts the running VHD (or, failing that, a fixed disk) labelled `Physical_Drive`, and refuses a `\srsdirectives` that is a link.
* `diskpart`, `bcdedit`, `cmd` and `notepad` are always started from `System32`.

### How the boot entries are used

Only the **default** boot entry is used (as in the original Steadier State). After any action, including Continue, WinPE makes the snapshot the default so the next boot starts Windows. When Windows starts, the SrsMgr service sets the default back to "Roll Back Windows", so the next restart (or a crash or power cut) goes to the boot manager. The exception is Straight to Windows mode, where the snapshot stays the default unless an action is scheduled.

### Updating srsmgr.exe on a deployed PC

Put the new `srsmgr.exe` next to `srs-update.cmd` and run the script elevated in Windows. It updates both copies (`C:\srs` and the WinPE copy on the hidden SrS_Tools partition) and offers to merge so the update survives rollbacks.

### Going back to a normal install (restore2disk)
Boot the USB stick and run `restore2disk`. It wipes the disk you choose and applies `image.wim` (left by cvt2vhd) or `image.vhd` from an external drive as a normal, non-VHD Windows install.

### WinPE backgrounds
`background\usb.jpg` is the desktop of the USB stick / ISO WinPE, and `background\disk.jpg` is the desktop of the on-disk "Roll Back Windows" WinPE. To change them, replace either JPG and re-run `buildpe.cmd`. To update things that already exist without rebuilding, run `setbackground.cmd` elevated in Windows: it updates this PC's hidden SrS_Tools WinPE (`disk.jpg`) and/or patches `sources\boot.wim` on an existing USB stick (`usb.jpg`).

### Disk layout created by prepnewpc (GPT)

| # | Partition | Size | Purpose |
|---|---|---|---|
| 1 | EFI System (`SYSTEM_UEFI`) | 260 MB | Boot manager and BCD |
| 2 | MSR | 16 MB | Microsoft reserved |
| 3 | `SrS_Tools` (Windows RE type, hidden) | 3 GB | On-disk WinPE: "Roll Back Windows" |
| 4 | `Physical_Drive` | Rest of disk | `image.vhd`, `snapshot.vhd`, `\srsdirectives` |

## Hooks
SteadierState now has a new feature called first run hooks. First run hooks provide users a way to apply custom setting and configurations during **Phase 4** when the `C:\srs\firstrun.cmd` command is ran. Also please remember that the `C:\srs\firstrun.cmd` command in **Phase 4** is disigned to be ran **only once** on a target PC.

### How do first run hooks work?

  First run hooks work like this, there is now a folder called "*C:\srs\hooks\*", in this folder are commands (i.e.hooks) that are executed when the `C:\srs\firstrun.cmd` command is ran. So prior to running the `C:\srs\firstrun.cmd` command, you can provide custom instructions to be ran for your deployment environment.

### How do I write my own first run hook?

  As a starting place take a look at the hooks-samples folder for some ideas on how it works.


### How do I install a first run hook?

  Hooks are enabled by placing them in the `C:\srs\hooks` folder prior to running the `C:\srs\firstrun.cmd`.

### Default hooks (Windows 11 edition)

| Hook | What it does |
|---|---|
| `1050-win11-vhdboot.cmd` | **New.** Sets `PreventDeviceEncryption`, turns off hibernation and Fast Startup. |
| `1100-registrynodrives.cmd` | Hides the Physical Drive in Explorer. **Fixed:** it used to write the wrong bitmask for E: onwards. |
| `1110-security.cmd` | Locks `\srsdirectives` to SYSTEM + Administrators and re-applies the `C:\srs` permissions (Users keep read/execute so the app runs). Uses SIDs. |

`hooks-samples/1100-removewindows10bootentry.cmd` has been replaced by `1100-removemasterbootentry.cmd`, which matches the `image.vhd` entry rather than the text "Windows 10". `1200-pinfeatureupdate.cmd` is new (see the feature update limitation above). `9900-nightlyreset` and `9901-nightlymerge` now use `srsmgr /schedule rollback|merge /now`. The old `1000-rollback.cmd` hook (the `bcddefault` scheduled task) is gone; the SrsMgr service does that job and the boot mode replaces Roll Back/Delta Mode. `1101-nightlyrestartmaster` boots the master image nightly so it can take updates: it first schedules `rollback_base`, because booting `image.vhd` invalidates the snapshot and any intermediate, so they must be rebuilt (any intermediate is discarded every night). The old `9902-bcddefaultmaster` sample was removed: making the master the permanent default could corrupt the chain.
