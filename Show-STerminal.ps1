# STerminal - mini-interfaccia (WPF). Due sezioni:
#  - Aree di lavoro: scegli e Riprendi / Elimina.
#  - Tab aperti: lista dei tab vivi (anche occupati), seleziona uno o piu' -> Aggiungi a gruppo.
#
# Avvio:  powershell.exe -WindowStyle Hidden -File "C:\projects\STerminal\Show-STerminal.ps1"
# ASCII puro. Compatibile 5.1 (STA di default) e 7 (-sta).
param([switch]$NoShow)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName Microsoft.VisualBasic

Import-Module (Join-Path $PSScriptRoot 'STerminal.psm1') -Force

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

      <!-- Colonna sinistra: aree di lavoro -->
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

      <!-- Colonna destra: tab aperti -->
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

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$wsList    = $win.FindName('WsList')
$liveList  = $win.FindName('LiveList')
$btnResume = $win.FindName('BtnResume')
$btnDelete = $win.FindName('BtnDelete')
$btnRefresh= $win.FindName('BtnRefresh')
$btnAdd    = $win.FindName('BtnAddGroup')
$status    = $win.FindName('Status')

function Update-WsList {
    $wsList.Items.Clear()
    $wss = @(Get-STWorkspace)
    foreach ($w in $wss) {
        $n = if ($w.Tabs) { @($w.Tabs).Count } else { 0 }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "$($w.Name)   ($n tab)"
        $item.Tag = $w.Name
        [void]$wsList.Items.Add($item)
    }
}

function Update-LiveList {
    $liveList.Items.Clear()
    foreach ($t in @(Get-STLiveTab | Sort-Object Cwd)) {
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = $t.Label
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
    $esistenti = ((Get-STWorkspace).Name | Sort-Object) -join ', '
    $grp = [Microsoft.VisualBasic.Interaction]::InputBox("Nome del gruppo a cui aggiungere i $($sel.Count) tab selezionati.`nEsistenti: $esistenti", "STerminal - Aggiungi a gruppo", "")
    if (-not $grp) { return }
    $tabs = @(foreach ($it in $sel) { $o = $it.Tag; @{ Title = $o.What; Cwd = $o.Cwd; Command = $o.Command } })
    Add-STWorkspaceTab -Name $grp -Tabs $tabs
    Update-WsList
    $status.Text = "Aggiunti $($sel.Count) tab al gruppo '$grp'."
})

Update-All

if (-not $NoShow) { [void]$win.ShowDialog() }
