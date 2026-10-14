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
    # show 按内核的真实格式输出 "32765:\t<规则>"，pref 用行号算 —— 这样「按 pref 删」
    # 这条路径才可测。若 $D/detached 存在，则把 "oif <dev> " 显示成 "oif <dev> [detached] "，
    # 复刻「接口已被 wg-quick 的 del_if 删掉之后」的显示形态：
    #   from all oif warp [detached] lookup 51820
    # 原样 grep 是匹配不上这一行的 —— 这正是 oif 规则永远清不掉的根因。
    show)
      if [ -f "$D/detached" ]; then
        awk '{ s=$0; gsub(/oif [^ ]+ /, "&[detached] ", s); printf "%d:\t%s\n", NR + 32760, s }' "$f" 2>/dev/null
      else
        awk '{ printf "%d:\t%s\n", NR + 32760, $0 }' "$f" 2>/dev/null
      fi
      exit 0 ;;
    add)    grep -qxF "$*" "$f" 2>/dev/null && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
            echo "$*" >> "$f"; exit 0 ;;
    delete)
      case "$*" in
        pref\ *)
          # 注意：${*##* } 不是「对拼接后的串做 ##」，而是对每个位置参数各做一次再拼回来，
          # 所以对 `pref 32761` 会得到 `pref 32761` 本身。要取最后一个参数得用 ${@: -1}。
          last="${@: -1}"
          n=$(( last - 32760 ))
          { [ "$n" -ge 1 ] && [ "$n" -le "$(wc -l < "$f" 2>/dev/null || echo 0)" ]; } \
            || { echo "RTNETLINK answers: No such file or directory" >&2; exit 2; }
          sed -i "${n}d" "$f"; exit 0 ;;
        *)
          grep -qxF "$*" "$f" 2>/dev/null || { echo "RTNETLINK answers: No such file or directory" >&2; exit 2; }
          grep -vxF "$*" "$f" > "$f.t"; mv "$f.t" "$f"; exit 0 ;;
      esac ;;
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

# v3.2.11 起：规则钩子不再用裸 ip，而是全部经 /etc/wireguard/Rule.sh
# （Rule.sh 的 add 先清空再加、del 循环删，且恒返回 0）——比逐行 || true 更彻底。
n=$(grep -cE '^(PostUp|PostDown) = ip ' menu.sh)
[ "$n" = 0 ] && ok "生成器里已无裸 ip 规则钩子，全部经 Rule.sh" || bad "仍有 $n 行裸 ip 规则钩子"
# 注意不能在行首锚定：CONF 分支里钩子写在 RULES="..." 引号串内，同行还有别的字符。
na=$(grep -oE 'Rule\.sh add [46] ' menu.sh | wc -l)
nd=$(grep -oE 'Rule\.sh del [46] ' menu.sh | wc -l)
printf '  \033[33m·\033[0m Rule.sh 钩子：add %s 条 / del %s 条\n' "$na" "$nd"
{ [ "$na" -ge 9 ] && [ "$na" = "$nd" ]; } \
  && ok "Rule.sh 钩子数量充足且 add/del 严格对称（各 $na 条）" \
  || bad "Rule.sh 钩子不成对（add $na / del $nd，应各 >= 9 且相等）"
# 脚本型钩子仍需显式容错（它们不经过 Rule.sh）
ns=$(grep -oE '(PostUp|PostDown) = /etc/wireguard/(NonGlobal|keepalive)\.sh (start|stop)' menu.sh | wc -l)
nm=$(grep -oE '(PostUp|PostDown) = /etc/wireguard/(NonGlobal|keepalive)\.sh (start|stop) 2>/dev/null \|\| true' menu.sh | wc -l)
printf '  \033[33m·\033[0m 脚本钩子：共 %s 处，其中带容错 %s 处\n' "$ns" "$nm"
{ [ "$ns" -ge 6 ] && [ "$ns" = "$nm" ]; } \
  && ok "NonGlobal / keepalive 钩子全部带 2>/dev/null || true（$ns 处）" \
  || bad "脚本钩子容错不全（共 $ns 处，带容错 $nm 处）"

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

# 8.4 ip_info：判断源不能只有自建 API，且兜底不能依赖 DNS
IP_INFO_BODY=$(awk '/^ip_info\(\)/,/^\}/' menu.sh)
# v3.2.14 起候选抽成常量，所以这里查的是「ip_info 用到了域名兜底常量」而不是字面量
grep -q 'TRACE_URL_DOMAIN' <<< "$IP_INFO_BODY" \
  && ok "ip_info 有 Cloudflare 官方 trace 兜底（自建 API 是 http + 2 秒超时，抖动就超时）" \
  || bad "ip_info 缺少官方 trace 兜底"

# earlier <haystack> <a> <b> —— 真表示 a 在 b 之前出现（取"首次出现之后的剩余"，剩余越长越靠前）
earlier(){ local h="$1" a="$2" b="$3" ta tb; ta=${h#*"$a"}; tb=${h#*"$b"}
  [ "${#ta}" -lt "${#h}" ] && [ "${#tb}" -lt "${#h}" ] && [ "${#ta}" -gt "${#tb}" ]; }

# v3.2.13：兜底首选必须是 IP 字面量。
# 反例：自建域名 ip.cloudflare.nyc.mn 在很多地区 DNS 解析失败（warp-sh #193/#231），
# 若兜底也用域名，DNS 一挂主路径与兜底会同时失败 → IPv6 那一行直接空白。
# 而字面量不能只有 v4 —— 见 8.5 的实测：IPv4 字面量配 -6 会 rc=7，等于兜底形同虚设。
# v3.2.14 起候选抽成常量，ip_info 与体检共用同一份，避免两处分叉。
V4CONST=$(grep -E '^TRACE_URLS_4=\(' menu.sh | head -1)
V6CONST=$(grep -E '^TRACE_URLS_6=\(' menu.sh | head -1)
DOMAINCONST=$(grep -E '^TRACE_URL_DOMAIN=' menu.sh | head -1)
if [ -n "$V4CONST" ]; then
  { grep -q 'https://1.1.1.1/cdn-cgi/trace' <<< "$V4CONST" && grep -q '1\.0\.0\.1' <<< "$V4CONST"; } \
    && ok "v4 候选常量含两个 IPv4 字面量（1.1.1.1 / 1.0.0.1，完全不需要 DNS）" \
    || bad "v4 候选常量不全"
else
  bad "找不到 TRACE_URLS_4 常量"
fi
if [ -n "$V6CONST" ]; then
  { grep -q '2606:4700:4700::1111' <<< "$V6CONST" && grep -q '2606:4700:4700::1001' <<< "$V6CONST"; } \
    && ok "v6 候选常量含两个 IPv6 字面量" || bad "v6 候选常量不全"
  # 关键回归防护：v6 候选里绝不能出现 IPv4 字面量
  if grep -qE '//[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<< "$V6CONST"; then
    bad "v6 候选里出现 IPv4 字面量 —— -6 下 curl 只能按 ::ffff: 映射，实测 rc=7、永远连不上"
  else
    ok "v6 候选全部是 IPv6 字面量（实测 IPv4 字面量 + -6 会 rc=7）"
  fi
else
  bad "找不到 TRACE_URLS_6 常量"
fi
[ -n "$DOMAINCONST" ] && grep -q 'www.cloudflare.com' <<< "$DOMAINCONST" \
  && ok "域名候选单独抽成常量（在 1.1.1.x 被屏蔽的网络里它是唯一能通的一条，不能删）" \
  || bad "缺少域名候选常量"
v4line=$(grep -E '^[[:space:]]*\*\)[[:space:]]*TRACE_URLS=\(' <<< "$IP_INFO_BODY" | head -1)
v6line=$(grep -E '^[[:space:]]*6\)[[:space:]]*TRACE_URLS=\(' <<< "$IP_INFO_BODY" | head -1)
earlier "$v4line" 'TRACE_URLS_4' 'TRACE_URL_DOMAIN' \
  && ok "ip_info 的 v4 组装：字面量在前、域名兜底在后" || bad "ip_info 的 v4 组装顺序不对"
earlier "$v6line" 'TRACE_URLS_6' 'TRACE_URL_DOMAIN' \
  && ok "ip_info 的 v6 组装：字面量在前、域名兜底在后" || bad "ip_info 的 v6 组装顺序不对"
grep -qF 'curl -ksm$ROUND_TIMEOUT $INTERFACE_SOCK5 -$CHECK_46 "$TRACE_URL"' <<< "$IP_INFO_BODY" \
  && ok "兜底沿用同一接口（--interface warp / socks5）+ 限定协议 + 超时可调" \
  || bad "兜底未沿用同一接口 / 未限定 -4 -6"
grep -qE 'ROUND_TIMEOUT=12' <<< "$IP_INFO_BODY" \
  && ok "第二轮把超时放宽到 12s（接口刚重建时首次握手偏慢，8s 会误判失败）" \
  || bad "第二轮未放宽超时"
grep -qE '^[[:space:]]*for ROUND in 1 2; do' <<< "$IP_INFO_BODY" \
  && ok "兜底全空时会打第二轮（覆盖接口刚硬复位、首次握手未完成的空窗）" \
  || bad "兜底没有第二轮重试"
grep -qE 'ROUND_URLS=\("\$\{TRACE_URLS\[0\]\}"\)' <<< "$IP_INFO_BODY" \
  && ok "第二轮只重试第一候选，不把整张清单再跑一遍（避免最坏耗时翻倍）" \
  || bad "第二轮重试范围未收敛"
n=$(grep -cE '&&[[:space:]]*$' <<< "$IP_INFO_BODY")
[ "$n" = 0 ] && ok "ip_info 不再用「行尾 && 续接 local 赋值」的短路写法（curl 失败会残留旧值）" || bad "仍有 $n 处行尾 && 续接"

# 8.5 兜底必须按协议限定 -4 / -6
# 反例：cdn-cgi/trace 是双栈可达的，不指定协议时 curl 会走系统首选协议（通常 IPv4），
# 于是 ip_info 6 也会拿到 IPv4 地址 —— 实测表现为「IPv6 那一行显示的是 IPv4 的地址」。
# 只看真正的 curl 调用行（候选清单里的 URL 常量、注释里提到的 URL 都不能算数）。
nt=$(grep -c 'curl.*\$TRACE_URL' <<< "$IP_INFO_BODY")
nn=$(grep 'curl.*\$TRACE_URL' <<< "$IP_INFO_BODY" | grep -c '\-\$CHECK_46')
{ [ "$nt" -ge 1 ] && [ "$nt" = "$nn" ]; } \
  && ok "ip_info 内 $nt 处 trace 调用全部带 -\$CHECK_46（漏写会让 IPv6 显示成 IPv4）" \
  || bad "ip_info 内有 trace 调用漏了 -\$CHECK_46（$nn/$nt 处合规）"
grep -q 'ip.cloudflare.nyc.mn/\${WAN}' menu.sh \
  && ok "用 trace 拿到的 IP 回查补全国家名/运营商（否则 v6 行只有国家码、没有 ISP）" \
  || bad "缺少按 IP 补全国家名/运营商"

# ===========================================================================
# 9. Rule.sh（幂等 rule 操作器，v3.2.11 新增）
#    要点：add 必须先清空同名规则再加（否则历史残留永远不收敛）；
#          del 要循环删到没有；任何路径都必须 exit 0（否则会打断 wg-quick 的 set -e）。
# ===========================================================================
sec "9. Rule.sh（幂等 rule 操作器）"

grep -qF "cat > /etc/wireguard/Rule.sh <<'EOF'" menu.sh \
  && ok "menu.sh 会生成 /etc/wireguard/Rule.sh" \
  || bad "menu.sh 没有生成 Rule.sh"
grep -qF 'keepalive.sh,Rule.sh}' menu.sh \
  && ok "uninstall 的 rm 列表包含 Rule.sh" \
  || bad "uninstall 的 rm 列表缺 Rule.sh"

# 生成器里不应再有裸 ip rule 钩子：它们非幂等，且 wg-quick 有 set -e，
# 一条失败就会中断 up()，随后 EXIT trap 的 del_if 会把刚建好的接口删掉。
raw=$(grep -cE '^Post(Up|Down) = ip -[46] rule (add|delete)' menu.sh)
[ "$raw" = 0 ] && ok "生成器里已无裸 ip rule 钩子，全部经 Rule.sh" \
              || bad "生成器里仍有 $raw 条裸 ip rule 钩子"
na9=$(grep -oE 'Rule\.sh add [46] ' menu.sh | wc -l)
nd9=$(grep -oE 'Rule\.sh del [46] ' menu.sh | wc -l)
{ [ "$na9" -ge 9 ] && [ "$na9" = "$nd9" ]; } \
  && ok "生成器里的 Rule.sh add/del 各 $na9 条且对称" \
  || bad "Rule.sh add/del 不对称（$na9 / $nd9）"

awk '/cat > \/etc\/wireguard\/Rule.sh <<.EOF./{f=1;next} f&&/^EOF$/{exit} f' menu.sh > "$TD/rule.sh"
if [ -s "$TD/rule.sh" ] && bash -n "$TD/rule.sh"; then
  ok "抽取成功且语法正确（$(wc -l < "$TD/rule.sh") 行）"
else
  bad "Rule.sh 抽取失败"
fi
grep -qE '^  add\) r_del;' "$TD/rule.sh" \
  && ok "add 分支先 r_del（先清空再加，历史残留据此收敛）" \
  || bad "add 分支没有先 r_del —— 历史残留无法收敛"
grep -q 'exit 0' "$TD/rule.sh" && [ "$(tail -1 "$TD/rule.sh")" = 'exit 0' ] \
  && ok "以 exit 0 收尾" \
  || bad "结尾不是 exit 0 —— 失败会打断 wg-quick"

reset_db
for i in 1 2 3 4 5 6; do echo "from 172.17.0.0/16 lookup main" >> "$TD/rule4"; done
bash "$TD/rule.sh" add 4 "from 172.17.0.0/16 lookup main" >/dev/null 2>&1; rc=$?
c=$(cnt "$TD/rule4" 'from 172.17.0.0/16 lookup main')
{ [ "$rc" = 0 ] && [ "$c" = 1 ]; } \
  && ok "预置 6 份重复 → add 后收敛为 1 份（退出码 0）" \
  || bad "add 后 $c 份、退出码 $rc（应为 1 / 0）"

bash "$TD/rule.sh" add 4 "from 172.17.0.0/16 lookup main" >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'from 172.17.0.0/16 lookup main')
[ "$c" = 1 ] && ok "再 add 一次仍 1 份（幂等）" || bad "重复 add 后 $c 份（应为 1）"

bash "$TD/rule.sh" del 4 "from 172.17.0.0/16 lookup main" >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'from 172.17.0.0/16 lookup main')
[ "$c" = 0 ] && ok "del 后清空" || bad "del 后仍 $c 份"

bash "$TD/rule.sh" del 4 "from 10.0.0.0/8 lookup main" >/dev/null 2>&1
[ "$?" = 0 ] && ok "del 一个不存在的规则仍返回 0" || bad "del 不存在规则返回非 0"
bash "$TD/rule.sh" >/dev/null 2>&1
[ "$?" = 0 ] && ok "不带参数返回 0" || bad "不带参数返回非 0"

# 匹配串必须是 ip rule show 的显示形态（不是 add 的写法），否则「加不查重、删不进循环」
reset_db
printf 'from all lookup main suppress_prefixlength 0\nfrom all lookup main suppress_prefixlength 0\n' >> "$TD/rule4"
bash "$TD/rule.sh" del 4 "from all lookup main suppress_prefixlength 0" >/dev/null 2>&1
c=$(cnt "$TD/rule4" 'suppress_prefixlength')
[ "$c" = 0 ] && ok "用显示形态的 spec 删 suppress_prefixlength：2 份 → 0 份" \
             || bad "显示形态 spec 删除失败，仍剩 $c 份"

# ===========================================================================
# 10. 接口已删除后的显示形态：[detached]（v3.2.12）
#     cmd_down 的顺序是 PreDown -> del_if -> unset_dns/remove_firewall -> PostDown，
#     所以 NonGlobal.sh 的 stop 跑到时 warp 接口早被删了，此时
#       ip -6 rule show  ===>  from all oif warp [detached] lookup 51820
#     比 add 时多出 " [detached]"，原样 grep -F 永远匹配不上 -> oif 规则一份都清不掉（实测 3 份）。
#     修法：匹配用「转义正则 + 容忍 [detached]」，删除一律按 pref。
# ===========================================================================
sec "10. 接口已删除（[detached]）时的规则清理"

grep -qF 'detached' "$TD/ng.sh" \
  && ok "NonGlobal.sh 的匹配逻辑里提到了 [detached]" \
  || bad "NonGlobal.sh 没处理 [detached]（oif 规则会永远清不掉）"
grep -qF 'rule delete pref' "$TD/ng.sh" \
  && ok "NonGlobal.sh 按 pref 删除（不依赖 spec 能否被解析）" \
  || bad "NonGlobal.sh 仍在按 spec 删除"
grep -qF 'delete pref' "$TD/rule.sh" \
  && ok "Rule.sh 也按 pref 删除" \
  || bad "Rule.sh 仍按 spec 删除"

# 行为：设备已 detached + 3 份重复的 oif 规则，stop 必须全部清掉
reset_db
for i in 1 2 3; do echo "oif warp lookup 51820" >> "$TD/rule6"; done
echo "from 172.16.0.2 lookup 51820" >> "$TD/rule4"
: > "$TD/detached"
before6=$(cnt "$TD/rule6" 'oif warp lookup 51820')
bash "$TD/ng.sh" stop >/dev/null 2>&1; rc=$?
after6=$(cnt "$TD/rule6" 'oif warp lookup 51820')
after4=$(cnt "$TD/rule4" 'from 172.16.0.2 lookup 51820')
rm -f "$TD/detached"
{ [ "$before6" = 3 ] && [ "$after6" = 0 ] && [ "$rc" = 0 ]; } \
  && ok "[detached] 形态下，3 份 oif 规则被全部清掉（退出码 0）" \
  || bad "[detached] 清理失败：$before6 份 -> $after6 份，rc=$rc"
[ "$after4" = 0 ] && ok "同一轮里 v4 规则也一并清掉" || bad "v4 仍残留 $after4 份"

# 对照组：把匹配退回「原样 grep -F + 按 spec 删」，确认它在 [detached] 下确实一条都清不掉。
# 不直接 sed 改新版 ng.sh —— rule_match 现在跨多行，sed 单行替换会把函数截断。
reset_db
for i in 1 2 3; do echo "oif warp lookup 51820" >> "$TD/rule6"; done
: > "$TD/detached"
cat > "$TD/ng_old.sh" <<'OLD'
#!/usr/bin/env bash
# 旧实现（v3.2.9/3.2.11）：原样 grep -F 匹配 + 按 spec 删除
rule_del() { n=0; while [ $n -lt 5000 ] && ip -$1 rule show | grep -qF "$2"; do ip -$1 rule delete $2 2>/dev/null || break; n=$((n+1)); done; }
rule_del 6 "oif warp lookup 51820"
OLD
bash "$TD/ng_old.sh" >/dev/null 2>&1
old=$(cnt "$TD/rule6" 'oif warp lookup 51820')
rm -f "$TD/detached"
[ "$old" = 3 ] && ok "对照组（旧实现）：[detached] 下确实留了 3 份（说明本测试能测出问题）" \
               || bad "对照组行为异常（剩余 $old 份，预期 3）"

# Rule.sh 在 [detached] 下同样要能清
reset_db
for i in 1 2 3; do echo "oif warp lookup 51820" >> "$TD/rule6"; done
: > "$TD/detached"
bash "$TD/rule.sh" del 6 "oif warp lookup 51820" >/dev/null 2>&1; rc=$?
c=$(cnt "$TD/rule6" 'oif warp lookup 51820')
rm -f "$TD/detached"
{ [ "$c" = 0 ] && [ "$rc" = 0 ]; } \
  && ok "Rule.sh del 在 [detached] 下也清得掉（退出码 0）" \
  || bad "Rule.sh 在 [detached] 下剩 $c 份，rc=$rc"

# ===========================================================================
# 11. 保活改为「先体检再决定」：链路健康就不重建（v3.2.14）
#     要点：warp n 默认体检；只有确认断链才重建；内部改配置的流程必须显式 force；
#           体检函数里**绝不能出现任何改状态的命令**（它是只读的，否则会自己把自己拆了）。
# ===========================================================================
sec "11. 保活先体检（健康不动、断链才重建）"

# 11.1 net() 默认是体检模式，且提供 force 逃生口
grep -qE "^  local NO_OUTPUT='' MODE='check' " menu.sh \
  && ok "net() 默认模式为 check（体检）" \
  || bad "net() 默认模式不是 check —— 保活会继续每 5 分钟重建接口"
grep -q "force) MODE='force'" menu.sh \
  && ok "net() 支持 force 参数（强制重建 / 换 IP）" \
  || bad "net() 没有 force 逃生口"
grep -q "no_output) NO_OUTPUT='no_output'" menu.sh \
  && ok "net() 参数按名解析（不再依赖位置，no_output/force/check 可任意组合）" \
  || bad "net() 参数仍是位置式的"

# 11.2 体检通过时提前返回，且必须释放单实例锁
NET_BODY=$(awk '/^net\(\) \{/,/^\}/' menu.sh)
grep -q 'if net_healthy; then' <<< "$NET_BODY" \
  && ok "net() 在重建前先调用 net_healthy 做体检" || bad "net() 未接入体检"
grep -q 'rm -f "\$WARPNET_LOCK"' <<< "$NET_BODY" \
  && ok "体检通过时释放单实例锁（否则后续 warp n 会被锁挡住）" || bad "体检分支未释放锁"

# 11.3 体检函数必须是只读的，且足够快
NH_BODY=$(awk '/^net_healthy\(\) \{/,/^\}/' menu.sh)
NIH_BODY=$(awk '/^net_iface_healthy\(\) \{/,/^\}/' menu.sh)
[ -n "$NH_BODY" ] && ok "net_healthy() 已定义" || bad "缺少 net_healthy()"
# 只读判据：不许出现任何会改动接口/路由的命令
if grep -qE 'wg-quick (up|down)|ip link (add|delete|set)|ip rule (add|delete)|ip route (add|delete)|systemctl (start|stop|restart|reset-failed)|warp_if_hard_reset|iptables .*-[AD]' <<< "$NH_BODY$NIH_BODY"; then
  bad "体检函数里出现了改状态的命令 —— 体检必须是只读的"
else
  ok "体检只读（无 wg-quick up/down、无 ip link/rule 增删、无 systemctl 启停）"
fi
# 速度判据：体检要直接打 IP 字面量，不走 ip_info 那条会卡 DNS 的主路径
grep -q 'net_iface_healthy "\$FAM" warp' <<< "$NH_BODY" \
  && ok "体检用专用快速探测（不经过 ip_info 的 DNS 主路径，避免占用锁数十秒）" \
  || bad "体检仍在走 ip_info 那条慢路径"
if grep -qE 'ip_case|ip_info' <<< "$NH_BODY"; then
  bad "net_healthy() 里出现了 ip_case/ip_info —— 会卡在自建域名的 DNS 解析上"
else
  ok "net_healthy() 不再调用 ip_case/ip_info"
fi
grep -q 'TRACE_URLS_4' <<< "$NIH_BODY" && grep -q 'TRACE_URLS_6' <<< "$NIH_BODY" \
  && ok "体检与 ip_info 共用同一份候选常量（不会两处分叉）" || bad "体检另写了一份候选清单"
grep -qE 'curl -ksm\$TRACE_CHECK_TIMEOUT --interface' <<< "$NIH_BODY" \
  && ok "体检探测带超时且绑定接口" || bad "体检探测缺超时/未绑定接口"
grep -q 'HEALTH_OK=' <<< "$NH_BODY" && grep -q 'HEALTH_BAD=' <<< "$NH_BODY" \
  && ok "体检会给出可用的族 / 不可用的族（供文案插值）" || bad "体检未产出 HEALTH_OK/HEALTH_BAD"

# 11.4 内部流程必须显式 force（否则改完配置后体检通过、新配置不会真正生效）
nf=$(grep -cE '^ +(net force|net no_output force)$' menu.sh)
[ "$nf" = 4 ] && ok "4 个改配置/换内核/安装流程的内部调用点已显式 force" \
             || bad "内部 force 调用点应为 4 处，实际 $nf 处"
grep -qE '\|\| net force$' menu.sh \
  && ok "onoff 的「拉起 WARP」分支用 net force（接口不在时必须无条件重建）" \
  || bad "onoff 未使用 force"
grep -q 'net; exit 0' menu.sh && bad "n) 分支仍是裸 net（无法把 force 透传进来）" \
                            || ok "n) 分支不再裸调用 net"

# 11.5 单实例锁：被挡住要可见，卡死要能接管（v3.2.14 实测踩出来的）
grep -q 'lock_touch() { echo "\$\$ \$(date +%s)" > "\$1"; }' menu.sh \
  && ok "锁里记 PID + 心跳时间戳（能被区分「在正常干活」与「已失控」）" \
  || bad "锁里没有心跳时间戳"
grep -q 'LOCK_STALE=' <<< "$NET_BODY" \
  && ok "锁有心跳超时阈值（超时可接管）" || bad "锁没有超时接管机制"
grep -qE 'kill -9 "\$_lp"' <<< "$NET_BODY" \
  && ok "持锁者失控时会被终止并接管，自愈不会被永久挡住" || bad "失控的持锁者不会被接管"
grep -qE 'hint " \$\(text 145\) "' <<< "$NET_BODY" \
  && ok "被别的实例挡住时会明确提示（不再静默返回 0，避免把「没做」误读成「成功」）" \
  || bad "被锁挡住时仍是静默返回"
grep -q 'lock_touch "\$WARPNET_LOCK"' <<< "$NET_BODY" \
  && ok "重试循环里会刷新心跳（长时间重试不会被误判成失控）" || bad "重试循环未刷新心跳"
# 旧格式（只有 PID）的遗留锁要能被识别成失效，否则升级后会被老锁卡住
grep -q 'NR==1{print \$2}' <<< "$NET_BODY" \
  && ok "兼容旧格式锁文件（无心跳字段 → 按失效处理）" || bad "未处理旧格式锁文件"
# 防御：curl 默认没有总超时，探测里漏写 -m 会把整个 warp 卡在探测阶段并占着锁
CC=$(awk '/^check_cdn\(\) \{/,/^\}/' menu.sh | grep -E '(^|[^[:alnum:]])curl -')
if [ -n "$CC" ]; then
  if grep -qv -- '-m[0-9]' <<< "$CC"; then
    bad "check_cdn 的 curl 缺 -m（默认无总超时，黑洞路由会把 warp 卡死并占住锁）"
  else
    ok "check_cdn 的 curl 都带总超时"
  fi
else
  ok "check_cdn 无 curl 调用（跳过超时检查）"
fi

# 11.5 保活巡检入口
grep -q 'warp n >/dev/null 2>&1 9>&- &' menu.sh \
  && ok "保活巡检仍调用 warp n（默认体检，兼容旧版 menu.sh）" \
  || bad "保活巡检入口变了 —— 旧版 menu.sh 上行为会不一致"
grep -q "warp n (获取 WARP IP；链路正常时不做任何改动" menu.sh \
  && ok "中文 help 已说明「正常时不做改动，强制重建用 warp n force」" || bad "help 未更新"
if [ -f README.md ]; then
  grep -q 'warp n force' README.md \
    && ok "README 已说明 warp n 的体检语义与 force" || bad "README 未说明"
else
  printf '  \033[33m·\033[0m README.md 不在当前目录，跳过该断言\n'
fi

# ===========================================================================
printf '\n\033[36m== 结果 ==\033[0m\n  通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then printf '  \033[32m全部通过\033[0m\n'; exit 0; else printf '  \033[31m有失败项\033[0m\n'; exit 1; fi
