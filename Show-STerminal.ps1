# STerminal - mini-interfaccia (WPF). Due sezioni:
#  - Aree di lavoro: scegli e Riprendi / Elimina.
#  - Tab aperti: lista dei tab vivi (anche occupati), seleziona uno o piu' -> Aggiungi a gruppo.
#    Il dialogo "Aggiungi a gruppo" offre due modi mutuamente esclusivi:
#      (A) Automatico: colori assortiti + titoli originali
#      (B) Per singola tab: scegli titolo e colore di ognuno
#
# Avvio:  powershell.exe -WindowStyle Hidden -File "C:\projects\STerminal\Show-STerminal.ps1"
# ASCII puro. Compatibile 5.1 (STA di default) e 7 (-sta).
param([switch]$NoShow, [switch]$TestAddDialog)

Add-Type -AssemblyName PresentationFramework

Import-Module (Join-Path $PSScriptRoot 'STerminal.psm1') -Force

$script:STUIPalette = @('#1FAA55','#2D7D9A','#3B7DD8','#8E44AD','#E67E22','#C0392B','#16A085','#D4A017','#E84393','#2C3E50','#7F8C8D','#2980B9')

# --- Dialogo "Aggiungi a gruppo" ---------------------------------------------
function Invoke-STAddDialog {
    # AreeFinte serve SOLO alle prove: senza, l'elenco viene dalle aree vere. Un test che
    # legge i dati di casa non e' isolato, e uno che li scrive e' un danno (13/08: la
    # suite creo' un'area 'rt' fra quelle vere).
    param([object[]]$LiveTabs, [switch]$NoShow, [string[]]$AreeFinte)

    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Aggiungi a gruppo" Height="480" Width="560" WindowStartupLocation="CenterOwner">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal" Margin="0,0,0,4">
        <RadioButton x:Name="RbExisting" GroupName="AreaScelta" Content="Area esistente:" IsChecked="True" VerticalAlignment="Center" Width="120"/>
        <ComboBox x:Name="GroupPick" Width="300"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="RbNew" GroupName="AreaScelta" Content="Nuova area:" VerticalAlignment="Center" Width="120"/>
        <TextBox x:Name="GroupName" Width="300" IsEnabled="False"/>
      </StackPanel>
    </StackPanel>
    <StackPanel Grid.Row="1" Margin="0,0,0,8">
      <RadioButton x:Name="RbAuto" Content="Automatico  (colori assortiti, titoli originali)" IsChecked="True" Margin="0,2,0,2"/>
      <RadioButton x:Name="RbManual" Content="Per singola tab  (scegli titolo e colore)" Margin="0,2,0,2"/>
    </StackPanel>
    <Border Grid.Row="2" BorderBrush="#DDDDDD" BorderThickness="1" Padding="6">
      <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel x:Name="Rows"/>
      </ScrollViewer>
    </Border>
    <WrapPanel Grid.Row="3" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Ok" Content="OK" Width="90" Height="30" Margin="0,0,8,0" IsDefault="True"/>
      <Button x:Name="Cancel" Content="Annulla" Width="90" Height="30" IsCancel="True"/>
    </WrapPanel>
  </Grid>
</Window>
"@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $gName  = $dlg.FindName('GroupName')
    $gPick  = $dlg.FindName('GroupPick')
    $rbExist= $dlg.FindName('RbExisting')
    $rbNew  = $dlg.FindName('RbNew')
    $rbAuto = $dlg.FindName('RbAuto')
    $rbMan  = $dlg.FindName('RbManual')
    $rows   = $dlg.FindName('Rows')
    $ok     = $dlg.FindName('Ok')
    $cancel = $dlg.FindName('Cancel')

    $rowCtrls = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($lt in $LiveTabs) {
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $sp.Margin = [System.Windows.Thickness]::new(0,3,0,3)

        $tb = New-Object System.Windows.Controls.TextBox
        $tb.Width = 200; $tb.Text = [string]$lt.What; $tb.Margin = [System.Windows.Thickness]::new(0,0,8,0)

        $cb = New-Object System.Windows.Controls.ComboBox
        $cb.Width = 120
        foreach ($c in $script:STUIPalette) {
            $it = New-Object System.Windows.Controls.ComboBoxItem
            $it.Content = $c
            $it.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($c))
            $it.Foreground = [System.Windows.Media.Brushes]::White
            [void]$cb.Items.Add($it)
        }
        $cb.SelectedIndex = ($i % $script:STUIPalette.Count)

        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "  $($lt.Label)"; $lbl.Foreground = [System.Windows.Media.Brushes]::Gray; $lbl.VerticalAlignment = 'Center'

        [void]$sp.Children.Add($tb); [void]$sp.Children.Add($cb); [void]$sp.Children.Add($lbl)
        [void]$rows.Children.Add($sp)
        [void]$rowCtrls.Add([pscustomobject]@{ Tab = $lt; TitleBox = $tb; ColorBox = $cb })
        $i++
    }

    $toggle = { $rows.IsEnabled = [bool]$rbMan.IsChecked }.GetNewClosure()
    $rbAuto.Add_Checked($toggle); $rbMan.Add_Checked($toggle)
    $rows.IsEnabled = $false

    # Le aree esistenti si SCELGONO, non si ricordano. Prima il nome andava digitato in
    # una casella vuota, e `Add-STWorkspaceTab` crea l'area se non la trova: un refuso
    # non dava errore, creava un'area nuova in silenzio. Creare resta possibile, ma e'
    # un gesto separato e dichiarato (referto Tommaso 13/08, rilievo 5).
    $aree = if ($PSBoundParameters.ContainsKey('AreeFinte')) { @($AreeFinte) }
            else { @(Get-STWorkspace | ForEach-Object { $_.Name } | Sort-Object) }
    foreach ($a in $aree) { [void]$gPick.Items.Add($a) }
    if ($aree.Count) { $gPick.SelectedIndex = 0 } else { $rbNew.IsChecked = $true }
    $rbExist.IsEnabled = [bool]$aree.Count
    $modo = {
        $gPick.IsEnabled = [bool]$rbExist.IsChecked
        $gName.IsEnabled = [bool]$rbNew.IsChecked
    }.GetNewClosure()
    $rbExist.Add_Checked($modo); $rbNew.Add_Checked($modo); & $modo

    $esito = @{ Valore = $null }   # contenitore condiviso: la chiusura lo cattura per riferimento
    $ok.Add_Click(({
        $name = if ($rbNew.IsChecked) { $gName.Text.Trim() } else { [string]$gPick.SelectedItem }
        if (-not $name) { if ($rbNew.IsChecked) { $gName.Focus() } else { $gPick.Focus() }; return }
        if ($rbMan.IsChecked) {
            $tabs = @(foreach ($r in $rowCtrls) {
                $col = if ($r.ColorBox.SelectedItem) { [string]$r.ColorBox.SelectedItem.Content } else { $null }
                # Intento viaggia con la riga: e' la parte della firma che distingue due
                # schede che il solo comando del lanciatore farebbe collassare.
                # Fonte viaggia dal 22/09 (D2b la legge): se la persona ha riscritto la
                # casella il nome e' suo ('persona'), se l'ha lasciata com'era resta
                # quella della riga viva. Cosi' un 'cmd' scelto a mano non viene mai
                # confuso col ripiego muto.
                $fonteR = if ($r.TitleBox.Text -ne [string]$r.Tab.What) { 'persona' } else { $r.Tab.Fonte }
                @{ Title = $r.TitleBox.Text; Color = $col; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command; Shell = $r.Tab.Shell; Intento = $r.Tab.Intento; Fonte = $fonteR }
            })
            $esito.Valore = @{ Name = $name; AutoColor = $false; Tabs = $tabs }
        } else {
            $tabs = @(foreach ($r in $rowCtrls) {
                # D2a (22/09): in automatico il nome muto non si spaccia per titolo. Se
                # What viene dal ripiego (Fonte='processo') ed e' un nome generico, il
                # Title resta VUOTO -- vuoto dice "non so", che e' onesto; la firma non
                # cambia (il Title non entra nella firma). La stessa guardia in
                # profondita' vive in Add-STWorkspaceTab (D2b).
                $tit = if ($r.Tab.Fonte -eq 'processo' -and (Test-STNomeGenerico ([string]$r.Tab.What))) { '' } else { $r.Tab.What }
                @{ Title = $tit; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command; Shell = $r.Tab.Shell; Intento = $r.Tab.Intento; Fonte = $r.Tab.Fonte }
            })
            $esito.Valore = @{ Name = $name; AutoColor = $true; Tabs = $tabs }
        }
        $dlg.DialogResult = $true; $dlg.Close()
    }).GetNewClosure())
    $cancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())

    if ($NoShow) {
        # Prima tornava la costante 'BUILT-OK': una risposta che non poteva fallire.
        # Ora escono i controlli veri, cosi' le prove possono premerli (referto 13/08, 4).
        return [pscustomobject]@{
            Costruito = $true
            Aree      = $aree
            RbExist   = $rbExist
            RbNew     = $rbNew
            Pick      = $gPick
            Name      = $gName
            Ok        = $ok
            Esito     = $esito
        }
    }
    try { $dlg.Owner = $win } catch { }
    [void]$dlg.ShowDialog()
    return $esito.Valore
}

# --- Applicazione dei cambi-titolo (tasto Modifica, colonna sinistra) ----------
# Fra la LETTURA del file e la SCRITTURA il file puo' cambiare (tre funzioni
# riscrivono workspace.json per intero). Quindi la riga si indirizza con i valori
# CATTURATI ALLA LETTURA (-TitleVecchio + -Cwd, piu' shell/comando quando ci sono):
# se quella riga non c'e' piu' o non e' piu' unica, il motore RIFIUTA invece di
# scrivere sulla riga sbagliata. MAI -Index: e' l'unico indirizzo con cui il motore
# non puo' rifiutare. E ogni rifiuto torna nel testo: un no ingoiato farebbe credere
# alla persona di aver rinominato.
function Invoke-STTabRenameApply {
    param([Parameter(Mandatory)][string]$Name, [object[]]$Cambi)
    $esiti = @()
    if (-not $Cambi -or $Cambi.Count -eq 0) {
        return @([pscustomobject]@{ Esito='nessuna'; Prima=$null; Dopo=$null; Motivo=$null
            Riga="Nessuna modifica: i titoli sono quelli salvati." })
    }
    foreach ($c in $Cambi) {
        $params = @{ Name = $Name; Title = $c.NuovoTitolo; TitleVecchio = $c.TitleVecchio; Cwd = [string]$c.Cwd }
        if ($c.Shell)   { $params.Shell   = [string]$c.Shell }
        if ($c.Command) { $params.Command = [string]$c.Command }
        $res = Set-STWorkspaceTabTitle @params
        if ($res.Rinominata) {
            $esiti += [pscustomobject]@{ Esito='rinominata'; Prima=$res.Prima; Dopo=$res.Dopo; Motivo=$null
                Riga="'$($res.Prima)' -> '$($res.Dopo)'   ($($c.Cwd))   [Fonte=persona]" }
        } else {
            $esiti += [pscustomobject]@{ Esito='rifiutata'; Prima=$c.TitleVecchio; Dopo=$c.NuovoTitolo; Motivo=$res.Motivo
                Riga="NON fatta: '$($c.TitleVecchio)'   ($($c.Cwd)):  $($res.Motivo)" }
        }
    }
    $esiti
}

# --- Dialogo "Modifica": i titoli delle righe SALVATE di un'area ---------------
# Qui NON c'e' il ponte col tab vivo (quello e' il ritirato della colonna destra):
# si lavora direttamente sulle righe del file. Il dialogo lo dichiara, e dichiara
# anche che sullo schermo non succede niente finche' non si fa Riprendi.
function Invoke-STEditTabsDialog {
    param([Parameter(Mandatory)][string]$Name, [switch]$NoShow)
    [xml]$dx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Modifica" Height="460" Width="620" WindowStartupLocation="CenterOwner">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock x:Name="Hdr" FontWeight="Bold" TextWrapping="Wrap"/>
      <TextBlock x:Name="Warn" Foreground="#8A6D00" TextWrapping="Wrap" Margin="0,4,0,0"
                 Text="Rinominare cambia cio&#39; che e&#39; salvato, non il tab vivo: sullo schermo non succede niente finche&#39; non fai Riprendi."/>
    </StackPanel>
    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,8">
      <TextBlock Text="Nome dell'area:" Width="110" VerticalAlignment="Center"/>
      <TextBox x:Name="AreaBox" Width="300"/>
    </StackPanel>
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto">
      <StackPanel x:Name="RowsPanel"/>
    </ScrollViewer>
    <TextBlock x:Name="Results" Grid.Row="3" Foreground="Gray" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <WrapPanel Grid.Row="5" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="Applica" Content="Applica" Width="90" Height="30" Margin="0,0,8,0"/>
      <Button x:Name="Chiudi" Content="Chiudi" Width="90" Height="30" IsCancel="True"/>
    </WrapPanel>
  </Grid>
</Window>
"@
    $dlg      = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $dx))
    $hdr      = $dlg.FindName('Hdr')
    $areaBox  = $dlg.FindName('AreaBox')
    $panel    = $dlg.FindName('RowsPanel')
    $results  = $dlg.FindName('Results')
    $btnApplica = $dlg.FindName('Applica')
    $btnChiudi  = $dlg.FindName('Chiudi')
    $hdr.Text = "Righe salvate dell'area '$Name'  (i titoli si cambiano qui)"
    $areaBox.Text = $Name
    # Il nome con cui si chiamano i gesti: parte da $Name e si aggiorna a ogni rinomina
    # riuscita, cosi' il prossimo Applica non chiama il fantasma del nome vecchio.
    $stato = @{ NomeCorrente = $Name }

    # LETTURA: i valori che indirizzeranno la scrittura si catturano ORA, non al click.
    $righeUi = @()
    $wj = Join-Path (Get-STWorkspaceDir $Name) 'workspace.json'
    $rows = @()
    if (Test-Path -LiteralPath $wj) {
        try { $rows = @((Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json).Tabs) } catch { $rows = @() }
    }
    if (-not (Test-Path -LiteralPath $wj)) {
        $results.Text = "L'area '$Name' non ha un workspace.json: niente da rinominare."
    } elseif ($rows.Count -eq 0) {
        $results.Text = "L'area '$Name' non ha righe: niente da rinominare."
    } else {
        foreach ($row in $rows) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.FontSize = 11; $tb.Foreground = [System.Windows.Media.Brushes]::Gray
            $pezzi = @([string]$row.Cwd)
            if ($row.Shell)   { $pezzi += [string]$row.Shell }
            if ($row.Command) { $pezzi += [string]$row.Command }
            $tb.Text = [string]::Join('  |  ', $pezzi)
            $box = New-Object System.Windows.Controls.TextBox
            $box.Width = 420; $box.HorizontalAlignment = 'Left'; $box.Margin = '0,2,0,8'
            $box.Text = [string]$row.Title
            [void]$panel.Children.Add($tb)
            [void]$panel.Children.Add($box)
            $righeUi += @{ Box=$box; Title=[string]$row.Title; Cwd=[string]$row.Cwd
                           Shell=[string]$row.Shell; Command=[string]$row.Command }
        }
    }

    $esito = @{ Valore = $null }
    $btnApplica.Add_Click(({
        # DUE gesti, non una cosa sola: la sequenza non ha rollback. L'ordine e' area
        # PRIMA, titoli POI col nome corrente: se la rinomina riesce, i titoli vanno
        # chiamati col nome NUOVO (col vecchio il motore direbbe "nessuna riga" e la
        # persona crederebbe a una colpa sua); se fallisce, i titoli restano possibili
        # col nome vecchio -- un no dell'area non deve portarsi dietro i titoli.
        $linee = @()
        $areaRinominata = $false; $areaRifiutata = $false; $areaMotivo = $null
        $nuovoNome = $areaBox.Text.Trim()
        if ($nuovoNome -cne $stato.NomeCorrente) {
            $ra = Rename-STWorkspace -Name $stato.NomeCorrente -NewName $nuovoNome
            if ($ra.Rinominata) {
                $areaRinominata = $true
                $linee += "Area: '$($stato.NomeCorrente)' -> '$nuovoNome'."
                $stato.NomeCorrente = $nuovoNome
                $hdr.Text = "Righe salvate dell'area '$nuovoNome'  (i titoli si cambiano qui)"
            } else {
                $areaRifiutata = $true; $areaMotivo = $ra.Motivo
                $linee += "Area NON rinominata: $($ra.Motivo)."
            }
        }
        $cambi = @()
        foreach ($r in $righeUi) {
            $nuovo = $r.Box.Text.Trim()
            if ($nuovo -ne $r.Title) {
                $cambi += @{ TitleVecchio=$r.Title; NuovoTitolo=$nuovo; Cwd=$r.Cwd; Shell=$r.Shell; Command=$r.Command }
            }
        }
        $esiti = if ($cambi.Count) { @(Invoke-STTabRenameApply -Name $stato.NomeCorrente -Cambi $cambi) } else { @() }
        $linee += @($esiti | ForEach-Object Riga)
        if (-not $linee) { $linee = @("Nessuna modifica: il nome e i titoli sono quelli salvati.") }
        $results.Text = [string]::Join([Environment]::NewLine, $linee)
        # Dopo un SI' la riga salvata ha il titolo nuovo: il prossimo Applica deve
        # indirizzare QUELLO, non il fantasma del vecchio. Dopo un NO resta il vecchio.
        $okN = 0; $noN = 0
        foreach ($e in $esiti) {
            if ($e.Esito -eq 'rinominata') {
                $okN++
                foreach ($r in $righeUi) { if ($r.Title -eq $e.Prima -and $r.Box.Text.Trim() -eq $e.Dopo) { $r.Title = $e.Dopo } }
            } elseif ($e.Esito -eq 'rifiutata') { $noN++ }
        }
        $esito.Valore = @{ Rinominate=$okN; Rifiutate=$noN
                           AreaRinominata=$areaRinominata; AreaNome=$stato.NomeCorrente
                           AreaRifiutata=$areaRifiutata; AreaMotivo=$areaMotivo }
    }).GetNewClosure())
    $btnChiudi.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() }.GetNewClosure())

    if ($NoShow) {
        return [pscustomobject]@{
            Costruito = $true; Righe = $righeUi; Results = $results; AreaBox = $areaBox
            Applica = $btnApplica; Chiudi = $btnChiudi; Esito = $esito; Warn = $dlg.FindName('Warn')
        }
    }
    try { $dlg.Owner = $win } catch { }
    [void]$dlg.ShowDialog()
    return $esito.Valore
}

# --- Finestra principale -----------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="STerminal" Height="500" Width="820" WindowStartupLocation="CenterScreen">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <Grid Grid.Row="0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Grid Grid.Column="0">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Aree di lavoro" FontSize="15" FontWeight="Bold" Margin="0,0,0,6"/>
        <ListBox x:Name="WsList" Grid.Row="1" FontSize="13"/>
        <WrapPanel Grid.Row="2" Margin="0,8,0,0">
          <Button x:Name="BtnResume" Content="Riprendi" Width="100" Height="30" Margin="0,0,6,0"/>
          <Button x:Name="BtnDelete" Content="Elimina"  Width="90"  Height="30" Margin="0,0,6,0"/>
          <Button x:Name="BtnRefresh" Content="Aggiorna" Width="90" Height="30" Margin="0,0,6,0"/>
          <Button x:Name="BtnEditTabs" Content="Modifica..." Width="100" Height="30"/>
        </WrapPanel>
      </Grid>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <StackPanel Grid.Row="0" Margin="0,0,0,6">
          <TextBlock Text="Tab aperti  (seleziona uno o piu')" FontSize="15" FontWeight="Bold"/>
          <TextBlock Text="ogni riga:  path  -  attivita  [pid]   in: aree che contengono gia&#39; questo tab" FontSize="11" Foreground="Gray"/>
        </StackPanel>
        <ListBox x:Name="LiveList" Grid.Row="1" FontSize="12" SelectionMode="Extended"/>
        <WrapPanel Grid.Row="2" Margin="0,8,0,0">
          <Button x:Name="BtnAddGroup" Content="Aggiungi a gruppo..." Width="170" Height="30"/>
        </WrapPanel>
      </Grid>
    </Grid>

    <TextBlock x:Name="Status" Grid.Row="1" Margin="0,10,0,0" Foreground="Gray"/>
  </Grid>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$wsList     = $win.FindName('WsList')
$liveList   = $win.FindName('LiveList')
$btnResume  = $win.FindName('BtnResume')
$btnDelete  = $win.FindName('BtnDelete')
$btnRefresh = $win.FindName('BtnRefresh')
$btnEdit    = $win.FindName('BtnEditTabs')
$btnAdd     = $win.FindName('BtnAddGroup')
$status     = $win.FindName('Status')

function Update-WsList {
    $wsList.Items.Clear()
    foreach ($w in @(Get-STWorkspace)) {
        $n = if ($w.Tabs) { @($w.Tabs).Count } else { 0 }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "$($w.Name)   ($n tab)"; $item.Tag = $w.Name
        # Lo STESSO colore dei tab a destra: e' qui che si accoppiano a occhio, ed era
        # meta' del requisito (referto §9-10.1, rilievo 2).
        if ($w.UiColor) {
            try {
                $cw = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($w.UiColor)
                $item.Background = New-Object System.Windows.Media.SolidColorBrush $cw
                $item.Foreground = [System.Windows.Media.Brushes]::White
            } catch { }
        }
        [void]$wsList.Items.Add($item)
    }
}
function Update-LiveList {
    # I tab si possono iniettare per poter provare il COLLEGAMENTO fra questa lista e
    # Get-STLiveRowSpec: l'helper era stato estratto per renderlo provabile, ma nessuno
    # verificava che la finestra lo USASSE -- un mutante che rompeva questo punto lasciava
    # la suite verde su 101 controlli (referto 13/08, rilievo 3).
    param([object[]]$Tabs)
    $liveList.Items.Clear()
    # I tab che stanno gia' in un'area si riconoscono dal COLORE DELL'AREA, cosi' non li
    # si riaggiunge per sbaglio. Il riconoscimento e' per RICETTA (cartella+shell+comando):
    # due tab gemelli aperti apposta sono indistinguibili, e per questo la riga lo dichiara
    # con "~" invece di affermare che e' proprio quel tab.
    $elenco = if ($PSBoundParameters.ContainsKey('Tabs')) { @($Tabs) }
              else { @(Get-STLiveTabAreas | Sort-Object Cwd) }
    foreach ($t in $elenco) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $spec = Get-STLiveRowSpec -Tab $t
        $item.Content = $spec.Testo
        if ($spec.Colore) {
            if ($true) {
                try {
                    $c = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($spec.Colore)
                    $item.Background = New-Object System.Windows.Media.SolidColorBrush $c
                    $item.Foreground = [System.Windows.Media.Brushes]::White
                } catch { }   # un colore illeggibile non deve far sparire la riga
            }
        }
        $item.Tag = $t
        [void]$liveList.Items.Add($item)
    }
}
function Update-All { Update-WsList; Update-LiveList; $status.Text = "$($wsList.Items.Count) aree - $($liveList.Items.Count) tab aperti" }

$btnResume.Add_Click({
    if ($wsList.SelectedItem) { $n = $wsList.SelectedItem.Tag; $status.Text = "Riprendo '$n'..."; Resume-STWorkspace -Name $n; $win.Close() }
    else { $status.Text = "Seleziona prima un'area." }
})
$btnDelete.Add_Click({
    if ($wsList.SelectedItem) { $n = $wsList.SelectedItem.Tag; Remove-STWorkspace -Name $n; Update-WsList; $status.Text = "Area '$n' eliminata." }
    else { $status.Text = "Seleziona prima un'area." }
})
$btnRefresh.Add_Click({ Update-All })
$btnAdd.Add_Click({
    $sel = @($liveList.SelectedItems)
    if ($sel.Count -eq 0) { $status.Text = "Seleziona almeno un tab aperto (a destra)."; return }
    $live = @($sel | ForEach-Object { $_.Tag })
    $r = Invoke-STAddDialog -LiveTabs $live
    if (-not $r) { return }
    $esito = if ($r.AutoColor) { Add-STWorkspaceTab -Name $r.Name -Tabs $r.Tabs -AutoColor }
             else { Add-STWorkspaceTab -Name $r.Name -Tabs $r.Tabs }
    # Il no del motore (la guardia sui nomi, 22/09) non si ingoia: "Aggiunti 0 tab"
    # farebbe credere che e' andata e non e' andata.
    if ($esito.Rifiutata) { $status.Text = "NON aggiunti a '$($esito.Name)': $($esito.Motivo)"; return }
    Update-WsList
    # Si dice cosa e' successo, non cosa era stato chiesto: prima questa riga annunciava
    # sempre il numero di tab selezionati, anche quando il motore ne aveva scartati.
    $t = "Aggiunti $($esito.Added) tab a '$($esito.Name)' (l'area ne ha $($esito.Total))."
    if ($esito.SkippedRecipe) { $t += "  $($esito.SkippedRecipe) c'erano gia': saltati." }
    # Il canale segue la cattura (regola 30/08): se tutti i tab selezionati stanno nello
    # STESSO terminale, l'area lo registra (sidecar, non workspace.json: i campi di la'
    # hanno gia' tre scrittori). Misti o non osservabili -> niente registrazione: il
    # resume usera' l'alias come ieri, e la riga di stato lo dice.
    if ($esito.Added -gt 0) {
        $canali = @($live | ForEach-Object { if ($_.PSObject.Properties['Terminale']) { [string]$_.Terminale } } | Where-Object { $_ } | Select-Object -Unique)
        if ($canali.Count -eq 1) {
            Set-STWorkspaceTerminale -Name $r.Name -Path $canali[0] -Fonte 'cattura'
        } elseif ($canali.Count -gt 1) {
            $t += "  Terminali misti: canale non registrato."
        }
    }
    $status.Text = $t
})

# Precedente vero della casa: tasto sempre acceso, e il click a vuoto ti dice cosa manca.
$btnEdit.Add_Click({
    if (-not $wsList.SelectedItem) { $status.Text = "Seleziona prima un'area (a sinistra)."; return }
    $n = $wsList.SelectedItem.Tag
    $esito = Invoke-STEditTabsDialog -Name $n
    # Si dice cosa e' successo, non cosa era stato chiesto. Il dettaglio per riga e'
    # rimasto nel dialogo; qui il riassunto, compresi i NO del motore, dei DUE gesti:
    # un "fatto" che nasconde meta' e' il difetto che togliamo da due giorni.
    if ($esito) {
        $parti = @()
        if ($esito.AreaRinominata) {
            $parti += "area rinominata in '$($esito.AreaNome)'"
            # La lista a sinistra mostra ancora il nome vecchio, e il suo Tag non
            # esiste piu': va rifatta, o Riprendi/Elimina cercherebbero un fantasma.
            Update-WsList
        }
        if ($esito.AreaRifiutata) { $parti += "area NON rinominata" }
        $parti += "$($esito.Rinominate) titoli rinominati"
        if ($esito.Rifiutate) { $parti += "$($esito.Rifiutate) NON fatti" }
        $t = "Modifica '$n': " + ($parti -join ', ') + "."
        if ($esito.AreaRifiutata -or $esito.Rifiutate) { $t += " Il perche' era nel dialogo." }
        $t += " Il tab vivo non cambia finche' non fai Riprendi."
        $status.Text = $t
    }
})

# Le prove entrano PRIMA di Update-All: quella chiamata legge le aree vere e interroga i
# processi vivi, e una prova che tocca il mondo reale non e' isolata -- anche quando non
# scrive niente (referto 14/08, rilievo 1). Con lo switch, la finestra non si popola.
if ($TestAddDialog) {
    # Prove del dialogo. Prima qui si stampava soltanto 'BUILT-OK', cioe' "si costruisce":
    # una risposta che non poteva fallire e che non diceva niente sul comportamento.
    $ok = $true
    function T($n, $c) { if ($c) { "  [OK]   $n" } else { $script:ok = $false; "  [FAIL] $n" } }
    $dummy = @(
        [pscustomobject]@{ What='claude'; Cwd='C:\projects\x'; Command="& claude"; Shell='pwsh.exe';       Label='x - claude [1]' }
        [pscustomobject]@{ What='caddy';  Cwd='C:\projects\y'; Command="& caddy";  Shell='powershell.exe'; Label='y - caddy [2]' }
    )
    $d = Invoke-STAddDialog -LiveTabs $dummy -NoShow -AreeFinte @('alfa','beta')
    T "il dialogo si costruisce"            ($d.Costruito -eq $true)
    T "l'elenco porta le aree"              (@($d.Pick.Items).Count -eq 2)
    T "parte da 'area esistente'"           ($d.RbExist.IsChecked -and -not $d.RbNew.IsChecked)
    T "e la casella del nome e' spenta"     (-not $d.Name.IsEnabled)

    # IL DIFETTO DEL 13/08: i due radio stavano in contenitori diversi, e WPF li raggruppa
    # per contenitore -> restavano accesi entrambi. Qui si preme davvero.
    $d.RbNew.IsChecked = $true
    T "scelgo 'nuova': l'altra si spegne"   (-not $d.RbExist.IsChecked)
    T "si accende la casella del nome"      ($d.Name.IsEnabled -and -not $d.Pick.IsEnabled)
    $d.RbExist.IsChecked = $true
    T "e si torna indietro davvero"         (-not $d.RbNew.IsChecked -and $d.Pick.IsEnabled)

    # Il nome che esce da OK deve venire dall'ELENCO quando si e' in modalita' esistente.
    $d.Pick.SelectedIndex = 1
    $d.Name.Text = 'refuso-da-ignorare'
    # Il gestore compone il risultato e POI chiude la finestra. Qui la finestra non e'
    # mai stata mostrata come dialogo, quindi `DialogResult` protesta: e' un rumore
    # atteso di questa prova, non un difetto -- il pezzo che conta (il risultato) e'
    # gia' stato scritto. Per questo l'errore si silenzia e non si silenzia il resto.
    $d.Ok.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $r = $d.Esito.Valore
    T "OK usa l'area scelta, non il testo"  ($r -and $r.Name -eq 'beta')
    T "la shell del tab vivo arriva nei tab" (@($r.Tabs)[0].Shell -eq 'pwsh.exe')

    # --- il COLLEGAMENTO fra l'helper e la lista vera -------------------------------
    # Non basta che Get-STLiveRowSpec sia giusta: la finestra deve usarla. Qui si popola
    # la lista con tab finti e si confronta riga per riga con l'helper.
    $finti = @(
        [pscustomobject]@{ Label='a [1]'; Cwd='C:\a'; Aree=@('alfa'); AreaColor='#112233'; Certezza='ricetta'  }
        [pscustomobject]@{ Label='b [2]'; Cwd='C:\b'; Aree=@('alfa'); AreaColor='#112233'; Certezza='cartella' }
        [pscustomobject]@{ Label='c [3]'; Cwd='C:\c'; Aree=@();       AreaColor=$null;     Certezza='nessuna'  }
    )
    Update-LiveList -Tabs $finti
    T "la lista mostra tutte le righe"   ($liveList.Items.Count -eq 3)
    $tuttiUguali = $true
    for ($k = 0; $k -lt $finti.Count; $k++) {
        if ($liveList.Items[$k].Content -ne (Get-STLiveRowSpec -Tab $finti[$k]).Testo) { $tuttiUguali = $false }
    }
    T "ogni riga e' quella dell'helper"  $tuttiUguali
    T "la riga per cartella lo dichiara" ($liveList.Items[1].Content -match 'stessa cartella')
    T "il tab in area ha lo sfondo"      ($liveList.Items[0].Background -and
                                          $liveList.Items[0].Background.Color.ToString() -match '112233')
    # NON "-not Background": in WPF un elemento di lista ha uno sfondo predefinito, che
    # non e' nullo. Quel che conta e' che non abbia il colore DELL'AREA.
    T "il tab libero non ha quel colore" (-not ($liveList.Items[2].Background -and
                                          $liveList.Items[2].Background.Color.ToString() -match '112233'))

    # --- Modifica (colonna sinistra): i titoli delle righe SALVATE --------------
    # Il dialogo legge il file, la persona modifica, il dialogo scrive: qui si prova
    # tutta la catena, compreso il caso in cui il file cambia FRA lettura e scrittura.
    $tmpWs2 = Join-Path $env:TEMP ('st_ui_ed_' + [guid]::NewGuid().ToString('n').Substring(0,8))
    & (Get-Module STerminal) { param($w) $script:STWorkspaces = $w } $tmpWs2
    New-STWorkspace -Name 'ed' -Tabs @(
        @{ Title='uno'; Cwd='C:\x1'; Shell='powershell.exe'; Command='& uno' },
        @{ Title='due'; Cwd='C:\x2'; Shell='pwsh.exe';       Command='& due' },
        @{ Title='';    Cwd='C:\x3'; Shell='powershell.exe'; Command='& tre' }
    ) | Out-Null
    New-STWorkspace -Name 'edtwin' -Tabs @(
        @{ Title='g'; Cwd='C:\g'; Shell='powershell.exe'; Command='& g' },
        @{ Title='g'; Cwd='C:\g'; Shell='powershell.exe'; Command='& g' }
    ) | Out-Null
    $wjEd = Join-Path (Join-Path $tmpWs2 'ed') 'workspace.json'

    $e1 = Invoke-STEditTabsDialog -Name 'ed' -NoShow
    T "Modifica: il dialogo si costruisce"     ($e1.Costruito -eq $true)
    T "una casella per riga salvata"           ($e1.Righe.Count -eq 3)
    T "prefill coi titoli salvati"             ($e1.Righe[0].Box.Text -eq 'uno' -and $e1.Righe[2].Box.Text -eq '')
    T "l'avviso Riprendi c'e'"                 ($e1.Warn.Text -match 'Riprendi')

    # IL SI': un titolo cambia, e solo quello
    $md5Prima = (Get-FileHash -LiteralPath (Join-Path (Join-Path $tmpWs2 'edtwin') 'workspace.json') -Algorithm MD5).Hash
    $e1.Righe[0].Box.Text = 'docker'
    $e1.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $salvato = Get-Content -LiteralPath $wjEd -Raw | ConvertFrom-Json
    T "il si' scrive il titolo nuovo"          ($salvato.Tabs[0].Title -eq 'docker')
    T "e lo marca Fonte=persona"               ($salvato.Tabs[0].Fonte -eq 'persona')
    T "senza toccare il resto della riga"      ($salvato.Tabs[0].Command -eq '& uno' -and $salvato.Tabs[0].Cwd -eq 'C:\x1')
    T "ne' le altre righe"                     ($salvato.Tabs[1].Title -eq 'due' -and $salvato.Tabs[2].Title -eq '')
    T "l'esito lo conta"                       ($e1.Esito.Valore.Rinominate -eq 1 -and $e1.Esito.Valore.Rifiutate -eq 0)
    T "e lo mostra nel dialogo"                ($e1.Results.Text -match "'uno' -> 'docker'")

    # Dopo un si', la riga si ri-indirizza col titolo NUOVO (niente fantasmi)
    $e1.Righe[0].Box.Text = 'docker2'
    $e1.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $salvato = Get-Content -LiteralPath $wjEd -Raw | ConvertFrom-Json
    T "secondo si' sulla stessa riga"          ($salvato.Tabs[0].Title -eq 'docker2')

    # Applica senza cambi: nessuna scrittura, e lo dice
    $md5Ed = (Get-FileHash -LiteralPath $wjEd -Algorithm MD5).Hash
    $e1.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    T "senza cambi non scrive"                 ((Get-FileHash -LiteralPath $wjEd -Algorithm MD5).Hash -eq $md5Ed)
    T "e lo dice"                              ($e1.Results.Text -match 'Nessuna modifica')

    # IL NO: il gemello -- il motore rifiuta e il rifiuto si VEDE
    $e2 = Invoke-STEditTabsDialog -Name 'edtwin' -NoShow
    $e2.Righe[0].Box.Text = 'x'
    $e2.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $gem = Get-Content -LiteralPath (Join-Path (Join-Path $tmpWs2 'edtwin') 'workspace.json') -Raw | ConvertFrom-Json
    T "il gemello non viene toccato"           ($gem.Tabs[0].Title -eq 'g' -and $gem.Tabs[1].Title -eq 'g')
    T "file dei gemelli byte-identico"         ((Get-FileHash -LiteralPath (Join-Path (Join-Path $tmpWs2 'edtwin') 'workspace.json') -Algorithm MD5).Hash -eq $md5Prima)
    T "il rifiuto arriva agli occhi"           ($e2.Results.Text -match 'NON fatta' -and $e2.Results.Text -match '2 righe')

    # IL FILE CAMBIATO SOTTO: lettura, poi il file perde la riga, poi scrittura.
    # L'indirizzo catturato alla lettura non trova piu' la riga: il motore dice no.
    $e3 = Invoke-STEditTabsDialog -Name 'ed' -NoShow
    $e3.Righe[1].Box.Text = 'sparito'
    $resto = Get-Content -LiteralPath $wjEd -Raw | ConvertFrom-Json
    @{ Tabs = @($resto.Tabs | Where-Object { $_.Cwd -ne 'C:\x2' }) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $wjEd -Encoding utf8
    $e3.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    T "file cambiato sotto: il no si vede"     ($e3.Results.Text -match 'NON fatta' -and $e3.Results.Text -match 'nessuna riga')
    $dopo = Get-Content -LiteralPath $wjEd -Raw | ConvertFrom-Json
    T "e nessuna riga e' stata riscritta"      (@($dopo.Tabs).Count -eq 2 -and -not @($dopo.Tabs | Where-Object { $_.Title -eq 'sparito' }))

    # Area senza righe: detto, non spento in silenzio
    $dirV = Join-Path $tmpWs2 'edvuota'; New-Item -ItemType Directory -Force -Path $dirV | Out-Null
    '{"Tabs": []}' | Set-Content -LiteralPath (Join-Path $dirV 'workspace.json') -Encoding utf8
    $e4 = Invoke-STEditTabsDialog -Name 'edvuota' -NoShow
    T "area vuota: lo dice"                    ($e4.Results.Text -match 'non ha righe')

    # --- Modifica: anche il NOME DELL'AREA, nello stesso posto ("in modifica puoi
    # gestire i nomi" -- il disegno). Due gesti, un Applica: area PRIMA, titoli POI
    # col nome corrente. La sequenza non ha rollback: ogni esito si mostra intero.
    New-STWorkspace -Name 'edarea' -Tabs @(@{ Title='r1'; Cwd='C:\ea'; Shell='powershell.exe'; Command='& ea' }) | Out-Null
    $f1 = Invoke-STEditTabsDialog -Name 'edarea' -NoShow
    T "la casella del nome area c'e'"            ($f1.AreaBox.Text -eq 'edarea')
    $f1.AreaBox.Text = 'edarea-new'
    $f1.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $wa = Get-Content -LiteralPath (Join-Path (Join-Path $tmpWs2 'edarea-new') 'workspace.json') -Raw | ConvertFrom-Json
    T "dalla finestra si rinomina l'area"        ((Test-Path -LiteralPath (Join-Path $tmpWs2 'edarea-new')) -and -not (Test-Path -LiteralPath (Join-Path $tmpWs2 'edarea')))
    T "il file porta il nome nuovo"              ($wa.Name -eq 'edarea-new')
    T "la riga e' venuta dietro intatta"         ($wa.Tabs[0].Title -eq 'r1' -and $wa.Tabs[0].Command -eq '& ea')
    T "l'esito conta anche l'area"               ($f1.Esito.Valore.AreaRinominata -and $f1.Esito.Valore.AreaNome -eq 'edarea-new')
    T "e lo mostra nel dialogo"                  ($f1.Results.Text -match "Area: 'edarea' -> 'edarea-new'")
    # Dopo la rinomina, il prossimo Applica deve lavorare col nome NUOVO
    $f1.Righe[0].Box.Text = 'r1bis'
    $f1.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $wa = Get-Content -LiteralPath (Join-Path (Join-Path $tmpWs2 'edarea-new') 'workspace.json') -Raw | ConvertFrom-Json
    T "dopo la rinomina i titoli vanno col nome nuovo" ($wa.Tabs[0].Title -eq 'r1bis')

    # Area + titoli nello STESSO Applica: tutti e due, e il file giusto
    New-STWorkspace -Name 'edboth' -Tabs @(@{ Title='t1'; Cwd='C:\eb'; Shell='powershell.exe'; Command='& eb' }) | Out-Null
    $f2 = Invoke-STEditTabsDialog -Name 'edboth' -NoShow
    $f2.AreaBox.Text = 'edboth-new'
    $f2.Righe[0].Box.Text = 't1new'
    $f2.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $wb = Get-Content -LiteralPath (Join-Path (Join-Path $tmpWs2 'edboth-new') 'workspace.json') -Raw | ConvertFrom-Json
    T "stesso Applica: area rinominata"          ($wb.Name -eq 'edboth-new')
    T "stesso Applica: titolo nel file giusto"   ($wb.Tabs[0].Title -eq 't1new' -and $wb.Tabs[0].Fonte -eq 'persona')
    T "il vecchio nome non esiste piu'"          (-not (Test-Path -LiteralPath (Join-Path $tmpWs2 'edboth')))

    # La guardia si VEDE: il punto ferma l'area, e i titoli vanno col nome vecchio --
    # mezzo fatto, detto intero
    New-STWorkspace -Name 'edguard' -Tabs @(@{ Title='vecchio'; Cwd='C:\eg'; Shell='powershell.exe'; Command='& eg' }) | Out-Null
    $f3 = Invoke-STEditTabsDialog -Name 'edguard' -NoShow
    $f3.AreaBox.Text = 'ed.guard'
    $f3.Righe[0].Box.Text = 'nuovo'
    $f3.Applica.RaiseEvent((New-Object System.Windows.RoutedEventArgs ([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) 2>$null
    $wg = Get-Content -LiteralPath (Join-Path (Join-Path $tmpWs2 'edguard') 'workspace.json') -Raw | ConvertFrom-Json
    T "nome col punto: la guardia si vede"       ($f3.Results.Text -match 'Area NON rinominata' -and $f3.Results.Text -match 'sembrare un file')
    T "la cartella non si e' mossa"              ($wg.Name -eq 'edguard')
    T "il titolo e' andato col nome vecchio"     ($wg.Tabs[0].Title -eq 'nuovo')
    T "mezzo fatto, detto intero"                ($f3.Esito.Valore.AreaRifiutata -and $f3.Esito.Valore.Rinominate -eq 1)

    "`n=== TestAddDialog: $(if ($ok) { 'TUTTO VERDE' } else { 'CI SONO FAIL' }) ==="
    if (-not $ok) { exit 1 }
    return
}

Update-All
if (-not $NoShow) { [void]$win.ShowDialog() }
