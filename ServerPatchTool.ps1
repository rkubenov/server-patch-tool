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

# ── Assemblies ────────────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# ── Persistent server list file ──────────────────────────────────────────────
$script:DataFile = Join-Path $PSScriptRoot "servers.json"

# ── Log file ─────────────────────────────────────────────────────────────────
# One file per day next to the script. The in-window log is cleared on close,
# which left no record of what was patched during a change window.
$script:LogDir  = Join-Path $PSScriptRoot "logs"
$script:LogFile = Join-Path $script:LogDir ("ServerPatchTool_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

# ── XAML UI Definition ────────────────────────────────────────────────────────
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Server Patch Tool" Height="720" Width="1100"
        MinHeight="600" MinWidth="900"
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
                    <Button x:Name="btnAddCredential" Content="Add Credential" FontSize="12"
                            ToolTip="Add a new credential set (domain\username)"/>
                    <Button x:Name="btnManageCredentials" Content="Manage" FontSize="12"
                            ToolTip="View and remove saved credentials"/>
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

# ── Create Window ─────────────────────────────────────────────────────────────
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# ── Resolve named controls ───────────────────────────────────────────────────
$ui = @{}
$xaml.SelectNodes('//*[@*[contains(translate(name(),"x","X"),"Name")]]') | ForEach-Object {
    $name = $_.Name
    if (-not $name) { $name = $_.'x:Name' }
    if ($name) { $ui[$name] = $window.FindName($name) }
}

# ── State ─────────────────────────────────────────────────────────────────────
$script:Credentials  = @{}   # Key = "DOMAIN\user" (label), Value = PSCredential object
$script:DefaultCredentialLabel = $null  # label of the default/first credential added
$script:ServerData   = [System.Collections.ObjectModel.ObservableCollection[PSObject]]::new()
$script:RunspacePool = $null
$script:ActiveJobs   = [System.Collections.Generic.List[PSObject]]::new()

$ui.dgServers.ItemsSource = $script:ServerData

# ── Sequential queue state ────────────────────────────────────────────────────
$script:SequentialQueue = [System.Collections.Generic.Queue[string]]::new()
$script:SequentialRunning = $false

# ── Persistent Storage ────────────────────────────────────────────────────────
function Save-ServerList {
    $data = @($script:ServerData | ForEach-Object {
        @{ Name = $_.ServerName; Credential = $_.CredentialLabel }
    })
    $data | ConvertTo-Json -Depth 3 | Set-Content -Path $script:DataFile -Encoding UTF8 -Force
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
                    $script:ServerData.Add((New-ServerEntry -Name $name -CredLabel $credLabel))
                }
            }
            Write-Log "Loaded $($raw.Count) server(s) from saved list"
        } catch {
            Write-Log "Failed to load saved server list: $($_.Exception.Message)" "WARN"
        }
    }
    Update-ServerCount
}

# ── Helpers ───────────────────────────────────────────────────────────────────
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
        Write-Log "Added credential: $label"
        return $label
    }
    return $null
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
    # Fallback: return any available credential
    if ($script:Credentials.Count -gt 0) {
        return @($script:Credentials.Values)[0]
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

# ── Initialize Runspace Pool ─────────────────────────────────────────────────
function Initialize-RunspacePool {
    if ($script:RunspacePool) { $script:RunspacePool.Dispose() }
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, 10, $iss, [System.Management.Automation.Host.PSHost]$Host)
    $script:RunspacePool.ApartmentState = "STA"
    $script:RunspacePool.Open()
}
Initialize-RunspacePool

# ── Remote Operations ─────────────────────────────────────────────────────────
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

    if ($searchResult.Updates.Count -eq 0) {
        $result = @{
            Success        = $true
            InstalledCount = 0
            FailedCount    = 0
            RebootRequired = $false
            Error          = $null
            Message        = "No updates to install"
        }
    } else {
        # Accept EULAs - required before download/install
        foreach ($u in $searchResult.Updates) {
            if (-not $u.EulaAccepted) {
                $u.AcceptEula()
                Log "Accepted EULA: $($u.Title)"
            }
        }

        # Download
        $toDownload = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $searchResult.Updates) {
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
        foreach ($u in $searchResult.Updates) {
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

            $ok = 0; $fail = 0
            for ($i = 0; $i -lt $toInstall.Count; $i++) {
                $rc = $installResult.GetUpdateResult($i).ResultCode
                $title = $toInstall.Item($i).Title
                if ($rc -eq 2) {
                    $ok++
                    Log "  OK: $title"
                } else {
                    $fail++
                    Log "  FAILED (code $rc): $title"
                }
            }

            $sysInfo = New-Object -ComObject Microsoft.Update.SystemInfo
            $result = @{
                Success        = $true
                InstalledCount = $ok
                FailedCount    = $fail
                RebootRequired = $sysInfo.RebootRequired
                Error          = $null
                Message        = "Installed $ok update(s)"
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
                        return (@{
                            Success = $false
                            Error   = "$Op timed out after $([int]($Timeout / 60)) minutes. Log: $diag"
                            Message = "Timed out"
                        } | ConvertTo-Json -Depth 3)
                    }
                    $err = "Result file not created. "
                    if ($diag) { $err += "Log: $diag" }
                    else       { $err += "No diagnostic log found - the task may have failed to start." }
                    return (@{ Success = $false; Error = $err; Message = "Task failed" } | ConvertTo-Json -Depth 3)
                } finally {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-Item -Path $scriptPath, $resultPath, $logPath -Force -ErrorAction SilentlyContinue
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
$script:ScanTimeout    = 600    # 10 min
$script:InstallTimeout = 1800   # 30 min

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
    param([string]$ServerName, [PSCredential]$Credential, $BootBefore)

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

    try {
        # Cumulative updates applied during shutdown/startup can take a while.
        $deadline = (Get-Date).AddMinutes(30)
        $sawDown  = $false

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 10
            $boot = & $probe $ServerName $Credential

            if ($null -eq $boot) {
                # Unreachable: shutting down, or still booting.
                $sawDown = $true
                continue
            }
            if ($BootBefore) {
                if ([datetime]$boot -ne [datetime]$BootBefore) {
                    return [PSCustomObject]@{ Phase = "Online"; Error = $null }
                }
                # Reachable with the same boot time: shutdown has not begun yet.
            } elseif ($sawDown) {
                # No baseline was captured - fall back to down-then-up.
                return [PSCustomObject]@{ Phase = "Online"; Error = $null }
            }
        }

        # Timed out. The ping here is diagnostic only, never a gate: it just
        # distinguishes "box is up, WinRM is not" from "box is gone".
        $pingable = Test-Connection -ComputerName $ServerName -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($pingable) {
            return [PSCustomObject]@{
                Phase = "WinRMTimeout"
                Error = "Server answers ping but no completed reboot was confirmed within 30 minutes"
            }
        }
        return [PSCustomObject]@{
            Phase = "Timeout"
            Error = "Server did not come back within 30 minutes"
        }
    } catch {
        return [PSCustomObject]@{ Phase = "Error"; Error = $_.Exception.Message }
    }
}

# ── Async Job Runner ──────────────────────────────────────────────────────────
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
$script:JobTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:JobTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:JobTimer.Add_Tick({
    $completed = @()
    foreach ($job in $script:ActiveJobs) {
        if ($job.Handle.IsCompleted) {
            try {
                $result = $job.PowerShell.EndInvoke($job.Handle)
                if ($job.OnComplete) {
                    & $job.OnComplete $result
                }
            } catch {
                Write-Log "Job error: $($_.Exception.Message)" "ERROR"
            } finally {
                $job.PowerShell.Dispose()
            }
            $completed += $job
        }
    }
    foreach ($c in $completed) {
        $script:ActiveJobs.Remove($c) | Out-Null
    }

    # Update progress
    if ($script:ActiveJobs.Count -eq 0) {
        Show-Progress -Visible $false
    }
})
$script:JobTimer.Start()

# ── Update server entry in the grid (thread-safe) ────────────────────────────
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

# ── Server Operations ─────────────────────────────────────────────────────────
function Invoke-ScanServer {
    param([string]$ServerName)

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
        Step-Progress
    }.GetNewClosure()
}

function Invoke-InstallServer {
    param([string]$ServerName)

    if (-not (Ensure-Credential)) { return }

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status  = "Installing..."
        Details = "Downloading and installing updates..."
    }
    Write-Log "Installing updates on $ServerName..."

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RunAsSystemScript -Arguments @($ServerName, $cred, $script:InstallPayload, $script:InstallTimeout, 'Install') -OnComplete {
        param($result)
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            $reboot = if ($r.RebootRequired) { "Yes" } else { "No" }
            $status = if ($r.RebootRequired) { "Reboot Required" }
                      elseif ($r.InstalledCount -gt 0) { "Up to date" }
                      else { "Up to date" }
            $details = $r.Message
            if ($r.FailedCount -gt 0) { $details += " ($($r.FailedCount) failed)" }

            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = $status
                Installed      = $r.InstalledCount.ToString()
                Available      = "0"
                RebootRequired = $reboot
                Details        = $details
            }
            Write-Log "$ServerName : $($r.Message)$(if($r.RebootRequired){' - reboot required'})"
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Install error: $($r.Error)"
            }
            Write-Log "$ServerName : Install failed - $($r.Error)" "ERROR"
        }
        Step-Progress
    }.GetNewClosure()
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

            # Launch the post-reboot monitor
            $monCred = Get-ServerCredential -ServerName $ServerName
            Start-AsyncJob -ScriptBlock $script:RebootMonitorScript -Arguments @($ServerName, $monCred, $r.BootBefore) -OnComplete {
                param($monResult)
                $m = $monResult | Select-Object -First 1
                $phase = $m.Phase
                if ($phase -eq "Online") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status         = "Back Online"
                        RebootRequired = "No"
                        Details        = "Server came back online at $(Get-Date -Format 'HH:mm:ss'). Re-scanning..."
                    }
                    Write-Log "$ServerName : Back online - starting post-reboot scan"
                    Invoke-ScanServer -ServerName $ServerName
                } elseif ($phase -eq "Timeout") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Offline"
                        Details = "Server did not respond after reboot. $($m.Error)"
                    }
                    Write-Log "$ServerName : Post-reboot timeout - server not responding" "WARN"
                } elseif ($phase -eq "WinRMTimeout") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Partially Online"
                        Details = "Server responds to ping but WinRM is not ready. $($m.Error)"
                    }
                    Write-Log "$ServerName : Pingable but WinRM not ready" "WARN"
                } else {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Error"
                        Details = "Post-reboot monitor error: $($m.Error)"
                    }
                    Write-Log "$ServerName : Monitor error - $($m.Error)" "ERROR"
                }
            }.GetNewClosure()
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Reboot failed: $($r.Error)"
            }
            Write-Log "$ServerName : Reboot failed - $($r.Error)" "ERROR"
        }
    }.GetNewClosure()
}

# ── Event Handlers ────────────────────────────────────────────────────────────

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
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            $added = 0
            foreach ($name in $r.Servers) {
                if (-not ($script:ServerData | Where-Object { $_.ServerName -eq $name.ToUpper() })) {
                    $window.Dispatcher.Invoke([action]{
                        $script:ServerData.Add((New-ServerEntry -Name $name))
                    })
                    $added++
                }
            }
            Update-ServerCount
            Save-ServerList
            Write-Log "AD query complete: found $($r.Servers.Count) servers, added $added new"
            Update-StatusBar "Added $added servers from Active Directory"
        } else {
            Write-Log "AD query failed: $($r.Error)" "ERROR"
            Update-StatusBar "AD query failed"
        }
    }.GetNewClosure()
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

    Start-ProgressBatch -Total $servers.Count
    Update-StatusBar "Scanning ALL $($servers.Count) server(s)..."

    foreach ($s in $servers) {
        Invoke-ScanServer -ServerName $s.ServerName
    }
})

# ── Sequential Install Logic ──────────────────────────────────────────────────
function Invoke-InstallServerSequential {
    param([string]$ServerName)

    if (-not (Ensure-Credential)) {
        $script:SequentialRunning = $false
        return
    }

    Update-ServerEntry -ServerName $ServerName -Properties @{
        Status  = "Installing..."
        Details = "Downloading and installing updates... (sequential)"
    }
    Write-Log "Installing updates on $ServerName (sequential mode)..."

    $cred = Get-ServerCredential -ServerName $ServerName
    Start-AsyncJob -ScriptBlock $script:RunAsSystemScript -Arguments @($ServerName, $cred, $script:InstallPayload, $script:InstallTimeout, 'Install') -OnComplete {
        param($result)
        $r = $result | Select-Object -First 1
        if ($r.Success) {
            $reboot = if ($r.RebootRequired) { "Yes" } else { "No" }
            $status = if ($r.RebootRequired) { "Reboot Required" }
                      elseif ($r.InstalledCount -gt 0) { "Up to date" }
                      else { "Up to date" }
            $details = $r.Message
            if ($r.FailedCount -gt 0) { $details += " ($($r.FailedCount) failed)" }

            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status         = $status
                Installed      = $r.InstalledCount.ToString()
                Available      = "0"
                RebootRequired = $reboot
                Details        = $details
            }
            Write-Log "$ServerName : $($r.Message)$(if($r.RebootRequired){' - reboot required'})"
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Install error: $($r.Error)"
            }
            Write-Log "$ServerName : Install failed - $($r.Error)" "ERROR"
        }

        Step-Progress

        # Process next in queue
        if ($script:SequentialQueue.Count -gt 0) {
            $next = $script:SequentialQueue.Dequeue()
            $remaining = $script:SequentialQueue.Count
            Update-StatusBar "Installing on $next... ($remaining remaining in queue)"
            Invoke-InstallServerSequential -ServerName $next
        } else {
            $script:SequentialRunning = $false
            Update-StatusBar "Sequential install complete"
            Show-Progress -Visible $false
            Write-Log "Sequential install queue completed"
        }
    }.GetNewClosure()
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
# ── Sequential Reboot Logic ───────────────────────────────────────────────────
$script:RebootQueue = [System.Collections.Generic.Queue[string]]::new()
$script:RebootQueueRunning = $false

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

            $monCred = Get-ServerCredential -ServerName $ServerName
            Start-AsyncJob -ScriptBlock $script:RebootMonitorScript -Arguments @($ServerName, $monCred, $r.BootBefore) -OnComplete {
                param($monResult)
                $m = $monResult | Select-Object -First 1
                $phase = $m.Phase
                if ($phase -eq "Online") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status         = "Back Online"
                        RebootRequired = "No"
                        Details        = "Server came back online at $(Get-Date -Format 'HH:mm:ss'). Re-scanning..."
                    }
                    Write-Log "$ServerName : Back online - starting post-reboot scan"
                    Invoke-ScanServer -ServerName $ServerName
                } elseif ($phase -eq "Timeout") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Offline"
                        Details = "Server did not respond after reboot. $($m.Error)"
                    }
                    Write-Log "$ServerName : Post-reboot timeout" "WARN"
                } elseif ($phase -eq "WinRMTimeout") {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Partially Online"
                        Details = "Server responds to ping but WinRM not ready. $($m.Error)"
                    }
                    Write-Log "$ServerName : Pingable but WinRM not ready" "WARN"
                } else {
                    Update-ServerEntry -ServerName $ServerName -Properties @{
                        Status  = "Error"
                        Details = "Post-reboot monitor error: $($m.Error)"
                    }
                    Write-Log "$ServerName : Monitor error - $($m.Error)" "ERROR"
                }

                # Process next in reboot queue
                if ($script:RebootQueue.Count -gt 0) {
                    $next = $script:RebootQueue.Dequeue()
                    $remaining = $script:RebootQueue.Count
                    Update-StatusBar "Rebooting $next... ($remaining remaining in queue)"
                    Write-Log "Sequential reboot: proceeding to $next"
                    Invoke-RebootServerSequential -ServerName $next
                } else {
                    $script:RebootQueueRunning = $false
                    Update-StatusBar "Sequential reboot complete"
                    Show-Progress -Visible $false
                    Write-Log "Sequential reboot queue completed"
                }
            }.GetNewClosure()
        } else {
            Update-ServerEntry -ServerName $ServerName -Properties @{
                Status  = "Error"
                Details = "Reboot failed: $($r.Error)"
            }
            Write-Log "$ServerName : Reboot failed - $($r.Error)" "ERROR"

            # Even on failure, proceed to next in queue
            if ($script:RebootQueue.Count -gt 0) {
                $next = $script:RebootQueue.Dequeue()
                $remaining = $script:RebootQueue.Count
                Update-StatusBar "Rebooting $next... ($remaining remaining in queue)"
                Write-Log "Sequential reboot: proceeding to $next (previous failed)"
                Invoke-RebootServerSequential -ServerName $next
            } else {
                $script:RebootQueueRunning = $false
                Update-StatusBar "Sequential reboot complete"
                Show-Progress -Visible $false
            }
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

                $monCred = Get-ServerCredential -ServerName $sn
                Start-AsyncJob -ScriptBlock $script:RebootMonitorScript -Arguments @($sn, $monCred, $r.BootBefore) -OnComplete {
                    param($monResult)
                    $m = $monResult | Select-Object -First 1
                    $phase = $m.Phase
                    if ($phase -eq "Online") {
                        Update-ServerEntry -ServerName $sn -Properties @{
                            Status         = "Back Online"
                            RebootRequired = "No"
                            Details        = "Server came back online at $(Get-Date -Format 'HH:mm:ss'). Re-scanning..."
                        }
                        Write-Log "$sn : Back online - starting post-reboot scan"
                        Invoke-ScanServer -ServerName $sn
                    } elseif ($phase -eq "Timeout") {
                        Update-ServerEntry -ServerName $sn -Properties @{
                            Status  = "Offline"
                            Details = "Server did not respond after reboot. $($m.Error)"
                        }
                        Write-Log "$sn : Post-reboot timeout" "WARN"
                    } elseif ($phase -eq "WinRMTimeout") {
                        Update-ServerEntry -ServerName $sn -Properties @{
                            Status  = "Partially Online"
                            Details = "Server responds to ping but WinRM not ready. $($m.Error)"
                        }
                        Write-Log "$sn : Pingable but WinRM not ready" "WARN"
                    } else {
                        Update-ServerEntry -ServerName $sn -Properties @{
                            Status  = "Error"
                            Details = "Post-reboot monitor error: $($m.Error)"
                        }
                        Write-Log "$sn : Monitor error - $($m.Error)" "ERROR"
                    }
                }.GetNewClosure()
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
    if ($toRemove -and $script:Credentials.ContainsKey($toRemove)) {
        $script:Credentials.Remove($toRemove)
        # Clear assignment from servers using this credential
        foreach ($s in $script:ServerData) {
            if ($s.CredentialLabel -eq $toRemove) {
                $s.CredentialLabel = $script:DefaultCredentialLabel
            }
        }
        if ($script:DefaultCredentialLabel -eq $toRemove) {
            $script:DefaultCredentialLabel = if ($script:Credentials.Count -gt 0) { @($script:Credentials.Keys)[0] } else { $null }
        }
        $ui.dgServers.Items.Refresh()
        Update-CredentialStatus
        Save-ServerList
        Write-Log "Removed credential: $toRemove"
    }
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

# Clear log
$ui.btnClearLog.Add_Click({
    $ui.txtLog.Clear()
})

# ── Cleanup on close ─────────────────────────────────────────────────────────
$window.Add_Closed({
    Save-ServerList
    $script:JobTimer.Stop()
    foreach ($job in $script:ActiveJobs) {
        try { $job.PowerShell.Stop(); $job.PowerShell.Dispose() } catch {}
    }
    if ($script:RunspacePool) { $script:RunspacePool.Dispose() }
})

# ── Load VisualBasic assembly for InputBox (AD browser) ──────────────────────
try { Add-Type -AssemblyName Microsoft.VisualBasic } catch {}

# ── Launch ────────────────────────────────────────────────────────────────────
Write-Log "Server Patch Tool started"
Write-Log "Please authenticate to begin managing servers"

# Load saved servers
Load-ServerList

# Prompt for credentials on startup
$window.Add_ContentRendered({
    $result = Add-CredentialSet -Message "Enter primary credentials for server management (domain\username)`nYou can add more credentials later for other domains."
    if (-not $result) {
        Write-Log "No credentials provided. Add credentials via the 'Add Credential' button." "WARN"
    }
})

$window.ShowDialog() | Out-Null
