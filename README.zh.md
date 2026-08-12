# codEx

codEx 是 [openai/codex](https://github.com/openai/codex) 的社区分支,面向 Linux
独立用户保持 CLI 的顺滑体验:更少的组件、默认不进行联网更新检查,内置的
`codex update` 会从本分支的 release 下载经过校验的二进制。

本仓库采用 **patch-queue 模型**:不复制上游代码树,只保存分支的改动(以
`git format-patch` 补丁系列形式)以及从上游 tag 重建完整 codex 代码树的脚本。
真正的代码在上游;`BASE_TAG` 固定了当前补丁队列所基于的上游 tag(当前为
`rust-v0.147.0`)。

## 从 Release 安装

Linux 独立用户可以用安装脚本安装或更新 codEx:

```sh
curl -fsSL https://raw.githubusercontent.com/NIyueeE/codEx/main/install.sh | sh
```

安装脚本会解析最新的分支 release,下载 `codex-<target>.tar.gz` 及其发布的
sha256 校验和,在改动任何内容之前先校验校验和,然后安装到
`~/.codex/packages/standalone/releases/<version>-<target>/` 下的独立布局
(捆绑的 `bwrap` 位于 `codex-resources/`),这样之后 `codex update` 仍能正常
工作。随后将 `codex` 链接到 `~/.local/bin`(或 `CODEX_INSTALL_DIR`)。

环境变量:

- `CODEX_RELEASE` - 要安装的版本,如 `0.147.0`(默认:`latest`)
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
- **发行**:仅提供 Linux 独立归档(`codex` + `bwrap`),没有
  macOS/Windows/app-server 包。
- **身份**:CLI 和 TUI 以 codEx 自居,`codex --version` 指向本分支的仓库。

详见下文。

### `/rewind` - 回滚对话与工作区文件

核心功能。`/rewind` 让你撤销某一轮对话和/或该轮造成的文件改动,不需要 git。

**用法**:输入 `/rewind`,然后选择范围:

1. **文件与对话** - 在对话记录中挑选一条过往消息;聊天会在该消息之前 fork
   (新线程,对话截断到那里,prompt 恢复到输入框),同时工作区文件会恢复到
   该消息之前拍摄的快照。执行前会先确认并预览将要恢复/删除的文件数量;
   若找不到匹配快照,对话仍会回滚,只是不碰文件。
2. **仅对话** - 在对话记录中挑选一条过往消息并在其之前 fork;文件保持不变。
3. **仅文件** - 选择一个编号快照;执行前会确认并预览将要恢复/删除的文件
   数量。

两种对话范围都复用对话记录选择器(即旧的双击 Esc 回溯所用的完整历史视图):
最新用户消息开始处于高亮状态,**Esc** 或 **Left** 向前翻更早的消息,**Right**
向后翻,**Enter** 确认回滚。

**快照原理**(纯文件,不涉及 git):

- 每个主线程用户回合提交前,TUI 将工作区快照到
  `~/.codex/snapshots/<workspace-hash>/threads/<对话>/<turn>/`(或
  `$CODEX_HOME/snapshots/...`)。每个对话拥有独立的快照链,对话之间互不挤占,
  编号始终与 picker 使用的 transcript 序号一致。侧对话消息和待发送的 steer
  编辑不会创建快照。每个快照包含一个 `manifest.json`(每个文件的相对路径、
  大小、mtime、对象 id,外加 prompt 摘要)以及 `files/` 下的文件内容。
- 存储采用小型**内容寻址对象库**(同样不涉及 git):每个唯一文件内容在
  `objects/` 下只保存一份,每个快照的 `files/` 条目都是指向对象库的硬链接。
  未变化的文件直接从上一份快照链接、无需重新读取,任何早期回合出现过的
  相同内容也绝不会重复存储。
- 遍历会跳过 `.git`,默认遵循 `.gitignore` 文件。
- 每个对话默认保留最近 **100 个**快照(可用 `rewind_max_snapshots` 配置);
  更旧的按对话清理,同时回收不再被任何快照引用的对象。
- 恢复时把快照文件复制回工作区,并删除快照之后创建的文件(被 gitignore 的
  路径保持不动)。还原后的文件会恢复原始 mtime,让后续快照继续保持低开销。
  如果某份快照的物理副本缺失,恢复会失败并列出缺失路径,而不是静默保留
  当前内容。
- **Files only** picker 会列出所有对话的快照(标注短对话 id 与每回合的变更
  文件数);任务运行中拒绝还原文件。每次还原前都会先做 dry-run 预览,报告
  将恢复和删除的文件数(若没有任何变化则直接跳过)。

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

- 快照拍摄是尽力而为:失败仅记日志、回合继续,因此对话回滚可能没有对应的
  文件状态。
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
- `chat.interrupt_turn` 键位**默认不绑定**(可在 `/keymap` 中重新绑定;模态
  视图会遵循它),旧的 "Esc-Esc to edit previous message" 回溯已从主界面
  移除;`/rewind` 现在复用它的对话记录选择器来选择消息。

### `codex update`:纯 Rust 自更新

- `codex update` 不再调用 `curl | sh`、npm 或 brew。它是自包含的 Rust 实现:
  1. 将主机架构映射到分支的发布目标(`x86_64-unknown-linux-musl`)。
  2. 从本分支最新的 GitHub release 下载 `codex-<target>.tar.gz` 及其
     `.sha256` 资产。
  3. 在改动任何内容**之前**校验 sha256 校验和。
  4. 解压后原子替换正在运行的 `codex` 二进制和捆绑的 `bwrap` 资源
     (`codex-resources/bwrap`),替换期间保留 `.old` 备份。
- 由于归档由分支的 release 工作流构建,新二进制内嵌的 bwrap 摘要始终与
  随附的新 bwrap 匹配。
- 非独立安装(npm/brew/...)会得到明确提示,指向分支 release 供手动下载。

### 无更新打扰、无公告

- `check_for_update_on_startup` 现在默认 **`false`**:TUI 启动时不联网。
  如需开启,在 `config.toml` 中设为 `true`。
- 启动时的**公告拉取**(远程 `announcement_tip.toml`)已彻底移除;只保留
  本地随机提示。
- 更新横幅/通知(如果启用)指向本分支的 release,并提示运行 `codex update`。

### 品牌

- `codex --version` 输出
  `codEx 0.147.0 (codEx fork, https://github.com/NIyueeE/codEx)`;状态栏
  显示 `codEx <version>`。
- TUI 的欢迎页、会话标题栏和状态标题栏显示 `codEx`;提示语也使用 `codEx`。
- 版本号本身**与上游基础 tag 保持一致**(如 `0.147.0`),因此版本解析保持
  纯 semver,分支 release tag 也保持整洁。

### 发布与 CI(仅 Linux + CLI)

- **发布矩阵**:仅 `x86_64-unknown-linux-musl`(上游发布
  macOS/Windows/ARM64/app-server 包;本分支不发布)。每个 release 恰好发布
  两个资产:
  - `codex-x86_64-unknown-linux-musl.tar.gz`(包含 `codex` + `bwrap`)
  - `codex-x86_64-unknown-linux-musl.tar.gz.sha256`
- **CI**(`blocking-ci.yml`)在托管 runner 上使用纯 Cargo:
  `cargo build --release --bin codex`、`cargo fmt --check`、`codex-tui`
  完整测试套件、`codex-core` 单元测试、codespell、repo-checks。依赖沙箱的
  核心集成套件(`suite::*`)需要具备沙箱能力的 runner,已从托管 CI 排除,
  与上游自己的自托管 runner 配置一致。
- 工作流是 bootstrap-aware 的:在完整检出和本精简仓库中都能工作(先
  bootstrap,再在 `tree/` 内构建/测试/发布)。

### Patch-queue 模型

本仓库刻意**不**复制上游代码,不同于携带完整代码树并定期合并上游的经典
fork。它只保存增量:

| 组成部分 | 用途 |
| --- | --- |
| `BASE_TAG` | 补丁队列所基于的上游 tag(如 `rust-v0.147.0`) |
| `patches/` | 包含所有分支改动的 `git format-patch` 补丁系列 |
| `scripts/bootstrap.sh` | 浅克隆 `openai/codex@BASE_TAG` 并 `git am` 应用补丁 |
| `scripts/update.sh` | 升级到新的上游 tag(应用补丁、与 CI 相同的检查、重新生成) |
| `scripts/gen-patches.sh` | 在 bootstrap 树内将 `patches/` 重新生成为模块化系列(每个提交一个补丁) |

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
bash scripts/update.sh rust-v0.148.0
```

`update.sh` 将新 tag 克隆到 `update-work/`,用 `git am --3way` 应用补丁队列,
然后从 `codex-rs` 工作区运行与 CI 相同的检查(构建、`cargo fmt --check`,
以及 `codex-tui`/`codex-core` 的 nextest 测试)。tag 参数带不带 `rust-v` 前缀
均可(`rust-v0.148.0` 或 `0.148.0`)。如果补丁冲突,在 `update-work/` 中解决
(`git am --continue`),然后在 bootstrap 树内用
`bash scripts/gen-patches.sh rust-v0.148.0` 重新生成(精简仓库没有上游历史,
脚本会拒绝在那里运行)。补丁队列从不改变版本号;分支 release 保持上游
semver,并以 `rust-v<version>` 打 tag(例如 `rust-v0.148.0`),release 工作流
发布 `codex-<target>.tar.gz` + sha256 校验和。

## 许可证

本分支保留上游许可证(Apache-2.0)。参见 `LICENSE`。
