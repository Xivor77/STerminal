# STerminal - ripristino sessioni per PowerShell su Windows Terminal.
#
# v1 = la "fotografia": all'avvio ripristina il TESTO della sessione (output + comandi),
# la cwd, e i metadati del tab (titolo, colore). La history dei comandi e' gia' tenuta
# da PSReadLine, qui non la tocchiamo.
#
# Compatibile con Windows PowerShell 5.1 e PowerShell 7. File volutamente in ASCII puro,
# cosi' l'encoding non puo' rompere il parsing su nessuna delle due.
#
# LIMITI ONESTI v1 (vedi README):
#  - Il replay e' testo INERTE: niente colori ANSI (il transcript di PowerShell li scarta),
#    niente stato vivo (variabili/job/processi non sopravvivono - quella e' la fase 2,
#    "motore vivo", via named pipe).
#  - Cattura I/O di comandi normali; non cattura redraw a tutto schermo (TUI, progress bar).
#  - Il colore del tab si applica alla riapertura (wt --tabColor); un cambio colore fatto
#    dalla UI di WT durante la sessione non e' leggibile dalla shell.

$script:STRoot        = Join-Path $HOME '.sterminal'
$script:STWorkspaces  = Join-Path $script:STRoot 'workspaces'  # aree di lavoro nominate
$script:STModulePath  = $PSCommandPath          # percorso di questo .psm1 (serve al restore)
$script:STActive      = $false                  # questa sessione ha gia' fatto Initialize?
$script:STSlot        = $null                   # id slot di QUESTO tab
$script:STScrollback  = $null                   # file scrollback di questo tab
$script:STLastBeat    = [datetime]::MinValue    # throttle dell'heartbeat

#region helper puri (testabili headless)

function Get-STSlotDir {
    param([Parameter(Mandatory)][string]$Slot)
    Join-Path $script:STRoot $Slot
}

# Estrae il corpo "vero" da un file di transcript, togliendo gli header/footer
# (blocchi delimitati da righe di soli '*' che iniziano con "PowerShell transcript").
function Get-STScrollbackBody {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxLines = 5000
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path
    if (-not $raw) { return $null }

    $segments = [System.Collections.Generic.List[object]]::new()
    $cur = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $raw) {
        if ($line -match '^\*{5,}\s*$') {
            $segments.Add($cur); $cur = [System.Collections.Generic.List[string]]::new()
        } else {
            $cur.Add($line)
        }
    }
    $segments.Add($cur)

    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($seg in $segments) {
        $firstNonEmpty = $null
        foreach ($l in $seg) { if ($l.Trim() -ne '') { $firstNonEmpty = $l; break } }
        if ($null -eq $firstNonEmpty) { continue }                       # segmento vuoto
        if ($firstNonEmpty -like 'PowerShell transcript*') { continue }  # header o footer
        foreach ($l in $seg) { $body.Add($l) }
    }

    if ($body.Count -eq 0) { return $null }
    if ($body.Count -gt $MaxLines) {
        $body = $body.GetRange($body.Count - $MaxLines, $MaxLines)
    }
    return ($body -join [Environment]::NewLine)
}

function Read-STMeta {
    param([Parameter(Mandatory)][string]$Slot)
    $p = Join-Path (Get-STSlotDir $Slot) 'meta.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $null }
}

function Write-STMeta {
    param([Parameter(Mandatory)]$Meta)
    $dir = Get-STSlotDir $Meta.Slot
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    ($Meta | ConvertTo-Json -Depth 5) |
        Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding utf8
}

# I tab "vivi" dell'ultima finestra: heartbeat vicino al piu' recente, cosi' i tab della
# sessione precedente tornano insieme e gli zombie vecchi restano fuori. NON ci appoggiamo
# al flag Closed (l'evento di uscita non e' affidabile su reboot/shutdown): regola = recenza.
function Get-STAliveSlots {
    param([int]$WindowMinutes = 5)
    if (-not (Test-Path -LiteralPath $script:STRoot)) { return @() }
    $metas = Get-ChildItem -LiteralPath $script:STRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Read-STMeta $_.Name } |
        Where-Object { $_ -and $_.Heartbeat }
    if (-not $metas) { return @() }

    $parse = {
        param($s)
        [datetime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    }
    $newest = ($metas | ForEach-Object { & $parse $_.Heartbeat } | Measure-Object -Maximum).Maximum
    $cutoff = $newest.AddMinutes(-$WindowMinutes)
    @($metas | Where-Object { (& $parse $_.Heartbeat) -ge $cutoff })
}

#endregion

#region effetti sul terminale

# Imposta il titolo del tab via OSC (Windows Terminal lo onora).
function Set-STTabTitle {
    param([string]$Title)
    if ($Title) { [Console]::Write("$([char]27)]0;$Title$([char]7)") }
}

#endregion

function Set-STerminalTab {
    [CmdletBinding()]
    param(
        [string]$Title,
        [string]$Color,   # es. "#00AA55" - applicato alla riapertura via wt --tabColor
        [string]$Command, # cosa rilanciare alla riapertura (es. "claude --resume <id>")
        [string]$Group    # etichetta: Save-STWorkspace -Group la usa per catturare solo questi tab
    )
    if (-not $script:STActive) { Write-Warning "STerminal non inizializzato in questo tab (Initialize-STerminal)."; return }
    $meta = Read-STMeta $script:STSlot
    if (-not $meta) { return }
    if ($PSBoundParameters.ContainsKey('Title'))   { $meta.Title = $Title; Set-STTabTitle $Title }
    if ($PSBoundParameters.ContainsKey('Color'))   { $meta.Color = $Color }
    if ($PSBoundParameters.ContainsKey('Command')) {
        if ($meta.PSObject.Properties['Command']) { $meta.Command = $Command }
        else { $meta | Add-Member -NotePropertyName Command -NotePropertyValue $Command }
    }
    if ($PSBoundParameters.ContainsKey('Group')) {
        if ($meta.PSObject.Properties['Group']) { $meta.Group = $Group }
        else { $meta | Add-Member -NotePropertyName Group -NotePropertyValue $Group }
    }
    Write-STMeta $meta
    if ($PSBoundParameters.ContainsKey('Group')) { Write-Host "STerminal: tab nel gruppo '$Group'." -ForegroundColor DarkCyan }
}

# Aggiorna cwd + heartbeat nel meta del tab (throttled). Chiamata dal prompt.
function Update-STHeartbeat {
    param([switch]$Force)
    if (-not $script:STActive) { return }
    $now = Get-Date
    if (-not $Force -and ($now - $script:STLastBeat).TotalSeconds -lt 2) { return }
    $script:STLastBeat = $now
    $meta = Read-STMeta $script:STSlot
    if (-not $meta) { return }
    $meta.Cwd = (Get-Location).Path
    $meta.Heartbeat = $now.ToString('o')
    Write-STMeta $meta
}

function Initialize-STerminal {
    [CmdletBinding()]
    param(
        [string]$RestoreSlot,   # se passato: questo tab "reincarna" lo slot e ne replaya la fotografia
        [string]$Title,
        [string]$Color
    )
    if ($script:STActive) { Write-Warning "STerminal gia' attivo in questo tab."; return }

    New-Item -ItemType Directory -Force -Path $script:STRoot | Out-Null

    $isRestore = [bool]$RestoreSlot
    $slot = if ($isRestore) { $RestoreSlot } else { [guid]::NewGuid().ToString('n').Substring(0,12) }
    $dir  = Get-STSlotDir $slot
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $scrollback = Join-Path $dir 'scrollback.log'

    $script:STSlot       = $slot
    $script:STScrollback = $scrollback

    # 1) Se stiamo ripristinando, ristampa la fotografia PRIMA di riprendere a registrare.
    if ($isRestore) {
        $body = Get-STScrollbackBody -Path $scrollback
        if ($body) {
            $bar = '-' * 60
            Write-Host $bar -ForegroundColor DarkGray
            Write-Host '  STerminal - fotografia ripristinata (testo inerte)' -ForegroundColor DarkGray
            Write-Host $bar -ForegroundColor DarkGray
            [Console]::Out.Write($body)
            [Console]::Out.Write([Environment]::NewLine)
            Write-Host $bar -ForegroundColor DarkGray
        }
    }

    # 2) Quale shell e' questa? Serve al restore per rilanciare la stessa.
    $shellExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }

    # 3) Meta del tab.
    $existing = Read-STMeta $slot
    $meta = [pscustomobject]@{
        Slot      = $slot
        Title     = if ($PSBoundParameters.ContainsKey('Title')) { $Title } elseif ($existing) { $existing.Title } else { $null }
        Color     = if ($PSBoundParameters.ContainsKey('Color')) { $Color } elseif ($existing) { $existing.Color } else { $null }
        Command   = if ($existing -and $existing.PSObject.Properties['Command']) { $existing.Command } else { $null }
        Group     = if ($existing -and $existing.PSObject.Properties['Group']) { $existing.Group } else { $null }
        Cwd       = (Get-Location).Path
        Shell     = $shellExe
        Pid       = $PID
        # Il canale (22/09): il padre diretto di questa shell, osservato alla nascita
        # del tab -- un salto solo, senza conhost in mezzo. Se non e' osservabile resta
        # null: non si indovina MAI il nome del processo di un canale che non si vede.
        Terminale = Get-STTerminaleDelGenitore
        Created   = if ($existing -and $existing.Created) { $existing.Created } else { (Get-Date).ToString('o') }
        Heartbeat = (Get-Date).ToString('o')
        Closed    = $false
    }
    Write-STMeta $meta
    if ($meta.Title) { Set-STTabTitle $meta.Title }

    # 4) Avvia la cattura (append: il file scrollback accumula tra le sessioni).
    try {
        Start-Transcript -LiteralPath $scrollback -Append -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "STerminal: Start-Transcript fallito: $($_.Exception.Message)"
    }

    # 5) Avvolgi il prompt per aggiornare cwd+heartbeat senza perderlo. Lo stato originale
    #    va in scope GLOBALE: la funzione prompt e' globale e li' deve poterlo leggere.
    if (-not $global:STerminalOrigPrompt) {
        $existingPrompt = Get-Item function:prompt -ErrorAction SilentlyContinue
        if ($existingPrompt) { $global:STerminalOrigPrompt = $existingPrompt.ScriptBlock }
    }
    function global:prompt {
        Update-STHeartbeat
        if ($global:STerminalOrigPrompt) { & $global:STerminalOrigPrompt }
        else { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
    }

    # 6) Alla chiusura pulita, prova a chiudere il transcript (scrive il footer). Best-effort:
    #    su kill/reboot non scatta, e va bene cosi' - il parser regge anche senza footer.
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    $script:STActive = $true
    Write-Verbose "STerminal attivo. Slot=$slot scrollback=$scrollback shell=$shellExe"
}

# Riapre, in un'unica finestra di Windows Terminal, tutti i tab "vivi" dell'ultima sessione.
function Restore-STerminal {
    [CmdletBinding()]
    param([int]$WindowMinutes = 5)

    $slots = Get-STAliveSlots -WindowMinutes $WindowMinutes
    if (-not $slots) { Write-Host "STerminal: nessuna sessione da ripristinare." -ForegroundColor Yellow; return }

    Write-Host "STerminal: ripristino $($slots.Count) tab..." -ForegroundColor Cyan
    # Una sola invocazione di wt con tutti i new-tab separati da ';' -> una finestra, N tab
    # (niente raffica di processi wt, che andava in corsa e apriva finestre multiple).
    # Il canale (22/09): se TUTTI gli slot osservano lo stesso terminale ed esiste ancora,
    # il ripristino torna li'; misto o assente -> alias, come ieri, e il piano lo dice.
    $conCanale = @($slots | Where-Object { $_.PSObject.Properties['Terminale'] -and $_.Terminale })
    $distinti  = @($conCanale | ForEach-Object { [string]$_.Terminale } | Select-Object -Unique)
    $registrato = if ($distinti.Count -eq 1 -and $conCanale.Count -eq @($slots).Count) { $distinti[0] } else { $null }
    $piano = Get-STPianoLancio -ExeRegistrato $registrato
    foreach ($a in $piano.Avvisi) { Write-Host "STerminal: $a" -ForegroundColor Yellow }
    $wtAll = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $slots) {
        $exe = if ($s.Shell) { $s.Shell } else { 'powershell.exe' }
        $cmd = "Import-Module '$($script:STModulePath)'; Initialize-STerminal -RestoreSlot '$($s.Slot)'"
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
        if ($wtAll.Count -gt 0) { $wtAll.Add(';') }
        $wtAll.Add('new-tab')
        if ($s.Title)                                    { $wtAll.AddRange([string[]]@('--title', $s.Title)) }
        if ($s.Color)                                    { $wtAll.AddRange([string[]]@('--tabColor', $s.Color)) }
        if ($s.Cwd -and (Test-Path -LiteralPath $s.Cwd)) { $wtAll.AddRange([string[]]@('-d', $s.Cwd)) }
        $wtAll.AddRange([string[]]@($exe, '-NoExit', '-EncodedCommand', $enc))
    }
    if ($wtAll.Count -gt 0) { Start-Process -FilePath $piano.Exe -ArgumentList (@($piano.WindowArgs) + $wtAll.ToArray()) }
}

function Get-STerminalStatus {
    [pscustomobject]@{
        Active      = $script:STActive
        Slot        = $script:STSlot
        Scrollback  = $script:STScrollback
        Root        = $script:STRoot
        AliveSlots  = (Get-STAliveSlots).Slot
    }
}

#region aree di lavoro (workspaces)

# I tab attualmente APERTI = quelli il cui processo (Pid) e' ancora vivo. Piu' robusto
# della recenza per "salva la finestra": prende anche i tab idle (heartbeat fermo).
function Get-STOpenSlots {
    # "Il processo esiste ancora" NON vuol dire "e' ancora il mio": i pid si riciclano, e
    # misurato il 01/09 questa funzione tornava 20 slot per 15 schede - dentro c'erano un
    # msedge, un grep, e due schede vere con addosso il nome di un'altra cosa. Chiamare
    # Save-STWorkspace adesso salverebbe venti righe per quindici schede, due delle quali
    # con l'etichetta sbagliata. Stesse due guardie di Get-STSlotForPid, chieste allo
    # stesso posto: il nome del processo e il battito non anteriore all'avvio.
    if (-not (Test-Path -LiteralPath $script:STRoot)) { return @() }
    $metas = Get-ChildItem -LiteralPath $script:STRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Read-STMeta $_.Name } |
        Where-Object {
            if (-not ($_ -and $_.Pid)) { return $false }
            $pr = Get-Process -Id $_.Pid -ErrorAction SilentlyContinue
            if (-not $pr) { return $false }
            $avvio = $null; $noto = $false
            try { $avvio = $pr.StartTime; $noto = $true } catch { $noto = $false }
            $slot = if ($noto) { Get-STSlotForPid -ProcId ([int]$_.Pid) -ProcName "$($pr.ProcessName).exe" -ProcStart $avvio -Slots @($_) }
                    else       { Get-STSlotForPid -ProcId ([int]$_.Pid) -ProcName "$($pr.ProcessName).exe" -Slots @($_) }
            [bool]$slot
        }
    if (-not $metas) { return @() }
    @($metas | Sort-Object { [datetime]::Parse($_.Created, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) })
}

function Get-STWorkspaceDir {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path $script:STWorkspaces $Name
}

# Elenca le aree di lavoro salvate.
function Get-STWorkspace {
    if (-not (Test-Path -LiteralPath $script:STWorkspaces)) { return @() }
    Get-ChildItem -LiteralPath $script:STWorkspaces -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $wj = Join-Path $_.FullName 'workspace.json'
        if (Test-Path -LiteralPath $wj) {
            try { Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json } catch { }
        }
    }
}

# Intento e Fonte sono campi della RICETTA: li scrive Add (dalla cattura viva), ma non
# li conosce chi riscrive l'area da un'altra porta (Save dai vivi, New da definizione).
# Stessa lezione del colore dell'area: si leggono PRIMA che la cartella venga cancellata,
# e la riga nuova eredita quelli della riga vecchia con la STESSA ricetta (firma a tre
# parti). Solo se combacia UNA riga sola: due righe vecchie con la stessa ricetta e
# intenti diversi renderebbero l'eredita' un indovinello, e un intento indovinato e'
# peggio di uno perso. Se nessuna riga vecchia combacia i campi restano vuoti, che e' la
# risposta onesta: "questa ricetta non l'ha mai raccontata nessuno".
function Get-STCampiRicettaPrecedenti {
    param([object[]]$TabPrec, [object]$Tab)
    if (-not $TabPrec) { return $null }
    $firma = Get-STTabSignature $Tab -SenzaIntento
    $candidati = @($TabPrec | Where-Object {
        $_ -and (Get-STTabSignature $_ -SenzaIntento) -eq $firma
    })
    if ($candidati.Count -ne 1) { return $null }
    $c = $candidati[0]
    $intento = if ($c.PSObject.Properties['Intento']) { $c.Intento } else { $null }
    $fonte   = if ($c.PSObject.Properties['Fonte'])   { $c.Fonte }   else { $null }
    if ($null -eq $intento -and $null -eq $fonte) { return $null }
    [pscustomobject]@{ Intento = $intento; Fonte = $fonte }
}

# Salva i tab della finestra corrente come area di lavoro nominata.
# NOTA: titolo/colore catturati sono quelli noti a STerminal (Set-STerminalTab); la shell
# NON puo' leggere quelli impostati dalla UI di WT (click destro / doppio click).
function Save-STWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Group   # se dato: cattura SOLO i tab etichettati con questo gruppo (Set-STerminalTab -Group)
    )

    $slots = Get-STOpenSlots
    if ($Group) { $slots = @($slots | Where-Object { $_.Group -eq $Group }) }
    if (-not $slots) {
        $hint = if ($Group) { "nessun tab con gruppo '$Group' (etichettali con Set-STerminalTab -Group '$Group')." }
                else { "nessun tab registrato/aperto. Serve l'auto-init nel profilo (o Initialize-STerminal nei tab)." }
        Write-Warning "STerminal: $hint"
        return
    }

    $dir = Get-STWorkspaceDir $Name
    # Il colore dell'area si legge PRIMA: qui sotto la cartella viene CANCELLATA e
    # ricreata da zero, quindi rileggerlo dopo significa leggere un file che non c'e' piu'.
    # (Ed era proprio il difetto: la sonda passava lo stesso, perche' il rimedio
    # automatico riassegnava un colore che nel test capitava identico.)
    # E dal 22/09 non e' solo il colore: anche Intento/Fonte delle righe gia' salvate e
    # il sidecar terminale.json stanno in quella cartella. Chi riscrive da un'altra porta
    # non li conosce, ma non deve cancellarli (ticket dei tre scrittori): si portano
    # dietro come il colore.
    $uiPrec = $null
    $tabPrec = @()
    $wjPrec = Join-Path $dir 'workspace.json'
    if (Test-Path -LiteralPath $wjPrec) {
        try {
            $prec = Get-Content -LiteralPath $wjPrec -Raw | ConvertFrom-Json
            $uiPrec = $prec.UiColor
            $tabPrec = @($prec.Tabs)
        } catch { }
    }
    $sidePrec = $null
    $sidePath = Join-Path $dir 'terminale.json'
    if (Test-Path -LiteralPath $sidePath) {
        try { $sidePrec = [System.IO.File]::ReadAllBytes($sidePath) } catch { }
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $tabs = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($s in $slots) {
        $storFile = "tab-$i.log"
        $body = Get-STScrollbackBody -Path (Join-Path (Get-STSlotDir $s.Slot) 'scrollback.log')
        if ($body) { Set-Content -LiteralPath (Join-Path $dir $storFile) -Value $body -Encoding utf8 }
        $campiPrec = Get-STCampiRicettaPrecedenti -TabPrec $tabPrec -Tab $s
        $tabs.Add([pscustomobject]@{
            Title   = $s.Title
            Color   = $s.Color
            Cwd     = $s.Cwd
            Shell   = $s.Shell
            Command = $s.Command
            Intento = if ($campiPrec) { $campiPrec.Intento } else { $null }
            Fonte   = if ($campiPrec) { $campiPrec.Fonte } else { $null }
            Storico = $storFile
        })
        $i++
    }

    # Il colore dell'area sopravvive al risalvataggio: Save ricrea il file da zero, e
    # senza rileggerlo prima un salvataggio cancellerebbe quello che c'era.
    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $tabs; UiColor = $uiPrec }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wjPrec -Encoding utf8
    if ($null -ne $sidePrec) { [System.IO.File]::WriteAllBytes($sidePath, $sidePrec) }
    if (-not $uiPrec) { [void](Set-STWorkspaceColor -Name $Name) }
    Write-Host "STerminal: area '$Name' salvata ($($tabs.Count) tab)." -ForegroundColor Green
}

# Definisce un'area da ZERO, senza catturare tab aperti: un elenco di tab con un comando.
# Ogni tab e' una hashtable: @{ Title=...; Cwd=...; Command=...; Color=...; Shell=... }
# (Title/Cwd/Command sono quelli che contano; Color/Shell opzionali.)
function New-STWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Tabs
    )
    $dir = Get-STWorkspaceDir $Name
    # Il colore dell'area si legge PRIMA: qui sotto la cartella viene CANCELLATA e
    # ricreata da zero, quindi rileggerlo dopo significa leggere un file che non c'e' piu'.
    # (Ed era proprio il difetto: la sonda passava lo stesso, perche' il rimedio
    # automatico riassegnava un colore che nel test capitava identico.)
    # E dal 22/09 non e' solo il colore: anche Intento/Fonte delle righe gia' salvate e
    # il sidecar terminale.json stanno in quella cartella. Chi riscrive da un'altra porta
    # non li conosce, ma non deve cancellarli (ticket dei tre scrittori): si portano
    # dietro come il colore.
    $uiPrec = $null
    $tabPrec = @()
    $wjPrec = Join-Path $dir 'workspace.json'
    if (Test-Path -LiteralPath $wjPrec) {
        try {
            $prec = Get-Content -LiteralPath $wjPrec -Raw | ConvertFrom-Json
            $uiPrec = $prec.UiColor
            $tabPrec = @($prec.Tabs)
        } catch { }
    }
    $sidePrec = $null
    $sidePath = Join-Path $dir 'terminale.json'
    if (Test-Path -LiteralPath $sidePath) {
        try { $sidePrec = [System.IO.File]::ReadAllBytes($sidePath) } catch { }
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Tabs) {
        $shellT = if ($t.Shell) { $t.Shell } else { 'powershell.exe' }
        $intentoDato = if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('Intento')) { $t['Intento'] } else { $null } }
                       elseif ($t.PSObject.Properties['Intento']) { $t.Intento } else { $null }
        $fonteData = if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('Fonte')) { $t['Fonte'] } else { $null } }
                     elseif ($t.PSObject.Properties['Fonte']) { $t.Fonte } else { $null }
        # La firma si calcola sulla shell EFFETTIVA: una definizione senza Shell vale
        # 'powershell.exe', e deve combaciare con la riga vecchia scritta cosi'.
        $campiPrec = Get-STCampiRicettaPrecedenti -TabPrec $tabPrec -Tab ([pscustomobject]@{ Cwd = $t.Cwd; Shell = $shellT; Command = $t.Command })
        $list.Add([pscustomobject]@{
            Title   = $t.Title
            Color   = $t.Color
            Cwd     = $t.Cwd
            Shell   = $shellT
            Command = $t.Command
            # Il chiamante puo' definire Intento/Fonte lui stesso; se tace, la riga
            # eredita quelli della riga vecchia con la stessa ricetta (come Save).
            Intento = if ($null -ne $intentoDato) { $intentoDato } elseif ($campiPrec) { $campiPrec.Intento } else { $null }
            Fonte   = if ($null -ne $fonteData) { $fonteData } elseif ($campiPrec) { $campiPrec.Fonte } else { $null }
            Storico = $null
        })
    }
    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $list; UiColor = $uiPrec }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wjPrec -Encoding utf8
    if ($null -ne $sidePrec) { [System.IO.File]::WriteAllBytes($sidePath, $sidePrec) }
    if (-not $uiPrec) { [void](Set-STWorkspaceColor -Name $Name) }
    Write-Host "STerminal: area '$Name' definita ($($list.Count) tab)." -ForegroundColor Green
}

# Apre un singolo tab di un'area: ristampa lo storico (testo) e poi diventa un tab vivo
# (re-Initialize), cosi' l'area si puo' ri-salvare.
function Open-STWorkspaceTab {
    [CmdletBinding()]
    param([string]$Storico, [string]$Title, [string]$Color, [string]$Command, [int]$RitardoAvvio = 0)
    if ($Storico -and (Test-Path -LiteralPath $Storico)) {
        $body = Get-Content -LiteralPath $Storico -Raw
        if ($body) {
            $bar = '-' * 60
            Write-Host $bar -ForegroundColor DarkGray
            Write-Host '  STerminal - storico ripristinato (testo)' -ForegroundColor DarkGray
            Write-Host $bar -ForegroundColor DarkGray
            [Console]::Out.Write($body)
            [Console]::Out.Write([Environment]::NewLine)
            Write-Host $bar -ForegroundColor DarkGray
        }
    }
    Initialize-STerminal -Title $Title -Color $Color
    if ($Command) {
        Set-STerminalTab -Command $Command   # persisti nel nuovo slot (ri-salvabile)
        # Rilancio ORDINATO (requisito di Vittorio, 22/09): una scheda alla volta, non
        # tutte insieme. Il ritardo e' deciso da chi costruisce la riga di resume
        # (Get-STResumeArgs) e vive solo in questa sessione: nessuno stato nuovo che
        # sopravvive fra una scheda e l'altra.
        if ($RitardoAvvio -gt 0) {
            Write-Host "STerminal: rilancio ordinato, questa scheda parte tra $RitardoAvvio s -> $Command" -ForegroundColor DarkGray
            Start-Sleep -Seconds $RitardoAvvio
        } else {
            Write-Host "STerminal: avvio -> $Command" -ForegroundColor DarkCyan
        }
        try { Invoke-Expression $Command } catch { Write-Warning "STerminal: comando fallito: $($_.Exception.Message)" }
    }
}

# Costruisce gli argomenti wt per UN tab (frammento che parte da 'new-tab'), SENZA lanciarlo.
# Separato dallo spawn cosi' e' testabile su percorsi/titoli difficili (spazi, apostrofi, accenti).
function Get-STResumeTabSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tab,
        [Parameter(Mandatory)][string]$WorkspaceDir,
        [int]$RitardoAvvio = 0
    )
    $q = { param($s) if ($null -eq $s) { '' } else { ([string]$s).Replace("'", "''") } }
    $stor = if ($Tab.Storico) { Join-Path $WorkspaceDir $Tab.Storico } else { '' }
    $exe  = if ($Tab.Shell) { [string]$Tab.Shell } else { 'powershell.exe' }
    $cmd  = "Import-Module '$(& $q $script:STModulePath)'; Open-STWorkspaceTab -Storico '$(& $q $stor)' -Title '$(& $q $Tab.Title)' -Color '$(& $q $Tab.Color)' -Command '$(& $q $Tab.Command)' -RitardoAvvio $RitardoAvvio"
    $enc  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    # NB: parte da 'new-tab' (niente -w): tutti i tab vanno in UNA sola invocazione di wt,
    # separati da ';' -> stessa finestra, niente race / finestre multiple (bug del per-tab spawn).
    $wtArgs = [System.Collections.Generic.List[string]]::new()
    $wtArgs.Add('new-tab')
    if ($Tab.Title) { $wtArgs.AddRange([string[]]@('--title', [string]$Tab.Title)) }
    if ($Tab.Color) { $wtArgs.AddRange([string[]]@('--tabColor', [string]$Tab.Color)) }
    if ($Tab.Cwd -and (Test-Path -LiteralPath ([string]$Tab.Cwd))) { $wtArgs.AddRange([string[]]@('-d', [string]$Tab.Cwd)) }
    $wtArgs.AddRange([string[]]@($exe, '-NoExit', '-EncodedCommand', $enc))

    [pscustomobject]@{
        WtArgs         = $wtArgs.ToArray()
        Exe            = $exe
        EncodedCommand = $enc
        DecodedCommand = $cmd
        HasCwd         = [bool]($wtArgs -contains '-d')
    }
}

# Unisce i frammenti di tutti i tab in UNA riga di comando wt: new-tab ... ; new-tab ... ; ...
# Il rilancio dei comandi e' ORDINATO (requisito di Vittorio, 22/09): i tab si aprono
# insieme in una finestra sola (cosi' niente focus-jump #19970), ma i loro COMANDI partono
# sfalsati di $PassoSecondi l'uno dall'altro, nell'ordine salvato, il primo subito. Lo
# sfasamento e' un ritardo cotto dentro la riga di ogni scheda: vive nella sessione della
# scheda stessa e non lascia nessuno stato nuovo in giro (niente file di coda, niente
# testimoni). Limite dichiarato: e' un passo a tempo, non un cancello -- se un comando
# impiega piu' del passo a comparire, il successivo parte lo stesso. Un cancello vero
# ("la prossima parte quando la precedente e' su") richiederebbe uno stato condiviso fra
# le schede, e quello va chiesto prima di costruirlo.
function Get-STResumeArgs {
    param([Parameter(Mandatory)][object[]]$Tabs, [Parameter(Mandatory)][string]$WorkspaceDir, [int]$PassoSecondi = 5)
    $all = [System.Collections.Generic.List[string]]::new()
    $attesa = 0
    foreach ($t in $Tabs) {
        if (-not $t) { continue }
        $ritardo = 0
        if ($t.Command) { $ritardo = $attesa; $attesa += $PassoSecondi }
        $spec = Get-STResumeTabSpec -Tab $t -WorkspaceDir $WorkspaceDir -RitardoAvvio $ritardo
        if ($all.Count -gt 0) { $all.Add(';') }
        $all.AddRange([string[]]$spec.WtArgs)
    }
    $all.ToArray()
}

# --- CANALE (22/09, ticket 01M19XAEJ415J466WSZD6A6ZQX) --------------------------------
# wt.exe e' un ALIAS DI ESECUZIONE: Stabile, Preview e Canary dichiarano tutti lo stesso
# alias e Windows ne tiene attivo UNO. La regola e' di Vittorio (30/08, non si ridecide):
# "l'area segue il terminale in cui e' stata catturata, e per cambiarlo serve una
# conversione esplicita". Quindi il canale si OSSERVA alla cattura (mai dedotto dal nome
# del pacchetto o indovinato) e si ritrova al ripristino.

# Il terminale di QUESTO tab: il padre diretto della shell, osservato.
function Get-STTerminaleDelGenitore {
    param([int]$ProcId = $PID)
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction Stop
        if (-not $me) { return $null }
        $padre = Get-CimInstance Win32_Process -Filter "ProcessId=$($me.ParentProcessId)" -ErrorAction Stop
        if ($padre -and $padre.ExecutablePath) { return [string]$padre.ExecutablePath }
    } catch { }
    $null
}

# Dal percorso dell'exe alla famiglia del pacchetto, per leggere il settings.json giusto.
# Forma osservata: ...\WindowsApps\<Nome_versione_arch__hash>\WindowsTerminal.exe ->
# famiglia <Nome>_<hash>. Fuori da WindowsApps il settings non si sa dove stia SENZA
# indovinare: si tace ($null), e chi chiama lo dichiara.
function Get-STTerminaleFamily {
    param([string]$ExePath)
    if (-not $ExePath) { return $null }
    $m = [regex]::Match($ExePath, '\\WindowsApps\\([^\\]+)\\')
    if (-not $m.Success) { return $null }
    $pezzi = $m.Groups[1].Value -split '_'
    if ($pezzi.Count -lt 2) { return $null }
    "$($pezzi[0])_$($pezzi[-1])"
}

# Il piano di lancio di un ripristino: QUALE exe, CON QUALI argomenti di finestra, e gli
# avvisi da dire a voce alta. Due punti cablati ('wt.exe' a Restore-STerminal e
# Resume-STWorkspace) diventano UNA decisione sola, qui:
# 1. il canale registrato alla cattura vince; se il percorso non esiste piu' (area di
#    un'altra macchina, canale disinstallato) si ripiega sull'alias e LO SI DICE;
# 2. windowingBehavior e' una PRECONDIZIONE che si legge, non un default che si assume:
#    se non e' 'useNew' i tab finirebbero in una finestra gia' aperta senza nessun
#    errore -- si forza '-w new' e LO SI DICE. (Il settings di WT e' JSONC: si estrae
#    il valore con una regex invece di parsare, cosi' i commenti non affondano la lettura.)
function Get-STPianoLancio {
    param([string]$ExeRegistrato, [switch]$TerminaleCorrente)
    $avvisi = [System.Collections.Generic.List[string]]::new()
    $exe = 'wt.exe'
    if ($TerminaleCorrente) {
        [void]$avvisi.Add("deviazione dichiarata: si usa il terminale corrente (alias wt.exe), non quello della cattura")
    } elseif ($ExeRegistrato) {
        if (Test-Path -LiteralPath $ExeRegistrato) { $exe = $ExeRegistrato }
        else { [void]$avvisi.Add("catturata in '$ExeRegistrato', che qui non esiste: ripiego sull'alias wt.exe") }
    }
    $winArgs = @()
    $fam = Get-STTerminaleFamily $exe
    if ($fam) {
        $sj = Join-Path $env:LOCALAPPDATA ("Packages\" + $fam + "\LocalState\settings.json")
        if (Test-Path -LiteralPath $sj) {
            $m = [regex]::Match((Get-Content -LiteralPath $sj -Raw), '"windowingBehavior"\s*:\s*"([^"]+)"')
            if ($m.Success -and $m.Groups[1].Value -ne 'useNew') {
                $winArgs = @('-w', 'new')
                [void]$avvisi.Add("windowingBehavior='$($m.Groups[1].Value)': forzato '-w new', altrimenti l'area si scioglierebbe in una finestra gia' aperta senza errori")
            }
        }
    } elseif ($exe -ne 'wt.exe') {
        [void]$avvisi.Add("terminale fuori pacchetto: windowingBehavior non leggibile senza indovinare -- si procede, dichiarato")
    }
    [pscustomobject]@{ Exe = $exe; WindowArgs = $winArgs; Avvisi = $avvisi }
}

# Riapre un'area di lavoro: UNA finestra WT con tutti i suoi tab, pre-colorati e titolati
# (cosi' si scavalca il focus-jump #19970), nelle cartelle giuste, con lo storico e il comando.
# I comandi partono UNO ALLA VOLTA (sfalsati di -PassoSecondi, vedi Get-STResumeArgs).
function Resume-STWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [int]$PassoSecondi = 5, [switch]$TerminaleCorrente)

    $dir = Get-STWorkspaceDir $Name
    $wj = Join-Path $dir 'workspace.json'
    if (-not (Test-Path -LiteralPath $wj)) { Write-Warning "STerminal: area '$Name' non trovata."; return }
    $ws = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
    if (-not $ws.Tabs) { Write-Warning "STerminal: area '$Name' senza tab."; return }

    # Il canale della cattura (22/09): sidecar terminale.json, scritto da
    # Set-STWorkspaceTerminale. -TerminaleCorrente e' la deviazione one-shot dichiarata;
    # la conversione che RESTA e' il gesto esplicito di Set-STWorkspaceTerminale -Corrente.
    $registrato = $null
    $sidecar = Join-Path $dir 'terminale.json'
    if (Test-Path -LiteralPath $sidecar) {
        try { $registrato = [string](Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json).Path } catch { }
    }
    $piano = Get-STPianoLancio -ExeRegistrato $registrato -TerminaleCorrente:$TerminaleCorrente
    foreach ($a in $piano.Avvisi) { Write-Host "STerminal: $a" -ForegroundColor Yellow }

    $conComando = @($ws.Tabs | Where-Object { $_.Command }).Count
    $coda = if ($conComando -gt 1) { " -- rilancio ordinato: $conComando comandi, uno ogni $PassoSecondi s" } else { '' }
    Write-Host "STerminal: riprendo area '$Name' ($(@($ws.Tabs).Count) tab)$coda..." -ForegroundColor Cyan
    $wtAll = Get-STResumeArgs -Tabs @($ws.Tabs) -WorkspaceDir $dir -PassoSecondi $PassoSecondi
    if ($wtAll.Count -gt 0) { Start-Process -FilePath $piano.Exe -ArgumentList (@($piano.WindowArgs) + $wtAll) }
}

# La CONVERSIONE ESPLICITA della regola del 30/08: l'area segue il terminale in cui fu
# catturata, e per cambiarlo serve un gesto col suo nome -- questo. Scrive il sidecar
# terminale.json accanto a workspace.json: un file suo, UNO scrittore solo, perche' i
# campi di workspace.json hanno gia' tre scrittori che si pestano (ticket
# 01M34VV43KE1FKZJDAAWMB3JQ7) e il quarto non deve nascere qui.
function Set-STWorkspaceTerminale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Path,
        [switch]$Corrente,
        [string]$Fonte = 'conversione'
    )
    if ($Corrente) {
        $Path = Get-STTerminaleDelGenitore
        if (-not $Path) { Write-Warning "STerminal: il terminale di questo tab non e' osservabile: niente da registrare, e non si indovina."; return }
    }
    if (-not $Path) { Write-Warning "STerminal: serve -Path o -Corrente."; return }
    $dir = Get-STWorkspaceDir $Name
    if (-not (Test-Path -LiteralPath $dir)) { Write-Warning "STerminal: area '$Name' non trovata."; return }
    [pscustomobject]@{ Path = $Path; Fonte = $Fonte; At = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'terminale.json') -Encoding utf8
    Write-Host "STerminal: area '$Name' seguira' '$Path' ($Fonte)." -ForegroundColor DarkCyan
}

function Remove-STWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $dir = Get-STWorkspaceDir $Name
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
        Write-Host "STerminal: area '$Name' eliminata." -ForegroundColor Yellow
    } else { Write-Warning "STerminal: area '$Name' non trovata." }
}

#endregion

#region tab vivi (sorgente per la UI: cosa e' aperto adesso, anche tab NON registrati/occupati)

# Lettore nativo della cwd di un processo (PEB). Caricato una volta sola per sessione.
if (-not ('STNative' -as [type])) {
    try {
        Add-Type -Language CSharp -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class STNative {
    [StructLayout(LayoutKind.Sequential)] struct PBI { public IntPtr R1; public IntPtr Peb; public IntPtr A; public IntPtr B; public IntPtr Id; public IntPtr R3; }
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h,int c,ref PBI p,int l,out int r);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(int a,bool i,int p);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadProcessMemory(IntPtr h,IntPtr a,byte[] b,IntPtr s,out IntPtr r);
    static IntPtr RP(IntPtr h,long a){byte[] b=new byte[8];IntPtr r;if(!ReadProcessMemory(h,(IntPtr)a,b,(IntPtr)8,out r))return IntPtr.Zero;return (IntPtr)BitConverter.ToInt64(b,0);}
    public static string Cwd(int pid){
        IntPtr h=OpenProcess(0x0410,false,pid); if(h==IntPtr.Zero) return null;
        try{ PBI p=new PBI(); int r; if(NtQueryInformationProcess(h,0,ref p,Marshal.SizeOf(p),out r)!=0) return null;
            IntPtr pp=RP(h,(long)p.Peb+0x20); if(pp==IntPtr.Zero) return null;
            byte[] us=new byte[16]; IntPtr q; if(!ReadProcessMemory(h,(IntPtr)((long)pp+0x38),us,(IntPtr)16,out q)) return null;
            ushort len=BitConverter.ToUInt16(us,0); long buf=BitConverter.ToInt64(us,8); if(len==0||buf==0) return null;
            byte[] sb=new byte[len]; if(!ReadProcessMemory(h,(IntPtr)buf,sb,(IntPtr)len,out q)) return null;
            return Encoding.Unicode.GetString(sb).TrimEnd('\0','\\');
        } finally { CloseHandle(h); }
    }
}
'@
    } catch { }
}

function Get-STCwdSafe { param([int]$ProcId) if ('STNative' -as [type]) { try { [STNative]::Cwd($ProcId) } catch { $null } } else { $null } }

# Converte una CommandLine di Win32 in una stringa eseguibile da PowerShell: & 'exe' args
function ConvertTo-STRunnable {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    $cl = $CommandLine.Trim()
    if ($cl.StartsWith('"')) {
        $end = $cl.IndexOf('"', 1)
        if ($end -lt 0) { return $cl }
        $exe = $cl.Substring(1, $end - 1); $rest = $cl.Substring($end + 1).Trim()
    } else {
        $sp = $cl.IndexOf(' ')
        if ($sp -lt 0) { $exe = $cl; $rest = '' } else { $exe = $cl.Substring(0, $sp); $rest = $cl.Substring($sp + 1).Trim() }
    }
    $exeEsc = $exe.Replace("'", "''")
    if ($rest) { "& '$exeEsc' $rest" } else { "& '$exeEsc'" }
}

#region la catena del nome (referto DISEGNO 01/09)
# La sorgente del nome di una scheda e' una CATENA, e l'ultimo anello e' il comportamento
# di prima: se le sorgenti nuove tacciono esce esattamente quello che usciva ieri.
#   1. il meta.json dello slot - la scheda l'ha aperta STerminal, comando e titolo sono
#      noti per costruzione. Erano gia' su disco e la strada di cattura non li apriva
#      (DISEGNO 01/09 sez.11.3: "butta via quello che ha gia' in mano").
#   2. l'ultima riga digitata nel transcript dello slot - l'intenzione di lancio e' gia'
#      scritta li' dentro (sez.11.2), ed e' l'informazione che le tre regole del 30/08
#      cercavano nell'albero dei processi, dove non c'e'.
#   3. il primo figlio della shell - quello che si faceva prima.
# Non si indovina piu' niente: si legge quello che e' gia' scritto, e dove non c'e' scritto
# niente resta in piedi la risposta di prima.

function Get-STSlotForPid {
    <#
    .SYNOPSIS
    Lo slot che appartiene DAVVERO a questo processo, non quello che ne rivendica il pid.

    .DESCRIPTION
    Confrontare meta.Pid con il pid NON basta, ed e' misurato: oggi cinque slot su venti
    rivendicano il pid di un processo che non e' il loro - un msedge, un grep, e DUE schede
    vere che si porterebbero addosso il nome di un'altra cosa ('ORKAI' su ComfyUI,
    'ComfyUI' sulla scheda vuota; DISEGNO 01/09 sez.4.1). I pid si riciclano: leggere un
    nome da uno slot scaduto e' peggio che non leggerlo, perche' non chiede di essere
    controllato (sez.5).

    Due guardie in fila, e nessuna delle due indovina:
      1. il processo vivo deve chiamarsi come la shell che lo slot ha REGISTRATO. Uno slot
         che dice powershell.exe non puo' essere di un msedge.exe.
      2. l'ultimo battito dello slot non puo' essere ANTERIORE all'avvio del processo.
         Initialize-STerminal scrive Heartbeat all'avvio, quindi uno slot che ha smesso di
         battere PRIMA che questo processo nascesse stava battendo per qualcun altro.
         Il confronto e' sul battito e NON su Created: al ripristino Created e' quello
         originale (v. Initialize-STerminal), e uno slot ripristinato verrebbe buttato via.

    Se restano piu' candidati vince chi ha battuto per ultimo. Se non ne resta nessuno la
    risposta e' $null e chi chiama torna al comportamento di prima: mai un ripiego inventato.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcId,
        [string]$ProcName,          # nome del processo vivo (es. powershell.exe)
        [datetime]$ProcStart,       # avvio del processo vivo
        [object[]]$Slots            # per le prove: l'elenco dei meta gia' letto
    )
    $avvioNoto = $PSBoundParameters.ContainsKey('ProcStart')
    if (-not $PSBoundParameters.ContainsKey('ProcName') -or -not $avvioNoto) {
        $pr = Get-Process -Id $ProcId -ErrorAction SilentlyContinue
        if (-not $pr) { return $null }
        if (-not $PSBoundParameters.ContainsKey('ProcName')) { $ProcName = "$($pr.ProcessName).exe" }
        # StartTime puo' essere illeggibile (processo elevato o protetto). In quel caso la
        # guardia 2 si SPEGNE invece di bocciare: buttare una scheda vera farebbe sparire
        # una riga da Save-STWorkspace, che e' un danno peggiore di uno slot di troppo.
        if (-not $avvioNoto) { try { $ProcStart = $pr.StartTime; $avvioNoto = $true } catch { $avvioNoto = $false } }
    }
    if (-not $PSBoundParameters.ContainsKey('Slots')) {
        if (-not (Test-Path -LiteralPath $script:STRoot)) { return $null }
        $Slots = @(Get-ChildItem -LiteralPath $script:STRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Read-STMeta $_.Name })
    }
    $batti = {
        param($m)
        if (-not $m.Heartbeat) { return $null }
        try { [datetime]::Parse($m.Heartbeat, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $null }
    }
    $cand = @($Slots | Where-Object {
        $_ -and $_.Pid -and ([int]$_.Pid -eq $ProcId) -and
        $_.Shell -and ([string]$_.Shell -eq [string]$ProcName)
    })
    if (-not $cand.Count) { return $null }
    # L'@() va INTORNO all'if, non dentro i suoi rami: l'uscita di un blocco `if` passa
    # per la pipeline, che SFILA le collezioni di un elemento solo. Con l'@() dentro,
    # $vivi diventava lo slot invece dell'array che lo contiene, $vivi.Count era $null e
    # la funzione rispondeva "nessuno slot" proprio nel caso normale (un candidato solo).
    $vivi = @(if ($avvioNoto) { $cand | Where-Object { $b = & $batti $_; $b -and ($b -ge $ProcStart) } } else { $cand })
    if (-not $vivi.Count) { return $null }
    if ($vivi.Count -eq 1) { return $vivi[0] }
    @($vivi | Sort-Object { & $batti $_ } -Descending)[0]
}

function Get-STLastTypedLine {
    <#
    .SYNOPSIS
    L'ultima riga DIGITATA nel transcript di uno slot, e se e' ancora quella che comanda.

    .DESCRIPTION
    Start-Transcript segna con 'PS>' in testa le righe che la persona ha digitato. Due
    trappole, misurate il 01/09 e non previste dal disegno:

    1. 'PS>' NON e' solo il marcatore dei comandi digitati: PowerShell scrive con lo stesso
       prefisso anche i propri errori terminanti. La riga
           PS>Errore fatale (): "Pipeline arrestata."
       compare in 5 slot su 15. Prendere "l'ultima riga PS>" e basta legge quella.
    2. La riga puo' essere STANTIA. Nello slot di Tommy sul disco c'e' 'PS>tommy' e poi
       'PS>cls': il tommy che sta girando ADESSO e' un secondo lancio che non e' ancora
       stato scaricato sul file, perche' il transcript scarica quando il prompt torna e in
       quella scheda non e' piu' tornato. Fidarsi dell'ultima riga darebbe 'cls'.

    La difesa contro tutt'e due e' la stessa, ed e' STRUTTURALE invece che una lista di
    parole da mantenere: la riga vale solo se dopo di lei nel transcript non e' stato
    ristampato un prompt. Un prompt ristampato significa che il comando e' finito e la
    console e' tornata alla persona, cioe' che quella riga non descrive piu' cosa c'e'
    dentro la scheda.

    Torna sempre un oggetto: Riga (l'ultima digitata, anche se stantia), Fresca (nessun
    prompt comparso dopo), Righe (quante ne ha viste). Riga $null = transcript muto.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Slot,
        [string]$Path   # per le prove: un file al posto dello scrollback dello slot
    )
    if (-not $Path) { $Path = Join-Path (Get-STSlotDir $Slot) 'scrollback.log' }
    $esito = [pscustomobject]@{ Riga = $null; Fresca = $false; Righe = 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return $esito }
    $riga = $null; $n = 0; $promptDopo = $false; $promptVisti = 0
    try {
        # Il file e' APERTO IN SCRITTURA dalla shell che lo sta registrando: senza
        # condivisione esplicita la lettura solleva IOException e Get-STLiveTab morirebbe
        # sulla propria scheda. Misurato il 01/09: succede su tutti gli slot vivi.
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                              ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            $sr = New-Object IO.StreamReader($fs)
            while ($null -ne ($l = $sr.ReadLine())) {
                if ($l.StartsWith('PS>')) {
                    $t = $l.Substring(3).Trim()
                    if ($t) { $riga = $t; $n++; $promptDopo = $false }
                    continue
                }
                # Un prompt RISTAMPATO: "PS <qualcosa>>" a fine riga. Non e' una riga
                # digitata (quelle iniziano con 'PS>' senza spazio) ed e' il segno che il
                # comando precedente ha restituito la console.
                if ($l -match 'PS\s[^>]*>\s*$') { $promptDopo = $true; $promptVisti++ }
            }
            $sr.Dispose()
        } finally { $fs.Dispose() }
    } catch { return $esito }
    # La freschezza vuole una PROVA, non un'assenza: se in tutto il transcript non si e'
    # mai riconosciuto un prompt ristampato, allora "nessun prompt dopo" non significa
    # "il comando gira ancora" - significa che il prompt di questa macchina non lo so
    # leggere. In quel caso si tace e parla l'anello dopo, invece di spacciare per fresca
    # una riga che potrebbe essere di tre settimane fa.
    [pscustomobject]@{
        Riga   = $riga
        Fresca = [bool]($riga -and -not $promptDopo -and $promptVisti -gt 0)
        Righe  = $n
    }
}

function Get-STNameFromLine {
    <#
    .SYNOPSIS
    Il nome breve che una riga digitata puo' dare a una scheda, oppure niente.

    .DESCRIPTION
    Una riga digitata e' ottima come etichetta quando e' una parola sola (frank, tommy,
    cattura): e' il nome che la persona usa per quella cosa. E' pessima quando e' una riga
    di comando, e accorciarla sarebbe di nuovo indovinare - la famiglia di rimedi che la
    PROVA del 30/08 ha smentito.

    Quindi qui non si accorcia niente: o la riga E' gia' un nome, o non se ne cava un nome
    e parla l'anello dopo. La riga INTERA resta comunque disponibile come intenzione per la
    firma, dove serve distinguere e non leggere.
    #>
    [CmdletBinding()]
    param([string]$Riga)
    if (-not $Riga) { return $null }
    $t = $Riga.Trim()
    if ($t.Length -eq 0 -or $t.Length -gt 40) { return $null }
    # una parola sola, che non sia un pezzo di percorso o di sintassi PowerShell
    if ($t -notmatch '^[A-Za-z][A-Za-z0-9._-]*$') { return $null }
    $t
}

function Get-STNameFromLaunch {
<#
.SYNOPSIS
Il bersaglio del LANCIO letto dalla riga di comando del figlio, oppure niente.

.DESCRIPTION
Il nome di una scheda NON sta nella forma dell'albero dei processi: tre regole che
ci hanno provato sono cadute (PROVA 30/08 - eta', mestiere, stabilita'). Due alberi
identici nella forma (cmd -> un figlio) portano nomi diversi, e la differenza sta
SCRITTA nella riga di comando del nodo dove la discesa si ferma gia' oggi. Per
questo qui non si scende di un livello: si legge meglio il nodo di sempre.

Forme riconosciute, tutte misurate sulle 21 schede vive del 18/09
(DISEGNO-livetab-2026-09-18 sez.3):
  F1  cmd.exe  -> il primo token che finisce in .cmd/.bat/.ps1
  F2  python   -> la cartella che contiene .venv, altrimenti il primo argomento .py
  F3  node     -> il primo .js/.mjs FUORI da node_modules
  F4  il resto -> $null, e chi chiama tiene il nome dell'exe (comportamento di oggi)

STESSA DISCIPLINA di Get-STNameFromLine, e vale piu' di ogni forma: forma non
riconosciuta -> $null, mai un nome indovinato. Un nome sbagliato costa piu' di
nessun nome, perche' ci si fida.
#>
[CmdletBinding()]
param([string]$Riga, [string]$Exe)
if (-not $Riga -or -not $Exe) { return $null }

# Le virgolette sono rumore e arrivano anche annidate (cmd /c ""C:\x.cmd""): tolte
# tutte, i token tornano separati dagli spazi. Il percorso dell'interprete invece si
# legge PRIMA di toglierle, perche' "C:\Program Files\..." ha uno spazio dentro e
# spezzarlo darebbe "C:\Program" -- un nome vero al posto sbagliato.
$nudo   = $Riga -replace '"', ''
$pezzi  = @($nudo -split '\s+' | Where-Object { $_ })
if ($Riga -match '^\s*"([^"]+)"') { $primo = $Matches[1] } elseif ($pezzi) { $primo = $pezzi[0] } else { $primo = '' }

# La foglia di un percorso, senza estensione. Fatta a mano e non con Split-Path
# perche' qui arrivano anche separatori '/' (node li mescola: nodejs/node_modules/...).
function local:Foglia([string]$p) {
    $f = @($p -split '[\\/]')[-1]
    $f -replace '\.[^.]+$', ''
}

if ($Exe -ieq 'cmd.exe') {
    # F1. Non si guarda /c o /k: se c'e' uno script e' quello il bersaglio, e se non
    # c'e' (cmd /c dir) si tace, che e' esattamente il comportamento di oggi.
    $s = @($pezzi | Where-Object { $_ -imatch '\.(cmd|bat|ps1)$' })[0]
    if ($s) { return (Foglia $s) }
    return $null
}

if ($Exe -imatch '^(python|python3|py)\.exe$') {
    # F2. La cartella del .venv batte il nome dello script: chatbot, FrankByMail e
    # comfyui lanciano tutti e tre un 'main.py', e chiamarle tutte 'main' sarebbe
    # PEGGIO di 'python' -- tre schede ambigue con un nome nuovo (sez.4, caso 3).
    if ($primo -imatch '^(.*)[\\/]\.venv[\\/]') { return (Foglia $Matches[1]) }
    $s = @($pezzi | Where-Object { $_ -imatch '\.py$' })[0]
    if ($s) { return (Foglia $s) }
    return $null
}

if ($Exe -ieq 'node.exe') {
    # F3. Uno script dentro node_modules non e' il nome del programma: 'npm-cli' non
    # dice niente a nessuno, e il nome parlante sta nel package.json, cioe' FUORI
    # dall'albero (sez.1a, eccezione 32896). Li' si tace e resta 'node'.
    $s = @($pezzi | Where-Object { $_ -imatch '\.(js|mjs)$' })[0]
    if (-not $s) { return $null }
    if ($s -imatch '[\\/]node_modules[\\/]') { return $null }
    return (Foglia $s)
}

# F4: tutto il resto -- caddy, Server.Loader, MikuSB. L'exe e' gia' il nome.
return $null
}

#endregion

# I nomi che non nominano niente: sono il nome di un INTERPRETE, non di un lavoro.
# Servono a D1b -- un Title generico nel meta non e' un nome, e' silenzio. Non e' una
# lista di cose vietate: se la persona chiama DAVVERO una scheda 'cmd', il nome del
# lancio vince e basta rinominarla con una parola non generica per riavere il titolo.
$script:STNomiGenerici = @('cmd', 'node', 'python', 'powershell', 'pwsh', 'shell', 'bash')

# Un nome generico non e' un nome: e' il nome di un interprete. Esportata perche' la
# guardia del titolo muto (D2, 22/09) deve valere la stessa lista nella UI e nel modulo.
function Test-STNomeGenerico { param([string]$Nome) [bool]($Nome -and ($Nome.Trim() -in $script:STNomiGenerici)) }

# Elenca i tab shell aperti (powershell/pwsh) con cosa ci gira dentro e dove. Sorgente =
# scansione processi (PEB + Win32_Process): mostra ANCHE i tab non registrati o occupati.
function Get-STLiveTab {
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate, ExecutablePath
    if (-not $all) { return @() }
    $kids = @{}
    foreach ($p in $all) { $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = @() }; $kids[$k] += $p }
    # Indice per pid: serve a OSSERVARE il padre diretto di ogni shell -- il terminale
    # in cui il tab vive (22/09, canale: un salto solo, misurato il 30/08 sul Mostro e
    # oggi qui). Niente deduzioni sul nome del processo: si registra il percorso che c'e'.
    $perPid = @{}
    foreach ($p in $all) { $perPid[[int]$p.ProcessId] = $p }
    $skip = @('conhost.exe', 'OpenConsole.exe')
    # Gli slot si leggono UNA volta per tutta la scansione: sono ~430 cartelle, e
    # rileggerle per ogni shell trasformerebbe una lista in un'attesa.
    $slotsTutti = @()
    if (Test-Path -LiteralPath $script:STRoot) {
        $slotsTutti = @(Get-ChildItem -LiteralPath $script:STRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Read-STMeta $_.Name } | Where-Object { $_ -and $_.Pid })
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in ($all | Where-Object { $_.Name -in 'powershell.exe', 'pwsh.exe' })) {
        $child = $null
        $q = New-Object System.Collections.Queue
        foreach ($c in $kids[[int]$s.ProcessId]) { $q.Enqueue($c) }
        while ($q.Count -gt 0) {
            $c = $q.Dequeue()
            if ($c.Name -in $skip) { foreach ($g in $kids[[int]$c.ProcessId]) { $q.Enqueue($g) }; continue }
            $child = $c; break
        }
        # $lancio si azzera a ogni giro: e' una variabile di ciclo, e una che sopravvive
        # all'iterazione presterebbe il nome della scheda precedente a quella senza figlio.
        $lancio = $null
        if ($child) {
            $cwd = Get-STCwdSafe ([int]$child.ProcessId); if (-not $cwd) { $cwd = Get-STCwdSafe ([int]$s.ProcessId) }
            $cmd = ConvertTo-STRunnable $child.CommandLine
            # D1 (DISEGNO 18/09): il nome del LANCIO, non il nome dell'eseguibile. La riga
            # di comando e' gia' qui -- e' la stessa che ConvertTo-STRunnable riceve sopra,
            # e fin qui veniva buttata tenendo solo il nome dell'exe. Se la forma non e'
            # riconosciuta $lancio resta $null e di qui esce esattamente quello che usciva
            # prima, carattere per carattere.
            $lancio = Get-STNameFromLaunch -Riga $child.CommandLine -Exe $child.Name
            $what = if ($lancio) { $lancio } else { $child.Name -replace '\.exe$', '' }
        } else {
            $cwd = Get-STCwdSafe ([int]$s.ProcessId); $cmd = $null; $what = 'shell'
        }

        # --- LA CATENA DEL NOME. L'ultimo anello e' $what com'era: se le sorgenti nuove
        # tacciono, di qui esce esattamente quello che usciva prima.
        # Le sorgenti nuove del NOME parlano SOLO se la scheda ha un figlio vivo. Senza
        # figlio la scheda e' sopravvissuta al suo programma, e li' un nome ricordato
        # sarebbe vero ieri e falso oggi: il nome tace, come ha sempre fatto.
        # La RICETTA invece non va stantia -- "cio' che la scheda e' stata APERTA per fare"
        # e' un fatto di lancio, vero ieri come oggi (D1c, ratifica 22/09): per lei il
        # lookup dello slot si fa SEMPRE, figlio o no.
        $intento = $null
        # 'lancio' e' il valore nuovo del 18/09: dice che il nome viene dalla riga di
        # comando del figlio. Resta 'processo' quando la forma non e' riconosciuta, cioe'
        # esattamente quando $what e' ancora il nome dell'exe come ieri.
        # (22/09) Fonte dice da quale anello viene il NOME -- e da oggi e' vero davvero:
        # si muove solo dove si muove $what, mai con l'Intento (terzo punto del disegno 18/09).
        $fonte   = if ($lancio) { 'lancio' } else { 'processo' }
        $slot = Get-STSlotForPid -ProcId ([int]$s.ProcessId) -ProcName $s.Name -ProcStart $s.CreationDate -Slots $slotsTutti
        if ($slot) {
            # anello 1: il meta dello slot. Il Command e' esatto per costruzione; il
            # Title e' il nome che la persona ha gia' dato a questa cosa.
            $mCmd = if ($slot.Command) { ([string]$slot.Command).Trim() } else { '' }
            $mTit = if ($slot.Title)   { ([string]$slot.Title).Trim() }   else { '' }
            if ($mCmd) { $intento = $mCmd }
            elseif ($mTit) { $intento = $mTit }
            if ($child) {
                # D1b (DISEGNO 18/09): un Title GENERICO non e' un nome, e' silenzio. Senza
                # questa riga 4 delle 8 schede 'cmd' del 18/09 restavano 'cmd': il Title
                # sporco nel meta vince sul nome del lancio -- e si riproduce a ogni
                # resume (workspace sporco -> meta sporco -> anello 1 lo riverisce).
                $nome = if ($mTit -and ($mTit -notin $script:STNomiGenerici)) { $mTit } else { $null }
                if ($nome) { $what = $nome; $fonte = 'meta' }
                # anello 2: l'ultima riga digitata, se e' ancora quella che comanda.
                if (-not $intento -or -not $nome) {
                    $r = Get-STLastTypedLine -Slot $slot.Slot
                    if ($r.Fresca) {
                        if (-not $intento) { $intento = $r.Riga }
                        if (-not $nome) {
                            $nome = Get-STNameFromLine $r.Riga
                            if ($nome) { $what = $nome; $fonte = 'prompt' }
                        }
                    }
                }
            } else {
                # D1c (ratifica 22/09, forma piena): la scheda senza figlio conserva la
                # RICETTA dal meta -- Intento e Command, cosi' la firma torna identica a
                # quella che aveva da viva e salvarla non perde il rilancio. Il NOME no:
                # What resta 'shell' e Fonte resta 'processo', perche' 'python' sarebbe
                # vero ieri e falso oggi. Mostrarlo spento resta lavoro della riga UI.
                if ($mCmd) { $cmd = $mCmd }
            }
        }

        $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }
        $out.Add([pscustomobject]@{
            Pid     = [int]$s.ProcessId
            Cwd     = $cwd
            Command = $cmd
            What    = $what
            # L'intenzione di lancio: cio' che la scheda e' stata APERTA per fare, letto e
            # non dedotto. Entra nella firma (v. Get-STTabSignature), perche' riparare solo
            # l'etichetta non toglie un doppione: etichetta e firma sono separate.
            Intento = $intento
            # Da quale anello viene il NOME: 'meta' (Title vero dello slot), 'prompt'
            # (transcript), 'lancio' (riga di comando del figlio, 18/09), 'processo'
            # (ripiego: nome dell'exe, o 'shell' senza figlio). Dal 22/09 il campo e'
            # coerente col suo contratto: si muove solo dove si muove $what -- prima lo
            # assegnava la logica dell'INTENTO, e un nome nato dal lancio poteva portare
            # Fonte='meta' (visto dal manovale il 18/09, punto 4).
            Fonte   = $fonte
            # La shell VERA del tab: qui si distingue gia' powershell.exe da pwsh.exe
            # (v. il filtro sopra), ma prima non usciva da questa funzione -- e allora
            # tutto arrivava al motore come 'powershell.exe', firma compresa. Referto
            # Tommaso 13/08, rilievo 1: una firma che dichiara di guardare la shell e
            # non la vede mai e' peggio che non guardarla, perche' ci si fida.
            Shell   = $s.Name
            # Il canale: il percorso del processo PADRE, osservato (22/09). Fuori da un
            # terminale registra il padre che c'e' -- dato, non ipotesi. Lo legge chi
            # cattura un'area: l'area segue il terminale della cattura (regola 30/08).
            Terminale = if ($perPid[[int]$s.ParentProcessId]) { [string]$perPid[[int]$s.ParentProcessId].ExecutablePath } else { $null }
            Label   = "$leaf  -  $what  [pid $($s.ProcessId)]"
        })
    }
    $out
}

# Aggiunge uno o piu' tab a un'area (la crea se non esiste). Per la UI "aggiungi a gruppo".
# Tavolozza colori distinti per i tab (formato #rrggbb, onorato da wt --tabColor).
$script:STPalette = @('#1FAA55','#2D7D9A','#3B7DD8','#8E44AD','#E67E22','#C0392B','#16A085','#D4A017','#E84393','#2C3E50','#7F8C8D','#2980B9')

function Get-STTabSignature {
    <#
    .SYNOPSIS
    La "ricetta" di un tab: cartella + shell + comando, normalizzati.

    .DESCRIPTION
    NON e' l'identita' del tab, ed e' importante non confonderle: due tab aperti di
    proposito nella stessa cartella con lo stesso comando hanno la STESSA ricetta e
    sono due tab diversi. Questa firma serve a dire "ricetta gia' presente", che e'
    un'altra frase da "gia' appartenente" (quella richiedera' un identificatore stabile,
    fase 2). Referto Tommaso 13/08, rilievo 2.

    Regole di normalizzazione, e i loro perche':
      Cwd     - sintattica soltanto: separatori uniformati, barra finale tolta salvo
                la radice di un drive, confronto senza distinzione di maiuscole.
                MAI Resolve-Path: dipenderebbe da cosa esiste in questo momento e dai
                collegamenti del filesystem, cioe' la firma cambierebbe nel tempo.
      Shell   - token senza distinzione di maiuscole; due eseguibili in cartelle diverse
                NON sono la stessa shell, quindi il percorso non si tocca.
      Command - null e stringa vuota sono la stessa cosa ("nessun comando"); per il resto
                solo trim esterno e confronto CASE-SENSITIVE. Gli argomenti possono essere
                sensibili alle maiuscole, e un falso negativo (due ricette che restano
                distinte) costa meno che fondere due ricette diverse.

    Con Command assente la firma e' DEBOLE: distingue solo per cartella e shell.

    Intento - QUARTA parte, e c'e' solo quando c'e' (01/09). E' l'intenzione di lancio
              letta dallo slot: il comando che STerminal ha scritto lui, o la riga che la
              persona ha digitato. Serve perche' riparare l'etichetta NON toglie un
              doppione: la firma non guarda il Title, quindi un nome giusto sull'etichetta
              lascia intero il difetto 3 del ticket. Regola presa dal disegno (sez.4.2) e
              non lasciata all'implementazione: si usa la riga INTERA, argomenti compresi.
              Chi la accorcia rifonde 'frank' con 'frank -eastwood -Grande' e riapre il
              difetto dentro il rimedio.
              Quando l'intento manca la firma e' IDENTICA a quella di prima, carattere per
              carattere: le aree gia' salvate continuano a combaciare.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Tab,
        [switch]$SenzaIntento   # la firma a tre parti, per confrontarsi con le voci vecchie
    )

    $cwd = if ($null -ne $Tab.Cwd) { ([string]$Tab.Cwd).Trim() } else { '' }
    if ($cwd) {
        $cwd = $cwd.Replace('/', '\')
        # Collasso di "." e ".." SINTATTICO (referto Tommaso 13/08, rilievo 3):
        # C:\a\..\b e C:\b sono la stessa cartella e devono avere la stessa ricetta.
        # A mano e non con Resolve-Path/GetFullPath, perche' quelli guardano il disco:
        # dipenderebbero da cosa esiste ADESSO e dalla cartella corrente del processo,
        # cioe' la firma cambierebbe nel tempo e da chi la calcola.
        $prefisso = ''
        $resto    = $cwd
        # La barra dopo il drive si conserva SOLO se c'era: "C:\" e' la radice, "C:" e' la
        # cartella corrente su quel drive. Sono due posti diversi e non vanno fusi --
        # stessa regola del comando: meglio due ricette che restano distinte.
        if ($cwd -match '^([A-Za-z]:)(\\?)(.*)$') {         # C:  oppure C:\...
            $prefisso = $matches[1] + $matches[2]; $resto = $matches[3]
        } elseif ($cwd -match '^(\\\\[^\\]+\\[^\\]+)\\?(.*)$') {  # \\server\condivisione
            $prefisso = $matches[1] + '\'; $resto = $matches[2]
        }
        $pila = [System.Collections.Generic.List[string]]::new()
        foreach ($seg in ($resto -split '\\')) {
            if ($seg -eq '' -or $seg -eq '.') { continue }
            if ($seg -eq '..') {
                # Sopra la radice non si sale: C:\..\.. resta C:\ .
                # Su percorso relativo l'ultimo segmento si toglie solo se non e' gia'
                # un '..': altrimenti '..\..' si mangerebbe da solo e diventerebbe vuoto,
                # cioe' due cartelle sopra si trasformerebbero in "qui".
                # "Radice" vuol dire prefisso che FINISCE con la barra: solo sopra
                # quella non si sale. "C:..\x" ha il drive ma non la barra, ed e' relativo
                # alla cartella corrente di quel drive: li' il '..' va conservato, se no
                # diventerebbe "C:x", che e' un'altra cartella (referto 13/08, rilievo 1).
                $radice = $prefisso -and $prefisso.EndsWith('\')
                if ($pila.Count -and ($radice -or $pila[$pila.Count-1] -ne '..')) {
                    $pila.RemoveAt($pila.Count - 1)
                } elseif (-not $radice) { [void]$pila.Add('..') }
                continue
            }
            [void]$pila.Add($seg)
        }
        $cwd = $prefisso + ($pila -join '\')
        # La radice di un drive ("C:\") tiene la sua barra; tutto il resto la perde.
        if ($cwd.Length -gt 3 -and $cwd.EndsWith('\')) { $cwd = $cwd.TrimEnd('\') }
        $cwd = $cwd.ToLowerInvariant()
    }
    $shell = if ($Tab.Shell) { ([string]$Tab.Shell).Trim().ToLowerInvariant() } else { 'powershell.exe' }
    $cmd   = if ($null -ne $Tab.Command) { ([string]$Tab.Command).Trim() } else { '' }
    # Il separatore e' un carattere che non puo' comparire in un percorso Windows.
    $base = "$cwd|$shell|$cmd"
    if ($SenzaIntento) { return $base }
    # Hashtable e pscustomobject non si interrogano allo stesso modo, e qui arrivano
    # tutt'e due (le righe della finestra sono hashtable).
    $int = $null
    if ($Tab -is [System.Collections.IDictionary]) { if ($Tab.Contains('Intento')) { $int = $Tab['Intento'] } }
    elseif ($Tab.PSObject.Properties['Intento'])   { $int = $Tab.Intento }
    $int = if ($null -ne $int) { ([string]$int).Trim() } else { '' }
    # Senza intento la firma resta quella di prima: nessuna coda vuota, se no ogni voce
    # vecchia smetterebbe di combaciare con se stessa.
    if (-not $int) { return $base }
    "$base|$int"
}

function Test-STWeakSignature {
    # Vero quando la ricetta non ha comando: distingue solo cartella e shell, quindi
    # due voci "uguali" possono benissimo essere due cose diverse. Serve a DIRLO,
    # non a cambiare comportamento.
    param([Parameter(Mandatory)][object]$Tab)
    -not ($null -ne $Tab.Command -and ([string]$Tab.Command).Trim())
}

# Tavolozza per il colore dell'AREA: e' un'altra cosa dal colore del tab (Tab.Color, che
# finisce a `wt --tabColor` quando si riapre). Referto Tommaso 13/08, rilievo 4: se si
# usasse lo stesso campo, cambiare l'appartenenza cambierebbe anche come si riapre il tab.
$script:STAreaPalette = @('#3B7DD8','#1FAA55','#E67E22','#8E44AD','#C0392B','#16A085','#D4A017','#E84393','#2D7D9A','#7F8C8D')

function Set-STWorkspaceColor {
    <#
    .SYNOPSIS
    Assegna (o cambia) il colore con cui l'area si riconosce a colpo d'occhio.
    .DESCRIPTION
    Senza -Color ne sceglie uno non ancora usato da altre aree. Non tocca i colori dei
    singoli tab.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [string]$Color)

    # Un colore che WPF non sa convertire non fa rumore: la riga resta senza sfondo,
    # perche' la finestra ha un catch che la salva. Il difetto sarebbe MUTO, quindi si
    # rifiuta all'ingresso invece di finire nel file (referto 13/08, rilievo 2).
    if ($Color -and $Color -notmatch '^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$') {
        throw "colore non valido: '$Color'. Atteso #RRGGBB o #AARRGGBB."
    }
    $dir = Get-STWorkspaceDir $Name
    $wj  = Join-Path $dir 'workspace.json'
    if (-not (Test-Path -LiteralPath $wj)) { throw "area '$Name' inesistente" }
    $ws = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
    if (-not $Color) {
        $presi = @(Get-STWorkspace | Where-Object { $_.Name -ne $Name } | ForEach-Object { $_.UiColor } | Where-Object { $_ })
        $Color = $script:STAreaPalette | Where-Object { $presi -notcontains $_ } | Select-Object -First 1
        if (-not $Color) { $Color = $script:STAreaPalette[(@(Get-STWorkspace).Count) % $script:STAreaPalette.Count] }
    }
    # Il campo puo' non esistere nei file scritti prima d'ora: si aggiunge senza migrare
    # nulla e senza toccare i tab.
    if ($ws.PSObject.Properties.Name -contains 'UiColor') { $ws.UiColor = $Color }
    else { $ws | Add-Member -NotePropertyName UiColor -NotePropertyValue $Color }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wj -Encoding utf8
    $Color
}

function Get-STLiveTabAreas {
    <#
    .SYNOPSIS
    Per ogni tab vivo, le aree che contengono una voce con la STESSA RICETTA.

    .DESCRIPTION
    ⚠️ Dice "ricetta compatibile", NON "e' proprio quel tab": finche' non esiste un
    identificatore stabile (fase 3), due tab gemelli aperti di proposito nella stessa
    cartella sono indistinguibili. Chi mostra questo dato deve dirlo come lo dice qui.
    Ritorna i tab vivi con in piu': Aree (nomi), AreaColor (colore della prima), Certezza.
    #>
    [CmdletBinding()]
    param([object[]]$LiveTabs, [object[]]$Aree)

    if (-not $PSBoundParameters.ContainsKey('LiveTabs')) { $LiveTabs = @(Get-STLiveTab) }
    if (-not $PSBoundParameters.ContainsKey('Aree'))     { $Aree     = @(Get-STWorkspace) }

    # DUE indici, perche' due sono i gradi di riconoscimento possibili oggi.
    #
    # Il secondo esiste per un motivo misurato sul campo (13/08): nell'area `sistema`,
    # salvata a giugno, i comandi hanno gli argomenti fra apici; i processi vivi no.
    #   area:      python.exe 'C:\projects\chatbot\main.py'
    #   processo:  python.exe  C:\projects\chatbot\main.py
    # Stesso comando, scritto diverso -> la ricetta non combaciava, e cinque tab su sei
    # restavano spenti. Le virgolette NON si normalizzano (referto Tommaso, rilievo 2:
    # riscrivere gli argomenti rischia di fondere comandi che non sono lo stesso), quindi
    # si aggiunge un grado piu' debole invece di ammorbidire quello preciso.
    # Ordinal, non @{}: una hashtable di PowerShell confronta le chiavi SENZA distinguere
    # le maiuscole, e avrebbe annullato proprio la regola che Add difende sul comando.
    $perFirma = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    # Terzo indice, a tre parti, per le voci salvate PRIMA del 01/09 (quelle senza intento):
    # una scheda che oggi porta un intento non combacia piu' con la propria riga vecchia, e
    # senza questo ripiego smetterebbe di risultare "gia' in quell'area".
    $perFirmaVecchia = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    $perCwd   = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($a in $Aree) {
        foreach ($t in @($a.Tabs)) {
            if (-not $t) { continue }
            $voce = [pscustomobject]@{ Name = $a.Name; UiColor = $a.UiColor }
            $f = Get-STTabSignature $t
            if (-not $perFirma.ContainsKey($f)) { $perFirma[$f] = [System.Collections.Generic.List[object]]::new() }
            if ($perFirma[$f].Name -notcontains $a.Name) { [void]$perFirma[$f].Add($voce) }
            $tHaIntento = [bool]($t.PSObject.Properties['Intento'] -and $t.Intento -and ([string]$t.Intento).Trim())
            if (-not $tHaIntento) {
                $fv = Get-STTabSignature $t -SenzaIntento
                if (-not $perFirmaVecchia.ContainsKey($fv)) { $perFirmaVecchia[$fv] = [System.Collections.Generic.List[object]]::new() }
                if ($perFirmaVecchia[$fv].Name -notcontains $a.Name) { [void]$perFirmaVecchia[$fv].Add($voce) }
            }
            # solo la cartella: la parte della ricetta che non dipende da come e' scritto
            $c = Get-STTabSignature @{ Cwd = $t.Cwd; Shell = 'x'; Command = $null }
            if (-not $perCwd.ContainsKey($c)) { $perCwd[$c] = [System.Collections.Generic.List[object]]::new() }
            if ($perCwd[$c].Name -notcontains $a.Name) { [void]$perCwd[$c].Add($voce) }
        }
    }
    foreach ($lt in @($LiveTabs)) {
        # Il null va tolto PRIMA di contare: @($hash['assente']) e' @($null), Count 1.
        $trovate = @($perFirma[(Get-STTabSignature $lt)] | Where-Object { $_ })
        $grado   = 'ricetta'
        if (-not $trovate.Count) {
            # ripiego 1: la ricetta a tre parti, contro le voci vecchie senza intento.
            # Stessa forza di prima, quindi stesso grado.
            $trovate = @($perFirmaVecchia[(Get-STTabSignature $lt -SenzaIntento)] | Where-Object { $_ })
        }
        if (-not $trovate.Count) {
            # ripiego: stessa cartella. Piu' largo -- due tab aperti nella stessa cartella
            # risultano entrambi "gia' in quell'area" -- ma per non riaggiungere qualcosa
            # per sbaglio un avviso in piu' e' meglio di un riconoscimento mancato.
            $trovate = @($perCwd[(Get-STTabSignature @{ Cwd = $lt.Cwd; Shell = 'x'; Command = $null })] | Where-Object { $_ })
            $grado   = if ($trovate.Count) { 'cartella' } else { 'nessuna' }
        }
        [pscustomobject]@{
            Pid       = $lt.Pid
            Cwd       = $lt.Cwd
            Command   = $lt.Command
            What      = $lt.What
            Intento   = $lt.Intento
            Fonte     = $lt.Fonte
            Shell     = $lt.Shell
            Terminale = $lt.Terminale
            Label     = $lt.Label
            Aree      = @($trovate | Where-Object { $_ } | ForEach-Object { $_.Name })
            AreaColor = @($trovate | Where-Object { $_ -and $_.UiColor } | ForEach-Object { $_.UiColor })[0]
            # 'ricetta' = cartella+shell+comando · 'cartella' = solo la cartella
            # fase 3: 'identita' quando esistera' un EntryId
            Certezza  = $grado
        }
    }
}

function Get-STLiveRowSpec {
    <#
    .SYNOPSIS
    Come si scrive e si colora una riga della lista "Tab aperti".

    .DESCRIPTION
    Sta nel modulo, e non dentro la finestra, per un motivo preciso: e' il pezzo che
    realizza la cosa chiesta -- vedere a colpo d'occhio cosa e' gia' in un'area -- e
    dentro un gestore WPF non lo proverebbe nessuno (referto §9-10.1, rilievo 5).

    Il TESTO dichiara quanto ne sappiamo: senza suffisso quando la ricetta combacia
    (cartella + shell + comando), con "(stessa cartella)" quando e' solo il ripiego.
    Cinque dei sei tab riconosciuti oggi stanno nel secondo caso, e la riga non deve
    farli sembrare certi (rilievo 2).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tab)

    $aree = @($Tab.Aree | Where-Object { $_ })
    if (-not $aree.Count) {
        return [pscustomobject]@{ Testo = [string]$Tab.Label; Colore = $null; Certezza = 'nessuna' }
    }
    $suffisso = if ($Tab.Certezza -eq 'cartella') { '  (stessa cartella)' } else { '' }
    [pscustomobject]@{
        Testo    = "$($Tab.Label)   in: $($aree -join ', ')$suffisso"
        Colore   = $Tab.AreaColor
        Certezza = $Tab.Certezza
    }
}

function Add-STWorkspaceTab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Tabs,
        [switch]$AutoColor,       # assegna a ogni tab senza colore il prossimo colore distinto della tavolozza
        [switch]$AllowDuplicate   # aggiunge anche cio' che c'e' gia': i gemelli VOLUTI
    )
    # IDEMPOTENTE PER DEFAULT (referto Tommaso 13/08, rilievo 3). Prima accodava sempre,
    # e nelle aree di Vittorio si erano formate coppie identiche: `Riprendi` apriva quattro
    # claude nella stessa cartella. La difesa sta QUI e non nell'interfaccia, perche'
    # questa funzione e' esportata e chiamabile a comandi: una difesa che vive solo nella
    # UI protegge una strada sola.
    # Chi vuole davvero due tab gemelli lo dice con -AllowDuplicate: un gesto deliberato,
    # non un caso.
    $dir = Get-STWorkspaceDir $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $wj = Join-Path $dir 'workspace.json'
    $list = [System.Collections.Generic.List[object]]::new()
    $uiColor = $null
    if (Test-Path -LiteralPath $wj) {
        $existing = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
        foreach ($t in @($existing.Tabs)) { if ($t) { $list.Add($t) } }
        $uiColor = $existing.UiColor    # il colore dell'area non si perde riaggiungendo tab
    }
    # Ordinal: il comando distingue le maiuscole (v. Get-STTabSignature).
    $firme = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # Secondo indice, a tre parti, e SOLO per le voci gia' salvate che NON hanno intento:
    # sono le voci scritte prima del 01/09. Senza di lui una scheda che oggi porta un
    # intento non combacerebbe piu' con la propria riga nell'area, e verrebbe riaggiunta:
    # cioe' il rimedio ai doppioni ne fabbricherebbe uno. Le voci CON intento non entrano
    # qui, cosi' due intenti diversi restano due ricette diverse.
    $firmeVecchie = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $haIntento = {
        param($v)
        if ($null -eq $v) { return $false }
        $i = if ($v -is [System.Collections.IDictionary]) { if ($v.Contains('Intento')) { $v['Intento'] } else { $null } }
             elseif ($v.PSObject.Properties['Intento']) { $v.Intento } else { $null }
        [bool]($null -ne $i -and ([string]$i).Trim())
    }
    foreach ($e in $list) {
        [void]$firme.Add((Get-STTabSignature $e))
        if (-not (& $haIntento $e)) { [void]$firmeVecchie.Add((Get-STTabSignature $e -SenzaIntento)) }
    }

    $used = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $list) { if ($e.Color) { [void]$used.Add([string]$e.Color) } }

    $aggiunti = 0; $saltati = 0; $deboli = 0
    foreach ($t in $Tabs) {
        if (-not $AllowDuplicate) {
            $firma = Get-STTabSignature $t
            $firmaVecchia = Get-STTabSignature $t -SenzaIntento
            # Il controllo vale anche DENTRO il lotto: due voci uguali passate insieme
            # sono un doppione quanto una gia' presente sul disco.
            if ($firme.Contains($firma) -or $firmeVecchie.Contains($firmaVecchia)) {
                $saltati++
                if (Test-STWeakSignature $t) { $deboli++ }
                continue
            }
            [void]$firme.Add($firma)
            if (-not (& $haIntento $t)) { [void]$firmeVecchie.Add($firmaVecchia) }
        }
        $color = $t.Color
        if ($AutoColor -and -not $color) {
            $color = $script:STPalette | Where-Object { $used -notcontains $_ } | Select-Object -First 1
            if (-not $color) { $color = $script:STPalette[$list.Count % $script:STPalette.Count] }
            [void]$used.Add($color)
        }
        $intentoT = if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('Intento')) { $t['Intento'] } else { $null } }
                    elseif ($t.PSObject.Properties['Intento']) { $t.Intento } else { $null }
        $fonteT = if ($t -is [System.Collections.IDictionary]) { if ($t.Contains('Fonte')) { $t['Fonte'] } else { $null } }
                  elseif ($t.PSObject.Properties['Fonte']) { $t.Fonte } else { $null }
        $titleT = $t.Title
        # D2b (22/09): la stessa guardia della UI, ma qui, perche' questa funzione e'
        # esportata e chiamabile a comandi -- una difesa che vive solo nella UI protegge
        # una strada sola. Un Title GENERICO ('cmd','node','python',...) nato dal ripiego
        # muto (Fonte='processo') non e' un nome: non si salva come Title. Si salva vuoto,
        # che dice "non so": onesto, e la firma non cambia (il Title non entra nella
        # firma). Un Title scritto dalla persona non arriva mai con Fonte='processo'
        # (la UI marca 'persona'), quindi la mano resta libera.
        if ($titleT -and ([string]$titleT).Trim() -and (([string]$titleT).Trim() -in $script:STNomiGenerici) -and $fonteT -eq 'processo') {
            Write-Warning "STerminal: Title '$titleT' con Fonte=processo e' il ripiego muto, non un nome: salvato senza titolo (D2b)."
            $titleT = ''
        }
        $list.Add([pscustomobject]@{
            Title   = $titleT
            Color   = $color
            Cwd     = $t.Cwd
            Shell   = if ($t.Shell) { $t.Shell } else { 'powershell.exe' }
            Command = $t.Command
            # L'intento si SALVA, se no la prossima cattura ripartirebbe da zero e la
            # riga non combacerebbe piu' con se stessa.
            Intento = $intentoT
            # Anche Fonte viaggia (22/09): senza di lui un Title 'cmd' salvato era
            # indistinguibile da uno scelto dalla persona, e la guardia qui sopra non
            # avrebbe avuto da dove leggere.
            Fonte   = $fonteT
            Storico = $null
        })
        $aggiunti++
    }
    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $list; UiColor = $uiColor }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wj -Encoding utf8
    # Un'area senza colore non si riconosce nella lista dei tab vivi: se ne prende uno
    # non ancora usato dalle altre. Il colore dell'AREA, non quello dei tab.
    if (-not $uiColor) { [void](Set-STWorkspaceColor -Name $Name) }

    $msg = "STerminal: $aggiunti tab aggiunti all'area '$Name' (totale $($list.Count))."
    if ($saltati) {
        $msg += " $saltati gia' presenti, saltati."
        # Un salto muto somiglia a un guasto: se la ricetta era debole (nessun comando)
        # va detto, perche' li' "uguale" significa solo "stessa cartella e stessa shell".
        if ($deboli) { $msg += " Di questi $deboli senza comando: ricetta debole, usa -AllowDuplicate se sono tab diversi." }
    }
    Write-Host $msg -ForegroundColor $(if ($saltati) { 'Yellow' } else { 'Green' })

    # Risultato STRUTTURATO: chi chiama deve poter dire cosa e' successo davvero, invece
    # di annunciare il numero che aveva chiesto. SkippedExact resta 0 finche' non esiste
    # l'identita' certa (fase 2): la forma del risultato non cambiera' quando arrivera'.
    [pscustomobject]@{
        Name          = $Name
        Added         = $aggiunti
        SkippedExact  = 0
        SkippedRecipe = $saltati
        Total         = $list.Count
    }
}

#endregion

Export-ModuleMember -Function Initialize-STerminal, Restore-STerminal, Set-STerminalTab,
    Get-STerminalStatus, Update-STHeartbeat, Get-STScrollbackBody, Get-STAliveSlots,
    Get-STOpenSlots, Read-STMeta, Write-STMeta, Get-STSlotDir,
    Save-STWorkspace, New-STWorkspace, Add-STWorkspaceTab, Resume-STWorkspace, Get-STResumeTabSpec,
    Get-STResumeArgs, Open-STWorkspaceTab, Get-STWorkspace, Get-STWorkspaceDir, Remove-STWorkspace,
    Get-STLiveTab, ConvertTo-STRunnable, Get-STTabSignature, Set-STWorkspaceColor, Get-STLiveTabAreas, Get-STLiveRowSpec,
    Get-STSlotForPid, Get-STLastTypedLine, Get-STNameFromLine, Test-STNomeGenerico, Set-STWorkspaceTerminale
