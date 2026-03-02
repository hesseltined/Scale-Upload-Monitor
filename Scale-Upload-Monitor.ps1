<#
.SYNOPSIS
    Monitors Scale Computing Virtual Disk Upload Progress via REST API and sends SMTP2GO notifications.
.PARAMETER Test
    If specified, sends a test email using the configured SMTP2GO settings and then exits.
#>

param (
    [switch]$Test
)

# GUI vs console: WinForms not available on PowerShell Core (e.g. macOS)
$script:UseConsolePrompts = $false
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
} catch {
    $script:UseConsolePrompts = $true
}

# ---------------------------------------------------------
# CONFIG: Persist IP, Cluster Credentials, and SMTP Settings
# ---------------------------------------------------------
if ($PSScriptRoot) { $scriptDir = $PSScriptRoot } else { $scriptDir = (Get-Location).Path }
$configPath = Join-Path $scriptDir 'Scale-Monitor-Uploads.config.json'

# Load Saved Settings (with try/catch for corrupted JSON)
$SavedSettings = $null
if (Test-Path $configPath) {
    try {
        $SavedSettings = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    } catch {
        $SavedSettings = $null
    }
}

function Get-InputBox {
    param ([string]$Title, [string]$Prompt, [string]$DefaultText, [bool]$IsPassword = $false)
    if ($script:UseConsolePrompts) {
        Write-Host $Prompt -ForegroundColor Cyan
        $read = Read-Host $Title
        if ([string]::IsNullOrWhiteSpace($read) -and -not [string]::IsNullOrWhiteSpace($DefaultText)) { return $DefaultText }
        return $read
    }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title ; $form.Size = New-Object System.Drawing.Size(350, 180)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
    $label = New-Object System.Windows.Forms.Label ; $label.Location = New-Object System.Drawing.Point(10, 20)
    $label.Size = New-Object System.Drawing.Size(320, 20) ; $label.Text = $Prompt ; $form.Controls.Add($label)
    $textBox = New-Object System.Windows.Forms.TextBox ; $textBox.Location = New-Object System.Drawing.Point(10, 50)
    $textBox.Size = New-Object System.Drawing.Size(310, 20) ; $textBox.Text = $DefaultText
    if ($IsPassword) { $textBox.UseSystemPasswordChar = $true }
    $form.Controls.Add($textBox)
    $okButton = New-Object System.Windows.Forms.Button ; $okButton.Location = New-Object System.Drawing.Point(130, 90)
    $okButton.Size = New-Object System.Drawing.Size(75, 23) ; $okButton.Text = "OK" ; $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $okButton ; $form.Controls.Add($okButton)
    $form.Topmost = $true
    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $textBox.Text } else { return $null }
}

# 1. Get Cluster IP and Credentials
$targetIP = if ($SavedSettings.TargetIP) { $SavedSettings.TargetIP } else { Get-InputBox "Cluster" "Enter Scale Cluster IP:" "10.110.248.10" }
if ([string]::IsNullOrWhiteSpace($targetIP)) {
    Write-Host "No cluster IP provided. Exiting." -ForegroundColor Red
    exit 1
}
if (-not $SavedSettings.Username -or -not $SavedSettings.PasswordEnc) {
    Write-Host "Enter Scale Cluster Credentials:" -ForegroundColor Yellow
    $clusterCred = Get-Credential
} else {
    try {
        $pass = ConvertTo-SecureString $SavedSettings.PasswordEnc -ErrorAction Stop
        $clusterCred = New-Object System.Management.Automation.PSCredential($SavedSettings.Username, $pass)
    } catch {
        Write-Host "Could not decrypt saved cluster password. Please re-enter." -ForegroundColor Yellow
        $clusterCred = Get-Credential
    }
}

# 2. Get SMTP2GO Settings (API Key Only)
$emailFrom = if ($SavedSettings.EmailFrom) { $SavedSettings.EmailFrom } else { Get-InputBox "Email" "Sender Email Address (Verified in SMTP2GO):" "alerts@yourdomain.com" }
$emailTo   = if ($SavedSettings.EmailTo)   { $SavedSettings.EmailTo }   else { Get-InputBox "Email" "Recipient Email Address:" "admin@yourdomain.com" }

# Logic to handle API Key (decrypt existing or prompt for new)
$smtpApiKey = $null
if ($SavedSettings.SmtpApiKeyEnc) {
    try {
        $smtpApiKey = ConvertTo-SecureString $SavedSettings.SmtpApiKeyEnc -ErrorAction Stop
    } catch {
        $smtpApiKey = $null # Force re-prompt if decryption fails
    }
}

if ($null -eq $smtpApiKey) {
    $p = Get-InputBox "SMTP2GO" "Enter SMTP2GO API Key:" "" -IsPassword $true
    if ([string]::IsNullOrWhiteSpace($p)) { 
        Write-Host "Error: SMTP2GO API Key is required to send notifications." -ForegroundColor Red
        exit 
    }
    $smtpApiKey = $p | ConvertTo-SecureString -AsPlainText -Force 
}

# Save Settings to JSON
$settingsToSave = [pscustomobject]@{
    TargetIP        = $targetIP
    Username        = $clusterCred.UserName
    PasswordEnc     = $clusterCred.Password | ConvertFrom-SecureString
    SmtpApiKeyEnc   = $smtpApiKey | ConvertFrom-SecureString
    EmailFrom       = $emailFrom
    EmailTo         = $emailTo
}
$settingsToSave | ConvertTo-Json | Set-Content -Path $configPath

# ---------------------------------------------------------
# EMAIL FUNCTION (SMTP2GO REST API - API key is for HTTP API, not SMTP)
# ---------------------------------------------------------
function Send-SmtpNotification {
    param([string]$Subject, [string]$Body)
    
    if ($null -eq $smtpApiKey) {
        Write-Host "[Email Error] API Key is missing. Cannot send notification." -ForegroundColor Red
        return
    }

    try {
        $plainKey = $null
        $BSTR = $null
        try {
            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtpApiKey)
            $plainKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        } finally {
            if ($null -ne $BSTR) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
        }
        $apiHeaders = @{
            "Content-Type"       = "application/json"
            "X-Smtp2go-Api-Key"  = $plainKey
        }
        $bodyObj = @{
            sender   = $emailFrom
            to       = @($emailTo)
            subject  = $Subject
            text_body = $Body
        } | ConvertTo-Json
        $response = Invoke-RestMethod -Uri "https://api.smtp2go.com/v3/email/send" -Method Post -Headers $apiHeaders -Body $bodyObj -ErrorAction Stop
        if ($response.data.succeeded -eq 1 -or $response.data.email_id) {
            Write-Host "[Email Sent] $Subject" -ForegroundColor Green
        } else {
            $errMsg = if ($response.data.error) { $response.data.error } else { "Unknown API response" }
            Write-Host "[Email Failed] $errMsg" -ForegroundColor Red
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
    Send-SmtpNotification -Subject "SMTP2GO Test Notification" -Body "This is a test email from your Scale Monitor script. If you received this, your SMTP2GO settings are correct!`n`nTimestamp: $(Get-Date)"
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
Write-Host "Notifications: Every 10GB or 2 minute stall." -ForegroundColor Gray
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
                        LastGBNotified = $currentGB
                        LastBytes      = $currentBytes
                        LastChangeTime = $now
                        StallAlertSent = $false
                    }
                    Send-SmtpNotification -Subject "Upload Started: $name" -Body "Script started monitoring $name. Current progress: $currentGB GB."
                }

                $stats = $DiskStats[$uuid]

                if ($currentGB -ge ($stats.LastGBNotified + 10)) {
                    $stats.LastGBNotified = $currentGB
                    Send-SmtpNotification -Subject "Progress Update: $name" -Body "Disk $name has reached $currentGB GB of $([math]::Round($totalBytes/1GB, 2)) GB."
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

                $percent = if ($totalBytes -gt 0) { [math]::Min(100, [math]::Round(($currentBytes / $totalBytes) * 100, 1)) } else { 0 }
                Write-Progress -Id $progressId -Activity "Monitoring: $name" -Status "$currentGB GB / $([math]::Round($totalBytes/1GB, 2)) GB ($percent%)" -PercentComplete $percent
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