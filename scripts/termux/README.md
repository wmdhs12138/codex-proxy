# Termux / Android ARM64 下游适配

这组脚本把 Termux 适配集中在 `scripts/termux/`，让 `termux-aarch64` 分支可以长期 rebase 到原作者的 `master`，而不用反复手工修改业务源码。

Android ARM64 **不等于** generic Linux ARM64：Termux Node 的 `process.platform` 是 `android`、`process.arch` 是 `arm64`，因此 NAPI 加载器使用 `native/codex-tls.android-arm64.node`；Linux glibc/musl 的 `.node` 不能代替它。GitHub 托管的 Linux ARM64 runner 也不能等价验证 Android/Bionic，所以最终构建验证应在真实 Termux 设备上完成。

`run.sh` 设置的 `CODEX_PLATFORM=linux` 与 `CODEX_ARCH=arm64` 只是有意模拟 Codex Desktop 的上游客户端平台/指纹；它不会改变 Node 自己的 `process.platform=android`，也不会让 NAPI 加载器误用 Linux 二进制。

## 首次安装

默认来源：

- fork：`https://github.com/wmdhs12138/codex-proxy.git`
- 分支：`termux-aarch64`
- 源码目录：`~/projects/codex-proxy`
- 端口：`8080`

分支发布到 GitHub 后，可以从任意目录执行：

```bash
installer="${TMPDIR:-$HOME/tmp}/install-codex-proxy-termux.sh"
mkdir -p "$(dirname "$installer")"
curl -fsSL \
  https://raw.githubusercontent.com/wmdhs12138/codex-proxy/termux-aarch64/scripts/termux/install.sh \
  -o "$installer"
bash "$installer"
```

也可以先克隆再安装：

```bash
git clone -b termux-aarch64 \
  https://github.com/wmdhs12138/codex-proxy.git \
  "$HOME/projects/codex-proxy"
bash "$HOME/projects/codex-proxy/scripts/termux/install.sh"
```

安装器会：

1. 安装 Node.js、Rust、Clang、CMake、Ninja、tmux 等 Termux 构建依赖；
2. 克隆或检查部署分支，不覆盖不干净的工作树或本地源码提交；
3. 保留已有 `data/local.yaml`、账号数据库和 API Key；
4. 本机编译 `better-sqlite3` 与 Android ARM64 Rust TLS 模块；
5. 构建 Web/TypeScript 后端并启动 tmux 服务；
6. 安装 `~/.local/bin/codex-proxy` 控制命令及 Termux:Boot 启动脚本。

安装器只会在 `~/.gyp/include.gypi` 不存在时创建它；已有 node-gyp 配置不会被覆盖。

可覆盖默认配置：

```bash
CODEX_PROXY_REPO=https://github.com/me/codex-proxy.git \
CODEX_PROXY_BRANCH=termux-aarch64 \
CODEX_PROXY_DIR="$HOME/apps/codex-proxy" \
CODEX_PROXY_PORT=8081 \
bash install-codex-proxy-termux.sh
```

调试安装器时可设置：

```bash
CODEX_PROXY_SKIP_BUILD=1 CODEX_PROXY_SKIP_START=1 bash install-codex-proxy-termux.sh
```

## 日常使用

```bash
codex-proxy start
codex-proxy stop
codex-proxy restart
codex-proxy pause
codex-proxy resume
codex-proxy status
codex-proxy logs
codex-proxy attach
codex-proxy build
codex-proxy update
codex-proxy key
codex-proxy url
```

`run.sh` 默认清除代理环境变量，避免本机 7890 代理造成代理回环或健康检查异常；确实需要让 Codex Proxy 进程继承代理时，设置 `CODEX_PROXY_KEEP_PROXY=1`。`start` 默认等待 HTTP 最多 15 秒；慢设备可通过 `CODEX_PROXY_HEALTH_TIMEOUT=30 codex-proxy start` 调整。

`pause` 会停止服务并写入 `$CODEX_PROXY_CONFIG_DIR/paused` 标记；之后普通 `start` 与 Termux:Boot 都不会意外拉起服务。`resume` 只解除暂停，不会自动启动。服务日志会在每次启动前检查，默认达到 20 MiB 时轮转并保留 3 份；可用 `CODEX_PROXY_LOG_MAX_BYTES` 和 `CODEX_PROXY_LOG_KEEP_FILES` 调整。

## 部署更新与数据安全

`codex-proxy update` 的流程是：

1. 要求当前部署分支正确且工作树完全干净；
2. **先 fetch，服务此时仍在运行**；
3. 为旧 HEAD 创建 `refs/codex-proxy/rollback/<时间>-<提交>` 回滚引用，并只保留最近 10 个；
4. 停止服务并明确 `reset --hard origin/termux-aarch64`，因此兼容维护者 rebase 后的 force-push；
5. 重新安装依赖、编译 native 模块并构建项目；
6. 保留更新前的运行状态：原本在运行才重启，原本停止/暂停则构建后继续保持停止；失败时恢复旧 HEAD、重建并尽力恢复原运行状态。

部署分支应只追踪远端发布结果，不要在里面保存未推送的源码提交。更新脚本不会执行 `git clean`，而且项目的 `data/` 已被忽略，因此不会删除 `data/local.yaml`、账号数据库或 API Key；重要数据仍建议定期备份。

查看自动保留的回滚点：

```bash
cd "$HOME/projects/codex-proxy"
git for-each-ref --sort=-refname \
  --format='%(refname:short) %(objectname:short)' \
  refs/codex-proxy/rollback/
```

手工回滚会丢弃**已跟踪源码改动**，先确认路径和提交：

```bash
codex-proxy stop
cd "$HOME/projects/codex-proxy"
git status --short
git reset --hard refs/codex-proxy/rollback/<时间>
codex-proxy build
codex-proxy start
```

`git reset --hard` 不会删除被忽略的 `data/`，但仍不要在部署分支里存放未提交源码。

## 维护者同步上游

推荐 remote 约定：

```text
origin   https://github.com/wmdhs12138/codex-proxy.git
upstream https://github.com/icebear0828/codex-proxy.git
```

初始化一次：

```bash
git remote rename origin upstream       # 仅当 origin 当前是原作者仓库
git remote rename fork origin           # 仅当 fork 当前是个人仓库
git config rerere.enabled true
```

在干净的 `termux-aarch64` 工作树中同步：

```bash
bash scripts/termux/sync-upstream.sh
```

脚本会：

- fetch `upstream/master`；
- rebase 当前 Termux 补丁；
- 执行 `bash -n`，并在可用时执行 `shellcheck`；
- 运行脚本 TypeScript 检查；
- 通过 `build.sh` 真实编译 Android/Bionic native 模块及 Web/后端。

默认绝不推送。检查 diff 与运行结果后再显式发布：

```bash
bash scripts/termux/sync-upstream.sh --push
```

`--push` 使用 `git push --force-with-lease origin termux-aarch64`。发生 rebase 冲突时，按提示解决后执行 `git rebase --continue`，或者用 `git rebase --abort` 返回同步前状态。
