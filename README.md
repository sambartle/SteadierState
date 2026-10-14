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

**Known limitation: feature updates.** Windows 11 feature updates (for example 24H2 to 25H2) won't install on a native-boot VHD. Monthly cumulative updates work. To move to a new release, update the reference PC and rebuild `image.vhd`. The sample hook `hooks-samples/1200-pinfeatureupdate.cmd` pins the release so Windows Update stops retrying the upgrade.

**Secure Boot certificates (2011 vs 2023 CA).** By default the media and the disk use the standard boot manager signed with the 2011 certificate. If your PCs have had the BlackLotus (CVE-2023-24932) revocations applied, `buildpe.cmd` and `prepnewpc.cmd` offer to use the boot manager signed with "Windows UEFI CA 2023" (`/bootex`) when your ADK and image support it. Only choose that on PCs that already trust the 2023 CA.

## Instructions
There are five phases (phase 0 is new for Windows 11):

### Phase 0 -- Prepare the Windows 11 reference PC.
  1. Set up the reference PC with Windows 11 Pro/Enterprise/Education, apps and settings the way you want them.
  2. Copy this repository to it, open a Command Prompt **as an Administrator** and run `prepref.cmd`.
  3. `prepref.cmd` checks for UEFI and a supported edition, turns BitLocker/Device Encryption off (and stops it coming back), turns off hibernation and Fast Startup, and then offers to run Sysprep with `Sysprep\unattend-win11.xml`. Sysprep is only needed if you will deploy to *other* PCs.
  4. After Sysprep shuts the PC down, **don't** let it boot Windows again. Go to Phase 2 and boot the USB stick.

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
  2. Customize and make any further desired changes on the PC (see **Directives**, **Hooks**, and **Operating Modes** below).
  3. Open a Command Prompt window **as an Administrator**.
  4. In the Command Prompt window opened in **step 3.**, initiate the SteadierState rollback point with the `c:\srs\firstrun.cmd` command.
  3. Should something go wrong during the `C:\srs\firstrun.cmd` execution, follow the suggestions offered by the error message.
  5. Reboot the PC and the next boot should be to WindowsPE which will perform the final configurations of a snapshot.vhd and a corresponding boot entry.

## Directives
SteadierState target PC's which have completed **Phase 4** are essentially deployment ready. There are times which admins will need to perform some type of maintenance or configuration adjustments on these deployment ready PC's. SteadierState utilizes the local install of WindowsPE and what is called **Directives** to change the default deployment configurations. There are two primary **Directives** "*noauto*" and "*automerge*". To activate **Directives** simply place a file named appropriately ("*noauto.txt*" or "*automerge.txt*") in a directory named `\srsdirectives` on the drive containing the image.vhd and snapshot.vhd. Note: The contents of the **Directives** file does not matter only the name.

### Directive "*noauto*"
The noauto directive tells the WindowsPE install to take no automatic action. To enable the "*noauto*" directive perform the following steps:

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Open a Command Prompt window **as an Administrator**.
  3. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\noauto.txt`.
  4. Reboot the PC and the next boot should be to WindowsPE with the "*noauto*" directive.

### Directive "*automerge*"
The automerge directive tells the WindowsPE install to automerge the image.vhd and the snapshot.vhd to a new image.vhd. To enable the "*automerge*" directive perform the following steps:

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Open a Command Prompt window **as an Administrator**.
  3. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\automerge.txt`.
  4. Reboot the PC and the next boot should be to WindowsPE with the "*automerge*" directive.


### Directive Examples
To provide an understanding of how these **Directives** can be used please examine the following examples.

#### Example: How can I boot my SteadierState PC to WindowsPE for diagnostics image running "*Roll Back Mode*"?

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Boot the PC up which will be in the pristine state of deployment.
  3. Apply the configuration adjustments desired.
  4. Open a Command Prompt window **as an Administrator**.
  5. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\noauto.txt`.
  6. Reboot the PC and the next boot should be to WindowsPE with the "*noauto*" directive.

#### Example: How can I boot my SteadierState PC to WindowsPE for diagnostics image running "*Delta Mode*"?

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Boot the PC up which will be in the pristine state of deployment.
  3. Apply the configuration adjustments desired.
  4. Open a Command Prompt window **as an Administrator**.
  5. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\noauto.txt`.
  6. In the Command Prompt window opened in **step 3.**, run the following command `C:\srs\bcddefault.cmd`.
  7. Reboot the PC and the next boot should be to WindowsPE with the "*noauto*" directive.

#### Example: How can I upgrade my SteadierState PC base image running "*Roll Back Mode*"?

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Boot the PC up which will be in the pristine state of deployment.
  3. Apply the configuration adjustments desired.
  4. Open a Command Prompt window **as an Administrator**.
  5. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\automerge.txt`.
  6. Reboot the PC and the next boot should be to WindowsPE with the "*automerge*" directive.

#### Example: How can I upgrade my SteadierState PC base image running "*Delta Mode*"?

  1. Assume that D: is the drive containing the image.vhd, snapshot.vhd, and the \srsdirectives folder.
  2. Boot the PC up which will be in the pristine state of deployment.
  3. Apply the configuration adjustments desired.
  4. Open a Command Prompt window **as an Administrator**.
  5. In the Command Prompt window opened in **step 3.**, run the following command `echo > D:\srsdirectives\automerge.txt`.
  6. In the Command Prompt window opened in **step 3.**, run the following command `C:\srs\bcddefault.cmd`.
  7. Reboot the PC and the next boot should be to WindowsPE with the "*automerge*" directive.

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
| `1000-rollback.cmd` | Scheduled task that makes every reboot go to "Roll Back Windows" (Roll Back Mode). |
| `1050-win11-vhdboot.cmd` | **New.** Sets `PreventDeviceEncryption`, turns off hibernation and Fast Startup. |
| `1100-registrynodrives.cmd` | Hides the Physical Drive in Explorer. **Fixed:** it used to write the wrong bitmask for E: onwards. |
| `1110-security.cmd` | Locks down `C:\srs` and `\srsdirectives`. |

`hooks-samples/1100-removewindows10bootentry.cmd` has been replaced by `1100-removemasterbootentry.cmd`, which matches the `image.vhd` entry rather than the text "Windows 10". `1200-pinfeatureupdate.cmd` is new (see the feature update limitation above).

## Operating Modes
SteadierState with the new first run hooks model can now offer two primary "*modes*" **Roll Back Mode** (the default) and **Delta Mode** which are described below.

### **Roll Back Mode**
  * The default deployment "*mode*" of SteadierState with the default set of first run hooks enabled when the `C:\srs\firstrun.cmd` command is ran on a target PC. Essentially this "*mode*" "*Rolls Back*" any changes that were made since the last reboot.

### **Delta Mode**
  * The deployment "*mode*" of SteadierState with the default hook of `hooks\1000-rollback.cmd` removed from the hooks folder prior to running the `C:\srs\firstrun.cmd` command on a target PC. Essentially this "*mode*" allows the target PC to run on the snapshot.vhd in **Delta Mode** without rolling back at reboot until instructed otherwise.
