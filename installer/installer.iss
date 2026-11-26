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

[Types]
Name: "full"; Description: "Full (CLAP + VST3)"
Name: "clap"; Description: "CLAP only"
Name: "vst3"; Description: "VST3 only"
Name: "custom"; Description: "Custom"; Flags: iscustom

[Components]
Name: "clap"; Description: "CLAP plugin (with artwork)"; Types: full clap custom
Name: "vst3"; Description: "VST3 plugin"; Types: full vst3 custom

[Tasks]
Name: "clean"; Description: "Clean install (remove the previous version first)"

[Files]
; CLAP plugin + its assets (assets must sit next to the .clap for DllDir)
Source: "..\ChameleonConsole.clap"; DestDir: "{code:GetCLAPDir}"; Components: clap; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{code:GetCLAPDir}\Assets"; Components: clap; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\README.md"; DestDir: "{code:GetCLAPDir}"; Components: clap; Flags: ignoreversion
; VST3 proxy goes to its own standard folder
Source: "..\ChameleonConsole.vst3"; DestDir: "{code:GetVST3Dir}"; Components: vst3; Flags: ignoreversion
Source: "..\Assets\*"; DestDir: "{code:GetVST3Dir}\Assets"; Components: vst3; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
{ Per-user (no admin) or system-wide (admin), chosen via the standard
  all-users / just-me dialog. Uses only confirmed Inno constants:
  commonpf64 is C:\Program Files (64-bit); append the literal Common Files. }
{ Clean install: remove the previous version first (only when the
  clean task is selected). Runs after the tasks page. }
procedure CurStepChanged(CurStep: TSetupStep);
var
  RegKey: String;
  UninstallPath: String;
  ResultCode: Integer;
begin
  if (CurStep = ssInstall) and WizardIsTaskSelected('clean') then
  begin
    RegKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + ExpandConstant('{#SetupSetting("AppId")}') + '_is1';
    if not RegQueryStringValue(HKEY_LOCAL_MACHINE, RegKey, 'UninstallString', UninstallPath) then
      RegQueryStringValue(HKEY_CURRENT_USER, RegKey, 'UninstallString', UninstallPath);
    if UninstallPath <> '' then
    begin
      UninstallPath := RemoveQuotes(UninstallPath);
      Exec(UninstallPath, '/SILENT /NORESTART /SUPPRESSMSGBOXES', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
      Sleep(1000);
    end;
  end;
end;

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