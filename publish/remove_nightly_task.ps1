# Removes the nightly WAI update from the Windows Task Scheduler. See README.md.
#
#   powershell -ExecutionPolicy Bypass -File publish\remove_nightly_task.ps1

param([string]$TaskName = "WAI nightly update")
$ErrorActionPreference = "Stop"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "Removed '$TaskName'"
