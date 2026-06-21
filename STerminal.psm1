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
        [string]$Color   # es. "#00AA55" - applicato alla riapertura via wt --tabColor
    )
    if (-not $script:STActive) { Write-Warning "STerminal non inizializzato in questo tab (Initialize-STerminal)."; return }
    $meta = Read-STMeta $script:STSlot
    if (-not $meta) { return }
    if ($PSBoundParameters.ContainsKey('Title')) { $meta.Title = $Title; Set-STTabTitle $Title }
    if ($PSBoundParameters.ContainsKey('Color')) { $meta.Color = $Color }
    Write-STMeta $meta
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
    # Tutti i tab in UNA finestra con nome fisso "STerminal": il primo new-tab la crea,
    # i successivi vi si agganciano. Deterministico, non dirotta finestre WT esistenti.
    foreach ($s in $slots) {
        $exe = if ($s.Shell) { $s.Shell } else { 'powershell.exe' }
        $cmd = "Import-Module '$($script:STModulePath)'; Initialize-STerminal -RestoreSlot '$($s.Slot)'"
        # base64 (UTF-16LE) -> nessuno spazio/;/virgoletta che WT possa interpretare male.
        $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

        $wtArgs = [System.Collections.Generic.List[string]]::new()
        $wtArgs.AddRange([string[]]@('-w', 'STerminal', 'new-tab'))
        if ($s.Title)                                    { $wtArgs.AddRange([string[]]@('--title', $s.Title)) }
        if ($s.Color)                                    { $wtArgs.AddRange([string[]]@('--tabColor', $s.Color)) }
        if ($s.Cwd -and (Test-Path -LiteralPath $s.Cwd)) { $wtArgs.AddRange([string[]]@('-d', $s.Cwd)) }
        $wtArgs.AddRange([string[]]@($exe, '-NoExit', '-EncodedCommand', $enc))

        Start-Process -FilePath 'wt.exe' -ArgumentList $wtArgs.ToArray()
        Start-Sleep -Milliseconds 600   # lascia a WT il tempo di creare/agganciare la finestra
    }
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
    param([Parameter(Mandatory)][string]$Name)

    $slots = Get-STOpenSlots
    if (-not $slots) {
        Write-Warning "STerminal: nessun tab registrato/aperto. Serve l'auto-init nel profilo (o Initialize-STerminal nei tab)."
        return
    }

    $dir = Get-STWorkspaceDir $Name
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
            Command = $null            # riservato alla fase "comando per tab"
            Storico = $storFile
        })
        $i++
    }

    $ws = [pscustomobject]@{ Name = $Name; Created = (Get-Date).ToString('o'); Tabs = $tabs }
    ($ws | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath (Join-Path $dir 'workspace.json') -Encoding utf8
    Write-Host "STerminal: area '$Name' salvata ($($tabs.Count) tab)." -ForegroundColor Green
}

# Apre un singolo tab di un'area: ristampa lo storico (testo) e poi diventa un tab vivo
# (re-Initialize), cosi' l'area si puo' ri-salvare.
function Open-STWorkspaceTab {
    [CmdletBinding()]
    param([string]$Storico, [string]$Title, [string]$Color)
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
}

# Costruisce gli argomenti wt e il comando base64 per UN tab di un'area, SENZA lanciarlo.
# Separato dallo spawn cosi' e' testabile su percorsi/titoli difficili (spazi, apostrofi, accenti).
function Get-STResumeTabSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Tab,
        [Parameter(Mandatory)][string]$WorkspaceDir,
        [Parameter(Mandatory)][string]$WindowId
    )
    $q = { param($s) if ($null -eq $s) { '' } else { ([string]$s).Replace("'", "''") } }
    $stor = if ($Tab.Storico) { Join-Path $WorkspaceDir $Tab.Storico } else { '' }
    $exe  = if ($Tab.Shell) { [string]$Tab.Shell } else { 'powershell.exe' }
    $cmd  = "Import-Module '$(& $q $script:STModulePath)'; Open-STWorkspaceTab -Storico '$(& $q $stor)' -Title '$(& $q $Tab.Title)' -Color '$(& $q $Tab.Color)'"
    $enc  = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    $wtArgs = [System.Collections.Generic.List[string]]::new()
    $wtArgs.AddRange([string[]]@('-w', $WindowId, 'new-tab'))
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

# Riapre un'area di lavoro: una finestra WT con i suoi tab, pre-colorati e titolati
# (cosi' si scavalca il focus-jump #19970), nelle cartelle giuste, con lo storico.
function Resume-STWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $dir = Get-STWorkspaceDir $Name
    $wj = Join-Path $dir 'workspace.json'
    if (-not (Test-Path -LiteralPath $wj)) { Write-Warning "STerminal: area '$Name' non trovata."; return }
    $ws = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
    if (-not $ws.Tabs) { Write-Warning "STerminal: area '$Name' senza tab."; return }

    $winId = "STerminal-$Name"
    Write-Host "STerminal: riprendo area '$Name' ($(@($ws.Tabs).Count) tab)..." -ForegroundColor Cyan
    foreach ($t in $ws.Tabs) {
        $spec = Get-STResumeTabSpec -Tab $t -WorkspaceDir $dir -WindowId $winId
        Start-Process -FilePath 'wt.exe' -ArgumentList $spec.WtArgs
        Start-Sleep -Milliseconds 600
    }
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

Export-ModuleMember -Function Initialize-STerminal, Restore-STerminal, Set-STerminalTab,
    Get-STerminalStatus, Update-STHeartbeat, Get-STScrollbackBody, Get-STAliveSlots,
    Get-STOpenSlots, Read-STMeta, Write-STMeta, Get-STSlotDir,
    Save-STWorkspace, Resume-STWorkspace, Get-STResumeTabSpec, Open-STWorkspaceTab,
    Get-STWorkspace, Get-STWorkspaceDir, Remove-STWorkspace
