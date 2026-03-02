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
            <PasswordBox Name="ClusterPasswordBox" Margin="0,0,0,4" />
            <TextBlock Name="ClusterPasswordHint" Foreground="Gray" FontStyle="Italic" Margin="0,0,0,8" />
          </StackPanel>
        </GroupBox>

        <!-- Email provider selection -->
        <GroupBox Header="Email Provider" Margin="0,0,0,10">
          <StackPanel Margin="8">
            <TextBlock Text="Choose a common provider to auto-fill typical SMTP settings, or select Generic to enter everything manually." TextWrapping="Wrap" Margin="0,0,0,8" />
            <StackPanel Orientation="Horizontal">
              <RadioButton Name="ProviderGenericRadio" Content="Generic" Margin="0,0,10,0" IsChecked="True" />
              <RadioButton Name="ProviderOffice365Radio" Content="Office 365" Margin="0,0,10,0" />
              <RadioButton Name="ProviderGmailRadio" Content="Gmail" Margin="0,0,10,0" />
              <RadioButton Name="ProviderZohoRadio" Content="Zoho" Margin="0,0,10,0" />
              <RadioButton Name="ProviderSmtp2GoRadio" Content="SMTP2GO" />
            </StackPanel>
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
            <PasswordBox Name="SmtpPasswordBox" Margin="0,0,0,4" />
            <TextBlock Name="SmtpPasswordHint" Foreground="Gray" FontStyle="Italic" Margin="0,0,0,8" />

            <TextBlock Text="For SMTP2GO you can alternatively use an API key instead of SMTP username/password. If an API key is entered, the password field will be ignored for sending via the API." TextWrapping="Wrap" Margin="0,4,0,4" />
            <TextBlock Text="SMTP2GO API key (only used when provider is SMTP2GO):" />
            <PasswordBox Name="Smtp2GoApiKeyBox" Margin="0,0,0,4" />
            <TextBlock Name="Smtp2GoApiKeyHint" Foreground="Gray" FontStyle="Italic" Margin="0,0,0,8" />
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
      <Button Name="TestEmailButton" Content="Test Email" Width="110" Margin="0,0,8,0" />
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
    $providerGenericRadio = $window.FindName("ProviderGenericRadio")
    $providerOffice365Radio = $window.FindName("ProviderOffice365Radio")
    $providerGmailRadio = $window.FindName("ProviderGmailRadio")
    $providerZohoRadio = $window.FindName("ProviderZohoRadio")
    $providerSmtp2GoRadio = $window.FindName("ProviderSmtp2GoRadio")
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
    $smtp2GoApiKeyBox    = $window.FindName("Smtp2GoApiKeyBox")
    $clusterPasswordHint = $window.FindName("ClusterPasswordHint")
    $smtpPasswordHint   = $window.FindName("SmtpPasswordHint")
    $smtp2GoApiKeyHint   = $window.FindName("Smtp2GoApiKeyHint")
    $notificationBox     = $window.FindName("NotificationIntervalBox")
    $errorTextBlock      = $window.FindName("ErrorText")
    $testEmailButton     = $window.FindName("TestEmailButton")
    $startButton         = $window.FindName("StartButton")
    $cancelButton        = $window.FindName("CancelButton")

    # Helper to determine provider name based on selected radio
    $getProviderName = {
        if ($providerOffice365Radio.IsChecked) { return "Office365" }
        if ($providerGmailRadio.IsChecked)     { return "Gmail" }
        if ($providerZohoRadio.IsChecked)      { return "Zoho" }
        if ($providerSmtp2GoRadio.IsChecked)   { return "SMTP2GO" }
        return "Generic"
    }

    # Helper to apply reasonable defaults when switching providers (only if fields are empty)
    $updateProviderDefaults = {
        $prov = & $getProviderName
        switch ($prov) {
            "Office365" {
                if (-not $smtpServerBox.Text) { $smtpServerBox.Text = "smtp.office365.com" }
                if (-not $smtpPortBox.Text)   { $smtpPortBox.Text   = "587" }
                $smtpUseSslCheck.IsChecked = $true
            }
            "Gmail" {
                if (-not $smtpServerBox.Text) { $smtpServerBox.Text = "smtp.gmail.com" }
                if (-not $smtpPortBox.Text)   { $smtpPortBox.Text   = "587" }
                $smtpUseSslCheck.IsChecked = $true
            }
            "Zoho" {
                if (-not $smtpServerBox.Text) { $smtpServerBox.Text = "smtp.zoho.com" }
                if (-not $smtpPortBox.Text)   { $smtpPortBox.Text   = "587" }
                $smtpUseSslCheck.IsChecked = $true
            }
            "SMTP2GO" {
                if (-not $smtpServerBox.Text) { $smtpServerBox.Text = "mail.smtp2go.com" }
                if (-not $smtpPortBox.Text)   { $smtpPortBox.Text   = "2525" }
                $smtpUseSslCheck.IsChecked = $true
            }
            default { }
        }
    }

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
        if ($SavedSettings.EmailProvider) {
            switch ($SavedSettings.EmailProvider) {
                "Office365" { $providerOffice365Radio.IsChecked = $true }
                "Gmail"     { $providerGmailRadio.IsChecked     = $true }
                "Zoho"      { $providerZohoRadio.IsChecked      = $true }
                "SMTP2GO"   { $providerSmtp2GoRadio.IsChecked   = $true }
                default     { $providerGenericRadio.IsChecked   = $true }
            }
        } else {
            $providerGenericRadio.IsChecked = $true
        }

        # Show "(saved - leave blank to use)" when we have encrypted values so user knows they need not re-enter
        if ($SavedSettings.PasswordEnc)          { $clusterPasswordHint.Text = "(saved - leave blank to use)" }
        if ($SavedSettings.SmtpPasswordEnc)     { $smtpPasswordHint.Text    = "(saved - leave blank to use)" }
        if ($SavedSettings.Smtp2GoApiKeyEnc)    { $smtp2GoApiKeyHint.Text   = "(saved - leave blank to use)" }
    }

    # Provide sensible defaults if boxes are empty
    if (-not $smtpPortBox.Text)       { $smtpPortBox.Text = "587" }
    if (-not $notificationBox.Text)   { $notificationBox.Text = "10" }
    & $updateProviderDefaults

    # Hook provider selection changes to update defaults
    $null = $providerGenericRadio.Add_Checked({ & $updateProviderDefaults })
    $null = $providerOffice365Radio.Add_Checked({ & $updateProviderDefaults })
    $null = $providerGmailRadio.Add_Checked({ & $updateProviderDefaults })
    $null = $providerZohoRadio.Add_Checked({ & $updateProviderDefaults })
    $null = $providerSmtp2GoRadio.Add_Checked({ & $updateProviderDefaults })

    $script:ConfigResult = $null

    $startHandler = {
        $errorTextBlock.Text = ""
        $errorTextBlock.Foreground = 'Red'

        $provider = & $getProviderName
        $ip   = $clusterIpBox.Text.Trim()
        $user = $clusterUserBox.Text.Trim()
        $cPwd = $clusterPasswordBox.Password
        $from = $emailFromBox.Text.Trim()
        $to   = $emailToBox.Text.Trim()
        $sSrv = $smtpServerBox.Text.Trim()
        $sPortText = $smtpPortBox.Text.Trim()
        $sUser = $smtpUserBox.Text.Trim()
        $sPwd  = $smtpPasswordBox.Password
        $apiKeyPlain = $smtp2GoApiKeyBox.Password
        $notifText = $notificationBox.Text.Trim()

        if ([string]::IsNullOrWhiteSpace($ip))   { $errorTextBlock.Text = "Cluster IP/hostname is required."; return }
        if ([string]::IsNullOrWhiteSpace($user)) { $errorTextBlock.Text = "Cluster username is required."; return }
        if ([string]::IsNullOrWhiteSpace($from)) { $errorTextBlock.Text = "Sender email address is required."; return }
        if ([string]::IsNullOrWhiteSpace($to))   { $errorTextBlock.Text = "Recipient email address is required."; return }
        if ([string]::IsNullOrWhiteSpace($sSrv)) { $errorTextBlock.Text = "SMTP server hostname is required."; return }
        if ([string]::IsNullOrWhiteSpace($sUser)){ $errorTextBlock.Text = "SMTP username is required."; return }

        # Cluster password: required unless we have a saved encrypted value (leave field blank to use saved)
        $hasSavedClusterPwd = $SavedSettings.PasswordEnc -and -not [string]::IsNullOrWhiteSpace($SavedSettings.PasswordEnc)
        if ([string]::IsNullOrWhiteSpace($cPwd) -and -not $hasSavedClusterPwd) {
            $errorTextBlock.Text = "Cluster password is required (enter once; it will be saved encrypted for next run)."
            return
        }

        # SMTP / SMTP2GO: need password or (for SMTP2GO) API key; blank is OK if we have saved value
        $hasSavedSmtpPwd   = $SavedSettings.SmtpPasswordEnc -and -not [string]::IsNullOrWhiteSpace($SavedSettings.SmtpPasswordEnc)
        $hasSavedSmtp2GoKey = $SavedSettings.Smtp2GoApiKeyEnc -and -not [string]::IsNullOrWhiteSpace($SavedSettings.Smtp2GoApiKeyEnc)
        if ($provider -eq "SMTP2GO") {
            if ([string]::IsNullOrWhiteSpace($sPwd) -and [string]::IsNullOrWhiteSpace($apiKeyPlain) -and -not $hasSavedSmtpPwd -and -not $hasSavedSmtp2GoKey) {
                $errorTextBlock.Text = "For SMTP2GO, enter either an SMTP password or an API key (or leave blank if already saved)."
                return
            }
        } else {
            if ([string]::IsNullOrWhiteSpace($sPwd) -and -not $hasSavedSmtpPwd) {
                $errorTextBlock.Text = "SMTP password is required (enter once; it will be saved encrypted for next run)."
                return
            }
        }

        $portVal = 0
        if (-not [int]::TryParse($sPortText, [ref]$portVal) -or $portVal -le 0) {
            $errorTextBlock.Text = "SMTP port must be a positive number (e.g. 587)."
            return
        }

        $notifVal = 0
        if (-not [int]::TryParse($notifText, [ref]$notifVal) -or $notifVal -le 0) {
            $notifVal = 10
        }

        # Cluster credential: use entered password or decrypt saved
        $clusterSecure = $null
        $saveClusterEnc = $null
        if (-not [string]::IsNullOrWhiteSpace($cPwd)) {
            $clusterSecure = $cPwd | ConvertTo-SecureString -AsPlainText -Force
            $saveClusterEnc = $clusterSecure | ConvertFrom-SecureString
        } else {
            try {
                $clusterSecure = ConvertTo-SecureString $SavedSettings.PasswordEnc -ErrorAction Stop
                $saveClusterEnc = $SavedSettings.PasswordEnc
            } catch {
                $errorTextBlock.Text = "Could not use saved cluster password. Please re-enter it."
                return
            }
        }
        $clusterCred = New-Object System.Management.Automation.PSCredential($user, $clusterSecure)

        # SMTP password: use entered or decrypt saved; track what to save to JSON
        $smtpSecure = $null
        $saveSmtpEnc = $null
        if (-not [string]::IsNullOrWhiteSpace($sPwd)) {
            $smtpSecure = $sPwd | ConvertTo-SecureString -AsPlainText -Force
            $saveSmtpEnc = $smtpSecure | ConvertFrom-SecureString
        } elseif ($hasSavedSmtpPwd) {
            try {
                $smtpSecure = ConvertTo-SecureString $SavedSettings.SmtpPasswordEnc -ErrorAction Stop
                $saveSmtpEnc = $SavedSettings.SmtpPasswordEnc
            } catch {
                $smtpSecure = $null
                $saveSmtpEnc = $null
            }
        }

        # SMTP2GO API key: use entered or decrypt saved; track what to save to JSON
        $smtp2GoSecure = $null
        $saveSmtp2GoEnc = $null
        if ($provider -eq "SMTP2GO") {
            if (-not [string]::IsNullOrWhiteSpace($apiKeyPlain)) {
                $smtp2GoSecure = $apiKeyPlain | ConvertTo-SecureString -AsPlainText -Force
                $saveSmtp2GoEnc = $smtp2GoSecure | ConvertFrom-SecureString
            } elseif ($hasSavedSmtp2GoKey) {
                try {
                    $smtp2GoSecure = ConvertTo-SecureString $SavedSettings.Smtp2GoApiKeyEnc -ErrorAction Stop
                    $saveSmtp2GoEnc = $SavedSettings.Smtp2GoApiKeyEnc
                } catch {
                    $smtp2GoSecure = $null
                    $saveSmtp2GoEnc = $null
                }
            }
        }

        # Test cluster login before saving and starting monitoring
        try {
            if (-not ("TrustAllCertsPolicy" -as [type])) {
                add-type "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
            }
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

            $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $clusterCred.UserName, $clusterCred.GetNetworkCredential().Password)))
            $headers = @{ Authorization = ("Basic {0}" -f $base64AuthInfo) }
            $testUrl = "https://$ip/rest/v1/VirtualDisk"

            Invoke-RestMethod -Uri $testUrl -Method Get -Headers $headers -ErrorAction Stop | Out-Null
        } catch {
            $errorTextBlock.Text = "Cluster login test failed: $($_.Exception.Message)"
            return
        }

        $script:ConfigResult = [pscustomobject]@{
            TargetIP               = $ip
            EmailProvider          = $provider
            ClusterCredential      = $clusterCred
            ClusterPasswordEnc     = $saveClusterEnc
            EmailFrom              = $from
            EmailTo                = $to
            SmtpServer             = $sSrv
            SmtpPort               = $portVal
            SmtpUseSsl             = [bool]$smtpUseSslCheck.IsChecked
            SmtpUsername           = $sUser
            SmtpPassword           = $smtpSecure
            SmtpPasswordEnc        = $saveSmtpEnc
            Smtp2GoApiKey          = $smtp2GoSecure
            Smtp2GoApiKeyEnc       = $saveSmtp2GoEnc
            NotificationGbInterval = $notifVal
        }

        $window.DialogResult = $true
        $window.Close()
    }

    $null = $startButton.Add_Click($startHandler)

    # Test email handler: allows verifying SMTP / API settings before starting monitoring
    $testHandler = {
        $errorTextBlock.Text = ""

        $provider = & $getProviderName
        $from = $emailFromBox.Text.Trim()
        $to   = $emailToBox.Text.Trim()
        $sSrv = $smtpServerBox.Text.Trim()
        $sPortText = $smtpPortBox.Text.Trim()
        $sUser = $smtpUserBox.Text.Trim()
        $sPwd  = $smtpPasswordBox.Password
        $apiKeyPlain = $smtp2GoApiKeyBox.Password

        if ([string]::IsNullOrWhiteSpace($from)) { $errorTextBlock.Text = "Sender email address is required for test email."; return }
        if ([string]::IsNullOrWhiteSpace($to))   { $errorTextBlock.Text = "Recipient email address is required for test email."; return }
        if ([string]::IsNullOrWhiteSpace($sSrv)) { $errorTextBlock.Text = "SMTP server hostname is required for test email."; return }

        $portVal = 0
        if (-not [int]::TryParse($sPortText, [ref]$portVal) -or $portVal -le 0) {
            $errorTextBlock.Text = "SMTP port must be a positive number (e.g. 587)."
            return
        }

        # Use API if SMTP2GO and we have key (entered or saved)
        $apiKeyToUse = $apiKeyPlain
        if ([string]::IsNullOrWhiteSpace($apiKeyToUse) -and $SavedSettings.Smtp2GoApiKeyEnc) {
            try {
                $ss = ConvertTo-SecureString $SavedSettings.Smtp2GoApiKeyEnc -ErrorAction Stop
                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
                try { $apiKeyToUse = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) } finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            } catch { $apiKeyToUse = $null }
        }
        $useApi = ($provider -eq "SMTP2GO" -and -not [string]::IsNullOrWhiteSpace($apiKeyToUse))

        try {
            if ($useApi) {
                $headers = @{
                    "Content-Type"      = "application/json"
                    "X-Smtp2go-Api-Key" = $apiKeyToUse
                }
                $bodyObj = @{
                    sender    = $from
                    to        = @($to)
                    subject   = "SMTP2GO API Test from Scale Upload Monitor"
                    text_body = "This is a test email sent via the SMTP2GO API from the Scale Upload Monitor configuration window.`n`nTimestamp: $(Get-Date)"
                } | ConvertTo-Json

                $response = Invoke-RestMethod -Uri "https://api.smtp2go.com/v3/email/send" -Method Post -Headers $headers -Body $bodyObj -ErrorAction Stop
                if ($response.data.succeeded -ne 1 -and -not $response.data.email_id) {
                    $msg = if ($response.data.error) { $response.data.error } else { "Unknown SMTP2GO API response" }
                    throw "SMTP2GO API error: $msg"
                }
            } else {
                if ([string]::IsNullOrWhiteSpace($sUser)) { throw "SMTP username is required for test email." }
                $smtpSecureForTest = $null
                if (-not [string]::IsNullOrWhiteSpace($sPwd)) {
                    $smtpSecureForTest = $sPwd | ConvertTo-SecureString -AsPlainText -Force
                } elseif ($SavedSettings.SmtpPasswordEnc) {
                    try { $smtpSecureForTest = ConvertTo-SecureString $SavedSettings.SmtpPasswordEnc -ErrorAction Stop } catch { throw "Saved SMTP password could not be used. Re-enter password." }
                }
                if (-not $smtpSecureForTest) { throw "SMTP password is required for test email (or leave blank if already saved)." }

                $creds = New-Object System.Management.Automation.PSCredential($sUser, $smtpSecureForTest)

                Send-MailMessage -From $from `
                                 -To $to `
                                 -Subject "SMTP Test from Scale Upload Monitor" `
                                 -Body "This is a test email sent via SMTP from the Scale Upload Monitor configuration window.`n`nTimestamp: $(Get-Date)" `
                                 -SmtpServer $sSrv `
                                 -Port $portVal `
                                 -UseSsl:$smtpUseSslCheck.IsChecked `
                                 -Credential $creds `
                                 -ErrorAction Stop
            }
            $errorTextBlock.Foreground = 'Green'
            $errorTextBlock.Text = "Test email sent successfully."
        } catch {
            $errorTextBlock.Foreground = 'Red'
            $errorTextBlock.Text = "Test email failed: $($_.Exception.Message)"
        }
    }

    $null = $testEmailButton.Add_Click($testHandler)

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
$emailProvider         = $config.EmailProvider
$clusterCred           = $config.ClusterCredential
$emailFrom             = $config.EmailFrom
$emailTo               = $config.EmailTo
$smtpServer            = $config.SmtpServer
$smtpPort              = $config.SmtpPort
$smtpUseSsl            = $config.SmtpUseSsl
$smtpUser              = $config.SmtpUsername
$smtpPassword          = $config.SmtpPassword
$smtp2GoApiKey         = $config.Smtp2GoApiKey
$notificationGbInterval = $config.NotificationGbInterval
if ($notificationGbInterval -le 0) { $notificationGbInterval = 10 }

# Save Settings to JSON (use encrypted strings from config so saved values are preserved when user left fields blank)
$settingsToSave = [pscustomobject]@{
    TargetIP               = $targetIP
    Username               = $clusterCred.UserName
    PasswordEnc            = $config.ClusterPasswordEnc
    EmailProvider          = $emailProvider
    EmailFrom              = $emailFrom
    EmailTo                = $emailTo
    SmtpServer             = $smtpServer
    SmtpPort               = $smtpPort
    SmtpUseSsl             = $smtpUseSsl
    SmtpUsername           = $smtpUser
    SmtpPasswordEnc        = $config.SmtpPasswordEnc
    Smtp2GoApiKeyEnc       = $config.Smtp2GoApiKeyEnc
    NotificationGbInterval = $notificationGbInterval
}
$settingsToSave | ConvertTo-Json | Set-Content -Path $configPath

# ---------------------------------------------------------
# EMAIL FUNCTION (supports generic SMTP and SMTP2GO API)
# ---------------------------------------------------------
function Send-SmtpNotification {
    param([string]$Subject, [string]$Body)

    try {
        $provider = if ($emailProvider) { $emailProvider } else { "Generic" }

        # If using SMTP2GO with an API key, prefer the HTTP API for sending
        if ($provider -eq "SMTP2GO" -and $smtp2GoApiKey) {
            $plainKey = $null
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtp2GoApiKey)
            try {
                $plainKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            } finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }

            $apiHeaders = @{
                "Content-Type"      = "application/json"
                "X-Smtp2go-Api-Key" = $plainKey
            }
            $bodyObj = @{
                sender    = $emailFrom
                to        = @($emailTo)
                subject   = $Subject
                text_body = $Body
            } | ConvertTo-Json

            $response = Invoke-RestMethod -Uri "https://api.smtp2go.com/v3/email/send" -Method Post -Headers $apiHeaders -Body $bodyObj -ErrorAction Stop
            if ($response.data.succeeded -ne 1 -and -not $response.data.email_id) {
                $msg = if ($response.data.error) { $response.data.error } else { "Unknown SMTP2GO API response" }
                throw "SMTP2GO API error: $msg"
            }

            Write-Host "[Email Sent via SMTP2GO API] $Subject" -ForegroundColor Green
        } else {
            if ($null -eq $smtpPassword -or [string]::IsNullOrWhiteSpace($smtpServer)) {
                Write-Host "[Email Error] SMTP settings are incomplete. Cannot send notification." -ForegroundColor Red
                return
            }

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
        }
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

# Simple WPF monitoring window to show high-level status instead of console only
Add-Type -AssemblyName PresentationCore,PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

function New-MonitorWindow {
    param(
        [string]$TargetIP,
        [string]$ApiUrl
    )

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Scale Upload Monitor - Status"
        Height="450" Width="800"
        SizeToContent="Manual"
        ResizeMode="CanResize">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto" />
      <RowDefinition Height="*" />
      <RowDefinition Height="Auto" />
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,8">
      <TextBlock FontSize="16" FontWeight="Bold">
        <Run Text="Monitoring: " />
        <Run Text="$TargetIP" />
      </TextBlock>
      <TextBlock Margin="0,4,0,0">
        <Run Text="API URL: " />
        <Hyperlink Name="ApiLink" NavigateUri="$ApiUrl">
          <Run Text="$ApiUrl" />
        </Hyperlink>
      </TextBlock>
    </StackPanel>

    <TextBox Name="StatusTextBox"
             Grid.Row="1"
             IsReadOnly="True"
             AcceptsReturn="True"
             VerticalScrollBarVisibility="Auto"
             HorizontalScrollBarVisibility="Auto"
             TextWrapping="NoWrap" />

    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button Name="CloseButton" Content="Close" Width="80" />
    </StackPanel>
  </Grid>
</Window>
"@

    [xml]$xamlXml = $xaml
    $reader = New-Object System.Xml.XmlNodeReader $xamlXml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $statusTextBox = $window.FindName("StatusTextBox")
    $closeButton   = $window.FindName("CloseButton")
    $apiLink       = $window.FindName("ApiLink")

    $null = $closeButton.Add_Click({ $window.Close() })
    $null = $apiLink.Add_RequestNavigate({
        param($sender, $e)
        [System.Diagnostics.Process]::Start($e.Uri.AbsoluteUri) | Out-Null
        $e.Handled = $true
    })

    $window.Show()

    $script:MonitorWindow     = $window
    $script:MonitorStatusBox  = $statusTextBox
}

# SSL Bypass for Scale Cluster
if (-not ("TrustAllCertsPolicy" -as [type])) {
    add-type "using System.Net; using System.Security.Cryptography.X509Certificates; public class TrustAllCertsPolicy : ICertificatePolicy { public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) { return true; } }"
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $clusterCred.UserName, $clusterCred.GetNetworkCredential().Password)))
$headers = @{Authorization=("Basic {0}" -f $base64AuthInfo)}
$url = "https://$targetIP/rest/v1/VirtualDisk"

# Create monitoring window and show basic info
New-MonitorWindow -TargetIP $targetIP -ApiUrl $url

# Send a "monitoring started" email so you know it's running
Send-SmtpNotification -Subject "Scale Upload Monitoring Started ($targetIP)" -Body "Scale Upload Monitor has started watching uploads on cluster $targetIP.`n`nAPI URL: $url`nTimestamp: $(Get-Date)"

while ($true) {
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
        $diskList = if ($response.data) { $response.data } else { $response }
        $activityDisks = $diskList | Where-Object { $_.name -match "uploading|convert" }

        $statusLines = @()

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

                $statusLines += "$name : $status"

                Write-Progress -Id $progressId -Activity "Monitoring: $name" -Status $status -PercentComplete $percent
            }
        }
        else {
            foreach ($id in $script:UuidToProgressId.Values) {
                Write-Progress -Id $id -Activity "Monitoring Scale Uploads" -Completed
            }
            $script:UuidToProgressId = @{}
            Write-Progress -Activity "Monitoring Scale Uploads" -Status "No active uploads or conversions found..." -Completed
            $statusLines += "No active uploads or conversions found..."
        }
    }
    catch {
        Write-Host "Error connecting to Scale API: $($_.Exception.Message)" -ForegroundColor Red
        $statusLines += "Error connecting to Scale API: $($_.Exception.Message)"
    }

    if ($script:MonitorWindow -and -not $script:MonitorWindow.IsVisible) {
        break
    }
    if ($script:MonitorStatusBox) {
        $script:MonitorStatusBox.Text = ($statusLines -join [Environment]::NewLine)
        $script:MonitorStatusBox.ScrollToEnd()
    }

    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Seconds 5
}