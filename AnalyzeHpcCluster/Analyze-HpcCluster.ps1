# ----------------------------------------------------------------------------- 
# Script: Analyze-HpcCluster.ps1 
# Author: Yutong Sun 
# Date: Mar. 20, 2016
# Keywords: HPC, Performance, Diagnostics
# Comments: This script is used to setup, run specific workloads, and analyze
# the performance counters on an HPC Pack cluster
# Version: 1.0
# ----------------------------------------------------------------------------- 

<# 
   .Synopsis 
    This script is used to do performance evaluation and bottleneck diagnostics via the Performance Counters collected

   .Parameter Setup
    Specify whether to deploy the bits and setup the perf counters are needed.
   
   .Parameter RunAnalyze
    Specify whether to run the workload, collect the logs and analyze the results.

   .Parameter Analyze
   Specify whether to analyze the results.
       
   .Example 
    .\Analyze-HpcCluster.ps1 -Setup

   .Example  
    .\Analyze-HpcCluster.ps1 -RunAnalyze 
    
   .Example  
    .\Analyze-HpcCluster.ps1 -Analyze

   .Notes 
    The prerequisites for running this scripts:
    1.	The tool Analyze-HpcCluster.zip can be unzipped in a folder e.g. C:\HpcPerfRun on the head node. The same folder will be created on all cluster nodes and the DB server.
    2.	The script Analyze-HpcCluster.ps1 should run on head node under the HPC Administrator account which is in the local administrators group on all the cluster nodes and the DB server.
    3.	The powershell remoting is enabled on head node and DB server.
    4.	The HPC Pack cluster is better with performance and scale configurations.
    5.	The windows built-in relog tool is used to filter the blg file and export temp csv file for analysis.
    6.	There is a sample workload Run_SOA_Echo.ps1 which utilize the built-in EchoClient.exe on the compute nodes. Specific workload may be needed for different scenarios.

   .Link 

#>

param (

[switch] 
$Setup,

[switch] 
$RunAnalyze,

[switch]
$Analyze

)

Add-PSSnapin microsoft.hpc

# Setup on all HN, DB, BNs, CNs

[string] $headnode = $env:CCP_SCHEDULER
[string] $schedulerDBString = (gi HKLM:\SOFTWARE\Microsoft\HPC\Security).GetValue("SchedulerDbConnectionString")
$schedulerDBStringItems = $schedulerDBString.Split('=;',[System.StringSplitOptions]::RemoveEmptyEntries)
$dbItems = $schedulerDBStringItems[1].Split('\',[System.StringSplitOptions]::RemoveEmptyEntries)
if ($dbItems.Count -eq 2)
{
  $dbServer = $dbItems[0]
  $dbInstance = "MSSQL`$$($dbItems[1])"
}
elseif ($dbItems.Count -eq 1)
{
  $dbServer = $dbItems[0]
  $dbInstance = "SQLServer"
}
else
{
  write-host "Faied to obtain DB server and instance from SchedulerDbConnectionString : $schedulerDBString." -ForegroundColor Red
  return
}
$computenodes = @(Get-HpcNode -GroupName computenodes -HealthState OK -ErrorAction SilentlyContinue).NetBiosName
$onlineBrokernodes = @(Get-HpcNode -GroupName wcfbrokernodes -State Online -HealthState OK -ErrorAction SilentlyContinue).NetBiosName
$onlineComputenodes = @(Get-HpcNode -GroupName computenodes -State Online -HealthState OK -ErrorAction SilentlyContinue).NetBiosName
$offlineComputenodes = @(Get-HpcNode -GroupName computenodes -State Offline -HealthState OK -ErrorAction SilentlyContinue).NetBiosName

### only setup and monitor perf counters on the selected compute nodes
$selectedComputenodes = $onlineComputenodes # @()

[bool] $localDB = [string]::Equals(".", $dbServer, [StringComparison]::InvariantCultureIgnoreCase)
[string] $currentDir = $PSScriptRoot;
$collectLogPath = "$currentDir\CollectedLogs"
$resultFile = 'AnalysisResult.txt'
$resultHtmFile = 'AnalysisReport.htm'

# analyze result function

[xml] $reportTemplateXML ='<html><head><meta http-equiv="content-type" content="text/html; charset=gb2312" /><meta name="ProgId" content="Word.Document" /><meta name="Generator" content="Microsoft Word 15" /><meta name="Originator" content="Microsoft Word 15" /></head><body lang="en-us" link="#0563C1" vlink="#954F72"><div class="WordSection1"><h2><span lang="EN" style="color:#5B9BD5">HPC Pack Cluster Performance Analysis Report</span></h2><p class="MsoNormal"><span lang="EN"></span></p></div></body></html>'
$divNode = $reportTemplateXML.SelectSingleNode("/html/body/div")
$docFrag = $reportTemplateXML.CreateDocumentFragment()
$NodenameXMLString='<h2><span lang="EN-US">NodeName</span></h2>'
$ReturnLineXMLString='<p class="MsoNormal"><span lang="EN" ></span></p>'
$TableXMLString='<table title="NodeName" class="MsoTableGridLight" border="1" cellspacing="0" cellpadding="0" style="border-collapse:collapse;border:none;"></table>'
$RowXMLString='<tr><td width="670" valign="top" style="width:502.85pt;border:solid #BFBFBF 1.0pt;padding:0cm 5.4pt 0cm 5.4pt"><p class="MsoNormal"><span lang="EN-US">CounterName</span></p></td><td width="94" valign="top" style="width:70.85pt;border:solid #BFBFBF 1.0pt;padding:0cm 5.4pt 0cm 5.4pt"><p class="MsoNormal"><span lang="EN-US"><a href="CounterTxtFilePath">.Txt</a><a href="CounterBlgFilePath">.Blg</a></span></p></td></tr>'
$OutputRowXMLString='<tr><td width="800" valign="top" style="width:800.85pt;border:solid #BFBFBF 1.0pt;padding:0cm 5.4pt 0cm 5.4pt"><p class="MsoNormal"><span lang="EN-US"><a href="OutputTxtFilePath">OutputError</a></span></p></td></tr>'

Function Analyze-Results
{
  param ([string]$xmlFilePath, [string]$blgFilePath, [string]$resultFilePath)

  $blgFilePath >> $resultFilePath

  if (-not (Test-Path $xmlFilePath))
  {
    write-host "Error analyzing results: xml file $xmlFilePath doesn't exist." -ForegroundColor Yellow
    return
  }

  if (-not (Test-Path $blgFilePath))
  {
    write-host "Error analyzing results: blg file $blgFilePath doesn't exist." -ForegroundColor Yellow
    return
  }

  # convert blg file to csv file

  $csvFilePath = "$blgFilePath.csv"

  relog $blgFilePath -f csv -o $csvFilePath -y

  $xmlDoc = [xml](Get-Content $xmlFilePath)
  $setValues = $xmlDoc.SelectNodes("//Counter[@MinValue or @MaxValue]")
  $csvContent = @(Get-Content $csvFilePath)
  $counterNames = $csvContent[0].Split('",', [StringSplitOptions]::RemoveEmptyEntries)

  $minPositionValues = @{}
  $maxPositionValues = @{}
  $minPositionNames = @{}
  $maxPositionNames = @{}

  $warningMessages = @{}
  $warningIndexes= New-Object System.Collections.ArrayList

  $i=0
  foreach ($name in $counterNames)
  {
    foreach ($value in $setValues)
    {
      if ($name.EndsWith($value.InnerText) -or ($name -like "*$($value.InnerText)"))
      {
        if ($value.MinValue -ne $null -and $value.MinValue -ne "")
        {
          $minPositionValues.$i = [double] $value.MinValue
          $minPositionNames.$i = $name
         }

        if ($value.MaxValue -ne $null -and $value.MaxValue -ne "")
        {
         $maxPositionValues.$i = [double] $value.MaxValue
         $maxPositionNames.$i = $name
        }

        break
      }
    }

    $i++

  }

  for($l=1; $l -lt $csvContent.Length; $l++)
  {
    $records = $csvContent[$l].Split('",', [StringSplitOptions]::RemoveEmptyEntries)
  
    # check min values
    foreach ($k in $minPositionValues.Keys)
    {
      if ($records[$k] -ne " " -and ([double] $records[$k]) -lt $minPositionValues[$k])
      {
        $warningString = "$($minPositionNames[$k]):$($records[0]):$($records[$k]) < $($minPositionValues[$k])"
        Write-Host $warningString -ForegroundColor Yellow
        $warningMessages.$($minPositionNames[$k]) += ,$warningString
        if (-not $warningIndexes.Contains($minPositionNames[$k]))
        {
          $warningIndexes.Add($minPositionNames[$k])
        }
      }
    }

    # check max values
    foreach ($k in $maxPositionValues.Keys)
    {
      if ($records[$k] -ne " " -and ([double] $records[$k]) -gt $maxPositionValues[$k])
      {
        $warningString = "$($maxPositionNames[$k]):$($records[0]):$($records[$k]) > $($maxPositionValues[$k])"
        Write-Host $warningString -ForegroundColor Yellow
        $warningMessages.$($maxPositionNames[$k]) += ,$warningString
        if (-not $warningIndexes.Contains($maxPositionNames[$k]))
        {
          $warningIndexes.Add($maxPositionNames[$k])
        }
      }
    }
  }

  # generate new blg files for the warning indexes
  # generate report htm file

  foreach ($index in $warningIndexes)
  {
    $indexFileString = [string]::Join('_',$index.Split('\:|/', [StringSplitOptions]::RemoveEmptyEntries))
    $resultFileName = "$blgFilePath-$indexFileString"
    relog $blgFilePath -c $index -o "$resultFileName.blg" -y
    $warningMessages.$index > "$resultFileName.txt"
    $resultFileName >> $resultFilePath

    $nodeNameString = ""
    # C:\Users\HpcPerfRun\CollectedLogs\PerfLogs\CREDITBN-001\HPC.BN.blg__CREDITBN-001_Process(HpcBroker)_Handle%20Count
    if ($resultFileName -match '(?<=PerfLogs\\).*(?=\\)')
    {
      $nodeNameString = $Matches[0].ToUpperInvariant()
    }

    $tableXMLNode = $reportTemplateXML.SelectSingleNode("//table[@title='$nodeNameString']")

    if ($tableXMLNode -eq $null)
    {
      # add the head line, table and return lines
      $docFrag.InnerXml = $NodenameXMLString -replace 'NodeName', $nodeNameString
      $divNode.AppendChild($docFrag) | Out-Null
      $docFrag.InnerXml = $TableXMLString -replace 'NodeName', $nodeNameString
      $divNode.AppendChild($docFrag) | Out-Null
      $docFrag.InnerXml = $ReturnLineXMLString
      $divNode.AppendChild($docFrag) | Out-Null
      $divNode.AppendChild($docFrag) | Out-Null
    }
    else
    {
      # add the row
      $docFrag.InnerXml = $RowXMLString.Replace('CounterName',$indexFileString).Replace('CounterTxtFilePath', "$resultFileName.txt").Replace('CounterBlgFilePath', "$resultFileName.blg")
      $tableXMLNode.AppendChild($docFrag) | Out-Null
    }
  }
}

if ($Setup)
{
  # replace the RootPath in the counter xml files with the current path
  (Get-Content HPC.SYS.xml) | % { if ($_ -match "<RootPath>.*</RootPath>") { $_ -replace "(?<=>).*(?=\\PerfLogs)", $currentDir } else { $_ } } | Set-Content HPC.SYS.xml
  (Get-Content HPC.HN.xml) | % { if ($_ -match "<RootPath>.*</RootPath>") { $_ -replace "(?<=>).*(?=\\PerfLogs)", $currentDir } else { $_ } } | Set-Content HPC.HN.xml
  (Get-Content HPC.DB.xml) | % { if ($_ -match "<RootPath>.*</RootPath>") { $_ -replace "(?<=>).*(?=\\PerfLogs)", $currentDir } else { $_ } } | Set-Content HPC.DB.xml
  (Get-Content HPC.BN.xml) | % { if ($_ -match "<RootPath>.*</RootPath>") { $_ -replace "(?<=>).*(?=\\PerfLogs)", $currentDir } else { $_ } } | Set-Content HPC.BN.xml
  (Get-Content HPC.CN.xml) | % { if ($_ -match "<RootPath>.*</RootPath>") { $_ -replace "(?<=>).*(?=\\PerfLogs)", $currentDir } else { $_ } } | Set-Content HPC.CN.xml
  
  # alter db instance name in the xml file if it is not default COMPUTECLUSTER
  (Get-Content HPC.DB.xml) | % { if ($_ -match '>\\(MSSQL|SQLServer)') { $_ -replace "(?<=>\\).*(?=:)", $dbInstance } else { $_ } } | Set-Content HPC.DB.xml

  # enable hn perf counters on the head node
  logman stop HPC.SYS
  logman stop HPC.HN
  logman delete HPC.SYS
  logman delete HPC.HN
  logman import HPC.SYS -xml HPC.SYS.xml
  logman import HPC.HN -xml HPC.HN.xml

  # deploy the bits to the DB server if not local
  if (-not $localDB)
  {
    $dbFolder = "\\$dbServer\$($currentDir.Replace(':', '$'))"
    if (-not (Test-Path $dbFolder))
    {
      New-Item -ItemType Directory -Path $dbFolder -ErrorAction Stop
    }
    # robocopy the bits
    robocopy $currentDir $dbFolder
    
    # enable db perf counters on the remote DB server
    Invoke-Command -ComputerName $dbServer -ScriptBlock { cd $($args[0]); logman stop HPC.SYS; logman stop HPC.DB; logman delete HPC.SYS; logman delete HPC.DB; logman import HPC.SYS -xml HPC.SYS.xml; logman import HPC.DB -xml HPC.DB.xml } -ArgumentList $currentDir
  }
  else
  {
    # enable db perf counters on the local head node
    logman stop HPC.DB
    logman delete HPC.DB
    logman import HPC.DB -xml HPC.DB.xml
  }

  # deploy the bits to the broker nodes
  foreach ($bn in $onlineBrokernodes)
  {
    $bnFolder = "\\$bn\$($currentDir.Replace(':', '$'))"
    if (-not (Test-Path $bnFolder))
    {
      New-Item -ItemType Directory -Path $bnFolder -ErrorAction Stop
    }
    robocopy $currentDir $bnFolder
  }
  
  # enable the bn perf counters on the broker nodes
  if ($onlineBrokernodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $onlineBrokernodes)) "cd $currentDir & logman stop HPC.SYS & logman stop HPC.BN & logman delete HPC.SYS & logman delete HPC.BN & logman import HPC.SYS -xml HPC.SYS.xml & logman import HPC.BN -xml HPC.BN.xml"
  }

  ### deploy the bits to all online compute nodes using clusrun
  $hnFolder = "\\$headnode\$($currentDir.Replace(':', '$'))"
  clusrun /nodegroup:computenodes /nodestate:online robocopy $hnFolder $currentDir
  
  # enable the cn perf counters on the selected compute nodes
  if ($selectedComputenodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $selectedComputenodes)) "cd $currentDir & logman stop HPC.SYS & logman stop HPC.CN & logman delete HPC.SYS & logman delete HPC.CN & logman import HPC.SYS -xml HPC.SYS.xml & logman import HPC.CN -xml HPC.CN.xml"
  }
}

if ($RunAnalyze)
{
  # restart all the perf counter monitors, clean up the logs
  logman stop HPC.SYS; logman stop HPC.HN

  if (-not $localDB)
  {
    Invoke-Command -ComputerName $dbServer -ScriptBlock { logman stop HPC.SYS; logman stop HPC.DB; ri -Path "$($args[0])\PerfLogs\HPC.*" -Recurse -Force -ErrorAction SilentlyContinue
} -ArgumentList $currentDir
  }
  else
  {
    logman stop HPC.DB
  }

  ri -Path $currentDir\PerfLogs\HPC.* -Recurse -Force -ErrorAction SilentlyContinue

  if ($onlineBrokernodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $onlineBrokernodes)) "cd $currentDir & logman stop HPC.SYS & logman stop HPC.BN & rd /s /q $currentDir\PerfLogs"
  }

  if ($selectedComputenodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $selectedComputenodes)) "cd $currentDir & logman stop HPC.SYS & logman stop HPC.CN & rd /s /q $currentDir\PerfLogs"
  }

  logman start HPC.SYS; logman start HPC.HN
  if (-not $localDB)
  {
    Invoke-Command -ComputerName $dbServer -ScriptBlock { logman start HPC.SYS; logman start HPC.DB }
  }
  else
  {
    logman start HPC.DB
  }

  if ($onlineBrokernodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $onlineBrokernodes)) "logman start HPC.SYS & logman start HPC.BN "
  }

  if ($selectedComputenodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $selectedComputenodes)) "logman start HPC.SYS & logman start HPC.CN "
  }

  ### start the specific workload on all online compute nodes

  sleep 30
  cmd /c start clusrun /nodegroup:computenodes /nodestate:online "powershell -command `"`"& { cd $currentDir; .\Run_SOA_Echo.ps1 } `"`""

  ### wait for all the jobs done
  sleep 15
  $activeJobs = @(Get-HpcJob -ErrorAction SilentlyContinue)
  while ($activeJobs.Count -gt 0)
  {
    sleep 15
    $activeJobs = @(Get-HpcJob -ErrorAction SilentlyContinue)
  }

  ### stop all the perf counter monitors

  sleep 30
  logman stop HPC.SYS; logman stop HPC.HN

  if (-not $localDB)
  {
    Invoke-Command -ComputerName $dbServer -ScriptBlock { logman stop HPC.SYS; logman stop HPC.DB }
  }
  else
  {
    logman stop HPC.DB
  }

  if ($onlineBrokernodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $onlineBrokernodes)) "logman stop HPC.SYS & logman stop HPC.BN "
  }

  if ($selectedComputenodes.Length -gt 0)
  {
    clusrun /nodes:$([string]::Join(',', $selectedComputenodes)) "logman stop HPC.SYS & logman stop HPC.CN "
  }

  # collect the perf counters from all the nodes

  if (Test-Path $collectLogPath)
  {
    ri -Path $collectLogPath -Recurse -Force
    mkdir $collectLogPath
  }
  else
  {
    mkdir $collectLogPath
  }

  if (-not (Test-Path $collectLogPath\PerfLogs\$headnode))
  {
    mkdir $collectLogPath\PerfLogs\$headnode
  }

  gci -Path $currentDir\PerfLogs -Filter *.blg -Recurse | mi -Destination $collectLogPath\PerfLogs\$headnode -Force

  if (-not $localDB)
  {
    if (-not (Test-Path $collectLogPath\PerfLogs\$dbServer))
    {
      mkdir $collectLogPath\PerfLogs\$dbServer
    }

    gci -Path \\$dbServer\$($currentDir.Replace(':', '$'))\PerfLogs -Filter *.blg -Recurse | mi -Destination $collectLogPath\PerfLogs\$dbServer -Force
  }

  foreach ($bn in $onlineBrokernodes)
  {
    if (-not (Test-Path $collectLogPath\PerfLogs\$bn))
    {
      mkdir $collectLogPath\PerfLogs\$bn
    }

    gci -Path \\$bn\$($currentDir.Replace(':', '$'))\PerfLogs -Filter *.blg -Recurse | mi -Destination $collectLogPath\PerfLogs\$bn -Force
  }

  foreach ($cn in $selectedComputenodes)
  {
    if (-not (Test-Path $collectLogPath\PerfLogs\$cn))
    {
      mkdir $collectLogPath\PerfLogs\$cn
    }

    gci -Path \\$cn\$($currentDir.Replace(':', '$'))\PerfLogs -Filter *.blg -Recurse | mi -Destination $collectLogPath\PerfLogs\$cn -Force
  }

  foreach ($cn in $onlineComputenodes)
  {
    if (-not (Test-Path $collectLogPath\RunLogs\$cn))
    {
      mkdir $collectLogPath\RunLogs\$cn
    }
  
  gci -Path \\$cn\$($currentDir.Replace(':', '$'))\RunLogs -Filter *.cs.txt -Recurse | mi -Destination $collectLogPath\RunLogs\$cn -Force
  }

} # if RunAnalyze


if ($RunAnalyze -or $Analyze)
{

  'Analyze Results' > $resultFile

  # analyze the perf counters and generate the report

  $blgFiles = @( gci -Path $collectLogPath\PerfLogs -Filter *.blg -Recurse -ErrorAction SilentlyContinue)

  foreach ($blgFile in $blgFiles)
  {
    Analyze-Results -xmlFilePath "$($blgFile.Name.Replace('.blg', '.xml'))" -blgFilePath $blgFile.FullName -resultFilePath $resultFile
  }
  
  # analyze the workload outputs
  $docFrag.InnerXml = $NodenameXMLString -replace 'NodeName', 'OutputFiles'
  $divNode.AppendChild($docFrag) | Out-Null
  $docFrag.InnerXml = $TableXMLString -replace 'NodeName', 'OutputFiles'
  $divNode.AppendChild($docFrag) | Out-Null
  $docFrag.InnerXml = $ReturnLineXMLString
  $divNode.AppendChild($docFrag) | Out-Null
  $divNode.AppendChild($docFrag) | Out-Null
  $tableXMLNode = $reportTemplateXML.SelectSingleNode("//table[@title='OutputFiles']")

  'Output Results' >> $resultFile
  
  $outputTxtFiles = @( gci -Path $collectLogPath\RunLogs -Filter *.txt -Recurse -ErrorAction SilentlyContinue)

  foreach ($txtFile in $outputTxtFiles)
  {
    $outputContent = Get-Content -Path $txtFile.FullName
    foreach($outputLine in $outputContent)
    {
      ### check if there is any word 'error' in the output files
      if($outputLine -like '*error*')
      {
        $outputErrorLine = "$($txtFile.FullName)--$outputLine"
        $outputErrorLine >> $resultFile
        $docFrag.InnerXml = $OutputRowXMLString.Replace('OutputTxtFilePath', "$($txtFile.FullName)").Replace('OutputError', $outputErrorLine)
        $tableXMLNode.AppendChild($docFrag) | Out-Null
      }
    }
  }

  $reportTemplateXML.Save("$currentDir\\$resultHtmFile")

} # if RunAnalyze or Analyze

# print the help info

if (-not $Setup -and -not $RunAnalyze -and -not $Analyze)
{
"Usage: "
"1. To deploy the bits and setup perf counters run: .\Analyze-HpcCluster.ps1 -Setup"
"2. To run the workload, collect the perf counters and analyze the results run: .\Analyze-HpcCluster.ps1 -RunAnalyze"
"3. To just analyze the collected results run: .\Analyze-HpcCluster.ps1 -Analyze"
}
