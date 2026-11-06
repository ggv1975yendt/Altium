{ CloneTasks.pas - Altium Designer DelphiScript
  Entry point: RunCloneTasks
  Built-in fields: Description, Designator, Comment.
  LibReference is reserved for Task Target.
  Fixed-format XML reader, no COM/MSXML.
  Clone full components via Replicate to preserve graphical modes and their names.
  Confirmed by user test in Altium Designer 26.6.0.
  XML attribute values must use double quotes.
  Parameter Value is selectively decoded from UTF-8; XML structure is unchanged.
  Test on a BACKUP of the SchLib first.
}


const
  XML_FILE = 'clone_config.xml';
  LIB_FILE = 'Library.SCHLIB';


function PosEx(Needle, Haystack : String; Offset : Integer) : Integer;
var
  P : Integer;
begin
  Result := 0;
  if Offset < 1 then Offset := 1;
  P := Pos(Needle, Copy(Haystack, Offset, Length(Haystack)));
  if P > 0 then Result := Offset + P - 1;
end;

function ReplaceAllText(S, OldText, NewText : String) : String;
var
  P : Integer;
  R : String;
begin
  if OldText = '' then
  begin
    Result := S;
    Exit;
  end;
  R := '';
  P := Pos(OldText, S);
  while P > 0 do
  begin
    R := R + Copy(S, 1, P - 1) + NewText;
    Delete(S, 1, P + Length(OldText) - 1);
    P := Pos(OldText, S);
  end;
  Result := R + S;
end;

function XmlDecode(S : String) : String;
begin
  S := ReplaceAllText(S, '&quot;', '"');
  S := ReplaceAllText(S, '&apos;', #39);
  S := ReplaceAllText(S, '&lt;', '<');
  S := ReplaceAllText(S, '&gt;', '>');
  S := ReplaceAllText(S, '&amp;', '&');
  Result := S;
end;

{ Reads double-quoted attributes from an opening XML tag. }
function TagAttribute(TagText, AttrName : String) : String;
var
  I, J, K, N : Integer;
  Key : String;
begin
  Result := '';
  N := Length(TagText);
  I := 1;

  { Skip '<' and the tag name. }
  if (N > 0) and (TagText[1] = '<') then I := 2;
  while I <= N do
  begin
    if (TagText[I] = ' ') or (TagText[I] = #9) or
       (TagText[I] = #10) or (TagText[I] = #13) or
       (TagText[I] = '>') then Break;
    Inc(I);
  end;

  while I <= N do
  begin
    while I <= N do
    begin
      if (TagText[I] <> ' ') and (TagText[I] <> #9) and
         (TagText[I] <> #10) and (TagText[I] <> #13) then Break;
      Inc(I);
    end;
    if I > N then Break;
    if (TagText[I] = '>') or (TagText[I] = '/') then Break;

    J := I;
    while I <= N do
    begin
      if (TagText[I] = '=') or (TagText[I] = ' ') or
         (TagText[I] = #9) or (TagText[I] = #10) or
         (TagText[I] = #13) or (TagText[I] = '>') then Break;
      Inc(I);
    end;
    Key := Copy(TagText, J, I - J);
    if I = J then
    begin
      Inc(I);
      Continue;
    end;

    while I <= N do
    begin
      if (TagText[I] <> ' ') and (TagText[I] <> #9) and
         (TagText[I] <> #10) and (TagText[I] <> #13) then Break;
      Inc(I);
    end;
    if I > N then Break;
    if TagText[I] <> '=' then Continue;
    Inc(I);
    while I <= N do
    begin
      if (TagText[I] <> ' ') and (TagText[I] <> #9) and
         (TagText[I] <> #10) and (TagText[I] <> #13) then Break;
      Inc(I);
    end;
    if I > N then Break;
    if TagText[I] <> '"' then Break;
    Inc(I);
    K := I;
    while I <= N do
    begin
      if TagText[I] = '"' then Break;
      Inc(I);
    end;
    if UpperCase(Key) = UpperCase(AttrName) then
    begin
      Result := XmlDecode(Copy(TagText, K, I - K));
      Exit;
    end;
    if I <= N then Inc(I);
  end;
end;

function FindNextTag(S, TagName : String; StartAt : Integer) : Integer;
var
  P : Integer;
begin
  Result := 0;
  P := StartAt;
  while P <= Length(S) do
  begin
    P := PosEx('<' + TagName, S, P);
    if P = 0 then Exit;
    if (P + Length(TagName) + 1 <= Length(S)) and
       ((S[P + Length(TagName) + 1] = ' ') or
        (S[P + Length(TagName) + 1] = #9) or
        (S[P + Length(TagName) + 1] = #10) or
        (S[P + Length(TagName) + 1] = #13) or
        (S[P + Length(TagName) + 1] = '>') or
        (S[P + Length(TagName) + 1] = '/')) then
    begin
      Result := P;
      Exit;
    end;
    Inc(P);
  end;
end;

function FindComponent(Lib : ISch_Lib; Name : String) : ISch_Component;
begin
  Result := Lib.GetState_SchComponentByLibRef(Name);
end;

function GetLibraryByPath : ISch_Lib;
var
  WS : IWorkspace;
  Doc : IDocument;
begin
  Result := Nil;
  if not FileExists(LIB_FILE) then
  begin
    ShowMessage('Library not found: ' + LIB_FILE);
    Exit;
  end;
  WS := GetWorkspace;
  if WS = Nil then Exit;
  Doc := WS.DM_GetDocumentFromPath(LIB_FILE);
  if Doc = Nil then
  begin
    ResetParameters;
    AddStringParameter('ObjectKind', 'Document');
    AddStringParameter('FileName', LIB_FILE);
    RunProcess('WorkspaceManager:OpenObject');
  end;
  Result := SchServer.GetSchDocumentByPath(LIB_FILE);
  if Result = Nil then
    ShowMessage('Cannot access SchLib: ' + LIB_FILE);
end;

function FindParameter(Comp : ISch_Component; Name : String) : ISch_Parameter;
var
  It : ISch_Iterator;
  P : ISch_Parameter;
begin
  Result := Nil;
  It := Comp.SchIterator_Create;
  It.AddFilter_ObjectSet(MkSet(eParameter));
  P := It.FirstSchObject;
  while P <> Nil do
  begin
    if UpperCase(P.Name) = UpperCase(Name) then
    begin
      Result := P;
      Break;
    end;
    P := It.NextSchObject;
  end;
  Comp.SchIterator_Destroy(It);
end;

function SetParameter(Comp : ISch_Component; Name, Value : String) : Boolean;
var
  P : ISch_Parameter;
begin
  Result := False;
  P := FindParameter(Comp, Name);
  if P = Nil then
  begin
    P := SchServer.SchObjectFactory(eParameter, eCreate_Default);
    if P = Nil then Exit;
    P.Name := Name;
    P.Text := Value;
    P.OwnerPartId := 0;
    P.OwnerPartDisplayMode := 0;
    Comp.AddSchObject(P);
  end
  else
    P.Text := Value;

  { Verify through the component's iterator, not just the local object. }
  P := FindParameter(Comp, Name);
  if P <> Nil then
    Result := (P.Text = Value);
end;

{ Built-in component fields must not be created as user parameters.
  LibReference is controlled exclusively by Task Target. }
function SetComponentField(Comp : ISch_Component;
                           Name, Value : String) : Boolean;
var
  Key : String;
begin
  Result := False;
  Key := UpperCase(Name);

  if Key = 'DESCRIPTION' then
  begin
    Comp.ComponentDescription := Value;
    Result := (Comp.ComponentDescription = Value);
  end
  else if Key = 'DESIGNATOR' then
  begin
    if Comp.Designator <> Nil then
    begin
      Comp.Designator.Text := Value;
      Result := (Comp.Designator.Text = Value);
    end;
  end
  else if Key = 'COMMENT' then
  begin
    if Comp.Comment <> Nil then
    begin
      Comp.Comment.Text := Value;
      Result := (Comp.Comment.Text = Value);
    end;
  end;
end;

function IsProtectedField(Name : String) : Boolean;
var
  Key : String;
begin
  Key := UpperCase(Name);
  Result := (Key = 'LIBREFERENCE') or (Key = 'PARTCOUNT') or
            (Key = 'DISPLAYMODECOUNT') or (Key = 'DISPLAYMODE') or
            (Key = 'CURRENTPARTID') or
            (Key = 'CUSTOMDISPLAYMODENAME');
end;

{ Decode only Parameter Value, never the whole XML document.
  If LoadFromFile has already produced Unicode, leave it untouched.
  Validate UTF-8 byte sequences before calling UTF8Decode. }
function DecodeParameterValueUtf8(S : String) : String;
var
  I, J, B, B2, N, CodePoint : Integer;
  HasMultibyte, Valid : Boolean;
begin
  Result := S;
  I := 1;
  HasMultibyte := False;
  Valid := True;
  while I <= Length(S) do
  begin
    B := Ord(S[I]);
    { Unicode code units mean the string is already decoded. }
    if B > 255 then Exit;
    if B < 128 then
    begin
      Inc(I);
      Continue;
    end;

    if (B >= 194) and (B <= 223) then
    begin
      N := 2;
      CodePoint := B - 192;
    end
    else if (B >= 224) and (B <= 239) then
    begin
      N := 3;
      CodePoint := B - 224;
    end
    else if (B >= 240) and (B <= 244) then
    begin
      N := 4;
      CodePoint := B - 240;
    end
    else
    begin
      Valid := False;
      Break;
    end;

    if I + N - 1 > Length(S) then
    begin
      Valid := False;
      Break;
    end;
    for J := 1 to N - 1 do
    begin
      B2 := Ord(S[I + J]);
      if (B2 < 128) or (B2 > 191) then
      begin
        Valid := False;
        Break;
      end;
      CodePoint := CodePoint * 64 + (B2 - 128);
    end;
    if not Valid then Break;
    if ((N = 2) and (CodePoint < 128)) or
       ((N = 3) and (CodePoint < 2048)) or
       ((N = 4) and (CodePoint < 65536)) or
       (CodePoint > 1114111) or
       ((CodePoint >= 55296) and (CodePoint <= 57343)) then
    begin
      Valid := False;
      Break;
    end;
    HasMultibyte := True;
    Inc(I, N);
  end;
  if Valid and HasMultibyte then
    Result := UTF8Decode(S);
end;

function ApplyParameters(Comp : ISch_Component; TaskBody : String;
                         var Errors : String) : Integer;
var
  P, E : Integer;
  Tag, Name, Value : String;
begin
  Result := 0;
  P := 1;
  while True do
  begin
    P := FindNextTag(TaskBody, 'Parameter', P);
    if P = 0 then Break;
    E := PosEx('>', TaskBody, P);
    if E = 0 then Break;
    Tag := Copy(TaskBody, P, E - P + 1);
    Name := TagAttribute(Tag, 'Name');
    Value := TagAttribute(Tag, 'Value');
    Value := DecodeParameterValueUtf8(Value);
    if Name = '' then
      Errors := Errors + 'Parameter without Name in ' + Comp.LibReference + #13#10
    else if IsProtectedField(Name) then
      Errors := Errors + 'Reserved component field (not changed): ' +
                Comp.LibReference + ' / ' + Name + #13#10
    else if (UpperCase(Name) = 'DESCRIPTION') or
            (UpperCase(Name) = 'DESIGNATOR') or
            (UpperCase(Name) = 'COMMENT') then
    begin
      if SetComponentField(Comp, Name, Value) then
        Inc(Result)
      else
        Errors := Errors + 'Built-in field NOT applied: ' +
                  Comp.LibReference + ' / ' + Name + #13#10;
    end
    else if SetParameter(Comp, Name, Value) then
      Inc(Result)
    else
      Errors := Errors + 'Parameter NOT applied: ' + Comp.LibReference +
                ' / ' + Name + #13#10;
    P := E + 1;
  end;
end;

{ Clone the whole component to preserve internal display-mode metadata.
  Tested in AD 26.6.0: alternative mode names are preserved.
  No manual primitive copy or AddDisplayMode is performed. }
function CloneComponent(Lib : ISch_Lib;
                        SourceComp : ISch_Component;
                        TargetName : String) : ISch_Component;
var
  NewComp : ISch_Component;
  SourceModeCount, NewModeCount : Integer;
begin
  Result := Nil;
  SourceModeCount := SourceComp.DisplayModeCount;

  { Replicate is invoked on the component itself, not on its children. }
  NewComp := SourceComp.Replicate;
  if NewComp = Nil then
  begin
    ShowMessage('Replicate returned Nil for ' + TargetName);
    Exit;
  end;

  NewModeCount := NewComp.DisplayModeCount;
  if NewModeCount <> SourceModeCount then
  begin
    ShowMessage('Replicate mode count mismatch for ' + TargetName +
                #13#10 + 'Source modes: ' + IntToStr(SourceModeCount) +
                #13#10 + 'Copied modes: ' + IntToStr(NewModeCount) +
                #13#10 + 'Clone was NOT added to library.');
    Exit;
  end;

  NewComp.LibReference := TargetName;

  Lib.AddSchComponent(NewComp);
  Result := NewComp;
end;

procedure RunCloneTasks;
var
  Lib : ISch_Lib;
  Lines : TStringList;
  Content, TaskTag, TaskBody : String;
  SourceName, TargetName, Errors : String;
  P, E, CloseP, PassNo : Integer;
  Created, Modified, Skipped, ParametersApplied, TaskParameters : Integer;
  Comp, NewComp : ISch_Component;
begin
  if SchServer = Nil then
  begin
    ShowMessage('SchServer unavailable');
    Exit;
  end;
  if not FileExists(XML_FILE) then
  begin
    ShowMessage('XML file not found: ' + XML_FILE);
    Exit;
  end;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(XML_FILE);
    Content := Lines.Text;
  finally
    Lines.Free;
  end;

  if (Pos('<CloneTasks', Content) = 0) or
     (Pos('</CloneTasks>', Content) = 0) then
  begin
    ShowMessage('Invalid CloneTasks XML structure');
    Exit;
  end;

  Lib := GetLibraryByPath;
  if Lib = Nil then Exit;

  Created := 0;
  Modified := 0;
  Skipped := 0;
  Errors := '';
  ParametersApplied := 0;

  { Notify schematic server about the batch update. }
  { This is experimental for SchLib in Altium Designer 26.6.0. }
  SchServer.ProcessControl.PreProcess(Lib, '');
  try
    { Two passes: first clone, then edit original components. }
    for PassNo := 1 to 2 do
    begin
      P := 1;
      while True do
      begin
        P := FindNextTag(Content, 'Task', P);
        if P = 0 then Break;
        E := PosEx('>', Content, P);
        if E = 0 then Break;
        CloseP := PosEx('</Task>', Content, E + 1);
        if CloseP = 0 then
        begin
          Errors := Errors + 'Unclosed Task tag' + #13#10;
          Break;
        end;

        TaskTag := Copy(Content, P, E - P + 1);
        TaskBody := Copy(Content, E + 1, CloseP - E - 1);
        SourceName := TagAttribute(TaskTag, 'Source');
        TargetName := TagAttribute(TaskTag, 'Target');
        P := CloseP + Length('</Task>');

        if (PassNo = 1) and (TargetName = '') then Continue;
        if (PassNo = 2) and (TargetName <> '') then Continue;

        if SourceName = '' then
        begin
          Inc(Skipped);
          Errors := Errors + 'Missing Source' + #13#10;
          Continue;
        end;

        Comp := FindComponent(Lib, SourceName);
        if Comp = Nil then
        begin
          Inc(Skipped);
          Errors := Errors + 'Source not found: ' + SourceName + #13#10;
          Continue;
        end;

        if TargetName <> '' then
        begin
          if FindComponent(Lib, TargetName) <> Nil then
          begin
            Inc(Skipped);
            Errors := Errors + 'Target exists: ' + TargetName + #13#10;
            Continue;
          end;
          NewComp := CloneComponent(Lib, Comp, TargetName);
          if NewComp = Nil then
          begin
            Inc(Skipped);
            Errors := Errors + 'Clone failed: ' + TargetName + #13#10;
            Continue;
          end;
          TaskParameters := ApplyParameters(NewComp, TaskBody, Errors);
          ParametersApplied := ParametersApplied + TaskParameters;
          if (TaskParameters = 0) and (Pos('<Parameter', TaskBody) = 0) then
            Errors := Errors + 'No Parameter tags in clone task: ' + TargetName + #13#10;
          Inc(Created);
        end
        else
        begin
          TaskParameters := ApplyParameters(Comp, TaskBody, Errors);
          ParametersApplied := ParametersApplied + TaskParameters;
          if (TaskParameters = 0) and (Pos('<Parameter', TaskBody) = 0) then
            Errors := Errors + 'No Parameter tags in edit task: ' + SourceName + #13#10;
          Inc(Modified);
        end;
      end;
    end;

  finally
    SchServer.ProcessControl.PostProcess(Lib, '');
  end;

  Lib.GraphicallyInvalidate;
  ShowMessage('Processing completed.' + #13#10 +
              'Created: ' + IntToStr(Created) + #13#10 +
              'Modified: ' + IntToStr(Modified) + #13#10 +
              'Skipped: ' + IntToStr(Skipped) + #13#10 +
              'Parameters applied: ' + IntToStr(ParametersApplied) + #13#10 +
              Errors);
end;
