﻿[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String] $ConfigASDKProgressLogPath,

    [Parameter(Mandatory = $true)]
    [String] $ASDKpath,

    [Parameter(Mandatory = $true)]
    [String] $downloadPath,

    [Parameter(Mandatory = $true)]
    [String] $deploymentMode,

    [Parameter(Mandatory = $true)]
    [ValidateSet("MySQL", "SQLServer")]
    [String] $dbrp,

    [parameter(Mandatory = $true)]
    [String] $tenantID,

    [parameter(Mandatory = $true)]
    [securestring] $secureVMpwd,

    [parameter(Mandatory = $true)]
    [String] $ERCSip,

    [parameter(Mandatory = $true)]
    [pscredential] $asdkCreds,

    [parameter(Mandatory = $true)]
    [pscredential] $cloudAdminCreds,
    
    [parameter(Mandatory = $true)]
    [String] $ScriptLocation,

    [parameter(Mandatory = $false)]
    [String] $skipMySQL,

    [parameter(Mandatory = $false)]
    [String] $skipMSSQL,

    [parameter(Mandatory = $true)]
    [String] $branch
)

$Global:VerbosePreference = "Continue"
$Global:ErrorActionPreference = 'Stop'
$Global:ProgressPreference = 'SilentlyContinue'

### DOWNLOADER FUNCTION #####################################################################################################################################
#############################################################################################################################################################
function DownloadWithRetry([string] $downloadURI, [string] $downloadLocation, [int] $retries) {
    while ($true) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            (New-Object System.Net.WebClient).DownloadFile($downloadURI, $downloadLocation)
            break
        }
        catch {
            $exceptionMessage = $_.Exception.Message
            Write-Verbose "Failed to download '$downloadURI': $exceptionMessage"
            if ($retries -gt 0) {
                $retries--
                Write-Verbose "Waiting 10 seconds before retrying. Retries left: $retries"
                Start-Sleep -Seconds 10
            }
            else {
                $exception = $_.Exception
                throw $exception
            }
        }
    }
}

$logFolder = "$($dbrp)RP"
$logName = $logFolder
$progressName = $logFolder
if ($dbrp -eq "MySQL") {
    $vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("mysqlrpadmin", $secureVMpwd)
    $rp = "mysql"
}
elseif ($dbrp -eq "SQLServer") {
    $vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("sqlrpadmin", $secureVMpwd)
    $rp = "sql"
}
if (($skipMySQL -eq $true) -or ($skipMSSQL -eq $true)) { $skipRP = $true }
else { $skipRP = $false }

### SET LOG LOCATION ###
$logDate = Get-Date -Format FileDate
New-Item -ItemType Directory -Path "$ScriptLocation\Logs\$logDate\$logFolder" -Force | Out-Null
$logPath = "$ScriptLocation\Logs\$logDate\$logFolder"

### START LOGGING ###
$runTime = $(Get-Date).ToString("MMdd-HHmmss")
$fullLogPath = "$logPath\$($logName)$runTime.txt"
Start-Transcript -Path "$fullLogPath" -Append -IncludeInvocationHeader

$progress = Import-Csv -Path $ConfigASDKProgressLogPath
$RowIndex = [array]::IndexOf($progress.Stage, "$progressName")

if ($progress[$RowIndex].Status -eq "Complete") {
    Write-Verbose -Message "ASDK Configuration Stage: $($progress[$RowIndex].Stage) previously completed successfully"
}
elseif (($skipRP -eq $false) -and ($progress[$RowIndex].Status -ne "Complete")) {
    # We first need to check if in a previous run, this section was skipped, but now, the user wants to add this, so we need to reset the progress.
    if ($progress[$RowIndex].Status -eq "Skipped") {
        Write-Verbose -Message "Operator previously skipped this step, but now wants to perform this step. Updating ConfigASDKProgressLog.csv file to Incomplete."
        # Update the ConfigASDKProgressLog.csv file with successful completion
        $progress = Import-Csv -Path $ConfigASDKProgressLogPath
        $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
        $progress[$RowIndex].Status = "Incomplete"
        $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
        $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
    }
    if (($progress[$RowIndex].Status -eq "Incomplete") -or ($progress[$RowIndex].Status -eq "Failed")) {
        try {
            if ($progress[$RowIndex].Status -eq "Failed") {
                # Update the ConfigASDKProgressLog.csv file back to incomplete status if previously failed
                $progress = Import-Csv -Path $ConfigASDKProgressLogPath
                $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
                $progress[$RowIndex].Status = "Incomplete"
                $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
            }
            # Need to ensure this stage doesn't start before the Windows Server images have been put into the PIR
            $progress = Import-Csv -Path $ConfigASDKProgressLogPath
            $serverCoreJobCheck = [array]::IndexOf($progress.Stage, "ServerCoreImage")
            while (($progress[$serverCoreJobCheck].Status -ne "Complete")) {
                Write-Verbose -Message "The ServerCoreImage stage of the process has not yet completed. Checking again in 10 seconds"
                Start-Sleep -Seconds 10
                if ($progress[$serverCoreJobCheck].Status -eq "Failed") {
                    throw "The ServerCoreImage stage of the process has failed. This should fully complete before the Windows Server full image is created. Check the UbuntuServerImage log, ensure that step is completed first, and rerun."
                }
                $progress = Import-Csv -Path $ConfigASDKProgressLogPath
                $serverCoreJobCheck = [array]::IndexOf($progress.Stage, "ServerCoreImage")
            }
            # Need to confirm that both deployments don't operate at exactly the same time, or there may be a conflict with creating DNS records at the end of the RP deployment
            if ($dbrp -eq "SQLServer") {
                if (($skipMySQL -eq $false) -and ($skipMSSQL -eq $false)) {
                    $progress = Import-Csv -Path $ConfigASDKProgressLogPath
                    $mySQLProgressCheck = [array]::IndexOf($progress.Stage, "MySQLRP")
                    if (($progress[$mySQLProgressCheck].Status -ne "Complete")) {
                        Write-Verbose -Message "To avoid deployment conflicts with the MySQL RP, delaying the SQL Server RP deployment by 2 minutes"
                        Start-Sleep -Seconds 120
                    }
                }
            }

            ###################################################################################################################
            ###################################################################################################################
            
            # PowerShell 1.4.0 & AzureRM 2017-03-09-profile installation for current SQL RP - just for this session
            if ($deploymentMode -eq "Online") {
                if (!$(Get-Module -Name AzureRM -ListAvailable | Where-Object {$_.Version -eq "1.2.11"})) {
                    # Install the old Azure Stack PS module and AzureRMProfile for database RP compatibility
                    Import-Module -Name PowerShellGet -ErrorAction Stop
                    Import-Module -Name PackageManagement -ErrorAction Stop
                    Remove-Module -Name AzureRM -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Compute -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Dns -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.KeyVault -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Network -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Profile -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Resources -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Storage -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.Tags -Force -ErrorAction SilentlyContinue
                    Remove-Module -Name AzureRM.UsageAggregates -Force -ErrorAction SilentlyContinue
                    Install-Module -Name AzureRM -RequiredVersion 1.2.11 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM -RequiredVersion 1.2.11 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Compute -RequiredVersion 1.2.3.4 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Dns -RequiredVersion 3.4.1  -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Network -RequiredVersion 1.0.5.4  -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Profile -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Resources -RequiredVersion 4.4.1 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Storage -RequiredVersion 1.0.5.4 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Tags -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.UsageAggregates -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                }
                if (!$(Get-Module -Name AzureStack -ListAvailable | Where-Object {$_.Version -eq "1.4.0"})) {
                    # Install the old Azure Stack PS module and AzureRMProfile for database RP compatibility
                    Import-Module -Name PowerShellGet -ErrorAction Stop -Verbose
                    Import-Module -Name PackageManagement -ErrorAction Stop -Verbose
                    Import-Module -Name AzureRM.Bootstrapper -ErrorAction Stop -Verbose
                    Install-Module -Name AzureStack -RequiredVersion 1.4.0 -ErrorAction Stop -Verbose
                    Import-Module -Name AzureStack -RequiredVersion 1.4.0 -ErrorAction Stop -Verbose
                }
            }
            elseif (($deploymentMode -eq "PartialOnline") -or ($deploymentMode -eq "Offline")) {
                # If this is a PartialOnline or Offline deployment, pull from the extracted zip file
                Import-Module -Name PowerShellGet -ErrorAction Stop -Verbose
                Import-Module -Name PackageManagement -ErrorAction Stop -Verbose
                $SourceLocation = "$downloadPath\ASDK\PowerShell\1.4.0"
                $RepoName = "AzureStackOfflineRepo1.4.0"
                Register-PSRepository -Name $RepoName -SourceLocation $SourceLocation -InstallationPolicy Trusted
                Remove-Module -Name AzureRM -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Compute -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Dns -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.KeyVault -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Network -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Profile -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Resources -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Storage -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.Tags -Force -ErrorAction SilentlyContinue
                Remove-Module -Name AzureRM.UsageAggregates -Force -ErrorAction SilentlyContinue
                Install-Module AzureRM -Repository $RepoName -Force -ErrorAction Stop
                Import-Module -Name AzureRM -RequiredVersion 1.2.11 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Compute -RequiredVersion 1.2.3.4 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Dns -RequiredVersion 3.4.1  -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Network -RequiredVersion 1.0.5.4  -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Profile -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Resources -RequiredVersion 4.4.1 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Storage -RequiredVersion 1.0.5.4 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.Tags -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                Import-Module -Name AzureRM.UsageAggregates -RequiredVersion 3.4.1 -ErrorAction Stop -Verbose
                Install-Module AzureStack -Repository $RepoName -Force -ErrorAction Stop
                Import-Module -Name AzureStack -RequiredVersion 1.4.0 -ErrorAction Stop -Verbose
            }

            ###################################################################################################################
            ###################################################################################################################

            ### Login to Azure Stack ###
            $ArmEndpoint = "https://adminmanagement.local.azurestack.external"
            Add-AzureRMEnvironment -Name "AzureStackAdmin" -ArmEndpoint "$ArmEndpoint" -ErrorAction Stop
            Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $tenantID -Credential $asdkCreds -ErrorAction Stop | Out-Null

            # Get Azure Stack location
            $azsLocation = (Get-AzsLocation).Name
            # Need to 100% confirm that the ServerCoreImage is ready as it seems that starting the MySQL/SQL RP deployment immediately is causing an issue
            Write-Verbose -Message "Need to confirm that the Windows Server 2016 Core image is available in the gallery and ready"
            $azsPlatformImageExists = (Get-AzsPlatformImage -Location "$azsLocation" -Publisher "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-Datacenter-Server-Core" -Version "1.0.0" -ErrorAction SilentlyContinue).ProvisioningState -eq 'Succeeded'
            $azureRmVmPlatformImageExists = (Get-AzureRmVMImage -Location "$azsLocation" -Publisher "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-Datacenter-Server-Core" -Version "1.0.0" -ErrorAction SilentlyContinue).StatusCode -eq 'OK'
            Write-Verbose -Message "Check #1 - Using Get-AzsPlatformImage to check for Windows Server 2016 Core image"
            if ($azsPlatformImageExists) {
                Write-Verbose -Message "Get-AzsPlatformImage, successfully located an appropriate image with the following details:"
                Write-Verbose -Message "Publisher: MicrosoftWindowsServer | Offer: WindowsServer | Sku: 2016-Datacenter-Server-Core"
            }
            While (!$(Get-AzsPlatformImage -Location "$azsLocation" -Publisher "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-Datacenter-Server-Core" -Version "1.0.0" -ErrorAction SilentlyContinue).ProvisioningState -eq 'Succeeded') {
                Write-Verbose -Message "Using Get-AzsPlatformImage, ServerCoreImage is not ready yet. Delaying by 20 seconds"
                Start-Sleep -Seconds 20
            }
            Write-Verbose -Message "Check #2 - Using Get-AzureRmVMImage to check for Windows Server 2016 Core image"
            if ($azureRmVmPlatformImageExists) {
                Write-Verbose -Message "Using Get-AzureRmVMImage, successfully located an appropriate image with the following details:"
                Write-Verbose -Message "Publisher: MicrosoftWindowsServer | Offer: WindowsServer | Sku: 2016-Datacenter-Server-Core"
            }
            While (!$(Get-AzureRmVMImage -Location "$azsLocation" -Publisher "MicrosoftWindowsServer" -Offer "WindowsServer" -Sku "2016-Datacenter-Server-Core" -Version "1.0.0" -ErrorAction SilentlyContinue).StatusCode -eq 'OK') {
                Write-Verbose -Message "Using Get-AzureRmVMImage to test, ServerCoreImage is not ready yet. Delaying by 20 seconds"
                Start-Sleep -Seconds 20
            }

            # For an extra safety net, add an extra delay to ensure the image is fully ready in the PIR, otherwise it seems to cause a failure.
            Write-Verbose -Message "Delaying for a further 4 minutes to account for random failure with MySQL/SQL RP to detect platform image immediately after upload"
            Start-Sleep -Seconds 240

            # Login to Azure Stack
            Write-Verbose -Message "Downloading and installing $dbrp Resource Provider"

            if (!$([System.IO.Directory]::Exists("$ASDKpath\databases"))) {
                New-Item -Path "$ASDKpath\databases" -ItemType Directory -Force | Out-Null
            }
            if ($deploymentMode -eq "Online") {
                # Cleanup old folder
                Remove-Item "$asdkPath\databases\$dbrp" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item "$ASDKpath\databases\$($dbrp).zip" -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
                # Download and Expand the RP files
                if ($dbrp -eq "MySQL") {
                    $rpURI = "https://aka.ms/azurestack$($rp)rp1804"
                }
                else {
                    $rpURI = "https://aka.ms/azurestacksqlrp1804"
                }
                $rpDownloadLocation = "$ASDKpath\databases\$($dbrp).zip"
                DownloadWithRetry -downloadURI "$rpURI" -downloadLocation "$rpDownloadLocation" -retries 10
            }
            elseif ($deploymentMode -ne "Online") {
                if (-not [System.IO.File]::Exists("$ASDKpath\databases\$($dbrp).zip")) {
                    throw "Missing Zip file in extracted dependencies folder. Please ensure this exists at $ASDKpath\databases\$($dbrp).zip - Exiting process"
                }
            }
            Set-Location "$ASDKpath\databases"
            Expand-Archive "$ASDKpath\databases\$($dbrp).zip" -DestinationPath .\$dbrp -Force -ErrorAction Stop
            Set-Location "$ASDKpath\databases\$($dbrp)"

            # Replace MySQL/SQL RP Common File
            if ($deploymentMode -eq "Online") {
                # Grab from my GitHub and overwrite existing file
                $commonPathUri = "https://raw.githubusercontent.com/mattmcspirit/azurestack/$branch/deployment/powershell/Common.psm1"
                DownloadWithRetry -downloadURI -downloadLocation "$asdkPath\databases\$dbrp\Prerequisites\Common\Common.psm1" -retries 10
            }
            elseif (($deploymentMode -eq "PartialOnline") -or ($deploymentMode -eq "Offline")) {
                # Grab from offline ZIP path
                $commonPathUri = Get-ChildItem -Path "$ASDKpath\databases\Common.psm1" -ErrorAction Stop | ForEach-Object { $_.FullName }
                $commonTargetPath = "$asdkPath\databases\$dbrp\Prerequisites\Common\"
                Copy-Item $commonPathUri -Destination $commonTargetPath -Force -Verbose
            }

            if ($dbrp -eq "MySQL") {
                if ($deploymentMode -eq "Online") {
                    .\DeployMySQLProvider.ps1 -AzCredential $asdkCreds -VMLocalCredential $vmLocalAdminCreds -CloudAdminCredential $cloudAdminCreds -PrivilegedEndpoint $ERCSip -DefaultSSLCertificatePassword $secureVMpwd -AcceptLicense
                }
                elseif (($deploymentMode -eq "PartialOnline") -or ($deploymentMode -eq "Offline")) {
                    $dependencyFilePath = New-Item -ItemType Directory -Path "$ASDKpath\databases\$dbrp\Dependencies" -Force | ForEach-Object { $_.FullName }
                    $MySQLMSI = Get-ChildItem -Path "$ASDKpath\databases\*" -Recurse -Include "*connector*.msi" -ErrorAction Stop | ForEach-Object { $_.FullName }
                    Copy-Item $MySQLMSI -Destination $dependencyFilePath -Force -Verbose
                    .\DeployMySQLProvider.ps1 -AzCredential $asdkCreds -VMLocalCredential $vmLocalAdminCreds -CloudAdminCredential $cloudAdminCreds -PrivilegedEndpoint $ERCSip -DefaultSSLCertificatePassword $secureVMpwd -DependencyFilesLocalPath $dependencyFilePath -AcceptLicense
                }
            }
            elseif ($dbrp -eq "SQLServer") {
                .\DeploySQLProvider.ps1 -AzCredential $asdkCreds -VMLocalCredential $vmLocalAdminCreds -CloudAdminCredential $cloudAdminCreds -PrivilegedEndpoint $ERCSip -DefaultSSLCertificatePassword $secureVMpwd
            }

            # Update the ConfigASDKProgressLog.csv file with successful completion
            Write-Verbose "Updating ConfigASDKProgressLog.csv file with successful completion`r`n"
            $progress = Import-Csv -Path $ConfigASDKProgressLogPath
            $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
            $progress[$RowIndex].Status = "Complete"
            $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
            Write-Output $progress | Out-Host
        }
        catch {
            Write-Verbose "ASDK Configuration Stage: $($progress[$RowIndex].Stage) Failed`r`n"
            $progress = Import-Csv -Path $ConfigASDKProgressLogPath
            $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
            $progress[$RowIndex].Status = "Failed"
            $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
            Write-Output $progress | Out-Host
            Set-Location $ScriptLocation
            throw $_.Exception.Message
            return
        }
    }
}
elseif (($skipRP) -and ($progress[$RowIndex].Status -ne "Complete")) {
    Write-Verbose -Message "Operator chose to skip Resource Provider Deployment`r`n"
    # Update the ConfigASDKProgressLog.csv file with successful completion
    $progress = Import-Csv -Path $ConfigASDKProgressLogPath
    $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
    $progress[$RowIndex].Status = "Skipped"
    $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
    Write-Output $progress | Out-Host
}
Set-Location $ScriptLocation
Stop-Transcript -ErrorAction SilentlyContinue