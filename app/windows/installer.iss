; Inno Setup script of the Windows installer, see build-installer.ps1.
; AppId identifies the app for updates, so it must never change.

#ifndef AppVersion
  #error AppVersion is missing
#endif
#ifndef BuildNumber
  #error BuildNumber is missing
#endif

[Setup]
AppId={{92965AA3-8994-44FA-B374-A4ED087B95A5}
AppName=Kintura
AppVersion={#AppVersion}
AppVerName=Kintura {#AppVersion}
AppPublisher=Kintura
VersionInfoVersion={#AppVersion}.{#BuildNumber}
DefaultDirName={autopf}\Kintura
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\builds
OutputBaseFilename=kintura-{#AppVersion}-{#BuildNumber}-windows-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\kintura.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Kintura"; Filename: "{app}\kintura.exe"
Name: "{autodesktop}\Kintura"; Filename: "{app}\kintura.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\kintura.exe"; Description: "{cm:LaunchProgram,Kintura}"; Flags: nowait postinstall skipifsilent
