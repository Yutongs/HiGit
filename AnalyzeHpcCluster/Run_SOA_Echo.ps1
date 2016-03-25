# SOA Echo sample work load 

param (

[int]
$numberOfClients = 3

)

### update the username
$username = '<username>'
### update the password
$password = '<password>'

$currentDir = $PSScriptRoot;

cd $currentDir

$runlogPath = "$currentDir\RunLogs";

if (Test-Path $runlogPath)
{
  ri -Path $runlogPath -Recurse -Force
  mkdir $runlogPath
}
else
{
  mkdir $runlogPath
}


for($i = 0; $i -lt $numberOfClients; $i++)
{
  cmd /c start cmd /c "`"`"$env:CCP_HOME\Bin\EchoClient.exe`" -h $env:CCP_Scheduler -insecure -max 625 -user $username -pass $password -n 100 > $runlogPath\$i.cs.txt 2>&1`""
}

Sleep 5

$ps= @(Get-Process -Name EchoClient)

while ($ps.Count -gt 0)
{
  Sleep 15
  $ps= @(Get-Process -Name EchoClient)
}
