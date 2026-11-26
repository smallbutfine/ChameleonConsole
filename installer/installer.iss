[Setup]
AppId={{B7E2D1C4-9A3F-4C8E-A1D2-3F4E5A6B7C8D}
AppName=ChameleonConsole
AppVersion={#MyAppVersion}
DefaultDirName={code:GetCLAPDir}
OutputBaseFilename=ChameleonConsole_Setup_{#MyAppVersion}
OutputDir=..
PrivilegesRequired=none
PrivilegesRequiredOverridesAllowed=dialog
DisableDirPage=no
DisableProgramGroupPage=yes
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Files]
; CLAP plugin + its assets (assets must sit next to the .clap for DllDir)
Source: "..\clap_skeleton.clap"; DestDir: "{code:GetCLAPDir}"; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{code:GetCLAPDir}\Assets"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{code:GetCLAPDir}"; Flags: ignoreversion
; VST3 proxy goes to its own standard folder
Source: "..\clap_skeleton.vst3"; DestDir: "{code:GetVST3Dir}"; Flags: ignoreversion

[Icons]
Name: "{group}\ChameleonConsole Readme"; Filename: "{app}\README.md"

[Code]
{ Per-user (no admin) or system-wide (admin), chosen via the standard
  all-users / just-me dialog. Uses only confirmed Inno constants:
  commonpf64 is C:\Program Files (64-bit); append the literal Common Files. }
function GetCLAPDir(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := ExpandConstant('{commonpf64}') + '\Common Files\CLAP\ChameleonConsole'
  else
    Result := ExpandConstant('{localappdata}') + '\Programs\Common\CLAP\ChameleonConsole';
end;

function GetVST3Dir(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := ExpandConstant('{commonpf64}') + '\Common Files\VST3'
  else
    Result := ExpandConstant('{localappdata}') + '\Programs\Common\VST3';
end;