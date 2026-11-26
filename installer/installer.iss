[Setup]
AppId={{B7E2D1C4-9A3F-4C8E-A1D2-3F4E5A6B7C8D}
AppName=ChameleonConsole
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\ChameleonConsole
OutputBaseFilename=ChameleonConsole_Setup_{#MyAppVersion}
OutputDir=..
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=none
DisableProgramGroupPage=yes
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "..\clap_skeleton.clap"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\clap_skeleton.vst3"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{app}\Assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\ChameleonConsole Readme"; Filename: "{app}\README.md"