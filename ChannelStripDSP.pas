unit ChannelStripDSP;


interface

uses
  SysUtils, ctypes,
  Math, IniFiles
  {$IFDEF MSWINDOWS}, Windows{$ENDIF}
  {$IFDEF DARWIN}, dl{$ENDIF};

const
  METER_RB_SIZE = 256;
  
  // Port-Indizes (exakt synchronisiert mit der Mono-TTL)
  PORT_IN        = 0;
  PORT_OUT       = 1;
  PORT_CONSOLE   = 2;
  PORT_TRIM      = 3;
  PORT_DRIVE     = 4;
  PORT_HPF       = 5;
  PORT_LPF       = 6;
  PORT_EQ_LO_F   = 7;
  PORT_EQ_LO_G   = 8;
  PORT_EQ_MID_F  = 9;
  PORT_EQ_MID_G  = 10;
  PORT_EQ_HI_F   = 11;
  PORT_EQ_HI_G   = 12;
  PORT_VOLUME    = 16; // ChameleonConsole Port 12 - Output Gain
  PORT_LUX       = 13;
  PORT_GLOSS     = 14;
  PORT_TAPE      = 15;
  NUM_PORTS      = 17;

type
  c_byte = Byte;
  c_uint32 = LongWord;
  c_int32 = LongInt;
  c_uint64 = UInt64;
  c_int64 = Int64;
  c_float = Single;
  c_double = Double;
  PSingle = ^c_float;
  TSampleF = array[0..1048575] of c_float;
  PSampleF = ^TSampleF;
  TMeterRingBuffer = record
    Data: array[0..METER_RB_SIZE - 1] of single;
    ReadIdx, WriteIdx: Integer;
  end;
  PMeterRingBuffer = ^TMeterRingBuffer;

  // --- Zero-Delay Feedback State Variable Filter (ZDF SVF) ---
  TZDF_SVF = record
    ic1eq, ic2eq: Double;
    g, k, a1, a2, a3: Double;
    m0, m1, m2: Double;
  end;

  TDSPInstance = packed record
    SampleRate: double;
    Ports: array[0..NUM_PORTS - 1] of PSingle;
    MeterRB: TMeterRingBuffer;

    // --- ZDF SVF Filter-States ---
    FilterHPF, FilterLPF: TZDF_SVF;
    EQLow, EQMid, EQHigh: TZDF_SVF;
    FilterMode8Bell: TZDF_SVF;

    // --- 2x Oversampling FIR (127 Taps -> 128 Ringpuffer) ---
    FIRCoeffs: array[0..127] of Double;
    UpBuffer: array[0..127] of Double;
    DnBuffer: array[0..127] of Double;
    UpPos, DnPos: Integer;

    // --- First-Order IIR History für HPF/LPF Kaskaden ---
    AlphaHPF1st, AlphaLPF1st: Double;
    HPF_1st_Hist, LPF_1st_Hist: Double;

    // --- Tape Emulation State ---
    TapePhase, TapeHistory: Double;

    // --- Gloss/Lux State ---
    LowGlossState, LuxState: Double;

    // --- Final Slew Limiter ---
    LastSample2x, LastSlew: Double;

    // --- Transformer Hysterese States ---
    TxInputState, TxInterState, TxOutputState: Double;

    // --- VU-Meter RMS State ---
    VU_RMS: Double;
    VU_Value: Double;
    VU_SampleCounter: Integer;
    VU_UpdateInterval: Integer;

    // --- Per-channel analog inaccuracy (age/tolerance drift) ---
    Inaccuracy: Double;   { per-instance random value in [-1,1] }
    RngState: UInt64;     { per-instance PRNG state }
  end;
  PDSPInstance = ^TDSPInstance;

function instantiate_dsp(const descriptor: Pointer; rate: double; bundle_path: PAnsiChar; const features: PPointer): Pointer; cdecl;
procedure connect_port_dsp(instance: Pointer; port: cuint32; data_location: Pointer); cdecl;
procedure run_dsp(instance: Pointer; sample_count: cuint32); cdecl;
procedure cleanup_dsp(instance: Pointer); cdecl;
procedure ReadWriteBarrier; inline;

implementation

// =============================================================================
// HELPER-FUNKTIONEN
// =============================================================================

procedure ReadWriteBarrier; inline;
begin
  System.ThreadSwitch;
end;

// --- ZDF Filter Processing ---
function ProcessZDF(var F: TZDF_SVF; Input: Double): Double; inline;
var
  v1, v2, v3: Double;
begin
  v3 := Input - F.ic2eq;
  v1 := F.a1 * F.ic1eq + F.a2 * v3;
  v2 := F.ic2eq + F.a2 * F.ic1eq + F.a3 * v3;
  F.ic1eq := 2.0 * v1 - F.ic1eq;
  F.ic2eq := 2.0 * v2 - F.ic2eq;
  Result := F.m0 * Input + F.m1 * v1 + F.m2 * v2;
end;

// --- ZDF Filter Setup Functions ---
procedure ClearZDFState(var F: TZDF_SVF); inline;
begin
  F.ic1eq := 0.0;
  F.ic2eq := 0.0;
end;

procedure SetupZDFHPF(var F: TZDF_SVF; Freq, Q, SR: Double);
var g, k: Double;
begin
  g := tan(Pi * Freq / SR);
  k := 1.0 / Q;
  F.a1 := 1.0 / (1.0 + g * (g + k));
  F.a2 := g * F.a1;
  F.a3 := g * F.a2;
  F.m0 := 1.0;
  F.m1 := -k;
  F.m2 := -1.0;
end;

procedure SetupZDFLPF(var F: TZDF_SVF; Freq, Q, SR: Double);
var g, k: Double;
begin
  g := tan(Pi * Freq / SR);
  k := 1.0 / Q;
  F.a1 := 1.0 / (1.0 + g * (g + k));
  F.a2 := g * F.a1;
  F.a3 := g * F.a2;
  F.m0 := 0.0;
  F.m1 := 0.0;
  F.m2 := 1.0;
end;

procedure SetupZDFLowShelf(var F: TZDF_SVF; Freq, GainDB, SR: Double);
var A, g, k: Double;
begin
  A := exp(GainDB * ln(10.0) / 40.0);
  g := tan(Pi * Freq / SR) / sqrt(A);
  k := 1.41421356237;
  F.a1 := 1.0 / (1.0 + g * (g + k));
  F.a2 := g * F.a1;
  F.a3 := g * F.a2;
  F.m0 := 1.0;
  F.m1 := k * (A - 1.0);
  F.m2 := (A * A) - 1.0;
end;

procedure SetupZDFHighShelf(var F: TZDF_SVF; Freq, GainDB, SR: Double);
var A, g, k: Double;
begin
  A := exp(GainDB * ln(10.0) / 40.0);
  g := tan(Pi * Freq / SR) * sqrt(A);
  k := 1.41421356237;
  F.a1 := 1.0 / (1.0 + g * (g + k));
  F.a2 := g * F.a1;
  F.a3 := g * F.a2;
  F.m0 := A * A;
  F.m1 := k * A * (1.0 - A);
  F.m2 := 1.0 - (A * A);
end;

procedure SetupZDFBell(var F: TZDF_SVF; Freq, GainDB, Q, SR: Double);
var A, g, k: Double;
begin
  A := exp(GainDB * ln(10.0) / 40.0);
  g := tan(Pi * Freq / SR);
  k := 1.0 / (Q * A);
  F.a1 := 1.0 / (1.0 + g * (g + k));
  F.a2 := g * F.a1;
  F.a3 := g * F.a2;
  F.m0 := 1.0;
  F.m1 := k * (A * A - 1.0);
  F.m2 := 0.0;
end;

// --- First-Order IIR Alpha Calculation ---
function GetAlpha1stOrd(Freq, SampleRate: Double): Double; inline;
var
  w0: Double;
begin
  w0 := 2.0 * Pi * Freq / SampleRate;
  Result := w0 / (w0 + 1.0);
end;

// --- Half-Band FIR Design für Oversampling ---
procedure DesignHalfBandFIR(var Coeffs: array of Double);
var
  i: Integer;
  x, window: Double;
const
  M = 126;
begin
  for i := Low(Coeffs) to High(Coeffs) do Coeffs[i] := 0.0;
  for i := 0 to M do
  begin
    if i = (M div 2) then
      Coeffs[i] := 0.5
    else
    begin
      x := pi * (i - (M div 2));
      Coeffs[i] := sin(0.5 * x) / x;
      window := 0.42 - 0.5 * cos(2.0 * pi * i / M) + 0.08 * cos(4.0 * pi * i / M);
      Coeffs[i] := Coeffs[i] * window;
    end;
  end;
end;

// --- Transformer Enhancement (Hysterese-Magnetisierungskurve) ---
function ProcessTransformerEnhanced(Input: Double; CoreSat, Asym, Hysteresis: Double; var State: Double): Double; inline;
var
  EffectiveField, AnhysterMagnetization, dM, ClampVal: Double;
begin
  // Effektivfeld = Eingang + Hysterese-Gedächtnis (Coercivity)
  EffectiveField := Input + State * Hysteresis;

  // Anhysteretische Magnetisierung: arctanh-Kern mit CoreSat als Sättigungsparameter
  ClampVal := EffectiveField * CoreSat;
  if ClampVal > 0.99 then ClampVal := 0.99;
  if ClampVal < -0.99 then ClampVal := -0.99;
  AnhysterMagnetization := Arctanh(ClampVal) / CoreSat;

  // Dynamische Permeabilität: dM = 1/(1 + 3*k*M^2) -> sanfter Soft-Clip am Sättigungspunkt
  dM := 1.0 / (1.0 + 3.0 * CoreSat * AnhysterMagnetization * AnhysterMagnetization);

  // Hysteresis-Differentialgleichung: exponentieller Verfall zum Ziel
  State := State + dM * (AnhysterMagnetization - State);

  // Output = M_anhyster mit Asymmetrie-Korrektur für gerade Harmonische
  Result := AnhysterMagnetization + Asym * Sqr(EffectiveField) * Sign(EffectiveField);
end;

// =============================================================================
// SOFT-CLIPPER (3 Versionen) + HARD CLIPPER
// =============================================================================

// gSoftCeilingFactor wird in SoftClipCubic verwendet
const
  gSoftCeilingFactor: Double = 3.981071706; // 10^(12/20)

function SoftClipCubic(Input: Double): Double; inline;
var
  Scaled: Double;
begin
  Scaled := Input / gSoftCeilingFactor;
  if Scaled > 1.0 then
    Scaled := 2.0 / 3.0
  else if Scaled < -1.0 then
    Scaled := -2.0 / 3.0
  else
    Scaled := Scaled - (Scaled * Scaled * Scaled / 3.0);
  Result := Scaled * gSoftCeilingFactor;
end;

function HardClip(Input: Double): Double; inline;
const
  CEILING = 0.944060876; // -0.5 dBFS
begin
  if Input > CEILING then
    Result := CEILING
  else if Input < -CEILING then
    Result := -CEILING
  else
    Result := Input;
end;

// =============================================================================
// VU-Meter RMS-Berechnung (Exponential Approximation)
// =============================================================================

const
  // VU-Ballistik-Alphas für jeden Modus (Attack / Release), berechnen zur Laufzeit in instantiate_dsp
  VU_NUM_MODES = 17;

function GetVUAttackAlpha(SR: Double; Mode: Integer): Double; inline;
begin
  case Mode of
    0: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    1: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    2: Result := 1.0 - Exp(-1.0 / (0.15 * SR));
    3: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    4: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    5: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    6: Result := 1.0 - Exp(-1.0 / (0.25 * SR));
    7: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    8: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    9: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    10: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    11: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    12: Result := 1.0 - Exp(-1.0 / (0.25 * SR));
    13: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    14: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    15: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    16: Result := 1.0 - Exp(-1.0 / (0.15 * SR));
    else Result := 1.0 - Exp(-1.0 / (0.3 * SR));
  end;
end;

function GetVUReleaseAlpha(SR: Double; Mode: Integer): Double; inline;
begin
  case Mode of
    0: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    1: Result := 1.0 - Exp(-1.0 / (0.6 * SR));
    2: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    3: Result := 1.0 - Exp(-1.0 / (0.4 * SR));
    4: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    5: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    6: Result := 1.0 - Exp(-1.0 / (0.35 * SR));
    7: Result := 1.0 - Exp(-1.0 / (0.4 * SR));
    8: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    9: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    10: Result := 1.0 - Exp(-1.0 / (0.15 * SR));
    11: Result := 1.0 - Exp(-1.0 / (0.2 * SR));
    12: Result := 1.0 - Exp(-1.0 / (0.25 * SR));
    13: Result := 1.0 - Exp(-1.0 / (0.35 * SR));
    14: Result := 1.0 - Exp(-1.0 / (0.3 * SR));
    15: Result := 1.0 - Exp(-1.0 / (0.4 * SR));
    16: Result := 1.0 - Exp(-1.0 / (0.15 * SR));
    else Result := 1.0 - Exp(-1.0 / (0.3 * SR));
  end;
end;

procedure UpdateVUMeterFast(var Context: TDSPInstance; Sample: Double; Mode: Integer);
var
  Alpha: Double;
  SampleSq: Double;
begin
  SampleSq := Sqr(Sample);
  if SampleSq > Context.VU_RMS then
    Alpha := GetVUAttackAlpha(Context.SampleRate, Mode)
  else
    Alpha := GetVUReleaseAlpha(Context.SampleRate, Mode);
  Context.VU_RMS := Context.VU_RMS + Alpha * (SampleSq - Context.VU_RMS);
end;

procedure UpdateVUDisplay(var Context: TDSPInstance);
var
  RMS, DB: Double;
begin
  if Context.VU_RMS > 0.0 then
  begin
    RMS := Sqrt(Context.VU_RMS);
    DB := 20.0 * Log10(RMS / gSoftCeilingFactor);
  end
  else
    DB := -40.0;
  if DB < -40.0 then DB := -40.0;
  if DB > 6.0 then DB := 6.0;
  Context.VU_Value := DB;
end;

// =============================================================================
// MODE-SPECIFIC PARAMETER TABLES (ChameleonConsole.lpr)
// =============================================================================

type
  TModeParams = record
    InputCoreSat, InputAsym, InputHyst: Double;
    OutCoreSat, OutAsym, OutHyst: Double;
    MidQBoost, MidQCutoff: Double;   // Für Bell EQ mit gain-abhängigem Q
    IsTransformerActive: Boolean;     // false für Mackie VLZ (solid-state bypass)
  end;

const
  ModeParamsTable: array[0..16] of TModeParams = (
    // Neve 1073 (Marinair / Carnhill)
    (InputCoreSat:0.05; InputAsym:0.03; InputHyst:0.12; OutCoreSat:0.065; OutAsym:0.025; OutHyst:0.10; MidQBoost:0.0; MidQCutoff:0.0; IsTransformerActive:true),
    // API 500 (Blue Stripe / Silver Stripe)
    (InputCoreSat:0.07; InputAsym:0.04; InputHyst:0.06; OutCoreSat:0.08; OutAsym:0.02; OutHyst:0.05; MidQBoost:0.1; MidQCutoff:0.06; IsTransformerActive:true),
    // SSL 4000G (GML Mic / GML Line)
    (InputCoreSat:0.04; InputAsym:0.05; InputHyst:0.14; OutCoreSat:0.05; OutAsym:0.045; OutHyst:0.13; MidQBoost:0.08; MidQCutoff:0.1; IsTransformerActive:true),
    // Neve ISA (Custom / Custom Line)
    (InputCoreSat:0.05; InputAsym:0.03; InputHyst:0.12; OutCoreSat:0.06; OutAsym:0.025; OutHyst:0.10; MidQBoost:0.0; MidQCutoff:0.0; IsTransformerActive:true),
    // Mackie VLZ (Solid state - Bypass)
    (InputCoreSat:0; InputAsym:0; InputHyst:0; OutCoreSat:0; OutAsym:0; OutHyst:0; MidQBoost:0; MidQCutoff:0; IsTransformerActive:false),
    // EMI REDD (Custom Mic / Custom Line)
    (InputCoreSat:0.045; InputAsym:0.06; InputHyst:0.13; OutCoreSat:0.05; OutAsym:0.055; OutHyst:0.125; MidQBoost:0.0; MidQCutoff:0.0; IsTransformerActive:true),
    // UA Classic (UA Custom / Neve Line)
    (InputCoreSat:0.048; InputAsym:0.035; InputHyst:0.12; OutCoreSat:0.06; OutAsym:0.025; OutHyst:0.10; MidQBoost:0.0; MidQCutoff:0.0; IsTransformerActive:true),
    // Telefunken V72 (Custom Stack / V-series)
    (InputCoreSat:0.065; InputAsym:0.02; InputHyst:0.11; OutCoreSat:0.07; OutAsym:0.015; OutHyst:0.10; MidQBoost:0.0; MidQCutoff:0.0; IsTransformerActive:true),
    // Helios 69 (Helios "B" / MkIV)
    (InputCoreSat:0.052; InputAsym:0.07; InputHyst:0.10; OutCoreSat:0.055; OutAsym:0.065; OutHyst:0.095; MidQBoost:0; MidQCutoff:0; IsTransformerActive:true),
    // Hybrid (API Input / Neve Output)
    (InputCoreSat:0.07; InputAsym:0.04; InputHyst:0.06; OutCoreSat:0.065; OutAsym:0.025; OutHyst:0.10; MidQBoost:0.1; MidQCutoff:0.06; IsTransformerActive:true),
    // RCA SR-780 (CBS/Columbia Studios)
    (InputCoreSat:0.055; InputAsym:0.06; InputHyst:0.14; OutCoreSat:0.062; OutAsym:0.035; OutHyst:0.105; MidQBoost:0.08; MidQCutoff:0.1; IsTransformerActive:true),
    // Detroit (Hitsville Motown) - Home-brew 12AX7 tube preamps
    (InputCoreSat:0.04; InputAsym:0.085; InputHyst:0.13; OutCoreSat:0.058; OutAsym:0.03; OutHyst:0.10; MidQBoost:0.1; MidQCutoff:0.06; IsTransformerActive:true),
    // Studer 169 (Swiss Precision Desk) - Ultra-clean isolation transfer
    (InputCoreSat:0.02; InputAsym:0.015; InputHyst:0.04; OutCoreSat:0.025; OutAsym:0.018; OutHyst:0.035; MidQBoost:0; MidQCutoff:0; IsTransformerActive:true),
    // Polar (Norwegian Nordic Desk) - Scandinavian precision with warmth
    (InputCoreSat:0.045; InputAsym:0.028; InputHyst:0.09; OutCoreSat:0.05; OutAsym:0.022; OutHyst:0.075; MidQBoost:0; MidQCutoff:0; IsTransformerActive:true),
    // Harrison 32C (Legendary Discrete Console) - Ultra-clean discrete transfer
    (InputCoreSat:0.015; InputAsym:0.012; InputHyst:0.03; OutCoreSat:0.018; OutAsym:0.014; OutHyst:0.025; MidQBoost:0.12; MidQCutoff:0.08; IsTransformerActive:true),
    // Trident A-Range (EMI Custom) - Smooth body, glue character
    (InputCoreSat:0.03; InputAsym:0.015; InputHyst:0.04; OutCoreSat:0.035; OutAsym:0.012; OutHyst:0.045; MidQBoost:0.1; MidQCutoff:0.05; IsTransformerActive:true),
    // MCI JH Series (Studio Standard) - Clean-tight input, punchy-slam output
    (InputCoreSat:0.04; InputAsym:0.025; InputHyst:0.06; OutCoreSat:0.055; OutAsym:0.028; OutHyst:0.08; MidQBoost:0; MidQCutoff:0; IsTransformerActive:true)
  );

// =============================================================================
// PLUGIN CORE IMPLEMENTIERUNG
// =============================================================================

var
  g_InaccuracyPct: array[0..16] of Double;
  g_InaccuracyLoaded: Boolean = False;
  g_InstanceCounter: UInt64 = 0;

function EraName(i: Integer): ShortString;
begin
  case i of
    0: Result:='neve'; 1: Result:='api'; 2: Result:='ssl'; 3: Result:='isa';
    4: Result:='mackie'; 5: Result:='redd'; 6: Result:='ua'; 7: Result:='telefunken';
    8: Result:='helios'; 9: Result:='hybrid'; 10: Result:='rca'; 11: Result:='detroit';
    12: Result:='studer'; 13: Result:='polar'; 14: Result:='harrison'; 15: Result:='trident';
    16: Result:='mci';
  else Result:='neve'; end;
end;

{ Directory of the loaded plugin, so the DSP can read inaccuracy.ini. }
function DllDir: ShortString;
{$IFDEF MSWINDOWS}
var mbi: MEMORY_BASIC_INFORMATION; h: HMODULE; buf: array[0..MAX_PATH] of Char;
begin
  VirtualQuery(@instantiate_dsp, @mbi, SizeOf(mbi));
  h := HMODULE(mbi.AllocationBase);
  FillChar(buf, SizeOf(buf), 0);
  GetModuleFileNameA(h, buf, MAX_PATH);
  Result := ExtractFilePath(StrPas(buf));
end;
{$ELSE}
{$IFDEF DARWIN}
var info: dl_info; p: Pointer;
begin
  p := @DllDir;
  if dladdr(p, @info) <> 0 then
    Result := ExtractFilePath(StrPas(info.dli_fname))
  else Result := '';
end;
{$ELSE}
var f: TextFile; line: ShortString; p: Integer;
begin
  Result := '';
  AssignFile(f, '/proc/self/maps');
  Reset(f);
  try
    while not Eof(f) do
    begin
      ReadLn(f, line);
      if Pos('ChameleonConsole', line) > 0 then
      begin
        p := Pos('/', line);
        if p > 0 then begin Result := ExtractFilePath(Copy(line, p, Length(line))); Break; end;
      end;
    end;
  finally CloseFile(f); end;
end;
{$ENDIF}
{$ENDIF}

{ Load per-era inaccuracy percentages from inaccuracy.ini (once). }
procedure LoadInaccuracyTable;
var ini: TIniFile; i: Integer; path: ShortString;
begin
  if g_InaccuracyLoaded then Exit;
  g_InaccuracyLoaded := True;
  for i := 0 to 16 do g_InaccuracyPct[i] := 0.05;  { default 5% }
  path := DllDir + 'inaccuracy.ini';
  if (path <> '') and FileExists(path) then
  begin
    ini := TIniFile.Create(path);
    try
      for i := 0 to 16 do
        g_InaccuracyPct[i] := ini.ReadFloat(EraName(i), 'pct', 0.05);
    finally ini.Free; end;
  end;
end;

{ xorshift64 -> [0,1) }
function NextRand(var state: UInt64): Double;
begin
  if state = 0 then state := 1;
  state := state xor (state shl 13);
  state := state xor (state shr 7);
  state := state xor (state shl 17);
  Result := (state shr 11) * (1.0 / 9007199254740992.0);
end;

function instantiate_dsp(const descriptor: Pointer; rate: double; bundle_path: PAnsiChar; const features: PPointer): Pointer; cdecl;
var
  Self: PDSPInstance;
begin
  if rate <= 0.0 then rate := 44100.0;

  New(Self);
  FillChar(Self^, SizeOf(TDSPInstance), 0);
  Self^.SampleRate := rate;

  { Per-channel analog inaccuracy: a unique random value per instance. }
  LoadInaccuracyTable;
  Inc(g_InstanceCounter);
  Self^.RngState := g_InstanceCounter * 6364136223846793005 + UInt64(PtrUInt(Self));
  Self^.Inaccuracy := NextRand(Self^.RngState) * 2.0 - 1.0;

  // VU-Ballistik vorbereiten (werden pro Sample in UpdateVUMeterFast gelesen)
  Self^.VU_RMS := 0.0;
  Self^.VU_Value := -40.0;
  Self^.VU_SampleCounter := 0;
  Self^.VU_UpdateInterval := 64;

  // Design Half-Band FIR für Oversampling
  DesignHalfBandFIR(Self^.FIRCoeffs);

  // Clear ZDF states
  ClearZDFState(Self^.FilterHPF);
  ClearZDFState(Self^.FilterLPF);
  ClearZDFState(Self^.EQLow);
  ClearZDFState(Self^.EQMid);
  ClearZDFState(Self^.EQHigh);
  ClearZDFState(Self^.FilterMode8Bell);

  Self^.AlphaHPF1st := 0.0;
  Self^.AlphaLPF1st := 0.0;
  Self^.HPF_1st_Hist := 0.0;
  Self^.LPF_1st_Hist := 0.0;
  Self^.TapePhase := 0.0;
  Self^.TapeHistory := 0.0;
  Self^.LowGlossState := 0.0;
  Self^.LuxState := 0.0;
  Self^.LastSample2x := 0.0;
  Self^.LastSlew := 0.0;
  Self^.TxInputState := 0.0;
  Self^.TxInterState := 0.0;
  Self^.TxOutputState := 0.0;

  Result := Pointer(Self);
end;

procedure connect_port_dsp(instance: Pointer; port: cuint32; data_location: Pointer); cdecl;
var
  Self: PDSPInstance;
begin
  Self := PDSPInstance(instance);
  if port < NUM_PORTS then
    Self^.Ports[port] := PSingle(data_location);
end;

procedure run_dsp(instance: Pointer; sample_count: cuint32); cdecl;
var
  Self: PDSPInstance;
  InBuf, OutBuf: PSingle;
  i, j, k: cuint32;
  Mode: Integer;
  
  // Drive/Gain Berechnung
  DriveFactor, MakeupGain, VolGain: Double;
  
  // Parameter für Filter/EQ
  HPFFreq, LPFFreq, LowFreq, MidFreq, HighFreq: Double;
  HPFVal, LPFVal, LowFreqVal, MidFreqVal, CurrentStripMode: Integer;
  LowGain, MidGain, HighGain: Double;

  // Tape/Flutter
  IsTapeEnabled: Boolean;
  TapeDrive: Double;
  TapeFlutter: Double;
  TapeSoftener: Double;
  TapePhaseInc: Double;
  
  // Gloss/Lux
  GlossAmount, GlossRate: Double;
  LuxIntensity, LuxTrim: Double;

  // Mode-spezifische Parameter (geladen pro Block)
  InputCoreSat, InputAsym, InputHyst: Double;
  OutCoreSat, OutAsym, OutHyst: Double;
  
  // Per-Sample Variablen
  InputSample, ProcessSample, X: Double;
  SR2x: Double;
  UseHPF, UseLPF: Boolean;
  Slew, TempLux, ClampVal, HPFSine, FlutterOffset: Double;
  RCAMidQ: Double;
  APISlewLimit, CurrentSlew: Double;
  LPFRaw, TrimDB, HPFOut: Double;

  // VU Meter (Output Gain wird direkt verwendet)
  VolumeDB: Double;
begin
  Self := PDSPInstance(instance);
  if (Self^.Ports[PORT_IN] = nil) or (Self^.Ports[PORT_OUT] = nil) then Exit;

  InBuf := Self^.Ports[PORT_IN];
  OutBuf := Self^.Ports[PORT_OUT];

  // --- Konsole-Modus laden ---
  CurrentStripMode := 0;
  if Assigned(Self^.Ports[PORT_CONSOLE]) then
    CurrentStripMode := Round(Self^.Ports[PORT_CONSOLE]^);
  if CurrentStripMode < 0 then CurrentStripMode := 0;
  if CurrentStripMode > 16 then CurrentStripMode := 16;

  Mode := CurrentStripMode; // Alias für VU-Meter

  // --- Mode-spezifische Transformer-Parameter laden ---
  InputCoreSat := ModeParamsTable[Mode].InputCoreSat * (1.0 + Self^.Inaccuracy * g_InaccuracyPct[Mode]);
  InputAsym    := ModeParamsTable[Mode].InputAsym;
  InputHyst    := ModeParamsTable[Mode].InputHyst;
  OutCoreSat   := ModeParamsTable[Mode].OutCoreSat * (1.0 + Self^.Inaccuracy * g_InaccuracyPct[Mode]);
  OutAsym      := ModeParamsTable[Mode].OutAsym;
  OutHyst      := ModeParamsTable[Mode].OutHyst;

  // --- Gain-Vorbereitung ---
  DriveFactor  := 1.0 + (Self^.Ports[PORT_DRIVE]^ * 7.0);
  MakeupGain   := 1.0 / (1.0 + (Self^.Ports[PORT_DRIVE]^ * 2.0));
  
  // Output Gain (Volume) - ChameleonConsole Port 12: -inf/+12dB, default = 0
  if Assigned(Self^.Ports[PORT_VOLUME]) then
  begin
    VolumeDB := Self^.Ports[PORT_VOLUME]^ * 24.0 - 6.0; // Range: -6dB .. +18dB (default bei 0.5)
    if VolumeDB < -80.0 then VolumeDB := -80.0;
    VolGain := Exp(VolumeDB * ln(10.0) / 20.0);
  end
  else
    VolGain := 1.0;

  LowGain     := Self^.Ports[PORT_EQ_LO_G]^;
  MidGain     := Self^.Ports[PORT_EQ_MID_G]^;
  HighGain    := Self^.Ports[PORT_EQ_HI_G]^;

  GlossAmount := Self^.Ports[PORT_GLOSS]^;
  GlossRate   := 1.0 - (GlossAmount * 0.9);
  LuxIntensity := Self^.Ports[PORT_LUX]^;
  LuxTrim     := LuxIntensity * 0.5;

  APISlewLimit := 0.1 + (Sqr(1.0 - Self^.Ports[PORT_DRIVE]^) * 0.9);
  SR2x := Self^.SampleRate * 2.0;

  IsTapeEnabled := Assigned(Self^.Ports[PORT_TAPE]) and (Self^.Ports[PORT_TAPE]^ >= 0.5);
  TapeDrive     := 0.3;
  TapeFlutter   := 0.22;
  TapeSoftener  := 0.40;
  TapePhaseInc  := 0.00037;

  // --- HPF Frequenz aus Port-Wert (diskrete Stufen) ---
  HPFVal := Round(Self^.Ports[PORT_HPF]^);
  case HPFVal of
    1: HPFFreq := 50.0;
    2: HPFFreq := 80.0;
    3: HPFFreq := 160.0;
    4: HPFFreq := 300.0;
    else HPFFreq := 0.0;
  end;
  UseHPF := HPFFreq > 0.0;

  // --- LPF Frequenz aus Port-Wert (diskrete Stufen, normalisiert [0..1]) ---
  LPFRaw := Self^.Ports[PORT_LPF]^;
  if LPFRaw > 20000.0 then LPFRaw := 20000.0;
  if LPFRaw < 1000.0 then LPFRaw := 1000.0;
  LPFVal := Round(((LPFRaw - 1000.0) / 19000.0) * 5.0);
  case LPFVal of
    0: LPFFreq := 6000.0;
    1: LPFFreq := 8000.0;
    2: LPFFreq := 11000.0;
    3: LPFFreq := 15000.0;
    4: LPFFreq := 20000.0;
    5: LPFFreq := 22050.0;
    else LPFFreq := 22050.0;
  end;
  UseLPF := LPFFreq < 22050.0;

  // --- EQ Low Frequenz (diskret) ---
  LowFreqVal := Round(Self^.Ports[PORT_EQ_LO_F]^);
  case LowFreqVal of
    0: LowFreq := 35.0;
    1: LowFreq := 60.0;
    2: LowFreq := 110.0;
    3: LowFreq := 220.0;
    else LowFreq := 60.0;
  end;

  // --- EQ Mid Frequenz (diskret) ---
  MidFreqVal := Round(Self^.Ports[PORT_EQ_MID_F]^);
  case MidFreqVal of
    0: MidFreq := 360.0;
    1: MidFreq := 720.0;
    2: MidFreq := 1600.0;
    3: MidFreq := 3200.0;
    4: MidFreq := 4800.0;
    5: MidFreq := 7200.0;
    else MidFreq := 1600.0;
  end;

  // --- EQ High Frequenz (kontinuierlich) ---
  HighFreq := Self^.Ports[PORT_EQ_HI_F]^;

  // --- Trim vorbereiten ---
  if Assigned(Self^.Ports[PORT_TRIM]) then
  begin
    TrimDB := Self^.Ports[PORT_TRIM]^;
    if TrimDB > 30.0 then TrimDB := 30.0;
    if TrimDB < -30.0 then TrimDB := -30.0;
  end;

  // ========================= AUDIO-LOOP =========================
  for i := 0 to sample_count - 1 do
  begin
    // Drive-Gain auf Input
    InputSample := PSampleF(InBuf)^[i] * DriveFactor;
    
    // Tape Flutter LFO
    Self^.TapePhase := Self^.TapePhase + TapePhaseInc;
    if Self^.TapePhase > (2.0 * Pi) then Self^.TapePhase := Self^.TapePhase - (2.0 * Pi);
    FlutterOffset := Sin(Self^.TapePhase) * TapeFlutter * 0.05;

    // --- 2x Oversampling Loop ---
    for j := 0 to 1 do
    begin
      // Upsample: FIR Interpolation in Ringpuffer
      Self^.UpPos := (Self^.UpPos - 1) and 127;
      if j = 0 then
        Self^.UpBuffer[Self^.UpPos] := InputSample * 2.0
      else
        Self^.UpBuffer[Self^.UpPos] := 0.0;

      // FIR Downsampling-Vorbereitung (berechnet Output für diese Upsample-Phase)
      ProcessSample := 0.0;
      ProcessSample := Self^.UpBuffer[(Self^.UpPos + 63) and 127] * Self^.FIRCoeffs[63];
      for k := 0 to 63 do
        ProcessSample := ProcessSample + Self^.UpBuffer[(Self^.UpPos + (k shl 1)) and 127] * Self^.FIRCoeffs[k shl 1];
      X := ProcessSample;

      // === INPUT TRIM (nach Oversampling, vor jeglicher Verarbeitung) ===
      if TrimDB <> 0.0 then
        X := X * Exp(TrimDB * ln(10.0) / 20.0);

      // === MIC INPUT TRANSFORMER ===
      if ModeParamsTable[Mode].IsTransformerActive then
        X := ProcessTransformerEnhanced(X, InputCoreSat, InputAsym, InputHyst, Self^.TxInputState);

      // === MODE-SPECIFIC SATURATION ===
      case Mode of
        0, 5, 7: begin // Neve 1073 / EMI REDD / Telefunken V72 - Tube Soft Clip
                   if X > 1.0 then X := 2.0 / 3.0
                   else if X < -1.0 then X := -2.0 / 3.0
                   else X := X - (X * X * X / 3.0);
                 end;
        1, 4, 8: begin // API 500 / Mackie VLZ / Helios 69 - Slew + Sine Comp
                   CurrentSlew := X - Self^.LastSlew;
                   if CurrentSlew > APISlewLimit then X := Self^.LastSlew + APISlewLimit
                   else if CurrentSlew < -(APISlewLimit * 0.75) then X := Self^.LastSlew - (APISlewLimit * 0.75);
                   Self^.LastSlew := X;
                   if X > 0.0 then
                   begin
                     ClampVal := X * 1.5707963267948966;
                     if ClampVal > 1.5707963267948966 then X := 1.0 else X := Sin(ClampVal);
                   end
                   else
                   begin
                     if X < -1.0 then X := -1.0 else X := X - (X * X * X * 0.15);
                   end;
                 end;
        2, 6: begin // SSL 4000G / UA Classic - Cube Softening
                   ClampVal := X * X * X;
                   X := X - (ClampVal * 0.25);
                 end;
        3: begin // Neve ISA - Exponential Soft Clip @ ±0.95
                   if X > 0.95 then X := 0.95 + (X - 0.95) / (1.0 + Sqr(X - 0.95))
                   else if X < -0.95 then X := -0.95 + (X + 0.95) / (1.0 + Sqr(X + 0.95));
                 end;
        10: begin // RCA SR-780 - Exponential Soft Clip @ ±0.92
                   if X > 0.92 then X := 0.92 + (X - 0.92) / (1.0 + Sqr(X - 0.92))
                   else if X < -0.92 then X := -0.92 + (X + 0.92) / (1.0 + Sqr(X + 0.92));
                 end;
        11: begin // Detroit (Hitsville Motown) - Fast-knee Tube Soft Clip @ ±0.9
                   if X > 0.9 then X := 0.9 + (X - 0.9) / (1.0 + Sqr(X - 0.9))
                   else if X < -0.9 then X := -0.9 + (X + 0.9) / (1.0 + Sqr(X + 0.9));
                 end;
        16: begin // MCI JH Series - Subtle even-order harmonics @ ±0.98
                   if X > 0.98 then X := 0.98 + (X - 0.98) / (1.0 + Abs(X - 0.98))
                   else if X < -0.98 then X := -0.98 + (X + 0.98) / (1.0 + Abs(X + 0.98));
                 end;
        9: begin // Hybrid - Sine Compression
                   ClampVal := X * 1.5707963267948966;
                   if ClampVal > 1.5707963267948966 then X := 1.0
                   else if ClampVal < -1.5707963267948966 then X := -1.0
                   else X := Sin(ClampVal);
                 end;
        // Modes 12, 13, 14 (Studer, Polar, Harrison): Ultra-clean bypass - keine Saturation
      end;

      // === FILTER & EQ STAGES (in oversampled domain) ===
      
      // HPF: ZDF SVF oder First-Order Kaskade je nach Modus
      if UseHPF then
      begin
        if Mode in [0, 1, 7, 9, 12, 13, 14, 15, 16] then
          X := ProcessZDF(Self^.FilterHPF, X)
        else if Mode in [2, 3, 4, 10, 11, 14] then
        begin
          HPFOut := ProcessZDF(Self^.FilterHPF, X);
          Self^.HPF_1st_Hist := Self^.HPF_1st_Hist + Self^.AlphaHPF1st * (HPFOut - Self^.HPF_1st_Hist);
          X := HPFOut - Self^.HPF_1st_Hist;
        end
        else if Mode in [5, 6] then
        begin
          Self^.HPF_1st_Hist := Self^.HPF_1st_Hist + Self^.AlphaHPF1st * (X - Self^.HPF_1st_Hist);
          X := X - Self^.HPF_1st_Hist;
        end;
      end;

      // LPF: ZDF SVF oder First-Order Kaskade je nach Modus
      if UseLPF and (Mode <> 4) then
      begin
        if Mode in [3, 5, 10, 11, 12, 13, 14, 15, 16] then
        begin
          Self^.LPF_1st_Hist := Self^.LPF_1st_Hist + Self^.AlphaLPF1st * (X - Self^.LPF_1st_Hist);
          X := Self^.LPF_1st_Hist;
        end
        else
          X := ProcessZDF(Self^.FilterLPF, X);
      end;

      // Mode 8: Extra Bell für Low-Gain Boost
      if (Mode = 8) and (LowGain > 0.0) then
        X := ProcessZDF(Self^.FilterMode8Bell, X);

      // 3-Band EQ (alle ZDF SVF)
      SetupZDFLowShelf(Self^.EQLow, LowFreq, LowGain, SR2x);
      
      // Mid Q: Mode-abhängig
      if Mode = 16 then
        RCAMidQ := Math.Max(0.8, 3.0 - (MidFreq / 4000.0)) // MCI: freq-dependent Q
      else
        RCAMidQ := 0.55; // Standard
      
      // Mid Q mode-abhängig anpassen
      case Mode of
        1, 9, 11: begin // API/Hybrid/Detroit: Boost-wider, Cut-tighter
                     if MidGain >= 0.0 then RCAMidQ := 0.55 + (MidGain * 0.1)
                     else RCAMidQ := 0.85 - (Abs(MidGain) * 0.06);
                   end;
        2: begin // SSL: wider on boost, tighter on cut
               if MidGain >= 0.0 then RCAMidQ := 0.5 + (Abs(MidGain) * 0.12)
               else RCAMidQ := 1.2;
             end;
        6: begin // UA: wider bell
               if MidGain >= 0.0 then RCAMidQ := 0.4
               else RCAMidQ := 0.5;
             end;
        7: RCAMidQ := 0.6; // Telefunken: stable wide
        8: begin // Helios: boost = narrow bell
               if LowGain > 0.0 then SetupZDFBell(Self^.FilterMode8Bell, LowFreq * 2.0, -LowGain * 0.15, 0.5, SR2x);
               RCAMidQ := 0.4;
             end;
        10: begin // RCA: Boost = wide creamy, Cut = tighter notch
                 if MidGain >= 0.0 then RCAMidQ := 0.7 + (MidGain * 0.08)
                 else RCAMidQ := 0.9 - (Abs(MidGain) * 0.1);
               end;
        12, 14: RCAMidQ := 0.65; // Studer/Harrison: stable parametric
        13: RCAMidQ := 0.55; // Polar: bright Nordic sweep
        15: begin // Trident: wide-sweep variable Q
               if MidGain >= 0.0 then RCAMidQ := 1.3 + (MidGain * 0.1)
               else RCAMidQ := 0.8 - (Abs(MidGain) * 0.05);
             end;
        0, 4: RCAMidQ := 0.5; // Neve default / Mackie standard
      end;

      SetupZDFBell(Self^.EQMid, MidFreq, MidGain, RCAMidQ, SR2x);
      SetupZDFHighShelf(Self^.EQHigh, HighFreq, HighGain, SR2x);
      
      X := ProcessZDF(Self^.EQLow, X);
      X := ProcessZDF(Self^.EQMid, X);
      X := ProcessZDF(Self^.EQHigh, X);

      // === OUTPUT TRANSFORMER ===
      if ModeParamsTable[Mode].IsTransformerActive then
        X := ProcessTransformerEnhanced(X, OutCoreSat, OutAsym, OutHyst, Self^.TxOutputState);

      // === TAPE EMULATION ===
      if IsTapeEnabled then
      begin
        X := X + (FlutterOffset * (X - Self^.TapeHistory)) + (FlutterOffset * 0.005);
        if TapeDrive > 0.0 then
        begin
          X := X * (1.0 + TapeDrive);
          if X > Self^.TapeHistory then
            X := X - 0.05 * (X - Self^.TapeHistory);
          HPFSine := X * 1.5707963267948966;
          if HPFSine > 1.5707963267948966 then X := 1.0
          else if HPFSine < -1.5707963267948966 then X := -1.0
          else X := Sin(HPFSine);
        end;
        TapeSoftener := (Abs(X) * TapeSoftener) + 0.05;
        if TapeSoftener > 0.8 then TapeSoftener := 0.8;
        X := (X * (1.0 - TapeSoftener)) + (Self^.TapeHistory * TapeSoftener);
        Self^.TapeHistory := X;
      end;

      // === GLOSS (Low-Pass Smoothing) ===
      Self^.LowGlossState := (Self^.LowGlossState * GlossRate) + (X * (1.0 - GlossRate));
      X := (X * (1.0 - GlossAmount)) + (Self^.LowGlossState * GlossAmount);

      // === LUX (Transient Enhancer / Air) ===
      TempLux := X - Self^.LuxState;
      if LuxTrim > 0.0 then
      begin
        if TempLux > 1.0 then TempLux := 1.0 else if TempLux < -1.0 then TempLux := -1.0;
        X := Self^.LuxState + (TempLux * (1.0 - (Abs(TempLux) * LuxTrim)));
      end;
      Self^.LuxState := X;

      // === FINAL SATURATION (Slew Limiter + Soft Clip) ===
      if Mode <> 9 then
      begin
        Slew := X - Self^.LastSample2x;
        if Slew > 0.25 then Slew := 0.25 else if Slew < -0.25 then Slew := -0.25;
        X := Self^.LastSample2x + Slew;
        X := X + (X * (1.0 - Abs(X)) * 0.04);
      end;
      Self^.LastSample2x := X;

      // Soft-Clip (K-14 soft ceiling)
      X := SoftClipCubic(X);

      // === DOWNSAMPLING ===
      Self^.DnPos := (Self^.DnPos - 1) and 127;
      Self^.DnBuffer[Self^.DnPos] := X;

      if j = 1 then
      begin
        // FIR Downsampling zum Output
        ProcessSample := 0.0;
        ProcessSample := Self^.DnBuffer[(Self^.DnPos + 63) and 127] * Self^.FIRCoeffs[63];
        for k := 0 to 63 do
          ProcessSample := ProcessSample + Self^.DnBuffer[(Self^.DnPos + (k shl 1)) and 127] * Self^.FIRCoeffs[k shl 1];

        // Finale Verstärkung + Hard-Clipper
        PSampleF(OutBuf)^[i] := HardClip(ProcessSample * MakeupGain * VolGain);

        // VU-Meter aktualisieren
        UpdateVUMeterFast(Self^, PSampleF(OutBuf)^[i], Mode);
        Inc(Self^.VU_SampleCounter);
        if Self^.VU_SampleCounter >= Self^.VU_UpdateInterval then
        begin
          Self^.VU_SampleCounter := 0;
          UpdateVUDisplay(Self^);
        end;
      end;
    end;
  end;

  // Restliche VU-Anzeige schreiben (falls nicht gerade bei 64 Samples)
  if Self^.VU_SampleCounter > 0 then
  begin
    UpdateVUDisplay(Self^);
  end;
  Self^.VU_SampleCounter := 0;
end;

procedure cleanup_dsp(instance: Pointer); cdecl;
var
  Self: PDSPInstance;
begin
  Self := PDSPInstance(instance);
  Dispose(Self);
end;

end.
