# LLM + ComfyUI 啟動腳本
# 用法：雙擊桌面捷徑，或 powershell -File start-llm-comfy.ps1 [-Mode dual|single]
#   dual   = 雙卡跑 LLM Q6_K（預設，開機自啟用此模式）
#   single = 單卡跑 LLM（4090 Q4），PRO 4500 留給 ComfyUI
#
# 開機行為：
#   - LLM: dual 模式，Q6_K tensor-split 雙卡（Hermes 用）
#   - Embedding server: 自動隨 llama-oneclick.ps1 啟動（port 8099, CPU）
#   - ComfyUI: 不自動啟動（需要時手動開啟，避免搶 PRO 4500 顯存）

param([ValidateSet("dual","single")][string]$Mode = "dual")

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LLAMA_SCRIPT = "D:\LLama-cuda12\llama-oneclick.ps1"
$COMFY_DESKTOP = "D:\Comfy\Comfy Desktop\Comfy Desktop.exe"

Write-Host ""
Write-Host "  ==============================================" Cyan
Write-Host "   LLM + ComfyUI 啟動器" Cyan
Write-Host "  ==============================================" Cyan
Write-Host ""

if ($Mode -eq "dual") {
    Write-Host "  模式: 雙卡 LLM Q6_K（tensor-split，Hermes 用）" Green
    Write-Host "  Embedding: 自動啟動 (port 8099, CPU)" Green
    Write-Host "  ComfyUI: 不自動啟動（需要時手動開啟）" DarkGray
} else {
    Write-Host "  模式: 單卡 LLM（4090）+ ComfyUI（PRO 4500）" Green
}
Write-Host ""

# 1. 啟動 llama-server（獨立視窗，輸出不會混進主視窗）
Write-Host "  [1/2] 啟動 llama-server..." White
$llamaArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$LLAMA_SCRIPT`" -Mode $Mode"
Start-Process powershell -ArgumentList $llamaArgs -WorkingDirectory "D:\LLama-cuda12"

# 等 llama-server 起來（最多 180 秒，Q6 雙卡載入比較慢）
$port = 8080
$ready = $false
for ($i = 0; $i -lt 180; $i++) {
    Start-Sleep -Seconds 1
    foreach ($p in @($port, 8090, 8081, 8188)) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect("127.0.0.1", $p)
            $c.Close()
            $port = $p
            $ready = $true
            break
        } catch { }
    }
    if ($ready) { break }
}

if ($ready) {
    Write-Host "  llama-server 已就緒 (port $port)" Green
} else {
    Write-Host "  llama-server 180秒內未就緒，請檢查是否已有 instance 在跑" Yellow
}

# 等 embedding server（port 8099）
$embedReady = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $c = New-Object Net.Sockets.TcpClient
        $c.Connect("127.0.0.1", 8099)
        $c.Close()
        $embedReady = $true
        break
    } catch { }
}
if ($embedReady) {
    Write-Host "  embedding server 已就緒 (port 8099)" Green
} else {
    Write-Host "  embedding server 未就緒（不影響主 LLM）" Yellow
}

# 2. ComfyUI：只在 single 模式才自動啟動
if ($Mode -eq "single") {
    Write-Host "  [2/2] 啟動 ComfyUI..." White
    # Comfy Desktop 會自己管理 GPU 選擇
    # 如果要用特定 GPU，可以在 ComfyUI 設定裡改
    Start-Process $COMFY_DESKTOP
    Start-Sleep -Seconds 3
    Write-Host "  ComfyUI 已啟動" Green
} else {
    Write-Host "  [2/2] 雙卡模式：ComfyUI 未自動啟動（避免搶顯存）" DarkGray
    Write-Host "  需要時手動開啟 Comfy Desktop" DarkGray
}

Write-Host ""
Write-Host "  完成！" Cyan
Write-Host "  - LLM: http://127.0.0.1:$port" White
Write-Host "  - Embedding: http://127.0.0.1:8099" White
if ($Mode -eq "single") {
    Write-Host "  - ComfyUI: 請看 Comfy Desktop 視窗" White
}
Write-Host ""
Write-Host "  llama-server 在另一個黑視窗跑（關那個視窗才停止 LLM + embedding）。" DarkGray
Write-Host "  此視窗 5 秒後自動關閉..." DarkGray
Start-Sleep -Seconds 5
