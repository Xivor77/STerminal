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
    param([object[]]$LiveTabs, [switch]$NoShow)

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
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="Gruppo:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="GroupName" Width="400"/>
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

    $toggle = { $rows.IsEnabled = [bool]$rbMan.IsChecked }
    $rbAuto.Add_Checked($toggle); $rbMan.Add_Checked($toggle)
    $rows.IsEnabled = $false

    $script:STDlgResult = $null
    $ok.Add_Click({
        $name = $gName.Text.Trim()
        if (-not $name) { $gName.Focus(); return }
        if ($rbMan.IsChecked) {
            $tabs = @(foreach ($r in $rowCtrls) {
                $col = if ($r.ColorBox.SelectedItem) { [string]$r.ColorBox.SelectedItem.Content } else { $null }
                @{ Title = $r.TitleBox.Text; Color = $col; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command }
            })
            $script:STDlgResult = @{ Name = $name; AutoColor = $false; Tabs = $tabs }
        } else {
            $tabs = @(foreach ($r in $rowCtrls) { @{ Title = $r.Tab.What; Cwd = $r.Tab.Cwd; Command = $r.Tab.Command } })
            $script:STDlgResult = @{ Name = $name; AutoColor = $true; Tabs = $tabs }
        }
        $dlg.DialogResult = $true; $dlg.Close()
    })
    $cancel.Add_Click({ $dlg.DialogResult = $false; $dlg.Close() })

    if ($NoShow) { return 'BUILT-OK' }
    try { $dlg.Owner = $win } catch { }
    [void]$dlg.ShowDialog()
    return $script:STDlgResult
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
          <TextBlock Text="ogni riga:  path  -  attivita del tab  [pid]" FontSize="11" Foreground="Gray"/>
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
        [void]$wsList.Items.Add($item)
    }
}
function Update-LiveList {
    $liveList.Items.Clear()
    foreach ($t in @(Get-STLiveTab | Sort-Object Cwd)) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $t.Label; $item.Tag = $t
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
    if ($r.AutoColor) { Add-STWorkspaceTab -Name $r.Name -Tabs $r.Tabs -AutoColor }
    else { Add-STWorkspaceTab -Name $r.Name -Tabs $r.Tabs }
    Update-WsList
    $status.Text = "Aggiunti $(@($r.Tabs).Count) tab al gruppo '$($r.Name)'."
})

Update-All

if ($TestAddDialog) {
    $dummy = @(
        [pscustomobject]@{ What='claude'; Cwd='C:\projects\x'; Command="& claude"; Label='x - claude [1]' }
        [pscustomobject]@{ What='caddy';  Cwd='C:\projects\y'; Command="& caddy";  Label='y - caddy [2]' }
    )
    "TestAddDialog: " + (Invoke-STAddDialog -LiveTabs $dummy -NoShow)
    return
}

if (-not $NoShow) { [void]$win.ShowDialog() }
