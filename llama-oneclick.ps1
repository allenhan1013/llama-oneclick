# =====================================================================
#  llama.cpp 一键启动器  (Windows / PowerShell)
#  自动检测显卡 → 选后端 → 计算参数 → 启动 router mode → 打开浏览器
#  用法：右键「使用 PowerShell 运行」，或者双击配套的 启动.bat
#  GPU 模式：
#    powershell -File llama-oneclick.ps1              (默认 dual 双卡)
#    powershell -File llama-oneclick.ps1 -Mode single (单卡，PRO 4500 留给 ComfyUI)
# =====================================================================

param([ValidateSet("dual","single")][string]$Mode = "dual")

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PORT_PREF  = 8080                 # 首选端口，被占用会自动顺延
$EMBED_PORT = 8099                 # Embedding server 固定端口（Mem0 語意搜尋用）
$MODELS_DIR = Join-Path $PSScriptRoot "models"
# 单次生成上限。必须明显小于 ctx-size，否则上下文先被撑满、这个上限根本没机会生效。
$MAX_PREDICT = 8192

# 深度思考模式（Qwen3 / DeepSeek-R1 这类带 <think> 的模型）
#   off  = 关闭思考，直接出答案（默认，给新手用最省事，也最不容易跑飞）
#   on   = 开启思考
#   auto = 不干预，用模型自己的默认行为
# 注意：开了思考必须放宽生成上限，否则 token 全花在 <think> 里、
#       正文还没开始写就被截断了，表现是"回复空白 / 只有半句话"。
$THINKING = "off"

# YaRN 长上下文外推：0 = 关闭（推荐）。
# 确实需要塞长文档时才填目标长度，比如 65536 / 131072。
# 注意三件事：
#   1) llama.cpp 的 YaRN 是启动时全局生效的，短对话质量也会跟着掉；
#   2) 它只改位置编码，不会让 KV cache 变小 —— 上下文翻 4 倍，KV 也翻 4 倍；
#   3) 有些 GGUF 已经把 YaRN 烤进 metadata 了，启动日志里会打印 rope scaling，
#      那种情况下不用再手动开，重复设置反而会出问题。
$YARN_CTX      = 0
$YARN_ORIG_CTX = 131072            # 模型的原生上下文长度，Qwen3 系列是 131072

function Say($msg, $color = "White") { Write-Host $msg -ForegroundColor $color }

Say ""
Say "  llama.cpp 一键启动器" Cyan
Say "  ---------------------------------------------" DarkGray

# ---------------------------------------------------------------------
# 1. 硬件检测（支持多卡）
# ---------------------------------------------------------------------
$gpuName   = "无独立显卡"
$vramGB    = 0
$vendor    = "cpu"
$allGpus   = @()   # @{Name=...; VRAM_MB=...}

# NVIDIA：nvidia-smi 最准，一次读所有卡
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $lines = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($lines) {
            foreach ($line in $lines) {
                $parts   = $line -split ","
                $gName   = $parts[0].Trim()
                $gVramMB = [int]$parts[1].Trim()
                $allGpus += @{Name=$gName; VRAM_MB=$gVramMB}
            }
            # 第一张卡作为主显示（用于档位判断）
            if ($allGpus.Count -gt 0) {
                $gpuName = $allGpus[0].Name
                $vramGB  = [math]::Round($allGpus[0].VRAM_MB / 1024, 1)
                $vendor  = "cuda"
            }
        }
    } catch { }
}

# AMD / Intel：走注册表读显存（Win32_VideoController 的 AdapterRAM 超过 4G 会溢出，不能用）
if ($vendor -eq "cpu") {
    $cards = Get-CimInstance Win32_VideoController |
             Where-Object { $_.Name -notmatch "Basic Display|Remote|Meta|Parsec|Virtual" }
    foreach ($c in $cards) {
        $n = $c.Name
        if ($n -match "Radeon|AMD|Intel\s+Arc|Intel\(R\)\s+Arc") {
            $gpuName = $n
            $vendor  = "vulkan"   # AMD / Intel 在 Windows 上 Vulkan 后端最省心
            break
        }
    }
    if ($vendor -eq "vulkan") {
        $key = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
        Get-ChildItem $key -ErrorAction SilentlyContinue | ForEach-Object {
            $sz = (Get-ItemProperty $_.PSPath -Name "HardwareInformation.qwMemorySize" -ErrorAction SilentlyContinue)."HardwareInformation.qwMemorySize"
            if ($sz -and ($sz / 1GB) -gt $vramGB) { $vramGB = [math]::Round($sz / 1GB, 1) }
        }
    }
}

$ramGB    = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$cores    = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if (-not $cores) { $cores = [Environment]::ProcessorCount / 2 }
$threads  = [math]::Max(4, [math]::Min($cores, 16))   # 线程数取物理核，封顶 16，再多收益递减

Say ""
Say "  GPU 模式 : $(if ($Mode -eq 'dual') { '双卡 tensor-split（' + $allGpus.Count + ' 张卡合并）' } else { '单卡（4090 专用，PRO 4500 留给 ComfyUI）' })" Green
foreach ($g in $allGpus) {
    Say ("  GPU      : {0}  ({1} GB)" -f $g.Name, [math]::Round($g.VRAM_MB / 1024, 1)) White
}
Say "  内存     : ${ramGB} GB" White
Say "  物理核心 : $cores" White

# ---------------------------------------------------------------------
# 2. 选端口
#    Windows 上 8080 经常落在 Hyper-V / WSL 的保留端口段里（netsh 能查到），
#    这种情况下 bind 会直接失败且报错很难懂，所以先探测再顺延。
# ---------------------------------------------------------------------
$reserved = @()
try {
    $out = & netsh int ipv4 show excludedportrange protocol=tcp 2>$null
    foreach ($l in $out) {
        if ($l -match "^\s*(\d+)\s+(\d+)\s*$") { $reserved += ,@([int]$Matches[1], [int]$Matches[2]) }
    }
} catch { }

function Test-PortFree($p) {
    foreach ($r in $reserved) { if ($p -ge $r[0] -and $p -le $r[1]) { return $false } }
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { return $false }
    return $true
}

$PORT = $null
foreach ($cand in @($PORT_PREF, 8090, 8081, 8188, 11434, 18080)) {
    if (Test-PortFree $cand) { $PORT = $cand; break }
}
if (-not $PORT) { $PORT = 18080 }
if ($PORT -ne $PORT_PREF) { Say ""; Say "  端口 $PORT_PREF 被占用或被系统保留，改用 $PORT" Yellow }

# ---------------------------------------------------------------------
# 3. 确认 llama-server 存在
#    同目录下可能解压过多个版本（CPU 版 / 旧版），不能随手取第一个：
#    优先路径里带 cuda / vulkan 的，再按文件时间取最新。
# ---------------------------------------------------------------------
$cands = @(Get-ChildItem $PSScriptRoot -Recurse -Filter "llama-server.exe" -ErrorAction SilentlyContinue)
if ($cands.Count -gt 0) {
    $exe = ($cands | Sort-Object `
        @{ Expression = { if ($_.FullName -match "cuda|cu1\d|vulkan|hip") { 0 } else { 1 } } }, `
        @{ Expression = { $_.LastWriteTime }; Descending = $true } |
        Select-Object -First 1).FullName
} else {
    $exe = (Get-Command llama-server -ErrorAction SilentlyContinue).Source
}

if (-not $exe) {
    Say ""
    Say "  未找到 llama-server，正在通过 winget 安装…" Yellow
    try {
        winget install llama.cpp --accept-package-agreements --accept-source-agreements
    } catch {
        Say "  winget 失败，改用官方安装脚本 llama.app…" Yellow
        Invoke-RestMethod https://llama.app/install.ps1 | Invoke-Expression
    }
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    $exe = (Get-Command llama-server -ErrorAction SilentlyContinue).Source
}
if (-not $exe) {
    Say "  安装失败。请手动下载 https://github.com/ggml-org/llama.cpp/releases 后重试。" Red
    Read-Host "  按回车退出"; exit 1
}
Say ""
Say "  可执行文件 : $exe" DarkGray

# ---------------------------------------------------------------------
# 4. 探测当前版本支持哪些参数（不同版本参数名会变，探测后再传，避免直接启动失败）
# ---------------------------------------------------------------------
$help = (& $exe --help 2>&1) -join "`n"
function Has($flag) { return $help -match [regex]::Escape($flag) }

if (-not (Has "--models-dir")) {
    Say ""
    Say "  你的 llama.cpp 版本太旧，不支持 router 模式（模型热切换）。" Red
    Say "  请升级：winget upgrade llama.cpp" Yellow
    Read-Host "  按回车退出"; exit 1
}

# Flash Attention：新版语法是 -fa on/off/auto，旧版是纯 flag，要分开处理
$faMode = "none"
if (Has "--flash-attn") {
    if ($help -match "flash-attn.*\[on\|off\|auto\]") { $faMode = "value" } else { $faMode = "flag" }
}

# ---------------------------------------------------------------------
# 5. 按显存档位算参数
#    注意：-ngl / 具体分层交给 llama.cpp 自带的 --fit 自动算，
#    它会在加载前实测显存并自动降层、自动把 MoE 专家权重甩到内存，
#    比人肉试 -ngl 准得多。这里只决定「策略」：上下文多长、KV 要不要压缩。
# ---------------------------------------------------------------------
# 双卡模式用总显存档位，单卡模式用第一张卡
if ($Mode -eq "dual" -and $allGpus.Count -ge 2) {
    $totalMB = 0
    foreach ($g in $allGpus) { $totalMB += $g.VRAM_MB }
    $totalVramGB = [math]::Round($totalMB / 1024, 1)
} else {
    $totalVramGB = $vramGB
}

if ($totalVramGB -ge 48)    { $ctx = 131072; $kvq = $false; $maxModels = 2; $tier = "$totalVramGB GB 双卡（56G+）" }
elseif ($totalVramGB -ge 32) { $ctx = 131072; $kvq = $false; $maxModels = 2; $tier = "$totalVramGB GB（32G+ / 5090 / 专业卡）" }
elseif ($totalVramGB -ge 24) { $ctx = 131072; $kvq = $true;  $maxModels = 1; $tier = "$totalVramGB GB（24G 档 / 4090 / 3090）" }
elseif ($totalVramGB -ge 16) { $ctx = 32768;  $kvq = $true;  $maxModels = 1; $tier = "$totalVramGB GB（16G 档）" }
elseif ($totalVramGB -ge 11) { $ctx = 16384;  $kvq = $true;  $maxModels = 1; $tier = "$totalVramGB GB（12G 档）" }
elseif ($totalVramGB -ge 7)  { $ctx = 8192;   $kvq = $true;  $maxModels = 1; $tier = "$totalVramGB GB（8G 档）" }
elseif ($totalVramGB -ge 4)  { $ctx = 4096;   $kvq = $true;  $maxModels = 1; $tier = "$totalVramGB GB（6G 及以下）" }
else                         { $ctx = 4096;   $kvq = $true;  $maxModels = 1; $tier = "纯 CPU 模式（会比较慢）" }

# 内存不够就别开太长上下文
if ($ramGB -lt 16 -and $ctx -gt 8192) { $ctx = 8192 }

# V-cache 量化必须有 Flash Attention 撑着，没有就只压 K
$kvqV = $kvq -and ($faMode -ne "none")

# YaRN：开了就用它的目标长度覆盖档位算出来的 ctx
$yarnOn = $false
if ($YARN_CTX -gt $YARN_ORIG_CTX) {
    if (Has "--rope-scaling") {
        $yarnOn = $true
        $ctx    = $YARN_CTX
        $yarnScale = [math]::Round($YARN_CTX / $YARN_ORIG_CTX, 2)
        Say ""
        Say "  YaRN 已开启：$YARN_ORIG_CTX → $YARN_CTX（scale $yarnScale）" Yellow
        Say "  KV cache 会同比膨胀，显存不够会大量掉到内存，速度明显下降。" Yellow
        Say "  短对话的质量也会受影响，不需要长上下文时请把 YARN_CTX 改回 0。" Yellow
    } else {
        Say ""
        Say "  本版本不支持 --rope-scaling，YaRN 设置已忽略。" Yellow
    }
}

# 思考模式联动：开了思考就把生成上限抬高，给 <think> 留出空间
if ($THINKING -ne "off" -and $MAX_PREDICT -lt 16384) { $MAX_PREDICT = 16384 }

Say ""
Say "  匹配档位 : $tier" Green
Say "  后端     : $vendor" Green
Say "  端口     : $PORT" Green
Say "  思考模式 : $(switch ($THINKING) { 'off' { '关闭（直接出答案）' } 'on' { '开启' } default { '跟随模型默认' } })" Green
Say "  生成上限 : $MAX_PREDICT tokens" Green

# ---------------------------------------------------------------------
# 6. 模型目录
# ---------------------------------------------------------------------
if (-not (Test-Path $MODELS_DIR)) { New-Item -ItemType Directory -Path $MODELS_DIR | Out-Null }
$ggufs = Get-ChildItem $MODELS_DIR -Recurse -Filter "*.gguf" -ErrorAction SilentlyContinue

Say ""
if ($ggufs.Count -eq 0) {
    Say "  models 文件夹是空的。" Yellow
    Say "  按你的显存，推荐先下这些（放进 models 文件夹即可）：" Yellow
    if     ($totalVramGB -ge 48) { Say "    · Qwen3 70B Instruct  Q4_K_M   （约 40G，双卡刚好）" }
    elseif ($totalVramGB -ge 24) { Say "    · Qwen3 32B Instruct  Q4_K_M   （约 20G）" }
    elseif ($totalVramGB -ge 16) { Say "    · Qwen3 14B Instruct  Q4_K_M   （约 9G）" }
    elseif ($totalVramGB -ge 11) { Say "    · Qwen3 14B Instruct  Q4_K_M   （约 9G）" }
    elseif ($totalVramGB -ge 7)  { Say "    · Qwen3 8B Instruct   Q4_K_M   （约 5G）" }
    else                         { Say "    · Qwen3 4B Instruct   Q4_K_M   （约 2.5G）" }
    Say ""
    Say "  多个 GGUF 分片 / 带 mmproj 的多模态模型，请各自放进一个子文件夹。" DarkGray
    Say "  放好后重新运行本脚本即可。" DarkGray
    Read-Host "  按回车退出"; exit 0
}

Say "  发现 $($ggufs.Count) 个模型：" Green
$ggufs | Select-Object -First 8 | ForEach-Object {
    Say ("    · {0}  ({1} GB)" -f $_.Name, [math]::Round($_.Length / 1GB, 1)) DarkGray
}
if ($ggufs.Count -gt 8) { Say "    · …以及其他 $($ggufs.Count - 8) 个" DarkGray }

# 按模式選默认模型：双卡用 Q6_K（56G 装得下，精度最高），单卡用 Q4_K_M（24G 比较挤）
# dual 模式只加载 Q6_K 一个模型（不扫整个 models 目录），避免 router 自动载入排序靠前的 Q4。
# 优先选 Uncensored 版本（UD- 前缀是另一个量化，不是同一系列）。
$defaultModel = $null
if ($Mode -eq "dual") {
    $defaultModel = $ggufs | Where-Object { $_.Name -match "Q6_K" } | Select-Object -First 1
    if (-not $defaultModel) { $defaultModel = $ggufs | Where-Object { $_.Name -match "Q5_K_M" } | Select-Object -First 1 }
} else {
    # 单卡：优先 Uncensored Q4_K_M（排除 UD- 和 XL 版本）
    $defaultModel = $ggufs | Where-Object { $_.Name -match "Uncensored.*Q4_K_M" -and $_.Name -notmatch "XL" } | Select-Object -First 1
    if (-not $defaultModel) { $defaultModel = $ggufs | Where-Object { $_.Name -match "Q4_K_M" -and $_.Name -notmatch "UD|XL" } | Select-Object -First 1 }
}
if ($defaultModel) {
    Say "  默认模型 : $($defaultModel.Name)（$(if ($Mode -eq 'dual') { '双卡 Q6 高精度' } else { '单卡 Q4 轻量' })）" Green
}

# ---------------------------------------------------------------------
# 7. 读 presets.ini，看 [*] 段里用户自己定了哪些键
#    定过的键 CLI 就不再传，避免两边打架（之前 -c 32768 会盖掉 ini 里的 16384）
# ---------------------------------------------------------------------
$presets    = Join-Path $PSScriptRoot "presets.ini"
$presetKeys = @()
$usePresets = (Test-Path $presets) -and (Has "--models-preset")

if ($usePresets) {
    $inStar = $false
    foreach ($l in (Get-Content $presets -Encoding UTF8)) {
        $t = $l.Trim()
        if ($t -match '^\[(.+)\]$') { $inStar = ($Matches[1] -eq '*'); continue }
        if ($inStar -and $t -match '^([A-Za-z0-9\-_]+)\s*=') { $presetKeys += $Matches[1].ToLower() }
    }
    Say ""
    Say "  已传入 presets.ini（仅用于按模型单独覆盖，通用参数仍以命令行为准）" Green
    Say "  注意：段名必须是模型名，[*] 通配不被支持。" DarkGray
    Say "  启动后看日志里 'Loaded N custom model presets'，N=0 就是格式没对上。" DarkGray
} elseif (Test-Path $presets) {
    Say ""
    Say "  检测到 presets.ini，但你这个版本不支持 --models-preset，已忽略。" Yellow
}

function NotInPreset($k) { return -not ($presetKeys -contains $k.ToLower()) }

# ---------------------------------------------------------------------
# 8. 组装启动参数
#    dual 模式：直接用 --model 指定 Q6_K，不传 --models-dir（避免 router 扫全目录后自动载入 Q4）
#    single 模式：用 --models-dir 扫全部模型，--model 指定 Q4_K_M
# ---------------------------------------------------------------------
if ($Mode -eq "dual" -and $defaultModel) {
    # 双卡：只加载 Q6_K，不扫目录
    $srvArgs = @(
        "--host", "127.0.0.1"
        "--port", "$PORT"
        "-t", "$threads"
        "--model", $defaultModel.FullName
    )
} else {
    # 单卡 / 无默认模型：扫整个目录
    $srvArgs = @(
        "--models-dir", $MODELS_DIR
        "--host", "127.0.0.1"
        "--port", "$PORT"
        "-t", "$threads"
    )
    if ($defaultModel) {
        $srvArgs += @("--model", $defaultModel.FullName)
    }
}

if ($usePresets) { $srvArgs += @("--models-preset", $presets) }

# 开了 YaRN 就必须由 CLI 接管 ctx，否则 ini 里的短 ctx 和外推后的 rope 对不上
# -c 一律由命令行传。
# 之前的版本会因为 presets.ini 里写了 ctx-size 就跳过 -c，但 llama-server 对
# 自定义 preset 文件的段名格式很挑（[*] 通配是不认的，日志会打印
# "Loaded 0 custom model presets"），一旦没读进去，两边都没设，
# 最后跑的是内置默认值。命令行是唯一可靠的路径。
$srvArgs += @("-c", "$ctx")
if ($yarnOn) {
    $srvArgs += @("--rope-scaling", "yarn", "--rope-scale", "$yarnScale")
    if (Has "--yarn-orig-ctx") { $srvArgs += @("--yarn-orig-ctx", "$YARN_ORIG_CTX") }
    Say "  上下文   : $ctx tokens（YaRN 外推）" Green
} else {
    Say "  上下文   : $ctx tokens" Green
}

if (Has "--models-max") { $srvArgs += @("--models-max", "$maxModels") }

# ★ 生成上限：llama-server 默认 --predict -1（无限），模型一旦复读就会把整个
#   上下文吃满、直到 0 remaining 卡死。这里给个硬上限。
#   注意网页端设置里的 max tokens 会覆盖它，两边都要设。
if     (Has "--predict")   { $srvArgs += @("-n", "$MAX_PREDICT") }
elseif (Has "--n-predict") { $srvArgs += @("--n-predict", "$MAX_PREDICT") }

# Flash Attention（顺带让 V-cache 量化真正生效）
if     ($faMode -eq "value") { $srvArgs += @("-fa", "on") }
elseif ($faMode -eq "flag")  { $srvArgs += "-fa" }

# KV 量化
if ($kvq -and (Has "--cache-type-k")) {
    $srvArgs += @("--cache-type-k", "q8_0")
    if ($kvqV) { $srvArgs += @("--cache-type-v", "q8_0") }
}
Say "  KV 缓存  : $(if ($kvq) { if ($kvqV) { 'K+V q8_0 压缩' } else { '仅 K q8_0（无 FA，V 保持 f16）' } } else { 'f16 原精度' })" Green

if (Has "--jinja") { $srvArgs += "--jinja" }          # 正确套用模型自带对话模板 + 工具调用

# 思考模式开关。不同版本的 llama.cpp 实现方式不一样，按优先级探测：
#   1) --reasoning-budget 0   最直接（新版）
#   2) --chat-template-kwargs 走模板变量 enable_thinking
# 两个都没有的话，只能在对话里手动打 /no_think，脚本层面控制不了。
if ($THINKING -eq "off") {
    if (Has "--reasoning-budget") {
        $srvArgs += @("--reasoning-budget", "0")
    } elseif (Has "--chat-template-kwargs") {
        $srvArgs += @("--chat-template-kwargs", '{"enable_thinking":false}')
    } else {
        Say "  本版本无法从服务端关闭思考，请在提问末尾加 /no_think" Yellow
    }
} elseif ($THINKING -eq "on") {
    if (Has "--reasoning-budget") { $srvArgs += @("--reasoning-budget", "-1") }
    # 让思考内容走独立字段，网页端会折叠显示，不跟正文混在一起
    if (Has "--reasoning-format") { $srvArgs += @("--reasoning-format", "auto") }
}

# 采样默认值：Qwen3 官方对两种模式给的是两套推荐值，别混用
if ($THINKING -eq "on") {
    $sTemp = "0.6"; $sTopP = "0.95"; $sPresence = "0.5"   # 思考模式下 presence 给高了会中英文混杂
} else {
    $sTemp = "0.7"; $sTopP = "0.8";  $sPresence = "1.0"   # 非思考模式，presence 主要用来压复读
}
if (Has "--temp")             { $srvArgs += @("--temp", $sTemp) }
if (Has "--top-p")            { $srvArgs += @("--top-p", $sTopP) }
if (Has "--top-k")            { $srvArgs += @("--top-k", "20") }
if (Has "--min-p")            { $srvArgs += @("--min-p", "0") }
if (Has "--presence-penalty") { $srvArgs += @("--presence-penalty", $sPresence) }

# 显存分配：优先用 --fit 自动算；版本不支持就退回全量 offload，别静默变成纯 CPU
if (Has "--fit-target") {
    $srvArgs += @("--fit-target", $(if ($totalVramGB -ge 16) { "2048" } else { "1024" }))
} elseif ($vendor -ne "cpu") {
    $srvArgs += @("-ngl", "99")
    Say "  显存分配 : 本版本无 --fit，已回退 -ngl 99（全量 offload）" Yellow
}

# 双卡 tensor-split：按各卡显存比例分配模型层数
if ($Mode -eq "dual" -and $allGpus.Count -ge 2) {
    # 计算每张卡的权重（按显存 MB 比例，取整数百分比）
    $totalMB = 0
    foreach ($g in $allGpus) { $totalMB += $g.VRAM_MB }
    $weights = @()
    $assigned = 0
    for ($i = 0; $i -lt $allGpus.Count; $i++) {
        if ($i -eq ($allGpus.Count - 1)) {
            # 最后一张卡拿剩余，避免四舍五入误差
            $w = 100 - $assigned
        } else {
            $w = [math]::Round($allGpus[$i].VRAM_MB / $totalMB * 100)
            $assigned += $w
        }
        $weights += $w
    }
    $tsStr = ($weights -join ",")
    if (Has "--tensor-split") {
        $srvArgs += @("--tensor-split", $tsStr)
        Say "  双卡分配 : --tensor-split $tsStr （$($allGpus[0].Name) ${weights[0]}% / $($allGpus[1].Name) ${weights[1]}%）" Green
    }
} elseif ($Mode -eq "single" -and $allGpus.Count -ge 2) {
    # 单卡模式：只跑在第一张卡（4090），用 CUDA_VISIBLE_DEVICES 隐藏第二张
    $env:CUDA_VISIBLE_DEVICES = "0"
    if (Has "--main-gpu") {
        $srvArgs += @("--main-gpu", "0")
    }
    Say "  单卡模式 : 仅使用 $($allGpus[0].Name)（GPU 0），PRO 4500 留给 ComfyUI" Green
}

if ($vendor -eq "cpu" -and (Has "--no-warmup")) { $srvArgs += "--no-warmup" }

Say ""
Say "  启动命令：" DarkGray
Say "  $exe $($srvArgs -join ' ')" DarkGray
Say ""
Say "  正在启动… 浏览器会自动打开 http://127.0.0.1:$PORT" Cyan
Say "  在网页左上角的下拉框里可以随时切换模型，无需重启。" Cyan
Say "  提示：网页右上角设置里把 max tokens 也改成 $MAX_PREDICT，别留 -1。" Yellow
Say "  关闭这个黑窗口即停止服务。" DarkGray
Say ""

# ---------------------------------------------------------------------
# 9. Embedding server（bge-small-zh-v1.5，Mem0 語意搜尋用）
#    CPU-only，不搶顯存，固定 port 8099。
#    如果模型檔案不存在或 port 已被佔（上次沒關乾淨），靜默跳過。
# ---------------------------------------------------------------------
$embedModel = Join-Path $MODELS_DIR "bge-small-zh-v1.5-q8_0.gguf"
if (Test-Path $embedModel) {
    $embedFree = -not (Get-NetTCPConnection -LocalPort $EMBED_PORT -State Listen -ErrorAction SilentlyContinue)
    if ($embedFree) {
        Say "  啟動 embedding server (port $EMBED_PORT, CPU)…" DarkGray
        $embedArgs = @(
            "-m", "`"$embedModel`""
            "--embedding"
            "--pooling", "cls"
            "--port", "$EMBED_PORT"
            "-c", "512"
            "--no-warmup"
            "-ngl", "0"
        )
        $embedLog = Join-Path $PSScriptRoot "embedding-server.log"
        Start-Process -FilePath $exe -ArgumentList ($embedArgs -join " ") `
            -WindowStyle Minimized -RedirectStandardOutput $embedLog -RedirectStandardError "$embedLog.err"
        # 等 embedding server 就緒（最多 30 秒）
        $embedReady = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Seconds 1
            try {
                $c = New-Object Net.Sockets.TcpClient
                $c.Connect("127.0.0.1", $EMBED_PORT)
                $c.Close()
                $embedReady = $true
                break
            } catch { }
        }
        if ($embedReady) {
            Say "  Embedding server 已就緒 (port $EMBED_PORT)" Green
        } else {
            Say "  Embedding server 30秒內未就緒（不影響主 LLM）" Yellow
        }
    } else {
        Say "  Embedding server 已在 port $EMBED_PORT 運行，跳過" DarkGray
    }
} else {
    Say "  未找到 bge-small-zh-v1.5 模型，跳過 embedding server" DarkGray
}

Say ""

# 直接测 TCP 端口，不用 /health —— router 模式下模型没加载时 /health 会返回 503，
# Invoke-WebRequest 会当成异常抛出，浏览器就永远打不开了。
Start-Job -ScriptBlock {
    param($p)
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        try {
            $c = New-Object Net.Sockets.TcpClient
            $c.Connect("127.0.0.1", $p)
            $c.Close()
            Start-Process "http://127.0.0.1:$p"
            break
        } catch { }
    }
} -ArgumentList $PORT | Out-Null

& $exe @srvArgs
