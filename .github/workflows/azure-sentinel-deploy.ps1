## Globals ##
$CloudEnv = $Env:cloudEnv
$ResourceGroupName = $Env:resourceGroupName
$WorkspaceName = $Env:workspaceName
$Directory = $Env:directory
$Creds = $Env:creds

$MaxRetries = 3
$secondsBetweenAttempts = 5

function AttemptAzLogin($psCredential, $tenantId, $cloudEnv) {
    $maxLoginRetries = 3
    $delayInSeconds = 30
    $retryCount = 1
    $stopTrying = $false
    do {
        try {
            Connect-AzAccount -ServicePrincipal -Tenant $tenantId -Credential $psCredential -Environment $cloudEnv | out-null;
            Write-Host "Login Successful"
            $stopTrying = $true
        }
        catch {
            if ($retryCount -ge $maxLoginRetries) {
                Write-Host "Login failed after $maxLoginRetries attempts."
                $stopTrying = $true
            }
            else {
                Write-Host "Login attempt failed, retrying in $delayInSeconds seconds."
                Start-Sleep -Seconds $delayInSeconds
                $retryCount++
            }
        }
    }
    while (-not $stopTrying)
}

function ConnectAzCloud {
    $RawCreds = $Creds | ConvertFrom-Json

    Clear-AzContext -Scope Process;
    Clear-AzContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue;

    Add-AzEnvironment `
        -Name $CloudEnv `
        -ActiveDirectoryEndpoint $RawCreds.activeDirectoryEndpointUrl `
        -ResourceManagerEndpoint $RawCreds.resourceManagerEndpointUrl `
        -ActiveDirectoryServiceEndpointResourceId $RawCreds.activeDirectoryServiceEndpointResourceId `
        -GraphEndpoint $RawCreds.graphEndpointUrl | out-null;

    $servicePrincipalKey = ConvertTo-SecureString $RawCreds.clientSecret.replace("'", "''") -AsPlainText -Force
    $psCredential = New-Object System.Management.Automation.PSCredential($RawCreds.clientId, $servicePrincipalKey)

    AttemptAzLogin $psCredential $RawCreds.tenantId $CloudEnv
    Set-AzContext -Tenant $RawCreds.tenantId | out-null;
}

function IsValidTemplate($object) {
    Try {
        Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateObject $object -workspace $WorkspaceName
        return $true
    }
    Catch {
        Write-Host "[Warning] The file $path is not valid: $_"
        return $false
    }
}

function IsRetryable($deploymentName) {
    $retryableStatusCodes = "Conflict","TooManyRequests","InternalServerError"
    Try {
        $deploymentResult = Get-AzResourceGroupDeploymentOperation -DeploymentName $deploymentName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
        return $retryableStatusCodes -contains $deploymentResult.StatusCode
    }
    Catch {
        return $false
    }
}


function AttemptDeployment($object, $deploymentName) {
    $isValid = IsValidTemplate $object
    if (-not $isValid) {
        return $false
    }
    $isSuccess = $false
    $currentAttempt = 0
    While (($currentAttempt -lt $MaxRetries) -and (-not $isSuccess))
    {
        $currentAttempt ++
        Try
        {
            New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateObject $object -workspace $workspaceName -ErrorAction Stop | Out-Host
            $isSuccess = $true
        }
        Catch [Exception]
        {
            $error = $_
            if (-not (IsRetryable $deploymentName))
            {
                Write-Host "[Warning] Failed to deploy $path with error: $error"
                break
            }
            else
            {
                if ($currentAttempt -le $MaxRetries)
                {
                    Write-Host "[Warning] Failed to deploy $path with error: $error. Retrying in $secondsBetweenAttempts seconds..."
                    Start-Sleep -Seconds $secondsBetweenAttempts
                }
                else
                {
                    Write-Host "[Warning] Failed to deploy $path after $currentAttempt attempts with error: $error"
                }
            }
        }
    }
    return $isSuccess
}

function main() {
    if ($CloudEnv -ne 'AzureCloud')
    {
        Write-Output "Attempting Sign In to Azure Cloud"
        ConnectAzCloud
    }

    Write-Output "Starting Deployment for Files in path: $Directory"

    # ARM Temlate basic
    $template = @{
        '$schema' = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
        contentVersion = "1.0.0.0"
        Parameters = @{
            Workspace = @{
                type = "string"
            }
        }
        resources = @()
    }

    if (Test-Path -Path $Directory)
    {
        $totalRules = 0;
        $totalFailed = 0;

        Get-ChildItem -Path $Directory -Recurse -Filter *.json  | ForEach-Object {
            $totalRules ++
            $template.resources += ($_ | Get-Content -Raw | ConvertFrom-Json -Depth 20 -AsHashtable | Select-Object resources).resources
        }
        $deploymentName = (Get-Date -Format ddMMyyyy)
        $isSuccess = AttemptDeployment $template $deploymentName
        if (-not $isSuccess)
        {
            $totalFailed++
        }


        if ($totalRules -gt 0 -and $totalFailed -gt 0)
        {
            $error = "$totalFailed of $totalRules deployments failed."
            Throw $error
        }
    }
    else
    {
        Write-Output "[Warning] $Directory not found. nothing to deploy"
    }
}

main
