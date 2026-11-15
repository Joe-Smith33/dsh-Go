#Requires -Version 5.1
<#
.SYNOPSIS
  Kills stale `dsh web --host 127.0.0.1 --port 0` instances started by the phone app's SSH bootstrap.

.DESCRIPTION
  The DSH-Go app starts `dsh web --port 0` over SSH for every connection attempt and never
  terminates the previous one, so instances pile up (~240 MB each). Observed: 47 instances
  and 11.2 GB after ~2.5 hours of retrying.

  This script keeps:
    - the newest instance, and
    - any instance that currently has an ESTABLISHED connection (i.e. the one the app is using),
  and kills everything else.

  Run it manually, or register it as a scheduled task every 30 minutes (see -InstallTask).

.PARAMETER KeepNewest
  How many of the newest instances to always keep (default 1). Use 0 to rely on connections only.

.PARAMETER MinAgeMinutes
  Only kill instances older than this many minutes (default 0 = do not care).

.PARAMETER DryRun
  Report what would be killed and exit.

.PARAMETER InstallTask
  Register a scheduled task that runs this script every 30 minutes as the current user.

.PARAMETER RemoveTask
  Unregister that scheduled task.
#>
[CmdletBinding()]
param(
  [int]$KeepNewest = 1,
  [int]$MinAgeMinutes = 0,
  [switch]$DryRun,
  [switch]$InstallTask,
  [switch]$RemoveTask
)

$ErrorActionPreference = 'Stop'
$TaskName = 'dsh-go-clean-dsh-web'

function Get-WebInstances {
  Get-CimInstance Win32_Process -Filter "Name='DSH NEXT.exe'" |
    Where-Object { $_.CommandLine -match 'desktop-cli\.js' -and $_.CommandLine -match 'web --host 127\.0\.0\.1 --port 0' } |
    ForEach-Object {
      $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
      [pscustomobject]@{
        Pid       = $_.ProcessId
        StartTime = if ($p) { $p.StartTime } else { $null }
        MemoryMB  = if ($p) { [math]::Round($p.WorkingSet64 / 1MB, 1) } else { 0 }
      }
    }
}

function Get-ConnectedPorts {
  # Local ports that a client (the app's SSH tunnel) currently has an established connection to.
  $ports = New-Object System.Collections.Generic.HashSet[int]
  foreach ($line in (netstat -ano)) {
    if ($line -notmatch 'ESTABLISHED') { continue }
    if ($line -match '127\.0\.0\.1:(\d+)\s+127\.0\.0\.1:\d+') { [void]$ports.Add([int]$matches[1]) }
  }
  return $ports
}

function Get-ListeningPortMap {
  $map = @{}
  foreach ($line in (netstat -ano)) {
    if ($line -match '127\.0\.0\.1:(\d+)\s+\S+\s+LISTENING\s+(\d+)') {
      $map[[int]$matches[2]] = [int]$matches[1]
    }
  }
  return $map
}

if ($RemoveTask) {
  schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null
  Write-Host "Removed scheduled task '$TaskName'."
  return
}

if ($InstallTask) {
  $self = $PSCommandPath
  $args = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
  schtasks.exe /Create /TN $TaskName /TR "powershell.exe $args" /SC MINUTE /MO 30 /RL HIGHEST /F | Out-Null
  Write-Host "Installed scheduled task '$TaskName' (every 30 minutes)."
  return
}

$instances = @(Get-WebInstances)
if ($instances.Count -eq 0) {
  Write-Host 'No stale dsh web instances.'
  return
}

$connectedPorts = Get-ConnectedPorts
$listenMap = Get-ListeningPortMap
$now = Get-Date

$keep = New-Object System.Collections.Generic.HashSet[int]
foreach ($inst in ($instances | Where-Object { $_.StartTime } | Sort-Object StartTime -Descending | Select-Object -First $KeepNewest)) {
  [void]$keep.Add([int]$inst.Pid)
}
foreach ($inst in $instances) {
  $port = $listenMap[[int]$inst.Pid]
  if ($port -and $connectedPorts.Contains([int]$port)) { [void]$keep.Add([int]$inst.Pid) }
}

$kill = @()
foreach ($inst in $instances) {
  if ($keep.Contains([int]$inst.Pid)) { continue }
  if ($inst.StartTime -and ((($now - $inst.StartTime).TotalMinutes) -lt $MinAgeMinutes)) { continue }
  $kill += $inst
}

$totalMB = [math]::Round((($instances | Measure-Object MemoryMB -Sum).Sum), 0)
Write-Host ("Instances: {0}  memory: {1} MB  keeping: {2}  killing: {3}" -f $instances.Count, $totalMB, $keep.Count, $kill.Count)
foreach ($inst in $kill) {
  Write-Host ("  kill pid={0} started={1} mem={2}MB" -f $inst.Pid, $inst.StartTime, $inst.MemoryMB)
  if (-not $DryRun) { Stop-Process -Id $inst.Pid -Force -ErrorAction SilentlyContinue }
}
if ($DryRun) { Write-Host '(dry run - nothing killed)' }
