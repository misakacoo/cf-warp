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
| **统一 LF 换行** | 新增 `.gitattributes`（`*.sh` / `*.md` / `*.yml` 等一律 `eol=lf`，二进制标为 `binary`）。Shell 脚本一旦带 CRLF，在 Linux 上会报 `$'\r': command not found`；`endpoint/ipv4`、`endpoint/ipv6` 这类 CIDR 列表带 `\r` 也会解析失败。 |
| **版本号标记** | `menu.sh` → `v3.2.8`、`warp-go.sh` → `v1.3.3`，便于与原版区分。两处 `VERSION` 变量只用于界面显示、代码里没有任何版本比较逻辑，因此改动无副作用（`warp v` 也不做版本判断，直接覆盖脚本）。 |
| **README 更新** | 顶部加 fork 说明与「快速开始（VPS 安装）」（安装 / 验证 / 分流 / 升级 / 从原版迁移），更新信息里补本次修复条目；顺手修正上游遗留的过时项：选项表里的 `p`（刷 Warp+ 流量）在当前代码中已无实现。 |
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

## 五、第二轮修复（v3.2.9 —— 2026-10-13 在真实 VPS 上复现并定位）

第一轮修完后，真实机器上仍然「拿不到 WARP IP」。上机抓到了完整证据链，是**另一组互相纠缠的缺陷**：

### 1. 保活脚本的「启动即巡检」引发自我放大的重启风暴（`menu.sh` 生成的 `keepalive.sh`）

原循环：

```bash
while true; do
  if wg | grep -q 'warp'; then warp n >/dev/null 2>&1 & fi   # ← 每轮先执行
  sleep "${INTERVAL:-5m}" & wait
done
```

每次接口 `up` 都会由 `PostUp` 启动本循环，而**循环一启动就立刻执行一次 `warp n`**；
`warp n` 又会重启接口 → 新的 `up` 又启动一个循环……**正反馈**。

实测数据：`journalctl` 里 **每分钟 60~330 次 `wg-quick` 起停**，同时有 **4 个 `warp n` 进程并发**，
接口被反复拆建、永远等不到一次完整握手。

**修复**：启动后先给 `FIRST_DELAY`（默认 30s）稳定时间再巡检，之后每 `INTERVAL`（默认 5m）一次。
注意**不能简单改成「先睡满 5 分钟」** —— WARP 链路本身不稳，那样断联最长 5 分钟才被发现，
所以保留了「启动后的一次巡检」，只是给了它稳定时间。

### 2. `NonGlobal.sh` 的匹配串用了 add 形态，导致「加不查重、删不进循环」

```bash
rule_add 4 "table main suppress_prefixlength 0"     # add 命令写法
# 但 `ip -4 rule show` 显示的是：
#   32480:	from all lookup main suppress_prefixlength 0
```

`grep -qF "table main suppress_prefixlength 0"` 永远匹配不上显示结果 → `rule_add` 每次都真的再加一条、
`rule_del` 的循环一次都不进。实测该规则累积到 **47 条**（v4/v6 各 47）。
`warp-go.sh` 的 `NonGlobal.sh` 有同样问题。

**修复**：统一用显示形态 `from all lookup main suppress_prefixlength 0`（已验证两种写法的显示结果一致）。

### 3. 保活的巡检条件会让「接口消失」变成永久断联

原条件是 `if wg | grep -q 'warp'` —— 只有**接口还在**时才巡检。
用户态实现（wireguard-go）崩溃时接口会直接消失，此时保活认为「无需巡检」，**永久放弃**，
WARP 再也回不来。而「用户主动关闭 WARP」其实是由 `PostDown → keepalive.sh stop` 杀掉整个循环来保证的，
所以条件可以安全放宽。

**修复**：改成只看 `[ -e /etc/wireguard/warp.conf ]`（= 处于「已安装」状态就巡检）。

### 4. `net()` 失败时会把接口拆掉，同样造成永久断联

原失败收尾是 `wg-quick down` → 打印错误 → `wg-quick down`，最终留下一个**不存在的接口**；
结合第 3 点，保活再也不会重试。

**修复**：失败收尾不再拆接口，保留已尽力拉起的接口，让下一轮巡检还有机会自愈。

### 5. 成败判断依赖一个有 2 秒超时的自建 API

```bash
IP_JSON=$(curl --retry 2 -ksm2 $INTERFACE_SOCK5 -$CHECK_46 http://ip.cloudflare.nyc.mn${IS_CHINESE})
IP_TRACE=$(awk ... '/"warp"/{print $4}' <<< "$IP_JSON")
```

实测在 WARP 链路不稳时，这条命令**退出码 28（超时）、响应为空** → `trace` 为空 →
上层把「链路暂时不稳」误判成「WARP 没装上」→ 不停拆建接口。
另外原来写成 `local A=$(..) && local B=$(..) && local C=$(..)`，curl 一失败后面两个赋值会被短路跳过，
变量会残留上一轮的旧值。

**修复**：① 拆开为独立赋值；② 拿不到 trace 时用 **Cloudflare 官方 `cdn-cgi/trace`**（走同一个接口、
权威、无第三方依赖）补齐 `warp` / `ip` / `loc`。

### 6. 重试路径在「接口残留但 wg 不认」时彻底救不回来

`wg-quick` 有两处自锁死，且都发生在 `EXIT trap` 注册之前，它自己不会清理：

- `cmd_up` 开头：`ip link show dev warp` 有结果就 `die "'warp' already exists"`
- `cmd_down` 开头：`wg show interfaces` 不含 `warp` 就 `die "'warp' is not a WireGuard interface"`

两者叠加时 `up` / `down` 双双失败，`systemctl restart` 也一样（ExecStop 非 0 会中止整个 restart）。

**修复**：新增 `warp_if_hard_reset()`（`wg-quick down` → 兜底 `ip link delete` → 杀 `wireguard-go` → 清 socket，恒返回 0），
在 `net()` 起始、每次重试前、切 reserved 分支、失败诊断前都调用；
重试改为 `systemctl stop` → 硬复位 → `reset-failed` → `systemctl start`（不再用 `restart`）。

### 7. 并发保护：用 PID 文件而不是 flock（这是本轮踩到的坑）

`net()` 会被保活的 `warp n`、安装流程、手动重试同时进入，多个实例互相重启接口就谁也好不了，
所以加了单实例锁。但**第一版用 flock 是错的**：`exec 8>lock; flock -n 8` 的锁 fd 会被 fork 到后台的
`wireguard-go` 继承并常驻，锁被永久占住 → 之后所有 `net()` 都在 `flock -n` 处静默返回 →
**WARP 反而再也拉不起来**（自愈测试直接失败，实测确认）。
改用 PID 文件（内容为 PID，配合 `kill -0` 判活，正常结束时删除），并注意**不能用 `trap ... EXIT` 去删**
—— 脚本第 12 行已有 `trap cleanup_temp EXIT`，覆盖它会让临时文件清理失效。

### 本轮验证（真实机器）

| 项目 | 结果 |
|---|---|
| 重启风暴 | 修复前每分钟 60~330 次 `wg-quick` 起停 → 修复后 100 秒内 **1 次** |
| 规则累积 | suppress 规则从 47/47 → 清理后稳定在 **1/1**，多次 `warp n` 后不再增长 |
| `warp n` 收敛 | 日志显示 **第 1 次尝试即成功**（修复前空转到第 3~5 次仍失败） |
| 出口 | `curl --interface warp` → `ip=104.28.211.105 warp=on loc=JP` |
| **断联自愈** | 直接删掉 `warp` 接口（模拟 wireguard-go 崩溃）后，保活 **10 秒内自动重建并握手成功** |
| 回归自测 | `bash tests/self-test.sh` 全部通过（新增第 8 节专门覆盖本轮缺陷） |

---

## 六、第三轮修复（v3.2.10 —— IPv6 那一行显示成了 IPv4 地址）

### 现象

安装完成后脚本回报：

```
 IPv4: 104.28.211.105 日本  Cloudflare, Inc.
 IPv6: 104.28.211.105 JP          ← 与 IPv4 完全相同
```

但同一台机器上第三方脚本（`ip.sh`）读到的 WARP IPv6 是正常的
（`2a09:bac1:3b60:10::16:1da`），接口上也有 `inet6 2606:4700:110:808c:.../128`。
即：**只是取值取错了，WARP 的 IPv6 本身没问题。**

### 根因（第二轮引入的回归）

第二轮为「自建 API 抖动就误判失败」加的 Cloudflare 官方 trace 兜底，**漏了协议限定**：

```bash
# 错：不指定 -4 / -6，curl 会走系统首选协议（通常 IPv4）
local TRACE_RAW=$(curl -ksm8 --retry 2 $INTERFACE_SOCK5 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
```

`cdn-cgi/trace` 是双栈可达的，于是 `ip_info 6` 拿回的仍是 IPv4 地址。

为什么 v6 一定会走到这个兜底？因为**经 warp 的明文 HTTP（80 端口）不通、HTTPS（443）通**：

| 请求（均经 warp 接口） | 结果 |
|---|---|
| `curl -6 -ksm3 http://ip.cloudflare.nyc.mn` | **rc=28 超时** ← 主路径必然失败 |
| `curl -4 -ksm3 http://ip.cloudflare.nyc.mn` | rc=0，正常 |
| `curl -6 https://www.cloudflare.com/cdn-cgi/trace` | 正常，返回 `2a09:...` |

所以 v6 这条路径**每次都**落到兜底分支，`-4/-6` 一旦漏写就 100% 复现错误显示。

### 修复

1. 兜底补上 `-$CHECK_46`（`menu.sh`）：

```bash
local TRACE_RAW=$(curl -ksm8 --retry 2 $INTERFACE_SOCK5 -$CHECK_46 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
```

2. 顺带补全国家名与运营商：官方 trace 只给 `loc=` 两位国家码、没有 ISP，
   会让 v6 显示成「`2a09:... JP`」而 v4 是「`104... 日本 Cloudflare, Inc.`」，看着仍像坏了。
   改用 trace 拿到的 IP 去自建 API 反查（该接口同时支持 v4/v6 字面量），
   且**不绑定 warp 接口**（走原生网络，避开上面那个 HTTP over IPv6 超时）；
   反查成功时以它为准，失败则保留 trace 的原值，不阻塞主流程。

### 实测（真实 VPS，同一台）

修复前（旧 `menu.sh`）：

```
ip_case 6 warp non-global -> WAN6=104.28.243.105     ← 与 WAN4 相同
ip_case 4 warp non-global -> WAN4=104.28.243.105
```

修复后：

```
L=E  v6: WAN6=2a09:bac1:3b60:10::16:183  COUNTRY6=JP    ASNORG6=Cloudflare, Inc.
     v4: WAN4=104.28.211.105             COUNTRY4=JP    ASNORG4=Cloudflare, Inc.
L=C  v6: WAN6=2a09:bac1:3b60:10::16:183  COUNTRY6=日本  ASNORG6=Cloudflare, Inc.
     v4: WAN4=104.28.211.105             COUNTRY4=日本  ASNORG4=Cloudflare, Inc.
```

`warp n` 的端到端输出（用户实际看到的那两行）：

```
 IPv4:104.28.211.105 日本 Cloudflare, Inc.
 IPv6:2a09:bac1:3b00:10::16:215 日本 Cloudflare, Inc.
```

自测新增 4 条断言，其中：
- 「trace 兜底带 `-$CHECK_46`」直接防住本次回归；
- 「`ip_info` 内所有 trace 调用都限定协议」会遍历该函数里**非注释**的 trace 调用行，
  将来再加调用点也会被拦住。

> 附带说明：`menu.sh` 里还有一处不带 `-4/-6` 的 `cdn-cgi/trace` 调用
> （判断 VPS 原生优先栈的 `PRIO`），那是**故意**的 —— 它要测的就是「系统默认走哪个协议」。

---

## 七、第四轮修复（v3.2.11 —— 让分流规则彻底幂等，残留不再累积）

### 现象

第三轮修完后，在一台已连续运行约 3 天的 VPS 上复查，发现 `ip rule` **又在增长**：
`v4 = 40` 条、`v6 = 11` 条，其中 5 个内网网段规则各有 **6 份**重复。

### 根因：`add` 与 `delete` 的语义不对称

`warp.conf` 里那 7 条内网 / Docker 规则走的是裸 `PostUp` / `PostDown`：

```
PostUp   = ip -4 rule add    from 172.17.0.0/16 lookup main 2>/dev/null || true
PostDown = ip -4 rule delete from 172.17.0.0/16 lookup main 2>/dev/null || true
```

第三轮给它们补了 `|| true`，解决了「EEXIST 中断 `up()`、EXIT trap 删掉接口」这个致命问题；
但两条语义**仍然不对称**：

- `add` 因为 `|| true` 把 EEXIST 吞掉 —— 等于幂等（既不新增也不报错）；
- `delete` **一次只删一条** —— 历史重复规则永远清不掉。

于是只要有几次「`up` 成功但 `down` 没走完 `PostDown`」（例如保活循环的 `warp n` 与人工
`systemctl restart` 撞在一起），重复就会长期留存，而且**没有任何机制能让它收敛**。
极端情况下累积到 4681 条（`from 172.16.0.2 lookup 51820`），既拖慢 `ip rule show`，也让排障变困难。

### 修法：所有 rule 操作收敛到一个幂等操作器

新增 `/etc/wireguard/Rule.sh`（由 `install()` 生成，与 `NonGlobal.sh`、`keepalive.sh` 并列）：

```
Rule.sh add|del <4|6> "<规则串，用 ip rule show 的显示形态>"
```

- `add`：**先 `del` 清空同名规则，再添加一条** → 无论历史上累积了多少份，一次 `up` 就收敛到恰好 1 份；
- `del`：循环删到没有为止（上限 5000）；
- 任何路径都以 `exit 0` 收尾 → 永不中断 wg-quick 的 `up()` / `down()`。

`warp.conf` 的 4 条 LAN / LAN6 规则 + 7 条内网 / Docker 规则全部改为调用它：

```
PostUp   = /etc/wireguard/Rule.sh add 4 "from 172.17.0.0/16 lookup main"
PostDown = /etc/wireguard/Rule.sh del 4 "from 172.17.0.0/16 lookup main"
```

匹配串刻意写成 `ip rule show` 的**显示形态**（`from all lookup main suppress_prefixlength 0`），
而不是 `ip rule add` 的写法（`table main suppress_prefixlength 0`）—— 后者永远匹配不上，
会造成「加不查重、删不进循环」的双向失效（实测累积到 47 条）。

### 同批改动

- `NONGLOBAL_UP` / `NONGLOBAL_DOWN` 与 `keepalive.sh start` / `stop` 两条钩子也补上
  `2>/dev/null || true`（安全网，防将来被改坏）；
- `change_warp`（`warp i` 换 IP 那条路径）里 reserved 的取法改为与主安装路径一致的
  `reserved_decode`，不再直接转录账户文件里的数组；
- `uninstall` 的清理列表补上 `Rule.sh`。

### 实测（mock `ip`，复现内核语义）

| 场景 | 结果 |
|---|---|
| 预置 6 份重复 → `Rule.sh add` | 收敛为 **1 份**，退出码 0 |
| 再 `add` 一次 | 仍 **1 份**（幂等） |
| `Rule.sh del` | **0 份**，退出码 0 |
| `del` 一个不存在的规则 | 退出码 **0** |
| 不带参数 | 退出码 **0** |
| `PATH` 里没有 `ip` | 退出码 **0**（不会打断 wg-quick） |
| 用显示形态的 spec 删 `suppress_prefixlength` | 2 份 → **0 份** |

> 结论：**历史残留会在下一次 `wg-quick up` 时被自动收敛**，不再需要手工清理；
> 也不会再累积。这项改动对已在跑的机器同样生效 —— 不需要重装，只要让它经历一次 up/down。

---

## 八、第五轮修复（v3.2.12 —— 接口已删除后，oif 规则一份都清不掉）

### 现象

v3.2.11 部署到真机并重启接口后复查：v4 已收敛到每条 1 份，但 v6 始终留着 **3 份**
`from all oif warp lookup 51820` —— `NonGlobal.sh stop` 反复跑也清不掉。

### 根因：`oif <dev>` 规则在设备被删除后会多出 ` [detached]`

`wg-quick` 的 `cmd_down()` 顺序是：

```
PRE_DOWN → save_config → del_if → unset_dns → remove_firewall → POST_DOWN
```

`del_if`（删接口）排在 `POST_DOWN` **之前**，所以 `NonGlobal.sh stop` 执行时 `warp` 接口早就没了。
此时 `ip -6 rule show` 的输出变成：

```
32719:	from all oif warp [detached] lookup 51820
```

比 `add` 时多出 ` [detached]`，于是 `grep -qF "oif warp lookup 51820"` 永远匹配不上，
`rule_del` 的 while 循环一次都不进入 —— 这条规则一份都清不掉（实测 3 份）。

### 修法

1. **匹配容忍 `[detached]`，删除一律按 pref**：不再用 `grep -qF` + `ip rule delete <spec>`，
   而是先用正则找到第一个匹配的 pref，再 `ip rule delete pref <N>` ——
   不依赖 spec 能否被 iproute2 解析（设备已删时按 spec 删也会失败）。
2. **oif 规则的匹配写成 `oif .*lookup <表号>`**，不要去匹配字面量 `[detached]`。
   坑：sed 替换部分里的 `\[` 会被吃掉，`[detached]` 会退化成字符类 `[deach]`，反而永远匹配不上 ——
   这个坑让自测红了两次才定位到。
3. `Rule.sh` 与 `NonGlobal.sh` 使用同一套逻辑，避免以后再分叉。

### 实测（mock `ip`，可模拟 `[detached]` 显示形态）

| 场景 | 结果 |
|---|---|
| 3 份 `oif warp lookup 51820` + 设备已 detached → `NonGlobal.sh stop` | 全部清掉，退出码 0 |
| 同上 → `Rule.sh del 6 "oif warp lookup 51820"` | 全部清掉，退出码 0 |
| **对照组**（旧实现：原样 `grep -F` + 按 spec 删） | 3 份原封不动 —— 证明该测试确实能测出问题 |
| 同轮 v4 规则 | 一并清空 |

自测在真机（Debian 12）上 **94 项全通过**。

---

## 九、第六轮修复（v3.2.13 —— IPv6 那一行空白：兜底链路不能依赖 DNS）

### 现象

非全局 + 双栈的机器，安装完 `warp n` 明明成功（IPv4/IPv6 都有值），但随后直接运行
`warp` 进菜单时 **`IPv6:` 那一行是空的**，`IPv4:` 却有值。

### 根因一：整条兜底链都要先过 DNS

`ip_info()` 对每个地址族取值只有两条路：

| 顺序 | 来源 | 依赖 |
|---|---|---|
| 主路径 | `http://ip.cloudflare.nyc.mn`（自建、明文 80、`-m2`） | **DNS** + 明文 HTTP |
| 兜底 | `https://www.cloudflare.com/cdn-cgi/trace` | **DNS** |

而 `ip.cloudflare.nyc.mn` 这个自建域名近期在很多地区**解析失败**（warp-sh issue #193 / #231，
临时办法是写 `/etc/hosts`）。于是机器上 DNS 一旦不稳，**主路径与兜底会一起失败** ——
v4 侧因为主路径偶尔能通所以一直有值，v6 侧没有任何余量，于是那一行直接空白。

### 根因二（更隐蔽）：v6 的兜底不能用 IPv4 字面量

把兜底换成 IP 字面量时，最容易顺手写成 `https://1.1.1.1/cdn-cgi/trace` ——
但 `1.1.1.1` 是 **IPv4 字面量**，配 `-6` 时 curl 只能按 `::ffff:` 映射去连。实测（同一台机器、同一时刻）：

| 请求 | 结果 |
|---|---|
| `curl -6 --interface warp https://1.1.1.1/cdn-cgi/trace` | `rc=7`（连不上） |
| `curl -6 --interface warp https://[2606:4700:4700::1111]/cdn-cgi/trace` | `rc=0` `ip=2a09:… warp=on` |
| `curl -4 --interface warp https://1.1.1.1/cdn-cgi/trace` | `rc=0` `ip=104.28.… warp=on` |

也就是说：**v6 必须用 1.1.1.1 的 IPv6 地址字面量**，否则「兜底看着存在、却永远失败」，
问题看起来修了其实没修。

### 修法

`ip_info()` 的兜底改成「协议相关候选清单 + 两轮」，候选里 IP 字面量优先、域名最后：

```
v4: https://1.1.1.1/cdn-cgi/trace              → https://1.0.0.1/cdn-cgi/trace        → https://www.cloudflare.com/cdn-cgi/trace
v6: https://[2606:4700:4700::1111]/cdn-cgi/trace → https://[2606:4700:4700::1001]/… → https://www.cloudflare.com/cdn-cgi/trace
```

1. **字面量优先**：完全不经过 DNS，DNS 挂掉时仍能救回显示。域名候选**保留在最后一档**，
   不能删 —— 在「1.1.1.x 被本地/上游屏蔽」的网络里它反而是唯一能通的一条。
2. **字面量与协议严格匹配**（上面的实测表就是依据）。
3. **两轮**：第一轮 3 个候选各 `-m8`；第一轮全空时，只对**第一个候选**再打一轮、超时放宽到 `-m12`。
   收紧第二轮范围是为了不让最坏耗时翻倍。最坏 ≈ 3×8 + 12 = 36s，与旧实现（主路径 `-m2 --retry 2`
   + 兜底 `-m8 --retry 2`）大致相当；正常路径（第一个候选就成功）仍然只发一次请求。
   12s 那一轮是给「接口刚被硬复位重建、首次握手还没完成」的空窗留的。
4. 所有 trace 调用继续带 `-$CHECK_46`（v3.2.10 那轮的教训：漏写会让 IPv6 显示成 IPv4）。

### 为什么值得修（不只是显示问题）

`net()`（`warp n`）的成功判据是 `[[ "$TRACE4$TRACE6" =~ on|plus ]]`，取值来自 `ip_info`。
所以**兜底取不到 trace 时，保活会认为「链路没起来」**，然后进入「`systemctl stop` → 硬复位 →
`reset-failed` → `start`」的重试循环（最多 5 轮，每轮都把接口拆建一次），最后报错退出。
一次 DNS 抖动就可能换来 5 轮拆建 —— 这正是「后台一直静默重连」的来源之一。
把兜底改成不依赖 DNS，同时也让这条**检测**可靠了。

### 测试方法（这轮踩到的最大一个坑）

验证「DNS 全挂时还能不能取到 IP」需要让 DNS 失败。**第一版做法是直接往宿主 `/etc/hosts`
里写测试条目** —— 结果保活的 `warp n` 恰好在那 30 秒内巡检，因为 trace 全失败而
把接口拆了、没能拉回来，**WARP 中断约 1 分钟**（18:26:29 停、18:27:24 才被我手动拉起）。

正确做法是**进程级隔离**——用 mount namespace 只让本次进程看到假的 hosts：

```bash
printf '127.0.0.1 ip.cloudflare.nyc.mn\n127.0.0.1 www.cloudflare.com\n' > /tmp/fake_hosts
unshare -m --propagation private bash -c '
  mount --bind /tmp/fake_hosts /etc/hosts
  ... 在这里跑 curl / ip_info ...
'
# 宿主 /etc/hosts 的 sha256 前后一致（脚本里直接核对）
```

配套两条纪律，之后所有真机实验都按这个来：
- 测试前先 **停掉保活巡检**（`/etc/wireguard/keepalive.sh stop`），测完拉回来，
  并挂一个「死人开关」（`setsid nohup bash -c 'sleep 300; keepalive.sh start'`）防止中途失败把自愈关掉；
- 每轮测量前先做**基线校验**（接口 up + `curl --interface warp` 拿到 `warp=on`），
  基线不健康就整轮作废、不下结论。

### 实测（真机 Debian 12，非全局 + 双栈）

| 场景 | 旧版 v3.2.12 | 新版 v3.2.13 |
|---|---|---|
| 正常环境 `ip_info 4` | 空（自建 API 域名解析失败、兜底同样要 DNS） | `ip=104.28.211.105 loc=JP warp=on` |
| 正常环境 `ip_info 6` | 空 | 有值 |
| DNS 全挂 `ip_info 4/6` | 空 | 有值（走 IP 字面量，不需要 DNS） |

### 顺带记录：`warp n` 每 5 分钟会重建一次接口

`net()` 开头（menu.sh:1395-1397）是**无条件**的「硬复位 → 起服务 → `wg-quick up`」，
而保活循环每 `INTERVAL`（默认 5m）就执行一次 `warp n`。所以：

- WARP 每 5 分钟会被拆掉重建一次，重建窗口内（实测约十几秒）**经 warp 接口的查询必然失败**；
- 这段窗口里打开菜单 / 跑 `ip_info`，同样会看到空白或 `rx=0` —— 与上面那个 DNS 根因是两种不同的成因，
  排查时要先看「接口当时在不在」；
- 这是上游 v3.2.7 引入的保活设计（「断联必须能较快发现并重连」），本轮**没有改动频率**，
  以满足「任何降容错改动都必须保留检测 + 自愈」的约束。

---

## 十、第七轮修复（v3.2.14 —— 保活不再无条件重建接口：链路好就别动它）

### 现象

WARP 用起来是好的，但**出口 IP 每 5 分钟换一次**。用户访问的网站、账号系统看到的都是一个不断跳动的 IP，
对依赖固定出口的场景（登录态、风控、白名单）很不利。

### 根因

1. 保活循环每 `INTERVAL`（默认 5 分钟）执行一次 `warp n`：
   ```bash
   if [ -e /etc/wireguard/warp.conf ]; then
     warp n >/dev/null 2>&1 9>&- &
   ```
2. 而 `net()` 开头是**无条件**的：
   ```bash
   warp_if_hard_reset                 # 硬复位（拆掉接口）
   ${SYSTEMCTL_START[int]}            # 重新起服务
   wg-quick up warp                   # 重建接口
   ```
   也就是说 —— **不管链路好不好，先把接口拆了重建**。重建会重新注册/分配，于是 WARP IP 每次都变。

实测一次 `warp n`：`104.28.211.105` → `104.28.243.105`，接口缺失约 1s、完整就绪约 6s。

> 附带影响：这段重建窗口里跑 `ip_info` 会得到空白 / `rx=0`。排查「拿不到 IP」时必须先确认
> 「接口当时在不在」，否则会把重建窗口的假失败当成本故障。

### 修法：把「无条件重建」改成「按需重建」

新增只读体检 `net_healthy()`，并在 `net()` 里作为**默认模式**接入：

- **判据**（与 `net()` 自身的成功判据保持一致）：接口存在，且**至少一个**「经 warp 转发」的
  地址族（`AllowedIPs` 未被注释）能经接口拿到 `warp=on/plus`。
- **健康** → 打印 IP 后直接返回，**不碰接口**（只释放单实例锁）。
- **不健康** → 打印「链路断开（IPv4, IPv6）」后走原来的重建 + 重试逻辑（检测与自愈能力不变）。
- 部分地址族不可用（例如 v4 好、v6 差）→ **不重建**，但明确提示哪一族不可用。
  理由：WARP 的 v6 通路本身比 v4 抖动大，若要求「全部族都好」，一台 v6 偶发抖动的机器
  会每 5 分钟被重建一次、IP 一直变 —— 正是要消除的行为。链路整体断开时两族都会失败，照样会重建。

参数改为按名解析，避免位置歧义：

| 调用 | 语义 |
|---|---|
| `warp n`（保活巡检走的就是这条） | **先体检**；健康不动，断链才重建 |
| `warp n force` | 无条件重建（旧行为，会换新 IP） |
| `net no_output` | 安装流程用：静默（内部已改为 `net no_output force`） |
| 内部改配置的流程 | 显式 `net force` —— 见下 |

**为什么内部流程必须显式 `force`**：`stack_switch`（切栈）、`kernel_reserved_switch`（换内核）、
`working_mode_switch`（切全局/非全局）、安装流程都是**刚刚改过配置**才调用 `net`。
如果它们走体检路径，一台「配置改了但旧接口还活着」的机器会因为体检通过而**跳过重建、新配置不生效**。
`onoff` 的「拉起 WARP」分支（`|| net force`）同理：走这条路说明 `wg show warp` 已经看不到接口，
必须无条件重建。共 5 处内部调用点显式 force。

**体检函数必须是只读的**（自测里有专门的断言守着）：不许出现 `wg-quick up/down`、`ip link add/delete`、
`ip rule add/delete`、`systemctl start/stop/restart`、`iptables -A/-D` 之类任何会改状态的命令。

### 保活脚本无需一起升级

`keepalive.sh` 里仍然写 `warp n`（不是 `warp n check`）。因为 `net()` 的**默认**就是体检模式，
所以**老机器上已安装的 keepalive.sh 不用重新生成**就能获得新语义；反过来，新生成的 keepalive.sh
落到老 menu.sh 上也只是退回旧行为。这样两边没有耦合，不需要「必须同时升级」的约束。

### 兼容与逃生口

- `warp n` = 「获取（并保持）可用的 WARP IP」——与 help 里原本的说明一致；健康时不做改动。
- `warp n force` = 强制重建（旧的 `warp n` 行为）。
- `warp i` = 换一个 WARP IP（原本就有，需要新 IP 时的正路）。

### 实测（真机 Debian 12，非全局 + 双栈）

判据不是 IP 有没有变（CF 从池子里分配，重建也可能分到同一个），而是**接口的创建时间**
（`/sys/class/net/warp` 的 mtime，重建会被重新创建）与 **wg 最近握手时间戳**（重建后重置）。
每次调用前先确认单实例锁与在跑的 `net()` 都已空闲，并把 stdout/stderr 留档 —— 用来证明走的是
哪条分支，而不是被锁静默挡回来（这正是第一版测试得出错误结论的原因）。

| 动作 | 接口创建时间 / 握手 | 结论 |
|---|---|---|
| 新版 `warp n`，链路健康 | `1791975904` / `1791975880` **均未变** | 只做只读探测；输出「保活巡检：WARP 链路正常（IPv4, IPv6），未做任何改动」 |
| 新版 `warp n force` | `…904→…938` / `…880→…908` | 接口被重建（逃生口有效） |
| 旧版 `warp n`（对照组） | `…938→…965` / `…908→…939` | 无条件重建，且 IP 由 `104.28.243.105` 变为 `104.28.211.105` |
| 停掉接口后再跑新版 `warp n` | `none→1791975994` | 输出「检测到 WARP 链路断开（IPv4, IPv6），正在重建连接……」，链路恢复 |

部署后现网复核：`保活=1 接口=up 服务=active 规则 v4=11 v6=5`，
v4/v6 经接口 trace 均 `warp=on`，默认路由仍是原生。

自测在真机（Debian 12）上 **128 项全通过**，其中第 11 节专门守这一行为（默认 check、force 逃生口、
体检只读、体检不走会卡 DNS 的慢路径、4 处内部 force、`n)` 透传参数、锁的心跳与超时接管、
keepalive 入口不变）。

### 体检本身带出来的两个问题（同批修掉）

#### ① 体检会卡在自建域名的 DNS 上，而这段时间单实例锁一直被占着

体检最初复用了 `ip_info`（「单一事实来源」的想法）。但 `ip_info` 的第一条路是自建的
`http://ip.cloudflare.nyc.mn` —— 这个域名在很多地区**解析会卡到超时**。实测一次体检能耗掉
**40~60 秒**，而这几十秒里 `/var/run/warp-net.lock` 一直是被占着的，别的 `warp n`（包括保活）全部被挡。

修法：新增只读的 `net_iface_healthy()`，**只打 IP 字面量**（零 DNS，sub-second 级返回）：

```bash
net_iface_healthy() {
  local FAM="$1" IF="${2:-warp}" URLS URL BODY
  if [ "$FAM" = 6 ]; then URLS=("${TRACE_URLS_6[@]}"); else URLS=("${TRACE_URLS_4[@]}"); fi
  for URL in "${URLS[@]}"; do
    BODY=$(curl -ksm$TRACE_CHECK_TIMEOUT --interface "$IF" -"$FAM" "$URL" 2>/dev/null)
    if grep -qE '^warp=(on|plus)' <<< "$BODY"; then ...; return 0; fi
  done
  return 1
}
```

同时把候选清单抽成常量（`TRACE_URLS_4` / `TRACE_URLS_6` / `TRACE_URL_DOMAIN`），
`ip_info` 与体检**共用同一份**，避免两处分叉（自测里有断言守着）。
命中时顺带取出 trace 里的 `ip=` / `loc=`，`warp n` 依然能把 IP 显示出来。

#### ② 单实例锁会「静默挡住一切」，而且卡住的持锁者没人能接管

这是实测踩出来的，也是本轮最值得记的一条：

- `net()` 发现锁被别人拿着时是 **`return 0`（静默）**。于是每一次调用都「看起来成功了」，
  实际什么都没做 —— 排查时所有观测都是假的。本轮就因此在验证里连着得出两个错误结论
  （把「被锁挡住」误读成「体检通过，所以没重建」）。
- 更严重的是：**持锁者要是卡住（例如某次域名解析卡满超时），锁会被占住很久**，
  而下一个 `net()` 只会再次静默退出 —— 保活再也修不回来。这直接违反
  「断联必须能自愈、不能让脚本察觉不到」。

修法两条：

```bash
local LOCK_STALE=180
if [ -e "$WARPNET_LOCK" ]; then
  _lp=$(awk 'NR==1{print $1}' "$WARPNET_LOCK")     # PID
  _lt=$(awk 'NR==1{print $2}' "$WARPNET_LOCK")     # 心跳时间戳
  if ... kill -0 "$_lp" && [ -n "$_lt" ] && [ $(( _now - _lt )) -lt "$LOCK_STALE" ]; then
    hint "$(text 145)"        # 明确告诉人「另一次 net() 在进行中，本次不做任何操作」
    return 0
  fi
  kill -9 "$_lp"; rm -f "$WARPNET_LOCK"   # 心跳过期 → 判定失控，终止并接管
fi
lock_touch "$WARPNET_LOCK"                # 内容 "PID 时间戳"
```

- 锁内容从「只有一个 PID」变成 **`PID 心跳时间戳`**；`net()` 的每轮重试都会 `lock_touch` 刷新心跳。
  这样能区分「还在正常重试」（每轮都刷新）与「已经失控」（心跳不动）——
  比单纯的墙钟超时可靠：一次正常的重试循环最长可以跑十几分钟，但它一直在刷新心跳。
- **旧格式锁（只有 PID、没有心跳）一律按失效处理**，保证升级后不会被老锁卡住。
- `check_cdn` 里 curl 分支补上 `-m8`：curl 默认**没有总超时**（连接默认可等 300s），
  黑洞路由会把整个 `warp`（含保活的 `warp n`）长时间卡在探测阶段，而这时锁是被占着的。
- 旧格式（无心跳字段）遗留锁走**单独文案**（v3.2.15）：否则会打出「持锁超过 0 秒没有心跳」
  这种读不通的提示 —— 这条提示恰恰是排查时要看的，必须写准。

---

## 十一、验证方式

```bash
# 单元 / 集成自测（mock ip，复现内核 FIB 语义，含旧版对照组）
bash tests/self-test.sh

# 语法检查
for f in menu.sh api.sh warp-go.sh docker.sh pc/mac.sh; do bash -n "$f"; done
```

自测会验证：
- NonGlobal.sh 的 start 幂等（连跑 3 次仍只有 1 条规则）、stop 一次性清空、能自愈 5 条历史重复规则、退出码恒为 0；
- **对照组**同时跑一遍旧版 `NonGlobal.sh`，确认它确实会残留规则并返回非 0（证明测试有效）；
- `Rule.sh` 会由 menu.sh 生成、会随卸载清理；生成器里已无裸 `ip rule` 钩子；
  6 份重复经 `add` 收敛为 1 份、重复 `add` 仍 1 份、`del` 清空，且各种异常输入（不存在的规则 / 无参数 / 无 `ip`）退出码恒为 0；
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
