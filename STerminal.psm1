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
    if ($wtAll.Count -gt 0) { Start-Process -FilePath 'wt.exe' -ArgumentList $wtAll.ToArray() }
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
    if (-not (Test-Path -LiteralPath $script:STRoot)) { return @() }
    $metas = Get-ChildItem -LiteralPath $script:STRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Read-STMeta $_.Name } |
        Where-Object { $_ -and $_.Pid -and (Get-Process -Id $_.Pid -ErrorAction SilentlyContinue) }
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
    $uiPrec = $null
    $wjPrec = Join-Path $dir 'workspace.json'
    if (Test-Path -LiteralPath $wjPrec) {
        try { $uiPrec = (Get-Content -LiteralPath $wjPrec -Raw | ConvertFrom-Json).UiColor } catch { }
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $tabs = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($s in $slots) {
        $storFile = "tab-$i.log"
        $body = Get-STScrollbackBody -Path (Join-Path (Get-STSlotDir $s.Slot) 'scrollback.log')
        if ($body) { Set-Content -LiteralPath (Join-Path $dir $storFile) -Value $body -Encoding utf8 }
        $tabs.Add([pscustomobject]@{
            Title   = $s.Title
            Color   = $s.Color
            Cwd     = $s.Cwd
            Shell   = $s.Shell
            Command = $s.Command
            Storico = $storFile
        })
        $i++
    }

    # Il colore dell'area sopravvive al risalvataggio: Save ricrea il file da zero, e
    # senza rileggerlo prima un salvataggio cancellerebbe quello che c'era.
    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $tabs; UiColor = $uiPrec }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wjPrec -Encoding utf8
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
    $uiPrec = $null
    $wjPrec = Join-Path $dir 'workspace.json'
    if (Test-Path -LiteralPath $wjPrec) {
        try { $uiPrec = (Get-Content -LiteralPath $wjPrec -Raw | ConvertFrom-Json).UiColor } catch { }
    }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $Tabs) {
        $list.Add([pscustomobject]@{
            Title   = $t.Title
            Color   = $t.Color
            Cwd     = $t.Cwd
            Shell   = if ($t.Shell) { $t.Shell } else { 'powershell.exe' }
            Command = $t.Command
            Storico = $null
        })
    }
    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $list; UiColor = $uiPrec }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $wjPrec -Encoding utf8
    if (-not $uiPrec) { [void](Set-STWorkspaceColor -Name $Name) }
    Write-Host "STerminal: area '$Name' definita ($($list.Count) tab)." -ForegroundColor Green
}

# Apre un singolo tab di un'area: ristampa lo storico (testo) e poi diventa un tab vivo
# (re-Initialize), cosi' l'area si puo' ri-salvare.
function Open-STWorkspaceTab {
    [CmdletBinding()]
    param([string]$Storico, [string]$Title, [string]$Color, [string]$Command)
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
        Write-Host "STerminal: avvio -> $Command" -ForegroundColor DarkCyan
        try { Invoke-Expression $Command } catch { Write-Warning "STerminal: comando fallito: $($_.Exception.Message)" }
    }
}

# Costruisce gli argomenti wt per UN tab (frammento che parte da 'new-tab'), SENZA lanciarlo.
# Separato dallo spawn cosi' e' testabile su percorsi/titoli difficili (spazi, apostrofi, accenti).
function Get-STResumeTabSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tab,
        [Parameter(Mandatory)][string]$WorkspaceDir
    )
    $q = { param($s) if ($null -eq $s) { '' } else { ([string]$s).Replace("'", "''") } }
    $stor = if ($Tab.Storico) { Join-Path $WorkspaceDir $Tab.Storico } else { '' }
    $exe  = if ($Tab.Shell) { [string]$Tab.Shell } else { 'powershell.exe' }
    $cmd  = "Import-Module '$(& $q $script:STModulePath)'; Open-STWorkspaceTab -Storico '$(& $q $stor)' -Title '$(& $q $Tab.Title)' -Color '$(& $q $Tab.Color)' -Command '$(& $q $Tab.Command)'"
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
function Get-STResumeArgs {
    param([Parameter(Mandatory)][object[]]$Tabs, [Parameter(Mandatory)][string]$WorkspaceDir)
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $Tabs) {
        if (-not $t) { continue }
        $spec = Get-STResumeTabSpec -Tab $t -WorkspaceDir $WorkspaceDir
        if ($all.Count -gt 0) { $all.Add(';') }
        $all.AddRange([string[]]$spec.WtArgs)
    }
    $all.ToArray()
}

# Riapre un'area di lavoro: UNA finestra WT con tutti i suoi tab, pre-colorati e titolati
# (cosi' si scavalca il focus-jump #19970), nelle cartelle giuste, con lo storico e il comando.
function Resume-STWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $dir = Get-STWorkspaceDir $Name
    $wj = Join-Path $dir 'workspace.json'
    if (-not (Test-Path -LiteralPath $wj)) { Write-Warning "STerminal: area '$Name' non trovata."; return }
    $ws = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
    if (-not $ws.Tabs) { Write-Warning "STerminal: area '$Name' senza tab."; return }

    Write-Host "STerminal: riprendo area '$Name' ($(@($ws.Tabs).Count) tab)..." -ForegroundColor Cyan
    $wtAll = Get-STResumeArgs -Tabs @($ws.Tabs) -WorkspaceDir $dir
    if ($wtAll.Count -gt 0) { Start-Process -FilePath 'wt.exe' -ArgumentList $wtAll }
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

# Elenca i tab shell aperti (powershell/pwsh) con cosa ci gira dentro e dove. Sorgente =
# scansione processi (PEB + Win32_Process): mostra ANCHE i tab non registrati o occupati.
function Get-STLiveTab {
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId, Name, CommandLine
    if (-not $all) { return @() }
    $kids = @{}
    foreach ($p in $all) { $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = @() }; $kids[$k] += $p }
    $skip = @('conhost.exe', 'OpenConsole.exe')
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
        if ($child) {
            $cwd = Get-STCwdSafe ([int]$child.ProcessId); if (-not $cwd) { $cwd = Get-STCwdSafe ([int]$s.ProcessId) }
            $cmd = ConvertTo-STRunnable $child.CommandLine
            $what = $child.Name -replace '\.exe$', ''
        } else {
            $cwd = Get-STCwdSafe ([int]$s.ProcessId); $cmd = $null; $what = 'shell'
        }
        $leaf = if ($cwd) { Split-Path $cwd -Leaf } else { '?' }
        $out.Add([pscustomobject]@{
            Pid     = [int]$s.ProcessId
            Cwd     = $cwd
            Command = $cmd
            What    = $what
            # La shell VERA del tab: qui si distingue gia' powershell.exe da pwsh.exe
            # (v. il filtro sopra), ma prima non usciva da questa funzione -- e allora
            # tutto arrivava al motore come 'powershell.exe', firma compresa. Referto
            # Tommaso 13/08, rilievo 1: una firma che dichiara di guardare la shell e
            # non la vede mai e' peggio che non guardarla, perche' ci si fida.
            Shell   = $s.Name
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
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Tab)

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
    "$cwd|$shell|$cmd"
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
    $perCwd   = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    foreach ($a in $Aree) {
        foreach ($t in @($a.Tabs)) {
            if (-not $t) { continue }
            $voce = [pscustomobject]@{ Name = $a.Name; UiColor = $a.UiColor }
            $f = Get-STTabSignature $t
            if (-not $perFirma.ContainsKey($f)) { $perFirma[$f] = [System.Collections.Generic.List[object]]::new() }
            if ($perFirma[$f].Name -notcontains $a.Name) { [void]$perFirma[$f].Add($voce) }
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
            Shell     = $lt.Shell
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
    foreach ($e in $list) { [void]$firme.Add((Get-STTabSignature $e)) }

    $used = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $list) { if ($e.Color) { [void]$used.Add([string]$e.Color) } }

    $aggiunti = 0; $saltati = 0; $deboli = 0
    foreach ($t in $Tabs) {
        if (-not $AllowDuplicate) {
            $firma = Get-STTabSignature $t
            # Il controllo vale anche DENTRO il lotto: due voci uguali passate insieme
            # sono un doppione quanto una gia' presente sul disco.
            if ($firme.Contains($firma)) {
                $saltati++
                if (Test-STWeakSignature $t) { $deboli++ }
                continue
            }
            [void]$firme.Add($firma)
        }
        $color = $t.Color
        if ($AutoColor -and -not $color) {
            $color = $script:STPalette | Where-Object { $used -notcontains $_ } | Select-Object -First 1
            if (-not $color) { $color = $script:STPalette[$list.Count % $script:STPalette.Count] }
            [void]$used.Add($color)
        }
        $list.Add([pscustomobject]@{
            Title   = $t.Title
            Color   = $color
            Cwd     = $t.Cwd
            Shell   = if ($t.Shell) { $t.Shell } else { 'powershell.exe' }
            Command = $t.Command
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
    Get-STLiveTab, ConvertTo-STRunnable, Get-STTabSignature, Set-STWorkspaceColor, Get-STLiveTabAreas, Get-STLiveRowSpec
