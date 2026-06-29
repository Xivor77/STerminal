# STerminal - test suite (senza Pester). Logica pura + percorsi/titoli edge-case.
# Esegui:  powershell.exe -NoProfile -File "C:\projects\STerminal\tests\STerminal.Tests.ps1"
# ASCII puro; apostrofo/accento sono costruiti via [char] per non sporcare il file.

Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'STerminal.psm1') -Force

$script:pass = $true
function Check($n, $c) { if ($c) { "  [OK]   $n" } else { $script:pass = $false; "  [FAIL] $n" } }
function Section($t) { "`n=== $t ===" }

$star   = [char]42
$apos   = [char]39       # '
$egrave = [char]0x00E8   # e accentata

# root temporanea isolata (iniettata nello scope del modulo)
$root  = Join-Path $env:TEMP ('st_test_' + [guid]::NewGuid().ToString('n').Substring(0,8))
$wsDir = Join-Path $root 'workspaces'
& (Get-Module STerminal) { param($r,$w) $script:STRoot=$r; $script:STWorkspaces=$w } $root $wsDir
$delim = [string]$star * 22

try {
    Section "Get-STScrollbackBody"
    $tf = Join-Path $root 'tr.log'
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    @($delim,'PowerShell transcript start','Start time: x',$delim,'riga uno','riga due',$delim,'PowerShell transcript end',$delim) -join [Environment]::NewLine | Set-Content -LiteralPath $tf -Encoding utf8
    $body = Get-STScrollbackBody -Path $tf
    Check "estrae il corpo"        ($body -match 'riga uno' -and $body -match 'riga due')
    Check "scarta header/footer"   (-not ($body -match 'transcript'))

    Section "Save-STWorkspace round-trip (path con spazi)"
    $cwdSpazi = Join-Path $root 'cartella con spazi'
    New-Item -ItemType Directory -Force -Path $cwdSpazi | Out-Null
    $slotDir = Join-Path $root 'slot1'; New-Item -ItemType Directory -Force -Path $slotDir | Out-Null
    ([pscustomobject]@{ Slot='slot1'; Title='uno'; Color='#112233'; Cwd=$cwdSpazi; Shell='powershell.exe'; Pid=$PID; Created=(Get-Date).ToString('o'); Heartbeat=(Get-Date).ToString('o'); Closed=$false } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $slotDir 'meta.json') -Encoding utf8
    @($delim,'PowerShell transcript start',$delim,'contenuto uno',$delim,'PowerShell transcript end',$delim) -join [Environment]::NewLine | Set-Content -LiteralPath (Join-Path $slotDir 'scrollback.log') -Encoding utf8
    Save-STWorkspace -Name 'rt' | Out-Null
    $ws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'rt') 'workspace.json') -Raw | ConvertFrom-Json
    Check "cwd con spazi preservata" ($ws.Tabs[0].Cwd -eq $cwdSpazi)
    Check "storico salvato"          (Test-Path -LiteralPath (Join-Path (Join-Path $wsDir 'rt') 'tab-0.log'))

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
        Check "[$($c.n)] comando valido (niente quote-break)"          (@($e).Count -eq 0)
        $expect = Test-Path -LiteralPath $c.Cwd
        Check "[$($c.n)] -d presente solo se la cartella esiste"        ($spec.HasCwd -eq $expect)
        $ti = [array]::IndexOf($spec.WtArgs, '--title')
        Check "[$($c.n)] titolo preservato esatto negli args wt"        ($ti -ge 0 -and $spec.WtArgs[$ti+1] -eq $c.Title)
    }

    Section "apostrofo NEL path dello storico (finisce nel comando)"
    $tabS = [pscustomobject]@{ Title='s'; Color=$null; Cwd=$dirs.normale; Shell='powershell.exe'; Storico='tab-0.log' }
    $specS = Get-STResumeTabSpec -Tab $tabS -WorkspaceDir $dirs.apostrofo
    $e2 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($specS.DecodedCommand, [ref]$null, [ref]$e2)
    Check "comando valido con apostrofo nel path" (@($e2).Count -eq 0)
    Check "path storico presente nel comando"     ($specS.DecodedCommand -match 'tab-0\.log')

    Section "EncodedCommand decodifica round-trip"
    $dec = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($specS.EncodedCommand))
    Check "base64 -> comando originale identico" ($dec -eq $specS.DecodedCommand)

    Section "New-STWorkspace + comando per tab"
    New-STWorkspace -Name 'sys' -Tabs @(
        @{ Title='ORKAI'; Cwd=$dirs.normale; Command='& .\start.bat' }
        @{ Title='Chat';  Cwd=$dirs.spazi;   Command=('claude --resume ' + $apos + 'abc' + $apos) }
    ) | Out-Null
    $sys = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'sys') 'workspace.json') -Raw | ConvertFrom-Json
    Check "New-STWorkspace: 2 tab"               ($sys.Tabs.Count -eq 2)
    Check "comando per tab preservato"           ($sys.Tabs[0].Command -eq '& .\start.bat')
    $specC = Get-STResumeTabSpec -Tab $sys.Tabs[1] -WorkspaceDir (Join-Path $wsDir 'sys')
    $e3 = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($specC.DecodedCommand, [ref]$null, [ref]$e3)
    Check "comando con apostrofo -> Open valido"  (@($e3).Count -eq 0)
    Check "comando finisce nel comando di Open"   ($specC.DecodedCommand -match 'claude --resume')

    Section "Get-STResumeArgs - UNA invocazione wt (niente finestre multiple)"
    $argv = Get-STResumeArgs -Tabs $sys.Tabs -WorkspaceDir (Join-Path $wsDir 'sys')
    $nt   = @($argv | Where-Object { $_ -eq 'new-tab' }).Count
    $semi = @($argv | Where-Object { $_ -eq ';' }).Count
    Check "un 'new-tab' per tab (2)"   ($nt -eq 2)
    Check "';' separatori = tab-1 (1)" ($semi -eq 1)
    Check "niente -w (finestra unica)" (-not ($argv -contains '-w'))

    Section "Save-STWorkspace -Group (filtra per etichetta)"
    foreach ($g in @(@{s='slotA'; t='gruppoA-tab'; grp='A'}, @{s='slotB'; t='gruppoB-tab'; grp='B'})) {
        $sd = Join-Path $root $g.s; New-Item -ItemType Directory -Force -Path $sd | Out-Null
        ([pscustomobject]@{ Slot=$g.s; Title=$g.t; Color=$null; Command=$null; Group=$g.grp; Cwd=$env:TEMP; Shell='powershell.exe'; Pid=$PID; Created=(Get-Date).ToString('o'); Heartbeat=(Get-Date).ToString('o'); Closed=$false } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $sd 'meta.json') -Encoding utf8
    }
    Save-STWorkspace -Name 'soloA' -Group 'A' | Out-Null
    $wa = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'soloA') 'workspace.json') -Raw | ConvertFrom-Json
    Check "Group A: catturato 1 solo tab"  (@($wa.Tabs).Count -eq 1)
    Check "Group A: e' il tab giusto"      ($wa.Tabs[0].Title -eq 'gruppoA-tab')

    Section "ConvertTo-STRunnable + Add-STWorkspaceTab"
    Check "exe quotato -> & 'exe' args"  ((ConvertTo-STRunnable '"C:\py.exe" -m uvicorn') -eq "& 'C:\py.exe' -m uvicorn")
    Check "exe senza virgolette"         ((ConvertTo-STRunnable 'caddy.exe run') -eq "& 'caddy.exe' run")
    Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='a'; Cwd=$root; Command='& .\x'}, @{Title='b'; Cwd=$root}) | Out-Null
    Add-STWorkspaceTab -Name 'addws' -Tabs @(@{Title='c'; Cwd=$root}) | Out-Null
    $addws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'addws') 'workspace.json') -Raw | ConvertFrom-Json
    Check "Add-STWorkspaceTab accumula (3 tab)" (@($addws.Tabs).Count -eq 3)
    Check "append: ultimo tab e' 'c'"           ($addws.Tabs[2].Title -eq 'c')

    Section "Add-STWorkspaceTab -AutoColor (colori distinti per tab)"
    Add-STWorkspaceTab -Name 'colws' -Tabs @(@{Title='a'; Cwd=$root}, @{Title='b'; Cwd=$root}, @{Title='c'; Cwd=$root}) -AutoColor | Out-Null
    $colws = Get-Content -LiteralPath (Join-Path (Join-Path $wsDir 'colws') 'workspace.json') -Raw | ConvertFrom-Json
    $cols = @($colws.Tabs | ForEach-Object { $_.Color })
    Check "AutoColor: 3 colori assegnati"  ((@($cols | Where-Object { $_ })).Count -eq 3)
    Check "AutoColor: tutti distinti"      ((@($cols | Select-Object -Unique)).Count -eq 3)
}
finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

"`n=== RISULTATO: $(if ($script:pass) { 'TUTTO VERDE' } else { 'CI SONO FAIL' }) ==="
if (-not $script:pass) { exit 1 } else { exit 0 }
