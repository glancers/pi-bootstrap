# pi-bootstrap

一键给一台干净的 Mac / Linux 装好：

- **[Pi](https://pi.dev)** coding agent（自动装 Node.js ≥ 22.19，机器上没有 npm/node 也没关系）
- **火山方舟 Agent Plan**：通过 `arkcli helper configure pi` 把 pi 的默认 model/provider 配成 Agent Plan（`ark-code-latest`），可选注入 Agent Plan 内置 MCP（豆包搜索 / dataPro / OpenViking）
- **飞书全家桶**：`lark-cli` + 全套 `lark-*` skills + `arkcli-*` skills
- **arkcli-* skills** 装进 pi 的 skills 目录

全程 **不需要 sudo**，所有文件都落在 `$HOME` 下。

## 一键安装

把本仓库 push 到 GitHub 后（假设 `glancers/pi-bootstrap`、默认分支 `main`）：

```bash
curl -fsSL https://raw.githubusercontent.com/glancers/pi-bootstrap/main/install.sh | bash
```

或者先下载、审查后再跑（推荐第一次这么做）：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/glancers/pi-bootstrap/main/install.sh
less install.sh
bash install.sh
```

脚本末尾会引导两次**必须人工完成**的登录（密钥不会也不能写进脚本）：

1. `arkcli auth login` —— 浏览器 SSO 登录火山引擎
2. `lark-cli config init --new` → `lark-cli auth login --domain all` —— 绑定飞书自建应用 + 扫码授权

## 安装位置

| 内容 | 路径 |
|---|---|
| Node.js standalone | `~/.local/share/pi-node/current`（系统已有 ≥22.19 则直接复用） |
| npm 全局包前缀 | `~/.local/npm-global`（pi / arkcli / lark-cli 装在这里） |
| pi 数据 / skills | `~/.pi/agent/` |
| arkcli 配置 | `~/.arkcli/`（由 arkcli 自己管理） |
| lark-cli 配置 | `~/.lark-cli/`（appSecret 存系统 keychain） |
| PATH / 环境变量 | 写入 `~/.zshrc` 或 `~/.bashrc` / `~/.profile` 的 `pi-bootstrap` 区块 |

脚本只往 shell profile 追加一个带 `# >>> pi-bootstrap >>>` 标记的区块，重复执行不会重复写入。

## 环境变量开关

```bash
# 只装 pi，不碰飞书和火山
curl -fsSL https://raw.githubusercontent.com/glancers/pi-bootstrap/main/install.sh | SKIP_LARK=1 SKIP_ARK=1 bash

# 跳过 Node 安装（自己用 brew/mise 等装好了）
SKIP_NODE=1 bash install.sh

# 跳过 skills
SKIP_SKILLS=1 bash install.sh

# 给 pi 注入 Agent Plan 内置 MCP（豆包搜索 / dataPro / OpenViking）
WITH_MCP=1 bash install.sh

# 自定义 Agent Plan profile 名
ARK_PROFILE_NAME=my-plan bash install.sh

# 已有 Agent Plan API Key，跳过浏览器 SSO（密钥不会落盘到任何仓库）
ARK_API_KEY=ark-xxxx bash install.sh
```

| 变量 | 默认值 | 作用 |
|---|---|---|
| `SKIP_NODE` | 未设置 | `1` = 不装 standalone Node，要求 PATH 上已有 ≥ 22.19 |
| `SKIP_LARK` | 未设置 | `1` = 跳过 lark-cli、飞书 skills、飞书登录 |
| `SKIP_ARK` | 未设置 | `1` = 跳过 arkcli、Agent Plan 配置、arkcli skills |
| `SKIP_SKILLS` | 未设置 | `1` = 不装任何 skills |
| `WITH_MCP` | 未设置 | `1` = `helper configure pi --with-mcp`，注入 Agent Plan MCP |
| `ARK_PROFILE_NAME` | `agent-plan_cn-beijing_personal` | Agent Plan profile 名 |
| `ARK_API_KEY` | 空 | 提供后跳过 SSO，直接用 Key 建 profile |

## 安装后验证

```bash
# 新开一个终端，或 source 对应的 profile
pi --version
arkcli profile show
lark-cli auth status

pi        # 启动后用 /model 确认默认是 ark-code-latest / agent-plan
```

## 完全卸载

```bash
rm -rf ~/.local/share/pi-node ~/.local/npm-global ~/.pi ~/.arkcli ~/.lark-cli
# 再从 ~/.zshrc（或 ~/.bashrc / ~/.profile）删掉 >>> pi-bootstrap >>> 区块
```

## 前置条件

- macOS（Intel / Apple Silicon）或 Linux x86_64 / arm64
- `curl`、`tar`（Linux 精简镜像若没有 `xz`，脚本会尝试 apt/apk 安装；完全无 sudo 的环境请先自行装 `xz`）
- 能访问 nodejs.org、registry.npmjs.org、github.com（大陆网络如走代理，先 `export HTTPS_PROXY=...`）
