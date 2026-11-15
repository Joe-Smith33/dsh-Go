# Tests a DeepSeek API key against the real endpoint, without the key ever
# being written to disk or to the chat.
#
#   powershell -ExecutionPolicy Bypass -File .\test-deepseek-key.ps1
#
# Paste the sk-... key when prompted (input is hidden).

$ErrorActionPreference = 'Stop'

Write-Host '粘贴你的 DeepSeek API Key（sk- 开头），回车确认。输入不显示。'
$secure = Read-Host -AsSecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
  $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if (-not $key) { Write-Host '没有输入，退出。'; exit 2 }
if ($key -notmatch '^sk-') { Write-Host "注意：这个 key 不是 sk- 开头的（前 3 位：$($key.Substring(0,[Math]::Min(3,$key.Length)))）" }
Write-Host ("key 长度 {0}，前 6 位 {1}…" -f $key.Length, $key.Substring(0, [Math]::Min(6, $key.Length)))

$body = @{
  model    = 'deepseek-chat'
  messages = @(@{ role = 'user'; content = 'ping' })
  max_tokens = 4
  stream   = $false
} | ConvertTo-Json -Depth 5 -Compress

try {
  $r = Invoke-WebRequest -Uri 'https://api.deepseek.com/chat/completions' -Method Post `
    -Headers @{ Authorization = "Bearer $key"; 'Content-Type' = 'application/json' } `
    -Body $body -TimeoutSec 60 -UseBasicParsing
  Write-Host ("HTTP {0}" -f $r.StatusCode)
  Write-Host '回复：' -NoNewline
  ($r.Content | ConvertFrom-Json).choices[0].message.content
  Write-Host ''
  Write-Host '结论：这个 key 可以用。'
  exit 0
} catch {
  $code = $null
  try { $code = $_.Exception.Response.StatusCode.value__ } catch { }
  Write-Host ("请求失败：HTTP {0}" -f $code)
  Write-Host $_.Exception.Message
  try {
    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
    $text = $reader.ReadToEnd()
    if ($text) { Write-Host "响应体：`n$text" }
  } catch { }
  Write-Host '结论：这个 key 被服务端拒绝（无效 / 欠费 / 额度用完 / 不是 DeepSeek 平台的 key）。'
  exit 1
}
