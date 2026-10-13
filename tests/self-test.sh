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
printf '\n\033[36m== 结果 ==\033[0m\n  通过 %s 项，失败 %s 项\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then printf '  \033[32m全部通过\033[0m\n'; exit 0; else printf '  \033[31m有失败项\033[0m\n'; exit 1; fi
