#!/bin/sh
#
# 在路由器上把已安装的 smart-srun 就地更新到指定仓库/分支的最新代码。
#
# 用途：固件按上游最新编译，刷好之后跑一次这个脚本，即可换成 fork 里带修复的版本。
# 运行：LuCI 的「系统 → TTYD 终端」或 SSH 里执行
#
#   sh router-patch-smart-srun.sh
#
# 自定义来源：
#   FORK_REPO=owner/repo FORK_REF=branch sh router-patch-smart-srun.sh
#
# 只替换软件包自带的文件（*.py / lua / js / init.d / srunnet）。
# config.json、user_presets.json、school_presets_cache.json 等运行时状态不会被动。
# 每次运行都会先备份，失败或不满意可按结尾提示一键回滚。

set -eu

FORK_REPO="${FORK_REPO:-majianyu2007/smart-srun}"
FORK_REF="${FORK_REF:-fixes/all}"

LIB_DIR="/usr/lib/smart_srun"
LUA_DIR="/usr/lib/lua/luci"
TARBALL_URL="https://codeload.github.com/${FORK_REPO}/tar.gz/refs/heads/${FORK_REF}"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/smart-srun-backup-${STAMP}"
TMP_DIR="$(mktemp -d /tmp/smart-srun-patch.XXXXXX)"

log()  { printf '  %s\n' "$*"; }
step() { printf '\n[%s] %s\n' "$1" "$2"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

printf '=== smart-srun 就地更新 ===\n'
log "来源: ${FORK_REPO} @ ${FORK_REF}"
log "备份: ${BACKUP_DIR}"

[ -d "$LIB_DIR" ] || die "$LIB_DIR 不存在，smart-srun 似乎没有安装"

step 1/7 "下载源码"
wget -q --timeout=30 --tries=3 -O "$TMP_DIR/src.tar.gz" "$TARBALL_URL" ||
  die "下载失败: $TARBALL_URL（确认仓库/分支存在且为公开仓库）"
log "已下载 $(wc -c < "$TMP_DIR/src.tar.gz") 字节"

step 2/7 "解压并校验"
mkdir -p "$TMP_DIR/x"
tar -xzf "$TMP_DIR/src.tar.gz" -C "$TMP_DIR/x" || die "解压失败"
SRC="$(find "$TMP_DIR/x" -maxdepth 1 -mindepth 1 -type d | head -n1)"
[ -n "$SRC" ] || die "压缩包结构异常"
ROOT="$SRC/root"
for f in \
  "$ROOT/usr/lib/smart_srun/daemon.py" \
  "$ROOT/usr/lib/smart_srun/wireless.py" \
  "$ROOT/usr/lib/smart_srun/portal_detect.py" \
  "$ROOT/usr/bin/srunnet" \
  "$ROOT/etc/init.d/smart_srun"
do
  [ -f "$f" ] || die "压缩包缺少预期文件: ${f#$SRC/}"
done
log "结构校验通过"

step 3/7 "语法预检（防止装进去一个跑不起来的版本）"
PY="$(command -v python3 || true)"
[ -n "$PY" ] || die "找不到 python3"
for f in "$ROOT/usr/lib/smart_srun"/*.py "$ROOT/usr/lib/smart_srun/schools"/*.py; do
  [ -f "$f" ] || continue
  "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" ||
    die "Python 语法错误: ${f#$SRC/}"
done
if command -v lua >/dev/null 2>&1; then
  for f in "$ROOT/usr/lib/lua/luci/controller/smart_srun.lua" \
           "$ROOT/usr/lib/lua/luci/model/cbi/smart_srun.lua" \
           "$ROOT/usr/lib/lua/luci/smart_srun/schema.lua"; do
    [ -f "$f" ] || continue
    lua -e "local f,e=loadfile('$f'); if not f then print(e); os.exit(1) end" ||
      die "Lua 语法错误: ${f#$SRC/}"
  done
fi
log "语法预检通过"

step 4/7 "备份当前文件"
mkdir -p "$BACKUP_DIR"
tar -czf "$BACKUP_DIR/smart-srun-files.tar.gz" \
  "$LIB_DIR" \
  "$LUA_DIR/controller/smart_srun.lua" \
  "$LUA_DIR/model/cbi/smart_srun.lua" \
  "$LUA_DIR/smart_srun" \
  /www/luci-static/resources/smart_srun.js \
  /etc/init.d/smart_srun \
  /usr/bin/srunnet 2>/dev/null || true
log "已备份到 $BACKUP_DIR/smart-srun-files.tar.gz"

step 5/7 "安装新文件"
WAS_RUNNING=0
if [ -x /etc/init.d/smart_srun ]; then
  /etc/init.d/smart_srun running 2>/dev/null && WAS_RUNNING=1 || true
  /etc/init.d/smart_srun stop >/dev/null 2>&1 || true
fi

# 只覆盖包自带的文件；config.json / user_presets.json / *_cache.json 保持不动
cp -f "$ROOT/usr/lib/smart_srun"/*.py                       "$LIB_DIR/"
cp -f "$ROOT/usr/lib/smart_srun/defaults.json"              "$LIB_DIR/" 2>/dev/null || true
cp -f "$ROOT/usr/lib/smart_srun/school_presets_fallback.json" "$LIB_DIR/" 2>/dev/null || true
mkdir -p "$LIB_DIR/schools"
cp -f "$ROOT/usr/lib/smart_srun/schools"/*.py               "$LIB_DIR/schools/" 2>/dev/null || true
cp -f "$ROOT/usr/lib/lua/luci/controller/smart_srun.lua"    "$LUA_DIR/controller/" 2>/dev/null || true
cp -f "$ROOT/usr/lib/lua/luci/model/cbi/smart_srun.lua"     "$LUA_DIR/model/cbi/" 2>/dev/null || true
mkdir -p "$LUA_DIR/smart_srun"
cp -f "$ROOT/usr/lib/lua/luci/smart_srun"/*.lua             "$LUA_DIR/smart_srun/" 2>/dev/null || true
cp -f "$ROOT/www/luci-static/resources/smart_srun.js"       /www/luci-static/resources/ 2>/dev/null || true
cp -f "$ROOT/etc/init.d/smart_srun"                         /etc/init.d/smart_srun
cp -f "$ROOT/usr/bin/srunnet"                               /usr/bin/srunnet
chmod 0755 /etc/init.d/smart_srun /usr/bin/srunnet
log "文件已就位"

step 6/7 "清理缓存"
rm -rf "$LIB_DIR/__pycache__" "$LIB_DIR/schools/__pycache__" 2>/dev/null || true
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache 2>/dev/null || true
log "已清理 Python 与 LuCI 缓存"

step 7/7 "启动并验证"
if [ "$WAS_RUNNING" = "1" ] || [ -L /etc/rc.d/S99smart_srun ]; then
  /etc/init.d/smart_srun start >/dev/null 2>&1 || true
  sleep 6
fi

printf '\n=== 结果 ===\n'
if srunnet status 2>&1 | grep -qE '状态|守护'; then
  srunnet status 2>&1 | grep -E '状态|模式|账号|IP|连通|守护' | sed 's/^/  /'
else
  printf '  srunnet status 无正常输出，请检查 /var/log/smart_srun.log\n'
fi

printf '\n如需回滚：\n'
printf '  /etc/init.d/smart_srun stop\n'
printf '  tar -xzf %s -C /\n' "$BACKUP_DIR/smart-srun-files.tar.gz"
printf '  rm -rf %s/__pycache__ /tmp/luci-indexcache* /tmp/luci-modulecache\n' "$LIB_DIR"
printf '  /etc/init.d/smart_srun start\n'
