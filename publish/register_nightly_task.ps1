# Registers the nightly WAI update in the Windows Task Scheduler. See README.md.
#
#   powershell -ExecutionPolicy Bypass -File publish\register_nightly_task.ps1
#   powershell -ExecutionPolicy Bypass -File publish\register_nightly_task.ps1 -At 03:15
#
# Asks for your Windows password: the task runs whether you are logged on or not.

param(
  [string]$At = "02:30",
  [string]$TaskName = "WAI nightly update",
  [string]$Rscript = ""
)
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo "run_nightly.R"))) { throw "run_nightly.R not found in $repo" }

if (-not $Rscript) {
  $found = Get-ChildItem "C:\Program Files\R\R-*\bin\x64\Rscript.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.FullName -replace '.*\\R-([0-9.]+)\\.*', '$1') } | Select-Object -Last 1
  if (-not $found) { throw "Rscript.exe not found; pass -Rscript <full path>" }
  $Rscript = $found.FullName
}

New-Item -ItemType Directory -Force (Join-Path $repo "dataset\out\logs") | Out-Null

$command = "/c `"`"$Rscript`" run_nightly.R >> dataset\out\logs\nightly_task.log 2>&1`""
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument $command -WorkingDirectory $repo
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)

$credential = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" `
  -Message "Windows password, so the task runs whether you are logged on or not"
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -User $credential.UserName -Password $credential.GetNetworkCredential().Password -Force | Out-Null

Write-Output "Registered '$TaskName': daily at $At, $Rscript run_nightly.R, in $repo"
