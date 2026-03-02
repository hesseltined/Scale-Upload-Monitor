<#
.SYNOPSIS
    Monitors Scale Computing Virtual Disk upload progress via REST API and sends SMTP email notifications.
.PARAMETER Test
    If specified, sends a test email using the configured SMTP settings and then exits.
#>

param (
    [switch]$Test
)

# ---------------------------------------------------------
# CONFIG: Persist IP, Cluster Credentials, SMTP Settings, and Notification Interval
# ---------------------------------------------------------
if ($PSScriptRoot) { $scriptDir = $PSScriptRoot } else { $scriptDir = (Get-Location).Path }

# Primary config file is named after this script (Scale-Upload-Monitor)
$configPath     = Join-Path $scriptDir 'Scale-Upload-Monitor.config.json'
# Backward-compat: read older config name once if the new file does not exist
$oldConfigPath  = Join-Path $scriptDir 'Scale-Monitor-Uploads.config.json'

# Load Saved Settings (with try/catch for corrupted JSON)
$SavedSettings = $null
$configToLoad = $null
if (Test-Path $configPath) {
    $configToLoad = $configPath
} elseif (Test-Path $oldConfigPath) {
    $configToLoad = $oldConfigPath
}

if ($configToLoad) {
    try {
        $SavedSettings = Get-Content -Path $configToLoad -Raw | ConvertFrom-Json
    } catch {
        $SavedSettings = $null
    }
}

# ---------------------------------------------------------
# WPF CONFIGURATION WINDOW
# Collects all inputs in a single, resizable window instead of many popups.
# ---------------------------------------------------------
function Show-ScaleMonitorConfigWindow {
    param (
        [Parameter()]$SavedSettings
    )

    Add-Type -AssemblyName PresentationCore,PresentationFramework

    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scale Upload Monitor Configuration"
        Height="520" Width="720"
        SizeToContent="Manual"
        ResizeMode="CanResize">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>

    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="0,0,0,10">
        <TextBlock Text="Scale Upload Monitor Settings" FontSize="18" FontWeight="Bold" Margin="0,0,0,10" />
        <TextBlock Text="Enter connection, email, SMTP, and notification settings below. These will be saved so you don't have to re-enter them each time." TextWrapping="Wrap" Margin="0,0,0,12" />

        <!-- Cluster settings -->
        <GroupBox Header="Scale Cluster" Margin="0,0,0,10">
          <StackPanel Margin="8">
            <TextBlock Text="Cluster IP or hostname:" />
            <TextBox Name="ClusterIpBox" Margin="0,0,0,8" />

            <TextBlock Text="Cluster username:" />
            <TextBox Name="ClusterUserBox" Margin="0,0,0,8" />

            <TextBlock Text="Cluster password:" />
            <PasswordBox Name="ClusterPasswordBox" Margin="0,0,0,8" />
          </StackPanel>
        </GroupBox>

        <!-- Email / SMTP settings -->
        <GroupBox Header="Email / SMTP Settings" Margin="0,0,0,10">
          <StackPanel Margin="8">
            <TextBlock Text="Sender email address (must be valid for your SMTP account):" />
            <TextBox Name="EmailFromBox" Margin="0,0,0,8" />

            <TextBlock Text="Recipient email address for alerts:" />
            <TextBox Name="EmailToBox" Margin="0,0,0,8" />

            <TextBlock Text="SMTP server hostname (e.g. smtp.example.com):" />
            <TextBox Name="SmtpServerBox" Margin="0,0,0,8" />

            <TextBlock Text="SMTP port (e.g. 587):" />
            <TextBox Name="SmtpPortBox" Margin="0,0,0,8" Width="100" />

            <CheckBox Name="SmtpUseSslCheck" Content="Use SSL/TLS" IsChecked="True" Margin="0,0,0,8" />

            <TextBlock Text="SMTP username (often the same as sender address):" />
            <TextBox Name="SmtpUserBox" Margin="0,0,0,8" />

            <TextBlock Text="SMTP password:" />
            <PasswordBox Name="SmtpPasswordBox" Margin="0,0,0,8" />
          </StackPanel>
        </GroupBox>

        <!-- Notification settings -->
        <GroupBox Header="Notification Interval" Margin="0,0,0,10">
          <StackPanel Margin="8">
            <TextBlock Text="Notification interval in GB:" />
            <TextBlock Text="Example: 10 = send a progress email at 10, 20, 30 GB, etc., regardless of when this script was started." TextWrapping="Wrap" Margin="0,0,0,4" />
            <TextBox Name="NotificationIntervalBox" Margin="0,0,0,8" Width="100" />
          </StackPanel>
        </GroupBox>

        <TextBlock Name="ErrorText" Foreground="Red" Margin="0,4,0,0" TextWrapping="Wrap" />
      </StackPanel>
    </ScrollViewer>

    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button Name="StartButton" Content="Start Monitoring" Width="140" Margin="0,0,8,0" IsDefault="True" />
      <Button Name="CancelButton" Content="Cancel" Width="80" IsCancel="True" />
    </StackPanel>
  </Grid>
</Window>
'@

    [xml]$xamlXml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $xamlXml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # Grab controls
    $clusterIpBox        = $window.FindName("ClusterIpBox")
    $clusterUserBox      = $window.FindName("ClusterUserBox")
    $clusterPasswordBox  = $window.FindName("ClusterPasswordBox")
    $emailFromBox        = $window.FindName("EmailFromBox")
    $emailToBox          = $window.FindName("EmailToBox")
    $smtpServerBox       = $window.FindName("SmtpServerBox")
    $smtpPortBox         = $window.FindName("SmtpPortBox")
    $smtpUseSslCheck     = $window.FindName("SmtpUseSslCheck")
    $smtpUserBox         = $window.FindName("SmtpUserBox")
    $smtpPasswordBox     = $window.FindName("SmtpPasswordBox")
    $notificationBox     = $window.FindName("NotificationIntervalBox")
    $errorTextBlock      = $window.FindName("ErrorText")
    $startButton         = $window.FindName("StartButton")
    $cancelButton        = $window.FindName("CancelButton")

    # Pre-populate from saved settings if available
    if ($SavedSettings) {
        if ($SavedSettings.TargetIP)           { $clusterIpBox.Text        = $SavedSettings.TargetIP }
        if ($SavedSettings.Username)           { $clusterUserBox.Text      = $SavedSettings.Username }
        if ($SavedSettings.EmailFrom)          { $emailFromBox.Text        = $SavedSettings.EmailFrom }
        if ($SavedSettings.EmailTo)            { $emailToBox.Text          = $SavedSettings.EmailTo }
        if ($SavedSettings.SmtpServer)         { $smtpServerBox.Text       = $SavedSettings.SmtpServer }
        if ($SavedSettings.SmtpPort)           { $smtpPortBox.Text         = [string]$SavedSettings.SmtpPort }
        if ($SavedSettings.SmtpUseSsl -ne $null) { $smtpUseSslCheck.IsChecked = [bool]$SavedSettings.SmtpUseSsl }
        if ($SavedSettings.SmtpUsername)       { $smtpUserBox.Text         = $SavedSettings.SmtpUsername }
        if ($SavedSettings.NotificationGbInterval) { $notificationBox.Text = [string]$SavedSettings.NotificationGbInterval }
    }

    # Provide sensible defaults if boxes are empty
    if (-not $smtpPortBox.Text)       { $smtpPortBox.Text = "587" }
    if (-not $notificationBox.Text)   { $notificationBox.Text = "10" }

    $script:ConfigResult = $null

    $startHandler = {
        $errorTextBlock.Text = ""

        $ip   = $clusterIpBox.Text.Trim()
        $user = $clusterUserBox.Text.Trim()
        $cPwd = $clusterPasswordBox.Password
        $from = $emailFromBox.Text.Trim()
        $to   = $emailToBox.Text.Trim()
        $sSrv = $smtpServerBox.Text.Trim()
        $sPortText = $smtpPortBox.Text.Trim()
        $sUser = $smtpUserBox.Text.Trim()
        $sPwd  = $smtpPasswordBox.Password
        $notifText = $notificationBox.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($ip))   { $errorTextBlock.Text = "Cluster IP/hostname is required."; return }
        if ([string]::IsNullOrWhiteSpace($user)) { $errorTextBlock.Text = "Cluster username is required."; return }
        if ([string]::IsNullOrWhiteSpace($cPwd)) { $errorTextBlock.Text = "Cluster password is required."; return }
        if ([string]::IsNullOrWhiteSpace($from)) { $errorTextBlock.Text = "Sender email address is required."; return }
        if ([string]::IsNullOrWhiteSpace($to))   { $errorTextBlock.Text = "Recipient email address is required."; return }
        if ([string]::IsNullOrWhiteSpace($sSrv)) { $errorTextBlock.Text = "SMTP server hostname is required."; return }
        if ([string]::IsNullOrWhiteSpace($sUser)){ $errorTextBlock.Text = "SMTP username is required."; return }
        if ([string]::IsNullOrWhiteSpace($sPwd)) { $errorTextBlock.Text = "SMTP password is required."; return }

        $portVal = 0
        if (-not [int]::TryParse($sPortText, [ref]$portVal) -or $portVal -le 0) {
            $errorTextBlock.Text = "SMTP port must be a positive number (e.g. 587)."
            return
        }

        $notifVal = 0
        if (-not [int]::TryParse($notifText, [ref]$notifVal) -or $notifVal -le 0) {
            $notifVal = 10
        }

        $clusterSecure = $cPwd | ConvertTo-SecureString -AsPlainText -Force
        $clusterCred   = New-Object System.Management.Automation.PSCredential($user, $clusterSecure)

        $smtpSecure    = $sPwd | ConvertTo-SecureString -AsPlainText -Force

        $script:ConfigResult = [pscustomobject]@{
            TargetIP               = $ip
            ClusterCredential      = $clusterCred
            EmailFrom              = $from
            EmailTo                = $to
            SmtpServer             = $sSrv
            SmtpPort               = $portVal
            SmtpUseSsl             = [bool]$smtpUseSslCheck.IsChecked
            SmtpUsername           = $sUser
            SmtpPassword           = $smtpSecure
            NotificationGbInterval = $notifVal
        }

        $window.DialogResult = $true
        $window.Close()
    }

    $null = $startButton.Add_Click($startHandler)

    # Simple handler for cancel
    $null = $cancelButton.Add_Click({
        $window.DialogResult = $false
        $window.Close()
    })

    # Show dialog modally
    $null = $window.ShowDialog()
    return $script:ConfigResult
}

# Show WPF window to collect / edit configuration
$config = Show-ScaleMonitorConfigWindow -SavedSettings $SavedSettings
if (-not $config) {
    Write-Host "Configuration cancelled. Exiting." -ForegroundColor Yellow
    exit 1
}

# Extract config values into variables used by the rest of the script
$targetIP              = $config.TargetIP
$clusterCred           = $config.ClusterCredential
$emailFrom             = $config.EmailFrom
$emailTo               = $config.EmailTo
$smtpServer            = $config.SmtpServer
$smtpPort              = $config.SmtpPort
$smtpUseSsl            = $config.SmtpUseSsl
$smtpUser              = $config.SmtpUsername
$smtpPassword          = $config.SmtpPassword
$notificationGbInterval = $config.NotificationGbInterval
if ($notificationGbInterval -le 0) { $notificationGbInterval = 10 }

# Save Settings to JSON
$settingsToSave = [pscustomobject]@{
    TargetIP               = $targetIP
    Username               = $clusterCred.UserName
    PasswordEnc            = $clusterCred.Password | ConvertFrom-SecureString
    EmailFrom              = $emailFrom
    EmailTo                = $emailTo
    SmtpServer             = $smtpServer
    SmtpPort               = $smtpPort
    SmtpUseSsl             = $smtpUseSsl
    SmtpUsername           = $smtpUser
    SmtpPasswordEnc        = $smtpPassword | ConvertFrom-SecureString
    NotificationGbInterval = $notificationGbInterval
}
$settingsToSave | ConvertTo-Json | Set-Content -Path $configPath

# ---------------------------------------------------------
# EMAIL FUNCTION (generic SMTP provider via Send-MailMessage)
# ---------------------------------------------------------
function Send-SmtpNotification {
    param([string]$Subject, [string]$Body)

    if ($null -eq $smtpPassword -or [string]::IsNullOrWhiteSpace($smtpServer)) {
        Write-Host "[Email Error] SMTP settings are incomplete. Cannot send notification." -ForegroundColor Red
        return
    }

    try {
        $creds = New-Object System.Management.Automation.PSCredential($smtpUser, $smtpPassword)

        Send-MailMessage -From $emailFrom `
                         -To $emailTo `
                         -Subject $Subject `
                         -Body $Body `
                         -SmtpServer $smtpServer `
                         -Port $smtpPort `
                         -UseSsl:$smtpUseSsl `
                         -Credential $creds `
                         -ErrorAction Stop

        Write-Host "[Email Sent] $Subject" -ForegroundColor Green
    } catch {
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails.Message) { $errMsg = $_.ErrorDetails.Message }
        Write-Host "[Email Failed] $errMsg" -ForegroundColor Red
    }
}

# ---------------------------------------------------------
# TEST MODE LOGIC
# ---------------------------------------------------------
if ($Test) {
    Write-Host "--- TEST MODE ENABLED ---" -ForegroundColor Cyan
    Write-Host "Sending test email to $emailTo..." -ForegroundColor Gray
    Send-SmtpNotification -Subject "SMTP Test Notification" -Body "This is a test email from your Scale Upload Monitor script. If you received this, your SMTP settings are correct!`n`nTimestamp: $(Get-Date)"
    Write-Host "Test complete. Exiting." -ForegroundColor Cyan
    exit
}

# ---------------------------------------------------------
# MONITORING TRACKING LOGIC
# ---------------------------------------------------------
$DiskStats = @{}
$script:NextProgressId = 1
$script:UuidToProgressId = @{} 

# SSL Bypass for Scale Cluster
if (-not ("TrustAllCertsPolicy" -as [type])) {
    add-type "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $clusterCred.UserName, $clusterCred.GetNetworkCredential().Password)))
$headers = @{Authorization=("Basic {0}" -f $base64AuthInfo)}
$url = "https://$targetIP/rest/v1/VirtualDisk"

Clear-Host
Write-Host "Monitoring $targetIP..." -ForegroundColor Cyan
Write-Host "Notifications: Every $notificationGbInterval GB or 2 minute stall." -ForegroundColor Gray
Write-Host "Run with -Test to verify email settings." -ForegroundColor DarkGray

while ($true) {
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
        $diskList = if ($response.data) { $response.data } else { $response }
        $activityDisks = $diskList | Where-Object { $_.name -match "uploading|convert" }

        if ($activityDisks) {
            foreach ($disk in $activityDisks) {
                $uuid = $disk.uuid
                $name = $disk.name
                $currentBytes = [double]$disk.totalAllocationBytes
                $totalBytes   = [double]$disk.capacityBytes
                $currentGB    = [math]::Floor($currentBytes / 1GB)
                $now          = Get-Date

                if (-not $script:UuidToProgressId.ContainsKey($uuid)) {
                    $script:UuidToProgressId[$uuid] = $script:NextProgressId++
                }
                $progressId = $script:UuidToProgressId[$uuid]

                if (-not $DiskStats.ContainsKey($uuid)) {
                    $DiskStats[$uuid] = [pscustomobject]@{
                        InitialBytes     = $currentBytes
                        InitialTime      = $now
                        NextGBThreshold  = [int]([math]::Ceiling([double]$currentGB / $notificationGbInterval) * $notificationGbInterval)
                        LastBytes        = $currentBytes
                        LastChangeTime   = $now
                        StallAlertSent   = $false
                    }
                    Send-SmtpNotification -Subject "Upload Started: $name" -Body "Script started monitoring $name. Current progress: $currentGB GB."
                }

                $stats = $DiskStats[$uuid]

                # Send progress emails at fixed GB boundaries from 0 (e.g. 10, 20, 30, ...),
                # regardless of when this script was started.
                if ($totalBytes -gt 0 -and $currentGB -ge $stats.NextGBThreshold) {
                    $totalGB = [math]::Round($totalBytes / 1GB, 2)
                    Send-SmtpNotification -Subject "Progress Update: $name" -Body "Disk $name has reached $currentGB GB of $totalGB GB."
                    $stats.NextGBThreshold += $notificationGbInterval
                }

                if ($currentBytes -gt $stats.LastBytes) {
                    $stats.LastBytes = $currentBytes
                    $stats.LastChangeTime = $now
                    $stats.StallAlertSent = $false
                } else {
                    $timeSinceChange = ($now - $stats.LastChangeTime).TotalMinutes
                    if ($timeSinceChange -ge 2 -and -not $stats.StallAlertSent) {
                        Send-SmtpNotification -Subject "STALL ALERT: $name" -Body "Disk $name has not progressed for over 2 minutes. Current position: $currentGB GB."
                        $stats.StallAlertSent = $true
                    }
                }

                # Compute percent and a simple ETA based on average bytes/second since monitoring started.
                $percent = if ($totalBytes -gt 0) { [math]::Min(100, [math]::Round(($currentBytes / $totalBytes) * 100, 1)) } else { 0 }
                $totalGB = if ($totalBytes -gt 0) { [math]::Round($totalBytes / 1GB, 2) } else { 0 }

                $etaText = $null
                if ($totalBytes -gt 0 -and $currentBytes -gt $stats.InitialBytes) {
                    $elapsedSec = ($now - $stats.InitialTime).TotalSeconds
                    if ($elapsedSec -gt 0) {
                        $bytesDone     = $currentBytes - $stats.InitialBytes
                        $bytesPerSec   = $bytesDone / $elapsedSec
                        if ($bytesPerSec -gt 0) {
                            $remainingBytes = $totalBytes - $currentBytes
                            if ($remainingBytes -gt 0) {
                                $etaSec = [math]::Round($remainingBytes / $bytesPerSec)
                                $ts = [TimeSpan]::FromSeconds($etaSec)
                                if ($ts.TotalHours -ge 1) {
                                    $etaText = "ETA ~{0:hh\:mm} remaining" -f $ts
                                } else {
                                    $etaText = "ETA ~{0:mm\:ss} remaining" -f $ts
                                }
                            }
                        }
                    }
                }

                $statusBase = "$currentGB GB / $totalGB GB ($percent%)"
                $status = if ($etaText) { "$statusBase - $etaText" } else { $statusBase }

                Write-Progress -Id $progressId -Activity "Monitoring: $name" -Status $status -PercentComplete $percent
            }
        }
        else {
            foreach ($id in $script:UuidToProgressId.Values) {
                Write-Progress -Id $id -Activity "Monitoring Scale Uploads" -Completed
            }
            $script:UuidToProgressId = @{}
            Write-Progress -Activity "Monitoring Scale Uploads" -Status "No active uploads or conversions found..." -Completed
        }
    }
    catch {
        Write-Host "Error connecting to Scale API: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    Start-Sleep -Seconds 5
}