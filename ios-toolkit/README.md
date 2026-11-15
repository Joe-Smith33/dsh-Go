# DSH-Go iOS 侧载工具包（非官方）

这个目录放在 **fork** 里，只装"把 DSH-Go 打包成 iOS 应用并装到 iPhone / iPad"要用的脚本和说明，**不改动上游一行代码**。

> 上游项目：<https://github.com/ccch1mneyyy/dsh-go>（作者 ccch1mneyyy，AGPL-3.0）
> 本目录的所有脚本同样以 **AGPL-3.0** 发布。这不是官方发布物，也不是官方支持的分支。

---

## 它解决什么问题

DSH-Go 原本只有 Android 包（里面塞了一整套 Ubuntu + Node + proot，在手机上直接跑）。iOS 上没有 proot，这条路走不通。本工具包做的是：

1. **在 GitHub Actions 的 macOS runner 上，把上游的 `feat/ios-foundation` 分支编成 ipa** —— 不签名，因为签名必须在有设备的那台机器上做；
2. 提供 **Windows 侧的一整套配套**：把电脑变成 App 可以连的"远程主机"（SSH + `dsh web`），以及防止 `dsh web` 在后台堆积的清理脚本；
3. 给出 **装到真机** 的完整步骤（iloader 官方推荐路径）。

两种用法，按需选：

| 模式 | 需要什么 | 特点 |
|---|---|---|
| **本机模式** | 一个 DeepSeek API Key | 完全离线跑在手机上，App 内自带 NodeMobile 引擎（约 160 MB 解压后） |
| **远程模式** | 电脑开着、能 SSH 到 | 手机上操作，算力在电脑上；不用在手机里塞引擎，包更小 |

---

## 快速开始

### 1. 云端编出 ipa

仓库 → **Actions** → **iOS ipa (unsigned)** → **Run workflow**

| 字段 | 填什么 |
|---|---|
| Use workflow from | `main` |
| Upstream branch or tag to build | `feat/ios-foundation`（默认） |
| Embed the on-device engine | 想要**本机模式**就勾上；只要远程模式就不勾 |

跑完在运行页底部下载 artifact：

- 勾了引擎 → `dsh-go-ipa-engine`（约 213 MB，含两个包）
- 没勾 → `dsh-go-ipa-remote`（约 64 MB）

artifact 里有 `dsh-go-*-unsigned.ipa` 和 `dsh-go-*-unsigned-noshare.ipa` 两个文件，**免费 Apple ID 优先用 noshare 那个**（不含分享扩展，避免"扩展缺少 provisioning profile"的签名失败）。

### 2. 装到 iPhone / iPad

Windows 上用 [iloader](https://iloader.app)（SideStore 官方推荐的安装器，能正确处理 App 扩展）：

1. 装好 iTunes（Apple 官网版，不是 Microsoft Store 版）
2. iloader 登录 Apple ID → 点设备卡片选中 → **Import IPA** → 选上面那个 ipa
3. 手机上：设置 → 通用 → VPN 与设备管理 → 信任开发者证书
4. 手机上：设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启 → 确认「打开」

> iOS 16 起，开发者签名的 App **必须**打开开发者模式才能运行，这一步不能跳。

### 3. 电脑侧（只有远程模式需要）

见 [`HANDOFF.md`](HANDOFF.md) 的第三、四、五节。要点：

- 装 **OpenSSH Server**（`Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`）
- 装 **PortableGit 并解包到无空格路径**（`D:\gitportable`），把 sshd 的 `DefaultShell` 指到 `D:\gitportable\bin\bash.exe`
  —— App 的引导脚本是 **POSIX sh**，用 `cmd.exe` 当默认 shell 会直接失败
- 建一个 `dsh` 垫片（见 HANDOFF），让 SSH 会话里能直接跑 `dsh web`

---

## 文件清单

| 路径 | 作用 |
|---|---|
| `.github/workflows/ios-ipa.yml` | 云端构建 + 打包 ipa 的 workflow（仓库根目录那份才是生效的） |
| [`workflow/ios-ipa.yml`](workflow/ios-ipa.yml) | 同一份的只读副本，方便对照 |
| [`scripts/package-ipa.sh`](scripts/package-ipa.sh) | 本地把 `Runner.app` 打成 ipa（含体积/框架体检），workflow 里已内联，这里留作参考 |
| [`scripts/run-host.ps1`](scripts/run-host.ps1) | 在 Windows 上起一个局域网可访问的 `dsh web`，并把明文 token 打出来 |
| [`scripts/clean-dsh-web.ps1`](scripts/clean-dsh-web.ps1) | 清理 App 反复连接时遗留的 `dsh web` 进程（实测一次能堆到 47 个 / 11 GB） |
| [`scripts/test-deepseek-key.ps1`](scripts/test-deepseek-key.ps1) | 不落盘地验证一个 DeepSeek API Key 是否可用 |
| [`HANDOFF.md`](HANDOFF.md) | 完整交接文档：踩过的每个坑、为什么这么选、哪些已验证哪些没有 |

---

## 已知限制（都是苹果或上游的硬限制，不是脚本的问题）

- **免费 Apple ID**：证书 7 天过期、10 个 App ID、设备数量有上限；不能推送通知；App Group 通常注册不了
- **Network Extension（VPN 类）权限只给付费账号** —— 所以 Tailscale / ZeroTier / WireGuard 这类客户端**即使侧载也跑不起来**
- **iOS 没有 proot**，本机模式走的是 NodeMobile（`--jitless`），不能执行任意原生二进制
- 首次冷启动解压引擎约 160 MB，会比较慢
- 未装可选 Linux 层时，`bash` 类命令由 just-bash 模拟，没有真正的 Linux / Python

---

## 合规说明

- 上游代码以 **AGPL-3.0** 发布；`sdk/` 与 `examples/` 是 MIT。本目录脚本同为 AGPL-3.0。
- `DSH Go` 这个名称、Deepy / 鲸娘等素材**不在** AGPL 授权范围内（见上游 `ASSETS.md`），再分发时请自行替换。
- 上游 README 里"改造前先联系作者、fork 需标注来源"是**协作请求**，不是许可证的附加限制；但既然是学生作业，建议照做，并在演示时说明清楚：

> 本作业基于开源项目 <https://github.com/ccch1mneyyy/dsh-go>（AGPL-3.0）。
> 本人完成的是：iOS 构建流水线、Windows 远程主机配套、真机安装验证与排错。

---

## 明天演示可以这么走

1. **30 秒**：手机亮屏 → DSH-Go → **本机模式** → 让它列一下工作区文件（证明引擎真的跑在手机上）
2. **60 秒**：切到 **远程模式** → 展示连接过程（SSH → 启动 `dsh web` → 隧道 → 登录）→ 让它在电脑上读一个文件
3. **30 秒**：打开 Actions 运行记录 → 展示 artifact 大小与两个包的差别
4. **30 秒**：讲清哪些是上游的、哪些是自己做的，以及三个踩坑（proot 为什么不行 / 免费证书 7 天 / Network Extension 权限）
