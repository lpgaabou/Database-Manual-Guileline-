#!/usr/bin/env bash
# =============================================================================
# Greenplum gpadmin 用户环境变量一键配置脚本（RHEL/CentOS 7.x）
#
# 对应《风哥就业培训班 - 03.os级别txt脚本.txt》末尾 gpadmin 的
#   ~/.bash_profile 与 ~/.bashrc（source greenplum_path.sh + PG* 变量）。
# 这一步在【已安装 Greenplum 软件、已创建 gpadmin 用户】之后、初始化集群之前执行。
#
# 用法（root 执行；每台节点一次）：
#   bash greenplum_gpadmin_env.sh                 # 默认按 master 角色配置
#   GP_ROLE=segment bash greenplum_gpadmin_env.sh # segment 节点（不写 MASTER_DATA_DIRECTORY）
#   GP_ROLE=standby bash greenplum_gpadmin_env.sh # standby master（同样写 master 数据目录）
#
# 可把变量放进同目录 greenplum_gpadmin_env.conf 自动加载，或用命令行临时覆盖。
#
# 相对原 txt 的修正/增强：
#   * 修正笔误：/usr/1ocal -> 正确安装目录；gpseg-l(字母l) -> gpseg-1(数字1)；
#   * 路径统一到 /data/greenplum（原 txt 为 /usr/local、/greenplum）；
#   * 自动取 gpadmin 真实家目录（本套部署为 /data/greenplum/gpadmin，不写死 /home/gpadmin）；
#   * 幂等：环境变量集中写 ~/.greenplum_env（每次整体刷新），.bashrc/.bash_profile
#     只各加一行托管引用，重复执行不会产生重复行、不会把 PATH 叠加多次；
#   * 区分角色：仅 master/standby 写 MASTER_DATA_DIRECTORY，segment 不写；
#   * greenplum_path.sh 暂不存在时只告警（允许先配环境、后补软件软链）。
#
# 退出码：0 成功；非 0 致命失败（如 gpadmin 用户不存在）。
# =============================================================================
set -u
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-/var/log/greenplum_gpadmin_env.log}"

# ----------------------------- 可配置项（默认值） ----------------------------
GP_USER="${GP_USER:-gpadmin}"
# greenplum_path.sh 所在目录（GP_HOME，通常是指向具体版本的软链）
GP_HOME="${GP_HOME:-/data/greenplum/greenplum-db}"
# master 数据目录与段前缀/编号（MASTER_DATA_DIRECTORY=$MASTER_DIR/$SEG_PREFIX-$MASTER_CONTENT）
MASTER_DIR="${MASTER_DIR:-/data/greenplum/gpdata/master}"
SEG_PREFIX="${SEG_PREFIX:-gpseg}"
MASTER_CONTENT="${MASTER_CONTENT:-1}"
PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-postgres}"
# 角色：master | standby | segment（master/standby 写 MASTER_DATA_DIRECTORY）
GP_ROLE="${GP_ROLE:-master}"

# 同目录可选 conf
[ -f "$SCRIPT_DIR/greenplum_gpadmin_env.conf" ] && . "$SCRIPT_DIR/greenplum_gpadmin_env.conf"

MASTER_DATA_DIRECTORY="$MASTER_DIR/$SEG_PREFIX-$MASTER_CONTENT"
MARK="# managed-by-greenplum-env"

# ------------------------------- 日志 -----------------------------------------
if [ -t 1 ]; then C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[36m'; C_RST=$'\e[0m'
else C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''; fi
FAILED=0
_log(){ printf '%s %s\n' "[$(date '+%F %T')]" "$*"; }
log(){ _log "${C_BLU}==>>${C_RST} $*"; }
ok (){ _log "${C_GRN}[ OK ]${C_RST} $*"; }
warn(){ _log "${C_YEL}[WARN]${C_RST} $*"; }
err(){ _log "${C_RED}[FAIL]${C_RST} $*"; FAILED=1; }
step(){ printf '\n%s\n' "-----------------------------------------------"; _log "${C_BLU}### $*${C_RST}"; }

# =============================================================================
preflight() {
  step "00 前置检查"
  [ "$(id -u)" -eq 0 ] || { echo "请使用 root 执行"; exit 1; }
  case "$GP_ROLE" in master|standby|segment) ok "节点角色：$GP_ROLE";; *) err "GP_ROLE 只能是 master/standby/segment（当前 $GP_ROLE）"; exit 1;; esac

  if ! getent passwd "$GP_USER" >/dev/null 2>&1; then
    err "用户 $GP_USER 不存在：请先完成 Greenplum 软件安装与 gpadmin 创建阶段，再执行本脚本"
    exit 1
  fi
  GHOME="$(getent passwd "$GP_USER" | awk -F: '{print $6}')"
  [ -n "$GHOME" ] || { err "无法获取 $GP_USER 家目录"; exit 1; }
  mkdir -p "$GHOME"
  ok "gpadmin 家目录：$GHOME"

  # shell 文件兜底存在
  local f
  for f in "$GHOME/.bashrc" "$GHOME/.bash_profile"; do [ -f "$f" ] || { touch "$f"; ok "已创建 $(basename "$f")"; }; done

  if [ -f "$GP_HOME/greenplum_path.sh" ]; then
    ok "找到 $GP_HOME/greenplum_path.sh"
  else
    warn "$GP_HOME/greenplum_path.sh 当前不存在；环境变量仍会写入，请在安装/软链就绪后验证 (which psql)"
  fi
}

# =============================================================================
# 01. 生成集中的环境变量文件 ~/.greenplum_env（每次整体刷新，幂等）
# =============================================================================
write_envfile() {
  step "01 写入 $GHOME/.greenplum_env"
  local ef="$GHOME/.greenplum_env"
  {
    echo '#!/usr/bin/env bash'
    echo "# ---- Greenplum 环境变量（由 greenplum_gpadmin_env.sh 托管，请勿手改此块）----"
    echo "source $GP_HOME/greenplum_path.sh"
    echo "export PGHOME=$GP_HOME"
    echo "export PGPORT=$PGPORT"
    echo "export PGDATABASE=$PGDATABASE"
    echo "export PGUSER=$GP_USER"
    if [ "$GP_ROLE" != "segment" ]; then
      echo "export MASTER_DATA_DIRECTORY=$MASTER_DATA_DIRECTORY"
    else
      echo "# segment 节点不设置 MASTER_DATA_DIRECTORY"
    fi
  } > "$ef"
  ok ".greenplum_env 已生成（角色=$GP_ROLE）"
}

# =============================================================================
# 02. .bashrc 与 .bash_profile 建立托管引用（幂等，去重）
# =============================================================================
wire_shell_files() {
  step "02 关联 .bashrc / .bash_profile"
  local bashrc="$GHOME/.bashrc" bashprof="$GHOME/.bash_profile"

  # .bashrc 引入集中环境文件（只保留一行托管引用）
  if grep -qF "$MARK" "$bashrc" 2>/dev/null; then
    sed -i "\\#$MARK#d" "$bashrc"
  fi
  printf '[ -f %s/.greenplum_env ] && . %s/.greenplum_env  %s\n' "$GHOME" "$GHOME" "$MARK" >> "$bashrc"
  ok ".bashrc 已引用 .greenplum_env（幂等去重）"

  # .bash_profile 保证加载 .bashrc，使登录shell也生效（只保留一行托管引用）
  if grep -qF "$MARK" "$bashprof" 2>/dev/null; then
    sed -i "\\#$MARK#d" "$bashprof"
  fi
  printf '[ -f %s/.bashrc ] && . %s/.bashrc  %s\n' "$GHOME" "$GHOME" "$MARK" >> "$bashprof"
  ok ".bash_profile 已加载 .bashrc（登录 shell 生效，且不会重复加载 PATH）"

  chown "$GP_USER:" "$GHOME/.greenplum_env" "$bashrc" "$bashprof"
  chmod 644 "$GHOME/.greenplum_env" "$bashrc" "$bashprof"
  ok "属主已设为 $GP_USER"
}

# =============================================================================
# 03. 结果展示与验证
# =============================================================================
show_result() {
  step "03 当前配置结果"
  echo "------ $GHOME/.greenplum_env ------"
  cat "$GHOME/.greenplum_env"
  echo "------ $GHOME/.bashrc（托管行） ------"
  grep -F "$MARK" "$GHOME/.bashrc" || true
  echo "------ $GHOME/.bash_profile（托管行） ------"
  grep -F "$MARK" "$GHOME/.bash_profile" || true

  echo
  log "验证（以 gpadmin 登录 shell 读取）："
  cat <<EOF
  su - $GP_USER -c 'echo PGHOME=\$PGHOME; echo PGPORT=\$PGPORT; echo MASTER_DATA_DIRECTORY=\$MASTER_DATA_DIRECTORY; command -v psql'
EOF
  if [ "$GP_ROLE" != "segment" ] && [ -d "$MASTER_DATA_DIRECTORY" ]; then
    ok "检测到 $MASTER_DATA_DIRECTORY 已存在"
  fi
  _log "详细日志：$LOG_FILE"
}

main() {
  preflight
  write_envfile
  wire_shell_files
  show_result
  if [ "$FAILED" -eq 0 ]; then ok "gpadmin 环境变量配置完成。"; else err "存在失败项，请检查。"; fi
  exit "$FAILED"
}

main "$@" 2>&1 | tee -a "$LOG_FILE"
exit "${PIPESTATUS[0]}"
