{ Altium Designer 26.6.0 DelphiScript - cautious XML replacement, PROJECT (loaded SchDoc only).
  Based on tested R13 RemoveSchObject + SCHM_PrimitiveRegistration +
  IntegratedLibraryManager.PlaceLibraryComponent.
  Entry points: AnalyzeXMLReplacements, ExecuteXMLReplacements.
  Run on a BACKUP. No automatic save. No automatic rollback on placement failure.
  Each sheet is activated and verified before destructive changes.
  Only Designator is copied; location/orientation used for positioning.
  Mirrored components skipped. Library pin geometry checked before replacement.
  No replacement limit. Aborts if any project SchDoc is not loaded. XML Task Source/Target attributes.
}
const
  XML_FILE = 'clone_config.xml';
  LIB_FILE = 'Library.SCHLIB';

function XMLAttr(const Tag, Attr: String): String;
var K,P,Q: Integer; Needle: String;
begin
  Result := '';
  Needle := Attr + '="'; K := Pos(Needle,Tag);
  if K = 0 then Exit;
  P := K + Length(Needle); Q := P;
  while (Q <= Length(Tag)) and (Tag[Q] <> '"') do Inc(Q);
  Result := Copy(Tag,P,Q-P);
end;

procedure ReadRules(Rules: TStringList);
var Lines: TStringList; S,Tag,Src,Dst: String; I,J,K,E: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(XML_FILE); S := Lines.Text; I := 1;
    while I <= Length(S) do
    begin
      J := Pos('<Task ',Copy(S,I,Length(S)-I+1));
      if J = 0 then Break;
      K := I+J-1; E := Pos('>',Copy(S,K,Length(S)-K+1));
      if E = 0 then Break;
      Tag := Copy(S,K,E); I := K+E;
      Src := XMLAttr(Tag,'Source'); Dst := XMLAttr(Tag,'Target');
      if (Src <> '') and (Dst <> '') then
      begin
        if Rules.IndexOfName(Src) < 0 then Rules.Add(Src+'='+Dst)
        else if Rules.Values[Src] <> Dst then Rules.Values[Src] := '#CONFLICT#';
      end;
    end;
  finally Lines.Free; end;
end;

function LibComponent(Lib: ISch_Document; const RefName: String): ISch_Component;
var It: ISch_Iterator; C: ISch_Component;
begin
  Result := Nil;
  It := Lib.SchLibIterator_Create;
  if It = Nil then Exit;
  try
    It.AddFilter_ObjectSet(MkSet(eSchComponent));
    C := It.FirstSchObject;
    while C <> Nil do
    begin
      if C.LibReference = RefName then begin Result := C; Break; end;
      C := It.NextSchObject;
    end;
  finally Lib.SchIterator_Destroy(It); end;
end;

function PinRecords(C: ISch_Component; Records: TStringList): Boolean;
var It: ISch_Iterator; P: ISch_Pin;
begin
  Result := False; Records.Clear;
  if C = Nil then Exit;
  It := C.SchIterator_Create;
  if It = Nil then Exit;
  try
    It.AddFilter_ObjectSet(MkSet(ePin));
    P := It.FirstSchObject;
    while P <> Nil do
    begin
      Records.Add(IntToStr(P.OwnerPartDisplayMode)+'|'+P.Designator+'|'+
                  IntToStr(P.Location.X)+'|'+IntToStr(P.Location.Y));
      P := It.NextSchObject;
    end;
  finally C.SchIterator_Destroy(It); end;
  Records.Sort; Result := Records.Count > 0;
end;

function GeometryMatches(Lib: ISch_Document; const Src,Dst: String): Boolean;
var A,B: TStringList; C1,C2: ISch_Component;
begin
  Result := False;
  C1 := LibComponent(Lib,Src); C2 := LibComponent(Lib,Dst);
  if (C1 = Nil) or (C2 = Nil) then Exit;
  A := TStringList.Create; B := TStringList.Create;
  try
    if PinRecords(C1,A) and PinRecords(C2,B) then Result := A.Text = B.Text;
  finally B.Free; A.Free; end;
end;

function FindDesignator(Doc: ISch_Document; const Des: String; var Count: Integer): ISch_Component;
var It: ISch_Iterator; C: ISch_Component;
begin
  Result := Nil; Count := 0;
  It := Doc.SchIterator_Create;
  if It = Nil then Exit;
  try
    It.AddFilter_ObjectSet(MkSet(eSchComponent));
    C := It.FirstSchObject;
    while C <> Nil do
    begin
      if C.Designator.Text = Des then begin Inc(Count); Result := C; end;
      C := It.NextSchObject;
    end;
  finally Doc.SchIterator_Destroy(It); end;
end;

function FindPlaced(Doc: ISch_Document; const RefName: String;
                    X,Y,Orient: Integer; var Count: Integer): ISch_Component;
var It: ISch_Iterator; C: ISch_Component;
begin
  Result := Nil; Count := 0;
  It := Doc.SchIterator_Create;
  if It = Nil then Exit;
  try
    It.AddFilter_ObjectSet(MkSet(eSchComponent));
    C := It.FirstSchObject;
    while C <> Nil do
    begin
      if (C.LibReference = RefName) and (C.Location.X = X) and
         (C.Location.Y = Y) and (C.Orientation = Orient) and
         (not C.IsMirrored) then begin Inc(Count); Result := C; end;
      C := It.NextSchObject;
    end;
  finally Doc.SchIterator_Destroy(It); end;
end;

function ActivateSheetSafely(const Path: String): Boolean;
var ServerDoc: IDocument; ActiveSch: ISch_Document;
begin
  Result := False;
  ServerDoc := Client.GetDocumentByPath(Path);
  if ServerDoc = Nil then
    ServerDoc := Client.OpenDocument('SCH', Path);
  if ServerDoc = Nil then Exit;
  Client.ShowDocument(ServerDoc);
  ActiveSch := SchServer.GetCurrentSchDocument;
  if ActiveSch = Nil then Exit;
  { Compare actual document interface to intended sheet interface. }
  Result := ActiveSch = SchServer.GetSchDocumentByPath(Path);
end;

procedure RunXMLReplacements(DoReplace: Boolean);
var Doc,Lib: ISch_Document; Project: IProject; DocInfo: IDocument;
    Rules,Jobs,Report,SheetPaths: TStringList;
    It: ISch_Iterator; C,OldC,NewC: ISch_Component;
    Src,Dst,Des,Options,Entry,Reason: String;
    I,N,Count,PlacedCount,X,Y,Orient,DoneCount,Skipped,SheetIndex,SheetCount: Integer;
    DocPath: String;
    Ready,Ok: Boolean;
begin
  if SchServer = Nil then Exit;
  Project := GetWorkspace.DM_FocusedProject;
  if Project = Nil then begin ShowMessage('Open/focus a PCB project.'); Exit; end;
  Lib := SchServer.GetSchDocumentByPath(LIB_FILE);
  if Lib = Nil then begin ShowMessage('Open the SchLib in LIB_FILE first.'); Exit; end;
  Rules := TStringList.Create; Jobs := TStringList.Create; Report := TStringList.Create;
  SheetPaths := TStringList.Create;
  try
    ReadRules(Rules);
    if Rules.Count = 0 then begin ShowMessage('No <Task Source="..." Target="..."> rules found.'); Exit; end;
    SheetCount := 0;
    for SheetIndex := 0 to Project.DM_LogicalDocumentCount-1 do
    begin
      DocInfo := Project.DM_LogicalDocuments(SheetIndex);
      if (DocInfo <> Nil) and (DocInfo.DM_DocumentKind = 'SCH') then
      begin
        DocPath := DocInfo.DM_FullPath;
        Doc := SchServer.GetSchDocumentByPath(DocPath);
        if Doc = Nil then
        begin
          ShowMessage('ABORT: project SchDoc is not loaded. Open all project sheets first:'+#13#10+DocPath);
          Exit;
        end;
        SheetPaths.Add(DocPath);
      end;
    end;
    if SheetPaths.Count = 0 then begin ShowMessage('No loaded project SchDoc found.'); Exit; end;
    for SheetIndex := 0 to SheetPaths.Count-1 do
    begin
      DocPath := SheetPaths[SheetIndex];
      Doc := SchServer.GetSchDocumentByPath(DocPath);
      Report.Add('SHEET: '+DocPath);
    It := Doc.SchIterator_Create;
    if It = Nil then Exit;
    try
      It.AddFilter_ObjectSet(MkSet(eSchComponent));
      C := It.FirstSchObject;
      while C <> Nil do
      begin
        Src := C.LibReference; Dst := Rules.Values[Src];
        if Dst <> '' then
        begin
          Des := C.Designator.Text; Reason := '';
          if Dst = '#CONFLICT#' then Reason := 'conflicting XML rules'
          else if C.IsMirrored then Reason := 'mirrored component'
          else if Des = '' then Reason := 'empty designator'
          else if not GeometryMatches(Lib,Src,Dst) then Reason := 'missing library part or pin geometry mismatch';
          if Reason = '' then
          begin
            Jobs.Add(DocPath+'|'+Des+'='+Src+'|'+Dst);
            Report.Add('READY '+DocPath+' / '+Des+' : '+Src+' -> '+Dst);
          end
          else Report.Add('SKIP '+DocPath+' / '+Des+' : '+Reason);
        end;
        C := It.NextSchObject;
      end;
    finally Doc.SchIterator_Destroy(It); end;
    end;
    Report.Add('READY COUNT = '+IntToStr(Jobs.Count));
    Report.Add('SHEETS = '+IntToStr(SheetPaths.Count));
    if not DoReplace then
    begin
      Report.Add('NO CHANGES MADE.');
      Report.SaveToFile(ChangeFileExt(XML_FILE,'.project_analyze_report.txt'));
      ShowMessage('Analysis complete: '+IntToStr(Jobs.Count)+' ready on '+
                  IntToStr(SheetPaths.Count)+' sheets. See .project_analyze_report.txt');
      Exit;
    end;
    if Jobs.Count = 0 then begin ShowMessage(Report.Text); Exit; end;
    if MessageDlg('PROJECT: '+IntToStr(Jobs.Count)+' candidates across '+IntToStr(SheetPaths.Count)+' sheets.'+#13#10+
                  'Replace ALL eligible components?'+#13#10+
                  'BACKUP REQUIRED. No autosave or rollback on placement failure.',
                  mtConfirmation,mbYesNo,0) <> mrYes then Exit;
    DoneCount := 0; Skipped := 0;
    for I := 0 to Jobs.Count-1 do
    begin
      Entry := Jobs[I];
      N := Pos('|',Entry);
      if N = 0 then Continue;
      DocPath := Copy(Entry,1,N-1);
      Entry := Copy(Entry,N+1,Length(Entry)-N);
      N := Pos('=',Entry);
      if N = 0 then Continue;
      Des := Copy(Entry,1,N-1);
      Entry := Copy(Entry,N+1,Length(Entry)-N);
      Doc := SchServer.GetSchDocumentByPath(DocPath);
      if Doc = Nil then begin Report.Add('STOP: sheet became unavailable: '+DocPath); Break; end;
      N := Pos('|',Entry);
      if N = 0 then Continue;
      Src := Copy(Entry,1,N-1); Dst := Copy(Entry,N+1,Length(Entry)-N);
      OldC := FindDesignator(Doc,Des,Count);
      if (Count <> 1) or (OldC = Nil) then begin Inc(Skipped); Continue; end;
      if (OldC.LibReference <> Src) or OldC.IsMirrored then begin Inc(Skipped); Continue; end;
      if not GeometryMatches(Lib,Src,Dst) then begin Inc(Skipped); Continue; end;
      { Critical: PlaceLibraryComponent targets the ACTIVE editor document. }
      if not ActivateSheetSafely(DocPath) then
      begin
        Report.Add('STOP: could not activate/verify sheet: '+DocPath);
        Break;
      end;
      Doc := SchServer.GetCurrentSchDocument;
      { Re-acquire component after document activation. }
      OldC := FindDesignator(Doc,Des,Count);
      if (Count <> 1) or (OldC = Nil) then
      begin Report.Add('STOP: old component not unique after activation: '+Des); Break; end;
      if (OldC.LibReference <> Src) or OldC.IsMirrored then
      begin Report.Add('STOP: old component changed after activation: '+Des); Break; end;
      X := OldC.Location.X; Y := OldC.Location.Y; Orient := OldC.Orientation;
      NewC := FindPlaced(Doc,Dst,X,Y,Orient,PlacedCount);
      if PlacedCount <> 0 then begin Inc(Skipped); Continue; end;
      Options := 'Orientation='+IntToStr(Orient)+'|Location.X='+IntToStr(X)+
                 '|Location.Y='+IntToStr(Y);
      Ok := True;
      SchServer.ProcessControl.PreProcess(Doc,'');
      try
        Doc.RemoveSchObject(OldC);
        SchServer.RobotManager.SendMessage(Doc.I_ObjectAddress,c_BroadCast,
                                           SCHM_PrimitiveRegistration,OldC.I_ObjectAddress);
        IntegratedLibraryManager.PlaceLibraryComponent(Dst,LIB_FILE,Options);
      except Ok := False; end;
      SchServer.ProcessControl.PostProcess(Doc,'');
      Doc.GraphicallyInvalidate;
      if not Ok then begin Report.Add('STOP: place error at '+Des+'. DO NOT SAVE.'); Break; end;
      if SchServer.GetCurrentSchDocument <> Doc then
      begin Report.Add('STOP: active sheet changed during placement. DO NOT SAVE.'); Break; end;
      NewC := FindPlaced(Doc,Dst,X,Y,Orient,PlacedCount);
      if (PlacedCount <> 1) or (NewC = Nil) then
      begin Report.Add('STOP: cannot uniquely identify placed '+Des+'. DO NOT SAVE.'); Break; end;
      SchServer.ProcessControl.PreProcess(Doc,'');
      try
        SchServer.RobotManager.SendMessage(NewC.I_ObjectAddress,c_BroadCast,
                                           SCHM_BeginModify,c_NoEventData);
        NewC.Designator.Text := Des;
        SchServer.RobotManager.SendMessage(NewC.I_ObjectAddress,c_BroadCast,
                                           SCHM_EndModify,c_NoEventData);
      finally SchServer.ProcessControl.PostProcess(Doc,''); end;
      Doc.GraphicallyInvalidate;
      NewC := FindDesignator(Doc,Des,Count);
      if (Count <> 1) or (NewC = Nil) then
      begin Report.Add('STOP: designator check failed at '+Des+'. DO NOT SAVE.'); Break; end;
      if NewC.LibReference <> Dst then
      begin Report.Add('STOP: target reference check failed at '+Des+'. DO NOT SAVE.'); Break; end;
      Inc(DoneCount); Report.Add('DONE '+DocPath+' / '+Des+' -> '+Dst);
    end;
    Report.Add('REPLACED = '+IntToStr(DoneCount)+'; SKIPPED DURING RUN = '+IntToStr(Skipped));
    Report.Add('NO AUTOMATIC SAVE. Check tree, wiring, ERC and Undo.');
    Report.SaveToFile(ChangeFileExt(XML_FILE,'.project_replace_report.txt'));
    ShowMessage('Replaced: '+IntToStr(DoneCount)+'; skipped: '+IntToStr(Skipped)+
                '. Report: '+ChangeFileExt(XML_FILE,'.project_replace_report.txt'));
  finally SheetPaths.Free; Report.Free; Jobs.Free; Rules.Free; end;
end;

procedure AnalyzeXMLReplacements;
begin RunXMLReplacements(False); end;

procedure ExecuteXMLReplacements;
begin RunXMLReplacements(True); end;
