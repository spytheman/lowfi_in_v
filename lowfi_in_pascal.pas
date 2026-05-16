program lowfi_in_pascal;

{$mode objfpc}{$H+}

uses
  cthreads,
  Classes,
  SysUtils,
  Process,
  SyncObjs;

type
  TSong = record
    Url: string;
    Title: string;
    Number: Integer;
  end;

  TSongArray = array of TSong;

  TApp = class;
  TDownloadThread = class;

  TSongQueue = class
  private
    FItems: TSongArray;
    FHead: Integer;
    FTail: Integer;
    FCount: Integer;
    FCapacity: Integer;
    FCrit: TCriticalSection;
    FHasItem: TEvent;
    FHasSpace: TEvent;
  public
    constructor Create(ACapacity: Integer);
    destructor Destroy; override;
    procedure Push(const ASong: TSong);
    function Pop: TSong;
  end;

  TApp = class
  private
    FDownloaded: TSongQueue;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddRandomSong;
    procedure DownloadLocalFile(const OSong: TSong; Counter: Integer);
    procedure RemoveSong(const ASong: TSong);
    procedure AddAnother(const ASong: TSong);
    property Downloaded: TSongQueue read FDownloaded;
  end;

  TDownloadThread = class(TThread)
  private
    FApp: TApp;
    FSong: TSong;
    FCounter: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(AApp: TApp; const ASong: TSong; ACounter: Integer);
  end;

var
  Songs: TSongArray;
  SongLocalDir: string;
  SongCounter: Integer = 0;

function Fnv1a64(const S: string): QWord;
const
  FNV_OFFSET_BASIS: QWord = 14695981039346656037;
  FNV_PRIME: QWord = 1099511628211;
var
  I: Integer;
begin
  Result := FNV_OFFSET_BASIS;
  for I := 1 to Length(S) do
  begin
    Result := Result xor Ord(S[I]);
    Result := Result * FNV_PRIME;
  end;
end;

function QWordToString(Value: QWord): string;
begin
  Result := '';
  repeat
    Result := Chr(Ord('0') + (Value mod 10)) + Result;
    Value := Value div 10;
  until Value = 0;
end;

function SongLocalPath(const ASong: TSong): string;
begin
  Result := IncludeTrailingPathDelimiter(SongLocalDir) + QWordToString(Fnv1a64(ASong.Url)) + '.mp3';
end;

function LocateDataFile(const FileName: string): string;
var
  BaseDir: string;
begin
  BaseDir := ExtractFilePath(ParamStr(0));
  if BaseDir <> '' then
  begin
    Result := IncludeTrailingPathDelimiter(BaseDir) + FileName;
    if FileExists(Result) then
      Exit;
  end;

  Result := FileName;
end;

function NewSong(const Line: string): TSong;
var
  SepPos: SizeInt;
begin
  SepPos := Pos('!', Line);
  if SepPos = 0 then
  begin
    Result.Url := Line;
    Result.Title := '';
  end
  else
  begin
    Result.Url := Copy(Line, 1, SepPos - 1);
    Result.Title := Copy(Line, SepPos + 1, MaxInt);
  end;
  Result.Number := 0;
end;

function CreateSongs: TSongArray;
var
  Lines: TStringList;
  BaseURL: string;
  I: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(LocateDataFile('chillhop.txt'));
    if Lines.Count = 0 then
      Exit(nil);

    BaseURL := Lines[0];
    SetLength(Result, Lines.Count - 1);
    for I := 1 to Lines.Count - 1 do
      Result[I - 1] := NewSong(BaseURL + Lines[I]);
  finally
    Lines.Free;
  end;
end;

function CommandExists(const Cmd: string): Boolean;
var
  Proc: TProcess;
begin
  Result := False;
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := '/bin/sh';
    Proc.Parameters.Add('-c');
    Proc.Parameters.Add('command -v ' + Cmd + ' >/dev/null 2>&1');
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    Result := Proc.ExitStatus = 0;
  except
    Result := False;
  end;
  Proc.Free;
end;

function RunCommand(const Exe: string; const Args: array of string): Integer;
var
  Proc: TProcess;
  I: Integer;
begin
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := Exe;
    for I := Low(Args) to High(Args) do
      Proc.Parameters.Add(Args[I]);
    Proc.Options := [poWaitOnExit];
    Proc.Execute;
    Result := Proc.ExitStatus;
  finally
    Proc.Free;
  end;
end;

constructor TSongQueue.Create(ACapacity: Integer);
begin
  inherited Create;
  FCapacity := ACapacity;
  SetLength(FItems, FCapacity);
  FCrit := TCriticalSection.Create;
  FHasItem := TEvent.Create(nil, False, False, '');
  FHasSpace := TEvent.Create(nil, False, False, '');
end;

destructor TSongQueue.Destroy;
begin
  FHasSpace.Free;
  FHasItem.Free;
  FCrit.Free;
  inherited Destroy;
end;

procedure TSongQueue.Push(const ASong: TSong);
begin
  while True do
  begin
    FCrit.Acquire;
    try
      if FCount < FCapacity then
      begin
        FItems[FTail] := ASong;
        FTail := (FTail + 1) mod FCapacity;
        Inc(FCount);
        FHasItem.SetEvent;
        Exit;
      end;
    finally
      FCrit.Release;
    end;
    FHasSpace.WaitFor(High(Cardinal));
  end;
end;

function TSongQueue.Pop: TSong;
begin
  while True do
  begin
    FCrit.Acquire;
    try
      if FCount > 0 then
      begin
        Result := FItems[FHead];
        FHead := (FHead + 1) mod FCapacity;
        Dec(FCount);
        FHasSpace.SetEvent;
        Exit;
      end;
    finally
      FCrit.Release;
    end;
    FHasItem.WaitFor(High(Cardinal));
  end;
end;

constructor TApp.Create;
begin
  inherited Create;
  FDownloaded := TSongQueue.Create(5);
end;

destructor TApp.Destroy;
begin
  FDownloaded.Free;
  inherited Destroy;
end;

procedure TApp.AddRandomSong;
var
  CurrentSong: TSong;
begin
  if Length(Songs) = 0 then
    Exit;

  CurrentSong := Songs[Random(Length(Songs))];
  Inc(SongCounter);
  TDownloadThread.Create(Self, CurrentSong, SongCounter);
end;

procedure TApp.DownloadLocalFile(const OSong: TSong; Counter: Integer);
var
  CurrentSong: TSong;
  LPath: string;
  Attempt: Integer;
  ExitCode: Integer;
begin
  CurrentSong := OSong;
  CurrentSong.Number := Counter;
  LPath := SongLocalPath(CurrentSong);

  if not FileExists(LPath) then
  begin
    for Attempt := 1 to 5 do
    begin
      ExitCode := RunCommand('wget', ['--quiet', '--output-document=' + LPath, CurrentSong.Url]);
      if ExitCode <> 0 then
      begin
        Sleep(500);
        Continue;
      end;
      Break;
    end;
  end;

  FDownloaded.Push(CurrentSong);
end;

procedure TApp.RemoveSong(const ASong: TSong);
begin
  DeleteFile(SongLocalPath(ASong));
end;

procedure TApp.AddAnother(const ASong: TSong);
begin
  RemoveSong(ASong);
  AddRandomSong;
end;

constructor TDownloadThread.Create(AApp: TApp; const ASong: TSong; ACounter: Integer);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FApp := AApp;
  FSong := ASong;
  FCounter := ACounter;
  Start;
end;

procedure TDownloadThread.Execute;
begin
  FApp.DownloadLocalFile(FSong, FCounter);
end;

procedure ShouldBePresent(const Cmd: string);
begin
  if not CommandExists(Cmd) then
  begin
    Writeln('This program needs ', Cmd, ' to work.');
    Halt(1);
  end;
end;

var
  App: TApp;
  Buffer: array[0..8191] of Char;
  CurrentSong: TSong;
  ExitCode: Integer;
  I: Integer;

begin
  Randomize;
  ShouldBePresent('mpg321');
  ShouldBePresent('wget');
  SetTextBuf(Output, Buffer, SizeOf(Buffer));
  SongLocalDir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'lowfi';
  ForceDirectories(SongLocalDir);
  Songs := CreateSongs;
  Writeln('Local folder: ', SongLocalDir);

  App := TApp.Create;
  try
    for I := 1 to 5 do
      App.AddRandomSong;

    while True do
    begin
      CurrentSong := App.Downloaded.Pop;
      Writeln(Format('Playing "%s" from URL: %-40s ...', [CurrentSong.Title, CurrentSong.Url]));
      ExitCode := RunCommand('mpg321', ['--quiet', SongLocalPath(CurrentSong)]);
      Writeln('res: ', ExitCode);
      if ExitCode = 4 then
      begin
        Writeln('mpv was interrupted by Ctrl-C. Good bye.');
        Halt(1);
      end;
      App.AddAnother(CurrentSong);
    end;
  finally
    App.Free;
  end;
end.
