{ Altium Designer 26.6.0 / DelphiScript
  Five-stage footprint processing:
  1. Collect unique project footprint names.
  2. Catalog all footprints in project PcbLib documents.
  3. Match names without geometry comparison.
  4. Compare available geometry signatures.
  5. Transfer approved library originals to a target PcbLib.
  Geometry checks are partial; transfer can modify the destination library.
  Entry point: RunFootprintAnalysisAndTransfer.
}

Var
    GAttentionEntries : Array[0..4095] Of String;
    GAttentionCount : Integer;
    GCheckpointPath : String;
    GReportFile : TextFile;
    GReportOpen : Boolean;

{ Open once, append lines while running, close in the outer Finally. }
Procedure WriteCheckpoint(LineText : String);
Begin
    If Not GReportOpen Then Exit;
    WriteLn(GReportFile, DateTimeToStr(Now) + ' | ' + LineText);
    Flush(GReportFile);
End;

{ Geometry for IPCB_Component (typed GroupIterator_Create/Destroy). }
Function CountPadsInGroupPCB(Comp : IPCB_Component) : Integer;
Var
    It  : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
Begin
    Result := 0;
    It := Comp.GroupIterator_Create;
    If It = Nil Then Exit;
    It.AddFilter_ObjectSet(MkSet(ePadObject));
    Obj := It.FirstPCBObject;
    While Obj <> Nil Do
    Begin
        Inc(Result);
        Obj := It.NextPCBObject;
    End;
    Comp.GroupIterator_Destroy(It);
End;


{ Translation/rotation/mirror invariant pad-center distance signature.
  Distances rounded to 0.01 mm. Does not compare pad sizes, numbering,
  holes, copper layers, mask or graphics. }
Function PadDistanceSignaturePCB(Comp : IPCB_Component) : String;
Var
    It    : IPCB_GroupIterator;
    Pad   : IPCB_Pad;
    Xs    : TStringList;
    Ys    : TStringList;
    Ds    : TStringList;
    I, J  : Integer;
    DX, DY, D : Double;
Begin
    Result := '';
    Xs := TStringList.Create;
    Ys := TStringList.Create;
    Ds := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Xs.Add(FloatToStr(CoordToMMs(Pad.X)));
            Ys.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);

        For I := 0 To Xs.Count - 1 Do
            For J := I + 1 To Xs.Count - 1 Do
            Begin
                DX := StrToFloat(Xs[I]) - StrToFloat(Xs[J]);
                DY := StrToFloat(Ys[I]) - StrToFloat(Ys[J]);
                D := Sqrt(DX * DX + DY * DY);
                { Integer hundredths of a millimeter avoids locale-specific decimals. }
                Ds.Add(IntToStr(Round(D * 100)));
            End;
        Ds.Sort;
        For I := 0 To Ds.Count - 1 Do
            Result := Result + Ds[I] + ';';
    Finally
        Ds.Free;
        Ys.Free;
        Xs.Free;
    End;
End;


{ Pad dimensions and hole diameter signature.
  X/Y dimensions are normalized so footprint rotation does not affect result.
  This is an additional screening test, not a full pad-stack comparison. }
Function PadSizeSignaturePCB(Comp : IPCB_Component) : String;
Var
    It   : IPCB_GroupIterator;
    Pad  : IPCB_Pad;
    Items: TStringList;
    A, B, H, T : Integer;
    I    : Integer;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            { Integer coordinates, avoiding decimal-format locale differences. }
            A := Pad.TopXSize;
            B := Pad.TopYSize;
            H := Pad.HoleSize;
            If A > B Then
            Begin
                T := A; A := B; B := T;
            End;
            Items.Add(IntToStr(A) + '/' + IntToStr(B) + '/' + IntToStr(H));
            Pad := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ Pad-name-aware signature: each pad designator is associated with
  its size/hole and sorted distances to every other pad, keyed by
  the other pad's designator. Translation/rotation invariant.
  Mirror invariant too; this is not a complete footprint comparison. }
{ Mid/bottom pad dimensions by pad name; independent of placement.
  This is NOT a full pad stack check (shape, mask, paste, hole type,
  plating, rotation and layer-specific stacks are not inspected). }
Function PadInnerOuterSignaturePCB(Comp : IPCB_Component) : String;
Var
    It : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Items : TStringList;
    I : Integer;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Items.Add(Pad.Name + ':Mid=' +
                IntToStr(Pad.MidXSize) + 'x' + IntToStr(Pad.MidYSize) +
                ':Bottom=' + IntToStr(Pad.BotXSize) + 'x' +
                IntToStr(Pad.BotYSize));
            Pad := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;

Function PadNamedSignaturePCB(Comp : IPCB_Component) : String;
Var
    It : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Names, Xs, Ys, Sizes, Lines, Neighbors : TStringList;
    I, J, A, B, H, T : Integer;
    DX, DY, D : Double;
    Line : String;
Begin
    Result := '';
    Names := TStringList.Create;
    Xs := TStringList.Create;
    Ys := TStringList.Create;
    Sizes := TStringList.Create;
    Lines := TStringList.Create;
    Neighbors := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Names.Add(Pad.Name);
            Xs.Add(FloatToStr(CoordToMMs(Pad.X)));
            Ys.Add(FloatToStr(CoordToMMs(Pad.Y)));
            A := Pad.TopXSize;
            B := Pad.TopYSize;
            H := Pad.HoleSize;
            If A > B Then
            Begin
                T := A; A := B; B := T;
            End;
            Sizes.Add(IntToStr(A) + '/' + IntToStr(B) + '/' + IntToStr(H));
            Pad := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);

        For I := 0 To Names.Count - 1 Do
        Begin
            Neighbors.Clear;
            For J := 0 To Names.Count - 1 Do
            Begin
                If I <> J Then
                Begin
                    DX := StrToFloat(Xs[I]) - StrToFloat(Xs[J]);
                    DY := StrToFloat(Ys[I]) - StrToFloat(Ys[J]);
                    D := Sqrt(DX * DX + DY * DY);
                    Neighbors.Add(Names[J] + ':' + IntToStr(Round(D * 100)));
                End;
            End;
            Neighbors.Sort;
            Line := Names[I] + '|' + Sizes[I] + '|';
            For J := 0 To Neighbors.Count - 1 Do
                Line := Line + Neighbors[J] + ',';
            Lines.Add(Line);
        End;
        Lines.Sort;
        For I := 0 To Lines.Count - 1 Do
            Result := Result + Lines[I] + #10;
    Finally
        Neighbors.Free;
        Lines.Free;
        Sizes.Free;
        Ys.Free;
        Xs.Free;
        Names.Free;
    End;
End;


{ Count basic non-pad primitives in the footprint/component group.
  This detects missing/extra primitives, but NOT geometry differences. }
{ Per-layer primitive counts. This is a diagnostic screening test,
  not a comparison of primitive shapes or positions.
  Layer identifiers are compared as returned by Altium; flipped components
  may require a layer mapping in a later version. }
Function PrimitiveCountSignaturePCB(Comp : IPCB_Component) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    Keys : TStringList;
    Key, Kind : String;
    KeyIndex, I : Integer;
Begin
    Result := '';
    Keys := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then
        Begin
            Result := 'ITERATOR ERROR';
            Exit;
        End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject,
                                     eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            Kind := '';
            If Obj.ObjectId = eTrackObject Then Kind := 'Track';
            If Obj.ObjectId = eArcObject Then Kind := 'Arc';
            If Obj.ObjectId = eFillObject Then Kind := 'Fill';
            If Obj.ObjectId = eTextObject Then Kind := 'Text';
            If Obj.ObjectId = eRegionObject Then Kind := 'Region';
            If Kind <> '' Then
            Begin
                Key := Kind + '@Layer' + IntToStr(Ord(Obj.Layer));
                KeyIndex := Keys.IndexOfName(Key);
                If KeyIndex < 0 Then
                    Keys.Add(Key + '=1')
                Else
                    Keys.ValueFromIndex[KeyIndex] :=
                        IntToStr(StrToInt(Keys.ValueFromIndex[KeyIndex]) + 1);
            End;
            Obj := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Keys.Sort;
        For I := 0 To Keys.Count - 1 Do
            Result := Result + Keys[I] + '; ';
    Finally
        Keys.Free;
    End;
End;


{ Track width/length per layer. Length is rotation/translation invariant.
  Rounded to 0.01 mm. This is NOT a full geometry comparison. }
Function TrackDimensionSignaturePCB(Comp : IPCB_Component) : String;
Var
    It : IPCB_GroupIterator;
    Track : IPCB_Track;
    Items : TStringList;
    I : Integer;
    DX, DY, L : Double;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then
        Begin
            Result := 'ITERATOR ERROR';
            Exit;
        End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject));
        Track := It.FirstPCBObject;
        While Track <> Nil Do
        Begin
            DX := CoordToMMs(Track.X2 - Track.X1);
            DY := CoordToMMs(Track.Y2 - Track.Y1);
            L := Sqrt(DX * DX + DY * DY);
            Items.Add('Layer' + IntToStr(Ord(Track.Layer)) +
                      ':Width=' + IntToStr(Round(CoordToMMs(Track.Width) * 100)) +
                      ':Length=' + IntToStr(Round(L * 100)));
            Track := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ Track endpoint geometry relative to NAMED pad centers.
  Translation/rotation invariant, endpoint order independent.
  Distances rounded to 0.01 mm; reflection is not distinguished.
  The comparison still does not prove full footprint identity. }
Function TrackPositionSignaturePCB(Comp : IPCB_Component) : String;
Var
    PadIt : IPCB_GroupIterator;
    TrackIt : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Track : IPCB_Track;
    PadNames, PadXs, PadYs, Items, End1, End2 : TStringList;
    I : Integer;
    DX, DY, D : Double;
    S1, S2, Temp : String;
Begin
    Result := '';
    PadNames := TStringList.Create;
    PadXs := TStringList.Create;
    PadYs := TStringList.Create;
    Items := TStringList.Create;
    End1 := TStringList.Create;
    End2 := TStringList.Create;
    Try
        PadIt := Comp.GroupIterator_Create;
        If PadIt = Nil Then
        Begin
            Result := 'PAD ITERATOR ERROR';
            Exit;
        End;
        PadIt.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := PadIt.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            PadNames.Add(Pad.Name);
            PadXs.Add(FloatToStr(CoordToMMs(Pad.X)));
            PadYs.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := PadIt.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(PadIt);

        TrackIt := Comp.GroupIterator_Create;
        If TrackIt = Nil Then
        Begin
            Result := 'TRACK ITERATOR ERROR';
            Exit;
        End;
        TrackIt.AddFilter_ObjectSet(MkSet(eTrackObject));
        Track := TrackIt.FirstPCBObject;
        While Track <> Nil Do
        Begin
            End1.Clear;
            End2.Clear;
            For I := 0 To PadNames.Count - 1 Do
            Begin
                DX := CoordToMMs(Track.X1) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Track.Y1) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                End1.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));

                DX := CoordToMMs(Track.X2) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Track.Y2) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                End2.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));
            End;
            End1.Sort;
            End2.Sort;
            S1 := '';
            S2 := '';
            For I := 0 To End1.Count - 1 Do
            Begin
                S1 := S1 + End1[I] + ',';
                S2 := S2 + End2[I] + ',';
            End;
            If S1 > S2 Then
            Begin
                Temp := S1; S1 := S2; S2 := Temp;
            End;
            Items.Add('Layer' + IntToStr(Ord(Track.Layer)) +
                      ':Width=' + IntToStr(Round(CoordToMMs(Track.Width) * 100)) +
                      ':EndA=' + S1 + ':EndB=' + S2);
            Track := TrackIt.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(TrackIt);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        End2.Free;
        End1.Free;
        Items.Free;
        PadYs.Free;
        PadXs.Free;
        PadNames.Free;
    End;
End;

{ Class-specific per-layer counts. }
{ Arc geometry screening: radius, line width, sweep angle and center
  distances to named pads. Does not verify arc start direction.
  For flipped components layer mapping is not normalized. }
Function ArcGeometrySignaturePCB(Comp : IPCB_Component) : String;
Var
    ArcIt, PadIt : IPCB_GroupIterator;
    Arc : IPCB_Arc;
    Pad : IPCB_Pad;
    PadNames, PadXs, PadYs, Entries, Distances : TStringList;
    I : Integer;
    DX, DY, D, Sweep : Double;
    Entry : String;
Begin
    Result := '';
    PadNames := TStringList.Create;
    PadXs := TStringList.Create;
    PadYs := TStringList.Create;
    Entries := TStringList.Create;
    Distances := TStringList.Create;
    Try
        PadIt := Comp.GroupIterator_Create;
        If PadIt = Nil Then Begin Result := 'PAD ITERATOR ERROR'; Exit; End;
        PadIt.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := PadIt.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            PadNames.Add(Pad.Name);
            PadXs.Add(FloatToStr(CoordToMMs(Pad.X)));
            PadYs.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := PadIt.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(PadIt);

        ArcIt := Comp.GroupIterator_Create;
        If ArcIt = Nil Then Begin Result := 'ARC ITERATOR ERROR'; Exit; End;
        ArcIt.AddFilter_ObjectSet(MkSet(eArcObject));
        Arc := ArcIt.FirstPCBObject;
        While Arc <> Nil Do
        Begin
            Sweep := Abs(Arc.EndAngle - Arc.StartAngle);
            While Sweep > 360 Do Sweep := Sweep - 360;
            Entry := 'L' + IntToStr(Ord(Arc.Layer)) +
                     '/R' + IntToStr(Round(CoordToMMs(Arc.Radius) * 100)) +
                     '/W' + IntToStr(Round(CoordToMMs(Arc.LineWidth) * 100)) +
                     '/Sweep' + IntToStr(Round(Sweep * 100));
            Distances.Clear;
            For I := 0 To PadNames.Count - 1 Do
            Begin
                DX := CoordToMMs(Arc.XCenter) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Arc.YCenter) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                Distances.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));
            End;
            Distances.Sort;
            For I := 0 To Distances.Count - 1 Do
                Entry := Entry + '/' + Distances[I];
            Entries.Add(Entry);
            Arc := ArcIt.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(ArcIt);
        Entries.Sort;
        For I := 0 To Entries.Count - 1 Do
            Result := Result + Entries[I] + ';';
    Finally
        Distances.Free;
        Entries.Free;
        PadYs.Free;
        PadXs.Free;
        PadNames.Free;
    End;
End;

Function PrimitiveClassSignaturePCB(Comp : IPCB_Component; ClassId : Integer) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    Keys : TStringList;
    Key : String;
    KeyIndex, I : Integer;
Begin
    Result := '';
    Keys := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Begin Result := 'ITERATOR ERROR'; Exit; End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            If Ord(Obj.ObjectId) = ClassId Then
            Begin
                Key := 'Layer' + IntToStr(Ord(Obj.Layer));
                KeyIndex := Keys.IndexOfName(Key);
                If KeyIndex < 0 Then Keys.Add(Key + '=1')
                Else Keys.ValueFromIndex[KeyIndex] := IntToStr(StrToInt(Keys.ValueFromIndex[KeyIndex]) + 1);
            End;
            Obj := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Keys.Sort;
        For I := 0 To Keys.Count - 1 Do Result := Result + Keys[I] + ';';
    Finally
        Keys.Free;
    End;
End;

{ Returns C (this footprint), G (all footprints), or N (do not ignore).
  Global policy is keyed by class, local policy by footprint + class.
  Decisions persist only during the current run. }
{ Stage 40: unlike InputBox, InputQuery distinguishes Cancel from OK.
  Cancel invokes SysUtils.Abort, immediately unwinding the entire script,
  including nested analysis/transfer procedures.  Already copied objects
  are not rolled back; no further items are processed. }
Function AskInputOrAbort(DialogTitle, PromptText, DefaultAnswer : String) : String;
Var
    AnswerText : String;
Begin
    { DelphiScript does not expose InputQuery. InputBox returns its
      default value when Cancel is pressed. A reserved marker makes
      Cancel distinguishable from user-entered commands. }
    AnswerText := InputBox(DialogTitle,
        PromptText + #13#10 +
        'Cancel = stop entire script. Enter a choice and press OK.',
        '__CANCEL_SCRIPT__');
    If AnswerText = '__CANCEL_SCRIPT__' Then
        Abort;
    Result := AnswerText;
End;

Function IgnoreClassDifference(FootprintName, ClassName : String;
                               GlobalPolicy, LocalPolicy : TStringList) : Boolean;
Var
    Key, Choice : String;
Begin
    Result := False;
    Key := FootprintName + '|' + ClassName;
    If GlobalPolicy.IndexOf(ClassName) >= 0 Then Begin Result := True; Exit; End;
    If LocalPolicy.IndexOf(Key) >= 0 Then Begin Result := True; Exit; End;
    Choice := '';
    While (Choice <> 'C') And (Choice <> 'G') And (Choice <> 'N') Do
    Begin
        Choice := UpperCase(Trim(AskInputOrAbort('Footprint mismatch: ' + ClassName,
            'Footprint: ' + FootprintName + #13#10 +
            'C = ignore class for this footprint' + #13#10 +
            'G = ignore class for entire run' + #13#10 +
            'N = do NOT ignore (continue comparing)' + #13#10 +
            'Enter C, G or N:', 'N')));
        If Choice = '' Then Choice := 'N';
    End;
    If Choice = 'G' Then GlobalPolicy.Add(ClassName);
    If Choice = 'C' Then LocalPolicy.Add(Key);
    Result := (Choice <> 'N');
End;

{ Detailed side-by-side diagnostic output goes directly to the open report. }
Procedure AddSignatureDifference(Caption, PCBValue, LibValue : String);
Begin
    If PCBValue <> LibValue Then
    Begin
        WriteCheckpoint('    ' + Caption + ': DIFFERENT');
    End
    Else
        WriteCheckpoint('    ' + Caption + ': EQUAL');
End;

{ DelphiScript-compatible separator conversion: no [rfReplaceAll] set. }
Function SemicolonsToLines(Value : String) : String;
Var
    CharPos : Integer;
Begin
    Result := '';
    For CharPos := 1 To Length(Value) Do
    Begin
        If Value[CharPos] = ';' Then
            Result := Result + #13#10
        Else
            Result := Result + Value[CharPos];
    End;
End;

{ Parse per-layer count from PrimitiveClassSignaturePCB output. }
Function CountForLayer(Signature, LayerKey : String) : Integer;
Var
    Parts : TStringList;
    I, EqPos : Integer;
    Entry : String;
Begin
    Result := 0;
    Parts := TStringList.Create;
    Try
        Parts.Text := SemicolonsToLines(Signature);
        For I := 0 To Parts.Count - 1 Do
        Begin
            Entry := Trim(Parts[I]);
            EqPos := Pos('=', Entry);
            If EqPos > 0 Then
                If Copy(Entry, 1, EqPos - 1) = LayerKey Then
                Begin
                    Result := StrToInt(Copy(Entry, EqPos + 1, Length(Entry)));
                    Exit;
                End;
        End;
    Finally
        Parts.Free;
    End;
End;

Procedure AddLayerDetails(PCBValue, LibValue : String);
Var
    Parts, Layers : TStringList;
    I, EqPos, PC, LC : Integer;
    Entry, Key : String;
Begin
    Parts := TStringList.Create;
    Layers := TStringList.Create;
    Try
        Parts.Text := SemicolonsToLines(PCBValue + ';' + LibValue);
        For I := 0 To Parts.Count - 1 Do
        Begin
            Entry := Trim(Parts[I]);
            EqPos := Pos('=', Entry);
            If EqPos > 0 Then
            Begin
                Key := Copy(Entry, 1, EqPos - 1);
                If Layers.IndexOf(Key) < 0 Then Layers.Add(Key);
            End;
        End;
        Layers.Sort;
        If Layers.Count = 0 Then WriteCheckpoint('    No per-layer primitives found');
        For I := 0 To Layers.Count - 1 Do
        Begin
            Key := Layers[I];
            PC := CountForLayer(PCBValue, Key);
            LC := CountForLayer(LibValue, Key);
            If PC <> LC Then
                WriteCheckpoint('    ' + Key + ': PCB=' + IntToStr(PC) +
                    ', LIB=' + IntToStr(LC) + ', delta(LIB-PCB)=' + IntToStr(LC-PC))
            Else
                WriteCheckpoint('    ' + Key + ': PCB=' + IntToStr(PC) +
                    ', LIB=' + IntToStr(LC) + ' [EQUAL]');
        End;
    Finally
        Layers.Free;
        Parts.Free;
    End;
End;


{ Screening for Fill/Text/Region: compare object bounding dimensions and layer.
  Bounding boxes are NOT a substitute for exact polygon or text geometry. }
Function OtherPrimitiveSignaturePCB(Comp : IPCB_Component; WantedId : Integer) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    TextObj : IPCB_Text;
    Items : TStringList;
    R : TCoordRect;
    W, H, Temp, I : Integer;
    Entry : String;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := Comp.GroupIterator_Create;
        If It = Nil Then Begin Result := 'ITERATOR ERROR'; Exit; End;
        It.AddFilter_ObjectSet(MkSet(eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            If Ord(Obj.ObjectId) = WantedId Then
            Begin
                R := Obj.BoundingRectangle;
                W := Abs(R.Right - R.Left);
                H := Abs(R.Top - R.Bottom);
                If W > H Then
                Begin
                    Temp := W; W := H; H := Temp;
                End;
                Entry := 'Layer' + IntToStr(Ord(Obj.Layer)) +
                         '/Bounds=' + IntToStr(Round(CoordToMMs(W) * 100)) +
                         'x' + IntToStr(Round(CoordToMMs(H) * 100));
                If WantedId = Ord(eTextObject) Then
                Begin
                    TextObj := Obj;
                    Entry := Entry + '/Text=' + TextObj.Text;
                End;
                Items.Add(Entry);
            End;
            Obj := It.NextPCBObject;
        End;
        Comp.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ 3D Body count per component. This does not inspect STEP contents,
  height, orientation, offsets or model identity. }
Function Count3DBodiesPCB(Comp : IPCB_Component) : Integer;
Var
    BodyIt : IPCB_GroupIterator;
    BodyObj : IPCB_Primitive;
Begin
    Result := 0;
    BodyIt := Comp.GroupIterator_Create;
    If BodyIt = Nil Then Exit;
    BodyIt.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
    BodyObj := BodyIt.FirstPCBObject;
    While BodyObj <> Nil Do
    Begin
        Inc(Result);
        BodyObj := BodyIt.NextPCBObject;
    End;
    Comp.GroupIterator_Destroy(BodyIt);
End;


{ Geometry for IPCB_LibComponent (typed GroupIterator_Create/Destroy). }
Function CountPadsInGroupLib(FP : IPCB_LibComponent) : Integer;
Var
    It  : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
Begin
    Result := 0;
    It := FP.GroupIterator_Create;
    If It = Nil Then Exit;
    It.AddFilter_ObjectSet(MkSet(ePadObject));
    Obj := It.FirstPCBObject;
    While Obj <> Nil Do
    Begin
        Inc(Result);
        Obj := It.NextPCBObject;
    End;
    FP.GroupIterator_Destroy(It);
End;


{ Translation/rotation/mirror invariant pad-center distance signature.
  Distances rounded to 0.01 mm. Does not compare pad sizes, numbering,
  holes, copper layers, mask or graphics. }
Function PadDistanceSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It    : IPCB_GroupIterator;
    Pad   : IPCB_Pad;
    Xs    : TStringList;
    Ys    : TStringList;
    Ds    : TStringList;
    I, J  : Integer;
    DX, DY, D : Double;
Begin
    Result := '';
    Xs := TStringList.Create;
    Ys := TStringList.Create;
    Ds := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Xs.Add(FloatToStr(CoordToMMs(Pad.X)));
            Ys.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);

        For I := 0 To Xs.Count - 1 Do
            For J := I + 1 To Xs.Count - 1 Do
            Begin
                DX := StrToFloat(Xs[I]) - StrToFloat(Xs[J]);
                DY := StrToFloat(Ys[I]) - StrToFloat(Ys[J]);
                D := Sqrt(DX * DX + DY * DY);
                { Integer hundredths of a millimeter avoids locale-specific decimals. }
                Ds.Add(IntToStr(Round(D * 100)));
            End;
        Ds.Sort;
        For I := 0 To Ds.Count - 1 Do
            Result := Result + Ds[I] + ';';
    Finally
        Ds.Free;
        Ys.Free;
        Xs.Free;
    End;
End;


{ Pad dimensions and hole diameter signature.
  X/Y dimensions are normalized so footprint rotation does not affect result.
  This is an additional screening test, not a full pad-stack comparison. }
Function PadSizeSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It   : IPCB_GroupIterator;
    Pad  : IPCB_Pad;
    Items: TStringList;
    A, B, H, T : Integer;
    I    : Integer;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            { Integer coordinates, avoiding decimal-format locale differences. }
            A := Pad.TopXSize;
            B := Pad.TopYSize;
            H := Pad.HoleSize;
            If A > B Then
            Begin
                T := A; A := B; B := T;
            End;
            Items.Add(IntToStr(A) + '/' + IntToStr(B) + '/' + IntToStr(H));
            Pad := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ Pad-name-aware signature: each pad designator is associated with
  its size/hole and sorted distances to every other pad, keyed by
  the other pad's designator. Translation/rotation invariant.
  Mirror invariant too; this is not a complete footprint comparison. }
{ Mid/bottom pad dimensions by pad name; independent of placement.
  This is NOT a full pad stack check (shape, mask, paste, hole type,
  plating, rotation and layer-specific stacks are not inspected). }
Function PadInnerOuterSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Items : TStringList;
    I : Integer;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Items.Add(Pad.Name + ':Mid=' +
                IntToStr(Pad.MidXSize) + 'x' + IntToStr(Pad.MidYSize) +
                ':Bottom=' + IntToStr(Pad.BotXSize) + 'x' +
                IntToStr(Pad.BotYSize));
            Pad := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;

Function PadNamedSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Names, Xs, Ys, Sizes, Lines, Neighbors : TStringList;
    I, J, A, B, H, T : Integer;
    DX, DY, D : Double;
    Line : String;
Begin
    Result := '';
    Names := TStringList.Create;
    Xs := TStringList.Create;
    Ys := TStringList.Create;
    Sizes := TStringList.Create;
    Lines := TStringList.Create;
    Neighbors := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Exit;
        It.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := It.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            Names.Add(Pad.Name);
            Xs.Add(FloatToStr(CoordToMMs(Pad.X)));
            Ys.Add(FloatToStr(CoordToMMs(Pad.Y)));
            A := Pad.TopXSize;
            B := Pad.TopYSize;
            H := Pad.HoleSize;
            If A > B Then
            Begin
                T := A; A := B; B := T;
            End;
            Sizes.Add(IntToStr(A) + '/' + IntToStr(B) + '/' + IntToStr(H));
            Pad := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);

        For I := 0 To Names.Count - 1 Do
        Begin
            Neighbors.Clear;
            For J := 0 To Names.Count - 1 Do
            Begin
                If I <> J Then
                Begin
                    DX := StrToFloat(Xs[I]) - StrToFloat(Xs[J]);
                    DY := StrToFloat(Ys[I]) - StrToFloat(Ys[J]);
                    D := Sqrt(DX * DX + DY * DY);
                    Neighbors.Add(Names[J] + ':' + IntToStr(Round(D * 100)));
                End;
            End;
            Neighbors.Sort;
            Line := Names[I] + '|' + Sizes[I] + '|';
            For J := 0 To Neighbors.Count - 1 Do
                Line := Line + Neighbors[J] + ',';
            Lines.Add(Line);
        End;
        Lines.Sort;
        For I := 0 To Lines.Count - 1 Do
            Result := Result + Lines[I] + #10;
    Finally
        Neighbors.Free;
        Lines.Free;
        Sizes.Free;
        Ys.Free;
        Xs.Free;
        Names.Free;
    End;
End;


{ Count basic non-pad primitives in the footprint/component group.
  This detects missing/extra primitives, but NOT geometry differences. }
{ Per-layer primitive counts. This is a diagnostic screening test,
  not a comparison of primitive shapes or positions.
  Layer identifiers are compared as returned by Altium; flipped components
  may require a layer mapping in a later version. }
Function PrimitiveCountSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    Keys : TStringList;
    Key, Kind : String;
    KeyIndex, I : Integer;
Begin
    Result := '';
    Keys := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then
        Begin
            Result := 'ITERATOR ERROR';
            Exit;
        End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject,
                                     eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            Kind := '';
            If Obj.ObjectId = eTrackObject Then Kind := 'Track';
            If Obj.ObjectId = eArcObject Then Kind := 'Arc';
            If Obj.ObjectId = eFillObject Then Kind := 'Fill';
            If Obj.ObjectId = eTextObject Then Kind := 'Text';
            If Obj.ObjectId = eRegionObject Then Kind := 'Region';
            If Kind <> '' Then
            Begin
                Key := Kind + '@Layer' + IntToStr(Ord(Obj.Layer));
                KeyIndex := Keys.IndexOfName(Key);
                If KeyIndex < 0 Then
                    Keys.Add(Key + '=1')
                Else
                    Keys.ValueFromIndex[KeyIndex] :=
                        IntToStr(StrToInt(Keys.ValueFromIndex[KeyIndex]) + 1);
            End;
            Obj := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Keys.Sort;
        For I := 0 To Keys.Count - 1 Do
            Result := Result + Keys[I] + '; ';
    Finally
        Keys.Free;
    End;
End;


{ Track width/length per layer. Length is rotation/translation invariant.
  Rounded to 0.01 mm. This is NOT a full geometry comparison. }
Function TrackDimensionSignatureLib(FP : IPCB_LibComponent) : String;
Var
    It : IPCB_GroupIterator;
    Track : IPCB_Track;
    Items : TStringList;
    I : Integer;
    DX, DY, L : Double;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then
        Begin
            Result := 'ITERATOR ERROR';
            Exit;
        End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject));
        Track := It.FirstPCBObject;
        While Track <> Nil Do
        Begin
            DX := CoordToMMs(Track.X2 - Track.X1);
            DY := CoordToMMs(Track.Y2 - Track.Y1);
            L := Sqrt(DX * DX + DY * DY);
            Items.Add('Layer' + IntToStr(Ord(Track.Layer)) +
                      ':Width=' + IntToStr(Round(CoordToMMs(Track.Width) * 100)) +
                      ':Length=' + IntToStr(Round(L * 100)));
            Track := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ Track endpoint geometry relative to NAMED pad centers.
  Translation/rotation invariant, endpoint order independent.
  Distances rounded to 0.01 mm; reflection is not distinguished.
  The comparison still does not prove full footprint identity. }
Function TrackPositionSignatureLib(FP : IPCB_LibComponent) : String;
Var
    PadIt : IPCB_GroupIterator;
    TrackIt : IPCB_GroupIterator;
    Pad : IPCB_Pad;
    Track : IPCB_Track;
    PadNames, PadXs, PadYs, Items, End1, End2 : TStringList;
    I : Integer;
    DX, DY, D : Double;
    S1, S2, Temp : String;
Begin
    Result := '';
    PadNames := TStringList.Create;
    PadXs := TStringList.Create;
    PadYs := TStringList.Create;
    Items := TStringList.Create;
    End1 := TStringList.Create;
    End2 := TStringList.Create;
    Try
        PadIt := FP.GroupIterator_Create;
        If PadIt = Nil Then
        Begin
            Result := 'PAD ITERATOR ERROR';
            Exit;
        End;
        PadIt.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := PadIt.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            PadNames.Add(Pad.Name);
            PadXs.Add(FloatToStr(CoordToMMs(Pad.X)));
            PadYs.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := PadIt.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(PadIt);

        TrackIt := FP.GroupIterator_Create;
        If TrackIt = Nil Then
        Begin
            Result := 'TRACK ITERATOR ERROR';
            Exit;
        End;
        TrackIt.AddFilter_ObjectSet(MkSet(eTrackObject));
        Track := TrackIt.FirstPCBObject;
        While Track <> Nil Do
        Begin
            End1.Clear;
            End2.Clear;
            For I := 0 To PadNames.Count - 1 Do
            Begin
                DX := CoordToMMs(Track.X1) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Track.Y1) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                End1.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));

                DX := CoordToMMs(Track.X2) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Track.Y2) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                End2.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));
            End;
            End1.Sort;
            End2.Sort;
            S1 := '';
            S2 := '';
            For I := 0 To End1.Count - 1 Do
            Begin
                S1 := S1 + End1[I] + ',';
                S2 := S2 + End2[I] + ',';
            End;
            If S1 > S2 Then
            Begin
                Temp := S1; S1 := S2; S2 := Temp;
            End;
            Items.Add('Layer' + IntToStr(Ord(Track.Layer)) +
                      ':Width=' + IntToStr(Round(CoordToMMs(Track.Width) * 100)) +
                      ':EndA=' + S1 + ':EndB=' + S2);
            Track := TrackIt.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(TrackIt);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        End2.Free;
        End1.Free;
        Items.Free;
        PadYs.Free;
        PadXs.Free;
        PadNames.Free;
    End;
End;

{ Class-specific per-layer counts. }
{ Arc geometry screening: radius, line width, sweep angle and center
  distances to named pads. Does not verify arc start direction.
  For flipped components layer mapping is not normalized. }
Function ArcGeometrySignatureLib(FP : IPCB_LibComponent) : String;
Var
    ArcIt, PadIt : IPCB_GroupIterator;
    Arc : IPCB_Arc;
    Pad : IPCB_Pad;
    PadNames, PadXs, PadYs, Entries, Distances : TStringList;
    I : Integer;
    DX, DY, D, Sweep : Double;
    Entry : String;
Begin
    Result := '';
    PadNames := TStringList.Create;
    PadXs := TStringList.Create;
    PadYs := TStringList.Create;
    Entries := TStringList.Create;
    Distances := TStringList.Create;
    Try
        PadIt := FP.GroupIterator_Create;
        If PadIt = Nil Then Begin Result := 'PAD ITERATOR ERROR'; Exit; End;
        PadIt.AddFilter_ObjectSet(MkSet(ePadObject));
        Pad := PadIt.FirstPCBObject;
        While Pad <> Nil Do
        Begin
            PadNames.Add(Pad.Name);
            PadXs.Add(FloatToStr(CoordToMMs(Pad.X)));
            PadYs.Add(FloatToStr(CoordToMMs(Pad.Y)));
            Pad := PadIt.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(PadIt);

        ArcIt := FP.GroupIterator_Create;
        If ArcIt = Nil Then Begin Result := 'ARC ITERATOR ERROR'; Exit; End;
        ArcIt.AddFilter_ObjectSet(MkSet(eArcObject));
        Arc := ArcIt.FirstPCBObject;
        While Arc <> Nil Do
        Begin
            Sweep := Abs(Arc.EndAngle - Arc.StartAngle);
            While Sweep > 360 Do Sweep := Sweep - 360;
            Entry := 'L' + IntToStr(Ord(Arc.Layer)) +
                     '/R' + IntToStr(Round(CoordToMMs(Arc.Radius) * 100)) +
                     '/W' + IntToStr(Round(CoordToMMs(Arc.LineWidth) * 100)) +
                     '/Sweep' + IntToStr(Round(Sweep * 100));
            Distances.Clear;
            For I := 0 To PadNames.Count - 1 Do
            Begin
                DX := CoordToMMs(Arc.XCenter) - StrToFloat(PadXs[I]);
                DY := CoordToMMs(Arc.YCenter) - StrToFloat(PadYs[I]);
                D := Sqrt(DX * DX + DY * DY);
                Distances.Add(PadNames[I] + ':' + IntToStr(Round(D * 100)));
            End;
            Distances.Sort;
            For I := 0 To Distances.Count - 1 Do
                Entry := Entry + '/' + Distances[I];
            Entries.Add(Entry);
            Arc := ArcIt.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(ArcIt);
        Entries.Sort;
        For I := 0 To Entries.Count - 1 Do
            Result := Result + Entries[I] + ';';
    Finally
        Distances.Free;
        Entries.Free;
        PadYs.Free;
        PadXs.Free;
        PadNames.Free;
    End;
End;

Function PrimitiveClassSignatureLib(FP : IPCB_LibComponent; ClassId : Integer) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    Keys : TStringList;
    Key : String;
    KeyIndex, I : Integer;
Begin
    Result := '';
    Keys := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Begin Result := 'ITERATOR ERROR'; Exit; End;
        It.AddFilter_ObjectSet(MkSet(eTrackObject, eArcObject, eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            If Ord(Obj.ObjectId) = ClassId Then
            Begin
                Key := 'Layer' + IntToStr(Ord(Obj.Layer));
                KeyIndex := Keys.IndexOfName(Key);
                If KeyIndex < 0 Then Keys.Add(Key + '=1')
                Else Keys.ValueFromIndex[KeyIndex] := IntToStr(StrToInt(Keys.ValueFromIndex[KeyIndex]) + 1);
            End;
            Obj := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Keys.Sort;
        For I := 0 To Keys.Count - 1 Do Result := Result + Keys[I] + ';';
    Finally
        Keys.Free;
    End;
End;

Function OtherPrimitiveSignatureLib(FP : IPCB_LibComponent; WantedId : Integer) : String;
Var
    It : IPCB_GroupIterator;
    Obj : IPCB_Primitive;
    TextObj : IPCB_Text;
    Items : TStringList;
    R : TCoordRect;
    W, H, Temp, I : Integer;
    Entry : String;
Begin
    Result := '';
    Items := TStringList.Create;
    Try
        It := FP.GroupIterator_Create;
        If It = Nil Then Begin Result := 'ITERATOR ERROR'; Exit; End;
        It.AddFilter_ObjectSet(MkSet(eFillObject, eTextObject, eRegionObject));
        Obj := It.FirstPCBObject;
        While Obj <> Nil Do
        Begin
            If Ord(Obj.ObjectId) = WantedId Then
            Begin
                R := Obj.BoundingRectangle;
                W := Abs(R.Right - R.Left);
                H := Abs(R.Top - R.Bottom);
                If W > H Then
                Begin
                    Temp := W; W := H; H := Temp;
                End;
                Entry := 'Layer' + IntToStr(Ord(Obj.Layer)) +
                         '/Bounds=' + IntToStr(Round(CoordToMMs(W) * 100)) +
                         'x' + IntToStr(Round(CoordToMMs(H) * 100));
                If WantedId = Ord(eTextObject) Then
                Begin
                    TextObj := Obj;
                    Entry := Entry + '/Text=' + TextObj.Text;
                End;
                Items.Add(Entry);
            End;
            Obj := It.NextPCBObject;
        End;
        FP.GroupIterator_Destroy(It);
        Items.Sort;
        For I := 0 To Items.Count - 1 Do
            Result := Result + Items[I] + ';';
    Finally
        Items.Free;
    End;
End;


{ 3D Body count per component. This does not inspect STEP contents,
  height, orientation, offsets or model identity. }
Function Count3DBodiesLib(FP : IPCB_LibComponent) : Integer;
Var
    BodyIt : IPCB_GroupIterator;
    BodyObj : IPCB_Primitive;
Begin
    Result := 0;
    BodyIt := FP.GroupIterator_Create;
    If BodyIt = Nil Then Exit;
    BodyIt.AddFilter_ObjectSet(MkSet(eComponentBodyObject));
    BodyObj := BodyIt.FirstPCBObject;
    While BodyObj <> Nil Do
    Begin
        Inc(Result);
        BodyObj := BodyIt.NextPCBObject;
    End;
    FP.GroupIterator_Destroy(BodyIt);
End;

{ CSV escaping without StringReplace flags (DelphiScript compatible). }
Function CsvField(Value : String) : String;
Var
    CharPos : Integer;
Begin
    Result := '"';
    For CharPos := 1 To Length(Value) Do
    Begin
        If Value[CharPos] = '"' Then Result := Result + '""'
        Else Result := Result + Value[CharPos];
    End;
    Result := Result + '"';
End;

{ Normalize a path exported from the source candidate accumulator.
  Trim removes trailing spaces, so the original " | " may become " |".
  This routine also supports existing v20 manifests. }
Function CleanLibraryPath(Value : String) : String;
Var
    DelimPos : Integer;
Begin
    Result := Trim(Value);
    DelimPos := Pos(' |', Result);
    If DelimPos > 0 Then
        Result := Trim(Copy(Result, 1, DelimPos - 1));
    { In case a legacy entry ends in a bare pipe. }
    While (Length(Result) > 0) And
          (Copy(Result, Length(Result), 1) = '|') Do
        Result := Trim(Copy(Result, 1, Length(Result) - 1));
End;

Function SingleSource(Value : String) : String;
Begin
    Result := CleanLibraryPath(Value);
End;

Function CSVColumn(Line : String; WantedColumn : Integer) : String;
Var
    CharPos, ColumnNo : Integer;
    InQuotes : Boolean;
    C : String;
Begin
    Result := '';
    ColumnNo := 0;
    InQuotes := False;
    CharPos := 1;
    While CharPos <= Length(Line) Do
    Begin
        C := Copy(Line, CharPos, 1);
        If C = '"' Then
        Begin
            If InQuotes And (CharPos < Length(Line)) And
               (Copy(Line, CharPos + 1, 1) = '"') Then
            Begin
                If ColumnNo = WantedColumn Then Result := Result + '"';
                Inc(CharPos);
            End
            Else InQuotes := Not InQuotes;
        End
        Else If (C = ',') And Not InQuotes Then
            Inc(ColumnNo)
        Else If ColumnNo = WantedColumn Then
            Result := Result + C;
        Inc(CharPos);
    End;
End;

Function SamePcbLibPath(LeftPath, RightPath : String) : Boolean;
Begin
    Result := UpperCase(Trim(CleanLibraryPath(LeftPath))) =
              UpperCase(Trim(CleanLibraryPath(RightPath)));
End;

Function TargetConfigPath(Prj : IProject) : String;
Begin
    Result := ExtractFilePath(Prj.DM_ProjectFileName) +
              'PCB_Footprint_Target_v32.txt';
End;

{ Resolve project-relative library names before filesystem operations. }
Function ResolveProjectPcbLibPath(Prj : IProject; Value : String) : String;
Var
    Candidate : String;
Begin
    Result := Trim(Value);
    If Result = '' Then Exit;
    If FileExists(Result) Then Exit;
    Candidate := ExtractFilePath(Prj.DM_ProjectFileName) + Result;
    If FileExists(Candidate) Then Result := Candidate;
End;

Function ChooseTargetLibrary(Prj : IProject; Out TargetPath : String;
                             Out ExcludeFromScan : Boolean) : Boolean;
Var
    Options : TStringList;
    Doc : IDocument;
    I, Selected : Integer;
    Candidate, MenuText, Answer : String;
Begin
    Result := False;
    TargetPath := '';
    Options := TStringList.Create;
    Try
        For I := 0 To Prj.DM_LogicalDocumentCount - 1 Do
        Begin
            Doc := Prj.DM_LogicalDocuments(I);
            If Doc <> Nil Then
            Begin
                Candidate := ResolveProjectPcbLibPath(Prj, Doc.DM_FullPath);
                If (UpperCase(ExtractFileExt(Candidate)) = '.PCBLIB') And
                   (Options.IndexOf(Candidate) < 0) Then
                    Options.Add(Candidate);
            End;
        End;
        MenuText := '0 = NEW unsaved PcbLib' + #13#10;
        For I := 0 To Options.Count - 1 Do
            MenuText := MenuText + IntToStr(I + 1) + ' = ' + Options[I] + #13#10;
        Answer := Trim(AskInputOrAbort('STAGE 32: TARGET LIBRARY',
                  'Choose destination number BEFORE analysis:' + #13#10 +
                  MenuText, '0'));
        If Answer = '' Then Exit;
        For I := 1 To Length(Answer) Do
            If Pos(Copy(Answer, I, 1), '0123456789') = 0 Then Exit;
        Selected := StrToInt(Answer);
        If (Selected < 0) Or (Selected > Options.Count) Then Exit;
        If Selected > 0 Then
        Begin
            TargetPath := ResolveProjectPcbLibPath(Prj, Options[Selected - 1]);
            If Not FileExists(TargetPath) Then
            Begin
                ShowMessage('Target library is listed in the project but not found on disk:' +
                            #13#10 + TargetPath + #13#10 +
                            'Save the PcbLib to disk first, then restart analysis.');
                Exit;
            End;
        End;
        ExcludeFromScan := False;
        If TargetPath <> '' Then
        Begin
            Answer := UpperCase(Trim(AskInputOrAbort('TARGET AS SOURCE',
                'Exclude the destination PcbLib from candidate source scanning?' + #13#10 +
                'Y = yes (recommended); N = no', 'Y')));
            If (Answer <> 'Y') And (Answer <> 'N') Then Exit;
            ExcludeFromScan := Answer = 'Y';
        End;
        Result := True;
    Finally
        Options.Free;
    End;
End;

Function SaveTargetSelection(Prj : IProject; TargetPath : String;
                             ExcludeFromScan, SkipGeometryChecks : Boolean) : Boolean;
Var Config : TStringList;
Begin
    Result := False;
    Config := TStringList.Create;
    Try
        Config.Add(TargetPath);
        If ExcludeFromScan Then Config.Add('YES') Else Config.Add('NO');
        If SkipGeometryChecks Then Config.Add('SKIP_GEOMETRY')
        Else Config.Add('CHECK_GEOMETRY');
        Config.SaveToFile(TargetConfigPath(Prj));
        Result := True;
    Finally
        Config.Free;
    End;
End;

Function ReadTargetSelection(Prj : IProject; Out TargetPath : String;
                             Out ExcludeFromScan, SkipGeometryChecks : Boolean) : Boolean;
Var Config : TStringList;
Begin
    Result := False;
    TargetPath := '';
    ExcludeFromScan := False;
    SkipGeometryChecks := False;
    If Not FileExists(TargetConfigPath(Prj)) Then Exit;
    Config := TStringList.Create;
    Try
        Config.LoadFromFile(TargetConfigPath(Prj));
        If Config.Count < 2 Then Exit;
        TargetPath := ResolveProjectPcbLibPath(Prj, Trim(Config[0]));
        ExcludeFromScan := UpperCase(Trim(Config[1])) = 'YES';
        If Config.Count >= 3 Then
            SkipGeometryChecks := UpperCase(Trim(Config[2])) = 'SKIP_GEOMETRY';
        Result := True;
    Finally
        Config.Free;
    End;
End;

Function BackupExistingPcbLib(SourcePath, BackupPath : String) : Boolean;
Var InputStream, OutputStream : TFileStream;
Begin
    Result := False;
    If (Not FileExists(SourcePath)) Or FileExists(BackupPath) Then Exit;
    InputStream := TFileStream.Create(SourcePath, fmOpenRead Or fmShareDenyWrite);
    Try
        OutputStream := TFileStream.Create(BackupPath, fmCreate);
        Try
            OutputStream.CopyFrom(InputStream, 0);
            Result := True;
        Finally
            OutputStream.Free;
        End;
    Finally
        InputStream.Free;
    End;
End;

{ Working metadata for the transfer decision; never accumulates report text. }
Procedure RecordAttention(FootprintName, LibraryPath, ClassName : String);
Var
    Key : String;
    EntryNo : Integer;
Begin
    Key := UpperCase(FootprintName) + '|' + UpperCase(ExtractFileName(LibraryPath)) + '|' + ClassName;
    For EntryNo := 0 To GAttentionCount - 1 Do
    Begin
        If GAttentionEntries[EntryNo] = Key Then Exit;
    End;
    If GAttentionCount >= 4096 Then
    Begin
        WriteCheckpoint('WARNING: attention metadata capacity reached');
        Exit;
    End;
    GAttentionEntries[GAttentionCount] := Key;
    Inc(GAttentionCount);
End;

Function AttentionClasses(FootprintName, SourcePath : String) : String;
Var
    ItemIndex, PrefixLen : Integer;
    KeyPrefix, ClassName : String;
Begin
    Result := '';
    KeyPrefix := UpperCase(FootprintName) + '|' + UpperCase(ExtractFileName(SourcePath)) + '|';
    PrefixLen := Length(KeyPrefix);
    For ItemIndex := 0 To GAttentionCount - 1 Do
        If Copy(GAttentionEntries[ItemIndex], 1, PrefixLen) = KeyPrefix Then
        Begin
            ClassName := Copy(GAttentionEntries[ItemIndex], PrefixLen + 1, Length(GAttentionEntries[ItemIndex]));
            If Result <> '' Then Result := Result + ', ';
            Result := Result + ClassName;
        End;
End;

Procedure BuildPCBFootprintSelectionAndApproveTransfer;
Var
    WS       : IWorkspace;
    Prj      : IProject;
    Doc      : IDocument;
    Board    : IPCB_Board;
    BI       : IPCB_BoardIterator;
    Comp     : IPCB_Component;
    Lib      : IPCB_Library;
    LI       : IPCB_LibraryIterator;
    FP       : IPCB_LibComponent;
    OpenDoc  : IServerDocument;
    ReturnPCBDoc : IServerDocument;
    PCBPath : String;
    Names    : TStringList;
    PadNums  : TStringList;
    InstanceCounts : TStringList;
    ComponentRefs : Array[0..4095] Of IPCB_Component;
    ComponentRefCount : Integer;
    PadSigs  : TStringList;
    SizeSigs : TStringList;
    StackSigs : TStringList;
    NameSigs : TStringList;
    PrimSigs : TStringList;
    PrimClasses : TStringList;
    TrackSigs: TStringList;
    TrackPosSigs: TStringList;
    ArcSigs: TStringList;
    FillSigs, TextSigs, RegionSigs : TStringList;
    BodyCounts : TStringList;
    ExactCandidates, IgnoredCandidates, DifferentCandidates : TStringList;
    ExactSources, IgnoredSources : TStringList;
    Paths    : TStringList;
    FoundFootprints : TStringList;
    Manifest : TStringList;
    SourceCatalog : TStringList;
    MatchedCatalog : TStringList;
    MatchStart : Array[0..4095] Of Integer;
    MatchLength : Array[0..4095] Of Integer;
    PairRow : Integer;
    LastOpenedPath : String;
    MissingNames : TStringList;
    MatchCount : Integer;
    CatalogRow : Integer;
    CatalogName, CatalogPath, MatchedLibraryNames : String;
    ManifestPath, SelectionStatus, SelectionSource : String;
    I, J, K  : Integer;
    P, N     : String;
    PCBCount : Integer;
    LibCount : Integer;
    Total    : Integer;
    Opened   : Integer;
    Failed   : Integer;
    Matches  : Integer;
    Diff     : Integer;
    GlobalPolicy, LocalPolicy : TStringList;
    PCBPrim, LibPrim : String;
    ClassName : String;
    ClassId, ClassNo : Integer;
    CandidateDiff, IgnoredDiff : Boolean;
    HadMismatch : Boolean;
    CurrentLibName : String;
    TargetPath : String;
    ExcludeTarget : Boolean;
    SkipExistingTarget : Boolean;
    SkipGeometryChecks : Boolean;
    GeometryChoice : String;
    TargetExistingNames : TStringList;
    SkipTargetNames : TStringList;
    TargetSkippedCount : Integer;
    TargetChoice : String;
Begin
    WS := GetWorkspace;
    If WS = Nil Then Begin ShowMessage('No workspace'); Exit; End;
    Prj := WS.DM_FocusedProject;
    If Prj = Nil Then Begin ShowMessage('No focused project'); Exit; End;

    { Keep exactly the working PCB access mechanism from v4. }
    If Not ChooseTargetLibrary(Prj, TargetPath, ExcludeTarget) Then
    Begin
        ShowMessage('Target selection cancelled.');
        Exit;
    End;

    { Decide conflict policy before any library analysis. }
    SkipExistingTarget := False;
    If TargetPath <> '' Then
    Begin
        TargetChoice := UpperCase(Trim(AskInputOrAbort('EXISTING TARGET FOOTPRINTS',
            'The destination library already exists:' + #13#10 +
            ExtractFileName(TargetPath) + #13#10 +
            'R = replace existing footprints (analyze them);' + #13#10 +
            'S = skip existing footprints (exclude at stage 2).', 'S')));
        If (TargetChoice <> 'R') And (TargetChoice <> 'S') Then
        Begin
            ShowMessage('Invalid target conflict policy; analysis cancelled.');
            Exit;
        End;
        SkipExistingTarget := TargetChoice = 'S';
    End;

    { User selects whether to compare PCB and library geometry. }
    GeometryChoice := UpperCase(Trim(AskInputOrAbort('GEOMETRY CHECK MODE',
        'C = compare PCB and library footprint geometry;' + #13#10 +
        'S = skip geometry comparison and automatically select the first' + #13#10 +
        'matching source library for each footprint.', 'C')));
    If (GeometryChoice <> 'C') And (GeometryChoice <> 'S') Then
    Begin
        ShowMessage('Invalid geometry mode; analysis cancelled.');
        Exit;
    End;
    SkipGeometryChecks := GeometryChoice = 'S';
    SaveTargetSelection(Prj, TargetPath, ExcludeTarget, SkipGeometryChecks);

    Board := PCBServer.GetCurrentPCBBoard;
    If Board = Nil Then Begin ShowMessage('PCB board not available'); Exit; End;

    Names := TStringList.Create;
    PadNums := TStringList.Create;
    InstanceCounts := TStringList.Create;
    ComponentRefCount := 0;
    PadSigs := TStringList.Create;
    SizeSigs := TStringList.Create;
    StackSigs := TStringList.Create;
    NameSigs := TStringList.Create;
    PrimSigs := TStringList.Create;
    PrimClasses := TStringList.Create;
    TrackSigs := TStringList.Create;
    TrackPosSigs := TStringList.Create;
    ArcSigs := TStringList.Create;
    FillSigs := TStringList.Create;
    TextSigs := TStringList.Create;
    RegionSigs := TStringList.Create;
    BodyCounts := TStringList.Create;
    ExactCandidates := TStringList.Create;
    IgnoredCandidates := TStringList.Create;
    DifferentCandidates := TStringList.Create;
    ExactSources := TStringList.Create;
    IgnoredSources := TStringList.Create;
    Paths := TStringList.Create;
    FoundFootprints := TStringList.Create;
    Manifest := TStringList.Create;
    SourceCatalog := TStringList.Create;
    MatchedCatalog := TStringList.Create;
    MissingNames := TStringList.Create;
    TargetExistingNames := TStringList.Create;
    SkipTargetNames := TStringList.Create;
    TargetSkippedCount := 0;
    SourceCatalog.Add('Footprint,SourcePcbLib');
    GlobalPolicy := TStringList.Create;
    LocalPolicy := TStringList.Create;
    Try
        { STAGE 1: collect only footprint names. No geometry calls. }
        Total := 0;
        WriteCheckpoint('STAGE 1 START: PCB footprint names only');
        BI := Board.BoardIterator_Create;
        BI.AddFilter_ObjectSet(MkSet(eComponentObject));
        BI.AddFilter_LayerSet(AllLayers);
        BI.AddFilter_Method(eProcessAll);
        Comp := BI.FirstPCBObject;
        While Comp <> Nil Do
        Begin
            Inc(Total);
            N := Comp.Pattern;
            If N <> '' Then
            Begin
                J := Names.IndexOf(N);
                If J < 0 Then
                Begin
                    Names.Add(N);
                    { Keep all per-footprint lists aligned at the moment a new name is found. }
                    PadNums.Add('');
                    InstanceCounts.Add('1');
                    ExactCandidates.Add('0');
                    IgnoredCandidates.Add('0');
                    DifferentCandidates.Add('0');
                    ExactSources.Add('');
                    IgnoredSources.Add('');
                    If ComponentRefCount >= 4096 Then
                    Begin
                        WriteCheckpoint('STAGE 1 ERROR: reference capacity exceeded');
                        Board.BoardIterator_Destroy(BI);
                        Exit;
                    End;
                    ComponentRefs[ComponentRefCount] := Comp;
                    Inc(ComponentRefCount);
                End
                Else InstanceCounts[J] := IntToStr(StrToInt(InstanceCounts[J]) + 1);
            End;
            If (Total Mod 200) = 0 Then
                WriteCheckpoint('STAGE 1: ' + IntToStr(Total) +
                    ' components; unique ' + IntToStr(Names.Count));
            Comp := BI.NextPCBObject;
        End;
        Board.BoardIterator_Destroy(BI);
        WriteCheckpoint('STAGE 1 COMPLETE: ' + IntToStr(Total) +
            ' components; unique ' + IntToStr(Names.Count));
        If Total = 0 Then Begin ShowMessage('No PCB components collected'); Exit; End;

        For I := 0 To Prj.DM_LogicalDocumentCount - 1 Do
        Begin
            Doc := Prj.DM_LogicalDocuments(I);
            If Doc <> Nil Then
            Begin
                P := Doc.DM_FullPath;
                If UpperCase(ExtractFileExt(P)) = '.PCBLIB' Then
                    If Paths.IndexOf(P) < 0 Then Paths.Add(P);
            End;
        End;

        { Remember the project PCB document before activating libraries. }
        PCBPath := '';
        For I := 0 To Prj.DM_LogicalDocumentCount - 1 Do
        Begin
            Doc := Prj.DM_LogicalDocuments(I);
            If Doc <> Nil Then
                If UpperCase(ExtractFileExt(Doc.DM_FullPath)) = '.PCBDOC' Then
                Begin
                    PCBPath := Doc.DM_FullPath;
                    Break;
                End;
        End;
        If PCBPath = '' Then
        Begin
            WriteCheckpoint('ERROR: no PCB document path for return from PcbLib');
            ShowMessage('PCB document not found in project.');
            Exit;
        End;

        { STAGE 2: inspect the existing destination first, regardless of
          whether it is excluded as a source. Exclusion is by footprint NAME,
          and does not alter aligned Names / ComponentRefs arrays. }
        If SkipExistingTarget Then
        Begin
            WriteCheckpoint('STAGE 2 TARGET FILTER: ' + TargetPath);
            OpenDoc := Client.OpenDocument('PCBLIB', TargetPath);
            If OpenDoc = Nil Then
            Begin
                ShowMessage('Cannot open destination PcbLib for filtering: ' + TargetPath);
                Exit;
            End;
            Client.ShowDocument(OpenDoc);
            Lib := PCBServer.GetCurrentPCBLibrary;
            If Lib = Nil Then
            Begin
                ShowMessage('Cannot activate destination PcbLib for filtering.');
                Exit;
            End;
            LI := Lib.LibraryIterator_Create;
            LI.SetState_FilterAll;
            Try
                FP := LI.FirstPCBObject;
                While FP <> Nil Do
                Begin
                    If FP.Name <> '' Then
                        TargetExistingNames.Add(UpperCase(FP.Name));
                    FP := LI.NextPCBObject;
                End;
            Finally
                Lib.LibraryIterator_Destroy(LI);
            End;
            For J := 0 To Names.Count - 1 Do
                If TargetExistingNames.IndexOf(UpperCase(Names[J])) >= 0 Then
                Begin
                    SkipTargetNames.Add(UpperCase(Names[J]));
                    Inc(TargetSkippedCount);
                    WriteCheckpoint('[SKIP EXISTING TARGET] ' + Names[J]);
                End;
            WriteCheckpoint('STAGE 2 TARGET FILTER COMPLETE: excluded ' +
                IntToStr(TargetSkippedCount) + ' project footprint names');
        End;

        { STAGE 2: independent full name catalog of every attached PcbLib.
          Do not filter against PCB names and do not inspect geometry. }
        WriteCheckpoint('STAGE 2 START: library footprint names');
        For I := 0 To Paths.Count - 1 Do
        Begin
            P := Paths[I];
            WriteCheckpoint('STAGE 2 library ' + IntToStr(I + 1) + '/' +
                IntToStr(Paths.Count) + ': ' + ExtractFileName(P));
            If Not (ExcludeTarget And SamePcbLibPath(P, TargetPath)) Then
            Begin
                If FileExists(P) Then
                Begin
                    OpenDoc := Client.OpenDocument('PCBLIB', P);
                    If OpenDoc <> Nil Then
                    Begin
                        Client.ShowDocument(OpenDoc);
                        Lib := PCBServer.GetCurrentPCBLibrary;
                        If Lib <> Nil Then
                        Begin
                            LI := Lib.LibraryIterator_Create;
                            LI.SetState_FilterAll;
                            Try
                                FP := LI.FirstPCBObject;
                                While FP <> Nil Do
                                Begin
                                    N := FP.Name;
                                    If N <> '' Then
                                    Begin
                                        SourceCatalog.Add(CsvField(N) + ',' + CsvField(P));
                                        FoundFootprints.Add(UpperCase(CleanLibraryPath(P)) +
                                            '|' + UpperCase(N));
                                    End;
                                    FP := LI.NextPCBObject;
                                End;
                            Finally
                                Lib.LibraryIterator_Destroy(LI);
                            End;
                        End;
                    End;
                End;
            End;
        End;
        WriteCheckpoint('STAGE 2 COMPLETE: libraries=' + IntToStr(Paths.Count) +
            '; footprint entries=' + IntToStr(SourceCatalog.Count - 1));

        { STAGE 3: name-only matching of two already collected lists.
          No PCB or library geometry is accessed in this stage. }
        WriteCheckpoint('STAGE 3 START: match project and library footprint names');
        MatchedCatalog.Add('Footprint,SourcePcbLib');
        MatchCount := 0;
        For J := 0 To Names.Count - 1 Do
        Begin
            N := Names[J];
            K := 0;
            MatchStart[J] := MatchedCatalog.Count;
            MatchLength[J] := 0;
            If SkipTargetNames.IndexOf(UpperCase(N)) >= 0 Then
            Begin
                WriteCheckpoint('STAGE 3 SKIPPED (already in target): ' + N);
                Continue;
            End;
            MatchedLibraryNames := '';
            For CatalogRow := 1 To SourceCatalog.Count - 1 Do
            Begin
                CatalogName := CSVColumn(SourceCatalog[CatalogRow], 0);
                If UpperCase(CatalogName) = UpperCase(N) Then
                Begin
                    CatalogPath := CSVColumn(SourceCatalog[CatalogRow], 1);
                    MatchedCatalog.Add(CsvField(N) + ',' + CsvField(CatalogPath));
                    If MatchedLibraryNames <> '' Then
                        MatchedLibraryNames := MatchedLibraryNames + ', ';
                    MatchedLibraryNames := MatchedLibraryNames + ExtractFileName(CatalogPath);
                    Inc(K);
                    Inc(MatchCount);
                End;
            End;
            MatchLength[J] := K;
            If K = 0 Then
            Begin
                MissingNames.Add(N);
                WriteCheckpoint('STAGE 3 NOT FOUND: ' + N);
            End
            Else
                WriteCheckpoint('STAGE 3 MATCH: ' + N +
                    ' | libraries=' + IntToStr(K) +
                    ' | ' + MatchedLibraryNames);
        End;
        MatchedCatalog.SaveToFile(ExtractFilePath(Prj.DM_ProjectFileName) +
            'PCB_Footprint_Name_Matches_v54.csv');
        WriteCheckpoint('STAGE 3 COMPLETE: matched pairs=' +
            IntToStr(MatchCount) + '; without library=' +
            IntToStr(MissingNames.Count));

        If SkipGeometryChecks Then
        Begin
            { Stage 3 already established name matches. No PCB geometry
              signatures, library footprint geometry or ignore prompts.
              The first matched library is chosen deterministically. }
            WriteCheckpoint('STAGE 4: geometry comparison SKIPPED by user');
            For J := 0 To Names.Count - 1 Do
            Begin
                N := Names[J];
                If SkipTargetNames.IndexOf(UpperCase(N)) < 0 Then
                Begin
                    If MatchLength[J] > 0 Then
                    Begin
                        P := CleanLibraryPath(CSVColumn(
                            MatchedCatalog[MatchStart[J]], 1));
                        ExactCandidates[J] := '1';
                        ExactSources[J] := P + ' | ';
                        WriteCheckpoint('STAGE 4 AUTO SOURCE: ' + N +
                            ' | ' + ExtractFileName(P) +
                            ' | NOT GEOMETRY VERIFIED');
                    End
                    Else
                        WriteCheckpoint('STAGE 4 NO SOURCE: ' + N);
                End;
            End;
        End
        Else
        Begin
        { Return to PCB exactly as in the successful v65 diagnostic. }
        WriteCheckpoint('STAGE 3 -> 4: reactivating PCB document: ' + PCBPath);
        ReturnPCBDoc := Client.OpenDocument('PCB', PCBPath);
        If ReturnPCBDoc = Nil Then
        Begin
            WriteCheckpoint('ERROR: cannot reopen PCB document');
            ShowMessage('Cannot reopen PCB document: ' + PCBPath);
            Exit;
        End;
        Client.ShowDocument(ReturnPCBDoc);
        If PCBServer.GetCurrentPCBBoard = Nil Then
        Begin
            WriteCheckpoint('ERROR: PCB not active after document switch');
            ShowMessage('PCB not active after returning from libraries.');
            Exit;
        End;
        WriteCheckpoint('STAGE 3 -> 4: PCB active; using saved component references');

        { STAGE 4: use the first PCB component saved in STAGE 1.
          No second board iterator; keep PCB document loaded throughout. }
        WriteCheckpoint('STAGE 4 START: PCB reference geometry from saved components');
        If ComponentRefCount <> Names.Count Then
        Begin
            WriteCheckpoint('STAGE 4 ERROR: component reference count mismatch');
            ShowMessage('PCB component reference count mismatch');
            Exit;
        End;
        For J := 0 To Names.Count - 1 Do
        Begin
            If SkipTargetNames.IndexOf(UpperCase(Names[J])) >= 0 Then
            Begin
                { Preserve one entry per footprint for all indexed signatures. }
                PadSigs.Add(''); SizeSigs.Add(''); StackSigs.Add('');
                NameSigs.Add(''); PrimSigs.Add('');
                PrimClasses.Add(''); PrimClasses.Add(''); PrimClasses.Add('');
                PrimClasses.Add(''); PrimClasses.Add('');
                TrackSigs.Add(''); TrackPosSigs.Add(''); ArcSigs.Add('');
                FillSigs.Add(''); TextSigs.Add(''); RegionSigs.Add('');
                BodyCounts.Add('');
                WriteCheckpoint('STAGE 4 SKIPPED: ' + Names[J]);
                Continue;
            End;
            Comp := ComponentRefs[J];
            If Comp = Nil Then
            Begin
                WriteCheckpoint('STAGE 4 ERROR: missing PCB component for ' + Names[J]);
                ShowMessage('Missing PCB component reference: ' + Names[J]);
                Exit;
            End;
            WriteCheckpoint('STAGE 4: ' + IntToStr(J + 1) + '/' +
                IntToStr(Names.Count) + ' ' + Names[J]);
            { The name was read from Comp.Pattern during STAGE 1.
              Avoid a second Pattern property access here: Altium DelphiScript
              rejects it at this location with Undeclared identifier: Pattern.
              This checkpoint does not assert that the stored reference is valid. }
            PCBCount := CountPadsInGroupPCB(Comp);
            PadSigs.Add(PadDistanceSignaturePCB(Comp));
            SizeSigs.Add(PadSizeSignaturePCB(Comp));
            StackSigs.Add(PadInnerOuterSignaturePCB(Comp));
            NameSigs.Add(PadNamedSignaturePCB(Comp));
            PrimSigs.Add(PrimitiveCountSignaturePCB(Comp));
            PrimClasses.Add(PrimitiveClassSignaturePCB(Comp, Ord(eTrackObject)));
            PrimClasses.Add(PrimitiveClassSignaturePCB(Comp, Ord(eArcObject)));
            PrimClasses.Add(PrimitiveClassSignaturePCB(Comp, Ord(eFillObject)));
            PrimClasses.Add(PrimitiveClassSignaturePCB(Comp, Ord(eTextObject)));
            PrimClasses.Add(PrimitiveClassSignaturePCB(Comp, Ord(eRegionObject)));
            TrackSigs.Add(TrackDimensionSignaturePCB(Comp));
            TrackPosSigs.Add(TrackPositionSignaturePCB(Comp));
            ArcSigs.Add(ArcGeometrySignaturePCB(Comp));
            FillSigs.Add(OtherPrimitiveSignaturePCB(Comp, Ord(eFillObject)));
            TextSigs.Add(OtherPrimitiveSignaturePCB(Comp, Ord(eTextObject)));
            RegionSigs.Add(OtherPrimitiveSignaturePCB(Comp, Ord(eRegionObject)));
            BodyCounts.Add(IntToStr(Count3DBodiesPCB(Comp)));
            PadNums[J] := IntToStr(PCBCount);
        End;
        WriteCheckpoint('STAGE 4: reference geometry collected');

        { Candidate lists were initialized alongside Names in STAGE 1. }
        Opened := 0;
        Failed := 0;
        Matches := 0;
        Diff := 0;

        { STAGE 4: footprint-first traversal. Stage 3 records the contiguous
          range of matched libraries for each project footprint. }
        WriteCheckpoint('STAGE 4: comparing ' + IntToStr(MatchCount) +
            ' matched footprint/library pairs, footprint-first');
        LastOpenedPath := '';
        Lib := Nil;
        For J := 0 To Names.Count - 1 Do
        Begin
            N := Names[J];
            If SkipTargetNames.IndexOf(UpperCase(N)) >= 0 Then Continue;
            WriteCheckpoint('STAGE 4 FOOTPRINT: ' + N +
                ' | libraries=' + IntToStr(MatchLength[J]));
            For PairRow := MatchStart[J] To MatchStart[J] + MatchLength[J] - 1 Do
            Begin
                P := CSVColumn(MatchedCatalog[PairRow], 1);
            If ExcludeTarget And (TargetPath <> '') And
                    SamePcbLibPath(P, TargetPath) Then
                WriteCheckpoint('[EXCLUDED TARGET] ' + N + ' | ' + P)
            Else If Not FileExists(P) Then
            Begin
                Inc(Failed);
                WriteCheckpoint('[MISSING LIBRARY] ' + N + ' | ' + P);
            End
            Else
            Begin
                { Reuse the current library only for consecutive pairs with
                  the same full path. Never use a stale library handle. }
                If Not SamePcbLibPath(LastOpenedPath, P) Then
                Begin
                    Lib := Nil;
                    LastOpenedPath := '';
                    OpenDoc := Client.OpenDocument('PCBLIB', P);
                    If OpenDoc <> Nil Then
                    Begin
                        Client.ShowDocument(OpenDoc);
                        Lib := PCBServer.GetCurrentPCBLibrary;
                    End;
                    If Lib <> Nil Then
                    Begin
                        LastOpenedPath := P;
                        Inc(Opened);
                        WriteCheckpoint('STAGE 4 ACTIVE PCBLIB: ' + P);
                    End;
                End;
                If Lib = Nil Then
                Begin
                    Inc(Failed);
                    WriteCheckpoint('[NOT LOADED] ' + P);
                End
                Else
                Begin
                    CurrentLibName := ExtractFileName(P);
                    FP := Lib.GetComponentByName(N);
                    If FP = Nil Then
                    Begin
                        Inc(Failed);
                        WriteCheckpoint('[NOT FOUND IN OPEN LIBRARY] ' + N + ' | ' + CurrentLibName);
                    End
                    Else
                    Begin
                                WriteCheckpoint('');
                                WriteCheckpoint('FOOTPRINT: ' + N + ' | LIBRARY: ' + CurrentLibName);
                                LibCount := CountPadsInGroupLib(FP);
                                { Pad differences are reported only when detected. }
                                CandidateDiff := False;
                                IgnoredDiff := False;
                                If PadNums[J] = 'MIXED' Then
                                Begin
                                    CandidateDiff := True;
                                    WriteCheckpoint('[PCB MIXED] ' + N + ' : PCB instances differ; cannot select reference automatically');
                                End
                                Else
                                Begin
                                    PCBCount := StrToInt(PadNums[J]);
                                    If PCBCount <> LibCount Then
                                    Begin
                                        CandidateDiff := True;
                                        RecordAttention(N, P, 'Pad');
                                        WriteCheckpoint('  Pad count: DIFFERENT');
                                    End;
                                    If PadSigs[J] <> PadDistanceSignatureLib(FP) Then
                                    Begin
                                        CandidateDiff := True;
                                        RecordAttention(N, P, 'Pad');
                                        WriteCheckpoint('[PAD POS DIFF] ' + N);
                                    End;
                                    If SizeSigs[J] <> PadSizeSignatureLib(FP) Then
                                    Begin
                                        CandidateDiff := True;
                                        RecordAttention(N, P, 'Pad');
                                        WriteCheckpoint('[PAD SIZE DIFF] ' + N);
                                    End;
                                    If StackSigs[J] <> PadInnerOuterSignatureLib(FP) Then
                                    Begin
                                        CandidateDiff := True;
                                        RecordAttention(N, P, 'Pad');
                                        WriteCheckpoint('[PAD MID/BOTTOM SIZE DIFF] ' + N);
                                    End;
                                    If NameSigs[J] <> PadNamedSignatureLib(FP) Then
                                    Begin
                                        CandidateDiff := True;
                                        RecordAttention(N, P, 'Pad');
                                        WriteCheckpoint('[PAD NAME DIFF] ' + N);
                                    End;
                                End;

                                { 3D Body is independent of all 2D classes. }
                                { 3D body differences are reported only when detected. }
                                If BodyCounts[J] <> IntToStr(Count3DBodiesLib(FP)) Then
                                Begin
                                    RecordAttention(N, P, '3DBody');
                                    If IgnoreClassDifference(N, '3DBody', GlobalPolicy, LocalPolicy) Then
                                    Begin
                                        IgnoredDiff := True;
                                        WriteCheckpoint('  DECISION: IGNORED (3DBody)');
                                    End
                                    Else
                                    Begin
                                        CandidateDiff := True;
                                        WriteCheckpoint('  DECISION: NOT IGNORED (3DBody)');
                                    End;
                                End;

                                { Every primitive class is checked independently. }
                                For ClassNo := 1 To 5 Do
                                Begin
                                    ClassName := '';
                                    ClassId := -1;
                                    If ClassNo = 1 Then Begin ClassName := 'Track'; ClassId := Ord(eTrackObject); End;
                                    If ClassNo = 2 Then Begin ClassName := 'Arc'; ClassId := Ord(eArcObject); End;
                                    If ClassNo = 3 Then Begin ClassName := 'Fill'; ClassId := Ord(eFillObject); End;
                                    If ClassNo = 4 Then Begin ClassName := 'Text'; ClassId := Ord(eTextObject); End;
                                    If ClassNo = 5 Then Begin ClassName := 'Region'; ClassId := Ord(eRegionObject); End;
                                    PCBPrim := PrimClasses[J * 5 + ClassNo - 1];
                                    LibPrim := PrimitiveClassSignatureLib(FP, ClassId);
                                    HadMismatch := (PCBPrim <> LibPrim);
                                    If ClassNo = 1 Then
                                        If (TrackSigs[J] <> TrackDimensionSignatureLib(FP)) Or
                                           (TrackPosSigs[J] <> TrackPositionSignatureLib(FP)) Then
                                            HadMismatch := True;
                                    If ClassNo = 2 Then
                                        If ArcSigs[J] <> ArcGeometrySignatureLib(FP) Then
                                            HadMismatch := True;
                                    If ClassNo = 3 Then
                                        If FillSigs[J] <> OtherPrimitiveSignatureLib(FP, Ord(eFillObject)) Then HadMismatch := True;
                                    If ClassNo = 4 Then
                                        If TextSigs[J] <> OtherPrimitiveSignatureLib(FP, Ord(eTextObject)) Then HadMismatch := True;
                                    If ClassNo = 5 Then
                                        If RegionSigs[J] <> OtherPrimitiveSignatureLib(FP, Ord(eRegionObject)) Then HadMismatch := True;
                                    If HadMismatch Then
                                    Begin
                                        RecordAttention(N, P, ClassName);
                                        WriteCheckpoint('[CLASS DIFF] ' + N + ' / ' + ClassName);
                                        If ClassNo = 1 Then
                                        Begin
                                        End;
                                        If ClassNo = 2 Then
                                        If ClassNo = 3 Then
                                        If ClassNo = 4 Then
                                        If ClassNo = 5 Then
                                        If IgnoreClassDifference(N, ClassName, GlobalPolicy, LocalPolicy) Then
                                        Begin
                                            IgnoredDiff := True;
                                            WriteCheckpoint('  DECISION: IGNORED (' + ClassName + ')');
                                        End
                                        Else
                                        Begin
                                            CandidateDiff := True;
                                            WriteCheckpoint('  DECISION: NOT IGNORED (' + ClassName + ')');
                                        End;
                                    End;
                                End;
                                If CandidateDiff Then
                                Begin
                                    Inc(Diff);
                                    DifferentCandidates[J] := IntToStr(StrToInt(DifferentCandidates[J]) + 1);
                                    WriteCheckpoint('[DIFFERENT] ' + N + ' | ' + CurrentLibName);
                                End
                                Else
                                Begin
                                    Inc(Matches);
                                    If IgnoredDiff Then
                                    Begin
                                        IgnoredCandidates[J] := IntToStr(StrToInt(IgnoredCandidates[J]) + 1);
                                        IgnoredSources[J] := IgnoredSources[J] + P + ' | ';
                                        WriteCheckpoint('[MATCH WITH IGNORED DIFFERENCES] ' + N + ' | ' + CurrentLibName);
                                    End
                                    Else
                                    Begin
                                        ExactCandidates[J] := IntToStr(StrToInt(ExactCandidates[J]) + 1);
                                        ExactSources[J] := ExactSources[J] + P + ' | ';
                                        WriteCheckpoint('[MATCH IN CHECKED CLASSES] ' + N + ' | ' + CurrentLibName);
                                    End;
                                End;
                    End;
                End;
            End;
            End; { matched libraries for this footprint }
        End; { project footprints }
        WriteCheckpoint('');
        WriteCheckpoint('');
        End; { geometry comparison mode }
        WriteCheckpoint('================ SELECTION PREVIEW ================');
        WriteCheckpoint('Stage 4 is read-only; transfer may modify destination in stage 5.');
        If SkipGeometryChecks Then
            WriteCheckpoint('AUTO-CANDIDATE = first name match; GEOMETRY NOT CHECKED')
        Else
        Begin
            WriteCheckpoint('AUTO-CANDIDATE = unique candidate matching all IMPLEMENTED checks,');
            WriteCheckpoint('not a guarantee of complete footprint identity.');
        End;
        For J := 0 To Names.Count - 1 Do
        Begin
            WriteCheckpoint('');
            WriteCheckpoint('FOOTPRINT: ' + Names[J]);
            WriteCheckpoint('  Strict candidates: ' + ExactCandidates[J]);
            WriteCheckpoint('  Ignored-difference candidates: ' + IgnoredCandidates[J]);
            WriteCheckpoint('  Different candidates: ' + DifferentCandidates[J]);
            If PadNums[J] = 'MIXED' Then
                WriteCheckpoint('  [REVIEW PCB] Instances of same pattern differ')
            Else If StrToInt(ExactCandidates[J]) = 1 Then
            Begin
                If SkipGeometryChecks Then
                    WriteCheckpoint('  [AUTO-CANDIDATE] Name matched; geometry NOT CHECKED')
                Else
                    WriteCheckpoint('  [AUTO-CANDIDATE] One strict candidate under implemented checks');
                WriteCheckpoint('  Source: ' + ExactSources[J]);
            End
            Else If StrToInt(ExactCandidates[J]) > 1 Then
            Begin
                WriteCheckpoint('  [REVIEW DUPLICATES] Multiple strict candidates');
                WriteCheckpoint('  Sources: ' + ExactSources[J]);
            End
            Else If StrToInt(IgnoredCandidates[J]) > 0 Then
            Begin
                WriteCheckpoint('  [REVIEW IGNORED] Only candidates with ignored differences');
                WriteCheckpoint('  Sources: ' + IgnoredSources[J]);
            End
            Else
                WriteCheckpoint('  [NO ACCEPTABLE CANDIDATE] Manual review required');
        End;
        Manifest.Add('Footprint,Status,SourcePcbLib,StrictCandidates,IgnoredCandidates,DifferentCandidates');
        For J := 0 To Names.Count - 1 Do
        Begin
            { Omit existing destination names entirely from the transfer queue. }
            If SkipTargetNames.IndexOf(UpperCase(Names[J])) >= 0 Then Continue;
            SelectionStatus := 'NO_ACCEPTABLE_CANDIDATE';
            SelectionSource := '';
            If PadNums[J] = 'MIXED' Then
                SelectionStatus := 'REVIEW_PCB'
            Else If StrToInt(ExactCandidates[J]) = 1 Then
            Begin
                SelectionStatus := 'AUTO_CANDIDATE';
                SelectionSource := SingleSource(ExactSources[J]);
            End
            Else If StrToInt(ExactCandidates[J]) > 1 Then
                SelectionStatus := 'REVIEW_DUPLICATES'
            Else If StrToInt(IgnoredCandidates[J]) > 0 Then
            Begin
                SelectionStatus := 'REVIEW_IGNORED';
                If StrToInt(IgnoredCandidates[J]) = 1 Then
                    SelectionSource := SingleSource(IgnoredSources[J]);
            End;
            Manifest.Add(CsvField(Names[J]) + ',' +
                         CsvField(SelectionStatus) + ',' +
                         CsvField(SelectionSource) + ',' +
                         ExactCandidates[J] + ',' + IgnoredCandidates[J] + ',' +
                         DifferentCandidates[J]);
        End;
        ManifestPath := ExtractFilePath(Prj.DM_ProjectFileName) +
                        'PCB_Footprint_Selection_Manifest_v24.csv';
        Manifest.SaveToFile(ManifestPath);
        SourceCatalog.SaveToFile(ExtractFilePath(ManifestPath) +
            'PCB_Footprint_Source_Catalog_v53.csv');
        WriteCheckpoint('Source catalog: PCB_Footprint_Source_Catalog_v53.csv');
        WriteCheckpoint('Selection manifest: ' + ManifestPath);
        WriteCheckpoint('');
        WriteCheckpoint('Libraries opened: ' + IntToStr(Opened) + ', failed: ' + IntToStr(Failed));
        WriteCheckpoint('Candidates with no unignored differences: ' + IntToStr(Matches));
        WriteCheckpoint('Candidates with unignored differences: ' + IntToStr(Diff));
        P := ExtractFilePath(Prj.DM_ProjectFileName) + 'PCB_Footprint_Selection_Preview_v24.txt';
        { Validation and transfer-queue TXT files are no longer generated.
          The manifest and source catalog CSV are kept for operation. }
        WriteCheckpoint('Target existing footprints excluded: ' + IntToStr(TargetSkippedCount));
        WriteCheckpoint('STAGE 4 COMPLETE: analysis and manifest saved');
    Finally
        SkipTargetNames.Free;
        TargetExistingNames.Free;
        LocalPolicy.Free;
        GlobalPolicy.Free;
        PrimClasses.Free;
        MissingNames.Free;
        MatchedCatalog.Free;
        SourceCatalog.Free;
        Manifest.Free;
        FoundFootprints.Free;
        Paths.Free;
        IgnoredSources.Free;
        ExactSources.Free;
        DifferentCandidates.Free;
        IgnoredCandidates.Free;
        ExactCandidates.Free;
        BodyCounts.Free;
        RegionSigs.Free;
        TextSigs.Free;
        FillSigs.Free;
        ArcSigs.Free;
        TrackPosSigs.Free;
        TrackSigs.Free;
        PrimSigs.Free;
        NameSigs.Free;
        StackSigs.Free;
        SizeSigs.Free;
        PadSigs.Free;
        InstanceCounts.Free;
        PadNums.Free;
        Names.Free;
    End;
End;

{ Stage 27 - guarded single-component transfer experiment.
  Run TransferOneVerifiedFootprint separately from the analysis command.
  Script creates a NEW EMPTY destination PcbLib itself.
  No Save is issued by this test. }
Function TransferGeometryAudit(Comp : IPCB_LibComponent) : String;
Begin
    If Comp = Nil Then Begin Result := 'NIL COMPONENT'; Exit; End;
    Result := 'Pads=' + IntToStr(CountPadsInGroupLib(Comp)) +
        '|PadNames=' + PadNamedSignatureLib(Comp) +
        '|PadSizes=' + PadSizeSignatureLib(Comp) +
        '|PadLayers=' + PadInnerOuterSignatureLib(Comp) +
        '|PadDistances=' + PadDistanceSignatureLib(Comp) +
        '|PrimitiveCounts=' + PrimitiveCountSignatureLib(Comp) +
        '|Tracks=' + TrackDimensionSignatureLib(Comp) +
        '|Arcs=' + ArcGeometrySignatureLib(Comp) +
        '|3DBodies=' + IntToStr(Count3DBodiesLib(Comp));
End;

{ A per-footprint source catalog, produced during the analysis scan.
  One record per actual footprint/library pair, regardless of match status. }
Function SelectSourceFromCatalog(BasePath, FootprintName, CurrentPath : String) : String;
Var
    Catalog, Options : TStringList;
    RowNo, ItemNo, ChoiceNo : Integer;
    CatalogPath, LibPath, PromptText, Answer : String;
Begin
    Result := '';
    CatalogPath := BasePath + 'PCB_Footprint_Source_Catalog_v53.csv';
    Catalog := TStringList.Create;
    Options := TStringList.Create;
    Try
        If FileExists(CatalogPath) Then
        Begin
            Catalog.LoadFromFile(CatalogPath);
            For RowNo := 1 To Catalog.Count - 1 Do
            Begin
                If UpperCase(Trim(CSVColumn(Catalog[RowNo], 0))) =
                   UpperCase(Trim(FootprintName)) Then
                Begin
                    LibPath := CleanLibraryPath(CSVColumn(Catalog[RowNo], 1));
                    If (LibPath <> '') And (Options.IndexOf(LibPath) < 0) Then
                        Options.Add(LibPath);
                End;
            End;
        End;
        If Options.Count = 0 Then
        Begin
            ShowMessage('No source library found for: ' + FootprintName);
            Exit;
        End;
        If Options.Count = 1 Then
        Begin
            Result := Options[0];
            Exit;
        End;
        PromptText := 'Footprint: ' + FootprintName + #13#10 +
                      'Select source PcbLib (0 = skip):' + #13#10;
        For ItemNo := 0 To Options.Count - 1 Do
            PromptText := PromptText + IntToStr(ItemNo + 1) + ' = ' +
                          Options[ItemNo] + #13#10;
        Answer := Trim(AskInputOrAbort('SELECT SOURCE LIBRARY', PromptText, '0'));
        ChoiceNo := StrToIntDef(Answer, 0);
        If (ChoiceNo >= 1) And (ChoiceNo <= Options.Count) Then
            Result := Options[ChoiceNo - 1];
    Finally
        Options.Free;
        Catalog.Free;
    End;
End;

Procedure TransferSelectedFootprintsBatch;
Var
    WS : IWorkspace;
    Prj : IProject;
    DestDoc : IServerDocument;
    DestLib : IPCB_Library;
    SourceComp, ExistingComp : IPCB_LibComponent;
    Lines, Impossible, Seen : TStringList;
    ManifestPath, BasePath, Name, Status, SourcePath, Choice, Reason : String;
    PolicyIgnored, PolicyDuplicate, PolicyPCB, PolicyOther, PolicyError : String;
    PolicyExisting : String;
    RowNo, CopiedCount, SkippedCount, FailedCount : Integer;
    Allowed, RegisteredOK : Boolean;
    TargetPath, BackupPath, SourceAudit, DestAudit : String;
    ExcludeTarget, UseExisting, SkipGeometryChecks : Boolean;
Begin
    WS := GetWorkspace;
    If WS = Nil Then Begin ShowMessage('Workspace unavailable'); Exit; End;
    Prj := WS.DM_FocusedProject;
    If Prj = Nil Then Begin ShowMessage('Focused project unavailable'); Exit; End;
    BasePath := ExtractFilePath(Prj.DM_ProjectFileName);
    ManifestPath := BasePath + 'PCB_Footprint_Selection_Manifest_v24.csv';
    If Not FileExists(ManifestPath) Then
    Begin
        ShowMessage('Manifest not found. Run BuildPCBFootprintSelectionAndApproveTransfer first: ' + ManifestPath);
        Exit;
    End;
    If Not ReadTargetSelection(Prj, TargetPath, ExcludeTarget, SkipGeometryChecks) Then
    Begin
        ShowMessage('Target configuration missing. Run analysis first.');
        Exit;
    End;
    UseExisting := TargetPath <> '';
    If UseExisting And (Not FileExists(TargetPath)) Then
    Begin
        ShowMessage('Target PcbLib not found on disk: ' + TargetPath + #13#10 + 'Save the library and run analysis again.');
        Exit;
    End;
    Choice := UpperCase(Trim(AskInputOrAbort('BATCH TRANSFER',
        'Destination: ' + TargetPath + #13#10 +
        'Copy verified footprints into this destination?' + #13#10 +
        'AUTO_CANDIDATE will be copied automatically.' + #13#10 +
        'Review/error entries require approval.' + #13#10 +
        'T = transfer; N = cancel.', 'N')));
    If Choice <> 'T' Then
    Begin
        WriteCheckpoint('Transfer declined');
        Exit;
    End;
    WriteCheckpoint('Transfer confirmed');
    Lines := TStringList.Create;
    Impossible := TStringList.Create;
    Seen := TStringList.Create;
    Try
        If SkipGeometryChecks Then
            WriteCheckpoint('STAGE 5 - GEOMETRY AUDIT DISABLED (user mode)')
        Else
            WriteCheckpoint('STAGE 5 - SOURCE-ONLY TRANSFER AUDIT');
        WriteCheckpoint('');
        Lines.LoadFromFile(ManifestPath);
        If (Lines.Count = 0) Or (CSVColumn(Lines[0], 0) <> 'Footprint') Then
        Begin
            ShowMessage('Invalid manifest header. Transfer cancelled.');
            Exit;
        End;
        WriteCheckpoint('STAGE 5 - BATCH FOOTPRINT TRANSFER');
        WriteCheckpoint('Manifest: ' + ManifestPath);
        If UseExisting Then WriteCheckpoint('Destination: ' + TargetPath)
        Else WriteCheckpoint('Destination: NEW UNSAVED PcbLib document');
        Impossible.Add('Footprint,Status,SourcePcbLib,Reason');
        CopiedCount := 0;
        SkippedCount := 0;
        FailedCount := 0;
        PolicyIgnored := '';
        PolicyDuplicate := '';
        PolicyPCB := '';
        PolicyOther := '';
        PolicyError := '';
        PolicyExisting := '';
        Client.StartServer('PCB');
        If UseExisting Then
        Begin
            { Never change an existing library without a verified backup. }
            BackupPath := TargetPath + '.backup_v32';
            If FileExists(BackupPath) Then
            Begin
                ShowMessage('Backup already exists; transfer cancelled: ' + BackupPath);
                Exit;
            End;
            If Not BackupExistingPcbLib(TargetPath, BackupPath) Then
            Begin
                ShowMessage('Cannot back up target; transfer cancelled.');
                Exit;
            End;
            WriteCheckpoint('Backup created: ' + BackupPath);
            DestDoc := Client.OpenDocument('PCBLIB', TargetPath);
        End
        Else
            DestDoc := CreateNewDocumentFromDocumentKind('PCBLib');
        If DestDoc = Nil Then
        Begin
            ShowMessage('Cannot open/create destination PcbLib.');
            Exit;
        End;
        Client.ShowDocument(DestDoc);
        DestLib := PCBServer.GetCurrentPCBLibrary;
        If DestLib = Nil Then
        Begin
            ShowMessage('Cannot access destination PcbLib.');
            Exit;
        End;
        For RowNo := 1 To Lines.Count - 1 Do
        Begin
            WriteCheckpoint('Transfer ' + IntToStr(RowNo) + '/' +
                IntToStr(Lines.Count - 1) + ': ' + CSVColumn(Lines[RowNo], 0));
            Name := Trim(CSVColumn(Lines[RowNo], 0));
            Status := Trim(CSVColumn(Lines[RowNo], 1));
            SourcePath := CleanLibraryPath(CSVColumn(Lines[RowNo], 2));
            Reason := '';
            Allowed := Status = 'AUTO_CANDIDATE';
            If Name = '' Then
                Reason := 'Empty footprint name'
            Else If Seen.IndexOf(UpperCase(Name)) >= 0 Then
                Reason := 'Duplicate footprint in manifest';
            If Reason = '' Then Seen.Add(UpperCase(Name));
            If (Reason = '') And (Not Allowed) Then
            Begin
                If Status = 'REVIEW_IGNORED' Then Choice := PolicyIgnored
                Else If Status = 'REVIEW_DUPLICATES' Then Choice := PolicyDuplicate
                Else If Status = 'REVIEW_PCB' Then Choice := PolicyPCB
                Else If Status = 'NO_ACCEPTABLE_CANDIDATE' Then Choice := PolicyError
                Else Choice := PolicyOther;
                If Choice = '' Then
                Begin
                    Repeat
                    Choice := UpperCase(Trim(AskInputOrAbort('REVIEW: ' + Status,
                        'Footprint: ' + Name + #13#10 +
                        'Source: ' + SourcePath + #13#10 +
                        'Y = allow once; A = allow all with same status;' + #13#10 +
                        'N = skip once; S = skip all with same status;' + #13#10 +
                        'X = stop the entire batch.', 'N')));
                    Until (Choice = 'Y') Or (Choice = 'A') Or
                          (Choice = 'N') Or (Choice = 'S') Or (Choice = 'X');
                    If Choice = 'A' Then
                    Begin
                        If Status = 'REVIEW_IGNORED' Then PolicyIgnored := 'Y'
                        Else If Status = 'REVIEW_DUPLICATES' Then PolicyDuplicate := 'Y'
                        Else If Status = 'REVIEW_PCB' Then PolicyPCB := 'Y'
                        Else If Status = 'NO_ACCEPTABLE_CANDIDATE' Then PolicyError := 'Y'
                        Else PolicyOther := 'Y';
                    End
                    Else If Choice = 'S' Then
                    Begin
                        If Status = 'REVIEW_IGNORED' Then PolicyIgnored := 'N'
                        Else If Status = 'REVIEW_DUPLICATES' Then PolicyDuplicate := 'N'
                        Else If Status = 'REVIEW_PCB' Then PolicyPCB := 'N'
                        Else If Status = 'NO_ACCEPTABLE_CANDIDATE' Then PolicyError := 'N'
                        Else PolicyOther := 'N';
                    End;
                End;
                If Choice = 'X' Then
                Begin
                    WriteCheckpoint('[STOP] User stopped before: ' + Name);
                    Break;
                End;
                Allowed := (Choice = 'Y') Or (Choice = 'A');
                If Not Allowed Then Reason := 'User skipped review status: ' + Status;
            End;
            { Offer all actually discovered libraries for this footprint.
              The target may have been excluded from the source scan. }
            If (Reason = '') And ((SourcePath = '') Or
                (Status = 'REVIEW_DUPLICATES')) Then
            Begin
                SourcePath := SelectSourceFromCatalog(BasePath, Name, SourcePath);
                If SourcePath <> '' Then
                    WriteCheckpoint('[SOURCE SELECTED] ' + Name + ' <= ' + SourcePath);
            End;
            If (Reason = '') And UseExisting And SamePcbLibPath(SourcePath, TargetPath) Then
                Reason := 'Source equals destination: already present (no copy)';
            If (Reason = '') And (SourcePath = '') Then
                Reason := 'No unique source selected; manual source choice required';
            If (Reason = '') And (Not FileExists(SourcePath)) Then
                Reason := 'Source library file missing';
            { Existing target: ask even for AUTO_CANDIDATE.
              Y=replace once, A=replace all existing-name conflicts,
              N=skip once, S=skip all. Cancel stops entire script. }
            If (Reason = '') And (DestLib.GetComponentByName(Name) <> Nil) Then
            Begin
                ExistingComp := DestLib.GetComponentByName(Name);
                Choice := PolicyExisting;
                If Choice = '' Then
                Begin
                    Repeat
                        Choice := UpperCase(Trim(AskInputOrAbort('TARGET FOOTPRINT EXISTS',
                            'Footprint: ' + Name + #13#10 +
                            'Destination: ' + TargetPath + #13#10 +
                            'Y = replace once; A = replace ALL existing;' + #13#10 +
                            'N = skip once; S = skip ALL existing;' + #13#10 +
                            'X = stop batch.', 'N')));
                    Until (Choice = 'Y') Or (Choice = 'A') Or
                          (Choice = 'N') Or (Choice = 'S') Or (Choice = 'X');
                    If Choice = 'A' Then PolicyExisting := 'Y';
                    If Choice = 'S' Then PolicyExisting := 'N';
                End;
                If Choice = 'X' Then
                Begin
                    WriteCheckpoint('[STOP] User stopped at existing target: ' + Name);
                    Break;
                End;
                If (Choice = 'N') Or (Choice = 'S') Then
                    Reason := 'Already present in destination (user skipped)'
                Else
                Begin
                    { Source is loaded BEFORE deleting existing target. }
                    SourceComp := PCBServer.LoadCompFromLibrary(Name, SourcePath);
                    If SourceComp = Nil Then
                        Reason := 'Replacement source could not be loaded'
                    Else
                    Begin
                        If Not SkipGeometryChecks Then
                            SourceAudit := TransferGeometryAudit(SourceComp);
                        WriteCheckpoint('[REPLACE SOURCE] ' + Name + ' <= ' + SourcePath);
                        Client.ShowDocument(DestDoc);
                        DestLib := PCBServer.GetCurrentPCBLibrary;
                        If DestLib = Nil Then
                        Begin
                            WriteCheckpoint('[ERROR] Destination PcbLib not active: ' + TargetPath);
                            Exit;
                        End;
                        PCBServer.PreProcess;
                        Try
                            DestLib.RemoveComponent(ExistingComp);
                            RegisteredOK := DestLib.RegisterComponent(SourceComp);
                        Finally
                            PCBServer.PostProcess;
                        End;
                        If Not RegisteredOK Then
                            Reason := 'Replacement registration failed - restore target from backup'
                        Else
                        Begin
                            ExistingComp := DestLib.GetComponentByName(Name);
                            If ExistingComp = Nil Then
                                Reason := 'Replacement absent after registration - restore backup'
                            Else If Not SkipGeometryChecks Then
                            Begin
                                If TransferGeometryAudit(ExistingComp) <> SourceAudit Then
                                    Reason := 'Replacement audit mismatch - inspect target'
                                Else
                                Begin
                                    WriteCheckpoint('[REPLACED] ' + Name + ' <= ' + SourcePath + ' | Attention: ' + AttentionClasses(Name, SourcePath));
                                    Inc(CopiedCount);
                                    Reason := 'REPLACED_OK';
                                End;
                            End
                            Else
                            Begin
                                WriteCheckpoint('[REPLACED] ' + Name + ' <= ' + SourcePath + ' | Geometry: SKIPPED');
                                Inc(CopiedCount);
                                Reason := 'REPLACED_OK';
                            End;
                        End;
                    End;
                End;
            End;
            If Reason = '' Then
            Begin
                SourceComp := PCBServer.LoadCompFromLibrary(Name, SourcePath);
                If SourceComp = Nil Then Reason := 'LoadCompFromLibrary returned Nil'
                Else
                Begin
                    If Not SkipGeometryChecks Then
                        SourceAudit := TransferGeometryAudit(SourceComp);
                    WriteCheckpoint('[SOURCE] ' + Name + ' <= ' + SourcePath);
                    Client.ShowDocument(DestDoc);
                    DestLib := PCBServer.GetCurrentPCBLibrary;
                    If DestLib = Nil Then
                    Begin
                        WriteCheckpoint('[ERROR] Destination PcbLib not active: ' + TargetPath);
                        Exit;
                    End;
                    PCBServer.PreProcess;
                    Try
                        RegisteredOK := DestLib.RegisterComponent(SourceComp);
                    Finally
                        PCBServer.PostProcess;
                    End;
                    If Not RegisteredOK Then Reason := 'RegisterComponent returned False'
                    Else
                    Begin
                        ExistingComp := DestLib.GetComponentByName(Name);
                        If ExistingComp = Nil Then
                            Reason := 'Not found in destination after registration'
                        Else
                        Begin
                            If Not SkipGeometryChecks Then
                            Begin
                                DestAudit := TransferGeometryAudit(ExistingComp);
                                If SourceAudit <> DestAudit Then
                                Begin
                                    Reason := 'REGISTERED BUT AUDIT MISMATCH - inspect before saving';
                                    WriteCheckpoint('[MISMATCH] ' + Name);
                                End
                                Else
                                    WriteCheckpoint('  Geometry: EQUAL');
                            End
                            Else
                                WriteCheckpoint('  Geometry: SKIPPED (user mode)');
                        End;
                    End;
                End;
            End;
            If (Reason <> '') And (Reason <> 'REPLACED_OK') Then
                WriteCheckpoint('[NOT VERIFIED] ' + Name + ': ' + Reason);
            If (Reason = '') Or (Reason = 'REPLACED_OK') Then
            Begin
                If Reason = '' Then
                Begin
                    Inc(CopiedCount);
                    WriteCheckpoint('[COPIED] ' + Name + ' <= ' + SourcePath + ' | Attention: ' + AttentionClasses(Name, SourcePath));
                End;
            End
            Else
            Begin
                If (Pos('User skipped', Reason) = 1) Or
                   (Pos('Already present', Reason) = 1) Or
                   (Pos('Source equals destination', Reason) = 1) Then Inc(SkippedCount)
                Else Inc(FailedCount);
                WriteCheckpoint('[NOT COPIED] ' + Name + ': ' + Reason + ' | Attention: ' + AttentionClasses(Name, SourcePath));
                Impossible.Add(CsvField(Name) + ',' + CsvField(Status) + ',' +
                    CsvField(SourcePath) + ',' + CsvField(Reason));
            End;
        End;
        WriteCheckpoint('');
        WriteCheckpoint('Copied: ' + IntToStr(CopiedCount));
        WriteCheckpoint('Skipped: ' + IntToStr(SkippedCount));
        WriteCheckpoint('Not copied/errors: ' + IntToStr(FailedCount));
        WriteCheckpoint('IMPORTANT: inspect all transferred footprints and 3D models before saving.');
        WriteCheckpoint('Default PCBCOMPONENT_1 may remain and must be removed manually.');
        WriteCheckpoint('STAGE 5 COMPLETE: transfer summary recorded');
        ShowMessage('Batch transfer finished.' + #13#10 +
            'Copied: ' + IntToStr(CopiedCount) + #13#10 +
            'Skipped: ' + IntToStr(SkippedCount) + #13#10 +
            'Errors: ' + IntToStr(FailedCount) + #13#10 +
            'Inspect the target PcbLib before saving. Existing files have a backup.');
    Finally
        Seen.Free;
        Impossible.Free;
        Lines.Free;
    End;
End;

{ Stage 37: single entry point. The batch transfer procedure already asks
  T/N before making any destination changes, so there is only one prompt. }
Procedure RunFootprintAnalysisAndTransfer;
Var
    WS : IWorkspace;
    Prj : IProject;
    ManifestPath : String;
Begin
    WS := GetWorkspace;
    If WS = Nil Then
    Begin
        ShowMessage('Workspace unavailable.');
        Exit;
    End;
    Prj := WS.DM_FocusedProject;
    If Prj = Nil Then
    Begin
        ShowMessage('Focused project unavailable.');
        Exit;
    End;

    ManifestPath := ExtractFilePath(Prj.DM_ProjectFileName) +
                    'PCB_Footprint_Selection_Manifest_v24.csv';
    { Prevent transfer of a stale manifest if the analysis is cancelled.
      This manifest is a generated intermediate file, not a user library. }
    If FileExists(ExtractFilePath(Prj.DM_ProjectFileName) +
        'PCB_Footprint_Name_Matches_v54.csv') Then
        DeleteFile(ExtractFilePath(Prj.DM_ProjectFileName) +
            'PCB_Footprint_Name_Matches_v54.csv');
    If FileExists(ManifestPath) Then
    Begin
        If Not DeleteFile(ManifestPath) Then
        Begin
            ShowMessage('Cannot clear old manifest. Analysis cancelled: ' + ManifestPath);
            Exit;
        End;
    End;

    { Unique report name based on this run's local start date and time. }
    GCheckpointPath := ExtractFilePath(Prj.DM_ProjectFileName) +
                       'PCB_Footprint_Full_Report_' +
                       FormatDateTime('yyyymmdd_hhnnss', Now) + '.txt';
    AssignFile(GReportFile, GCheckpointPath);
    Rewrite(GReportFile);
    GReportOpen := True;
    Try
        WriteCheckpoint('START: five-stage footprint processing; direct-write report');
        BuildPCBFootprintSelectionAndApproveTransfer;

    If Not FileExists(ManifestPath) Then
    Begin
        ShowMessage('Analysis did not produce a manifest. Transfer cancelled.');
        Exit;
    End;

    { TransferSelectedFootprintsBatch shows T/N confirmation itself.
      N leaves the analysis and unified report available. }
        WriteCheckpoint('STAGE 5 START: transfer decision and execution');
        TransferSelectedFootprintsBatch;
        WriteCheckpoint('STAGE 5 COMPLETE: transfer routine returned');
        WriteCheckpoint('END: processing finished');
    Finally
        If GReportOpen Then
        Begin
            Flush(GReportFile);
            CloseFile(GReportFile);
            GReportOpen := False;
        End;
    End;
End;

Begin
    GCheckpointPath := '';
    GReportOpen := False;
    GAttentionCount := 0;
    RunFootprintAnalysisAndTransfer;
End.
