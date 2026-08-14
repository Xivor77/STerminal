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
                @{ Title = $r.TitleBox.Text; Color = $col; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command; Shell = $r.Tab.Shell }
            })
            $esito.Valore = @{ Name = $name; AutoColor = $false; Tabs = $tabs }
        } else {
            $tabs = @(foreach ($r in $rowCtrls) { @{ Title = $r.Tab.What; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command; Shell = $r.Tab.Shell } })
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
          <Button x:Name="BtnRefresh" Content="Aggiorna" Width="90" Height="30"/>
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
    Update-WsList
    # Si dice cosa e' successo, non cosa era stato chiesto: prima questa riga annunciava
    # sempre il numero di tab selezionati, anche quando il motore ne aveva scartati.
    $t = "Aggiunti $($esito.Added) tab a '$($esito.Name)' (l'area ne ha $($esito.Total))."
    if ($esito.SkippedRecipe) { $t += "  $($esito.SkippedRecipe) c'erano gia': saltati." }
    $status.Text = $t
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

    "`n=== TestAddDialog: $(if ($ok) { 'TUTTO VERDE' } else { 'CI SONO FAIL' }) ==="
    if (-not $ok) { exit 1 }
    return
}

Update-All
if (-not $NoShow) { [void]$win.ShowDialog() }
