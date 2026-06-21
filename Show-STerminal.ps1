# STerminal - mini-interfaccia (WPF). App a parte: scegli un'area di lavoro da riprendere,
# salva i tab aperti come nuova area, elimina. Il Terminal classico resta vuoto e puo'
# riprendere un'area col comando Resume-STWorkspace.
#
# Avvio:  powershell.exe -WindowStyle Hidden -File "C:\projects\STerminal\Show-STerminal.ps1"
# (5.1 e' STA di default, quello che serve a WPF.)
#
# ASCII puro.
param([switch]$NoShow)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName Microsoft.VisualBasic

Import-Module (Join-Path $PSScriptRoot 'STerminal.psm1') -Force

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="STerminal - Aree di lavoro" Height="440" Width="480"
        WindowStartupLocation="CenterScreen">
  <Grid Margin="12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <TextBlock Grid.Row="0" Text="Scegli un'area di lavoro" FontSize="15" FontWeight="Bold" Margin="0,0,0,8"/>
    <ListBox x:Name="List" Grid.Row="1" FontSize="13"/>
    <WrapPanel Grid.Row="2" Margin="0,10,0,0">
      <Button x:Name="BtnResume"  Content="Riprendi"            Width="110" Height="32" Margin="0,0,8,0"/>
      <Button x:Name="BtnSave"    Content="Salva tab aperti..." Width="140" Height="32" Margin="0,0,8,0"/>
      <Button x:Name="BtnDelete"  Content="Elimina"             Width="90"  Height="32" Margin="0,0,8,0"/>
      <Button x:Name="BtnRefresh" Content="Aggiorna"            Width="90"  Height="32"/>
    </WrapPanel>
    <TextBlock x:Name="Status" Grid.Row="3" Margin="0,10,0,0" Foreground="Gray"/>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [Windows.Markup.XamlReader]::Load($reader)

$list    = $win.FindName('List')
$btnRes  = $win.FindName('BtnResume')
$btnSave = $win.FindName('BtnSave')
$btnDel  = $win.FindName('BtnDelete')
$btnRef  = $win.FindName('BtnRefresh')
$status  = $win.FindName('Status')

function Update-List {
    $list.Items.Clear()
    $wss = @(Get-STWorkspace)
    foreach ($w in $wss) {
        $n = if ($w.Tabs) { @($w.Tabs).Count } else { 0 }
        $item = New-Object System.Windows.Controls.ListBoxItem
        $item.Content = "$($w.Name)   ($n tab)"
        $item.Tag = $w.Name
        [void]$list.Items.Add($item)
    }
    $status.Text = "$($wss.Count) aree di lavoro salvate"
}

$btnRes.Add_Click({
    if ($list.SelectedItem) {
        $name = $list.SelectedItem.Tag
        $status.Text = "Riprendo '$name'..."
        Resume-STWorkspace -Name $name
        $win.Close()
    } else { $status.Text = "Seleziona prima un'area." }
})

$btnSave.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Nome della nuova area (dai tab attualmente aperti):", "STerminal - Salva", "")
    if ($name) {
        Save-STWorkspace -Name $name
        Update-List
        $status.Text = "Area '$name' salvata dai tab aperti."
    }
})

$btnDel.Add_Click({
    if ($list.SelectedItem) {
        $name = $list.SelectedItem.Tag
        Remove-STWorkspace -Name $name
        Update-List
        $status.Text = "Area '$name' eliminata."
    } else { $status.Text = "Seleziona prima un'area." }
})

$btnRef.Add_Click({ Update-List })

Update-List

if (-not $NoShow) { [void]$win.ShowDialog() }
