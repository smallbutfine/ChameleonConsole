[Setup]
AppId={{B7E2D1C4-9A3F-4C8E-A1D2-3F4E5A6B7C8D}
AppName=ChameleonConsole
AppVersion={#MyAppVersion}
DefaultDirName={localappdata}\Programs\Common\CLAP\ChameleonConsole
OutputBaseFilename=ChameleonConsole_Setup_{#MyAppVersion}
OutputDir=..
PrivilegesRequired=none
DisableDirPage=no
DisableProgramGroupPage=yes
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Files]
; CLAP plugin + its assets (assets must sit next to the .clap for DllDir)
Source: "..\clap_skeleton.clap"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{app}\Assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
; VST3 goes to its own standard folder (proxy that loads the CLAP by ID)
Source: "..\clap_skeleton.vst3"; DestDir: "{localappdata}\Programs\Common\VST3"; Flags: ignoreversion

[Icons]
Name: "{group}\ChameleonConsole Readme"; Filename: "{app}\README.md"