﻿[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [String] $ConfigASDKProgressLogPath,

    [Parameter(Mandatory = $true)]
    [String] $deploymentMode,

    [parameter(Mandatory = $true)]
    [String] $tenantID,

    [parameter(Mandatory = $true)]
    [pscredential] $asdkCreds,

    [Parameter(Mandatory = $false)]
    [String] $registerASDK,
    
    [parameter(Mandatory = $true)]
    [String] $ScriptLocation
)

$Global:VerbosePreference = "Continue"
$Global:ErrorActionPreference = 'Stop'
$Global:ProgressPreference = 'SilentlyContinue'

$logFolder = "AddVMExtensions"
$logName = $logFolder
$progressName = $logFolder

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

if ($registerASDK -and ($deploymentMode -ne "Offline")) {
    if (($progress[$RowIndex].Status -eq "Incomplete") -or ($progress[$RowIndex].Status -eq "Failed")) {
        try {
            # Currently an infinite loop bug exists in Azs.AzureBridge.Admin 0.1.1 - this section fixes it by editing the Get-TaskResult.ps1 file
            # Also then launches the VM Extension important in a fresh PSSession as a precaution.
            if (!(Get-Module -Name Azs.AzureBridge.Admin)) {
                Import-Module Azs.AzureBridge.Admin -Force
            }
            if ((((Get-Module -Name Azs.AzureBridge*).Version).ToString()) -eq "0.1.1") {
                $taskResult = (Get-ChildItem -Path "$((Get-Module -Name Azs.AzureBridge*).ModuleBase)" -Recurse -Include "Get-TaskResult.ps1" -ErrorAction Stop).FullName
                foreach ($task in $taskResult) {
                    $old = 'Write-Debug -Message "$($result | Out-String)"'
                    $new = '#Write-Debug -Message "$($result | Out-String)"'
                    $pattern1 = [RegEx]::Escape($old)
                    $pattern2 = [RegEx]::Escape($new)
                    if (!((Get-Content $taskResult) | Select-String $pattern2)) {
                        if ((Get-Content $taskResult) | Select-String $pattern1) {
                            Write-Verbose -Message "Known issue with Azs.AzureBridge.Admin Module Version 0.1.1 - editing Get-TaskResult.ps1"
                            Write-Verbose -Message "Removing module before editing file"
                            Remove-Module Azs.AzureBridge.Admin -Force -Confirm:$false -Verbose
                            Write-Verbose -Message "Editing file"
                            (Get-Content $taskResult) | ForEach-Object { $_ -replace $pattern1, $new } -Verbose -ErrorAction Stop | Set-Content $taskResult -Verbose -ErrorAction Stop
                            Write-Verbose -Message "Editing completed. Reimporting module"
                            Import-Module Azs.AzureBridge.Admin -Force
                        }
                    }
                }
            }
            Get-AzureRmContext -ListAvailable | Where-Object {$_.Environment -like "Azure*"} | Remove-AzureRmAccount | Out-Null
            Clear-AzureRmContext -Scope CurrentUser -Force
            ### Login to Azure Stack, then confirm if the MySQL Gallery Item is already present ###
            $ArmEndpoint = "https://adminmanagement.local.azurestack.external"
            Add-AzureRMEnvironment -Name "AzureStackAdmin" -ArmEndpoint "$ArmEndpoint" -ErrorAction Stop
            Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $tenantID -Credential $asdkCreds -ErrorAction Stop | Out-Null
            $activationName = "default"
            $activationRG = "azurestack-activation"
            if ($(Get-AzsAzureBridgeActivation -Name $activationName -ResourceGroupName $activationRG -ErrorAction SilentlyContinue -Verbose)) {
                Write-Verbose -Message "Adding Microsoft VM Extensions from the from the Azure Stack Marketplace"
                $getExtensions = ((Get-AzsAzureBridgeProduct -ActivationName $activationName -ResourceGroupName $activationRG -ErrorAction SilentlyContinue -Verbose | Where-Object {($_.ProductKind -eq "virtualMachineExtension") -and ($_.Name -like "*microsoft*")}).Name) -replace "default/", ""
                foreach ($extension in $getExtensions) {
                    while (!$(Get-AzsAzureBridgeDownloadedProduct -Name $extension -ActivationName $activationName -ResourceGroupName $activationRG -ErrorAction SilentlyContinue -Verbose)) {
                        Write-Verbose -Message "Didn't find $extension in your gallery. Downloading from the Azure Stack Marketplace"
                        Invoke-AzsAzureBridgeProductDownload -ActivationName $activationName -Name $extension -ResourceGroupName $activationRG -Force -Confirm:$false -Verbose
                    }
                }
                $getDownloads = (Get-AzsAzureBridgeDownloadedProduct -ActivationName $activationName -ResourceGroupName $activationRG -ErrorAction SilentlyContinue -Verbose | Where-Object {($_.ProductKind -eq "virtualMachineExtension") -and ($_.Name -like "*microsoft*")})
                Write-Verbose -Message "Your Azure Stack gallery now has the following Microsoft VM Extensions for enhancing your deployments:`r`n"
                foreach ($download in $getDownloads) {
                    "$($download.DisplayName) | Version: $($download.ProductProperties.Version)"
                }
                # Update the ConfigASDKProgressLog.csv file with successful completion
                Write-Verbose "Updating ConfigASDKProgressLog.csv file with successful completion`r`n"
                $progress = Import-Csv -Path $ConfigASDKProgressLogPath
                $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
                $progress[$RowIndex].Status = "Complete"
                $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
                Write-Output $progress | Out-Host
            }
            else {
                # No Azure Bridge Activation Record found - Skip rather than fail
                Write-Verbose -Message "Skipping Microsoft VM Extension download, no Azure Bridge Activation Object called $activationName could be found within the resource group $activationRG on your Azure Stack"
                Write-Verbose -Message "Assuming registration of this ASDK was successful, you should be able to manually download the VM extensions from Marketplace Management in the admin portal`r`n"
                # Update the ConfigASDKProgressLog.csv file with successful completion
                $progress = Import-Csv -Path $ConfigASDKProgressLogPath
                $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
                $progress[$RowIndex].Status = "Skipped"
                $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
                Write-Output $progress | Out-Host
            }
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
    elseif ($progress[$RowIndex].Status -eq "Skipped") {
        $progress = Import-Csv -Path $ConfigASDKProgressLogPath
        $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
        Write-Verbose -Message "ASDK Configuration Stage: $($progress[$RowIndex].Stage) previously skipped"
    }
    elseif ($progress[$RowIndex].Status -eq "Complete") {
        $progress = Import-Csv -Path $ConfigASDKProgressLogPath
        $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
        Write-Verbose -Message "ASDK Configuration Stage: $($progress[$RowIndex].Stage) previously completed successfully"
    }
}
elseif (!$registerASDK) {
    Write-Verbose -Message "Skipping VM Extension download, as Azure Stack has not been registered`r`n"
    # Update the ConfigASDKProgressLog.csv file with successful completion
    $progress = Import-Csv -Path $ConfigASDKProgressLogPath
    $RowIndex = [array]::IndexOf($progress.Stage, "$progressName")
    $progress[$RowIndex].Status = "Skipped"
    $progress | Export-Csv $ConfigASDKProgressLogPath -NoTypeInformation -Force
    Write-Output $progress | Out-Host
}
Set-Location $ScriptLocation
Stop-Transcript -ErrorAction SilentlyContinue