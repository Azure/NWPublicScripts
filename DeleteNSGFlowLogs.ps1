#region Global

$configPath = '.\RegionSubscriptionConfig.json'
$mutex = $null

#endregion


#region Utilities

function Read-ValuesIgnoringPreviousEntries($readMsg)
{
    while ($true)
    {
        $res = Read-Host $readMsg

        if ($res -ne '')
        {
            return $res
        }
    }

    return ""
}

function Filter-DisabledNSGFlowLogs($flList)
{
	[System.Collections.ArrayList]$disabledNSGFlList = @()
	Write-Host("Filtering disabled NSG flowlogs")

	foreach ($fl in $flList)
	{
		if ($fl.Enabled)
		{
			continue
		}

		$targetResource = Get-AzResource -ResourceId $fl.TargetResourceId

		if ($targetResource.ResourceType -eq "Microsoft.Network/networkSecurityGroups")
		{
			[void]$disabledNSGFlList.Add($fl)
		}
	}

	return $disabledNSGFlList
}

function Delete-FlowLogs($flowLogList)
{
    $allSucceeded = @{ "success" = $true }

	if ($flowLogList.Length -eq 0)
	{
		return $allSucceeded.success
	}

    $flowLogList | ForEach-Object -ThrottleLimit 16 -Parallel {
        $fl = $_
        Remove-AzNetworkWatcherFlowLog -ResourceId $fl.Id
        Start-Sleep -Seconds 10
        $deletedFl = Get-AzNetworkWatcherFlowLog -Location $fl.Location -Name $fl.Name -ErrorAction SilentlyContinue
        [void]($using:mutex).WaitOne()

        try
        {
            if ($null -eq $deletedFl)
            {
                Write-Host "Deleted flowlog:" $fl.Name ", TargetResourceId: " $fl.TargetResourceId -ForeGroundColor Green
            }
            else
            {
                $allSucceeded.success = $false
                Write-Host "Failed to delete flowlog:" $fl.Name ", TargetResourceId: " $fl.TargetResourceId -ForeGroundColor Yellow
            }
        }
        finally
        {
            ($using:mutex).ReleaseMutex()
        }
    }

    Get-Job | Wait-Job

    return $allSucceeded.success
}

function Delete-NSGFlowLogs()
{
    Write-Host "Getting all disabled NSG flowlogs in region:" $region "and subscription:" $subscriptionId -ForegroundColor Blue
    $flList =  Get-AzNetworkWatcherFlowLog -Location $region
    $disabledNSGFlList =  Filter-DisabledNSGFlowLogs $flList
    $proceed = Read-ValuesIgnoringPreviousEntries("Proceed with deletion of flowlogs?(y/n)")
    $proceed = $proceed.ToLower()

    if ($proceed -eq 'y')
    {
        if ((Delete-FlowLogs $disabledNSGFlList))
        {
            Write-Host "Deleted all disabled NSG flowlogs in region:" $region "and subscription:" $subscriptionId -ForegroundColor Green
        }
        else
        {
            Write-Host "There were some failures in deletion of disabled NSG flowlogs in region:" $region "and subscription:" $subscriptionId ", please take a look" -ForegroundColor Red
        }
    }
}


#endregion

try
{
	$configPath = Read-ValuesIgnoringPreviousEntries("Please enter the path to select config file:")
	$subIdRegion = Get-Content -Path $configPath | ConvertFrom-Json  -AsHashtable -ErrorAction SilentlyContinue
}
catch
{
	Write-Host "Config file is in incorrect json format, please format it correctly" -ForegroundColor Red
	return
}

if ($null -eq $subIdRegion)
{
	Write-Host "Config file is in incorrect json format, please format it correctly" -ForegroundColor Red
	return
}

Connect-AzAccount
$mutex = New-Object Threading.Mutex($false, "MyMutex")

foreach($subId in $subIdRegion.Keys)
{
	$subscriptionId = $subId

	foreach($reg in $subIdRegion[$subId])
	{
		$region = $reg
		Set-AzContext -SubscriptionId $subscriptionId

		Delete-NSGFlowLogs
	}
}

$mutex.Close()