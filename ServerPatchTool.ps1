#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Server Patch Management Tool
.DESCRIPTION
    A WPF-based GUI tool for scanning, installing Windows Updates,
    and managing reboots across AD-joined Windows Servers.
    Credentials are requested once at launch and reused for the session.
.NOTES
    Run as: powershell -ExecutionPolicy Bypass -File ServerPatchTool.ps1
#>

# -- Assemblies ----------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# -- Persistent server list file ----------------------------------------------
$script:DataFile = Join-Path $PSScriptRoot "servers.json"

# Credentials live under the user profile rather than next to the script: the
# DPAPI blob is scoped to this Windows account, so the file belongs with the
# account, not with a tool folder that may sit on a share.
$script:CredDir  = Join-Path $env:LOCALAPPDATA "ServerPatchTool"
$script:CredFile = Join-Path $script:CredDir "credentials.json"

# -- Log file -----------------------------------------------------------------
# One file per day next to the script. The in-window log is cleared on close,
# which left no record of what was patched during a change window.
$script:LogDir  = Join-Path $PSScriptRoot "logs"
$script:LogFile = Join-Path $script:LogDir ("ServerPatchTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

# -- XAML UI Definition --------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server Patch Tool" Height="720" Width="1240"
        MinHeight="600" MinWidth="1000"
        WindowStartupLocation="CenterScreen"
        Background="#1e1e2e" Foreground="#cdd6f4">

    <Window.Resources>
        <!-- Dark theme styles -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#45475a"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#585b70"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="Margin" Value="3"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#585b70"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#6c7086"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#89b4fa"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderThickness="0" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#b4d0fb"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#74c7ec"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#f38ba8"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderThickness="0" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#f5a3b8"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#eba0ac"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SuccessButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#a6e3a1"/>
            <Setter Property="Foreground" Value="#1e1e2e"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderThickness="0" CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#b8edb4"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#94e2d5"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#313244"/>
                                <Setter Property="Foreground" Value="#585b70"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#585b70"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="CaretBrush" Value="#cdd6f4"/>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#585b70"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="6,4"/>
        </Style>

        <!-- Without this the dropdown items keep the system's light background
             and the light foreground above becomes unreadable. -->
        <Style TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="Padding" Value="6,3"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#181825"/>
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="RowBackground" Value="#1e1e2e"/>
            <Setter Property="AlternatingRowBackground" Value="#232336"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#313244"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="SelectionMode" Value="Extended"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>

        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#313244"/>
            <Setter Property="Foreground" Value="#a6adc8"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="BorderBrush" Value="#45475a"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>

        <Style TargetType="DataGridRow">
            <Setter Property="Foreground" Value="#cdd6f4"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#45475a"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="DataGridCell">
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="DataGridCell">
                        <Border Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#45475a"/>
                    <Setter Property="Foreground" Value="#cdd6f4"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="140"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Border Grid.Row="0" Margin="0,0,0,12">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Text="&#x1F6E1;" FontSize="24" VerticalAlignment="Center" Margin="0,0,8,0"/>
                    <TextBlock Text="Server Patch Tool" FontSize="22" FontWeight="Bold"
                               Foreground="#89b4fa" VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="txtCredentialStatus" Text="No credentials"
                               Foreground="#f38ba8" VerticalAlignment="Center" Margin="0,0,10,0" FontSize="13"/>
                    <CheckBox x:Name="chkRememberCredentials" Content="Remember"
                              Margin="0,0,10,0" FontSize="12" VerticalAlignment="Center"
                              ToolTip="Save credentials for the next launch. Encrypted for your Windows account on this computer only - the file is useless elsewhere."/>
                    <Button x:Name="btnAddCredential" Content="Add Credential" FontSize="12"
                            ToolTip="Add a new credential set (domain\username)"/>
                    <Button x:Name="btnManageCredentials" Content="Manage" FontSize="12"
                            ToolTip="View and remove saved credentials"/>
                    <Button x:Name="btnChangePassword" Content="Change Password" FontSize="12"
                            ToolTip="Replace the password stored for a saved credential"/>
                    <Button x:Name="btnTestCredential" Content="Test" FontSize="12"
                            ToolTip="Check that a saved credential still authenticates, before a maintenance window finds out the hard way"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Toolbar -->
        <Border Grid.Row="1" Background="#181825" CornerRadius="6" Padding="10" Margin="0,0,0,10">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <!-- Add servers -->
                <StackPanel Grid.Column="0" Orientation="Horizontal">
                    <TextBox x:Name="txtServerName" Width="260" VerticalContentAlignment="Center"
                             ToolTip="Enter server name(s) separated by commas, or an AD search filter"/>
                    <Button x:Name="btnAddServer" Content="Add Server(s)" Style="{StaticResource AccentButton}"/>
                    <Button x:Name="btnBrowseAD" Content="Browse AD" ToolTip="Import servers from Active Directory OU"/>
                    <Button x:Name="btnImportFile" Content="Import CSV" ToolTip="Import server list from text/CSV file"/>
                    <Border Width="1" Background="#45475a" Margin="8,2"/>
                    <Button x:Name="btnRemoveSelected" Content="Remove Selected"/>
                    <Button x:Name="btnClearAll" Content="Clear All"/>
                </StackPanel>

                <!-- Bulk actions -->
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <Border Width="1" Background="#45475a" Margin="8,2"/>
                    <TextBlock Text="Mode:" Foreground="#a6adc8" VerticalAlignment="Center"
                               Margin="4,0,4,0" FontSize="12"/>
                    <Border Background="#313244" CornerRadius="4" Padding="2" VerticalAlignment="Center">
                        <StackPanel Orientation="Horizontal">
                            <RadioButton x:Name="rbParallel" Content="Parallel" IsChecked="True"
                                         Foreground="#cdd6f4" Margin="6,2,8,2" FontSize="12"
                                         VerticalContentAlignment="Center"
                                         ToolTip="Update all selected servers at the same time"/>
                            <RadioButton x:Name="rbSequential" Content="Sequential"
                                         Foreground="#cdd6f4" Margin="4,2,6,2" FontSize="12"
                                         VerticalContentAlignment="Center"
                                         ToolTip="Update servers one-by-one, waiting for each to finish before starting the next"/>
                        </StackPanel>
                    </Border>
                    <TextBlock Text="Max parallel:" Foreground="#a6adc8" VerticalAlignment="Center"
                               Margin="10,0,4,0" FontSize="12"/>
                    <ComboBox x:Name="cboParallel" Width="58" VerticalAlignment="Center"
                              SelectedIndex="3"
                              ToolTip="How many servers may be worked on at the same time in Parallel mode">
                        <ComboBoxItem Content="1"/>
                        <ComboBoxItem Content="2"/>
                        <ComboBoxItem Content="5"/>
                        <ComboBoxItem Content="10"/>
                        <ComboBoxItem Content="15"/>
                        <ComboBoxItem Content="20"/>
                        <ComboBoxItem Content="30"/>
                    </ComboBox>
                    <TextBlock Text="Limit:" Foreground="#a6adc8" VerticalAlignment="Center"
                               Margin="10,0,4,0" FontSize="12"
                               ToolTip="Time limit for a single install"/>
                    <ComboBox x:Name="cboInstallTimeout" Width="72" VerticalAlignment="Center"
                              SelectedIndex="2"
                              ToolTip="How long to wait for an install before giving up on watching it. A cumulative update often needs more than an hour. Running out of time does not cancel anything: the install carries on and the server is marked 'Still installing'.">
                        <ComboBoxItem Content="30 min"/>
                        <ComboBoxItem Content="60 min"/>
                        <ComboBoxItem Content="90 min"/>
                        <ComboBoxItem Content="120 min"/>
                        <ComboBoxItem Content="180 min"/>
                        <ComboBoxItem Content="240 min"/>
                    </ComboBox>
                    <TextBlock Text="Reboot:" Foreground="#a6adc8" VerticalAlignment="Center"
                               Margin="10,0,4,0" FontSize="12"
                               ToolTip="How long to watch for a server to come back"/>
                    <ComboBox x:Name="cboRebootTimeout" Width="72" VerticalAlignment="Center"
                              SelectedIndex="1"
                              ToolTip="How long to watch for a server to come back after a reboot. A server that applies a cumulative update while booting can take far longer than the default. Running out of time does not cancel anything - the server is simply no longer watched.">
                        <ComboBoxItem Content="15 min"/>
                        <ComboBoxItem Content="30 min"/>
                        <ComboBoxItem Content="45 min"/>
                        <ComboBoxItem Content="60 min"/>
                        <ComboBoxItem Content="90 min"/>
                        <ComboBoxItem Content="120 min"/>
                    </ComboBox>
                    <Button x:Name="btnHeldBackKB" Content="Held-back KBs" FontSize="12" Margin="10,0,0,0"
                            ToolTip="Updates to skip on every install - for a cumulative that is known to fail here, or one waiting on a vendor fix"/>
                    <Border Width="1" Background="#45475a" Margin="8,2"/>
                    <Button x:Name="btnScanSelected" Content="Scan Selected" Style="{StaticResource AccentButton}"
                            ToolTip="Check for updates on checked servers only"/>
                    <Button x:Name="btnInstallSelected" Content="Install Selected" Style="{StaticResource SuccessButton}"
                            ToolTip="Install updates on checked servers only"/>
                    <Button x:Name="btnRebootSelected" Content="Reboot Selected" Style="{StaticResource DangerButton}"
                            ToolTip="Reboot checked servers that require it"/>
                    <Border Width="1" Background="#45475a" Margin="8,2"/>
                    <Button x:Name="btnScanAll" Content="Scan All" Style="{StaticResource AccentButton}"
                            ToolTip="Check for available updates on ALL servers"/>
                    <Button x:Name="btnInstallAll" Content="Install All" Style="{StaticResource SuccessButton}"
                            ToolTip="Install available updates on ALL servers"/>
                    <Button x:Name="btnRebootAll" Content="Reboot All" Style="{StaticResource DangerButton}"
                            ToolTip="Reboot ALL servers that require it"/>
                    <Border Width="1" Background="#45475a" Margin="8,2"/>
                    <Button x:Name="btnExportCSV" Content="Export" ToolTip="Export results to CSV"/>
                    <Button x:Name="btnStop" Content="Stop" Style="{StaticResource DangerButton}"
                            IsEnabled="False"
                            ToolTip="Stop queued work and stop monitoring. Work already sent to a server cannot be recalled."/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Server Grid -->
        <DataGrid Grid.Row="2" x:Name="dgServers"
                  AutoGenerateColumns="False"
                  CanUserAddRows="False"
                  CanUserDeleteRows="False"
                  IsReadOnly="False"
                  SelectionUnit="FullRow"
                  Margin="0,0,0,10">
            <DataGrid.Columns>
                <DataGridCheckBoxColumn Binding="{Binding Selected, UpdateSourceTrigger=PropertyChanged}"
                                        Header="" Width="30" IsReadOnly="False"/>
                <DataGridTextColumn Binding="{Binding ServerName}" Header="Server" Width="160" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding CredentialLabel}" Header="Credential" Width="110" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding Status}" Header="Status" Width="120" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding Available}" Header="Available" Width="80" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding Installed}" Header="Installed" Width="80" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding RebootRequired}" Header="Reboot?" Width="80" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding LastScan}" Header="Last Scan" Width="150" IsReadOnly="True"/>
                <DataGridTextColumn Binding="{Binding Details}" Header="Details" Width="*" IsReadOnly="True"/>
            </DataGrid.Columns>

            <DataGrid.ContextMenu>
                <ContextMenu>
                    <MenuItem x:Name="ctxScan" Header="Scan for Updates"/>
                    <MenuItem x:Name="ctxInstall" Header="Install Updates"/>
                    <MenuItem x:Name="ctxReboot" Header="Reboot Server"/>
                    <Separator/>
                    <MenuItem x:Name="ctxViewUpdates" Header="View Available Updates"/>
                    <Separator/>
                    <MenuItem x:Name="ctxAssignCredential" Header="Assign Credential"/>
                    <Separator/>
                    <MenuItem x:Name="ctxSelectAll" Header="Select All"/>
                    <MenuItem x:Name="ctxDeselectAll" Header="Deselect All"/>
                    <Separator/>
                    <MenuItem x:Name="ctxRemove" Header="Remove from List"/>
                </ContextMenu>
            </DataGrid.ContextMenu>
        </DataGrid>

        <!-- Status bar -->
        <Border Grid.Row="3" Margin="0,0,0,6">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" Orientation="Horizontal">
                    <TextBlock x:Name="txtStatusBar" Text="Ready" Foreground="#a6adc8" FontSize="12"
                               VerticalAlignment="Center"/>
                </StackPanel>
                <StackPanel Grid.Column="1" Orientation="Horizontal">
                    <TextBlock x:Name="txtServerCount" Text="0 servers" Foreground="#a6adc8"
                               FontSize="12" VerticalAlignment="Center" Margin="0,0,16,0"/>
                    <ProgressBar x:Name="progressBar" Width="200" Height="8"
                                 Background="#313244" Foreground="#89b4fa"
                                 BorderThickness="0" Visibility="Collapsed"/>
                </StackPanel>
            </Grid>
        </Border>

        <!-- Log panel -->
        <Border Grid.Row="4" Background="#181825" CornerRadius="6" Padding="2">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Margin="8,4">
                    <TextBlock Text="Activity Log" FontSize="12" FontWeight="SemiBold"
                               Foreground="#a6adc8" VerticalAlignment="Center"/>
                    <Button x:Name="btnClearLog" Content="Clear" HorizontalAlignment="Right"
                            FontSize="11" Padding="8,2"/>
                </Grid>
                <TextBox Grid.Row="1" x:Name="txtLog"
                         IsReadOnly="True" TextWrapping="Wrap"
                         VerticalScrollBarVisibility="Auto"
                         Background="#11111b" Foreground="#a6adc8"
                         BorderThickness="0" FontFamily="Consolas" FontSize="12"
                         Margin="4,0,4,4"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# -- Create Window -------------------------------------------------------------
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# -- Resolve named controls ---------------------------------------------------
$ui = @{}
$xaml.SelectNodes('//*[@*[contains(translate(name(),"x","X"),"Name")]]') | ForEach-Object {
    $name = $_.Name
    if (-not $name) { $name = $_.'x:Name' }
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# -- State ---------------------------------------------------------------------
$script:Credentials  = @{}   # Key = "DOMAIN\user" (label), Value = PSCredential object
$script:DefaultCredentialLabel = $null  # label of the default/first credential added
$script:ServerData   = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:RunspacePool = $null
$script:ActiveJobs   = [System.Collections.Generic.List[PSObject]]::new()

$ui.dgServers.ItemsSource = $script:ServerData

# -- Sequential queue state ----------------------------------------------------
$script:SequentialQueue = [System.Collections.Generic.Queue[string]]::new()
$script:SequentialRunning = $false

# -- Persistent Storage --------------------------------------------------------
function Save-ServerList {
    # Scan results are persisted too, so a restart no longer wipes the picture
    # of the estate. LastScan travels with them, which is what tells the user
    # how stale the numbers are.
    $data = @($script:ServerData | ForEach-Object {
        @{
            Name           = $_.ServerName
            Credential     = $_.CredentialLabel
            Selected       = [bool]$_.Selected
            Status         = $_.Status
            Available      = $_.Available
            Installed      = $_.Installed
            RebootRequired = $_.RebootRequired
            LastScan       = $_.LastScan
            Details        = $_.Details
            UpdateList     = $_.UpdateList
        }
    })
    $data | ConvertTo-Json -Depth 5 | Set-Content -Path $script:DataFile -Encoding UTF8 -Force
}

function Load-ServerList {
    if (Test-Path $script:DataFile) {
        try {
            $raw = Get-Content $script:DataFile -Raw | ConvertFrom-Json
            foreach ($item in $raw) {
                # Support both old format (plain strings) and new format (objects with Name/Credential)
                $name = $null
                $credLabel = ""
                if ($item -is [string]) {
                    $name = $item
                } elseif ($item.Name) {
                    $name = $item.Name
                    $credLabel = if ($item.Credential) { $item.Credential } else { "" }
                }
                if ($name -and -not ($script:ServerData | Where-Object { $_.ServerName -eq $name })) {
                    $entry = New-ServerEntry -Name $name -CredLabel $credLabel

                    if ($item -isnot [string]) {
                        if ($null -ne $item.Selected)  { $entry.Selected       = [bool]$item.Selected }
                        if ($item.Status)              { $entry.Status         = $item.Status }
                        if ($item.Available)           { $entry.Available      = $item.Available }
                        if ($item.Installed)           { $entry.Installed      = $item.Installed }
                        if ($item.RebootRequired)      { $entry.RebootRequired = $item.RebootRequired }
                        if ($item.LastScan)            { $entry.LastScan       = $item.LastScan }
                        if ($item.Details)             { $entry.Details        = $item.Details }
                        if ($item.UpdateList)          { $entry.UpdateList     = @($item.UpdateList) }

                        # A status like "Installing..." only means something
                        # while a job is behind it. After a restart there is
                        # none, so say the operation was interrupted rather
                        # than imply work is still in flight.
                        if ($entry.Status -like "Scanning*" -or
                            $entry.Status -like "Installing*" -or
                            $entry.Status -like "Rebooting*") {
                            $entry.Details = "Tool was closed during '$($entry.Status)'. Rescan to get the current state."
                            $entry.Status  = "Interrupted"
                        }
                    }

                    $script:ServerData.Add($entry)
                }
            }
            Write-Log "Loaded $(@($raw).Count) server(s) from saved list"
        } catch {
            Write-Log "Failed to load saved server list: $($_.Exception.Message)" "WARN"
        }
    }
    Update-ServerCount
}

# -- Helpers -------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $now = Get-Date
    $window.Dispatcher.Invoke([action]{
        $ui.txtLog.AppendText("[$($now.ToString('HH:mm:ss'))] $Level  $Message`r`n")
        $ui.txtLog.ScrollToEnd()
    })
    # Persist to disk as well, so the run leaves an audit trail. A failure to
    # write must never take down the UI, hence the swallow.
    try {
        Add-Content -Path $script:LogFile -Encoding UTF8 -ErrorAction Stop `
            -Value ("{0} {1,-5} {2}" -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    } catch { }
}

function Update-StatusBar {
    param([string]$Text)
    $window.Dispatcher.Invoke([action]{
        $ui.txtStatusBar.Text = $Text
    })
}

function Update-ServerCount {
    $window.Dispatcher.Invoke([action]{
        $count = $script:ServerData.Count
        $ui.txtServerCount.Text = "$count server$(if($count -ne 1){'s'})"
    })
}

function Show-Progress {
    param([bool]$Visible, [int]$Value = 0, [int]$Max = 100)
    $window.Dispatcher.Invoke([action]{
        $ui.progressBar.Visibility = if ($Visible) { "Visible" } else { "Collapsed" }
        $ui.progressBar.Maximum = $Max
        $ui.progressBar.Value = $Value
    })
}

# Progress is tracked per batch. Show-Progress on its own was only ever called
# with -Value 0, so the bar stayed empty for the entire run.
$script:ProgressTotal = 0
$script:ProgressDone  = 0

function Start-ProgressBatch {
    param([int]$Total)
    $script:ProgressTotal = $Total
    $script:ProgressDone  = 0
    Show-Progress -Visible $true -Value 0 -Max $Total
}

function Step-Progress {
    # Ad-hoc single operations (context menu, post-reboot rescan) run outside a
    # batch and must not push the bar past its maximum.
    if ($script:ProgressTotal -le 0) { return }
    $script:ProgressDone++
    Show-Progress -Visible $true -Max $script:ProgressTotal `
                  -Value ([Math]::Min($script:ProgressDone, $script:ProgressTotal))
    if ($script:ProgressDone -ge $script:ProgressTotal) { $script:ProgressTotal = 0 }
}

function New-ServerEntry {
    param([string]$Name, [string]$CredLabel = "")
    $label = $CredLabel
    if (-not $label -and $script:DefaultCredentialLabel) {
        $label = $script:DefaultCredentialLabel
    }
    [PSCustomObject]@{
        Selected        = $true
        ServerName      = $Name.Trim().ToUpper()
        CredentialLabel = $label
        Status          = "Added"
        Available       = "-"
        Installed       = "-"
        RebootRequired  = "-"
        LastScan        = "-"
        Details         = ""
        UpdateList      = @()
    }
}

function Get-StatusColor {
    param([string]$Status)
    switch -Wildcard ($Status) {
        "Up to date"       { "#a6e3a1" }  # green
        "Back Online"      { "#a6e3a1" }  # green
        "Available*"       { "#f9e2af" }  # yellow
        "Installing*"      { "#89b4fa" }  # blue
        "Rebooting*"       { "#cba6f7" }  # purple
        "Reboot Req*"      { "#fab387" }  # peach
        "Scanning*"        { "#89dceb" }  # sky
        "Error*"           { "#f38ba8" }  # red
        "Offline"          { "#6c7086" }  # grey
        "Partially Online" { "#fab387" }  # peach
        default            { "#cdd6f4" }  # text
    }
}

# -- Saved credentials (DPAPI) ------------------------------------------------
# ConvertFrom-SecureString protects the password with DPAPI under the current
# user, so the stored blob is worthless to any other Windows account and on any
# other machine. It is NOT protection against this account: anything running as
# this user on this PC can decrypt it, which is why saving is opt-in.
function Save-Credentials {
    if (-not $ui.chkRememberCredentials.IsChecked) { return }
    try {
        # Nothing left to remember means the file has to go, not be rewritten
        # empty: piping an empty array into ConvertTo-Json produces no output
        # at all, so Set-Content left the previous contents untouched and the
        # last credential removed reappeared on the next launch.
        if ($script:Credentials.Count -eq 0) {
            Remove-SavedCredentials
            return
        }
        if (-not (Test-Path -LiteralPath $script:CredDir)) {
            New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null
        }
        $data = @(foreach ($label in @($script:Credentials.Keys)) {
            $c = $script:Credentials[$label]
            @{
                UserName  = $c.UserName
                Password  = ($c.Password | ConvertFrom-SecureString)
                IsDefault = ($label -eq $script:DefaultCredentialLabel)
            }
        })
        $data | ConvertTo-Json -Depth 3 | Set-Content -Path $script:CredFile -Encoding UTF8 -Force
    } catch {
        Write-Log "Could not save credentials: $($_.Exception.Message)" "WARN"
    }
}

function Load-Credentials {
    if (-not (Test-Path -LiteralPath $script:CredFile)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $script:CredFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($raw)) {
            if (-not $item.UserName -or -not $item.Password) { continue }
            $sec  = ConvertTo-SecureString $item.Password -ErrorAction Stop
            $cred = New-Object System.Management.Automation.PSCredential($item.UserName, $sec)
            $script:Credentials[$item.UserName] = $cred
            if ($item.IsDefault -or -not $script:DefaultCredentialLabel) {
                $script:DefaultCredentialLabel = $item.UserName
            }
        }
    } catch {
        # Normally means the file was written by a different Windows account or
        # copied from another machine, so DPAPI refuses to unprotect it.
        Write-Log "Saved credentials could not be decrypted - please re-enter them" "WARN"
        $script:Credentials.Clear()
        $script:DefaultCredentialLabel = $null
        Remove-SavedCredentials
        return $false
    }
    if ($script:Credentials.Count -gt 0) {
        Update-CredentialStatus
        Write-Log "Restored $($script:Credentials.Count) saved credential(s)"
        return $true
    }
    return $false
}

function Remove-SavedCredentials {
    if (Test-Path -LiteralPath $script:CredFile) {
        Remove-Item -LiteralPath $script:CredFile -Force -ErrorAction SilentlyContinue
    }
}

# Reloads the window log from today's file. Must run before this session writes
# anything, otherwise the session's own lines get read back and duplicated.
function Restore-LogWindow {
    param([int]$MaxLines = 200)
    if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
    try {
        $lines = @(Get-Content -LiteralPath $script:LogFile -Encoding UTF8 -ErrorAction Stop)
        if ($lines.Count -eq 0) { return }
        $tail = if ($lines.Count -gt $MaxLines) { $lines[(-$MaxLines)..-1] } else { $lines }
        $ui.txtLog.AppendText(($tail -join "`r`n") + "`r`n")
        $ui.txtLog.AppendText("----- above restored from $($script:LogFile) -----`r`n")
        $ui.txtLog.ScrollToEnd()
    } catch { }
}

function Add-CredentialSet {
    param([string]$Message = "Enter credentials (domain\username)")
    $cred = Get-Credential -Message $Message
    if ($cred) {
        $label = $cred.UserName
        $script:Credentials[$label] = $cred
        # First credential becomes the default
        if (-not $script:DefaultCredentialLabel) {
            $script:DefaultCredentialLabel = $label
            # Assign to any servers that have no credential yet
            foreach ($s in $script:ServerData) {
                if (-not $s.CredentialLabel) {
                    $s.CredentialLabel = $label
                }
            }
            $ui.dgServers.Items.Refresh()
        }
        Update-CredentialStatus
        Save-Credentials
        Write-Log "Added credential: $label"
        return $label
    }
    return $null
}

# Removes a credential set and re-points whatever referred to it. Kept out of
# the Manage button's handler so it can be exercised without opening a dialog.
function Remove-CredentialSet {
    param([string]$Label)

    if (-not $Label -or -not $script:Credentials.ContainsKey($Label)) { return $false }
    $script:Credentials.Remove($Label)

    # Pick the replacement default BEFORE re-pointing the servers. The other
    # order handed them $DefaultCredentialLabel while it still held the label
    # being deleted, so they kept a reference to a credential that no longer
    # existed and Get-ServerCredential quietly fell back to whichever one
    # happened to be first - possibly an account for another domain, which
    # costs a failed logon on every one of those servers.
    if ($script:DefaultCredentialLabel -eq $Label) {
        $script:DefaultCredentialLabel =
            if ($script:Credentials.Count -gt 0) { @($script:Credentials.Keys)[0] } else { $null }
    }
    $replacement = if ($script:DefaultCredentialLabel) { $script:DefaultCredentialLabel } else { "" }
    foreach ($s in $script:ServerData) {
        if ($s.CredentialLabel -eq $Label) {
            $s.CredentialLabel = $replacement
        }
    }

    $ui.dgServers.Items.Refresh()
    Update-CredentialStatus
    # Without this the removal lived only in memory: credentials.json still
    # held the account, so the next launch loaded it straight back and the
    # deletion looked like it had never happened. Save-Credentials writes the
    # whole set, so rewriting it here is all that is needed.
    Save-Credentials
    Save-ServerList
    Write-Log "Removed credential: $Label"
    return $true
}

# The credential picker shared by Change Password and Test. One entry needs no
# question at all; several use the numbered prompt the Assign Credential dialog
# already uses, so every credential action reads the same way.
function Select-CredentialLabel {
    param([string]$Title, [string]$Prompt)

    if ($script:Credentials.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No credentials added yet.", $Title, "OK", "Information") | Out-Null
        return $null
    }

    $credList = @($script:Credentials.Keys)
    if ($credList.Count -eq 1) { return $credList[0] }

    $options = for ($i = 0; $i -lt $credList.Count; $i++) { "$($i+1). $($credList[$i])" }
    $msg = "$Prompt`n`n$($options -join "`n")`n`nEnter the number:"
    try {
        $choice = [Microsoft.VisualBasic.Interaction]::InputBox($msg, $Title, "1")
    } catch {
        $choice = ""
    }
    if (-not $choice) { return $null }

    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $credList.Count) {
        return $credList[$idx - 1]
    }
    [System.Windows.MessageBox]::Show("That is not one of the listed numbers.", $Title, "OK", "Warning") | Out-Null
    return $null
}

# Replaces the password on an existing credential set. The label is deliberately
# left alone: it is the key every server entry stores, so changing it here would
# strand each of them on an account that no longer exists. Kept out of the
# button's handler so it can be exercised without opening a dialog.
function Set-CredentialPassword {
    param(
        [string]$Label,
        [System.Security.SecureString]$Password
    )

    if (-not $Label -or -not $script:Credentials.ContainsKey($Label)) { return $false }
    # An empty password would be stored and then fail every logon with nothing
    # in the log to explain it, so refuse it instead of writing it out.
    if (-not $Password -or $Password.Length -eq 0) { return $false }

    # PSCredential.Password is read-only, so the set is replaced rather than
    # edited in place. The label is reused as the username on purpose.
    $script:Credentials[$Label] =
        New-Object System.Management.Automation.PSCredential($Label, $Password)

    # Same reason as Remove-CredentialSet: without this the new password lives
    # only in memory and the next launch reads the old one back off disk.
    Save-Credentials
    Write-Log "Changed password for credential: $Label"
    return $true
}

function Update-CredentialStatus {
    $window.Dispatcher.Invoke([action]{
        $count = $script:Credentials.Count
        if ($count -eq 0) {
            $ui.txtCredentialStatus.Text = "No credentials"
            $ui.txtCredentialStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#f38ba8")
        } elseif ($count -eq 1) {
            $label = @($script:Credentials.Keys)[0]
            $ui.txtCredentialStatus.Text = "Credential: $label"
            $ui.txtCredentialStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#a6e3a1")
        } else {
            $ui.txtCredentialStatus.Text = "$count credential sets"
            $ui.txtCredentialStatus.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#a6e3a1")
        }
    })
}

function Get-ServerCredential {
    param([string]$ServerName)
    $entry = $script:ServerData | Where-Object { $_.ServerName -eq $ServerName } | Select-Object -First 1
    $label = $null
    if ($entry -and $entry.CredentialLabel) {
        $label = $entry.CredentialLabel
    }
    if (-not $label) { $label = $script:DefaultCredentialLabel }
    if ($label -and $script:Credentials.ContainsKey($label)) {
        return $script:Credentials[$label]
    }
    # Fallback: the entry may still point at a credential that has been removed.
    # Using a different one is a guess - and a wrong guess costs a failed logon
    # against the server - so it is recorded rather than done silently.
    if ($script:Credentials.Count -gt 0) {
        $fallback = @($script:Credentials.Keys)[0]
        if ($label) {
            Write-Log "$ServerName : credential '$label' no longer exists, falling back to '$fallback'" "WARN"
        }
        return $script:Credentials[$fallback]
    }
    return $null
}

function Ensure-Credential {
    if ($script:Credentials.Count -eq 0) {
        $result = Add-CredentialSet -Message "Enter credentials for server management (domain\username)"
        return ($null -ne $result)
    }
    return $true
}

# -- Stale-password guard -----------------------------------------------------
# A password rotated in the domain but not here is fired at every server in the
# batch at once, and each rejection is a bad logon against the same account. A
# fifty-server scan therefore walks straight into the domain lockout policy and
# locks the very account the maintenance window depends on. These counters stop
# the run before the policy does.
$script:AuthFailureLimit = 2       # rejections tolerated before the run is halted
$script:AuthFailures     = 0
$script:AuthHaltPending  = $false
$script:AuthHaltReason   = ""

# "The server said no to this account", as opposed to "the server could not be
# reached". Only the first kind is worth stopping a run over: an unreachable
# server costs nothing but itself, while a rejected logon spends part of a
# lockout budget shared with every other server in the batch.
function Test-AuthFailure {
    param([string]$ErrorText)
    if (-not $ErrorText) { return $false }
    return [bool]($ErrorText -match 'access is denied|access denied|logon failure|user name or password|username or password|password has expired|account has expired|locked out|no logon servers|0x8007052e|0x80070005|0x80070775|0x80070532|0x80070533')
}

# Being told the account is already locked is not a count-towards-the-limit
# event. The damage is done, and every further attempt only extends the lockout
# window, so this stops the run on its own.
function Test-AccountLockedOut {
    param([string]$ErrorText)
    if (-not $ErrorText) { return $false }
    return [bool]($ErrorText -match 'locked out|0x80070775')
}

# Reads the outcome of one finished job. Every operation returns the same
# Success/Error shape, so hooking this into the job timer covers scans,
# installs and reboots at once - and anything added later for free.
#
# Named rather than written into the tick itself for the usual reason: the
# tick's completion callbacks are closures, and a $script: counter updated
# inside one sets a copy that nobody ever reads.
function Register-JobAuthOutcome {
    param($Result)

    $r = $Result | Select-Object -First 1
    if (-not $r) { return }
    if (-not ($r.PSObject.Properties.Name -contains 'Success')) { return }

    # A success is proof the password is good. Whatever was counted before was
    # about those servers rather than the account, so the budget goes back full.
    if ($r.Success) {
        $script:AuthFailures = 0
        return
    }

    if (-not (Test-AuthFailure -ErrorText $r.Error)) { return }

    # A deliberate one-off probe from the Test button must not arm the guard:
    # the operator is watching that result, and a single logon is the whole
    # point of the check.
    if ($r.Probe) { return }

    if (Test-AccountLockedOut -ErrorText $r.Error) {
        $script:AuthHaltPending = $true
        $script:AuthHaltReason  = "the account is already locked out"
        return
    }

    $script:AuthFailures++
    if ($script:AuthFailures -ge $script:AuthFailureLimit) {
        $script:AuthHaltPending = $true
        $script:AuthHaltReason  = "$($script:AuthFailures) logons in a row were rejected"
    }
}

# Split out so the tests can exercise the guard without a window, and so the one
# event that can cost a maintenance window cannot be missed in the log.
function Show-AuthHaltNotice {
    param([string]$Text, [string]$Title = "Logons are being rejected")
    [System.Windows.MessageBox]::Show($Text, $Title, "OK", "Warning") | Out-Null
}

# Runs once per tick, after every finished job has been handled, so the run is
# torn down between ticks rather than underneath a callback that is still
# running and about to start the next server.
function Step-AuthLockdown {
    if (-not $script:AuthHaltPending) { return $false }

    $reason = $script:AuthHaltReason
    # Re-arm straight away: the operator fixes the password and starts again,
    # and a guard that stayed tripped would be no guard at all.
    $script:AuthHaltPending = $false
    $script:AuthHaltReason  = ""
    $script:AuthFailures    = 0

    Stop-AllOperations -Reason "Halted because $reason"
    $text = "The run was stopped because $reason. " +
            "Every rejected logon spends part of the domain lockout budget for this account, " +
            "and the rest of the batch would have spent the remainder. " +
            "If the domain password was rotated, set the new one with Change Password, " +
            "then confirm it with Test before starting again."
    Write-Log $text "ERROR"
    Show-AuthHaltNotice -Text $text
    return $true
}

# -- Credential test ----------------------------------------------------------
# Deliberately goes over WinRM with the same credential the real work uses: a
# check that took a different route - an LDAP bind, say - could pass happily
# while every scan still failed.
$script:CredentialTestScript = {
    param([string]$ServerName, [PSCredential]$Credential)
    try {
        $name = Invoke-Command -ComputerName $ServerName -Credential $Credential -ErrorAction Stop `
            -ScriptBlock { $env:COMPUTERNAME }
        [PSCustomObject]@{ Success = $true;  Error = ""; RemoteName = "$name"; Probe = $true }
    } catch {
        [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message; RemoteName = ""; Probe = $true }
    }
}

function Invoke-CredentialTest {
    param([string]$Label, [string]$ServerName)

    if (-not $Label -or -not $script:Credentials.ContainsKey($Label)) { return $false }
    if (-not $ServerName) { return $false }

    $cred = $script:Credentials[$Label]
    Write-Log "Testing credential '$Label' against $ServerName"
    Update-StatusBar "Testing credential against $ServerName..."

    Start-AsyncJob -ScriptBlock $script:CredentialTestScript -Arguments @($ServerName, $cred) -OnComplete {
        param($result)
        Complete-CredentialTest -Label $Label -ServerName $ServerName -Result $result
    }.GetNewClosure()
    return $true
}

# The verdict, and what to do about it. Telling the two apart is the whole value
# of the button: a rejected password and an unreachable server read almost the
# same in the log but need opposite responses.
function Complete-CredentialTest {
    param([string]$Label, [string]$ServerName, $Result)

    $r = $Result | Select-Object -First 1
    if ($r -and $r.Success) {
        Write-Log "Credential '$Label' authenticated against $ServerName (answered as $($r.RemoteName))"
        Update-StatusBar "Credential OK"
        Show-AuthHaltNotice -Title "Credential OK" `
            -Text "'$Label' authenticated against $ServerName. The server answered as $($r.RemoteName)."
        return $true
    }

    $err = if ($r -and $r.Error) { $r.Error } else { "no result came back from the test" }
    $hint = if (Test-AuthFailure -ErrorText $err) {
        "The server rejected the account. If the domain password was rotated, set the new one with Change Password."
    } else {
        "This does not look like a password problem: the server could not be reached, or WinRM refused the connection."
    }

    Write-Log "Credential '$Label' failed against $ServerName - $err" "ERROR"
    Update-StatusBar "Credential test failed"
    Show-AuthHaltNotice -Title "Credential test failed" `
        -Text "'$Label' did not authenticate against $ServerName. $err $hint"
    return $false
}

# -- Initialize Runspace Pool -------------------------------------------------
# How many servers may be worked on at the same time. Was hardcoded to 10,
# which is too many for a thin link and too few for a large estate.
$script:RunspacePoolSize = 10

function Initialize-RunspacePool {
    param([int]$MaxThreads = 10)
    if ($script:RunspacePool) { $script:RunspacePool.Dispose() }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $iss, [System.Management.Automation.Host.PSHost]$Host)
    $script:RunspacePool.ApartmentState = "STA"
    $script:RunspacePool.Open()
    $script:RunspacePoolSize = $MaxThreads
}
Initialize-RunspacePool -MaxThreads $script:RunspacePoolSize

# Applies the "Max parallel" box. A pool cannot be resized while it still holds
# work, so this runs at the start of each batch rather than on selection change.
function Sync-RunspacePool {
    if (-not $ui.cboParallel.SelectedItem) { return }
    $desired = [int]$ui.cboParallel.SelectedItem.Content
    if ($desired -lt 1) { $desired = 1 }
    if ($desired -eq $script:RunspacePoolSize) { return }
    if ($script:ActiveJobs.Count -gt 0) {
        Write-Log "Max parallel stays at $($script:RunspacePoolSize) until the current operations finish" "WARN"
        return
    }
    Initialize-RunspacePool -MaxThreads $desired
    Write-Log "Max parallel set to $desired"
}

# -- Remote Operations ---------------------------------------------------------
# Uses scheduled-task approach: creates a temporary task that runs as SYSTEM on
# the remote server.  SYSTEM always has full access to the Windows Update Agent
# COM objects, which avoids the "Access denied" DCOM error that occurs when
# Invoke-Command runs under a delegated (network) token.

# Helper: the PowerShell code that will execute ON the remote server as SYSTEM
# for scanning.  It writes JSON results to a well-known temp file.
$script:ScanPayload = @'
# $LogPath and $ResultPath are supplied by the runner as a prelude, so every
# run writes to its own files and two operations against the same server
# cannot overwrite or delete each other's results.
function Log { param([string]$Msg) Add-Content -Path $LogPath -Value "$(Get-Date -Format 'HH:mm:ss') $Msg" -Force }

try {
    Log "Starting Windows Update scan"
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $searcher      = $updateSession.CreateUpdateSearcher()
    $searchResult  = $searcher.Search("IsInstalled=0 AND IsHidden=0")
    Log "Found $($searchResult.Updates.Count) update(s)"

    $updates = @()
    foreach ($u in $searchResult.Updates) {
        $severity = "Unspecified"
        if ($u.MsrcSeverity) { $severity = $u.MsrcSeverity }
        $updates += @{
            Title    = $u.Title
            KB       = ($u.KBArticleIDs | Select-Object -First 1)
            Severity = $severity
            Size     = [math]::Round($u.MaxDownloadSize / 1MB, 1)
        }
    }

    $sysInfo        = New-Object -ComObject Microsoft.Update.SystemInfo
    $rebootRequired = $sysInfo.RebootRequired

    $result = @{
        Success        = $true
        Updates        = $updates
        Count          = $searchResult.Updates.Count
        RebootRequired = $rebootRequired
        Error          = $null
    }
    Log "Scan complete. Reboot required: $rebootRequired"
} catch {
    Log "EXCEPTION: $($_.Exception.Message)"
    $result = @{
        Success        = $false
        Updates        = @()
        Count          = 0
        RebootRequired = $false
        Error          = $_.Exception.Message
    }
}
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $ResultPath -Encoding UTF8 -Force
Log "Done"
'@

# Helper: PowerShell code for installing updates (runs as SYSTEM)
$script:InstallPayload = @'
# $LogPath and $ResultPath are supplied by the runner as a prelude - see the
# note on $script:ScanPayload above.
function Log { param([string]$Msg) Add-Content -Path $LogPath -Value "$(Get-Date -Format 'HH:mm:ss') $Msg" -Force }

try {
    Log "Starting Windows Update install process"
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $searcher      = $updateSession.CreateUpdateSearcher()
    Log "Searching for available updates..."
    $searchResult  = $searcher.Search("IsInstalled=0 AND IsHidden=0")
    Log "Found $($searchResult.Updates.Count) update(s)"

    # Updates the operator has chosen to hold back. $ExcludedKB arrives as a
    # plain assignment prepended by the caller; an empty list holds nothing back.
    if (-not $ExcludedKB) { $ExcludedKB = @() }
    $pending = @()
    $held    = @()
    foreach ($u in $searchResult.Updates) {
        $hit = @(@($u.KBArticleIDs) | Where-Object { $ExcludedKB -contains "$_" })
        if ($hit.Count -gt 0) {
            $held += "KB$($hit[0])"
            Log "Held back KB$($hit[0]) - on the exclusion list: $($u.Title)"
        } else {
            $pending += $u
        }
    }
    if ($held.Count -gt 0) {
        Log "Holding back $($held.Count) update(s): $($held -join ', ')"
    }

    if ($pending.Count -eq 0) {
        # "Nothing was pending" and "everything pending was held back" are
        # different answers, and only the first means the server is up to date.
        $noneMsg = if ($held.Count -gt 0) {
            "All $($held.Count) available update(s) are on the held-back list"
        } else {
            "No updates to install"
        }
        $result = @{
            Success        = $true
            InstalledCount = 0
            FailedCount    = 0
            RebootRequired = $false
            Error          = $null
            HeldBack       = $held
            Message        = $noneMsg
        }
    } else {
        # Accept EULAs - required before download/install
        foreach ($u in $pending) {
            if (-not $u.EulaAccepted) {
                $u.AcceptEula()
                Log "Accepted EULA: $($u.Title)"
            }
        }

        # Download
        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $pending) {
            if (-not $u.IsDownloaded) { $toDownload.Add($u) | Out-Null }
        }
        if ($toDownload.Count -gt 0) {
            Log "Downloading $($toDownload.Count) update(s)..."
            $dl = $updateSession.CreateUpdateDownloader()
            $dl.Updates = $toDownload
            $dlResult = $dl.Download()
            Log "Download finished. ResultCode=$($dlResult.ResultCode)"
        } else {
            Log "All updates already downloaded"
        }

        # Install
        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $pending) {
            if ($u.IsDownloaded) { $toInstall.Add($u) | Out-Null }
        }

        if ($toInstall.Count -eq 0) {
            Log "No updates ready to install after download phase"
            $result = @{
                Success        = $false
                InstalledCount = 0
                FailedCount    = 0
                RebootRequired = $false
                Error          = "Download completed but no updates were ready to install"
                Message        = "Download may have failed"
            }
        } else {
            Log "Installing $($toInstall.Count) update(s)..."
            $installer         = $updateSession.CreateUpdateInstaller()
            $installer.Updates = $toInstall
            $installResult     = $installer.Install()
            Log "Install finished. ResultCode=$($installResult.ResultCode) RebootRequired=$($installResult.RebootRequired)"

            # Per-update outcomes are kept, not just counted: the caller shows
            # which KBs failed, and "how many succeeded" alone cannot tell an
            # operator whether a server still needs attention.
            # ResultCode only ever says "Failed". The HRESULT next to it is what
            # says why, and the update agent already has it - without it the
            # operator is sent to the CBS log for something that was known here.
            $hints = @{
                '0x80070070' = 'not enough disk space'
                '0x80070005' = 'access denied'
                '0x80240016' = 'another install is in progress, or a reboot is pending'
                '0x800F081F' = 'component store source files are missing'
                '0x800F0922' = 'installer failed - often space on the system partition'
                '0x8024200B' = 'the update handler failed to install the update'
            }

            $ok = 0; $fail = 0
            $okList = @(); $failList = @()
            for ($i = 0; $i -lt $toInstall.Count; $i++) {
                $ur    = $installResult.GetUpdateResult($i)
                $rc    = $ur.ResultCode
                $title = $toInstall.Item($i).Title
                if ($rc -eq 2) {
                    $ok++
                    $okList += $title
                    Log "  OK: $title"
                } else {
                    $fail++
                    # An aborted update can carry no HRESULT at all; saying
                    # 0x00000000 there would be worse than saying nothing.
                    $hex = if ($ur.HResult -ne 0) { '0x{0:X8}' -f $ur.HResult } else { $null }
                    if ($hex) {
                        $why = if ($hints.ContainsKey($hex)) { " - $($hints[$hex])" } else { "" }
                        $failList += "$title ($hex$why)"
                        Log "  FAILED: $title  hresult=$hex resultcode=$rc$why"
                    } else {
                        $failList += "$title (result code $rc)"
                        Log "  FAILED (code $rc, no hresult): $title"
                    }
                }
            }

            $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
            if ($fail -gt 0) {
                $msg = "Installed $ok of $($toInstall.Count) update(s), $fail failed"
                $err = "$fail update(s) failed to install"
            } else {
                $msg = "Installed $ok update(s)"
                $err = $null
            }
            # Success means "the installer ran and reported per-update results",
            # not "everything installed" - $FailedCount carries that.
            $result = @{
                Success         = $true
                InstalledCount  = $ok
                FailedCount     = $fail
                InstalledTitles = $okList
                FailedTitles    = $failList
                RebootRequired  = $sysInfo.RebootRequired
                Error           = $err
                HeldBack        = $held
                Message         = $msg
            }
        }
    }
} catch {
    Log "EXCEPTION: $($_.Exception.Message)"
    $result = @{
        Success        = $false
        InstalledCount = 0
        FailedCount    = 0
        RebootRequired = $false
        Error          = $_.Exception.Message
        Message        = "Install failed"
    }
}
Log "Writing result JSON"
$result | ConvertTo-Json -Depth 5 | Set-Content -Path $ResultPath -Encoding UTF8 -Force
Log "Done"
'@

# -- Scheduled-task wrapper that runs a payload as SYSTEM and reads results ---
# Creating a scheduled task is what gives the payload a SYSTEM token, and SYSTEM
# always has access to the Windows Update Agent COM objects - a delegated
# network token does not, which is the "Access denied" DCOM error this avoids.
#
# The payload, its log and its result file live in a directory writable only by
# SYSTEM and Administrators. %SystemRoot%\Temp, used previously, is writable by
# ordinary users: they could swap the script between the moment it is written
# and the moment SYSTEM executes it, i.e. escalate to SYSTEM.
#
# Every run also gets its own file names, so a manual scan racing the automatic
# post-reboot rescan can no longer read or delete the other's result file.
$script:RunAsSystemScript = {
    param(
        [string]$ServerName,
        [PSCredential]$Credential,
        [string]$Payload,
        [int]$TimeoutSeconds,
        [string]$Operation
    )
    try {
        $session = New-PSSession -ComputerName $ServerName -Credential $Credential -ErrorAction Stop
        try {
            $json = Invoke-Command -Session $session -ErrorAction Stop `
                -ArgumentList $Payload, $TimeoutSeconds, $Operation -ScriptBlock {
                param([string]$Code, [int]$Timeout, [string]$Op)

                # -- Work directory writable only by SYSTEM and Administrators --
                $workDir = Join-Path $env:ProgramData 'ServerPatchTool'
                if (-not (Test-Path -LiteralPath $workDir)) {
                    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
                }
                # Re-assert the ACL on every run: the directory may have been
                # pre-created by someone else with looser permissions. Well-known
                # SIDs are used so this also holds on localised Windows.
                $sidSystem = [System.Security.Principal.SecurityIdentifier]'S-1-5-18'
                $sidAdmins = [System.Security.Principal.SecurityIdentifier]'S-1-5-32-544'
                $acl = Get-Acl -Path $workDir
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
                foreach ($sid in @($sidSystem, $sidAdmins)) {
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
                try { $acl.SetOwner($sidAdmins) } catch { }
                Set-Acl -Path $workDir -AclObject $acl

                # A run that times out deliberately leaves its script, log and
                # result file behind for diagnosis, so something has to collect
                # them eventually. A week is long enough to investigate and
                # short enough that the directory cannot grow without bound.
                Get-ChildItem -LiteralPath $workDir -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue

                # -- Per-run file names ---------------------------------------
                $runId      = [guid]::NewGuid().ToString('N')
                $taskName   = "SPT_${Op}_$runId"
                $scriptPath = Join-Path $workDir "$runId.ps1"
                $resultPath = Join-Path $workDir "$runId.result.json"
                $logPath    = Join-Path $workDir "$runId.log"

                # The payload reads $ResultPath and $LogPath. Supplying them as
                # real variables is safer than rewriting the code with -replace.
                $prelude = "`$ResultPath = '$resultPath'" + [Environment]::NewLine +
                           "`$LogPath = '$logPath'" + [Environment]::NewLine
                Set-Content -Path $scriptPath -Value ($prelude + $Code) -Encoding UTF8 -Force

                $timedOut = $false
                try {
                    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
                                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
                                -LogonType ServiceAccount -RunLevel Highest
                    Register-ScheduledTask -TaskName $taskName -Action $action `
                                -Principal $principal -Force | Out-Null
                    Start-ScheduledTask -TaskName $taskName

                    # Poll for the result file, not for task state alone: right
                    # after Start-ScheduledTask the task can still report 'Ready',
                    # and treating that as "finished" abandoned tasks that had
                    # simply not started yet.
                    $elapsed = 0
                    $idle    = 0
                    do {
                        Start-Sleep -Seconds 2
                        $elapsed += 2
                        if (Test-Path -LiteralPath $resultPath) { break }
                        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                        if ($task -and $task.State -eq 'Running') { $idle = 0 } else { $idle += 2 }
                    } while ($elapsed -lt $Timeout -and $idle -lt 30)

                    $diag = ""
                    if (Test-Path -LiteralPath $logPath) {
                        $diag = Get-Content -Path $logPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                    }

                    if (Test-Path -LiteralPath $resultPath) {
                        return (Get-Content -Path $resultPath -Raw -Encoding UTF8)
                    }
                    if ($elapsed -ge $Timeout) {
                        # Running out of time is not a failure of the payload -
                        # it is this tool giving up on watching. The task is
                        # left registered and its log left on disk: deleting the
                        # task definition would not stop an install that is
                        # under way, it would only throw away the only record of
                        # what happened. A later scan reports the real outcome.
                        $timedOut = $true
                        $where = "Task '$taskName' was left running on $env:COMPUTERNAME; log: $logPath"
                        return (@{
                            Success  = $false
                            TimedOut = $true
                            TaskName = $taskName
                            LogPath  = $logPath
                            Error    = "$Op still going after $([int]($Timeout / 60)) minutes. $where. Log so far: $diag"
                            Message  = "Still running"
                        } | ConvertTo-Json -Depth 3)
                    }
                    $err = "Result file not created. "
                    if ($diag) { $err += "Log: $diag" }
                    else       { $err += "No diagnostic log found - the task may have failed to start." }
                    return (@{ Success = $false; Error = $err; Message = "Task failed" } | ConvertTo-Json -Depth 3)
                } finally {
                    # Kept on purpose after a timeout - see the branch above.
                    if (-not $timedOut) {
                        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                        Remove-Item -Path $scriptPath, $resultPath, $logPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        } finally {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }
        return ($json | ConvertFrom-Json)
    } catch {
        return [PSCustomObject]@{
            Success        = $false
            Updates        = @()
            Count          = 0
            InstalledCount = 0
            FailedCount    = 0
            RebootRequired = $false
            Error          = $_.Exception.Message
            Message        = "Connection failed"
        }
    }
}

# Timeouts for the SYSTEM payloads, in seconds.
$script:ScanTimeout = 600    # 10 min

# The install limit used to be 30 minutes and hardcoded, which is less than a
# Windows Server cumulative update routinely takes: the tool declared an error
# while the install was still perfectly healthy. It is now chosen in the
# toolbar, defaults to 90 minutes, and running out of it no longer destroys the
# evidence - see the timeout branch of $RunAsSystemScript.
$script:InstallTimeoutDefault = 5400   # 90 min

# -- Held-back updates --------------------------------------------------------
# One bad cumulative can fail on every server in the estate, and until the
# vendor fixes it the only way through the window was to let it fail again each
# time. Listing its KB here takes it out of every install until it is removed.
$script:ExcludedKBFile = Join-Path $script:CredDir "excluded-kb.json"
$script:ExcludedKB     = @()

# Accepts whatever the operator types - "KB5120238, 5034441 kb5000802" - and
# reduces it to bare numbers, because bare numbers are what the update agent
# reports back in KBArticleIDs.
function ConvertTo-KBNumbers {
    param([string]$Text)
    if (-not $Text) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($token in ($Text -split '[^0-9A-Za-z]+')) {
        if (-not $token) { continue }
        $number = $token -replace '^[Kk][Bb]', ''
        # Anything that is not a KB number is dropped rather than passed on: it
        # would travel to every server and match nothing, which looks identical
        # to a working exclusion right up to the moment the update installs.
        if ($number -match '^\d+$' -and -not $out.Contains($number)) {
            $out.Add($number) | Out-Null
        }
    }
    # The leading comma matters. Returning a one-element array unrolls it into a
    # bare string, and a caller indexing [0] then gets the character "5" rather
    # than the KB number - which reads as a working exclusion right up to the
    # point where the update installs anyway.
    return ,@($out)
}

function Save-ExcludedKB {
    try {
        if ($script:ExcludedKB.Count -eq 0) {
            if (Test-Path -LiteralPath $script:ExcludedKBFile) {
                Remove-Item -LiteralPath $script:ExcludedKBFile -Force -ErrorAction SilentlyContinue
            }
            return
        }
        if (-not (Test-Path -LiteralPath $script:CredDir)) {
            New-Item -ItemType Directory -Path $script:CredDir -Force | Out-Null
        }
        # Always an array: a single held-back KB round-trips through ConvertTo-Json
        # as a bare string, and the next load would then hold back each of its
        # digits instead.
        ConvertTo-Json @($script:ExcludedKB) -Depth 2 |
            Set-Content -Path $script:ExcludedKBFile -Encoding UTF8 -Force
    } catch {
        Write-Log "Could not save the held-back KB list: $($_.Exception.Message)" "WARN"
    }
}

function Load-ExcludedKB {
    if (-not (Test-Path -LiteralPath $script:ExcludedKBFile)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:ExcludedKBFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:ExcludedKB = ConvertTo-KBNumbers -Text (@($raw) -join ' ')
    } catch {
        Write-Log "The held-back KB list could not be read - starting with none" "WARN"
        $script:ExcludedKB = @()
    }
    if ($script:ExcludedKB.Count -gt 0) {
        Write-Log "Holding back $($script:ExcludedKB.Count) update(s): $(($script:ExcludedKB | ForEach-Object { "KB$_" }) -join ', ')"
    }
    return ,@($script:ExcludedKB)
}

# Kept out of the button so the parse, the save and the log line can be
# exercised without a dialog.
function Set-ExcludedKB {
    param([string]$Text)
    $script:ExcludedKB = ConvertTo-KBNumbers -Text $Text
    Save-ExcludedKB
    if ($script:ExcludedKB.Count -eq 0) {
        Write-Log "No updates are held back any more"
    } else {
        Write-Log "Holding back $(($script:ExcludedKB | ForEach-Object { "KB$_" }) -join ', ')"
    }
    return ,@($script:ExcludedKB)
}

# The exclusion list travels as a prelude line rather than as a parameter: the
# runner hands the payload over as text, so prepending an assignment keeps
# $script:InstallPayload itself a plain script that the validator can parse.
# The numbers are digits only by the time they get here, so there is nothing to
# quote around.
function Get-InstallPayload {
    $quoted = @($script:ExcludedKB | ForEach-Object { "'$_'" }) -join ','
    return "`$ExcludedKB = @($quoted)`r`n" + $script:InstallPayload
}

function Get-InstallTimeout {
    $item = $ui.cboInstallTimeout.SelectedItem
    if (-not $item) { return $script:InstallTimeoutDefault }
    $minutes = [int]($item.Content -replace '\D')
    if ($minutes -lt 1) { return $script:InstallTimeoutDefault }
    return ($minutes * 60)
}

# How long to keep watching for a server to come back. This used to be 30
# minutes hard-coded inside the monitor, which is short for a server that
# applies a cumulative update while booting - and unlike the install limit
# there was no way to raise it.
$script:RebootTimeoutDefault = 1800   # 30 min

function Get-RebootTimeout {
    $item = $ui.cboRebootTimeout.SelectedItem
    if (-not $item) { return $script:RebootTimeoutDefault }
    $minutes = [int]($item.Content -replace '\D')
    if ($minutes -lt 1) { return $script:RebootTimeoutDefault }
    return ($minutes * 60)
}

# Reboot: triggers the restart and records the boot time beforehand, so the
# monitor can later prove the machine really came back rather than guessing.
$script:RebootScript = {
    param([string]$ServerName, [PSCredential]$Credential)
    $bootBefore = $null
    try {
        $session = New-PSSession -ComputerName $ServerName -Credential $Credential -ErrorAction Stop
        try {
            $bootBefore = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
                (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            }
        } finally {
            Remove-PSSession $session -ErrorAction SilentlyContinue
        }

        # -Protocol WSMan keeps the reboot on the same channel as everything
        # else. The -ComputerName default is DCOM/RPC, which is routinely
        # blocked on servers where WinRM (5985) is open, so reboots failed on
        # hosts that scanned and patched fine.
        Restart-Computer -ComputerName $ServerName -Credential $Credential `
                         -Protocol WSMan -Force -ErrorAction Stop
        return [PSCustomObject]@{ Success = $true; Error = $null; BootBefore = $bootBefore }
    } catch {
        return [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message; BootBefore = $bootBefore }
    }
}

# Post-reboot monitor. Confirms the reboot by watching for a NEW boot time.
#
# The previous version waited for the server to stop pinging, with a 120 s cap,
# and then fell through without an error if it was still up - which happens
# routinely when a server spends several minutes on "Working on updates" before
# it actually goes down. It then connected to the still-running pre-reboot OS
# and reported "Back Online", clearing RebootRequired and, in sequential mode,
# releasing the queue early.
#
# Comparing boot times removes that race and also makes the monitor tolerant of
# starting late (e.g. queued behind other jobs in the runspace pool): it does
# not need to observe the downtime window itself.
$script:RebootMonitorScript = {
    param([string]$ServerName, [PSCredential]$Credential, $BootBefore, [int]$TimeoutSeconds = 1800)

    # Probe over WinRM rather than ICMP: ping is commonly blocked by policy on
    # servers, and that made the old monitor report healthy hosts as offline.
    # Returns the remote boot time, or $null when unreachable.
    $probe = {
        param([string]$Name, [PSCredential]$Cred)
        try {
            $s = New-PSSession -ComputerName $Name -Credential $Cred -ErrorAction Stop
            try {
                return Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {
                    (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                }
            } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
        } catch { return $null }
    }

    # A description that is never empty. Exception.Message on its own can be,
    # and that produced a log line reading only "Monitor error -", which said
    # that something had failed but nothing about what.
    $describe = {
        param($Record)
        $ex   = $Record.Exception
        $text = if ($ex -and $ex.Message) { $ex.Message } else { [string]$Record }
        if (-not $text) { $text = "no details available" }
        if ($ex) { "$($ex.GetType().Name): $text" } else { $text }
    }

    $attempts  = 0
    $sawDown   = $false
    $lastIssue = $null

    try {
        # Cumulative updates applied during shutdown/startup can take a while,
        # so how long to keep watching is the operator's call, not a constant.
        $minutes  = [int]($TimeoutSeconds / 60)
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $attempts++

            # One bad probe must not end the watch. The machine is rebooting,
            # so transient oddities are expected - a half-open WinRM listener,
            # a boot time that cannot be read yet - and letting one of them
            # escape stopped the tool from looking while the server was still
            # on its way back.
            try {
                $boot = & $probe $ServerName $Credential

                if ($null -eq $boot) {
                    # Unreachable: shutting down, or still booting.
                    $sawDown = $true
                    continue
                }
                if ($BootBefore) {
                    if ([datetime]$boot -ne [datetime]$BootBefore) {
                        return [PSCustomObject]@{
                            Phase = "Online"; Error = $null; Attempts = $attempts
                        }
                    }
                    # Reachable with the same boot time: shutdown has not begun.
                } elseif ($sawDown) {
                    # No baseline was captured - fall back to down-then-up.
                    return [PSCustomObject]@{
                        Phase = "Online"; Error = $null; Attempts = $attempts
                    }
                }
            } catch {
                $lastIssue = & $describe $_
                $sawDown   = $true
            }
        }

        # Timed out. The ping here is diagnostic only, never a gate: it just
        # distinguishes "box is up, WinRM is not" from "box is gone".
        $trail = if ($lastIssue) { " Last problem seen: $lastIssue" } else { "" }
        $pingable = Test-Connection -ComputerName $ServerName -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($pingable) {
            return [PSCustomObject]@{
                Phase    = "WinRMTimeout"
                Error    = "Server answers ping but no completed reboot was confirmed within $minutes minutes.$trail"
                Attempts = $attempts
            }
        }
        return [PSCustomObject]@{
            Phase    = "Timeout"
            Error    = "Server did not come back within $minutes minutes.$trail"
            Attempts = $attempts
        }
    } catch {
        return [PSCustomObject]@{
            Phase    = "Error"
            Error    = (& $describe $_)
            Attempts = $attempts
        }
    }
}

# -- Async Job Runner ----------------------------------------------------------
function Start-AsyncJob {
    param(
        [ScriptBlock]$ScriptBlock,
        [object[]]$Arguments,
        [ScriptBlock]$OnComplete
    )

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    $ps.AddScript($ScriptBlock) | Out-Null
    foreach ($arg in $Arguments) {
        $ps.AddArgument($arg) | Out-Null
    }

    $handle = $ps.BeginInvoke()

    $script:ActiveJobs.Add([PSCustomObject]@{
        PowerShell = $ps
        Handle     = $handle
        OnComplete = $OnComplete
    })
}

# Timer to check for completed async jobs
# -- Deferred re-checks --------------------------------------------------------
# A server left as "Still installing" never corrects itself: the install carries
# on under its own scheduled task and nothing reports back, so the row kept that
# status until somebody scanned by hand. These re-checks are how it eventually
# tells the truth on its own.
$script:PendingRechecks = [System.Collections.Generic.List[PSObject]]::new()
$script:RecheckInterval = 10   # minutes between attempts
$script:RecheckAttempts = 6    # so roughly an hour of trying in total

function Add-PendingRecheck {
    param([string]$ServerName)

    Remove-PendingRecheck -ServerName $ServerName
    $script:PendingRechecks.Add([PSCustomObject]@{
        ServerName = $ServerName
        DueAt      = (Get-Date).AddMinutes($script:RecheckInterval)
        Remaining  = $script:RecheckAttempts
    })
    Write-Log "$ServerName : will re-check in $($script:RecheckInterval) min to find out how the install ended"
}

function Remove-PendingRecheck {
    param([string]$ServerName)
    foreach ($p in @($script:PendingRechecks)) {
        if ($p.ServerName -eq $ServerName) { $script:PendingRechecks.Remove($p) | Out-Null }
    }
}

# Fires the re-checks that have come due. Walks a snapshot: the scan it starts
# can finish and change this list while the loop is still running.
function Step-PendingRechecks {
    $now = Get-Date

    foreach ($p in @($script:PendingRechecks)) {
        if ($p.DueAt -gt $now) { continue }

        $entry = $script:ServerData | Where-Object { $_.ServerName -eq $p.ServerName } | Select-Object -First 1
        if (-not $entry) {
            $script:PendingRechecks.Remove($p) | Out-Null
            continue
        }

        # A status that only a completed scan can produce means the question
        # has been answered - by this re-check or by the operator.
        if ($entry.Status -like "Available*" -or
            $entry.Status -in @("Up to date", "Reboot Required", "Completed with errors")) {
            $script:PendingRechecks.Remove($p) | Out-Null
            Write-Log "$($p.ServerName) : install confirmed as finished - $($entry.Status)"
            continue
        }

        # Busy with something right now, including the previous re-check. Come
        # back shortly rather than spending an attempt on a server that cannot
        # answer yet.
        if ($entry.Status -in @("Scanning...", "Installing...", "Rebooting...")) {
            $p.DueAt = $now.AddMinutes(1)
            continue
        }

        $p.Remaining--
        if ($p.Remaining -lt 0) {
            $script:PendingRechecks.Remove($p) | Out-Null
            $waited = $script:RecheckAttempts * $script:RecheckInterval
            Update-ServerEntry -ServerName $p.ServerName -Properties @{
                Details = "Still unconfirmed after $waited minutes of re-checks. Scan manually once the server is free."
            }
            Write-Log "$($p.ServerName) : gave up re-checking after $waited min - scan manually" "WARN"
            continue
        }

        $p.DueAt = $now.AddMinutes($script:RecheckInterval)
        Write-Log "$($p.ServerName) : re-checking whether the install has finished"
        Invoke-ScanServer -ServerName $p.ServerName -NoProgress
    }
}

$script:JobTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:JobTimer.Add_Tick({
    # Walk a snapshot, and drop each finished job before its callback runs.
    # Callbacks start new jobs - the next server of a sequential install, the
    # post-reboot monitor, the confirming rescan - which adds to $ActiveJobs.
    # Enumerating the live list threw "Collection was modified" out of the tick
    # as soon as that happened, leaving the finished job in the list to be
    # EndInvoke'd again on the next tick and logged as a phantom "Job error".
    foreach ($job in @($script:ActiveJobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        $script:ActiveJobs.Remove($job) | Out-Null
        try {
            $result = $job.PowerShell.EndInvoke($job.Handle)
            # Before the callback, not after: the callback may start the next
            # server, and a rejected logon should be counted before another one
            # is spent.
            Register-JobAuthOutcome -Result $result
            if ($job.OnComplete) {
                & $job.OnComplete $result
            }
        } catch {
            Write-Log "Job error: $($_.Exception.Message)" "ERROR"
        } finally {
            $job.PowerShell.Dispose()
        }
    }

    # After every finished job has been handled, so the teardown never runs
    # underneath a callback that is still going.
    Step-AuthLockdown | Out-Null

    Step-PendingRechecks

    # Update progress
    if ($script:ActiveJobs.Count -eq 0) {
        Show-Progress -Visible $false
    }

    # Stop is only meaningful while there is something to stop.
    $ui.btnStop.IsEnabled = ($script:ActiveJobs.Count -gt 0 -or
                             $script:SequentialQueue.Count -gt 0 -or
                             $script:RebootQueue.Count -gt 0)
})
$script:JobTimer.Start()

# -- Update server entry in the grid (thread-safe) ----------------------------
function Update-ServerEntry {
    param(
        [string]$ServerName,
        [hashtable]$Properties
    )
    $window.Dispatcher.Invoke([action]{
        $entry = $script:ServerData | Where-Object { $_.ServerName -eq $ServerName } | Select-Object -First 1
        if ($entry) {
            foreach ($key in $Properties.Keys) {
                $entry.$key = $Properties[$key]
            }
            # Force UI refresh
            $index = $script:ServerData.IndexOf($entry)
            if ($index -ge 0) {
                $script:ServerData.RemoveAt($index)
                $script:ServerData.Insert($index, $entry)
            }
        }
    })
}

# -- Server Operations ---------------------------------------------------------
# Shared tail for install jobs: Invoke-InstallServer and its sequential twin
# differed only in what they did afterwards.
function Complete-InstallResult {
    param([string]$ServerName, $Result)

    if ($Result.Success) {
        $failed = [int]$Result.FailedCount
        $reboot = if ($Result.RebootRequired) { "Yes" } else { "No" }

        # A partly failed install used to be reported as "Up to date" with
        # Available = 0 and the failure count buried in the Details text: the
        # operator saw a clean green row on a server where half the KBs had not
        # installed. Updates that failed are still outstanding, so they are
        # counted as available and the row gets a status of its own.
        if ($failed -gt 0) {
            $status  = "Completed with errors"
            $details = $Result.Message
            if ($Result.FailedTitles) { $details += ". Failed: $(@($Result.FailedTitles) -join '; ')" }
        } elseif ($Result.RebootRequired) {
            $status  = "Reboot Required"
            $details = $Result.Message
        } else {
            $status  = "Up to date"
            $details = $Result.Message
        }

        Update-ServerEntry -ServerName $ServerName -Properties @{
            Status         = $status
            Installed      = $Result.InstalledCount.ToString()
            Available      = $failed.ToString()
            RebootRequired = $reboot
            Details        = $details
        }
        $level = if ($failed -gt 0) { "WARN" } else { "INFO" }
        Write-Log "$ServerName : $($Result.Message)$(if($Result.RebootRequired){' - reboot required'})" $level
        if ($failed -gt 0) {
            foreach ($t in @($Result.FailedTitles)) { Write-Log "$ServerName :   failed - $t" "WARN" }
        }

        # Everything above is the installer's own account of what it did. It is
        # confirmed against the server, because that is the only thing that can
        # distinguish "installed" from "reported as installed". A server waiting
        # on a reboot is skipped here - the post-reboot monitor rescans anyway,
        # and a scan before the reboot would only repeat what is already known.
        if (-not $Result.RebootRequired) {
            Write-Log "$ServerName : verifying with a rescan"
            Invoke-ScanServer -ServerName $ServerName -NoProgress
        }
    } elseif ($Result.TimedOut) {
        # The install did not fail - the tool stopped watching it. Saying
        # "Error" here would be a lie and would hide a run that is still going.
        Update-ServerEntry -ServerName $ServerName -Properties @{
            Status  = "Still installing"
            Details = "Stopped watching after the time limit. The install is still running on the server; re-checking every $($script:RecheckInterval) min. $($Result.Error)"
        }
        Write-Log "$ServerName : $($Result.Error)" "WARN"
        Add-PendingRecheck -ServerName $ServerName
    } else {
        Update-ServerEntry -ServerName $ServerName -Properties @{
            Status  = "Error"
            Details = "Install error: $($Result.Error)"
        }
        Write-Log "$ServerName : Install failed - $($Result.Error)" "ERROR"
    }
    Step-Progress
}

# Shared tail for post-reboot monitor jobs. The single, sequential and parallel
# reboot paths each carried an identical copy of this block, so every fix had
# to be made in three places.
function Complete-RebootMonitor {
    param([string]$ServerName, $Monitor)

    # Neither losing the monitor nor an error inside it proves anything about
    # the server, so both now fall back to the one check that does - a scan.
    # A job that produced no output at all used to land in the default branch
    # and be logged as "Monitor error -" with nothing after it: the tool called
    # the server broken and stopped watching, without saying why, while the
    # machine was very likely on its way back up.
    $phase = if ($null -eq $Monitor) { $null } else { $Monitor.Phase }

    switch ($phase) {
        "Online" {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = "Back Online"
                RebootRequired = "No"
                Details        = "Server came back online at $(Get-Date -Format 'HH:mm:ss'). Re-scanning..."
            }
            Write-Log "$ServerName : Back online - starting post-reboot scan"
            # -NoProgress: this rescan belongs to the reboot batch that is
            # already being counted, not to a scan batch of its own.
            Invoke-ScanServer -ServerName $ServerName -NoProgress
        }
        "Timeout" {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Offline"
                Details = "Server did not respond after reboot. $($Monitor.Error)"
            }
            Write-Log "$ServerName : Post-reboot timeout - server not responding" "WARN"
        }
        "WinRMTimeout" {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Partially Online"
                Details = "Server responds to ping but WinRM is not ready. $($Monitor.Error)"
            }
            Write-Log "$ServerName : Pingable but WinRM not ready" "WARN"
        }
        default {
            $reason =
                if     ($null -eq $Monitor) { "the monitor job returned no result" }
                elseif ($Monitor.Error)     { $Monitor.Error }
                elseif ($phase)             { "the monitor reported '$phase' without a reason" }
                else                        { "the monitor result carried no phase" }

            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Reboot issued"
                Details = "Lost track of the reboot: $reason. Re-scanning to find out whether the server is back."
            }
            Write-Log "$ServerName : lost track of the reboot - $reason; re-scanning instead" "WARN"
            Invoke-ScanServer -ServerName $ServerName -NoProgress
        }
    }
    Step-Progress
}

# Starts the watch that proves a server really came back, and hands the queue on
# afterwards when a sequential run is waiting for it.
#
# This has to be a function. A completion callback is a closure, and a closure
# is bound to a module of its own: it sees only the local variables copied into
# it when it was created. Two consequences bit here. A $script: variable read
# from inside one comes out empty - so launching the monitor from within the
# reboot callback passed a null script block to the job, which then finished
# instantly with no output at all. And a closure created inside another closure
# captures nothing, so the callback had no server name in it: the fallback
# rescan went out with an empty -ComputerName and failed on the spot. Both are
# visible in the log as a monitor that "returned no result" one second after
# the reboot, followed by lines with no server name in them.
# Applies the result of an Active Directory query to the grid. A function for
# the same reason as Start-RebootMonitor: this ran inside a completion closure,
# where $script:ServerData and $window are both empty. The duplicate check
# therefore passed for every name, and the add that followed was made on
# nothing at all.
#
# No dispatcher hop here: completion callbacks are delivered by a
# DispatcherTimer, so this is already on the UI thread.
function Complete-ADImport {
    param($Result)

    if (-not $Result.Success) {
        Write-Log "AD query failed: $($Result.Error)" "ERROR"
        Update-StatusBar "AD query failed"
        return
    }

    $added = 0
    foreach ($name in $Result.Servers) {
        if (-not ($script:ServerData | Where-Object { $_.ServerName -eq $name.ToUpper() })) {
            $script:ServerData.Add((New-ServerEntry -Name $name))
            $added++
        }
    }
    Update-ServerCount
    Save-ServerList
    Write-Log "AD query complete: found $($Result.Servers.Count) servers, added $added new"
    Update-StatusBar "Added $added servers from Active Directory"
}

function Start-RebootMonitor {
    param([string]$ServerName, $BootBefore, [switch]$Sequential)

    $monCred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RebootMonitorScript `
                   -Arguments @($ServerName, $monCred, $BootBefore, (Get-RebootTimeout)) `
                   -OnComplete {
        param($monResult)
        Complete-RebootMonitor -ServerName $ServerName -Monitor ($monResult | Select-Object -First 1)
        if ($Sequential) { Step-RebootQueue }
    }.GetNewClosure()
}

# Stops this tool from starting or watching anything further.
#
# It cannot recall work already handed to a server: an install that has begun
# runs to completion under its own scheduled task, and a reboot that has been
# issued still happens. Statuses below say so rather than claiming everything
# was cancelled.
function Stop-AllOperations {
    # The guard stops runs too, and "Stopped by user" in the log for a halt the
    # user did not ask for would send the next investigation the wrong way.
    param([string]$Reason = "Stopped by user")

    # Empty the queues first, so no completion handler can start the next server.
    $script:SequentialQueue.Clear()
    $script:RebootQueue.Clear()
    $script:SequentialRunning  = $false
    $script:RebootQueueRunning = $false
    $script:PendingRechecks.Clear()

    $stopped = $script:ActiveJobs.Count
    foreach ($job in @($script:ActiveJobs)) {
        try { $job.PowerShell.Stop() }    catch { }
        try { $job.PowerShell.Dispose() } catch { }
    }
    $script:ActiveJobs.Clear()

    $script:ProgressTotal = 0
    $script:ProgressDone  = 0
    Show-Progress -Visible $false

    foreach ($s in @($script:ServerData)) {
        switch -Wildcard ($s.Status) {
            "Scanning*" {
                Update-ServerEntry -ServerName $s.ServerName -Properties @{
                    Status  = "Cancelled"
                    Details = "Scan cancelled"
                }
            }
            "Installing*" {
                Update-ServerEntry -ServerName $s.ServerName -Properties @{
                    Status  = "Cancelled"
                    Details = "Stopped watching. The install may still be running on the server - rescan to see the result."
                }
            }
            "Rebooting*" {
                Update-ServerEntry -ServerName $s.ServerName -Properties @{
                    Status  = "Rebooting (unmonitored)"
                    Details = "Reboot was already issued. Monitoring stopped - rescan once the server is back."
                }
            }
        }
    }

    Update-StatusBar "Stopped"
    Write-Log "${Reason}: $stopped job(s) cancelled, queues cleared" "WARN"
}

function Invoke-ScanServer {
    param([string]$ServerName, [switch]$NoProgress)

    if (-not (Ensure-Credential)) { return }

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status  = "Scanning..."
        Details = "Checking for available updates..."
    }
    Write-Log "Scanning $ServerName for updates..."

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RunAsSystemScript -Arguments @($ServerName, $cred, $script:ScanPayload, $script:ScanTimeout, 'Scan') -OnComplete {
        param($result)
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            $status = if ($r.Count -gt 0) { "Available ($($r.Count))" } else { "Up to date" }
            $reboot = if ($r.RebootRequired) { "Yes" } else { "No" }
            $details = if ($r.Count -gt 0) {
                ($r.Updates | ForEach-Object { "KB$($_.KB): $($_.Title)" }) -join "; "
            } else { "No pending updates" }

            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = $status
                Available      = $r.Count.ToString()
                RebootRequired = $reboot
                LastScan       = (Get-Date -Format "yyyy-MM-dd HH:mm")
                Details        = $details
                UpdateList     = $r.Updates
            }
            Write-Log "$ServerName : $status$(if($r.RebootRequired){' (reboot required)'})"
        } else {
            $errMsg = if ($r.Error -match "WinRM") { "WinRM connection failed" }
                      elseif ($r.Error -match "Access") { "Access denied" }
                      elseif ($r.Error -match "not found|resolve") { "Offline" }
                      else { $r.Error }

            $displayStatus = if ($r.Error -match "not found|resolve") { "Offline" } else { "Error" }
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = $displayStatus
                Details = "Error: $errMsg"
            }
            Write-Log "$ServerName : $errMsg" "ERROR"
        }
        if (-not $NoProgress) { Step-Progress }
    }.GetNewClosure()
}

# -- Pre-flight ---------------------------------------------------------------
# An install that runs the system drive dry fails with 0x80070070 about an hour
# in, having spent the window and changed nothing. A disabled update agent fails
# on the first call into it. Both facts cost one WinRM round trip to learn
# beforehand, so they are learned beforehand.
$script:MinFreeSpaceGB = 8

$script:PreflightScript = {
    param([string]$ServerName, [PSCredential]$Credential)
    try {
        $facts = Invoke-Command -ComputerName $ServerName -Credential $Credential -ErrorAction Stop -ScriptBlock {
            $sysDrive = $env:SystemDrive
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction Stop
            $svc  = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
            # The two places Windows records that it wants restarting. Either is
            # enough; neither is fatal on its own.
            $pending = $false
            foreach ($key in @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
                if (Test-Path -LiteralPath $key) { $pending = $true }
            }
            [PSCustomObject]@{
                FreeSpaceGB   = [math]::Round(($disk.FreeSpace / 1GB), 1)
                ServiceExists = ($null -ne $svc)
                StartMode     = if ($svc) { "$($svc.StartMode)" } else { "" }
                RebootPending = $pending
            }
        }
        [PSCustomObject]@{ Success = $true; Error = ""; Facts = $facts }
    } catch {
        [PSCustomObject]@{ Success = $false; Error = $_.Exception.Message; Facts = $null }
    }
}

# Turns the facts into a verdict. Pure, and separate from the job that collects
# them, so the thresholds can be argued with in the tests rather than on a
# maintenance evening.
function Test-InstallPreflight {
    param($Result)

    if (-not $Result -or -not $Result.Success) {
        $why = if ($Result -and $Result.Error) { $Result.Error } else { "the check did not come back" }
        return [PSCustomObject]@{ Ok = $false; Blockers = @("the pre-flight check failed: $why"); Warnings = @() }
    }
    $facts = $Result.Facts
    if (-not $facts) {
        return [PSCustomObject]@{ Ok = $false; Blockers = @("the pre-flight check returned nothing"); Warnings = @() }
    }

    $blockers = @()
    $warnings = @()

    if ($facts.FreeSpaceGB -lt $script:MinFreeSpaceGB) {
        $blockers += "only $($facts.FreeSpaceGB) GB free on the system drive, $($script:MinFreeSpaceGB) GB wanted"
    }
    if (-not $facts.ServiceExists) {
        $blockers += "the Windows Update service is not present"
    } elseif ($facts.StartMode -eq 'Disabled') {
        $blockers += "the Windows Update service is disabled"
    }
    # Deliberately not a blocker: plenty of estates patch on top of a pending
    # reboot without trouble. It does explain a failure afterwards, which is the
    # reason for saying it out loud beforehand.
    if ($facts.RebootPending) {
        $warnings += "a reboot is already pending - the install may fail until it is taken"
    }

    return [PSCustomObject]@{ Ok = ($blockers.Count -eq 0); Blockers = $blockers; Warnings = $warnings }
}

function Start-InstallPreflight {
    param([string]$ServerName, [bool]$Sequential)

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status    = "Checking..."
        # Clear the count from the previous run. It is only written back when an
        # install succeeds, so leaving it meant a run that failed outright - a
        # dropped connection, a refusing update agent - kept showing yesterday's
        # number, as if those updates had just gone on.
        Installed = "-"
        Details   = "Checking disk space and the update agent before installing..."
    }

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:PreflightScript -Arguments @($ServerName, $cred) -OnComplete {
        param($result)
        Complete-InstallPreflight -ServerName $ServerName -Sequential $Sequential -Result ($result | Select-Object -First 1)
    }.GetNewClosure()
}

# Named, not folded into the callback above, for the usual reason: it reads and
# writes $script: state and hands the sequential queue on, and neither survives
# being done inside a closure.
function Complete-InstallPreflight {
    param([string]$ServerName, [bool]$Sequential, $Result)

    $verdict = Test-InstallPreflight -Result $Result
    foreach ($warning in $verdict.Warnings) {
        Write-Log "$ServerName : $warning" "WARN"
    }

    if (-not $verdict.Ok) {
        $why = $verdict.Blockers -join '; '
        Update-ServerEntry -ServerName $ServerName -Properties @{
            Status  = "Blocked"
            Details = "Install not started: $why"
        }
        Write-Log "$ServerName : install not started - $why" "ERROR"
        # The server still counted towards the batch, and a sequential queue
        # that is not handed on here simply stops.
        Step-Progress
        if ($Sequential) { Step-SequentialInstallQueue }
        return $false
    }

    Start-InstallJob -ServerName $ServerName -Sequential $Sequential
    return $true
}

# The install proper. Single and sequential runs differed only in what they did
# afterwards, which is now the one parameter.
function Start-InstallJob {
    param([string]$ServerName, [bool]$Sequential)

    $holding = if ($script:ExcludedKB.Count -gt 0) {
        " (holding back $(($script:ExcludedKB | ForEach-Object { "KB$_" }) -join ', '))"
    } else { "" }
    $mode = if ($Sequential) { " (sequential)" } else { "" }

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status    = "Installing..."
        Installed = "-"
        Details   = "Downloading and installing updates$holding$mode..."
    }
    Write-Log "Installing updates on $ServerName$mode$holding"

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RunAsSystemScript -Arguments @($ServerName, $cred, (Get-InstallPayload), (Get-InstallTimeout), 'Install') -OnComplete {
        param($result)
        Complete-InstallResult -ServerName $ServerName -Result ($result | Select-Object -First 1)
        if ($Sequential) { Step-SequentialInstallQueue }
    }.GetNewClosure()
}

function Invoke-InstallServer {
    param([string]$ServerName)

    if (-not (Ensure-Credential)) { return }
    Start-InstallPreflight -ServerName $ServerName -Sequential $false
}

function Invoke-RebootServer {
    param([string]$ServerName)

    if (-not (Ensure-Credential)) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Are you sure you want to reboot $($ServerName)?",
        "Confirm Reboot",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne "Yes") { return }

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status  = "Rebooting..."
        Details = "Reboot initiated..."
    }
    Write-Log "Rebooting $ServerName..."

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RebootScript -Arguments @($ServerName, $cred) -OnComplete {
        param($result)
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = "Rebooting..."
                RebootRequired = "Pending"
                Details        = "Reboot initiated at $(Get-Date -Format 'HH:mm:ss'). Monitoring server..."
            }
            Write-Log "$ServerName : Reboot initiated - monitoring until back online"

            Start-RebootMonitor -ServerName $ServerName -BootBefore $r.BootBefore
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Reboot failed: $($r.Error)"
            }
            Write-Log "$ServerName : Reboot failed - $($r.Error)" "ERROR"
        }
    }.GetNewClosure()
}

# -- Event Handlers ------------------------------------------------------------

# Add servers
$ui.btnAddServer.Add_Click({
    # Not $input: that is an automatic variable holding the pipeline enumerator.
    $entered = $ui.txtServerName.Text.Trim()
    if (-not $entered) { return }

    $names = $entered -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpper() }
    foreach ($name in $names) {
        if ($script:ServerData | Where-Object { $_.ServerName -eq $name }) {
            Write-Log "$name is already in the list" "WARN"
            continue
        }
        $entry = New-ServerEntry -Name $name
        $script:ServerData.Add($entry)
        Write-Log "Added server: $name"
    }
    $ui.txtServerName.Clear()
    Update-ServerCount
    Save-ServerList
})

# Allow Enter key in the server name textbox
$ui.txtServerName.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq "Return") {
        $ui.btnAddServer.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }
})

# Browse AD
$ui.btnBrowseAD.Add_Click({
    try {
        $ou = [Microsoft.VisualBasic.Interaction]::InputBox(
            "Enter the OU distinguished name to search (leave empty for all servers):`n`nExample: OU=Servers,DC=contoso,DC=com",
            "Browse Active Directory",
            ""
        )
    } catch {
        # Fallback if VisualBasic not available
        $ou = ""
    }

    Write-Log "Querying Active Directory for servers..."
    Update-StatusBar "Querying Active Directory..."

    Start-AsyncJob -ScriptBlock {
        param([string]$OU, [PSCredential]$Credential)
        try {
            $params = @{
                Filter     = 'OperatingSystem -like "*Server*"'
                Properties = @('Name', 'OperatingSystem', 'Enabled')
            }
            if ($OU) { $params.SearchBase = $OU }
            if ($Credential) { $params.Credential = $Credential }

            $servers = Get-ADComputer @params |
                Where-Object { $_.Enabled -eq $true } |
                Select-Object -ExpandProperty Name |
                Sort-Object
            return [PSCustomObject]@{ Success = $true; Servers = $servers; Error = $null }
        } catch {
            return [PSCustomObject]@{ Success = $false; Servers = @(); Error = $_.Exception.Message }
        }
    } -Arguments @($ou, $(if($script:DefaultCredentialLabel){$script:Credentials[$script:DefaultCredentialLabel]}else{$null})) -OnComplete {
        param($result)
        Complete-ADImport -Result ($result | Select-Object -First 1)
    }
})

# Import from file
$ui.btnImportFile.Add_Click({
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Filter = "Text files (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*"
    $dlg.Title = "Import Server List"
    if ($dlg.ShowDialog()) {
        $names = Get-Content $dlg.FileName | ForEach-Object {
            ($_ -split '[,;\t]')[0].Trim()
        } | Where-Object { $_ -and $_ -notmatch '^\s*#' }

        $added = 0
        foreach ($name in $names) {
            $upper = $name.ToUpper()
            if (-not ($script:ServerData | Where-Object { $_.ServerName -eq $upper })) {
                $script:ServerData.Add((New-ServerEntry -Name $name))
                $added++
            }
        }
        Update-ServerCount
        Save-ServerList
        Write-Log "Imported $added servers from file"
    }
})

# Remove selected
$ui.btnRemoveSelected.Add_Click({
    $toRemove = @($script:ServerData | Where-Object { $_.Selected })
    foreach ($s in $toRemove) {
        $script:ServerData.Remove($s) | Out-Null
    }
    Update-ServerCount
    if ($toRemove.Count -gt 0) {
        Save-ServerList
        Write-Log "Removed $($toRemove.Count) server(s)"
    }
})

# Clear all
$ui.btnClearAll.Add_Click({
    $confirm = [System.Windows.MessageBox]::Show(
        "Remove all servers from the list?", "Confirm",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($confirm -eq "Yes") {
        $script:ServerData.Clear()
        Update-ServerCount
        Save-ServerList
        Write-Log "Cleared all servers"
    }
})

# Scan Selected (only checked servers)
$ui.btnScanSelected.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData | Where-Object { $_.Selected })
    if ($servers.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No servers are checked. Use the checkboxes to select servers first.",
            "No Selection", "OK", "Information"
        )
        return
    }

    Sync-RunspacePool
    Start-ProgressBatch -Total $servers.Count
    Update-StatusBar "Scanning $($servers.Count) selected server(s)..."

    foreach ($s in $servers) {
        Invoke-ScanServer -ServerName $s.ServerName
    }
})

# Scan All (every server in the list)
$ui.btnScanAll.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData)
    if ($servers.Count -eq 0) { return }

    Sync-RunspacePool
    Start-ProgressBatch -Total $servers.Count
    Update-StatusBar "Scanning ALL $($servers.Count) server(s)..."

    foreach ($s in $servers) {
        Invoke-ScanServer -ServerName $s.ServerName
    }
})

# -- Sequential Install Logic --------------------------------------------------
# Advances the install queue: next server, or wind the run down.
#
# This has to be a function rather than a few lines in the completion callback.
# Those callbacks are created with .GetNewClosure(), and a closure is bound to a
# module of its own: reading $script: still works and method calls like
# Dequeue() still mutate the real object, but a plain assignment such as
# "$script:SequentialRunning = $false" lands in the closure's own scope and
# never reaches the variable Start-InstallBatch reads. The flag stayed $true for
# the rest of the session, so every later batch was refused with "a sequential
# run is still in progress" until the tool was restarted. A function keeps the
# session state it was defined in, so its writes land where they are read.
function Step-SequentialInstallQueue {
    if ($script:SequentialQueue.Count -gt 0) {
        $next = $script:SequentialQueue.Dequeue()
        Update-StatusBar "Installing on $next... ($($script:SequentialQueue.Count) remaining in queue)"
        Invoke-InstallServerSequential -ServerName $next
    } else {
        $script:SequentialRunning = $false
        Update-StatusBar "Sequential install complete"
        Show-Progress -Visible $false
        Write-Log "Sequential install queue completed"
    }
}

function Invoke-InstallServerSequential {
    param([string]$ServerName)

    if (-not (Ensure-Credential)) {
        $script:SequentialRunning = $false
        return
    }
    Start-InstallPreflight -ServerName $ServerName -Sequential $true
}

# Helper function to run install on a list of servers (used by both Selected and All)
function Start-InstallBatch {
    param([array]$Servers, [string]$Label)

    if ($Servers.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No $Label servers have available updates. Scan first.",
            "No Updates", "OK", "Information"
        )
        return
    }

    # A second click used to Clear() the queue mid-flight: the running chain
    # lost its tail and two chains then advanced in parallel.
    if ($script:SequentialRunning -or $script:RebootQueueRunning) {
        [System.Windows.MessageBox]::Show(
            "A sequential run is still in progress. Wait for it to finish before starting another.",
            "Busy", "OK", "Information"
        )
        return
    }

    $isSequential = $ui.rbSequential.IsChecked
    $modeLabel = if ($isSequential) { "sequentially (one-by-one)" } else { "in parallel" }

    $confirm = [System.Windows.MessageBox]::Show(
        "Install updates on $($Servers.Count) $Label server(s) $modeLabel ?`n`nThis may take a while and some servers may require a reboot afterward.",
        "Confirm Install",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne "Yes") { return }

    Sync-RunspacePool
    Start-ProgressBatch -Total $Servers.Count

    if ($isSequential) {
        $script:SequentialQueue.Clear()
        foreach ($s in $Servers) {
            $script:SequentialQueue.Enqueue($s.ServerName)
        }
        $script:SequentialRunning = $true
        $first = $script:SequentialQueue.Dequeue()
        Update-StatusBar "Installing on $first... ($($script:SequentialQueue.Count) remaining in queue)"
        Write-Log "Starting sequential install on $($Servers.Count) server(s)"
        Invoke-InstallServerSequential -ServerName $first
    } else {
        Update-StatusBar "Installing updates on $($Servers.Count) server(s) in parallel..."
        Write-Log "Starting parallel install on $($Servers.Count) server(s)"
        foreach ($s in $Servers) {
            Invoke-InstallServer -ServerName $s.ServerName
        }
    }
}

# Install Selected (only checked servers with available updates)
$ui.btnInstallSelected.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData | Where-Object { $_.Selected -and $_.Status -like "Available*" })
    Start-InstallBatch -Servers $servers -Label "selected"
})

# Install All (all servers with available updates, regardless of checkbox)
$ui.btnInstallAll.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData | Where-Object { $_.Status -like "Available*" })
    Start-InstallBatch -Servers $servers -Label ""
})

# Helper function to run reboot on a list of servers (used by both Selected and All)
# -- Sequential Reboot Logic ---------------------------------------------------
$script:RebootQueue = [System.Collections.Generic.Queue[string]]::new()
$script:RebootQueueRunning = $false

# Advances the reboot queue. A function for the same reason as
# Step-SequentialInstallQueue: the callers are closures, and a flag cleared
# inside one of those never reaches the flag the batch buttons read.
# -AfterFailure only changes the wording - a failed reboot must not strand the
# servers queued behind it.
function Step-RebootQueue {
    param([switch]$AfterFailure)

    if ($script:RebootQueue.Count -gt 0) {
        $next = $script:RebootQueue.Dequeue()
        $note = if ($AfterFailure) { " (previous failed)" } else { "" }
        Update-StatusBar "Rebooting $next... ($($script:RebootQueue.Count) remaining in queue)"
        Write-Log "Sequential reboot: proceeding to $next$note"
        Invoke-RebootServerSequential -ServerName $next
    } else {
        $script:RebootQueueRunning = $false
        Update-StatusBar "Sequential reboot complete"
        Show-Progress -Visible $false
        Write-Log "Sequential reboot queue completed"
    }
}

function Invoke-RebootServerSequential {
    param([string]$ServerName)

    $cred = Get-ServerCredential -ServerName $ServerName

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status  = "Rebooting..."
        Details = "Rebooting (sequential mode)..."
    }
    Write-Log "Rebooting $ServerName (sequential mode)..."

    Start-AsyncJob -ScriptBlock $script:RebootScript -Arguments @($ServerName, $cred) -OnComplete {
        param($result)
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = "Rebooting..."
                RebootRequired = "Pending"
                Details        = "Reboot initiated at $(Get-Date -Format 'HH:mm:ss'). Waiting for server to come back..."
            }
            Write-Log "$ServerName : Reboot initiated - monitoring until back online"

            Start-RebootMonitor -ServerName $ServerName -BootBefore $r.BootBefore -Sequential
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Reboot failed: $($r.Error)"
            }
            Write-Log "$ServerName : Reboot failed - $($r.Error)" "ERROR"

            # A failed reboot must not strand the servers queued behind it.
            Step-RebootQueue -AfterFailure
        }
    }.GetNewClosure()
}

# Helper for parallel reboot (fires all at once with monitoring)
function Start-RebootParallel {
    param([array]$Servers)

    foreach ($s in $Servers) {
        Update-ServerEntry -ServerName $s.ServerName -Properties @{
            Status  = "Rebooting..."
            Details = "Reboot initiated..."
        }
        Write-Log "Rebooting $($s.ServerName)..."

        $cred = Get-ServerCredential -ServerName $s.ServerName
        Start-AsyncJob -ScriptBlock $script:RebootScript -Arguments @($s.ServerName, $cred) -OnComplete {
            param($result)
            $r = $result | Select-Object -First 1
            $sn = $s.ServerName
            if ($r.Success) {
                Update-ServerEntry -ServerName $sn -Properties @{
                    Status         = "Rebooting..."
                    RebootRequired = "Pending"
                    Details        = "Reboot initiated at $(Get-Date -Format 'HH:mm:ss'). Monitoring server..."
                }
                Write-Log "$sn : Reboot initiated - monitoring until back online"

                Start-RebootMonitor -ServerName $sn -BootBefore $r.BootBefore
            } else {
                Update-ServerEntry -ServerName $sn -Properties @{
                    Status  = "Error"
                    Details = "Reboot failed: $($r.Error)"
                }
                Write-Log "$sn : Reboot failed - $($r.Error)" "ERROR"
            }
        }.GetNewClosure()
    }
}

function Start-RebootBatch {
    param([array]$Servers, [string]$Label)

    if ($Servers.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No $Label servers require a reboot.",
            "No Reboot Needed", "OK", "Information"
        )
        return
    }

    # See the note in Start-InstallBatch: the queue must not be rebuilt while a
    # chain is still walking it.
    if ($script:SequentialRunning -or $script:RebootQueueRunning) {
        [System.Windows.MessageBox]::Show(
            "A sequential run is still in progress. Wait for it to finish before starting another.",
            "Busy", "OK", "Information"
        )
        return
    }

    $isSequential = $ui.rbSequential.IsChecked
    $modeLabel = if ($isSequential) { "sequentially (one-by-one, waiting for each to come back)" } else { "in parallel (all at once)" }

    $confirm = [System.Windows.MessageBox]::Show(
        "Reboot $($Servers.Count) $Label server(s) $modeLabel ?`n`n$($Servers.ServerName -join ', ')`n`nThis will restart the servers!",
        "Confirm Reboot",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -ne "Yes") { return }

    Sync-RunspacePool
    Start-ProgressBatch -Total $Servers.Count

    if ($isSequential) {
        $script:RebootQueue.Clear()
        foreach ($s in $Servers) {
            $script:RebootQueue.Enqueue($s.ServerName)
        }
        $script:RebootQueueRunning = $true
        $first = $script:RebootQueue.Dequeue()
        Update-StatusBar "Rebooting $first... ($($script:RebootQueue.Count) remaining in queue)"
        Write-Log "Starting sequential reboot of $($Servers.Count) server(s)"
        Invoke-RebootServerSequential -ServerName $first
    } else {
        Update-StatusBar "Rebooting $($Servers.Count) server(s) in parallel..."
        Write-Log "Starting parallel reboot of $($Servers.Count) server(s)"
        Start-RebootParallel -Servers $Servers
    }
}

# Reboot Selected (only checked servers that need reboot)
$ui.btnRebootSelected.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData | Where-Object { $_.Selected -and $_.RebootRequired -eq "Yes" })
    Start-RebootBatch -Servers $servers -Label "selected"
})

# Reboot All (all servers that need reboot, regardless of checkbox)
$ui.btnRebootAll.Add_Click({
    if (-not (Ensure-Credential)) { return }
    $servers = @($script:ServerData | Where-Object { $_.RebootRequired -eq "Yes" })
    Start-RebootBatch -Servers $servers -Label ""
})

# Export CSV
$ui.btnExportCSV.Add_Click({
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Filter = "CSV files (*.csv)|*.csv"
    $dlg.FileName = "PatchStatus_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if ($dlg.ShowDialog()) {
        $script:ServerData | Select-Object ServerName, Status, Available, Installed, RebootRequired, LastScan, Details |
            Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        Write-Log "Exported results to $($dlg.FileName)"
    }
})

# Add credential
$ui.btnAddCredential.Add_Click({
    Add-CredentialSet -Message "Enter credentials (domain\username)`nMultiple credential sets can be added for different domains."
})

# Manage credentials (view/remove)
$ui.btnManageCredentials.Add_Click({
    if ($script:Credentials.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No credentials added yet.", "Manage Credentials", "OK", "Information")
        return
    }
    # Inside the Where-Object, $_ is the server entry rather than the credential
    # label, so the old one-liner compared an entry against itself and always
    # reported 0 servers. Bind the label to a named variable instead.
    $list = foreach ($label in @($script:Credentials.Keys)) {
        $isDefault   = if ($label -eq $script:DefaultCredentialLabel) { " (default)" } else { "" }
        $serverCount = @($script:ServerData | Where-Object { $_.CredentialLabel -eq $label }).Count
        "$label$isDefault - $serverCount server(s)"
    }
    $msg = "Current credentials:`n`n$($list -join "`n")`n`nTo remove a credential, enter the username below (leave empty to cancel):"
    try {
        $toRemove = [Microsoft.VisualBasic.Interaction]::InputBox($msg, "Manage Credentials", "")
    } catch {
        $toRemove = ""
    }
    Remove-CredentialSet -Label $toRemove | Out-Null
})

# Change the password on an existing credential
$ui.btnChangePassword.Add_Click({
    $label = Select-CredentialLabel -Title "Change Password" -Prompt "Change the password of which credential?"
    if (-not $label) { return }

    # The username box comes pre-filled but stays editable. Only the password is
    # taken from it: the label is what every server entry stores, so renaming an
    # account here would strand all of them. That is Add Credential plus Manage.
    $cred = Get-Credential -UserName $label -Message "Enter the new password for $label"
    if (-not $cred) { return }
    if ($cred.UserName -ne $label) {
        Write-Log "Username edited in the password prompt - only the password of $label was changed" "WARN"
    }
    if (-not (Set-CredentialPassword -Label $label -Password $cred.Password)) {
        [System.Windows.MessageBox]::Show("The password was not changed - it must not be empty.", "Change Password", "OK", "Warning")
    }
})

# Check that a credential still authenticates, before a maintenance window does
$ui.btnTestCredential.Add_Click({
    $label = Select-CredentialLabel -Title "Test Credential" -Prompt "Test which credential?"
    if (-not $label) { return }

    # Prefer whatever the operator is already looking at, then any server that
    # uses this account, and only ask when the grid cannot answer.
    $target = ""
    $selected = $ui.dgServers.SelectedItem
    if ($selected) {
        $target = $selected.ServerName
    } else {
        $bound = @($script:ServerData | Where-Object { $_.CredentialLabel -eq $label } | Select-Object -First 1)
        if ($bound.Count -gt 0) { $target = $bound[0].ServerName }
    }
    if (-not $target) {
        try {
            $target = [Microsoft.VisualBasic.Interaction]::InputBox(
                "Test '$label' against which server?", "Test Credential", "")
        } catch {
            $target = ""
        }
    }
    if (-not $target) { return }

    Invoke-CredentialTest -Label $label -ServerName $target.Trim() | Out-Null
})

# Updates to hold back on every install
$ui.btnHeldBackKB.Add_Click({
    $current = ($script:ExcludedKB | ForEach-Object { "KB$_" }) -join ', '
    $msg = "Updates to skip on every install, by KB number.`n`n" +
           "Separate them however you like - KB5120238, 5034441 - and clear the box to hold back nothing.`n`n" +
           "Anything that is not a KB number is dropped."
    try {
        $answer = [Microsoft.VisualBasic.Interaction]::InputBox($msg, "Held-back KBs", $current)
    } catch {
        return
    }
    # An empty box is a real answer - it means hold nothing back - so it cannot
    # simply be read as a cancelled dialog. InputBox returns "" for both, which
    # is why Cancel is only honoured when the list was empty to begin with.
    if (-not $answer -and -not $current) { return }

    $kept = Set-ExcludedKB -Text $answer
    $shown = if ($kept.Count -gt 0) {
        ($kept | ForEach-Object { "KB$_" }) -join ', '
    } else { "nothing" }
    [System.Windows.MessageBox]::Show(
        "Now holding back: $shown", "Held-back KBs", "OK", "Information") | Out-Null
})

# Context menu handlers
$ui.ctxScan.Add_Click({
    $selected = $ui.dgServers.SelectedItem
    if ($selected) { Invoke-ScanServer -ServerName $selected.ServerName }
})

$ui.ctxInstall.Add_Click({
    $selected = $ui.dgServers.SelectedItem
    if ($selected) { Invoke-InstallServer -ServerName $selected.ServerName }
})

$ui.ctxReboot.Add_Click({
    $selected = $ui.dgServers.SelectedItem
    if ($selected) { Invoke-RebootServer -ServerName $selected.ServerName }
})

$ui.ctxViewUpdates.Add_Click({
    $selected = $ui.dgServers.SelectedItem
    if ($selected -and $selected.UpdateList -and $selected.UpdateList.Count -gt 0) {
        $list = ($selected.UpdateList | ForEach-Object {
            "KB$($_.KB)  [$($_.Severity)]  $($_.Title)  ($($_.Size) MB)"
        }) -join "`n"
        [System.Windows.MessageBox]::Show(
            "Available updates for $($selected.ServerName):`n`n$list",
            "Available Updates - $($selected.ServerName)",
            "OK", "Information"
        )
    } else {
        [System.Windows.MessageBox]::Show(
            "No update details available. Scan the server first.",
            "No Data", "OK", "Information"
        )
    }
})

$ui.ctxAssignCredential.Add_Click({
    $selected = @($ui.dgServers.SelectedItems)
    if ($selected.Count -eq 0) { return }

    if ($script:Credentials.Count -eq 0) {
        [System.Windows.MessageBox]::Show(
            "No credentials available. Add a credential first using the 'Add Credential' button.",
            "No Credentials", "OK", "Information"
        )
        return
    }

    $credList = @($script:Credentials.Keys)
    $options = for ($i = 0; $i -lt $credList.Count; $i++) { "$($i+1). $($credList[$i])" }
    $msg = "Assign credential to $($selected.Count) server(s):`n`n$($options -join "`n")`n`nEnter the number:"
    try {
        $choice = [Microsoft.VisualBasic.Interaction]::InputBox($msg, "Assign Credential", "1")
    } catch {
        $choice = ""
    }
    if ($choice) {
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $credList.Count) {
            $newLabel = $credList[$idx - 1]
            foreach ($s in $selected) {
                $entry = $script:ServerData | Where-Object { $_.ServerName -eq $s.ServerName } | Select-Object -First 1
                if ($entry) { $entry.CredentialLabel = $newLabel }
            }
            $ui.dgServers.Items.Refresh()
            Save-ServerList
            Write-Log "Assigned credential '$newLabel' to $($selected.Count) server(s)"
        }
    }
})

$ui.ctxSelectAll.Add_Click({
    foreach ($s in $script:ServerData) { $s.Selected = $true }
    $ui.dgServers.Items.Refresh()
})

$ui.ctxDeselectAll.Add_Click({
    foreach ($s in $script:ServerData) { $s.Selected = $false }
    $ui.dgServers.Items.Refresh()
})

$ui.ctxRemove.Add_Click({
    $selected = $ui.dgServers.SelectedItem
    if ($selected) {
        $script:ServerData.Remove($selected) | Out-Null
        Update-ServerCount
        Save-ServerList
    }
})

# Stop everything
$ui.btnStop.Add_Click({
    if ($script:ActiveJobs.Count -eq 0 -and
        $script:SequentialQueue.Count -eq 0 -and
        $script:RebootQueue.Count -eq 0) { return }

    $confirm = [System.Windows.MessageBox]::Show(
        "Stop all operations?`n`nServers still queued will not be started, and monitoring will stop.`n`nWork already sent to a server cannot be recalled: an install that has begun will finish on its own, and a reboot that has been issued will still happen.",
        "Confirm Stop",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($confirm -eq "Yes") { Stop-AllOperations }
})

# Remember credentials on/off. Unchecking deletes the stored file straight
# away rather than at exit, so the secret is gone the moment the user says so.
$ui.chkRememberCredentials.Add_Checked({
    Save-Credentials
    Write-Log "Credentials will be remembered for the next launch (encrypted for this Windows account)"
})

$ui.chkRememberCredentials.Add_Unchecked({
    Remove-SavedCredentials
    Write-Log "Saved credentials deleted from disk"
})

# Clear log
$ui.btnClearLog.Add_Click({
    $ui.txtLog.Clear()
})

# -- Cleanup on close ---------------------------------------------------------
$window.Add_Closed({
    Save-ServerList
    $script:JobTimer.Stop()
    foreach ($job in $script:ActiveJobs) {
        try { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } catch {}
    }
    if ($script:RunspacePool) { $script:RunspacePool.Dispose() }
})

# -- Load VisualBasic assembly for InputBox (AD browser) ----------------------
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch {}

# -- Launch --------------------------------------------------------------------
# Bring back today's log first, before this session appends anything to it.
Restore-LogWindow

Write-Log "Server Patch Tool started"

# Load saved servers
Load-ServerList

# And whatever the operator has decided not to install
Load-ExcludedKB | Out-Null

# Restore saved credentials. Setting the checkbox fires Add_Checked, which
# re-saves the same data - harmless, and it keeps the box honest about state.
if (Load-Credentials) {
    $ui.chkRememberCredentials.IsChecked = $true
} else {
    Write-Log "Please authenticate to begin managing servers"
}

# Prompt for credentials on startup, but only if nothing was restored.
$window.Add_ContentRendered({
    if ($script:Credentials.Count -gt 0) { return }
    $result = Add-CredentialSet -Message "Enter primary credentials for server management (domain\username)`nYou can add more credentials later for other domains."
    if (-not $result) {
        Write-Log "No credentials provided. Add credentials via the 'Add Credential' button." "WARN"
    }
})

$window.ShowDialog() | Out-Null
