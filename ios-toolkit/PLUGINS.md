# 让"远程模式"也带上插件

## 问题

DSH 用 **profile** 隔离不同入口。电脑桌面端跑的是 `desktop` profile，手机连上来时 App 在电脑上执行的是：

```
dsh web --host 127.0.0.1 --port 0 --no-open
```

`dsh web` = 启动 **`web` profile**。这个 profile 出厂只有 3 个 bundle：

```
@deepseek-ai/dsh-base
@deepseek-ai/dsh-web-app
@dshworks/dsh-solidworks
```

而桌面的 `desktop` profile 有 18 个。所以手机上看到的是"什么都没有"的那个精简版——不是插件坏了，是**根本没加载**。

## 做法

不用改代码，把插件装进 `web` profile 就行。`dsh plugin` 会把参数原样转给 profile 目录里的 pnpm，**并且自动把新包追加到 `dsh.profile.bundles`**（不用手改 JSON）：

```powershell
# DSH 的 CLI 藏在 app.asar 里，这样调
$cli = 'D:\DSH\DSH NEXT\resources\app.asar\lib\desktop-cli.js'
$exe = 'D:\DSH\DSH NEXT\DSH NEXT.exe'
$env:ELECTRON_RUN_AS_NODE = '1'

& $exe $cli plugin --profile web add `
  '@copylee/dsh-office' '@wxg-prc-cpg/browser-skill-dsh-plugin' billion-context `
  dsh-auth-cookie-guard dsh-computer-use-win dsh-context dsh-image-gen `
  dsh-multitask dsh-ops dsh-plugin-debugging dsh-scrape-webpage dsh-see-now `
  dsh-whale-widget dsh-windows-mcp dshmarket
```

本地目录 / GitHub 源也能装（`file:` 的相对路径是相对 **profile 目录**，不是当前目录，容易踩）：

```powershell
& $exe $cli plugin --profile web add 'dsh-video-eyes@file:C:/Users/<你>/.dsh/video-eyes-src/dsh-video-eyes-1.0.0.tgz'
& $exe $cli plugin --profile web add 'avoid-ai-writing-cn@github:hellogit2021/avoid-ai-writing-cn#<commit>'
```

## 结果（本机实测）

| 项 | 改之前 | 改之后 |
|---|---|---|
| `web` profile bundles | 3 | **20** |
| 启动到打印 token | — | **2.4 秒** |
| 组合后的插件条目（`--dump-config`） | 极少 | 17 个独立条目（billion-context / dsh-image-gen / dshmarket / dsh-scrape-webpage / dsh-see-now / dsh-windows-mcp / dsh-video-eyes / dsh-whale-widget / dsh-multitask / dsh-ops / dsh-context / dsh-computer-use-win / dsh-auth-cookie-guard / dsh-plugin-debugging / avoid-ai-writing-cn …） |

验证启动：

```powershell
& $exe $cli web --host 127.0.0.1 --port 0 --no-open
# 打印：dsh web: http://127.0.0.1:<port>/?token=<43 字符>
```

## 剩下两条无害告警

```
[@wxg-prc-cpg/browser-skill-dsh-plugin] bsk probe failed (spawn bsk ENOENT);
    browser tools will report install guidance until the bsk CLI is available
dsh-multitask: could not prove which DSH install is running, so the optional
    "@deepseek-ai/dsh-tool-subagent-control/list-agents" row was dropped
```

- 第一条：`bsk` 这个 CLI 不在 SSH 会话的 PATH 里，浏览器技能会退化成"告诉你先装 bsk"。想修就把它的 bin 目录加进**机器级** PATH（`setx /M PATH`），SSH 会话才继承。
- 第二条：multitask 认不出宿主版本，少挂一行可选能力，不影响使用。

## 一个必须注意的坑：版本不匹配会被自动禁用

我先装了 `@deepseek-ai/dsh-experimental-terminal-bundle@0.2.1-alpha.2`，启动时被优雅地拒绝了：

```
dsh: disabling profile plugin row "pty":
  Plugin @deepseek-ai/dsh-terminal@0.2.1-alpha.2 is incompatible with dsh 0.2.2-rc.3
```

DSH 的做法是**禁用而不是崩溃**，所以这个插件装了等于没装。要装终端类插件，必须选和运行时不版本锁定的那份（`dsh --version` 看当前版本）。发现这种日志，直接：

```powershell
& $exe $cli plugin --profile web remove '@deepseek-ai/dsh-experimental-terminal-bundle'
```

## 注意：这只影响"远程模式"

App 的**本机模式**跑的是打进 ipa 里的整套运行时（`dsh-runtime/runtime.zip`），profile 跟着包走，改电脑上的 profile 对它没影响。想让本机模式也带插件，得在构建时把插件打进 `app/ios/Engine/`，属于另一件事。

## 回滚

改动前已备份：`%USERPROFILE%\.dsh\profiles\web.bak-<日期>`。要还原就把 `web` 删掉、把备份改名回来。
