# 修复说明（FIXES）

本仓库是 [fscarmen/warp](https://github.com/fscarmen/warp)（GitLab: `fscarmen/warp`）的 fork。

- 基线版本：上游 commit `61defcd`（2026-09-19）
- 改动范围：**只修缺陷**，不新增功能、不改变既有交互与文案
- 许可证：沿用上游 **GPL-3.0**（见 [LICENSE](LICENSE)），原始版权归原作者

所有改动均可由 `bash tests/self-test.sh` 复现验证（用 mock `ip` 复刻 Linux FIB 规则语义，
在 Windows/macOS/Linux 上都能跑，不需要真实 WARP 环境）。

---

## 一、P0：会导致「拿不到 WARP IP」的缺陷

这一组是同一个故障链上的四个环节，叠加起来表现为：
**香港 / 日本等需要重试的区域，`warp 4` / `warp 6` / `warp d` 永远拿不到 WARP IP，而同一台机器上 `warp-cli` 正常。**

### 1. `NonGlobal.sh` 的 start / stop 规则不对称（`menu.sh`）

原代码（生成在 `/etc/wireguard/NonGlobal.sh`）：

```bash
start)  ip -4 rule add from 172.16.0.2 lookup 51820   # 加的是这条（v4）
        ip -6 rule add oif warp lookup 51820          # v6 是这条
stop)   ip -4 rule delete oif warp lookup 51820       # 却去删这条，它从未被添加
        ip -6 rule delete oif warp lookup 51820
```

v6 两侧都是 `oif warp`，**只有 v4 那行抄错了**。同一文件里的 `rule_del()` 就是正确写法
（`ip -4 rule delete from 172.16.0.2 lookup 51820`）。

**后果链**：`stop` 的 delete 必然返回非 0 → 它挂在 `PostDown` 上 → `wg-quick` 顶层有 `set -e -o pipefail`
且 `execute_hooks()` 没有 `|| true` 保护 → `wg-quick down` 以非 0 退出 → `wg-quick@.service` 的
`ExecStop` 失败 → **systemd 把整个 `systemctl restart` 判为失败并中止，不再执行 `ExecStart`**
→ `menu.sh` 里 `net()` 的重试退化成「只拆不建」，5 次重试全部空转。

**修复**：重写 `NonGlobal.sh` —— start / stop 严格对称、del 循环删除直到无匹配（可自愈历史残留）、
所有命令返回 0。

### 2. `PostUp` 的 `ip rule add` 不幂等，失败即中断（`menu.sh`）

生成的 `warp.conf`：

```
PostUp = ip -4 rule add from <原生IP> lookup main
```

`ip rule add` 不是幂等的：规则已存在（上次未清理干净）时返回

```
RTNETLINK answers: File exists
```

`wg-quick` 因 `set -e` 中止 `up()`，而 `cmd_up` 开头的 `trap 'del_if; exit'` 会
**把刚建好的接口立刻删掉** → 现象是「接口未建立」，而且残留规则不清掉就永远自锁死。

同一个文件里 `rule_add()`（Client 模式用的）写的是 `ip rule show | grep -q ... || ip rule add ...`，
本来就是幂等的 —— 正确写法就在旁边。

**修复**：`$RULES` 里全部 14 条 rule/route 型 hook 追加 `2>/dev/null || true`，
任何一条失败都不会再中断 `wg-quick`。

### 3. reserved 转十进制依赖 locale（`menu.sh` / `api.sh`）

原实现逐字符取码点：

```bash
printf "%d, " "'$c"     # 依赖 locale，多字节环境下会把高位字节算错
```

**实测**：`client_id = y8eh` 正确值是 `[203,199,161]`，旧算法算出 `[203,199,737]`。
`737 > 255` 属非法值，而**打补丁的 wireguard-go 解析失败时会静默回落成 `[0,0,0]`**
（二进制内的提示串：「Reserved格式错误，使用默认是值 [ 0, 0, 0 ]」）。
在需要 reserved 的地区，CF 会直接丢弃握手 → 表现为 `rx=0`。

**修复**：改为取 base64 原始字节，与 locale 无关：

```bash
printf '%s' "$CLIENT_ID" | base64 -d | od -An -tu1
```

`menu.sh` 新增 `reserved_decode()`，`api.sh` 新增 `reserved_from_client_id()`；
都以 `client_id` 为准，读不到时回落到账户文件里已有的 `reserved` 数组。

> 注：生成的 `warp.conf` 里那行 `#Reserved = [...]` **必须保持注释状态** —— 补丁版
> wireguard-go 专门去读 `#Reserved=` 这一行，前置 `#` 是为了让标准 `wg setconf` 不把它当未知键报错。
> 这不是 bug（上游代码正确）。

### 4. 失败原因被 `>/dev/null 2>&1` 吞掉（`menu.sh` 的 `net()`）

```
${SYSTEMCTL_RESTART[int]} >/dev/null 2>&1
```

重试阶段的报错全部丢弃；而最后打印的 `ERROR_MESSAGE` 来自单独执行的一次
`wg-quick up warp`——**它其实是成功的**，于是错误信息是空的，用户只能看到
「失败已超过 N 次，不知道什么原因」。

**修复**：保留 restart 的退出码与输出，当 `wg-quick up` 无输出时把它们一并打印出来。

---

## 二、P1：确定存在、但影响面小一些的缺陷

| # | 位置 | 问题 | 修复 |
|---|---|---|---|
| 5 | `menu.sh` iptables 分流方案 | `Predown` 拼错（应为 `PreDown`）。wg-quick 键名大小写敏感，导致 `/etc/wireguard/down` **永不执行**，关闭后 iptables mangle 规则、ip rule、ipset 全部残留 | 改为 `PreDown`，并给 up/down 全部命令加 `\|\| true` + 先清理后建立（幂等）、down 补上 route 清理 |
| 6 | `menu.sh` 同处 | `sed -i "s/^Post.*/#&/g"` 会把 `install()` 刚写入的 keepalive `PostUp/PostDown` **一并注释掉**，导致 v3.2.7 新增的自动保活在该方案下失效 | 新 sed 跳过 `keepalive.sh` 行 |
| 7 | `menu.sh` `text()` / `warp-go.sh` `text()` | `local -n`（nameref）**要求 bash ≥ 4.3**，CentOS 7 自带 4.2.46 → `text()` 全部返回空串，菜单与提示整片空白 | 按 `BASH_VERSINFO` 判断，低版本走 eval 取值 |
| 8 | `menu.sh` `check_cdn()` | 真正的探测被 `#####` 注释掉，`CODE=200` 被硬编码 → 整个 `GITHUB_PROXY` 反代数组 + 并发探测成为**死代码** | 恢复 `CODE=$(get_code "$API_URL")` |
| 9 | `warp-go.sh:1371` | `PRIORITY_SWITCH=PRIORITY_SWITCH="${2,,}"` 笔误，变量被赋成字面量 `"PRIORITY_SWITCH=4"`，导致 `warp-go s 4` 不静默生效反而弹菜单 | 改为 `PRIORITY_SWITCH="${2,,}"` |
| 10 | `warp-go.sh:351` | `DEPS_INSTALL+=("vim-common")` 紧接下一行被整体重新赋值覆盖 → 死代码，CentOS 上不会装 vim | 挪到整体赋值之后 |
| 11 | `warp-go.sh` sing-box 导出 | 三行 sed 取 reserved 时，**第 1 个值取的其实是第 3 个**（3/2/3 而非 1/2/3），导出的 sing-box `reserved` 是错的 | 修正为分别取第 1/2/3 个数 |
| 12 | `api.sh:331` | `masque_enroll_account()` 在私钥为空时报 `"Private key found in config file. Please check if it is valid."` —— **语义完全反了** | 改为 `"Private key not found in config file. Please register first."` |
| 13 | `warp-go.sh` `NonGlobal.sh` | 与 #1 同源：`stop` 不删 route（`default dev WARP table 60000`），反复开关会残留 / 重复添加 | 与 menu.sh 同款重写（对称 + 循环删除 + 恒返回 0） |
| 14 | `docker.sh` | **整份 675 行脚本被完整写了两遍**，且第 676 行是 `esac#!/bin/bash`（第一份的 `esac` 与第二份的 shebang 粘连），第二份结尾还缺 `esac` | 去重为单份（1350 行 → 676 行） |

---

## 三、为让 fork 真正可用而必须做的改动

| 项 | 说明 |
|---|---|
| **自引用地址** | 脚本/文档里指向原仓库的下载、自升级、错误反馈链接全部改指本仓库 `misakacoo/cf-warp`（`raw.githubusercontent.com/misakacoo/cf-warp/main/...`）。否则：`menu.sh` 注册时会去拉**上游未修复的** `api.sh`；`warp v` 自升级会把修复覆盖回原版。 |
| **停用自动同步 CI** | `.github/workflows/` 下有 5 个每天定时的工作流（`sync_project` / `sync_warp-go` / `sync_wgcf` / `sync_wireguard-go` / `sync_wireproxy`），会自动 `sed` 版本号并 commit/镜像到 GitLab、Bitbucket。在 fork 里会干扰本地修复，已注释掉 `schedule:`，保留 `workflow_dispatch` 手动触发。 |
| **保留指向上游的地址** | 第三方资源不动：`fscarmen/warp_unlock`（解锁检测）、`ProjectWARP/warp-go`、`fscarmen/tools`、以及 `github.com/fscarmen/warp/releases/download/resolvconf/resolvconf`（发布资产，本 fork 未建 release，保持指向上游才能下载）。 |

---

## 四、已知但**未**改动的事项（需要时自行决定）

1. **运行统计上报**：脚本每次运行会向 `stat.cloudflare.now.cc` 上报运行次数，无开关。
   这是上游的遥测，不属于缺陷，故未改动。
2. **`warp-go.sh` 的 `[Script] PostUp/PostDown` 未加 `|| true`**：
   warp-go 的配置由第三方二进制解析（其 ini tag 为 `delim:";"`），
   无法确认它把整串交给 `sh -c` 还是按空格拆成 argv。为免引入新问题，这里保持原样；
   该路径的 `set -e` 问题不存在（不是 shell 在执行），NonGlobal.sh 的重写已覆盖主要风险。
3. **仓库体积约 199 MB**：`wgcf/` 73 MB + `wireguard-go/` 73 MB + `warp-go/` 17 MB +
   `wireproxy/` 9.6 MB + `endpoint/` 6.2 MB，都是上游随仓库分发的各平台二进制。
   单个文件最大 12.4 MB，未触及 GitHub 的限制。不需要的架构可以直接删掉以瘦身。
4. **`.gitlab-ci.yml`** 保留（上游用它跑 GitLab CI）；本仓库在 GitHub，不会执行。
5. **共享免费账户**：上游仓库内硬编码了一份共享免费 WARP 账户（私钥 + token）。
   这不是缺陷，但如果介意，建议自行删除相关常量。
6. **外部单点依赖**：`ip.cloudflare.nyc.mn` 等自建优选服务、若干 `bash <(curl ...)` 的
   远程脚本直执行，属于上游设计，未改动。

---

## 五、验证方式

```bash
# 单元 / 集成自测（mock ip，复现内核 FIB 语义，含旧版对照组）
bash tests/self-test.sh

# 语法检查
for f in menu.sh api.sh warp-go.sh docker.sh pc/mac.sh; do bash -n "$f"; done
```

自测会验证：
- NonGlobal.sh 的 start 幂等（连跑 3 次仍只有 1 条规则）、stop 一次性清空、能自愈 5 条历史重复规则、退出码恒为 0；
- **对照组**同时跑一遍旧版 `NonGlobal.sh`，确认它确实会残留规则并返回非 0（证明测试有效）；
- 有残留规则时 `PostUp` 行返回 0；
- `up` / `down` 幂等、`PreDown` 拼写、端到端 sed 不会误注释 keepalive；
- `reserved` 解码对 `y8eh` / `rRV4` / `abcd` 的结果与 `od` 直算一致；
- bash < 4.3 的 `text()` 回落分支实际可用。

### 真实环境验证

以上 P0 项已在两台真实 VPS 上验证过：修复前 `wg-quick up` 报
`RTNETLINK answers: File exists` 随后接口被 EXIT trap 删除；
按本仓库的修法处理后再启动，**第一个 Endpoint（`engage.cloudflareclient.com:2408`）即握手成功**，
`cdn-cgi/trace` 返回 `warp=on`，`systemctl restart wg-quick@warp` 退出码 0，
连续两次 restart 后规则数稳定为 1 条（不再累积）。

> 结论：这类「拿不到 WARP IP」绝大多数不是「UDP 被机房封锁」，而是上述脚本缺陷导致接口根本没能建起来。
> 只有在清掉残留、确认 `wg-quick up` 干净成功之后，才需要去怀疑 UDP 路径。
