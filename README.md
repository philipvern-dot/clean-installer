# Clean Installer

Version 1.0.0.

A Windows window for installing and uninstalling programs with [winget](https://learn.microsoft.com/windows/package-manager/winget/). Search the catalog, see what is installed, upgrade, uninstall, and then review anything the uninstaller left behind. Every action writes the command it ran into the activity box.

This is not an official Microsoft product. It runs `winget`. It does not replace it.

## Open it

Double-click `Clean Installer.lnk` in this folder. The shortcut starts `app\launch.vbs`, which opens the window with Windows PowerShell.

You need:

- 64-bit Windows 10 or 11
- `winget`, which comes with **App Installer** from the Microsoft Store

If `winget` is missing, the window says so. Install App Installer, then open Clean Installer again.

## What you can do

- **Search** finds catalog packages. Type at least two characters.
- **Installed** lists everything winget can see, including Windows inventory entries.
- **Updates** lists packages winget knows how to upgrade. **Upgrade all** asks first.
- **Suspects** flags known problem or trial software, and programs with no recorded launches for the months chosen beside **Flag after not used for**. That choice only changes this list. Windows only records when you launch a program yourself, not when another program runs a tool in the background. Known dependencies such as FFmpeg are left off this unused list. Other background programs can still look unused. Steam games, runtimes, and GPU or chipset drivers are left out. The list does not remove anything by itself.
- **Install** uses `winget install --id --exact` for a catalog package.
- **Uninstall** removes the program, then shows registry keys and folders that still look like it. Nothing on that list is removed until you tick it and choose **Remove selected**. Folders go to the Recycle Bin. Registry keys are deleted. After a successful uninstall, matching Add/Remove Programs keys start ticked. Folders start unticked. A known dependency such as FFmpeg asks you to confirm first: a missing launch does not mean it is unused, and removing it can break programs that run it in the background.
- **Auto-accept agreements and install quietly** is off until you turn it on. On, install and upgrade accept package agreements and run silent. Uninstall runs silent without the package-agreement flag, because winget rejects that flag. Off, those commands open a console so you can answer the installer.

Settings are saved in `app\settings.json`.

The bottom right corner shows this copy's version. The program checks for a newer version when it opens. **Check for updates** looks again. When a newer version is found, a window tells you once. Closing that window keeps it from opening again until a later version is published. The status line keeps saying that version is available. **Update** downloads it and opens the setup program. The setup replaces the installed copy and keeps your settings. Finish or cancel the current job before you update. The program closes while the setup runs.

Every button has a tooltip, including a button that is grayed out. **Donate** opens a tip page. The program stays free. **Report a bug** opens a GitHub page with this version and the Windows version filled in. Include latest activity is optional. Leave it unchecked and nothing else is added.

## Setup

`clean_installer.exe` installs Clean Installer for the current user. During setup you can choose a Start menu shortcut and a desktop shortcut separately. Setup also registers an uninstall entry in Windows Settings. The setup program does not include winget. Install App Installer from the Microsoft Store if `winget` is missing.

## What is in this folder

- `app\CleanInstaller.ps1` is the window.
- `app\Engine.ps1` reads winget output, finds leftovers, and keeps the safety rules.
- `app\data\known_problem.json` is the Suspects hint list.
- `app\launch.vbs` starts the window.
- `app\version.txt` is the version.
- `installer\CleanInstaller.iss` builds the setup program.
- `ci-icon.ico` is the window, taskbar, and shortcut icon.

## Support

Clean Installer is free and always will be.

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/philipvern)

- **Tips:** welcome at [ko-fi.com/philipvern](https://ko-fi.com/philipvern). Pick $1, $2, $5, or a custom amount. A tip of $5 or more can include a feature suggestion.
- **Bugs:** Report a bug in the program opens a GitHub page with this version and the Windows version filled in. Include latest activity is optional. You can also [open an issue](https://github.com/philipvern-dot/clean-installer/issues).
- **Commissions:** I'm open to them. Reach out through Ko-fi.

## License

This program is released under the MIT License. See [LICENSE](LICENSE).
