{ CloneTasks.pas - Altium Designer DelphiScript
  Entry point: RunCloneTasks
  Fixed-format XML reader, no COM/MSXML.
  Clone full components via Replicate to preserve graphical modes and their names.
  Confirmed by user test in Altium Designer 26.6.0.
  XML attribute values must use double quotes.
  Test on a BACKUP of the SchLib first.
}

const
  XML_FILE = 'C:\Altium\clone_config.xml';
  LIB_FILE = 'C:\Altium\Components.SchLib';

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

procedure SetParameter(Comp : ISch_Component; Name, Value : String);
var
  P : ISch_Parameter;
begin
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
end;

procedure ApplyParameters(Comp : ISch_Component; TaskBody : String);
var
  P, E : Integer;
  Tag, Name, Value : String;
begin
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
    if Name <> '' then SetParameter(Comp, Name, Value);
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
  Created, Modified, Skipped : Integer;
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
        ApplyParameters(NewComp, TaskBody);
        Inc(Created);
      end
      else
      begin
        ApplyParameters(Comp, TaskBody);
        Inc(Modified);
      end;
    end;
  end;

  Lib.GraphicallyInvalidate;
  ShowMessage('Processing completed.' + #13#10 +
              'Created: ' + IntToStr(Created) + #13#10 +
              'Modified: ' + IntToStr(Modified) + #13#10 +
              'Skipped: ' + IntToStr(Skipped) + #13#10 +
              Errors);
end;
