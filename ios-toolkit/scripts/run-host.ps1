# run-host.ps1 — 在电脑上起一个"手机能连"的 dsh web（局域网可直接访问）
#
# 背景：DSH NEXT 的图形界面只监听 127.0.0.1，而且日志里的 token 会被打码成
#       `?token=****…`，手机拿不到。本脚本绕开 GUI，直接用打包在 app.asar 里的
#       CLI 起一个独立的 `dsh web`：
#         · 绑到局域网 IP（CLI 拒绝 0.0.0.0，必须写具体地址）
#         · 自己抓 stdout，所以能拿到**明文 token**
#         · 自动加防火墙规则（仅专用网络）
#
# 用法（在 DSH NEXT 开着的情况下执行都可以，两个实例互不干扰）：
#   powershell -ExecutionPolicy Bypass -File run-host.ps1                 # 起服务，打印地址+token
#   powershell -ExecutionPolicy Bypass -File run-host.ps1 -Stop           # 停掉本脚本起的那一个
#   ... -Port 3080        # 端口，默认 3080
#   ... -Bind 172.20.10.5 # 指定绑定的局域网 IP（默认自动挑一个）
#   ... -Foreground       # 前台运行（默认后台 + 写日志文件）
#
# 注意：
#   · 手机上填的地址必须和这里打印的一致；手机与电脑要在同一网络。
#   · 电脑若开着全局 VPN（ZoogVPN 等 TUN），手机可能连不进来，演示时先关。
#   · token 只对这次启动有效，重启会换；别外发。

param(
    [int]$Port = 3080,
    [string]$Bind = '',
    [switch]$Stop,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

$DshExe = 'D:\DSH\DSH NEXT\DSH NEXT.exe'
$DshCli = 'D:\DSH\DSH NEXT\resources\app.asar\lib\desktop-cli.js'
$LogPath = Join-Path $PSScriptRoot 'dsh-web.log'
$PidFile = Join-Path $PSScriptRoot 'dsh-web.pid'
$RuleName = "dsh web LAN ($Port)"

function Get-LanIp {
    if ($Bind) { return $Bind }
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -notlike '127.*' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.PrefixOrigin -ne 'WellKnown'
        }
    if (-not $ips) { throw '找不到可用的局域网 IPv4 地址。' }
    # 优先 iPhone 热点 / 常见内网段
    $preferred = $ips | Where-Object { $_.IPAddress -like '172.20.10.*' }
    if (-not $preferred) { $preferred = $ips | Where-Object { $_.IPAddress -like '192.168.*' } }
    if (-not $preferred) { $preferred = $ips }
    $pick = $preferred | Select-Object -First 1
    Write-Host ("绑定地址: {0}（{1}）" -f $pick.IPAddress, $pick.InterfaceAlias) -ForegroundColor Cyan
    return $pick.IPAddress
}

if ($Stop) {
    if (Test-Path $PidFile) {
        $old = [int](Get-Content $PidFile -Raw).Trim()
        $p = Get-Process -Id $old -ErrorAction SilentlyContinue
        if ($p) { Stop-Process -Id $old -Force; Write-Host "已停止 dsh web（pid $old）" -ForegroundColor Green }
        else { Write-Host "pid $old 已经不在了" -ForegroundColor DarkGray }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    } else { Write-Host '没找到 pid 文件（不是本脚本起的？）' -ForegroundColor Yellow }
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    return
}

$ip = Get-LanIp

# 端口占用先看一下
$busy = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
if ($busy) {
    Write-Host ("端口 {0} 已被占用（pid {1}）。要么先 -Stop，要么换 -Port。" -f $Port, $busy[0].OwningProcess) -ForegroundColor Yellow
    return
}

if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $Port -Profile Private | Out-Null
    Write-Host "已添加防火墙规则：$RuleName（仅专用网络）" -ForegroundColor DarkGray
}

Remove-Item $LogPath -Force -ErrorAction SilentlyContinue
$env:ELECTRON_RUN_AS_NODE = '1'
$argList = @($DshCli, 'web', '--host', $ip, '--port', "$Port", '--no-open')

if ($Foreground) {
    Write-Host "前台运行：Ctrl+C 结束。地址 http://${ip}:${Port}/" -ForegroundColor Cyan
    & $DshExe @argList
    return
}

$proc = Start-Process -FilePath $DshExe -ArgumentList "`"$DshCli`" web --host $ip --port $Port --no-open" `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $LogPath -RedirectStandardError "$LogPath.err"
Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
Write-Host ("已启动 dsh web（pid {0}），等待它打印 token…" -f $proc.Id) -ForegroundColor Cyan

$token = $null
$url = $null
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 700
    if (Test-Path $LogPath) {
        $m = Select-String -Path $LogPath -Pattern 'dsh web: (http://\S+)' -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        if ($m) {
            $url = $m.Matches[0].Groups[1].Value
            $token = ($url -split 'token=')[-1]
            break
        }
    }
    if ($proc.HasExited) { break }
}

if (-not $token) {
    Write-Host '没等到 token。看一下日志：' -ForegroundColor Red
    Get-Content $LogPath -ErrorAction SilentlyContinue | Select-Object -Last 15
    Get-Content "$LogPath.err" -ErrorAction SilentlyContinue | Select-Object -Last 15
    throw 'dsh web 没有正常起来。'
}

Write-Host ''
Write-Host '========================================================' -ForegroundColor Green
Write-Host ' 手机端 dsh-Go 连"远程主机"时填：' -ForegroundColor Green
Write-Host ''
Write-Host ("   地址 / 主机 : http://{0}:{1}/" -f $ip, $Port)
Write-Host ("   令牌 token  : {0}" -f $token)
Write-Host ''
Write-Host ("   一次填全    : {0}" -f $url)
Write-Host '========================================================' -ForegroundColor Green
Write-Host ''
Write-Host '验证（本机自己 curl 一下，应看到 401 无 token / 303 有 token）：' -ForegroundColor DarkGray
Write-Host ("   curl.exe -i --max-time 8 `"http://{0}:{1}/?token={2}`"" -f $ip, $Port, $token) -ForegroundColor DarkGray
Write-Host ''
Write-Host ("停掉： powershell -ExecutionPolicy Bypass -File `"{0}`" -Stop" -f $PSCommandPath) -ForegroundColor DarkGray
Write-Host '提示：演示前把全局 VPN（ZoogVPN 等）关掉，否则手机连不进局域网。' -ForegroundColor Yellow
