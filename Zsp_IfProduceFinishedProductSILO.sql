
use dbTraceInt
go

if not exists (select * from dbo.sysobjects where id = object_id(N'Zsp_IfProduceFinishedProductSILO') and objectproperty(id, N'IsProcedure') = 1)
  execute (N'create procedure Zsp_IfProduceFinishedProductSILO as begin return end')
go

-- Protokollausgabe
print N'Anlegen der gespeicherten Prozedur <' + db_name() + N'..Zsp_IfProduceFinishedProductSILO>'
go

/* -- Testaufruf
select * from dbTraceIt..tblTdPlanOrder where nCondition=1
select * from dbTraceIt..vwMdRessourceLinePlantTiny
select dbTraceIt.dbo.fn_SysObjectGetTechname(nMaterialLink), * from dbTraceIt..tblMdBOMComponent where nBOMHeaderLink = 37832

declare @nError int, @szError nvarchar(200)
exec dbTraceInt..Zsp_IfProduceFinishedProductSILO
      @szOrderNumber        = N'000001123248'
    , @szMaterialNumber     = N'000000000001102751' -- N'000000000001201053'
    , @rQuantity            = 27
    , @szZielsilo           = N'Granulatsilo05'
    , @szANLAGENTEIL        = N'41'
    , @nError  = @nError output, @szError = @szError output
    , @bDebug  = 1
select [@nError]  = @nError
     , [@szError] = @szError
*/
alter procedure Zsp_IfProduceFinishedProductSILO
      @szOrderNumber        nvarchar(200)         -- Auftragsnummer
    , @szMaterialNumber     nvarchar(200) = N''   -- Material
    , @rQuantity            float                 -- Produzierte Menge
    , @szZielsilo           nvarchar(200) = N''   -- Zielsilo
    , @szANLAGENTEIL        nvarchar(2)   = N'00' -- Anlagenteil für Chargennummer
    , @szReasonIntLink      nvarchar(200) = N'[PlanTiT_LMS]'  -- Ident für Buchung
    , @szProdCharge         nvarchar(200) = N''
    , @bSAP_Booking         bit = 1               -- Verbuchungen an SAP ERP Durchfuehren (Erstellug der Charge / Menge melden)
    , @bBatchnumberNew      bit = 0               -- Erzwingen, dass ein neuer Quant angelegt wird

    , @bNoResultset   int = 0                     -- <> 0: kein Resultset ausgeben (wesentliche Rueckgaben sollten per output erfolgen)
    , @nError         int = 0             output  -- [MUSS-Parameter] Fehlernummer
    , @szError        nvarchar(200) = N'' output  -- [MUSS-Parameter] Fehlerbeschreibung
    , @bDebug         int = 0                     -- [MUSS-Parameter] <> 0: Debug-Ausgabe erzeugen
as
/********************************************************************************
  Name     : Zsp_IfProduceFinishedProductSILO

  Aufgabe  : Mechanismus fuer die Erstellung von SILOWARE
             Fuer den Quellauftrag wird die Charge erstellt/bebucht
             (Produzierte Menge und die Charge werden an SAP ERP gemeldet)
                
  Parameter: (Beschreibung siehe Schnittstellen-Definition)
    
  Returns  : (...)
             nError:  0 - Erfolgreich abgeschlossen

  Hinweise : (...)
             benoetigt die folgenden DB-Objekte:

              - dbTraceInt.dbo.fn_SysDebugPrint
              - dbTraceInt.dbo.fn_SysDebugPrint_Timestamp
              - dbTraceInt.dbo.fn_SysDebugPrint_DateTime
              - dbTraceIt.dbo.ZtblReportFailedBookingProtocol
    
  Historie :
             03.11.2016, PHe, Bestandstyp "0" gibt es nicht. Die Freigabe des Quants wird nun per Tx2140 bewirkt
             23.08.2016, PHe, Plausibilitätsprotokoll im Fehlerfall füllen
             03.08.2016, PHe, Neue Quants werden direkt als "frei" erstellt und nicht als "gesperrt"
             05.07.2016, MSh, Es wird jetzt die Chargennummer übergeben, wenn sie Befüllt ist wird nur noch diese verwendet
             09.06.2016, PHe, Material wird vor dem Auftrag verifiziert, da wir das Material für das MHD benötigen
             08.06.2016, PHe, MHD wird nicht mehr vom Zielprodukt ausgelesen sondern vom Material welches übergeben wird
             08.06.2016, PHe, Batchnummer wird auch bei der PI_PROD nur für chargenpflichtige Materialien übergeben
             08.06.2016, PHe, BATCH_CREATE nur, wenn das Material auch chargenpflichtig ist
             02.06.2016, KRz, Fehlerhandling vereinheitlicht
             01.06.2016, KRz, Sonderbehandlung für Kuppelprodukte für Zsp_MEG_MES2SAP_Batch_Production_FERT_Create
             31.05.2016, KRz, Erstellt
                                auf Basis von Zsp_IfProduceFinishedProductByNVE_Number
                                          und Zsp_If_Produce_Consume_Semi_Finished_Product

********************************************************************************/
begin

  -- Einstellungen
  set rowcount 0
  set nocount on

  -- Name der Prozedur
  declare @szModule sysname
  select @szModule = object_name (@@procid)

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  declare @dtStartZeit datetime
  set @dtStartZeit = getdate()

  print N'==========================================='
  print N'START ' + @szModule + N': ' + dbTraceIt.dbo.fn_SysDebugPrint_DateTime(@dtStartZeit, default)
  print N''
  print N'[!] Uebergabeparameter:'
  print N'  @szOrderNumber        = ' + dbo.fn_SysDebugPrint(@szOrderNumber)
  print N'  @szMaterialNumber     = ' + dbo.fn_SysDebugPrint(@szMaterialNumber)
  print N'  @rQuantity            = ' + dbo.fn_SysDebugPrint(@rQuantity)
  print N'  @szZielsilo           = ' + dbo.fn_SysDebugPrint(@szZielsilo)
  print N'  @szANLAGENTEIL        = ' + dbo.fn_SysDebugPrint(@szANLAGENTEIL)
  print N'  @szReasonIntLink      = ' + dbo.fn_SysDebugPrint(@szReasonIntLink)
  print N'  @bSAP_Booking         = ' + dbo.fn_SysDebugPrint(@bSAP_Booking)
  print N'  @bBatchnumberNew      = ' + dbo.fn_SysDebugPrint(@bBatchnumberNew)
  print N'  @bNoResultset         = ' + dbo.fn_SysDebugPrint(@bNoResultset)
  print N'  @nError               = ' + dbo.fn_SysDebugPrint(@nError)
  print N'  @szError              = ' + dbo.fn_SysDebugPrint(@szError)
  print N'  @bDebug               = ' + dbo.fn_SysDebugPrint(@bDebug)
end
/*DEBUG_Ausgabe ENDE*/


/* Plausibilitaets-Tabelle Grundinformation Start */
  declare @szPlausiInfo nvarchar(4000)
  
  Select @szPlausiInfo = 
  
          N'[!] Uebergabeparameter:'
        + N' @szOrderNumber    = ' + dbo.fn_SysDebugPrint(@szOrderNumber)
        + N' @szMaterialNumber = ' + dbo.fn_SysDebugPrint(@szMaterialNumber)
        + N' @rQuantity        = ' + dbo.fn_SysDebugPrint(@rQuantity)
        + N' @szZielsilo       = ' + dbo.fn_SysDebugPrint(@szZielsilo)
        + N' @szANLAGENTEIL    = ' + dbo.fn_SysDebugPrint(@szANLAGENTEIL)
        + N' @szReasonIntLink  = ' + dbo.fn_SysDebugPrint(@szReasonIntLink)
        + N' @bSAP_Booking     = ' + dbo.fn_SysDebugPrint(@bSAP_Booking)
        + N' @bNoResultset     = ' + dbo.fn_SysDebugPrint(@bNoResultset)
        + N' @nError           = ' + dbo.fn_SysDebugPrint(@nError)
        + N' @szError          = ' + dbo.fn_SysDebugPrint(@szError)
        + N' @bDebug           = ' + dbo.fn_SysDebugPrint(@bDebug)

/*  Plausibilitaets-Tabelle Grundinformation Ende */

  if @nError <> 0
    return
  set @nError = 0

  -- -----------------------------------------------------------------
  -- Vorbereitung Transaktionshandling
  -- ------------------------------------------------------------------
  declare @bUseTransaction bit
  select  @bUseTransaction = case when @@trancount > 0 then 0 else 1 end

  -- ------------------------------------------------------------------
  -- Einleitende Validierungen
  -- ------------------------------------------------------------------
  -- (keine)

  -- ------------------------------------------------------------------
  -- Deklaration von Variablen und Konstanten
  -- ------------------------------------------------------------------
  -- Trace iT Zeitstempel
  declare @tNow int, @tJob int
  exec dbTraceIt..sp_SysTimestampGetCurrent @tNow output
  select  @tJob = @tNow

  declare @szOrderIntLink             nvarchar(200)   -- Techname Auftrag
        , @nPlantLink                 int             -- Anlage des Auftrags
        , @nReasonLink                int             -- Buchungsgrund
        , @nPlanOrderLink             int             -- Auftrag
        , @szMHDHB                    nvarchar(200)   -- Anzahl der Tage bis Mindesthaltbarkeit endet
        , @szSTORAGE_LOCATION         nvarchar(200)   -- SAP-Lagerort des Autrags
        , @nMaterialLink              int             -- Material
        , @nTargetRLPLink             int             -- Zielsilo
        , @bGenerateNewBatchnumberMES int             -- 1, wenn im MESChargennummer neu generiert werden muss
        , @bGenerateNewBatchnumberSAP int             -- 1, wenn für SAP Chargennummer neu generiert werden muss
        , @szBatchNumber              nvarchar(200)   -- Generierte Chargennummer
        , @nTargetQuantLink           int             -- gefundener ZielQuant 
        , @szTargetQuantLink          nvarchar(200)   -- gefundener ZielQuant
        , @szSAPMaterialNumber        nvarchar(200)   -- Für Kuppelprodukte
        , @bIsByProduct               int = 0         -- Ist Material ein Kuppelprodukt? -> 1
        , @ZnXCHPF                    nvarchar(200)   -- Chargenpflichtig? -> dann = 1

  -- Konstanten fuer Transaktionen 
  declare @szInfo                     nvarchar(200)  = @szModule + N': Rückmeldung Wareneingang SILO-Ware'
        , @szUser                     nvarchar(200)  = N'[Interface]'
        , @szURL                      nvarchar(200)  = null 
        , @szSourceSystem             nvarchar(200)  = N'PlantiTLMS' 

  ---- Fehlertexte laden
  ----  -> unter \13_ZAddOn-ZUsermodel\03 CustomizeThis.tsq sind die SpecialText-Objekte anzulegen
  ---- Defaulttexte beginnen immer mit <#>
  --declare @szERRORTEXT_Success  nvarchar(200)
  --select @szERRORTEXT_Success = isnull(dbo.fn_SysObjectGetLanguageText(N'SQL:' + @szModule + N'.@szERRORTEXT_Success', @nLanguageLink, @tNow, N'[SysLanguageText]'), N'#Erfolgreich abgeschlossen')

  -- ==================================================================
  -- Hauptteil
  -- ==================================================================
  begin try

    -- ------------------------------------------------------------------
    -- Chargennummer erstellen
    --   (hier manuell, da dbTraceIt..Zsp_If_Create_Batchnumber mit fotlaufender Nummer arbeitet (?!))
    -- ------------------------------------------------------------------       
    -- WWWWJTTTAA ('W'erkskennung, 'J'ahr, 'T'ag des Jahres,'A'nlagenteil)
    declare @szJTTT                   nvarchar(4)   -- Jahr + Tag
          , @szWERK                   nvarchar(200)   -- Werk
    select @szWERK = dbTraceIt.dbo.Zfn_FoGetWERKS(@tNow)
    select @szJTTT = right(convert(nvarchar, datepart(yyyy, getdate())), 1)
                   + right(N'000' + convert(nvarchar, datepart(dy, getdate())),3)

    if (@szProdCharge = N'')
    begin
      select @szBatchNumber =  @szWERK + @szJTTT + @szANLAGENTEIL
    end

    else 
    begin
      select @szBatchNumber = @szProdCharge
    end

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  @szWERK        = ' + dbo.fn_SysDebugPrint(@szWERK)
  print N'  @szJTTT        = ' + dbo.fn_SysDebugPrint(@szJTTT)
  print N'  @szBatchNumber = ' + dbo.fn_SysDebugPrint(@szBatchNumber)
end
/*DEBUG_Ausgabe ENDE*/

    -- ------------------------------------------------------------------
    -- Die Menge für die Erstellung bzw. Verbrauch des Halbfertigprodukts
    -- muss größer > 0 sein
    -- ------------------------------------------------------------------ 
    if @rQuantity <= 0.0 begin
      select @nError = 1
           , @szError = N'Die Menge für die Erstellung bzw. Verbrauch von dem Hablfertigprodukt muss grosser 0 seien!'
      goto sp_error -- die Prozedur verlassen
    end  -- [if @rQuantity <= 0.0 begin]
  
    -- ------------------------------------------------------------------
    -- Auftrag/Material ausschlachten/verifizieren
    -- ------------------------------------------------------------------
    
    -- --------------------------------------------------
    -- Plausibilitaets Pruefung Material
    -- --------------------------------------------------
    select @nMaterialLink = mat.nKey 
         , @ZnXCHPF       = dbTraceIt.dbo.Zfn_SysSelectSingleMaterialParameterValue(mat.nKey, N'XCHPF', null)
    from   dbTraceIt..tblMdMaterial       mat
           join dbTraceIt..tblSysIntLink  sil_mat on sil_mat.nKey = mat.nKey
    where  1=1
    and    sil_mat.szIntLink  = @szMaterialNumber
           -- nur auf gueltige Materialien schauen
    and    sil_mat.nStatus between 2 and 16
    and    @tNow between sil_mat.tValidFrom and sil_mat.tValidTill
  
/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'-------------------------------------------'
  print N'Daten zum Material:'
  print N'  @nMaterialLink     = ' + dbo.fn_SysDebugPrint(@nMaterialLink)
  print N'  @ZnXCHPF           = ' + dbo.fn_SysDebugPrint(@ZnXCHPF)
end
/*DEBUG_Ausgabe ENDE*/
  
    if isnull(@nMaterialLink, 0) = 0 begin
      print  N'-------------------------------------------'
      print  N'Material/nMaterialLink im MES nicht bekannt'
      select @nError = 3
           , @szError = N'Material/nMaterialLink im MES nicht bekannt'
      goto sp_error            
    end  -- [if isnull(@nMaterialLink, 0) = 0 begin]
    
    -- --------------------------------------------------
    -- Plausibilitaets Pruefung Auftrag
    -- --------------------------------------------------
    select @szOrderIntLink      = sil_po.szIntLink 
         , @nPlantLink          = po.nPlantLink
         , @nPlanOrderLink      = po.nKey     
         , @szMHDHB             =  dbTraceIt.dbo.Zfn_SysSelectSingleMaterialParameterValue(@nMaterialLink, N'MHDHB', null)  -- Anzahl in Tagen        
         , @szSTORAGE_LOCATION  = po.ZszLGORT
    from   dbTraceIt..tblTdPlanOrder      po
            join dbTraceIt..tblSysIntLink  sil_po on  sil_po.nKey = po.nKey
    where  1=1
    and    po.szOrderNumber = @szOrderNumber
           -- nur auf gueltige Auftraege schauen
    and    sil_po.nStatus between 2 and 16
    and    @tNow between sil_po.tValidFrom and sil_po.tValidTill

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'-------------------------------------------'
  print N'Daten zum Auftrag:'
  print N'  @szOrderIntLink    = ' + dbo.fn_SysDebugPrint(@szOrderIntLink)
  print N'  @nPlantLink        = ' + dbo.fn_SysDebugPrint(@nPlantLink)
  print N'  @nPlanOrderLink    = ' + dbo.fn_SysDebugPrint(@nPlanOrderLink)
  print N'  @szMHDHB           = ' + dbo.fn_SysDebugPrint(@szMHDHB)
end
/*DEBUG_Ausgabe ENDE*/

    if isnull(@szOrderIntLink, N'') = N'' begin
      print  N'-------------------------------------------'
      print  N'Auftrag/OrderIntLink im MES nicht bekannt'
      select @nError = 2
           , @szError = N'Auftrag/OrderIntLink im MES nicht bekannt'
      goto sp_error
    end  -- [if isnull(@szOrderIntLink, N'') = N'' begin]

    -- --------------------------------------------------
    -- Umrechnung Gesamthaltbarkeit in Tagen "szMHDHB" zu Datum "szMHD" YYYYMMTT
    -- --------------------------------------------------
    declare @tMHD    int
          , @szMHD   nvarchar(200) = N''
    select @tMHD  = @tNow + convert(int, @szMHDHB) * 24*60*60
    select @szMHD = convert(nvarchar(200), dbTraceIt.dbo.fn_SysGmt2LocalDatetime(@tMHD), 112)

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'-------------------------------------------'
  print N'  @tMHD  = ' + dbo.fn_SysDebugPrint(@tMHD)
  print N'  @szMHD = ' + dbo.fn_SysDebugPrint(@szMHD)
end
/*DEBUG_Ausgabe ENDE*/

    -- --------------------------------------------------
    -- Plausibilitaets Pruefung Material <> Auftrag
    --   Material muss Produktmaterial des Auftrags sein
    --   ODER als Kuppelprodukt in StüLi des Auftrags enthalten sein
    -- --------------------------------------------------
    if not exists (select 1
                   from   dbTraceIt..tblTdPlanOrder po
                   where  1=1
                   and    po.nKey          = @nPlanOrderLink
                   and    po.nMaterialLink = @nMaterialLink
                  ) begin
  
      print  N'-------------------------------------------'
      print  N'Material: ist nicht das Produktmaterial des Auftrags'

      if not exists(select 1
                    from   dbTraceIt..tblTdPlanOrder         po
                           join dbTraceIt..tblMdBOMComponent bomC  on  bomC.nBOMHeaderLink = po.nBOMHeaderLink
                    where  1=1
                    and    po.nKey            = @nPlanOrderLink
                    and    bomC.nMaterialLink = @nMaterialLink
                    and    bomC.bIsByProduct  = 1
                    ) begin
      
            print  N'-------------------------------------------'
            print  N'Material ist weder Produktmaterial, noch in StüLi des Auftrags als Kuppelprodukt enthalten'
            select @nError = 4
                 , @szError = N'Material ist weder Produktmaterial, noch in StüLi des Auftrags als Kuppelprodukt enthalten'
            goto sp_error
  
      end else begin  -- [if not exists(select 1...bomC.Mat]
        print  N'          ...aber als Kuppelprodukt in der StüLi enthalten'
        select @bIsByProduct = 1
      end  -- [if not exists(select 1...bomC.Mat]

    end  -- [if not exists(select 1...po.Mat]

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  @bIsByProduct      = ' + dbo.fn_SysDebugPrint(@bIsByProduct)
end
/*DEBUG_Ausgabe ENDE*/

    -- --------------------------------------------------
    -- Plausibilitaets Pruefung Zielsilo
    -- --------------------------------------------------
    select @nTargetRLPLink = rlp.nKey 
    from   dbTraceIt..tblMdRessourceLinePlant  rlp
           join dbTraceIt..tblSysIntLink       sil_rlp  on  sil_rlp.nKey = rlp.nKey
    where  1=1
    and    sil_rlp.szIntLink  = @szZielsilo
           -- nur auf gueltige Teilanlagen schauen
    and    sil_rlp.nStatus between 2 and 16
    and    @tNow between sil_rlp.tValidFrom and sil_rlp.tValidTill

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'-------------------------------------------'
  print N'Daten zum Zielsilo:'
  print N'  @nTargetRLPLink = ' + dbo.fn_SysDebugPrint(@nTargetRLPLink)
end
/*DEBUG_Ausgabe ENDE*/
  
    if isnull(@nTargetRLPLink, 0) = 0 begin
      print  N'-------------------------------------------'
      print  N'Zielsilo/nTargetRLPLink im MES nicht bekannt.'
      select @nError = 5
           , @szError = N'Zielsilo/nTargetRLPLink im MES nicht bekannt.'
      goto sp_error
    end  -- [if isnull(@nTargetRLPLink, 0) = 0 begin]

    -- -------------------------------------------------- 
    -- Buchungsgrund ermitteln
    -- -------------------------------------------------- 
    select @nReasonLink = dbTraceIt.dbo.fn_SysObjectGetValidKey(@szReasonIntLink, @tNow, N'REASON')
    select @szReasonIntLink = case when isnull(@nReasonLink, 0) = 0 then null else @szReasonIntLink end

    ---------------------------------------------------------------------
    -- Es wird eine Charge (Quant) fuer den Auftrag im Zielsilo gesucht
    -- falls noch nicht vorhanden wird diese erstellt
    ---------------------------------------------------------------------
    -- Schritt #1: die erste Batchnummer ist am Auftrag gespeichert
    --  Ach was - was hier gespeichert ist, interessiert nicht.
    --         Relevant sind die für das Material und diesen Auftrag bisher produzierten Quants
    -- Schritt #2: Falls der Auftrag über mehrere Tage läuft, kann es mehrere Batchnummern geben -> aus produzierten Quants die neueste auslesen
    -- ----------------------------------------------------------------------
    select top 1
           @nTargetQuantLink = smt.nKey
    from   dbTraceIt..tblTsMaterialTracking smt with (nolock)
    where  1=1
    and    smt.nMaterialLink           = @nMaterialLink
    and    smt.nPlanOrderLink          = @nPlanOrderLink
    and    smt.nRessourceLinePlantLink = @nTargetRLPLink
    and    smt.szQuantID               = @szBatchNumber
    order by smt.szQuantID desc

    -- falls nichts gefunden wurde, immerhin mit Leerstring initialisieren
    select @szTargetQuantLink = dbTraceIt.dbo.fn_SysObjectGetTechname(@nTargetQuantLink)

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  -- Quant -------------------------------'
  print N'  @szTargetQuantLink = ' + dbo.fn_SysDebugPrint(@szTargetQuantLink)
  print N'  @nTargetQuantLink  = ' + dbo.fn_SysDebugPrint(@nTargetQuantLink)
end
/*DEBUG_Ausgabe ENDE*/

    -- Muss im MES eine neue Charge in der Teilanlage generiert werden?
    select @bGenerateNewBatchnumberMES = case when (isnull(@nTargetQuantLink, 0) = 0) or (@bBatchnumberNew = 1)
                                             then 1
                                             else 0
                                         end

    -- Muss eine neue Charge im SAP angelegt werden? (dort gibt es keine Teilanlagen, deshalb kumuliert)
    select @bGenerateNewBatchnumberSAP = 0
    if not exists(select smt.nKey
                  from   dbTraceIt..tblTsMaterialTracking smt with (nolock)
                  where  1=1
                  and    smt.szQuantID = @szBatchNumber
                 ) begin
      select @bGenerateNewBatchnumberSAP = 1
    end  -- [if not exists(select smt.nKey...]

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  @bGenerateNewBatchnumberMES = ' + dbo.fn_SysDebugPrint(@bGenerateNewBatchnumberMES)
  print N'  @bGenerateNewBatchnumberSAP = ' + dbo.fn_SysDebugPrint(@bGenerateNewBatchnumberSAP)
end
/*DEBUG_Ausgabe ENDE*/

    -- ##################################################################
    -- START TRANSAKTIONS-BLOCK (Errorhandling -> sp_error)
    -- ##################################################################
    if @bUseTransaction = 1 begin transaction

    -- ------------------------------------------------------------------
    -- Wenn es diese Charge (den Quant) noch nicht im Ziellager gibt,
    --  dann anlegen und mit Menge bebuchen
    -- ------------------------------------------------------------------
    if @bGenerateNewBatchnumberMES = 1 begin

      -- Neu zu erstellenden Quant für spätere Zubuchung merken
      select @szTargetQuantLink = dbTraceIt.dbo.fn_SysTechnameTruncate(@szBatchNumber + N'.' + @szOrderIntLink + N'.' + convert(nvarchar, @tNow) + N'.' + convert(nvarchar(200), newid()), 200)

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  -- Neuer Quant -------------------------------'
  print N'  @szTargetQuantLink = ' + dbo.fn_SysDebugPrint(@szTargetQuantLink)
end
/*DEBUG_Ausgabe ENDE*/

      -- -------------------------------------------------- 
      -- Wareineingang im MES erzeugen
      -- -------------------------------------------------- 
      insert dbTraceInt..tblIfJob1 ( 
             szTransactionLink  -- Auszufuehrene Transaktion (ACHTUNG: char(8)!!) 
           , tCreated           -- Zeitstempel Erstellung des Jobs 
           , nCode              -- Datentechnischer Status des Datensatzes 
           , tJob               -- Fuer diesen Zeitpunkt ist der Job gedacht ("order by"-Kriterium fuer Verbucher) 
           , szSourceSystem     -- Quelle: das System, das den Job beauftragt hat  
           , szUser             -- Name des Benutzer der den Job ausfuehren lassen will 
           , szSourceLink       -- optionale zusaetzliche Informationen (HIER hat die Info zu stehen)
           , szInfo             -- optionale zusaetzliche Informationen 
           , szURL              -- optionale zusaetzliche Informationen 
  
           , szParam00          -- Kurzname 
           , szParam01          -- QuantID 
           , szParam02          -- Startzeit 
           , szParam03          -- Teilanlage 
           , szParam04          -- Material 
           , szParam05          -- zugeordnete Buchung
           , szParam51          -- Tageschargennummer
           , szParam52          -- MHD
           , szParam59          -- Auftrag fuer Quant
           ) 
      select N'[Tx2100]'
           , @tNow                   -- TiT-konv. Zeitstempel 
           , 1                       -- zu bearbeiten 
           , @tJob                   -- TiT-konv. Zeitstempel 
           , @szSourceSystem         -- Konstante
           , @szUser                 -- Konstante 
           , @szInfo                 -- (nicht verwendet) 
           , @szInfo                 -- (nicht verwendet) 
           , @szURL                  -- (nicht verwendet) 
           -- Kurzname 
           , @szTargetQuantLink
           -- QuantID           
           , @szBatchNumber
           -- Startzeit           
           , convert(nvarchar, @tJob)
           -- Teilanlage         
           , @szZielsilo
           -- Material           
           , @szMaterialNumber
           -- zugeordnete Buchung
           , @szOrderIntLink
           -- Tageschargennummer
           , @szBatchNumber
           -- MHD
           , convert(nvarchar, @tMHD)
           -- Auftragsnummer
           , @szOrderIntLink

      -- Errorhandling
      select @nError = @@error
      if isnull(@nError, 0) <> 0 begin
        select @szError = N'Fehler beim Insert in die Tabelle dbTraceInt..tblIfJob1 [Tx2100]'
        goto sp_error
      end  -- [if isnull(@nError, 0) <> 0 begin]
      
      -- -------------------------------------------------- 
      -- Quant freigeben (Wird von der vorherigen Tx2100 gesperrt erzeugt)
      -- -------------------------------------------------- 
      -- tJob erhöhen
      select @tJob = @tJob +1
      
      insert dbTraceInt..tblIfJob1 ( 
             szTransactionLink  -- Auszufuehrene Transaktion (ACHTUNG: char(8)!!) 
           , tCreated           -- Zeitstempel Erstellung des Jobs 
           , nCode              -- Datentechnischer Status des Datensatzes 
           , tJob               -- Fuer diesen Zeitpunkt ist der Job gedacht ("order by"-Kriterium fuer Verbucher) 
           , szSourceSystem     -- Quelle: das System, das den Job beauftragt hat  
           , szUser             -- Name des Benutzer der den Job ausfuehren lassen will 
           , szSourceLink       -- optionale zusaetzliche Informationen (HIER hat die Info zu stehen)
           , szInfo             -- optionale zusaetzliche Informationen 
           , szURL              -- optionale zusaetzliche Informationen
       
           , szParam00          -- Kurzname
           , szParam01          -- Zeitstempel
           , szParam02          -- QuantID
           ) 
      select N'[Tx2140]'
           , @tNow                   -- TiT-konv. Zeitstempel 
           , 1                       -- zu bearbeiten 
           , @tJob                   -- TiT-konv. Zeitstempel 
           , @szSourceSystem         -- Konstante
           , @szUser                 -- Konstante 
           , @szInfo                 -- (nicht verwendet) 
           , @szInfo                 -- (nicht verwendet)
           , @szURL                  -- (nicht verwendet) 
           
           -- Kurzname 
           , N'UNLOCK->' + @szTargetQuantLink
           -- Zeitstempel           
           , @tJob
           -- QuantID           
           , @szTargetQuantLink
           
      -- Errorhandling
      select @nError = @@error
      if isnull(@nError, 0) <> 0 begin
        select @szError = N'Fehler beim Insert in die Tabelle dbTraceInt..tblIfJob1 [Tx2140]'
        goto sp_error
      end  -- [if isnull(@nError, 0) <> 0 begin]

      -- -------------------------------------------------- 
      -- Charge im SAP erzeugen
      -- -------------------------------------------------- 
      if     (isnull(@ZnXCHPF, 0) = 1)
         and (@bSAP_Booking = 1) 
         and (@bGenerateNewBatchnumberSAP = 1) 
      begin

        select @szSAPMaterialNumber = case when @bIsByProduct = 1 then @szMaterialNumber else N'' end
        exec dbTraceInt..Zsp_MEG_MES2SAP_Batch_Production_FERT_Create 
             @nPlanOrderLink           = @nPlanOrderLink      -- Link auf den Prozessauftag 
           , @szQuantID                = @szBatchNumber       -- Chargennummer   
           , @szMHD                    = @szMHD               -- Mindesthaltbarkeitsdatum   
           , @szAlternativeMaterial	   = @szSAPMaterialNumber -- Alternativmaterial
           , @bDebug = @bDebug
           , @nError = @nError output, @szError = @szError output

        if isnull(@nError, 0) <> 0 begin
          select @szError = N'Zsp_MEG_MES2SAP_Batch_Production_FERT_Create: ' + @szError
          goto sp_error
        end  -- [if isnull(@nError, 0) <> 0 begin]

      end  -- [if (isnull(@ZnXCHPF, 0) = 1) and (@bSAP_Booking = 1) and (@bGenerateNewBatchnumberSAP = 1) begin]

    end  -- [if @bGenerateNewBatchnumberMES = 1 begin]

    -----------------------------------------------------------------------------------
    -- Zubuchung im MES auf ermittelten (oder neuen) Quant erzeugen (Zugang aus Produktion)
    -----------------------------------------------------------------------------------
    insert dbTraceInt..tblIfJob1 ( 
            szTransactionLink  -- Auszufuehrene Transaktion (ACHTUNG: char(8)!!) 
          , tCreated           -- Zeitstempel Erstellung des Jobs 
          , nCode              -- Datentechnischer Status des Datensatzes 
          , tJob               -- Fuer diesen Zeitpunkt ist der Job gedacht ("order by"-Kriterium fuer Verbucher) 
          , szSourceSystem     -- Quelle: das System, das den Job beauftragt hat  
          , szUser             -- Name des Benutzer der den Job ausfuehren lassen will 
          , szSourceLink       -- optionale zusaetzliche Informationen (HIER hat die Info zu stehen)
          , szInfo             -- optionale zusaetzliche Informationen 
          , szURL              -- optionale zusaetzliche Informationen 
  
          , szParam00          -- Version
          , szParam02          -- Stoppzeit
          , szParam03          -- gebuchte Menge
          , szParam08          -- Kurzname des Quants
          , szParam21          -- zugeordnete Buchung
          , szParam38          -- Grund
          ) 
    select N'[Tx2320]'
          , @tNow                   -- TiT-konv. Zeitstempel 
          , 1                       -- zu bearbeiten 
          , @tJob+1                 -- TiT-konv. Zeitstempel 
          , @szSourceSystem         -- Konstante
          , @szUser                 -- Konstante 
          , @szInfo                 -- (nicht verwendet) 
          , @szInfo                 -- (nicht verwendet) 
          , @szURL                  -- (nicht verwendet) 
          -- Version 
          , dbTraceIt.dbo.fn_SysTechnameTruncate(@szTargetQuantLink + N'.' + convert(nvarchar(200), newid()), 200)
          -- Stoppzeit
          , convert(nvarchar, @tJob+1)
          -- gebuchte Menge
          , convert(nvarchar, @rQuantity)
          -- Kurzname des Quants
          , @szTargetQuantLink
          -- zugeordnete Buchung
          , @szOrderIntLink
          -- Grund
          , @szReasonIntLink
    
    -- Errorhandling
    select @nError = @@error
    if isnull(@nError, 0) <> 0 begin
      select @szError = N'Fehler beim Insert in die Tabelle dbTraceInt..tblIfJob1 [Tx2320]'
      goto sp_error
    end  -- [if isnull(@nError, 0) <> 0 begin]

    -----------------------------------------------------------------------------------
    -- Wareneingang (=Zubuchung) in SAP ERP erzeugen
    -----------------------------------------------------------------------------------   
    if @bSAP_Booking = 1 begin

      -- Einheit ermitteln
      declare @szUNIT_OF_MEASURE nvarchar(200)
      select @szUNIT_OF_MEASURE = dbTraceIt.dbo.fn_SysObjectGetTechname(mat.nBaseUnitQuantityLink)
      from   dbTraceIt..tblMdMaterial  mat
      where  1=1
      and    mat.nKey = @nMaterialLink

      -- Chargennummer nur bei Chargenpflichtigen Materialien übergeben
      select @szBatchNumber = case when (isnull(@ZnXCHPF, 0) = 1) then @szBatchNumber
                                   else N''
                              end
      
      exec dbTraceInt..Zsp_MEG_MES2SAP_Process_Message_PI_PROD
           @szPROCESS_ORDER     = @szOrderNumber      -- Prozessauftragsnummer
         , @szMATERIAL          = @szMaterialNumber   -- Materialnummer
         , @szBATCH             = @szBatchNumber      -- Chargennummer
         , @nMATERIAL_PRODUCED  = @rQuantity          -- Produzierte Menge
         , @szUNIT_OF_MEASURE   = @szUNIT_OF_MEASURE  -- Einheit
         , @szSTORAGE_LOCATION  = @szSTORAGE_LOCATION -- Lagerort
         , @szWERK              = @szWERK             -- Werk
         , @szSTOCK_TYPE        = N''                 -- Bestandsqualifikation '' für  Frei, X für Qualitaet, S für Gesperrt
         , @nTID                = 0                   -- Daten sollen sofort an SAP versendet werden
         , @bDebug = @bDebug
         , @nError = @nError output, @szError = @szError output

      if isnull(@nError, 0) <> 0 begin
        select @szError = N'Zsp_MEG_MES2SAP_Process_Message_PI_PROD: ' + @szError
        goto sp_error
      end  -- [if isnull(@nError, 0) <> 0 begin]

    end  -- [if @bSAP_Booking = 1 begin]

    if @bUseTransaction = 1 begin
 
/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  ----------------------------------'
  print N'[!] Die Datenbankaktionen werden durchgefuehrt [commit transaction]'
end
/*DEBUG_Ausgabe ENDE*/

      commit transaction

    end  -- [if @bUseTransaction = 1 begin]
    -- ##################################################################
    -- ENDE TRANSAKTIONS-BLOCK (Errorhandling -> sp_error)
    -- ##################################################################

    -- ------------------------------------------------------------------
    -- Ende der Prozeduraufgabe -> Alles OK
    -- ------------------------------------------------------------------
    select @nError  = 0
         , @szError = N'Erfolgreich abgeschlossen'--@szERRORTEXT_Success

  end try
  begin catch

    select @nError  = -1
         , @szError = @szModule + N': SQL-Fehler: '
                                + N'ErrNr=' + dbo.fn_SysDebugPrint(ERROR_NUMBER())
                                + N'; ErrSev=' + dbo.fn_SysDebugPrint(ERROR_SEVERITY())
                                + N'; ErrState=' + dbo.fn_SysDebugPrint(ERROR_STATE())
                                + N'; ErrProc=' + dbo.fn_SysDebugPrint(ERROR_PROCEDURE())
                                + N'; ErrLine=' + dbo.fn_SysDebugPrint(ERROR_LINE())
                                + N'; ErrMsg=' + dbo.fn_SysDebugPrint(ERROR_MESSAGE())
    print N'--CAUGHT--------------------------------'
    print N'[!] error_message() = ' + isnull(error_message(), N'(n.v.)')
  end catch

  -- --------------------------------------------------
  -- Ergebnis der Prozedur
  -- --------------------------------------------------
  if @nError <> 0
    goto sp_error

  -- ==================================================================
  -- Standardabschluss
  -- ==================================================================
  sp_exit:

    -- Fehler in Protokolltabelle speichern
    if @nError <> 0 begin
      -- Vorher prüfen ob der Plausibilitaetsbericht installiert wurde
         if exists (select 1 from dbTraceIt.sys.objects where name = N'ZtblReportFailedBookingProtocol')
         begin
           insert dbTraceIt..ZtblReportFailedBookingProtocol (tCreated, szModule, szInfo, szError, nError)
           values(@tNow,@szModule,@szPlausiInfo,@szError,@nError)
         end
    end  -- [if @nError <> 0 begin]

    --Plausibilitätsprotokoll im Fehlerfall füllen
    if @nError <> 0 
      begin
         insert dbTraceIt..ZtblReportFailedBookingProtocol (tCreated, szModule, szInfo, szError, nError)
         values(@tNow,@szModule,@szPlausiInfo,@szError,@nError)
    end
      
    -- Resultset bilden
    if @bNoResultset = 0 begin
      select [nError]  = isnull(@nError, 0)
           , [szError] = @szError
    end

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N''
  print N'Laufzeit ' + @szModule + N': ' + dbo.fn_SysDebugPrint(datediff(ms, @dtStartZeit, getdate())) + N' ms'
  print N'  @nError  = ' + dbo.fn_SysDebugPrint(@nError)
  print N'  @szError = ' + dbo.fn_SysDebugPrint(@szError)
  print N'ENDE ' + @szModule + N': ' + dbo.fn_SysDebugPrint_DateTime(getdate(), default)
  print N'==========================================='
end
/*DEBUG_Ausgabe ENDE*/

    return

  sp_error:

    -- Meine Transaktion zuruecknehmen
    if @bUseTransaction = 1 begin

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  ----------------------------------'
  print N'[!] Die Datenbankaktionen werden aufgrund eines Fehlers zurueckgenommen [rollback transaction]'
end
/*DEBUG_Ausgabe ENDE*/

      while (@@trancount > 0)
        rollback transaction  

    end  -- [if @bUseTransaction = 1 begin]

/*DEBUG_Ausgabe START*/
if not @bDebug = 0 begin
  print N'  ----------------------------------'
  print N'  [XXX] Fertig mit Fehler'
end
/*DEBUG_Ausgabe ENDE*/

    goto sp_exit

end
go

