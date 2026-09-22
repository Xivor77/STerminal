# STerminal - test suite (senza Pester). Logica pura + percorsi/titoli edge-case.
# Esegui:  powershell.exe -NoProfile -File "C:\projects\STerminal\tests\STerminal.Tests.ps1"
# ASCII puro; apostrofo/accento sono costruiti via [char] per non sporcare il file.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'STerminal.psm1') -Force

$script:pass = $true
$script:eseguite = 0; $script:passate = 0; $script:fallite = 0
# La forma e' copiata da PROVA-lettura-nome-2026-09-01.ps1: il try sta DENTRO la singola
# prova -- la condizione arriva come scriptblock e si valuta li' dentro -- cosi' un'eccezione
# manda KO QUELLA prova e lascia proseguire le altre. Prima il try era uno solo, attorno a
# tutto il corpo, e la prima eccezione portava via il resto del banco; e se nasceva dentro
# l'argomento di una Check, quella prova non risultava nemmeno fallita: non risultava affatto.
function Check([string]$nome, [scriptblock]$blocco) {
    $script:eseguite++
    try {
        $r = & $blocco
        if ($r) { $script:passate++; "  [OK]   $nome" }
        else    { $script:pass = $false; $script:fallite++; "  [FAIL] $nome" }
    } catch {
        $script:pass = $false; $script:fallite++
        "  [FAIL] $nome   -> ECCEZIONE: $($_.Exception.Message)"
    }
}
function Section($t) { "`n=== $t ===" }

$star   = [char]42
$apos   = [char]39       # '
$egrave = [char]0x00E8   # e accentata

# root temporanea isolata (iniettata nello scope del modulo)
$root  = Join-Path $env:TEMP ('st_test_' + [guid]::NewGuid().ToString('n').Substring(0,8))
$wsDir = Join-Path $root 'workspaces'
& (Get-Module STerminal) { param($r,$w) $script:STRoot=$r; $script:STWorkspaces=$w } $root $wsDir

# L'ISOLAMENTO SI VERIFICA, NON SI SPERA. Se `Get-Module STerminal` non trova il modulo
# (per esempio perche' e' stato importato sotto un altro nome, come capita provando un
# mutante), l'iniezione qui sopra fallisce IN SILENZIO e il modulo continua a puntare a
# $HOME\.sterminal: il banco scrive allora nelle aree VERE. E' successo il 13/08 alle
# 20:41 -- la suite ha creato un'area 'rt' fra quelle di Vittorio, con 13 tab e i loro
# storici. Il sintomo che avevo visto (un mutante che "non partiva") era questo, e l'ho
# letto come un guasto del mutante invece di chiedermi DOVE stesse scrivendo.
$visto = & (Get-Module STerminal) { $script:STWorkspaces }
if ($visto -ne $wsDir) {
    throw "isolamento del banco FALLITO: il modulo punta a '$visto' invece che a '$wsDir'. Non eseguo: scriverei nelle aree vere."
}
$delim = [string]$star * 22

# Il banco conta da se' le proprie prove, cosi' la riga finale puo' dichiarare la copertura
# invece di stampare la stessa riga per "2 su 95" e per "95 su 95". Criterio (lo stesso del
# conto del 18/09): una prova = una chiamata a Check; la definizione non combacia il pattern.
# Le tre dentro il foreach dei casi (le uniche con "$c.n" nel nome) valgono una PER CASO:
# la moltiplicazione sta nella riga finale, dove $cases esiste.
$script:siti = @(Select-String -LiteralPath $PSCommandPath -Pattern '^\s*Check "').Count
$script:nelCiclo = @(Select-String -LiteralPath $PSCommandPath -Pattern '^\s*Check "\[\$\(\$c\.n\)\]').Count

try {
    Section "Get-STScrollbackBody"
    $tf = Join-Path $root 'tr.log'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    @($delim,'PowerShell transcript start','Start time: x',$delim,'riga uno','riga due',$delim,'PowerShell transcript end',$delim) -join [Environment]::NewLine | Set-Content -LiteralPath $tf -Encoding utf8
    $body = Get-STScrollbackBody -Path $tf
    Check "estrae il corpo"        { ($body -match 'riga uno' -and $body -match 'riga due') }
    Check "scarta header/footer"   { (-not ($body -match 'transcript')) }

    Section "Save-STWorkspace round-trip (path con spazi)"
    $cwdSpazi = Join-Path $root 'cartella con spazi'
    New-Item -ItemType Directory -Force -Path $cwdSpazi | Out-Null
    $slotDir = Join-Path $root 'slot1'; New-Item -ItemType Directory -Force -Path $slotDir | Out-Null
    ([pscustomobject]@{ Slot='slot1'; Title='uno'; Color='#112233'; Cwd=$cwdSpazi; Shell='powershell.exe'; Pid=$PID; Created=(Get-Date).ToString('o'); Heartbeat=(Get-Date).ToString('o'); Closed=$false } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $slotDir 'meta.json') -Encoding utf8
    @($delim,'PowerShell transcript start',$delim,'contenuto uno',$delim,'PowerShell transcript end',$delim) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $slotDir 'scrollback.log') -Encoding utf8
    Save-STWorkspace -Name 'rt' | Out-Null
    $ws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'rt') 'workspace.json') -Raw | ConvertFrom-Json
    Check "cwd con spazi preservata" { ($ws.Tabs[0].Cwd -eq $cwdSpazi) }
    Check "storico salvato"          { (Test-Path -LiteralPath (Join-Path (Join-Path $wsDir 'rt') 'tab-0.log')) }

    Section "Get-STResumeTabSpec - percorsi e titoli diversi"
    $dirs = [ordered]@{
        normale   = Join-Path $root 'normale'
        spazi     = Join-Path $root 'con spazi'
        apostrofo = Join-Path $root ('con' + $apos + 'apostrofo')
        accenti   = Join-Path $root ('caff' + $egrave)
    }
    foreach ($d in $dirs.Values) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $nonEsiste = Join-Path $root 'mai-esistito'

    $cases = @(
        @{ n='normale';     Cwd=$dirs.normale;   Title='normale' }
        @{ n='spazi';       Cwd=$dirs.spazi;     Title='con spazi' }
        @{ n='apostrofo';   Cwd=$dirs.apostrofo; Title=('it'+$apos+'s') }
        @{ n='accenti';     Cwd=$dirs.accenti;   Title=('caff'+$egrave) }
        @{ n='inesistente'; Cwd=$nonEsiste;      Title='ghost' }
    )
    foreach ($c in $cases) {
        $tab = [pscustomobject]@{ Title=$c.Title; Color='#1FAA55'; Cwd=$c.Cwd; Shell='powershell.exe'; Storico=$null }
        $spec = Get-STResumeTabSpec -Tab $tab -WorkspaceDir $root
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($spec.DecodedCommand, [ref]$null, [ref]$e)
        Check "[$($c.n)] comando valido (niente quote-break)"          { (@($e).Count -eq 0) }
        $expect = Test-Path -LiteralPath $c.Cwd
        Check "[$($c.n)] -d presente solo se la cartella esiste"        { ($spec.HasCwd -eq $expect) }
        $ti = [array]::IndexOf($spec.WtArgs, '--title')
        Check "[$($c.n)] titolo preservato esatto negli args wt"        { ($ti -ge 0 -and $spec.WtArgs[$ti+1] -eq $c.Title) }
    }

    Section "apostrofo NEL path dello storico (finisce nel comando)"
    $tabS = [pscustomobject]@{ Title='s'; Color=$null; Cwd=$dirs.normale; Shell='powershell.exe'; Storico='tab-0.log' }
    $specS = Get-STResumeTabSpec -Tab $tabS -WorkspaceDir $dirs.apostrofo
    $e2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($specS.DecodedCommand, [ref]$null, [ref]$e2)
    Check "comando valido con apostrofo nel path" { (@($e2).Count -eq 0) }
    Check "path storico presente nel comando"     { ($specS.DecodedCommand -match 'tab-0\.log') }

    Section "EncodedCommand decodifica round-trip"
    $dec = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($specS.EncodedCommand))
    Check "base64 -> comando originale identico" { ($dec -eq $specS.DecodedCommand) }

    Section "New-STWorkspace + comando per tab"
    New-STWorkspace -Name 'sys' -Tabs @(
        @{ Title='ORKAI'; Cwd=$dirs.normale; Command='& .\start.bat' }
        @{ Title='Chat';  Cwd=$dirs.spazi;   Command=('claude --resume ' + $apos + 'abc' + $apos) }
    ) | Out-Null
    $sys = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'sys') 'workspace.json') -Raw | ConvertFrom-Json
    Check "New-STWorkspace: 2 tab"               { ($sys.Tabs.Count -eq 2) }
    Check "comando per tab preservato"           { ($sys.Tabs[0].Command -eq '& .\start.bat') }
    $specC = Get-STResumeTabSpec -Tab $sys.Tabs[1] -WorkspaceDir (Join-Path $wsDir 'sys')
    $e3 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($specC.DecodedCommand, [ref]$null, [ref]$e3)
    Check "comando con apostrofo -> Open valido"  { (@($e3).Count -eq 0) }
    Check "comando finisce nel comando di Open"   { ($specC.DecodedCommand -match 'claude --resume') }

    Section "Get-STResumeArgs - UNA invocazione wt (niente finestre multiple)"
    $argv = Get-STResumeArgs -Tabs $sys.Tabs -WorkspaceDir (Join-Path $wsDir 'sys')
    $nt   = @($argv | Where-Object { $_ -eq 'new-tab' }).Count
    $semi = @($argv | Where-Object { $_ -eq ';' }).Count
    Check "un 'new-tab' per tab (2)"   { ($nt -eq 2) }
    Check "';' separatori = tab-1 (1)" { ($semi -eq 1) }
    Check "niente -w (finestra unica)" { (-not ($argv -contains '-w')) }

    Section "Save-STWorkspace -Group (filtra per etichetta)"
    foreach ($g in @(@{s='slotA'; t='gruppoA-tab'; grp='A'}, @{s='slotB'; t='gruppoB-tab'; grp='B'})) {
        $sd = Join-Path $root $g.s; New-Item -ItemType Directory -Force -Path $sd | Out-Null
        ([pscustomobject]@{ Slot=$g.s; Title=$g.t; Color=$null; Command=$null; Group=$g.grp; Cwd=$env:TEMP; Shell='powershell.exe'; Pid=$PID; Created=(Get-Date).ToString('o'); Heartbeat=(Get-Date).ToString('o'); Closed=$false } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $sd 'meta.json') -Encoding utf8
    }
    Save-STWorkspace -Name 'soloA' -Group 'A' | Out-Null
    $wa = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'soloA') 'workspace.json') -Raw | ConvertFrom-Json
    Check "Group A: catturato 1 solo tab"  { (@($wa.Tabs).Count -eq 1) }
    Check "Group A: e' il tab giusto"      { ($wa.Tabs[0].Title -eq 'gruppoA-tab') }

    Section "ConvertTo-STRunnable + Add-STWorkspaceTab"
    Check "exe quotato -> & 'exe' args"  { ((ConvertTo-STRunnable '"C:\py.exe" -m uvicorn') -eq "& 'C:\py.exe' -m uvicorn") }
    Check "exe senza virgolette"         { ((ConvertTo-STRunnable 'caddy.exe run') -eq "& 'caddy.exe' run") }
    # NB: prima questa sezione pretendeva l'ACCODAMENTO ('c' aveva la stessa ricetta di
    # 'b' -- stessa cwd, nessun comando -- e il test chiedeva totale 3). Con il dedup
    # quella prova diventa rossa, ed e' giusto cosi': consacrava il difetto.
    $r1 = Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='a'; Cwd=$root; Command='& .\x'}, @{Title='b'; Cwd=$root})
    Check "prima aggiunta: 2 tab"            { ($r1.Added -eq 2 -and $r1.Total -eq 2) }
    $r2 = Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='c'; Cwd=$root})
    Check "ricetta gia' presente: saltata"   { ($r2.Added -eq 0 -and $r2.SkippedRecipe -eq 1) }
    $addws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'addws') 'workspace.json') -Raw | ConvertFrom-Json
    Check "l'area resta di 2 tab"            { (@($addws.Tabs).Count -eq 2) }
    Check "e 'c' non c'e'"                   { (-not (@($addws.Tabs | Where-Object { $_.Title -eq 'c' }))) }

    $r3 = Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='c'; Cwd=$root}) -AllowDuplicate
    Check "-AllowDuplicate: il gemello entra" { ($r3.Added -eq 1 -and $r3.Total -eq 3) }

    Section "Add-STWorkspaceTab: doppioni DENTRO lo stesso lotto"
    $r4 = Add-STWorkspaceTab -Name 'lotto' -Tabs @(
        @{Title='x'; Cwd=$root; Command='& .\y'},
        @{Title='x-bis'; Cwd=$root; Command='& .\y'})
    Check "due voci uguali nello stesso lotto: una sola entra" { ($r4.Added -eq 1 -and $r4.SkippedRecipe -eq 1) }

    # Questa prova nasce da un mutante SOPRAVVISSUTO: rendendo il confronto delle firme
    # insensibile alle maiuscole, tutto restava verde -- perche' le sonde qui sotto
    # provano Get-STTabSignature in isolamento, non il confronto DENTRO l'aggiunta.
    # Due proprieta' diverse vogliono due prove diverse.
    $r5 = Add-STWorkspaceTab -Name 'caso' -Tabs @(
        @{Title='su';  Cwd=$root; Command='& .\x -Flag'},
        @{Title='giu'; Cwd=$root; Command='& .\x -flag'})
    Check "comandi diversi solo per maiuscole: entrano entrambi" { ($r5.Added -eq 2 -and $r5.SkippedRecipe -eq 0) }

    Section "Get-STTabSignature (la ricetta, non l'identita')"
    $cwdMaiusc = $root.ToUpperInvariant() + '\'
    Check "cwd: maiuscole e barra finale non contano" { (
        (Get-STTabSignature @{Cwd=$root}) -ceq (Get-STTabSignature @{Cwd=$cwdMaiusc})) }
    Check "cwd: le barre / e \ sono lo stesso percorso" { (
        (Get-STTabSignature @{Cwd='C:\a\b'}) -ceq (Get-STTabSignature @{Cwd='C:/a/b'})) }
    # C:\ e C: NON sono lo stesso posto (il secondo e' "la cartella corrente sul drive C"),
    # quindi la barra della radice non va tolta. Confrontare C:\ con se stesso non
    # proverebbe niente: passerebbe anche cancellando tutta la normalizzazione.
    Check "cwd: la radice del drive tiene la sua barra" { (
        (Get-STTabSignature @{Cwd='C:\'}) -cne (Get-STTabSignature @{Cwd='C:'})) }
    Check "comando: null e stringa vuota sono la stessa cosa" { (
        (Get-STTabSignature @{Cwd=$root; Command=$null}) -ceq (Get-STTabSignature @{Cwd=$root; Command='  '})) }
    Check "comando: le MAIUSCOLE contano (argomenti sensibili)" { (
        (Get-STTabSignature @{Cwd=$root; Command='& .\x -Flag'}) -cne (Get-STTabSignature @{Cwd=$root; Command='& .\x -flag'})) }
    Check "shell diversa = ricetta diversa" { (
        (Get-STTabSignature @{Cwd=$root; Shell='powershell.exe'}) -cne (Get-STTabSignature @{Cwd=$root; Shell='pwsh.exe'})) }
    Check "shell: stesso nome, percorsi diversi NON si equiparano" { (
        (Get-STTabSignature @{Cwd=$root; Shell='C:\a\pwsh.exe'}) -cne (Get-STTabSignature @{Cwd=$root; Shell='C:\b\pwsh.exe'})) }
    Check "shell assente = powershell.exe" { (
        (Get-STTabSignature @{Cwd=$root}) -ceq (Get-STTabSignature @{Cwd=$root; Shell='PowerShell.exe'})) }

    Section "Get-STTabSignature: canonicalizzazione sintattica della cwd"
    Check "'..' si collassa"                { (
        (Get-STTabSignature @{Cwd='C:\a\..\b'}) -ceq (Get-STTabSignature @{Cwd='C:\b'})) }
    Check "'.' sparisce"                    { (
        (Get-STTabSignature @{Cwd='C:\a\.\b'}) -ceq (Get-STTabSignature @{Cwd='C:\a\b'})) }
    Check "'..' multipli"                   { (
        (Get-STTabSignature @{Cwd='C:\a\b\c\..\..\d'}) -ceq (Get-STTabSignature @{Cwd='C:\a\d'})) }
    Check "non si sale sopra la radice"     { (
        (Get-STTabSignature @{Cwd='C:\..\..'}) -ceq (Get-STTabSignature @{Cwd='C:\'})) }
    Check "UNC: il prefisso resta intero"   { (
        (Get-STTabSignature @{Cwd='\\srv\share\a\..\b'}) -ceq (Get-STTabSignature @{Cwd='\\srv\share\b'})) }
    Check "UNC non collassa nel prefisso"   { (
        (Get-STTabSignature @{Cwd='\\srv\share\..\..'}) -ceq (Get-STTabSignature @{Cwd='\\srv\share'})) }
    Check "doppie barre interne ignorate"   { (
        (Get-STTabSignature @{Cwd='C:\a\\b'}) -ceq (Get-STTabSignature @{Cwd='C:\a\b'})) }
    # Un percorso relativo non si finge assoluto: non sappiamo rispetto a cosa.
    Check "relativo: resta relativo, ma pulito" { (
        (Get-STTabSignature @{Cwd='a\..\b'}) -ceq (Get-STTabSignature @{Cwd='b'})) }
    Check "relativo e assoluto NON si confondono" { (
        (Get-STTabSignature @{Cwd='b'}) -cne (Get-STTabSignature @{Cwd='C:\b'})) }

    Section "la shell del tab vivo arriva fino alla firma (end-to-end)"
    # Il difetto era qui: Get-STLiveTab distingueva pwsh da powershell e poi la shell
    # si perdeva, quindi tutto diventava powershell.exe. Riproduco la proiezione che fa
    # la UI, nelle DUE modalita' del dialogo.
    $vivo = [pscustomobject]@{ Pid=1; Cwd='C:\x'; Command='& tool'; What='pwsh'; Shell='pwsh.exe'; Label='x - pwsh [1]' }
    $proiAuto = @{ Title = $vivo.What; Cwd = $vivo.Cwd; Command = $vivo.Command; Shell = $vivo.Shell }
    $proiMan  = @{ Title = 'a mano'; Color = '#1FAA55'; Cwd = $vivo.Cwd; Command = $vivo.Command; Shell = $vivo.Shell }
    Check "modo automatico: la shell sopravvive" { (
        (Get-STTabSignature $proiAuto) -ceq (Get-STTabSignature @{Cwd='C:\x'; Command='& tool'; Shell='pwsh.exe'})) }
    Check "modo per-tab: la shell sopravvive"    { (
        (Get-STTabSignature $proiMan) -ceq (Get-STTabSignature $proiAuto)) }
    Check "pwsh e powershell NON collidono"      { (
        (Get-STTabSignature $proiAuto) -cne (Get-STTabSignature @{Cwd='C:\x'; Command='& tool'; Shell='powershell.exe'})) }
    $rp = Add-STWorkspaceTab -Name 'shells' -Tabs @(
        @{Title='ps';   Cwd='C:\x'; Command='& tool'; Shell='powershell.exe'},
        @{Title='pwsh'; Cwd='C:\x'; Command='& tool'; Shell='pwsh.exe'})
    Check "due shell diverse entrano entrambe"   { ($rp.Added -eq 2) }
    $rp2 = Add-STWorkspaceTab -Name 'shells' -Tabs @(@{Title='pwsh-bis'; Cwd='C:\x'; Command='& tool'; Shell='pwsh.exe'})
    Check "lo stesso pwsh non rientra"           { ($rp2.Added -eq 0 -and $rp2.SkippedRecipe -eq 1) }
    Check "Get-STLiveTab espone Shell" { (
        (@(Get-STLiveTab) | Where-Object { $_.PSObject.Properties.Name -contains 'Shell' }).Count -eq @(Get-STLiveTab).Count) }

    Section "Add-STWorkspaceTab -AutoColor (colori distinti per tab)"
    # Ricette distinte di proposito: qui si prova il COLORE, non il dedup.
    Add-STWorkspaceTab -Name 'colws' -Tabs @(
        @{Title='a'; Cwd=(Join-Path $root 'a')},
        @{Title='b'; Cwd=(Join-Path $root 'b')},
        @{Title='c'; Cwd=(Join-Path $root 'c')}) -AutoColor | Out-Null
    $colws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'colws') 'workspace.json') -Raw | ConvertFrom-Json
    $cols = @($colws.Tabs | ForEach-Object { $_.Color })
    Check "AutoColor: 3 colori assegnati"  { ((@($cols | Where-Object { $_ })).Count -eq 3) }
    Check "AutoColor: tutti distinti"      { ((@($cols | Select-Object -Unique)).Count -eq 3) }

    Section "colore dell'AREA (fase 2)"
    $c1 = Set-STWorkspaceColor -Name 'addws'
    $c2 = Set-STWorkspaceColor -Name 'colws'
    Check "un'area riceve un colore"        { ($c1 -match '^#[0-9A-Fa-f]{6}$') }
    Check "due aree, colori diversi"        { ($c1 -ne $c2) }
    $riletto = @(Get-STWorkspace | Where-Object { $_.Name -eq 'addws' })[0]
    Check "il colore si rilegge dal file"   { ($riletto.UiColor -eq $c1) }
    Check "i colori dei TAB non cambiano"   { (@($riletto.Tabs | Where-Object { $_.Color -eq $c1 }).Count -eq 0) }
    Set-STWorkspaceColor -Name 'addws' -Color '#123456' | Out-Null
    Check "colore imposto a mano"           { ((@(Get-STWorkspace | Where-Object { $_.Name -eq 'addws' })[0]).UiColor -eq '#123456') }
    # Il colore dell'area non deve sparire quando le si aggiungono altri tab.
    Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='nuovo'; Cwd=(Join-Path $root 'nuovo'); Command='& .\z'}) | Out-Null
    Check "aggiungere tab non perde il colore" { ((@(Get-STWorkspace | Where-Object { $_.Name -eq 'addws' })[0]).UiColor -eq '#123456') }
    Add-STWorkspaceTab -Name 'nata-ora' -Tabs @(@{Title='q'; Cwd=$root; Command='& .\q'}) | Out-Null
    $nata = @(Get-STWorkspace | Where-Object { $_.Name -eq 'nata-ora' })[0]
    Check "un'area nuova nasce colorata"    { ([bool]$nata.UiColor) }

    Section "appartenenza dei tab vivi (per RICETTA, non identita')"
    $aree = @(
        [pscustomobject]@{ Name='alfa'; UiColor='#111111'; Tabs=@([pscustomobject]@{ Cwd='C:\x'; Shell='pwsh.exe';       Command='& tool' }) },
        [pscustomobject]@{ Name='beta'; UiColor='#222222'; Tabs=@([pscustomobject]@{ Cwd='C:\y'; Shell='powershell.exe'; Command=$null   }) }
    )
    $vivi = @(
        [pscustomobject]@{ Pid=1; Cwd='C:\x';  Command='& tool'; What='pwsh';   Shell='pwsh.exe';       Label='x [1]' }
        [pscustomobject]@{ Pid=2; Cwd='C:\y';  Command=$null;    What='shell';  Shell='powershell.exe'; Label='y [2]' }
        [pscustomobject]@{ Pid=3; Cwd='C:\z';  Command='& altro';What='shell';  Shell='powershell.exe'; Label='z [3]' }
        [pscustomobject]@{ Pid=4; Cwd='C:\x';  Command='& tool'; What='ps';     Shell='powershell.exe'; Label='x-ps [4]' }
    )
    $m = @(Get-STLiveTabAreas -LiveTabs $vivi -Aree $aree)
    Check "il tab in un'area la nomina"        { (@($m[0].Aree) -contains 'alfa') }
    Check "e ne prende il colore"              { ($m[0].AreaColor -eq '#111111') }
    Check "anche con comando assente"          { (@($m[1].Aree) -contains 'beta' -and $m[1].AreaColor -eq '#222222') }
    Check "il tab estraneo non ha aree"        { (@($m[2].Aree).Count -eq 0 -and -not $m[2].AreaColor) }
    # Con il ripiego sulla cartella (v. sezione sotto) una shell diversa NON e' piu'
    # "estranea": la ricetta resta diversa, ma la cartella coincide e quindi il tab viene
    # segnalato lo stesso, dichiarando il grado piu' debole. E' il comportamento voluto:
    # meglio un avviso in piu' che un tab riaggiunto per sbaglio.
    Check "shell diversa: non e' la stessa RICETTA" { ($m[3].Certezza -ne 'ricetta') }
    Check "ma la cartella lo segnala comunque"      { ($m[3].Certezza -eq 'cartella' -and @($m[3].Aree) -contains 'alfa') }
    Check "la certezza e' dichiarata 'ricetta'" { ($m[0].Certezza -eq 'ricetta') }
    $dueAree = $aree + @([pscustomobject]@{ Name='gamma'; UiColor='#333333'; Tabs=@([pscustomobject]@{ Cwd='C:\x'; Shell='pwsh.exe'; Command='& tool' }) })
    $m2 = @(Get-STLiveTabAreas -LiveTabs @($vivi[0]) -Aree $dueAree)
    Check "un tab in due aree le elenca entrambe" { (@($m2[0].Aree).Count -eq 2) }

    Section "ripiego sulla CARTELLA quando la ricetta non combacia"
    # Il caso vero del 13/08: l'area `sistema` (giugno) ha i comandi con gli argomenti fra
    # apici, i processi vivi no -> stesso comando, ricetta diversa, cinque tab su sei
    # restavano spenti. Il ripiego guarda solo la cartella e DICHIARA di averlo fatto.
    $vivi2 = @(
        [pscustomobject]@{ Pid=9; Cwd='C:\x'; Command="& tool 'con-apici'"; What='pwsh'; Shell='pwsh.exe'; Label='x [9]' }
        [pscustomobject]@{ Pid=8; Cwd='C:\estranea'; Command='& altro'; What='shell'; Shell='powershell.exe'; Label='e [8]' }
    )
    $m3 = @(Get-STLiveTabAreas -LiveTabs $vivi2 -Aree $aree)
    Check "comando diverso, stessa cartella: riconosciuto" { (@($m3[0].Aree) -contains 'alfa') }
    Check "e il grado dichiara 'cartella'"                 { ($m3[0].Certezza -eq 'cartella') }
    Check "ne prende comunque il colore"                   { ($m3[0].AreaColor -eq '#111111') }
    Check "cartella estranea: nessuna area"                { (@($m3[1].Aree).Count -eq 0) }
    # QUESTA e' la sonda che mancava: prima il grado restava 'ricetta' anche senza
    # riscontro, perche' @($hash['assente']) e' @($null) e Count valeva 1, quindi il
    # ripiego non partiva mai. Il difetto passava inosservato perche' le prove
    # guardavano solo che Aree fosse vuoto -- e lo era.
    Check "senza riscontro il grado e' 'nessuna'"          { ($m3[1].Certezza -eq 'nessuna') }
    Check "la ricetta esatta ha la precedenza"             { (
        (@(Get-STLiveTabAreas -LiveTabs @($vivi[0]) -Aree $aree)[0]).Certezza -eq 'ricetta') }

    Section "la riga della lista dice quanto ne sa (Get-STLiveRowSpec)"
    $rEsatto = Get-STLiveRowSpec -Tab ([pscustomobject]@{ Label='x [1]'; Aree=@('alfa'); AreaColor='#111111'; Certezza='ricetta' })
    $rDebole = Get-STLiveRowSpec -Tab ([pscustomobject]@{ Label='y [2]'; Aree=@('alfa'); AreaColor='#111111'; Certezza='cartella' })
    $rNulla  = Get-STLiveRowSpec -Tab ([pscustomobject]@{ Label='z [3]'; Aree=@();       AreaColor=$null;    Certezza='nessuna' })
    Check "ricetta: nomina l'area senza riserve"  { ($rEsatto.Testo -match 'in: alfa$') }
    Check "cartella: lo DICHIARA nel testo"       { ($rDebole.Testo -match 'stessa cartella') }
    Check "i due testi non sono uguali"           { ($rEsatto.Testo -ne $rDebole.Testo) }
    Check "entrambi prendono il colore dell'area" { ($rEsatto.Colore -eq '#111111' -and $rDebole.Colore -eq '#111111') }
    Check "senza aree: solo l'etichetta"          { ($rNulla.Testo -eq 'z [3]' -and -not $rNulla.Colore) }
    $rDue = Get-STLiveRowSpec -Tab ([pscustomobject]@{ Label='w [4]'; Aree=@('alfa','beta'); AreaColor='#111111'; Certezza='ricetta' })
    Check "due aree: le nomina entrambe"          { ($rDue.Testo -match 'alfa, beta') }

    Section "il colore dell'area sopravvive a Save e New"
    New-STWorkspace -Name 'ciclo' -Tabs @(@{ Title='a'; Cwd=$root; Command='& .\a' }) | Out-Null
    Check "New: l'area nasce colorata"        { ([bool](@(Get-STWorkspace | Where-Object { $_.Name -eq 'ciclo' })[0]).UiColor) }
    # Un colore FUORI tavolozza, apposta: se Save/New lo perdessero, il rimedio automatico
    # ne assegnerebbe uno della tavolozza e la differenza si vedrebbe. Con un colore
    # qualunque la prova passava anche perdendolo -- due mutanti sopravvissuti l'hanno
    # detto, e la sonda non provava quello che dichiarava.
    $col = '#FEDCBA'
    Set-STWorkspaceColor -Name 'ciclo' -Color $col | Out-Null
    New-STWorkspace -Name 'ciclo' -Tabs @(@{ Title='b'; Cwd=$root; Command='& .\b' }) | Out-Null
    Check "New su area esistente: colore intatto" { ((@(Get-STWorkspace | Where-Object { $_.Name -eq 'ciclo' })[0]).UiColor -eq $col) }
    Save-STWorkspace -Name 'ciclo' | Out-Null
    Check "Save: colore intatto"              { ((@(Get-STWorkspace | Where-Object { $_.Name -eq 'ciclo' })[0]).UiColor -eq $col) }

    Section "l'indice delle ricette distingue le maiuscole come Add"
    $areeCase = @([pscustomobject]@{ Name='cs'; UiColor='#999999'; Tabs=@(
        [pscustomobject]@{ Cwd='C:\k'; Shell='powershell.exe'; Command='& tool -Flag' }) })
    $vivoCase = [pscustomobject]@{ Pid=7; Cwd='C:\k'; Command='& tool -flag'; What='ps'; Shell='powershell.exe'; Label='k [7]' }
    $mc = @(Get-STLiveTabAreas -LiveTabs @($vivoCase) -Aree $areeCase)
    Check "comando con case diverso: non e' la stessa ricetta" { ($mc[0].Certezza -ne 'ricetta') }

    Section "cwd relativa: '..' non si divora fra loro"
    Check "'..\..' resta due livelli"  { (
        (Get-STTabSignature @{Cwd='..\..'}) -cne (Get-STTabSignature @{Cwd='.'})) }
    Check "'..\..' diverso da '..'"    { (
        (Get-STTabSignature @{Cwd='..\..'}) -cne (Get-STTabSignature @{Cwd='..'})) }
    Check "'a\..' torna alla base"     { (
        (Get-STTabSignature @{Cwd='a\..'}) -ceq (Get-STTabSignature @{Cwd='.'})) }
    Check "'..\a' conserva il salto"   { (
        (Get-STTabSignature @{Cwd='..\a'}) -cne (Get-STTabSignature @{Cwd='a'})) }

    Section "drive-relative: C:..\x conserva il genitore"
    # "C:\" e' una radice, "C:" no: e' la cartella corrente su quel drive, quindi il '..'
    # sopra di essa e' reale e non si butta. Senza, C:..\x diventerebbe C:x.
    Check "C:..\x non collassa in C:x"  { (
        (Get-STTabSignature @{Cwd='C:..\x'}) -cne (Get-STTabSignature @{Cwd='C:x'})) }
    Check "C:..\x diverso da C:\x"      { (
        (Get-STTabSignature @{Cwd='C:..\x'}) -cne (Get-STTabSignature @{Cwd='C:\x'})) }
    Check "C:\..\x resta sulla radice"  { (
        (Get-STTabSignature @{Cwd='C:\..\x'}) -ceq (Get-STTabSignature @{Cwd='C:\x'})) }

    Section "il colore dell'area si valida invece di scriverlo e basta"
    $errori = 0
    foreach ($brutto in @('#12345', 'rosso', '112233', '#GGHHII', '#1234567')) {
        try { Set-STWorkspaceColor -Name 'ciclo' -Color $brutto | Out-Null } catch { $errori++ }
    }
    Check "cinque colori illeggibili, cinque rifiuti" { ($errori -eq 5) }
    Check "il colore buono e' rimasto"  { ((@(Get-STWorkspace | Where-Object { $_.Name -eq 'ciclo' })[0]).UiColor -eq '#FEDCBA') }
    $okAlpha = $true
    try { Set-STWorkspaceColor -Name 'ciclo' -Color '#80FEDCBA' | Out-Null } catch { $okAlpha = $false }
    Check "con canale alfa e' accettato" { $okAlpha }
    Set-STWorkspaceColor -Name 'ciclo' -Color '#FEDCBA' | Out-Null

    Section "Set-STWorkspaceTabTitle - il gesto, non la decisione (D3)"
    # Fixture scritta a mano: tutti i campi che il gesto NON deve toccare, compresi
    # uno storico col suo file e il sidecar del canale. Le righe 1 e 2 hanno la
    # STESSA ricetta apposta: servono per l'indirizzo ambiguo.
    $rnDir = Join-Path $wsDir 'rn'
    New-Item -ItemType Directory -Force -Path $rnDir | Out-Null
    'contenuto storico' | Set-Content -LiteralPath (Join-Path $rnDir 'tab-0.log') -Encoding utf8
    'byte-del-sidecar' | Set-Content -LiteralPath (Join-Path $rnDir 'terminale.json') -Encoding utf8
    ([pscustomobject]@{
        Name='rn'; Created=(Get-Date).ToString('o'); UiColor='#112233'
        Tabs=@(
            [pscustomobject]@{ Title='uno'; Color='#1FAA55'; Cwd='C:\a'; Shell='powershell.exe'; Command='& uno'; Intento='i1'; Fonte='lancio';   Storico='tab-0.log' },
            [pscustomobject]@{ Title='cmd'; Color='#2D7D9A'; Cwd='C:\b'; Shell='powershell.exe'; Command='& due'; Intento='i2'; Fonte='processo'; Storico=$null },
            [pscustomobject]@{ Title='tre'; Color='#3B7DD8'; Cwd='C:\b'; Shell='powershell.exe'; Command='& due'; Intento='i3'; Fonte='meta';     Storico=$null }
        )
    } | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $rnDir 'workspace.json') -Encoding utf8
    $rnWj = Join-Path $rnDir 'workspace.json'
    $primaJson = Get-Content -LiteralPath $rnWj -Raw | ConvertFrom-Json
    $sidePrima = (Get-FileHash -LiteralPath (Join-Path $rnDir 'terminale.json') -Algorithm MD5).Hash

    $r1 = Set-STWorkspaceTabTitle -Name 'rn' -Title 'docker' -Cwd 'C:\a' -Command '& uno'
    Check "rinomina per ricetta: fatta, riga 0"       { ($r1.Rinominata -and $r1.Riga -eq 0 -and $r1.Prima -eq 'uno') }
    $dopoJson = Get-Content -LiteralPath $rnWj -Raw | ConvertFrom-Json
    Check "il Title e' cambiato"                       { ($dopoJson.Tabs[0].Title -eq 'docker') }
    # Frank, 23/09: l'osservabile del 3o e' aggiornato -- cambia il Title E Fonte
    # ('persona'), e nient'altro. Sui rifiuti il file resta intatto, come prima.
    Check "Fonte diventa 'persona' sulla riga"         { ($dopoJson.Tabs[0].Fonte -eq 'persona') }
    Check "le altre righe identiche"                   { ((($dopoJson.Tabs[1] | ConvertTo-Json -Depth 6 -Compress) -eq ($primaJson.Tabs[1] | ConvertTo-Json -Depth 6 -Compress)) -and (($dopoJson.Tabs[2] | ConvertTo-Json -Depth 6 -Compress) -eq ($primaJson.Tabs[2] | ConvertTo-Json -Depth 6 -Compress))) }
    Check "Intento/Storico della riga identici"        { ($dopoJson.Tabs[0].Intento -eq 'i1' -and $dopoJson.Tabs[0].Storico -eq 'tab-0.log' -and $dopoJson.Tabs[0].Command -eq '& uno' -and $dopoJson.Tabs[0].Color -eq '#1FAA55') }
    Check "UiColor identico"                           { ($dopoJson.UiColor -eq '#112233') }
    Check "sidecar byte-identico"                      { ((Get-FileHash -LiteralPath (Join-Path $rnDir 'terminale.json') -Algorithm MD5).Hash -eq $sidePrima) }
    Check "storico intatto"                            { ((Get-Content -LiteralPath (Join-Path $rnDir 'tab-0.log') -Raw) -match 'contenuto storico') }

    $rawPrima = Get-Content -LiteralPath $rnWj -Raw
    $r2 = Set-STWorkspaceTabTitle -Name 'rn' -Title 'x' -Cwd 'C:\b' -Command '& due'
    Check "indirizzo ambiguo: NON rinomina (2 righe)"  { (-not $r2.Rinominata -and $r2.Righe -eq 2) }
    Check "ambiguita': file non toccato"               { ((Get-Content -LiteralPath $rnWj -Raw) -eq $rawPrima) }
    $r3 = Set-STWorkspaceTabTitle -Name 'rn' -Title 'x' -Cwd 'C:\zzz'
    Check "nessuna riga all'indirizzo: NON rinomina"   { (-not $r3.Rinominata -and $r3.Righe -eq 0) }
    $r4 = Set-STWorkspaceTabTitle -Name 'rn' -Title 'x'
    Check "nessun indirizzo dato: NON rinomina"        { (-not $r4.Rinominata) }
    $r5 = Set-STWorkspaceTabTitle -Name 'rn' -Title 'claude' -TitleVecchio 'cmd' -Cwd 'C:\b'
    Check "TitleVecchio + ricetta: una riga sola"      { ($r5.Rinominata -and $r5.Riga -eq 1) }
    Check "TitleVecchio: file aggiornato"              { ((Get-Content -LiteralPath $rnWj -Raw | ConvertFrom-Json).Tabs[1].Title -eq 'claude') }
    Check "Fonte='persona' anche da 'processo'"        { ((Get-Content -LiteralPath $rnWj -Raw | ConvertFrom-Json).Tabs[1].Fonte -eq 'persona') }

    Section "Rename-STWorkspace - il gesto sull'area, non la decisione"
    # Il nome di un'area sta in DUE posti: la cartella e il campo Name dentro
    # workspace.json (fermata 4 del mandato, verificata). L'osservabile: rinominata
    # e INTATTA -- sidecar e storico byte per byte, righe coi loro Intento/Fonte.
    New-STWorkspace -Name 'rnm' -Tabs @(
        @{ Title='uno'; Cwd='C:\r1'; Shell='powershell.exe'; Command='& uno'; Intento='lavoro'; Fonte='persona' },
        @{ Title='due'; Cwd='C:\r2'; Command='& due' }
    ) | Out-Null
    Set-STWorkspaceTerminale -Name 'rnm' -Path 'C:\fake\wt.exe' | Out-Null
    $rnmDir = Join-Path $wsDir 'rnm'
    'storico finto' | Set-Content -LiteralPath (Join-Path $rnmDir 'tab-0.log') -Encoding utf8
    $md5Side = (Get-FileHash -LiteralPath (Join-Path $rnmDir 'terminale.json') -Algorithm MD5).Hash
    $md5Stor = (Get-FileHash -LiteralPath (Join-Path $rnmDir 'tab-0.log') -Algorithm MD5).Hash
    $colPrec = (Get-Content -LiteralPath (Join-Path $rnmDir 'workspace.json') -Raw | ConvertFrom-Json).UiColor
    $rr = Rename-STWorkspace -Name 'rnm' -NewName 'rnm-new'
    $rnmNewWj = Join-Path (Join-Path $wsDir 'rnm-new') 'workspace.json'
    $wsNew = Get-Content -LiteralPath $rnmNewWj -Raw | ConvertFrom-Json
    Check "rinomina: il gesto dice si'"                { ($rr.Rinominata -and $rr.Prima -eq 'rnm' -and $rr.Dopo -eq 'rnm-new') }
    Check "la cartella ha il nome nuovo"               { ((-not (Test-Path -LiteralPath $rnmDir)) -and (Test-Path -LiteralPath (Join-Path $wsDir 'rnm-new'))) }
    Check "il Name nel file segue la cartella"         { ($wsNew.Name -eq 'rnm-new') }
    Check "righe intatte: titoli e comandi"            { ($wsNew.Tabs[0].Title -eq 'uno' -and $wsNew.Tabs[0].Command -eq '& uno' -and $wsNew.Tabs[1].Title -eq 'due') }
    Check "righe intatte: Intento e Fonte"             { ($wsNew.Tabs[0].Intento -eq 'lavoro' -and $wsNew.Tabs[0].Fonte -eq 'persona') }
    Check "UiColor intatto"                            { ($wsNew.UiColor -eq $colPrec) }
    Check "sidecar byte-identico"                      { ((Get-FileHash -LiteralPath (Join-Path (Join-Path $wsDir 'rnm-new') 'terminale.json') -Algorithm MD5).Hash -eq $md5Side) }
    Check "storico byte-identico"                      { ((Get-FileHash -LiteralPath (Join-Path (Join-Path $wsDir 'rnm-new') 'tab-0.log') -Algorithm MD5).Hash -eq $md5Stor) }
    Check "Get-STWorkspace mostra il nome nuovo"       { ((Get-STWorkspace).Name -contains 'rnm-new' -and -not ((Get-STWorkspace).Name -contains 'rnm')) }
    # I rifiuti: prima il no, e niente si muove.
    New-STWorkspace -Name 'rnmA' -Tabs @(@{ Title='a'; Cwd='C:\ra'; Command='& a' }) | Out-Null
    New-STWorkspace -Name 'rnmB' -Tabs @(@{ Title='b'; Cwd='C:\rb'; Command='& b' }) | Out-Null
    $rj = Rename-STWorkspace -Name 'rnmA' -NewName 'rnmB'
    Check "nome gia' preso: NON rinomina (niente fusioni)" { ((-not $rj.Rinominata) -and $rj.Motivo -match 'esiste') }
    Check "nome gia' preso: tutto fermo"               { ((Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'rnmA') 'workspace.json') -Raw | ConvertFrom-Json).Name -eq 'rnmA') }
    Check "caratteri vietati: NON rinomina"            { (-not (Rename-STWorkspace -Name 'rnmA' -NewName 'a:b').Rinominata) }
    Check "nome riservato Windows: NON rinomina"       { (-not (Rename-STWorkspace -Name 'rnmA' -NewName 'CON').Rinominata) }
    Check "punto finale: NON rinomina"                 { (-not (Rename-STWorkspace -Name 'rnmA' -NewName 'abc.').Rinominata) }
    Check "solo punti ('..'): NON rinomina"            { (-not (Rename-STWorkspace -Name 'rnmA' -NewName '..').Rinominata) }
    Check "spazi soli: NON rinomina"                   { (-not (Rename-STWorkspace -Name 'rnmA' -NewName '   ').Rinominata) }
    Check "area che non c'e': NON rinomina"            { (-not (Rename-STWorkspace -Name 'fantasma' -NewName 'x').Rinominata) }
    Check "stesso nome: NON rinomina"                  { (-not (Rename-STWorkspace -Name 'rnmA' -NewName 'rnmA').Rinominata) }
    Check "dopo i no la cartella e' sempre quella"     { ((Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'rnmA') 'workspace.json') -Raw | ConvertFrom-Json).Name -eq 'rnmA') }
    # Solo maiuscole: e' una rinomina vera e Windows la sa fare (sonda 22/09).
    New-STWorkspace -Name 'rncase' -Tabs @(@{ Title='c'; Cwd='C:\rc'; Command='& c' }) | Out-Null
    $rc = Rename-STWorkspace -Name 'rncase' -NewName 'RnCase'
    Check "solo maiuscole: rinomina"                   { ($rc.Rinominata) }
    Check "solo maiuscole: il file porta il nome nuovo" { ((Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'RnCase') 'workspace.json') -Raw | ConvertFrom-Json).Name -ceq 'RnCase') }
    # Il rollback: cartella rinominata ma file non aggiornabile -> la cartella torna
    # indietro, niente stati a meta'. Il file in sola lettura e' il modo onesto di
    # vedere questo ramo davvero.
    New-STWorkspace -Name 'rnrb' -Tabs @(@{ Title='r'; Cwd='C:\rr'; Command='& r' }) | Out-Null
    $rbWj = Join-Path (Join-Path $wsDir 'rnrb') 'workspace.json'
    Set-ItemProperty -LiteralPath $rbWj -Name IsReadOnly -Value $true
    $rb = Rename-STWorkspace -Name 'rnrb' -NewName 'rnrb-new'
    Set-ItemProperty -LiteralPath $rbWj -Name IsReadOnly -Value $false
    Check "file non aggiornabile: NON rinomina"        { (-not $rb.Rinominata) }
    Check "e la cartella e' tornata indietro"          { ((Test-Path -LiteralPath (Join-Path $wsDir 'rnrb')) -and -not (Test-Path -LiteralPath (Join-Path $wsDir 'rnrb-new'))) }

    Section "la guardia sui nomi di area: UNA SOLA, tre strade"
    # Frank, 22/09: la guardia va anche alla creazione, UNA e non tre copie. L'osservabile:
    # un nome cattivo e' rifiutato dalle tre strade CON LO STESSO MOTIVO, e i nomi buoni
    # passano da tutte e tre come prima -- una guardia si prova anche su cio' che NON deve
    # fermare. Le due aree vere restano accettate: il numero del manovale (0 su 2),
    # verificato col codice nuovo -- solo stringhe, il disco delle aree vere mai toccato.
    Check "nome buono: la guardia tace"                 { ($null -eq (Test-STNomeArea 'buono')) }
    Check "caratteri vietati: motivo"                   { ((Test-STNomeArea 'a:b') -match 'caratteri non validi') }
    Check "punto: sembra un file (Frank)"               { ((Test-STNomeArea 'area.txt') -match 'sembrare un file') }
    Check "riservato: motivo"                           { ((Test-STNomeArea 'CON') -match 'riservato') }
    Check "spazio finale: motivo"                       { ((Test-STNomeArea 'x ') -match 'spazio finale') }
    Check "vuoto: motivo"                               { ((Test-STNomeArea '   ') -match 'vuoto') }
    Check "recupero (area vera): accettato"             { ($null -eq (Test-STNomeArea 'recupero')) }
    Check "sistema (area vera): accettato"              { ($null -eq (Test-STNomeArea 'sistema')) }
    $gNew = New-STWorkspace -Name 'male:via' -Tabs @(@{ Title='m'; Cwd='C:\m'; Command='& m' })
    Check "New- rifiuta: esito col motivo"              { ($gNew.Rifiutata -and $gNew.Motivo -match 'caratteri non validi') }
    Check "New- rifiuta: niente cartella"               { (-not (Get-ChildItem -LiteralPath $wsDir -Directory -Filter 'male*')) }
    New-STWorkspace -Name 'buona' -Tabs @(@{ Title='b'; Cwd='C:\b1'; Command='& b' }) | Out-Null
    Check "New- nome buono: crea come prima"            { (Test-Path -LiteralPath (Join-Path (Join-Path $wsDir 'buona') 'workspace.json')) }
    $gAdd = Add-STWorkspaceTab -Name 'male:via' -Tabs @(@{ Title='m'; Cwd='C:\m'; Command='& m' })
    Check "Add- rifiuta: stessa forma, stesso motivo"   { ($gAdd.Rifiutata -and $gAdd.Added -eq 0 -and $gAdd.Motivo -eq $gNew.Motivo) }
    Check "Add- rifiuta: niente cartella"               { (-not (Get-ChildItem -LiteralPath $wsDir -Directory -Filter 'male*')) }
    $gAddOk = Add-STWorkspaceTab -Name 'buona' -Tabs @(@{ Title='b2'; Cwd='C:\b2'; Command='& b2' })
    Check "Add- nome buono: aggiunge come prima"        { ($gAddOk.Added -eq 1 -and $gAddOk.Total -eq 2) }
    $gRen = Rename-STWorkspace -Name 'buona' -NewName 'male:via'
    Check "le tre strade: un motivo solo"               { ((-not $gRen.Rinominata) -and $gRen.Motivo -eq $gNew.Motivo) }
    # Il caso di Bruce: un'area con un nome che ALTROVE era legale (il punto) e qui non
    # sarebbe mai nata. Add- si ferma anche se l'area esiste gia': non si allarga un nome cattivo.
    $dirB = Join-Path $wsDir 'v1.2'; New-Item -ItemType Directory -Force -Path $dirB | Out-Null
    (@{ Name='v1.2'; Created=(Get-Date).ToString('o'); Tabs=@(); UiColor=$null } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath (Join-Path $dirB 'workspace.json') -Encoding utf8
    $gB = Add-STWorkspaceTab -Name 'v1.2' -Tabs @(@{ Title='x'; Cwd='C:\x'; Command='& x' })
    Check "nome nato altrove: Add- si ferma"            { ($gB.Rifiutata -and $gB.Motivo -match 'sembrare un file') }

    Section "Get-STNameFromLaunch - F2: il venv senza punto (context-server)"
    # La funzione non e' esportata: si chiama nello scope del modulo, come fece il
    # manovale. La regola vale in tutte e due le direzioni: il caso vero deve parlare,
    # e le forme che tacciono giustamente devono restare mute -- una regola allargata
    # che dice di si' a tutto non ha imparato niente.
    $nfl = { param($r,$e) & (Get-Module STerminal) { param($rr,$ee) Get-STNameFromLaunch -Riga $rr -Exe $ee } $r $e }
    $rigaVera = '"C:\projects\context-server\venv\Scripts\python.exe" -m uvicorn context_server.main:app --host 0.0.0.0 --port 8420 --timeout-graceful-shutdown 30'
    Check "venv senza punto: il nome del progetto esce"  { ((& $nfl $rigaVera 'python.exe') -eq 'context-server') }
    Check ".venv col punto: invariato, batte main.py"    { ((& $nfl '"C:\x\chatbot\.venv\Scripts\python.exe" main.py' 'python.exe') -eq 'chatbot') }
    Check "venv annidato: la foglia e' il progetto"      { ((& $nfl '"C:\a\progetto\venv\Scripts\python.exe" -m qualcosa' 'python.exe') -eq 'progetto') }
    Check "'venvetta' non e' un venv: ripiego sul .py"   { ((& $nfl '"C:\venvetta\python.exe" .\script.py' 'python.exe') -eq 'script') }
    Check "python di sistema con -m: resta MUTO"         { ($null -eq (& $nfl '"C:\Python312\python.exe" -m pip install' 'python.exe')) }
    Check "-m uvicorn senza venv nel path: resta MUTO"   { ($null -eq (& $nfl '"C:\Python312\python.exe" -m uvicorn app:main' 'python.exe')) }
    Check "npm-cli in node_modules: resta MUTO"          { ($null -eq (& $nfl 'node "C:\x\node_modules\npm\bin\npm-cli.js" install' 'node.exe')) }
    Check "nessuna forma python: resta MUTO"             { ($null -eq (& $nfl '"C:\Python312\python.exe"' 'python.exe')) }

    Section "mini-interfaccia (dialogo Aggiungi a gruppo)"
    # Le prove del dialogo vivono nello script della UI, perche' li' ci sono i controlli
    # WPF; ma se restano fuori dalla suite, un TUTTO VERDE qui non dice niente su meta'
    # del lavoro. Quindi si lancia e se ne guarda l'esito (referto 13/08, rilievo 4).
    $ui = Join-Path (Split-Path $PSScriptRoot -Parent) 'Show-STerminal.ps1'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ui -TestAddDialog 2>&1 | Out-String
    Check "le prove del dialogo passano" { ($LASTEXITCODE -eq 0 -and $out -match 'TestAddDialog: TUTTO VERDE') }
    if ($out -notmatch 'TestAddDialog: TUTTO VERDE') {
        ($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' } | ForEach-Object { "      $($_.Trim())" })
    }
}
catch {
    # Senza questo, un'eccezione a meta' banco saltava tutti i controlli rimanenti e la
    # riga finale stampava lo stesso TUTTO VERDE, uscendo con 0: la suite MENTIVA proprio
    # quando si rompeva. Scoperto il 13/08 provando un mutante che non riusciva nemmeno a
    # partire -- e il banco lo dichiarava verde.
    $script:pass = $false
    "  [FAIL] il banco si e' interrotto: $($_.Exception.Message)"
    "         (a riga $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim()))"
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

# La copertura si dichiara SEMPRE, anche a banco verde: per settimane la riga di chiusura
# e' stata la stessa per "2 su 95" e per "95 su 95", e 93 prove ferme non le ha viste nessuno.
# Se il try esterno scatta prima della definizione di $cases, il moltiplicatore ripiega sul
# numero scritto nel file (5). (File in ASCII puro: niente "·".)
$casiPerTitolo = if ($cases) { @($cases).Count } else { 5 }
$dichiarate = $script:siti - $script:nelCiclo + ($script:nelCiclo * $casiPerTitolo)
""
"copertura: dichiarate $dichiarate | eseguite $script:eseguite | passate $script:passate | fallite $script:fallite | mai raggiunte $($dichiarate - $script:eseguite)"
"`n=== RISULTATO: $(if ($script:pass) { 'TUTTO VERDE' } else { 'CI SONO FAIL' }) ==="
if (-not $script:pass) { exit 1 } else { exit 0 }
