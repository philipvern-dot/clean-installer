; Builds clean_installer.exe, the setup program attached to a GitHub Release.
; Compile with Inno Setup 6:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" CleanInstaller.iss

#define AppVersion "1.0.0"
#define Repo ".."

[Setup]
AppId={{6BBC5244-7556-4C5F-A3DF-C3DC731465B8}
AppName=Clean Installer
AppVersion={#AppVersion}
AppPublisher=Clean Installer
AppCopyright=Copyright (c) 2026 Philip Miller
DefaultDirName={localappdata}\Programs\Clean Installer
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#Repo}
OutputBaseFilename=clean_installer
Compression=lzma2
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
Uninstallable=yes
UninstallDisplayName=Clean Installer
SetupIconFile={#Repo}\ci-icon.ico
UninstallDisplayIcon={app}\ci-icon.ico
VersionInfoVersion=1.0.0.0
VersionInfoProductName=Clean Installer
VersionInfoCompany=Clean Installer
VersionInfoDescription=Installs Clean Installer
CloseApplications=yes

[Files]
Source: "{#Repo}\app\CleanInstaller.ps1"; DestDir: "{app}\app"
Source: "{#Repo}\app\Engine.ps1"; DestDir: "{app}\app"
Source: "{#Repo}\app\launch.vbs"; DestDir: "{app}\app"
Source: "{#Repo}\app\version.txt"; DestDir: "{app}\app"
Source: "{#Repo}\app\data\known_problem.json"; DestDir: "{app}\app\data"
Source: "{#Repo}\LICENSE"; DestDir: "{app}"
Source: "{#Repo}\ci-icon.ico"; DestDir: "{app}"

[Tasks]
Name: startmenuicon; Description: "Create a Start menu shortcut"; GroupDescription: "Shortcuts:"; Flags: checkedonce
Name: desktopicon; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Icons]
Name: "{autoprograms}\Clean Installer"; Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\app\launch.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ci-icon.ico"; Comment: "Install and uninstall programs with winget"; Tasks: startmenuicon
Name: "{autodesktop}\Clean Installer"; Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\app\launch.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\ci-icon.ico"; Comment: "Install and uninstall programs with winget"; Tasks: desktopicon

[InstallDelete]
Type: files; Name: "{autoprograms}\Clean Installer.lnk"
Type: files; Name: "{autodesktop}\Clean Installer.lnk"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: "//nologo ""{app}\app\launch.vbs"""; WorkingDir: "{app}"; Description: "Open Clean Installer"; Flags: postinstall nowait skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\Clean Installer.lnk"
