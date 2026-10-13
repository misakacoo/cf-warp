#!/usr/bin/env bash
# 自测脚本：不依赖真实 WARP 环境，用 mock ip 复现 Linux FIB 规则语义，
# 验证 menu.sh / warp-go.sh 生成的分流脚本与钩子规则是否幂等、是否自愈、是否永不返回非 0。
#
# 用法：  bash tests/self-test.sh
# 退出码：0 = 全部通过；非 0 = 有失败项

cd "$(dirname "$0")/.." || exit 1
TD=$(mktemp -d 2>/dev/null) || TD="/tmp/cf-warp-test-$$"
mkdir -p "$TD"
# 统一成 shell 的 POSIX 路径：Windows 上 mktemp 可能返回 C:\... 形式，
# 那种路径放进 PATH 会导致 mock 命令查找失败（命令找不到 → 规则一条也加不上）
TD=$(cd "$TD" && pwd)
[ -d "$TD" ] || { echo "无法创建临时目录"; exit 1; }
trap 'rm -rf "$TD" 2>/dev/null' EXIT

PASS=0
FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
sec() { printf '\n\033[36m== %s ==\033[0m\n' "$1"; }
# cnt <文件> <固定字符串> -> 出现次数；文件不存在记 0
cnt() { if [ -f "$1" ]; then grep -cF "$2" "$1" 2>/dev/null; else echo 0; fi; }
# 清空 mock 数据库（用截断而非 rm：部分沙箱会拦截带通配符/盘符的删除）
reset_db() {
  for f in rule4 rule6 route4.51820 route6.51820 route4.main route6.main; do
    : > "$TD/$f"
  done
  return 0
}

# ===========================================================================
# 0. 语法
# ===========================================================================
sec "0. 语法检查"
for f in menu.sh api.sh warp-go.sh docker.sh pc/mac.sh; do
  if bash -n "$f" 2>"$TD/err"; then ok "$f"; else bad "$f: $(cat "$TD/err")"; fi
done

# ===========================================================================
# 1. mock bin：ip 复现真实语义 —— 重复 add 报 "File exists" 且非 0；del 不存在报错且非 0
# ===========================================================================
mkdir -p "$TD/bin"
cat > "$TD/bin/ip" <<'MOCK'
#!/usr/bin/env bash
D=${MOCKDB:?}
proto=$1; shift
kind=$1; shift
act=$1; shift
proto=${proto#-}
case "$proto" in 4|6) : ;; *) exit 0 ;; esac
if [ "$kind" = rule ]; then
  f="$D/rule$proto"
  case "$act" in
    show)   [ -f "$f" ] && cat "$f"; exit 0 ;;
    add)    grep -qxF "$*" "$f" 2>/dev/null && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
            echo "$*" >> "$f"; exit 0 ;;
    delete) grep -qxF "$*" "$f" 2>/dev/null || { echo "RTNETLINK answers: No such file or directory" >&2; exit 2; }
            grep -vxF "$*" "$f" > "$f.t"; mv "$f.t" "$f"; exit 0 ;;
  esac
fi
if [ "$kind" = route ]; then
  t=main; args=()
  while [ $# -gt 0 ]; do
    if [ "$1" = table ]; then t=$2; shift 2; continue; fi
    args+=("$1"); shift
  done
  f="$D/route$proto.$t"; spec="${args[*]}"
  case "$act" in
    show)   [ -f "$f" ] && cat "$f"; exit 0 ;;
    add)    grep -qxF "$spec" "$f" 2>/dev/null && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
            echo "$spec" >> "$f"; exit 0 ;;
    delete) grep -qxF "$spec" "$f" 2>/dev/null || { echo "RTNETLINK answers: No such file or directory" >&2; exit 2; }
            grep -vxF "$spec" "$f" > "$f.t"; mv "$f.t" "$f"; exit 0 ;;
  esac
fi
exit 0
MOCK
printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/bin/sleep"
for c in iptables ipset; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TD/bin/$c"; done
chmod +x "$TD/bin"/*
export MOCKDB="$TD"
export PATH="$TD/bin:$PATH"

# ===========================================================================
# 2. NonGlobal.sh（menu.sh 内嵌模板）
# ===========================================================================
sec "2. NonGlobal.sh（menu.sh 内嵌模板）"
awk '/cat > \/etc\/wireguard\/NonGlobal.sh <<.EOF./{f=1;next} f&&/^EOF$/{exit} f' menu.sh > "$TD/ng.sh"
if [ -s "$TD/ng.sh" ] && bash -n "$TD/ng.sh"; then ok "抽取成功且语法正确（$(wc -l < "$TD/ng.sh") 行）"; else bad "抽取失败"; fi

reset_db
for n in 1 2 3; do bash "$TD/ng.sh" start >/dev/null 2>&1; done
c=$(cnt "$TD/rule4" 'from 172.16.0.2 lookup 51820')
[ "$c" = 1 ] && ok "start 连跑 3 次，v4 规则仍为 1 条（add 幂等，不会累积）" || bad "start 3 次后 v4 规则 $c 条（应为 1）"
c=$(cnt "$TD/route4.51820" 'default dev warp')
[ "$c" = 1 ] && ok "路由同样幂等（1 条）" || bad "路由 $c 条（应为 1）"

bash "$TD/ng.sh" stop >/dev/null 2>&1; rc=$?
left=$(( $(cnt "$TD/rule4" '') + $(cnt "$TD/rule6" '') ))
[ "$rc" = 0 ] && ok "stop 退出码 0（不会中断 wg-quick / systemd ExecStop）" || bad "stop 退出码 $rc"
[ "$left" = 0 ] && ok "stop 后规则清空" || bad "stop 后仍残留 $left 条"
c=$(cnt "$TD/route4.51820" 'default dev warp'); c2=$(cnt "$TD/route6.51820" 'default dev warp')
[ "$c" = 0 ] && [ "$c2" = 0 ] && ok "stop 同时清理了路由（与 start 对称）" || bad "路由残留 v4=$c v6=$c2"

# 历史残留自愈：人为塞 5 条重复 + 孤儿规则
for i in 1 2 3 4 5; do echo "from 172.16.0.2 lookup 51820" >> "$TD/rule4"; done
echo "oif warp lookup 51820" >> "$TD/rule6"
bash "$TD/ng.sh" stop >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'from 172.16.0.2 lookup 51820'); c2=$(cnt "$TD/rule6" 'oif warp lookup 51820')
[ "$c" = 0 ] && [ "$c2" = 0 ] && ok "stop 一次清掉 5 条历史重复 + v6 孤儿规则（自愈）" \
                                 || bad "仍有残留 v4=$c v6=$c2"

# 对照组：旧版（stop 删 'oif warp'，与 start 不对称）
cat > "$TD/ng-old.sh" <<'OLD'
#!/usr/bin/env bash
case "${1:-}" in
  start) ip -4 rule add from 172.16.0.2 lookup 51820 ;;
  stop)  ip -4 rule delete oif warp lookup 51820 ;;
esac
OLD
reset_db
# 预置 2 条同名规则（模拟历史上重复 add 的累积 —— 真实机器上曾累积到数千条）
echo "from 172.16.0.2 lookup 51820" >> "$TD/rule4"
echo "from 172.16.0.2 lookup 51820" >> "$TD/rule4"
bash "$TD/ng-old.sh" stop >/dev/null 2>&1; oldrc=$?
c=$(cnt "$TD/rule4" 'from 172.16.0.2 lookup 51820')
printf '  \033[33m·\033[0m 对照（旧版）：stop 退出码=%s，残留 %s 条 —— 原 bug 的原貌（非 0 会中断 systemctl restart）\n' "$oldrc" "$c"
{ [ "$oldrc" != 0 ] && [ "$c" = 2 ]; } && ok "对照组成功复现旧版缺陷（说明本测试有效）" || bad "对照组未复现（rc=$oldrc 残留=$c）"
bash "$TD/ng.sh" stop >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'from 172.16.0.2 lookup 51820')
[ "$c" = 0 ] && ok "新版 stop 能清掉旧版留下的残留（自愈）" || bad "新版仍留下 $c 条"

# ===========================================================================
# 3. warp.conf 钩子规则容错
# ===========================================================================
sec "3. warp.conf 钩子规则容错"
echo "from 172.17.0.0/16 lookup main" > "$TD/rule4"
out=$(eval "ip -4 rule add from 172.17.0.0/16 lookup main 2>/dev/null || true" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "已有残留时，PostUp 行返回 0（修复前会非 0 中断 wg-quick）" || bad "返回非 0：$out"
: > "$TD/rule4"
eval "ip -4 rule add from 172.17.0.0/16 lookup main 2>/dev/null || true" >/dev/null 2>&1
[ "$(cat "$TD/rule4" 2>/dev/null)" = "from 172.17.0.0/16 lookup main" ] && ok "无残留时规则被正常添加" || bad "规则未添加"

n=$(grep -cE '^(PostUp|PostDown) = ip .*lookup main$' menu.sh)
[ "$n" = 0 ] && ok "menu.sh \$RULES 无遗漏，全部带 2>/dev/null || true" || bad "仍有 $n 行裸规则"
n=$(grep -c 'lookup main 2>/dev/null || true' menu.sh)
printf '  \033[33m·\033[0m menu.sh 中带容错的规则行：%s 行\n' "$n"
[ "$n" -ge 14 ] && ok "覆盖了全部 rule/route 型钩子" || bad "只覆盖 $n 行，少于 14"

# ===========================================================================
# 4. iptables 分流方案
# ===========================================================================
sec "4. iptables 分流方案（up / down / PreDown）"
grep -qF 'PreDown = /etc/wireguard/down' menu.sh && ok "PreDown 拼写正确（原 Predown，wg-quick 不认）" || bad "PreDown 拼写错误"
grep -qF 'Predown = /etc/wireguard/down' menu.sh && bad "仍存在 Predown 写入" || ok "已无 Predown 写入（注释里的说明文字不算）"

awk '/cat >\/etc\/wireguard\/up << .EOF./{f=1;next} f&&/^EOF$/{exit} f'   menu.sh > "$TD/up.sh"
awk '/cat >\/etc\/wireguard\/down << .EOF./{f=1;next} f&&/^EOF$/{exit} f' menu.sh > "$TD/down.sh"
{ bash -n "$TD/up.sh" && bash -n "$TD/down.sh"; } && ok "up / down 语法正确" || bad "up / down 语法错误"
bash "$TD/up.sh" >/dev/null 2>&1; r1=$?
bash "$TD/up.sh" >/dev/null 2>&1; r2=$?
{ [ "$r1" = 0 ] && [ "$r2" = 0 ]; } && ok "up 可重复执行且始终返回 0（幂等）" || bad "up 退出码 $r1 / $r2"
bash "$TD/down.sh" >/dev/null 2>&1 && ok "down 返回 0" || bad "down 返回非 0"
grep -qF 'ip route del default dev warp table warp' "$TD/down.sh" && ok "down 补上了 route 清理（与 up 对称）" || bad "down 缺 route 清理"
grep -qF 'keepalive\.sh/! s/' menu.sh && ok "新 sed 保留 keepalive 保活钩子（不再被一并注释）" || bad "keepalive 仍会被注释掉"

cat > "$TD/warp.conf" <<'CONF'
[Interface]
PrivateKey = xxx
Address = 172.16.0.2/32
MTU = 1280
PostUp = ip -4 rule add from 1.2.3.4 lookup main
PostDown = ip -4 rule delete from 1.2.3.4 lookup main
#Table = off
PostUp = /etc/wireguard/keepalive.sh start
PostDown = /etc/wireguard/keepalive.sh stop
CONF
sed -i -E '/^Post(Up|Down) = \/etc\/wireguard\/keepalive\.sh/! s/^(Post(Up|Down) = )/#\1/' "$TD/warp.conf"
sed -i '/^#Table/ s/#//; /^Table/a\PostUp = /etc/wireguard/up\nPreDown = /etc/wireguard/down' "$TD/warp.conf"
grep -qE '^PostUp = /etc/wireguard/keepalive\.sh start' "$TD/warp.conf" && ok "端到端：keepalive 钩子保留" || bad "端到端：keepalive 被注释"
grep -qF '#PostUp = ip -4 rule add from 1.2.3.4 lookup main' "$TD/warp.conf" && ok "端到端：旧规则行被注释" || bad "端到端：旧规则未注释"
grep -qF 'PreDown = /etc/wireguard/down' "$TD/warp.conf" && ok "端到端：PreDown 已写入" || bad "端到端：PreDown 缺失"
grep -qF 'PostUp = /etc/wireguard/up' "$TD/warp.conf" && ok "端到端：PostUp=up 已写入" || bad "端到端：up 缺失"
grep -qF 'Table = off' "$TD/warp.conf" && ok "端到端：Table = off 已打开" || bad "端到端：Table 未打开"

# ===========================================================================
# 5. reserved 解码（locale 无关）
# ===========================================================================
sec "5. reserved 解码"
awk '/^reserved_decode\(\) \{/,/^\}/' menu.sh > "$TD/rd.sh"
awk '/^reserved_from_client_id\(\) \{/,/^\}/' api.sh > "$TD/rf.sh"
for pair in "y8eh 203,199,161" "rRV4 173,21,120" "abcd 105,183,29"; do
  cid=${pair%% *}; exp=${pair##* }
  got=$(bash -c ". $TD/rd.sh; reserved_decode $cid")
  [ "$got" = "[$exp]" ] && ok "menu.sh  $cid -> $got" || bad "menu.sh  $cid -> $got（应 [$exp]）"
  got=$(bash -c ". $TD/rf.sh; reserved_from_client_id $cid")
  [ "$got" = "[$exp]" ] && ok "api.sh   $cid -> $got" || bad "api.sh   $cid -> $got（应 [$exp]）"
done
printf '"reserved": [\n  11,\n  22,\n  33\n],\n' > "$TD/acct2"
got=$(bash -c ". $TD/rd.sh; reserved_decode '' $TD/acct2")
[ "$got" = "[11,22,33]" ] && ok "无 client_id 时回落读 reserved 数组：$got" || bad "回落异常：$got"
printf '"client_id":"y8eh","reserved":[1,2,3],\n' > "$TD/acct3"
got=$(bash -c ". $TD/rd.sh; reserved_decode y8eh $TD/acct3")
[ "$got" = "[203,199,161]" ] && ok "client_id 优先于文件里的旧值" || bad "优先级不对：$got"
got=$(bash -c ". $TD/rd.sh; reserved_decode '' /nonexistent")
[ "$got" = "[]" ] && ok "无可用数据时输出 [] （不产生非法值）" || bad "异常输出：$got"

# ===========================================================================
# 6. bash 4.2 兼容
# ===========================================================================
sec "6. bash 低版本（< 4.3）兼容"
for f in menu.sh warp-go.sh; do
  awk '/^# >>> text\(\) 回落实现/{f=1} f&&/^# <<< text\(\) 回落实现/{print;exit} f' "$f" > "$TD/fb.func"
  if [ ! -s "$TD/fb.func" ]; then bad "$f 缺少回落实现"; continue; fi
  {
    printf 'E=([1]="hello" [2]='"'"'v=$((1+1))'"'"')\nC=([1]="中文文案")\n'
    printf 'declare -A TEXT_NEEDS_EVAL\nTEXT_NEEDS_EVAL[2]=1\nL=E\n'
    cat "$TD/fb.func"
    printf 'printf "[%%s][%%s]" "$(text 1)" "$(text 2)"\nL=C; printf "[%%s]" "$(text 1)"\n'
  } > "$TD/fb.sh"
  got=$(bash "$TD/fb.sh" 2>&1)
  [ "$got" = "[hello][v=2][中文文案]" ] && ok "$f 回落实现可用（普通/含变量/中文）" || bad "$f 回落输出异常：$got"
done

# ===========================================================================
# 7. 其它已修项
# ===========================================================================
sec "7. 其它已修项"
grep -qF 'PRIORITY_SWITCH="${2,,}"' warp-go.sh && ok "PRIORITY_SWITCH 笔误已修" || bad "PRIORITY_SWITCH 仍有笔误"
grep -qF 'PRIORITY_SWITCH=PRIORITY_SWITCH' warp-go.sh && bad "仍有自赋值写法" || ok "已无自赋值写法"
awk '/^check_dependencies\(\)/,/^}/' warp-go.sh | grep -qF 'DEPS_INSTALL=("iputils-ping"' \
  && ok "vim-common 追加已挪到整体赋值之后" || bad "vim-common 仍会被覆盖"
grep -qF 'Private key not found in config file' api.sh && ok "api.sh MASQUE 报错文案已纠正（原语义反了）" || bad "报错文案未修"
grep -qF 'Private key found in config file' api.sh && bad "旧的反义文案仍在" || ok "旧的反义文案已清除"

mapfile -t rl < <(grep -F "sed -n 's/.*\"reserved\"" warp-go.sh | head -3)
c1=$(grep -oF '[0-9]\+' <<< "${rl[0]}" | wc -l)
c2=$(grep -oF '[0-9]\+' <<< "${rl[1]}" | wc -l)
c3=$(grep -oF '[0-9]\+' <<< "${rl[2]}" | wc -l)
{ [ "$c1" = 1 ] && [ "$c2" = 2 ] && [ "$c3" = 3 ]; } \
  && ok "sing-box reserved 三行分别取第 1/2/3 个数（原为 3/2/3）" \
  || bad "sing-box reserved 取值顺序异常：$c1/$c2/$c3"

grep -qF 'CODE=$(get_code "$API_URL")' menu.sh && ok "check_cdn 直连探测已恢复（原被硬编码短路）" || bad "check_cdn 仍是死代码"
grep -qE '^CODE=200' menu.sh && bad "硬编码 CODE=200 尚存" || ok "已无硬编码 CODE=200"
grep -qF 'RESTART_LAST_ERR=' menu.sh && ok "net() 不再吞掉 restart 输出" || bad "net() 仍静默"
grep -qF 'ERROR_MESSAGE="(wg-quick up 单独执行无输出)' menu.sh && ok "失败时会带出 restart 报错（避免错误信息为空）" || bad "错误信息仍可能为空"

n=$(wc -l < docker.sh)
[ "$n" -lt 700 ] && ok "docker.sh 已去重（$n 行，原 1350 行）" || bad "docker.sh 仍有重复（$n 行）"
grep -qF 'esac#!/bin/bash' docker.sh && bad "仍有 esac#!/bin/bash 粘连" || ok "已无 esac#!/bin/bash 粘连"

# ===========================================================================
# 8. 重启风暴 / 自锁死（2026-10-13 实机复现后新增）
# ===========================================================================
sec "8. 重启风暴与 wg-quick 自锁死"

# 8.1 NonGlobal 的匹配串必须是 `ip rule show` 的显示形态
n=$(grep -c '"table main suppress_prefixlength 0"' menu.sh)
[ "$n" = 0 ] && ok "menu.sh 不再用 add 形态的匹配串（show 输出是 from all lookup main ...）" \
             || bad "仍有 $n 处 add 形态匹配串 —— 会导致加不查重、删不进循环"
n=$(grep -c '"table main suppress_prefixlength 0"' warp-go.sh)
[ "$n" = 0 ] && ok "warp-go.sh 同上" || bad "warp-go.sh 仍有 $n 处"

rm -f "$TD/rule4" "$TD/rule6"
for k in 1 2 3; do bash "$TD/ng.sh" start >/dev/null 2>&1; done
c=$(cnt "$TD/rule4" 'lookup main suppress_prefixlength 0')
[ "$c" = 1 ] && ok "suppress 规则也幂等（连跑 3 次仍 1 条）" || bad "suppress 规则 $c 条（应为 1，>1 说明查重失效）"
bash "$TD/ng.sh" stop >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'lookup main suppress_prefixlength 0'); c2=$(cnt "$TD/rule6" 'lookup main suppress_prefixlength 0')
[ "$c" = 0 ] && [ "$c2" = 0 ] && ok "stop 能删掉 suppress 规则（v4/v6 都清空）" \
                              || bad "suppress 残留 v4=$c v6=$c2（>0 说明删的循环没进）"

# 8.2 keepalive：必须"先 sleep 再 warp n"
awk '/cat > \/etc\/wireguard\/keepalive.sh <<.EOF./{f=1;next} f&&/^EOF$/{exit} f' menu.sh > "$TD/ka.sh"
body=$(sed -n '/^  loop)/,/^    ;;/p' "$TD/ka.sh")
sl=$(printf '%s\n' "$body" | grep -n 'sleep' | head -1 | cut -d: -f1)
wn=$(printf '%s\n' "$body" | grep -n 'warp n' | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)
if [ -n "$sl" ] && [ -n "$wn" ] && [ "$sl" -lt "$wn" ]; then
  ok "keepalive 循环先 sleep 再 warp n（启动即触发会造成自我放大的重启风暴）"
else
  bad "keepalive 仍是先 warp n（sleep 行=$sl, warp n 行=$wn）"
fi

# 8.3 net()：单实例锁 + 硬复位兜底 + 不用 restart
grep -q '^warp_if_hard_reset() {' menu.sh && ok "定义了 warp_if_hard_reset（硬复位兜底）" || bad "缺少硬复位函数"
grep -q 'WARPNET_LOCK' menu.sh && ok "net() 有单实例锁（实测 4 个 warp n 并发会互相重启接口）" || bad "net() 缺少单实例锁"
# 单实例锁必须用 PID 文件：flock 的锁 fd 会被 fork 出去的 wireguard-go 继承并常驻，
# 会把锁永久占住，之后所有 net() 都静默返回 —— WARP 再也拉不起来（已实测踩到）
grep -q 'flock -n 8' menu.sh && bad "仍用 flock 做单实例锁（锁 fd 会被 wireguard-go 继承占住）" \
                             || ok "单实例锁没有用 flock（避开 fd 被常驻子进程继承）"
awk '/^net\(\)/,/^\}/' menu.sh | grep -q 'rm -f "\$WARPNET_LOCK"' && ok "net() 正常结束时释放锁" || bad "net() 未释放锁"
if grep -q '^trap cleanup_temp EXIT' menu.sh; then ok "脚本原有的 trap cleanup_temp EXIT 未被改动"; else bad "原有 EXIT trap 不见了"; fi
if awk '/WARPNET_LOCK/,0' menu.sh | grep -qE '^[[:space:]]*trap[[:space:]].*EXIT'; then
  bad "单实例锁用了 trap EXIT —— 会覆盖脚本原有的 cleanup_temp 清理"
else
  ok "单实例锁没有用 trap EXIT 覆盖既有清理逻辑"
fi
grep -q 'systemctl reset-failed wg-quick@warp' menu.sh && ok "重试改用 stop → 硬复位 → reset-failed → start（restart 在死锁态救不回来）" \
                                                        || bad "重试仍依赖 restart"
grep -c 'warp_if_hard_reset$' menu.sh | grep -qE '^[3-9]' && ok "硬复位在 net()/重试/诊断多处生效（$(grep -c 'warp_if_hard_reset$' menu.sh) 处）" \
                                                       || bad "硬复位调用点过少"
# 诊断段必须用硬复位，否则真实的 up 报错会被 "already exists" 掩盖
awk '/warp_if_hard_reset$/{n++} END{}' menu.sh >/dev/null
grep -B1 'ERROR_MESSAGE=$(wg-quick up warp 2>&1)' menu.sh | grep -q 'warp_if_hard_reset' \
  && ok "诊断段先硬复位再 up（避免用 already exists 掩盖真实错误）" || bad "诊断段未硬复位"

# 8.4 ip_info：判断源不能只有自建 API
grep -q 'www.cloudflare.com/cdn-cgi/trace' menu.sh && ok "ip_info 有 Cloudflare 官方 trace 兜底（自建 API 是 http + 2 秒超时，抖动就超时）" \
                                                 || bad "ip_info 缺少官方 trace 兜底"
grep -qF '$INTERFACE_SOCK5 -$CHECK_46 https://www.cloudflare.com' menu.sh && ok "兜底走同一个接口（--interface warp）" || bad "兜底未走指定接口"
n=$(awk '/^ip_info\(\)/,/^\}/' menu.sh | grep -cE '&&[[:space:]]*$')
[ "$n" = 0 ] && ok "ip_info 不再用「行尾 && 续接 local 赋值」的短路写法（curl 失败会残留旧值）" || bad "仍有 $n 处行尾 && 续接"

# 8.5 兜底必须按协议限定 -4 / -6
# 反例：cdn-cgi/trace 是双栈可达的，不指定协议时 curl 会走系统首选协议（通常 IPv4），
# 于是 ip_info 6 也会拿到 IPv4 地址 —— 实测表现为「IPv6 那一行显示的是 IPv4 的地址」。
grep -qF 'curl -ksm8 --retry 2 $INTERFACE_SOCK5 -$CHECK_46 https://www.cloudflare.com/cdn-cgi/trace' menu.sh \
  && ok "trace 兜底带 -\$CHECK_46（漏写会让 IPv6 显示成 IPv4）" \
  || bad "trace 兜底漏了 -\$CHECK_46 —— IPv6 会显示成 IPv4 地址"
# 只看代码行（注释里也提到了 cdn-cgi/trace，不能算数）
if awk '/^ip_info\(\)/,/^\}/' menu.sh | grep 'cdn-cgi/trace' | grep -v '^[[:space:]]*#' | grep -qv '\-\$CHECK_46'; then
  bad "ip_info 内仍有不带 -4/-6 的 trace 调用"
else
  ok "ip_info 内所有 trace 调用都限定了协议"
fi
grep -q 'ip.cloudflare.nyc.mn/\${WAN}' menu.sh \
  && ok "用 trace 拿到的 IP 回查补全国家名/运营商（否则 v6 行只有国家码、没有 ISP）" \
  || bad "缺少按 IP 补全国家名/运营商"

# ===========================================================================
printf '\n\033[36m== 结果 ==\033[0m\n  通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then printf '  \033[32m全部通过\033[0m\n'; exit 0; else printf '  \033[31m有失败项\033[0m\n'; exit 1; fi
