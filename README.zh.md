# codEx

[![upstream](https://img.shields.io/badge/upstream-openai%2Fcodex%20rust--v0.164.0-412991?style=flat-square&logo=github&logoColor=white)](https://github.com/openai/codex/tree/rust-v0.164.0)
[![release](https://img.shields.io/github/v/release/NIyueeE/codEx?style=flat-square&label=release&color=2ea44f)](https://github.com/NIyueeE/codEx/releases/latest)
[![license](https://img.shields.io/badge/license-Apache--2.0-003478?style=flat-square)](LICENSE)
[![platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20Windows-0078D6?style=flat-square&logo=linux&logoColor=white)](https://github.com/NIyueeE/codEx/releases/latest)
[![patch queue](https://img.shields.io/badge/patch%20queue-7%20modules-6f42c1?style=flat-square)](#patch-queue-模型)
[![CI](https://img.shields.io/github/actions/workflow/status/NIyueeE/codEx/blocking-ci.yml?branch=main&style=flat-square&label=CI)](https://github.com/NIyueeE/codEx/actions/workflows/blocking-ci.yml)

codEx 是 [openai/codex](https://github.com/openai/codex) 的社区分支,面向 Linux
与 Windows 独立用户保持 CLI 的顺滑体验:更少的组件、默认不进行联网更新检查,
内置的 `codex update` 会从本分支的 release 下载经过校验的二进制。

本仓库采用 **patch-queue 模型**:不复制上游代码树,只保存分支的改动(以
`git format-patch` 补丁系列形式)以及从上游 tag 重建完整 codex 代码树的脚本。
真正的代码在上游;`BASE_TAG` 固定了当前补丁队列所基于的上游 tag(当前为
`rust-v0.164.0`)。

## 从 Release 安装

Linux 独立用户可以用安装脚本安装或更新 codEx:

```sh
curl -fsSL https://raw.githubusercontent.com/NIyueeE/codEx/main/install.sh | sh
```

安装脚本会解析最新的分支 release,下载 `codex-<target>.tar.gz` 及其发布的
sha256 校验和,在改动任何内容之前先校验校验和,然后安装到
`~/.codex/packages/standalone/releases/<version>-<target>/` 下的独立布局,
这样之后 `codex update` 仍能正常工作。随后将 `codex` 链接到
`~/.local/bin`(或 `CODEX_INSTALL_DIR`)。

归档就是上游发布的那种规范 Codex 包:`codex-package.json` 清单与 `bin/`、
`codex-path/rg`、`codex-resources/` 并列。`bin/` 下是 `codex` 入口与
`codex-code-mode-host`、`codex-exec-server` 辅助程序,`codex-resources/`
下是当前平台的沙箱辅助程序(Linux 上为 `bwrap`,Windows 上为
`codex-command-runner` 与 `codex-windows-sandbox-setup`)。`InstallContext`
识别的正是这个布局,`codex app-server daemon` 安装共享后台服务时复制的也是它。

安装脚本只创建 CLI 包。共享后台服务自己的包
(`~/.codex/packages/app-server-daemon/`)由第一次 `codex` 启动时复制 CLI 包
创建,并不是单独的发布资产;因此在首次启动前只看到 `packages/standalone/`
是正常的。

如果 `codex` 以 `the CLI package version does not match its executable` 退出,
说明安装的清单与二进制版本不一致(较旧的 `codex update` 只替换了二进制)。
重新运行一次安装脚本即可:它会替换整个 release 目录。截至 `0.164.0`(含)的
版本仍只带旧的更新器,所以包含修复的第一个版本也要用安装脚本装一次;此后
`codex update` 就会保持整个包完整。

Windows 用户直接从 release 归档安装:下载 `codex-x86_64-pc-windows-msvc.tar.gz`,
对照随附的 `.sha256` 校验后,将该包解压到
[`codex update`](#codex-update-pure-rust-self-update)一节所述的独立安装目录。

### 从 0.155.1 或更早版本升级

截至 `0.155.1`(含)的发布使用的是扁平归档(裸 `codex` 加 `bwrap`)。这类安装
无法用 `codex update` 迁移到包布局:旧二进制会在归档根查找 `codex`,并以
`release archive is missing codex or bwrap` 拒绝新包。

请改为重新运行一次安装脚本 —— 它会把扁平发布目录替换为包发布目录并重新指向
`current`,此后 `codex update` 即可正常工作:

```sh
curl -fsSL https://raw.githubusercontent.com/NIyueeE/codEx/main/install.sh | sh
```

环境变量:

- `CODEX_RELEASE` - 要安装的版本,如 `0.164.0`(默认:`latest`)
- `CODEX_INSTALL_DIR` - `codex` 符号链接目录(默认:`~/.local/bin`)
- `CODEX_HOME` - codex 主目录(默认:`~/.codex`)

## 与上游的差异

codEx 保留了上游 `codex` 的二进制名称和配置格式,可以无缝融入现有工作流,但
改变了周边体验:

- **回滚**:`/rewind` 无需 git 即可撤销对话轮次和/或工作区文件改动。
- **输入**:Esc 不再误触中断;双击可停止正在进行的回复。
- **更新**:`codex update` 是纯 Rust 实现的下载器,带校验和验证;不再依赖
  `curl | sh`、npm 或 brew。
- **隐私**:默认启动时不检查更新、不拉取公告。
- **纯无头**:彻底移除了指向闭源桌面应用的所有入口 —— 启动器 `codex app`、
  `codex://` 深链、Codex Cloud 浏览器、远程控制中继,以及远程插件市场。
  codEx 只提供 TUI/CLI,没有图形界面,也不连厂商中继服务。
- **发行**:为 Linux 与 Windows 提供规范 Codex 包(与上游发布的
  `codex-package.json` 布局一致),没有 macOS/app-server 包。
- **身份**:CLI 和 TUI 以 codEx 自居,`codex --version` 指向本分支的仓库。

详见下文。

### `/rewind` - 回滚对话与工作区文件

核心功能。`/rewind` 让你撤销某一轮对话和/或该轮造成的文件改动,不需要 git。

**用法**:输入 `/rewind`,然后选择范围:

1. **文件与对话** - 在对话记录中挑选一条过往消息;聊天会就地回滚到该消息
   之前(对话截断到那里,prompt 恢复到输入框),同时工作区文件会恢复到
   该消息之前拍摄的快照。执行前会先确认并预览将要恢复/删除的文件数量;
   若找不到匹配快照,对话仍会回滚,只是不碰文件。
2. **仅对话** - 在对话记录中挑选一条过往消息并就地回滚到它之前;文件保持不变。
3. **仅文件** - 选择一个编号快照;执行前会确认并预览将要恢复/删除的文件
   数量。

两种对话范围都复用对话记录选择器(即旧的双击 Esc 回溯所用的完整历史视图):
最新用户消息开始处于高亮状态,**Left** 向前翻更早的消息,**Right** 向后翻,
**Enter** 确认回滚,**Esc** 取消。

**快照原理**(纯文件,不涉及 git):

- 每个主线程用户回合提交前,TUI 将工作区快照到
  `~/.codex/snapshots/<workspace-hash>/threads/<对话>/<turn>/`(或
  `$CODEX_HOME/snapshots/...`)。每个对话拥有独立的快照链,对话之间互不挤占,
  编号始终与 picker 使用的 transcript 序号一致。侧对话消息和待发送的 steer
  编辑不会创建快照。每个快照包含一个 `manifest.json`(每个文件的相对路径、
  大小、mtime、对象 id,外加 prompt 摘要、用于精确匹配消息的完整 prompt
  哈希、快照时的 `.gitignore` 设置,以及非 UTF-8 文件名的原始路径字节)
  以及 `files/` 下的文件内容。
- 存储采用小型**内容寻址对象库**(同样不涉及 git):每个唯一文件内容在
  `objects/` 下只保存一份,每个快照的 `files/` 条目都是指向对象库的硬链接。
  未变化的文件直接从上一份快照链接、无需重新读取,任何早期回合出现过的
  相同内容也绝不会重复存储。对话的第一份快照还会从同一工作区其它对话的
  最新快照"借种",让恢复/分支后的对话保持低成本。
- 遍历会跳过 `.git`,默认遵循 `.gitignore` 文件。
- 每个对话默认保留最近 **100 个**快照(可用 `rewind_max_snapshots` 配置);
  更旧的按对话清理,同时回收不再被任何快照引用的对象,并清理中断(缺少
  manifest)的快照目录。
- 无法读取的文件会被跳过而不是让整份快照失败;跳过的路径记录在 manifest
  中、显示在对话记录里,之后的还原也不会碰它们。整份快照失败时同样会在
  对话记录中提示,而不是只写日志。
- 恢复时把快照文件复制回工作区,并删除快照之后创建的文件。删除集合使用
  快照时的 `.gitignore` 设置、结合当前工作区的 `.gitignore` 规则,因此确认
  预览与实际恢复的结果始终一致。还原后的文件会恢复原始 mtime,让后续快照
  继续保持低开销。
- 恢复前会先做整体预检:物理副本缺失、目标位置是目录、记录了不安全路径、
  或目标上方存在符号链接时,直接中止、不改动任何文件。目标路径本身是符号
  链接时会被替换为还原出的普通文件(绝不穿透写入),只读目标则通过临时文件
  +rename 原子替换。
- **Files only** picker 会列出所有对话的快照(标注短对话 id 与每回合的变更
  文件数);任务运行中拒绝还原文件。每次还原前都会先做 dry-run 预览,报告
  将恢复和删除的文件数(若没有任何变化则直接跳过)。当对话回滚需要跨对话
  查找匹配快照时,若匹配存在歧义(多个对话出现过相同 prompt),会拒绝恢复
  文件而不是猜测。

**配置**(codEx 数据目录下的 `config.toml`):

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `rewind_enabled` | `true` | `/rewind` 总开关。为 `false` 时命令禁用且不再拍摄快照。 |
| `rewind_respect_gitignore` | `true` | 为 `true` 时快照跳过 `.gitignore` 匹配的文件(始终跳过 `.git`);设为 `false` 则快照所有文件。 |
| `rewind_max_snapshots` | `100` | 每个对话保留的快照数量(`1`-`10000`),更旧的会被修剪。 |

示例:

```toml
rewind_enabled = true            # 总开关
rewind_respect_gitignore = true  # 快照时遵循 .gitignore
rewind_max_snapshots = 200       # 每个对话保留 200 份快照
```

**限制**:

- 快照拍摄是尽力而为:失败会显示在对话记录中、回合继续,因此对话回滚可能
  没有对应的文件状态。
- 当文件的大小与修改时间都和上一份快照一致时,快照会认为它未变化;同时
  保持两者不变的内容改动(例如 `touch -r`)无法被识别。快照在回合开始前
  同步拍摄,因此总是反映该回合文件写入之前的状态。
- 还原会覆盖受影响文件的当前内容,并删除快照之后创建的文件;快照之后的
  手动编辑不会保留。
- Shell 命令可能改变数据库、服务、网络资源、git 状态或活动目录之外的文件;
  rewind 不会逆转这些副作用,其它进程也可能在拍摄与还原之间改动工作区。
- 快照包含被捕获文件的完整内容(默认排除 `.gitignore` 匹配的路径),存放在
  codEx 数据目录下;请像对待源代码一样对待它们,而非无秘密的元数据。
- rewind 是修订近期工作的便利功能,不能替代 git 提交或备份。

### Esc:单击无操作,双击停止回复

- 在主界面/输入框中的单次 **Esc** 是**无操作** - 不再中断对话轮次,也不再
  进入任何回溯模式。
- 回复进行中时,第一次 **Esc** 会显示底部提示("esc again to stop reply")
  并开启 **400 ms** 窗口;窗口内的第二次 **Esc** 会中断当前轮次(与旧行为
  一致,先提交挂起的 steers)。
- 在需要 Esc 的地方,原有行为全部保留:模态框、弹出层、`?` 快捷键浮层、
  历史搜索、bash 模式提示、vim 插入模式以及请求用户输入面板仍照常使用 Esc。
- 全屏对话记录模式(`tui.fullscreen_transcript`,默认开启)同样如此:Esc 不会
  进入回溯浏览;没有回复在跑时,它只会把暂停的视口带回最新一条。
- `chat.interrupt_turn` 键位**默认不绑定**(可在 `/keymap` 中重新绑定;模态
  视图会遵循它),旧的 "Esc-Esc to edit previous message" 回溯已从主界面
  移除;`/rewind` 现在复用它的对话记录选择器来选择消息。

### `codex update`:纯 Rust 自更新

- `codex update` 不再调用 `curl | sh`、npm 或 brew。它是自包含的 Rust 实现:
  1. 将主机架构映射到分支的发布目标(`x86_64-unknown-linux-musl` 或
     `x86_64-pc-windows-msvc`)。
  2. 从本分支最新的 GitHub release 下载 `codex-<target>.tar.gz` 及其
     `.sha256` 资产。
  3. 在改动任何内容**之前**校验 sha256 校验和。
  4. 读取归档的 `codex-package.json`,确认该包对当前目标平台是完整的,然后把
     **整个包**覆盖安装到当前 release:先写辅助程序与资源,再换 `codex`
     入口,最后写清单;替换二进制期间保留 `.old` 备份。清单与可执行文件保持
     同一版本,`codex app-server daemon` 才能从这个包安装共享后台服务。没有
     清单的归档会被拒绝,并提示重新运行 `install.sh` —— 那是一次性迁移到包
     布局的方式。
- 由于归档由分支的 release 工作流构建,新二进制内嵌的 bwrap 摘要始终与
  随附的新 bwrap 匹配。
- Windows 无法替换正在运行的可执行文件,因此更新会先暂存到安装目录旁,再交给
  新二进制的分离副本:它等待 codEx 退出后替换整个包并重新启动 codEx。
- 非独立安装(npm/brew/...)会得到明确提示,指向分支 release 供手动下载。
- 后台 daemon 同样不会从远程脚本安装:其更新循环只负责看守受管安装,并在外部
  更新替换了二进制后重新执行;`codex app-server daemon update` 必须带
  `--from-cli`——它复制并固定**当前 CLI 自己的包**,而不是拉取上游安装脚本。

### 无更新打扰、无公告

- `check_for_update_on_startup` 现在默认 **`false`**:TUI 启动时不联网。
  如需开启,在 `config.toml` 中设为 `true`。
- 启动时的**公告拉取**(远程 `announcement_tip.toml`)已彻底移除;只保留
  本地随机提示。
- 更新横幅/通知(如果启用)指向本分支的 release,并提示运行 `codex update`。

### 纯无头:不含任何闭源界面

codEx 面向无头、自托管场景,只提供 TUI 与 CLI。所有会引入 OpenAI 闭源产品
或厂商托管服务的入口都已**删除**(而非仅禁用):

- **`codex app` 与桌面启动器**:子命令、`AppCommand` 与 `desktop_app/`
  下载器均已移除。它在 macOS 上会拉取闭源 `.dmg`,在 Windows 上打开厂商
  安装页。
- **`/app` 与 `codex://` 深链**:斜杠命令、对应 `AppEvent` 以及各平台启动
  逻辑(含查询 `OpenAI.Codex` AppX 包的 PowerShell 路径)全部移除,TUI
  无法再跳转到桌面应用。
- **`codex doctor` 的桌面探测**:`desktop` 模块、appcast 与 Windows Store
  更新源、Sparkle 暂存检查均已移除;`doctor` 不再访问
  `persistent.oaistatic.com`。
- **桌面应用提示语**:任何平台都不再宣传桌面应用;付费用户的推广位只保留
  Fast 模式。
- **`codex cloud`**(Codex Cloud 任务浏览)与 **`codex remote-control`**
  及守护进程的 `enable-remote-control` / `disable-remote-control` 开关
  —— 它们会把本地守护进程与厂商中继配对。
- **远程插件市场**(`openai-curated-remote`,由 chatgpt.com 后端提供)会被
  拒绝;本地与 Git 市场不受影响。

有意保留:agent 实际通信的模型/API 后端,以及 Windows 沙箱相关代码 —— 后者
引用厂商包标识仅用于授权同机沙箱 IPC。

### 品牌

- `codex --version` 输出
  `codEx 0.164.0 (codEx fork, https://github.com/NIyueeE/codEx)`;状态栏
  显示 `codEx <version>`。
- TUI 的欢迎页、会话标题栏和状态标题栏显示 `codEx`;提示语也使用 `codEx`。
- 版本号本身**与上游基础 tag 保持一致**(如 `0.164.0`),因此版本解析保持
  纯 semver,分支 release tag 也保持整洁。

### 发布与 CI(Linux CI + Windows 检查)

- **发布矩阵**:`x86_64-unknown-linux-musl` 与 `x86_64-pc-windows-msvc`
  (上游发布 macOS/ARM64/app-server 包;本分支不发布)。每个目标各发布两个
  资产:
  - `codex-x86_64-unknown-linux-musl.tar.gz`(规范 Codex 包:
    `codex-package.json`、`bin/`、`codex-path/rg`、`codex-resources/`)
  - `codex-x86_64-unknown-linux-musl.tar.gz.sha256`
  - `codex-x86_64-pc-windows-msvc.tar.gz`(同样的布局,入口带 `.exe`
    后缀,Windows 沙箱辅助程序位于 `codex-resources/` 下)
  - `codex-x86_64-pc-windows-msvc.tar.gz.sha256`
- **CI**(`blocking-ci.yml`)在托管 runner 上使用纯 Cargo,并与上游一样分层:
  轻门阻塞 PR,重门不阻塞。本仓库是补丁队列仓库,因此分层的界线是「该检查
  是否需要先应用补丁队列」(`scripts/bootstrap.sh`,CI 中最贵的一步)。

  | 门 | 工作流 | 触发时机 | 内容 |
  | --- | --- | --- | --- |
  | 轻门 | `repo-checks.yml` | 每个 PR、每次推送 `main` | 补丁队列布局、README ASCII、README.zh 排版、shellcheck |
  | 轻门 | `blob-size-policy.yml` | 每个 PR | 新增 blob 体积预算(沿用上游策略) |
  | 轻门 | `codespell.yml` | 每个 PR | 拼写检查 |
  | 重门 | `rust-ci.yml` | 合并后、手动触发、`**full-ci**` 分支 | 队列完整性与导出漂移、package/installer 测试、TUI/core 边界、CLI/TUI/core 编译面的 `cargo check`、config schema 基线、`cargo fmt --check`、cargo-deny |
  | 重门 | `rust-ci-full.yml` | 合并后、手动触发、`**full-ci**` 分支 | `cargo build --release --bin codex`、`codex-tui` 完整套件、`codex-core` 单元测试、Windows 检查 |
  | 重门 | `cargo-deny.yml` | 合并后、手动触发 | 许可证、ban 与安全公告漂移 |

  `blocking-ci.yml` 汇总轻门并报告唯一的必需状态,`postmerge-ci.yml` 汇总重门。
  依赖沙箱的核心集成套件(`suite::*`)需要具备沙箱能力的 runner,已从托管
  CI 排除,与上游自己的自托管 runner 配置一致。
- 工作流是 bootstrap-aware 的:在完整检出和本精简仓库中都能工作(先
  bootstrap,再在 `tree/` 内构建/测试/发布)。

### 本地门禁(同样的命令,先于远端执行)

`scripts/gates.sh` 是唯一的门禁执行器。本地 git hook 和 CI 都调用它,所以
本地通过就等于 CI 通过,而不是另写一套等价逻辑:

```sh
bash scripts/gates.sh light # 不涉及补丁列表、无需 bootstrap:数秒
bash scripts/bootstrap.sh   # 一次性;树上的门禁需要先应用源码
bash scripts/gates.sh tree  # 队列完整性 + 编译面
bash scripts/gates.sh full  # release 构建 + TUI/core 套件
bash scripts/gates.sh heavy # tree + full:CI 合并后跑的那一档
bash scripts/gates.sh all   # light + heavy
```

装好 hook 后,`git commit` 跑轻门、`git push` 再加跑重门——本地这一档先
跑,多数问题不会走到远端 CI:

```sh
pip install pre-commit
pre-commit install                        # 提交 hook:轻门
pre-commit install --hook-type pre-push   # 推送 hook:重门
```

`scripts/gates.sh` 会自动探测代码树,因此在精简仓库、升级期间的
`update-work/` 以及完整检出中都无需加参数即可运行。两档都可以按需裁剪
(`--only`/`--skip`,id 列表见脚本头部注释),CI 的各 job 正是这样选片的。

### Patch-queue 模型

本仓库刻意**不**复制上游代码,不同于携带完整代码树并定期合并上游的经典
fork。它只保存增量,并按**每个特性模块一个补丁**(而非每个提交一个补丁)
组织:

| 组成部分 | 用途 |
| --- | --- |
| `BASE_TAG` | 补丁队列所基于的上游 tag(如 `rust-v0.164.0`) |
| `patches/` | 每个特性模块一个 `git format-patch` 补丁,顺序固定 |
| `scripts/patch-modules.conf` | 模块清单:顺序、subject 与文件归属 |
| `scripts/check-patch-modules.sh` | 用清单机器校验代码树与 `patches/` |
| `scripts/bootstrap.sh` | 浅克隆 `openai/codex@BASE_TAG` 并 `git am` 应用补丁 |
| `scripts/update.sh` | 升级到新的上游 tag(应用补丁、与 CI 相同的检查、重新生成) |
| `scripts/gen-patches.sh` | 从代码树历史重新生成 `patches/`;拒绝导出违反清单的布局 |
| `scripts/gates.sh` | 唯一的门禁执行器(`light` / `tree` / `full` / `heavy` / `all`),git hook 与 CI 都调用它 |
| `scripts/asciicheck.py`、`scripts/check_blob_size.py` | 上游的 README 与 blob 预算检查器,按字节原样携带,使轻门无需 bootstrap |

七个模块为 `infra`(补丁队列工具、锁文件、README)、`rollback`(`/rewind`)、
`updates`(纯 Rust 自更新)、`input`(双击 Esc 中断)、`privacy`(启动无网络
请求)、`distribution`(Linux CI + Windows 检查,release 含 Linux + Windows)与
`identity`(品牌标识)。
分支改动的每个文件都归属且仅归属一个模块;`check-patch-modules.sh` 在导出
(gen-patches)、升级(update.sh)、CI(rust-ci)和本地门禁(`gates.sh tree`)
四处强制校验这一划分。

工作流:**新增特性** = 在 `patch-modules.conf` 中加一节并在 bootstrap 树里
建对应提交;**修改已有特性** = 将改动 rebase/折叠进该模块的提交。直接手改
`patches/` 会被检查器拒绝。

`bootstrap.sh` + `git am` 会生成完整、可构建的 codEx 代码树;CI 和 release
工作流在构建前正是这么做的。参见下面的
[构建](#building-from-this-repository)和
[升级](#upgrading-to-a-new-upstream-tag)。

## 从本仓库构建

精简仓库没有检入 `codex-rs/`,因此要从 bootstrap 的代码树构建:

```sh
bash scripts/bootstrap.sh        # 将 openai/codex@BASE_TAG 克隆到 tree/ 并应用补丁
cd tree/codex-rs
cargo build --release --bin codex
```

如果你恰好有完整代码树检出(存在 `codex-rs/`),可以直接构建:

```sh
cd codex-rs
cargo build --release --bin codex
```

## 升级到新的上游 tag

```sh
bash scripts/update.sh rust-v0.164.0
```

`update.sh` 将新 tag 克隆到 `update-work/`,用 `git am --3way` 应用补丁队列,
然后从 `codex-rs` 工作区运行与 CI 相同的检查(构建、`cargo fmt --check`,
以及 `codex-tui`/`codex-core` 的 nextest 测试)。tag 参数带不带 `rust-v` 前缀
均可(`rust-v0.164.0` 或 `0.164.0`)。如果补丁冲突,在 `update-work/` 中解决
(`git am --continue`),然后在 bootstrap 树内用
`bash scripts/gen-patches.sh rust-v0.164.0` 重新生成(精简仓库没有上游历史,
脚本会拒绝在那里运行)。补丁队列从不改变版本号;分支 release 保持上游
semver,并以 `rust-v<version>` 打 tag(例如 `rust-v0.164.0`),release 工作流
发布 `codex-<target>.tar.gz` + sha256 校验和。

## 许可证

本分支保留上游许可证(Apache-2.0)。参见 `LICENSE`。
