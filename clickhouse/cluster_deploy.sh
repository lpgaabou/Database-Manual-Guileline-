#!/usr/bin/env bash
###############################################################################
# ClickHouse 集群一键编排部署脚本
#
# 核心思路 :
#   在集群内【任意一台机器】执行本脚本，由它通过 SSH 把整个集群的所有节点
#   并发部署完成（ZooKeeper 先行，再 ClickHouse），无需逐台登录。
#   扩容到几百台：只改 cluster_hosts.conf 清单，脚本自动推导分片/副本拓扑。
#
# 适用环境 : CentOS 7 / RHEL 7（x86_64），以 root 运行
# 依赖说明 :
#   - 编排机自动生成本机专用 SSH 密钥并分发到所有节点；
#     若尚未免密，可用 SSH_PASSWORD=xxx 提供一次 root 口令（自动安装 sshpass）。
#   - 离线 tgz 包统一放在 PKG_SRC（默认 /clickhouse/soft）。
#
# 用法 :
#   ./cluster_deploy.sh deploy                 # 一键部署整个集群（默认动作）
#   ./cluster_deploy.sh verify                 # 集群级校验
#   ./cluster_deploy.sh status|start|stop|restart
#   ./cluster_deploy.sh rollback               # 全集群回滚最近一次部署
#   ./cluster_deploy.sh uninstall [--purge]    # 全集群卸载
#
# 常用环境变量 :
#   INVENTORY=./cluster_hosts.conf   主机清单
#   PKG_SRC=/clickhouse/soft         离线包目录
#   PARALLEL=10                      每波并发节点数
#   MULTI_INSTANCE=false             是否同时部署 9200 第二实例
#   SSH_PASSWORD=xxx                 首次分发密钥用的 root 口令
#   ROLLBACK_ON_FAILURE=true         部署失败是否自动全集群回滚
###############################################################################
set -Eeuo pipefail

#============================ 配置区（环境变量可覆盖） ========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVENTORY="${INVENTORY:-$SCRIPT_DIR/cluster_hosts.conf}"
PKG_SRC="${PKG_SRC:-/clickhouse/soft}"

REMOTE_DEPLOY_DIR="/opt/clickhouse-deploy"
REMOTE_SOFT_DIR="/clickhouse/soft"
STATE_DIR="${STATE_DIR:-/var/lib/cluster-deploy}"
SSH_KEY="${SSH_KEY:-/root/.ssh/cluster_deploy_key}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"

PARALLEL="${PARALLEL:-10}"
CH_VERSION="${CH_VERSION:-20.11.4.13}"
MULTI_INSTANCE="${MULTI_INSTANCE:-false}"
CLUSTER_NAME="${CLUSTER_NAME:-xxcluster3s2r02}"
CLUSTER_LAYER="${CLUSTER_LAYER:-02}"
ZK_CLIENT_PORT="${ZK_CLIENT_PORT:-32181}"
ZK_PEER_PORT="${ZK_PEER_PORT:-2888}"       # ZK 仲裁端口（节点间内部通信）
ZK_ELECT_PORT="${ZK_ELECT_PORT:-3888}"     # ZK 选举端口（节点间内部通信）
ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-true}"
# 第二实例（9200）分片对，分号分隔；留空则与实例1同拓扑
EXPAND_PAIRS="${EXPAND_PAIRS:-}"

#============================ 日志函数 =======================================
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
log_info(){ echo "${C_GRN}[INFO]${C_RST} $*"; }
log_warn(){ echo "${C_YEL}[WARN]${C_RST} $*"; }
log_err (){ echo "${C_RED}[ERROR]${C_RST} $*" >&2; }
log_step(){ echo; echo "${C_BLU}========== $* ==========${C_RST}"; }

#============================ 清单加载 =======================================
H_NAME=(); H_IP=(); H_ZK=(); H_SHARD=(); H_REP=()

trim(){ local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

load_inventory(){
  [ -f "$INVENTORY" ] || { log_err "找不到主机清单 $INVENTORY"; exit 1; }
  local line name ip zk shard rep
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(trim "$line")"
    [ -n "$line" ] || continue
    IFS='|' read -r name ip zk shard rep <<< "$line"
    name="$(trim "${name:-}")"; ip="$(trim "${ip:-}")"
    zk="$(trim "${zk:-0}")"; shard="$(trim "${shard:-0}")"; rep="$(trim "${rep:-0}")"
    [ -n "$name" ] && [ -n "$ip" ] || { log_err "清单行格式错误: $line"; exit 1; }
    case "$zk$shard$rep" in *[!0-9]*) log_err "清单编号必须为数字: $line"; exit 1;; esac
    H_NAME+=("$name"); H_IP+=("$ip")
    H_ZK+=("${zk:-0}"); H_SHARD+=("${shard:-0}"); H_REP+=("${rep:-0}")
  done < "$INVENTORY"
  [ ${#H_NAME[@]} -gt 0 ] || { log_err "主机清单为空"; exit 1; }
  log_info "已加载 ${#H_NAME[@]} 台主机：$INVENTORY"
}

#============================ 本机识别 =======================================
LOCAL_IPS="$(hostname -I 2>/dev/null || true)"
LOCAL_HOSTNAME="$(hostname 2>/dev/null || true)"
is_local(){
  local i="$1"
  [ -n "$LOCAL_HOSTNAME" ] && [ "${H_NAME[$i]}" = "$LOCAL_HOSTNAME" ] && return 0
  local x
  for x in $LOCAL_IPS; do [ "$x" = "${H_IP[$i]}" ] && return 0; done
  return 1
}

#============================ SSH 基础 =======================================
SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes)

ensure_ssh_key(){
  [ -f "$SSH_KEY" ] || {
    log_info "生成编排专用 SSH 密钥：$SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"; chmod 700 /root/.ssh
    ssh-keygen -t rsa -b 4096 -N '' -f "$SSH_KEY" -C 'cluster-deploy' >/dev/null
  }
}

ensure_sshpass(){
  command -v sshpass >/dev/null 2>&1 && return 0
  log_info "本机安装 sshpass（用于首次分发密钥）"
  yum install -y sshpass >/dev/null 2>&1 || { log_err "sshpass 安装失败，请手工安装或先配置免密"; return 1; }
}

# 让单台主机可免密登录
bootstrap_host(){
  local i="$1"
  is_local "$i" && return 0
  if ssh "${SSH_OPTS[@]}" "$SSH_USER@${H_IP[$i]}" 'true' 2>/dev/null; then return 0; fi
  log_info "${H_NAME[$i]} 尚未免密，开始分发公钥"
  [ -n "${SSH_PASSWORD:-}" ] || { log_err "${H_NAME[$i]} 无法免密登录，请设置 SSH_PASSWORD 或先手工配置"; return 1; }
  ensure_sshpass || return 1
  local pub; pub="$(cat "$SSH_KEY.pub")"
  # pub 需在编排端展开后注入远端命令，SC2029 为预期行为
  # shellcheck disable=SC2029
  SSHPASS="$SSH_PASSWORD" sshpass -e ssh -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
    "$SSH_USER@${H_IP[$i]}" \
    "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
     grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys; \
     chmod 600 ~/.ssh/authorized_keys" >/dev/null
  ssh "${SSH_OPTS[@]}" "$SSH_USER@${H_IP[$i]}" 'true' 2>/dev/null \
    || { log_err "${H_NAME[$i]} 密钥分发后仍无法登录"; return 1; }
  log_info "${H_NAME[$i]} 免密就绪"
}

# 在目标主机执行命令（本机直接 bash，远端 ssh；stdin 透传，用于 tar 管道）
exec_host(){
  local i="$1"; shift
  if is_local "$i"; then bash -c "$*"
  else
    # 命令字符串在编排端构造完成后整体下发，SC2029 为预期行为
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "$SSH_USER@${H_IP[$i]}" "$*"
  fi
}

#============================ 运行目录 =======================================
RUN_DIR=""
init_run(){
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="$STATE_DIR/run-$stamp"
  mkdir -p "$RUN_DIR"; ln -sfn "run-$stamp" "$STATE_DIR/latest" 2>/dev/null || true
}

#============================ 拓扑推导 =======================================
ZK_IDX=(); CH_IDX=()
ZK_NODES_LIST=""; ZK_HOSTS_CH=""; SHARD_PAIRS=""

derive_topology(){
  local i
  # ZK：按 myid 升序
  local zk_sorted=()
  for i in "${!H_NAME[@]}"; do [ "${H_ZK[$i]}" -gt 0 ] && zk_sorted+=("$i"); done
  if [ ${#zk_sorted[@]} -gt 0 ]; then
    mapfile -t zk_sorted < <(printf '%s\n' "${zk_sorted[@]}" | \
      while read -r x; do echo "${H_ZK[$x]} $x"; done | sort -n | awk '{print $2}')
  fi
  ZK_IDX=("${zk_sorted[@]}")
  local ips=(); chosts=()
  for i in "${zk_sorted[@]}"; do ips+=("${H_IP[$i]}"); chosts+=("${H_NAME[$i]}:$ZK_CLIENT_PORT"); done
  ZK_NODES_LIST="$(IFS=','; echo "${ips[*]}")"
  ZK_HOSTS_CH="$(IFS=','; echo "${chosts[*]}")"
  [ ${#ZK_IDX[@]} -gt 0 ] && log_info "ZooKeeper ${#ZK_IDX[@]} 节点：$ZK_NODES_LIST"
  case $(( ${#ZK_IDX[@]} % 2 )) in 0) log_warn "ZooKeeper 节点数为偶数，生产建议奇数（3/5）";; esac

  # CH：按分片号、副本号排序
  local ch_sorted=()
  for i in "${!H_NAME[@]}"; do [ "${H_SHARD[$i]}" -gt 0 ] && ch_sorted+=("$i"); done
  if [ ${#ch_sorted[@]} -gt 0 ]; then
    mapfile -t ch_sorted < <(printf '%s\n' "${ch_sorted[@]}" | \
      while read -r x; do printf '%03d %03d %s\n' "${H_SHARD[$x]}" "${H_REP[$x]}" "$x"; done \
      | sort -n | awk '{print $3}')
  fi
  CH_IDX=("${ch_sorted[@]}")

  # 每分片两个副本 → “h1 h2”，分号连接
  local pairs=() cur_shard="" cur_pair=""
  for i in "${ch_sorted[@]}"; do
    if [ "${H_SHARD[$i]}" != "$cur_shard" ]; then
      [ -n "$cur_pair" ] && pairs+=("$cur_pair")
      cur_shard="${H_SHARD[$i]}"; cur_pair="${H_NAME[$i]}"
    else cur_pair="$cur_pair ${H_NAME[$i]}"
    fi
  done
  [ -n "$cur_pair" ] && pairs+=("$cur_pair")
  SHARD_PAIRS="$(IFS=';'; echo "${pairs[*]}")"
  [ ${#CH_IDX[@]} -gt 0 ] && log_info "ClickHouse ${#CH_IDX[@]} 节点，分片拓扑：$SHARD_PAIRS"

  # 校验每分片副本数
  local p
  for p in "${pairs[@]}"; do
    local n; n="$(wc -w <<< "$p")"
    [ "$n" -eq 2 ] || log_warn "分片 [$p] 副本数=$n，生产建议每分片 2 副本"
  done
}

#============================ 前置检查 =======================================
preflight(){
  require_root
  [ -f "$SCRIPT_DIR/clickhouse_install.sh" ] || { log_err "缺少 clickhouse_install.sh"; exit 1; }
  [ -f "$SCRIPT_DIR/zookeeper_install.sh" ] || { log_err "缺少 zookeeper_install.sh"; exit 1; }
  [ -d "$PKG_SRC" ] || { log_err "离线包目录不存在：$PKG_SRC（可用 PKG_SRC=... 指定）"; exit 1; }
  local f missing=()
  local req=(
    "clickhouse-common-static-$CH_VERSION.tgz"
    "clickhouse-common-static-dbg-$CH_VERSION.tgz"
    "clickhouse-server-$CH_VERSION.tgz"
    "clickhouse-client-$CH_VERSION.tgz"
    "jdk-8u261-linux-x64.tar.gz"
    "apache-zookeeper-3.6.2.tar.gz")
  for f in "${req[@]}"; do [ -f "$PKG_SRC/$f" ] || missing+=("$f"); done
  if [ ${#missing[@]} -gt 0 ]; then log_err "缺少离线包：${missing[*]}"; exit 1; fi
  log_info "离线包齐全：$PKG_SRC"
}

require_root(){ [ "$(id -u)" -eq 0 ] || { log_err "请使用 root 运行"; exit 1; }; }

#============================ 载荷分发 =======================================
prepare_stage(){
  STAGE="$RUN_DIR/stage"
  mkdir -p "$STAGE$REMOTE_SOFT_DIR" "$STAGE$REMOTE_DEPLOY_DIR"
  cp -a "$PKG_SRC"/. "$STAGE$REMOTE_SOFT_DIR"/
  cp -a "$SCRIPT_DIR/clickhouse_install.sh" "$SCRIPT_DIR/zookeeper_install.sh" "$STAGE$REMOTE_DEPLOY_DIR"/
  # 由清单生成 hosts 解析文件
  local i
  : > "$STAGE$REMOTE_DEPLOY_DIR/hosts.conf"
  for i in "${!H_NAME[@]}"; do echo "${H_IP[$i]} ${H_NAME[$i]}" >> "$STAGE$REMOTE_DEPLOY_DIR/hosts.conf"; done
}

sync_host(){
  local i="$1"
  exec_host "$i" "mkdir -p $REMOTE_SOFT_DIR $REMOTE_DEPLOY_DIR"
  local remote_man local_man
  remote_man="$(exec_host "$i" "cd / && sha256sum $REMOTE_SOFT_DIR/* $REMOTE_DEPLOY_DIR/* 2>/dev/null || true" \
    | sed 's#  /#  ./#')"
  local_man="$(cd "$STAGE" && find . -type f -print0 | sort -z | xargs -0 sha256sum)"
  if [ "$remote_man" = "$local_man" ]; then
    log_info "${H_NAME[$i]} 安装文件已同步，跳过传输"
    return 0
  fi
  log_info "${H_NAME[$i]} 传输安装文件 ..."
  tar cf - -C "$STAGE" . | exec_host "$i" "tar xf - -C /"
}

#============================ 波次并发执行器 =================================
# $1=阶段名 $2=worker 函数名；其余为目标主机数组下标
run_phase(){
  local name="$1" worker="$2"; shift 2
  local targets=("$@")
  local total=${#targets[@]} pos=0 fail=0
  while [ "$pos" -lt "$total" ]; do
    local chunk=(); pids=()
    while [ "${#chunk[@]}" -lt "$PARALLEL" ] && [ "$pos" -lt "$total" ]; do
      chunk+=("${targets[$pos]}"); pos=$((pos+1))
    done
    local h
    for h in "${chunk[@]}"; do
      ( $worker "$h" ) > "$RUN_DIR/${H_NAME[$h]}.log" 2>&1 &
      pids+=("$!")
    done
    local rc
    for rc in "${pids[@]}"; do wait "$rc" || fail=$((fail+1)); done
    if [ $fail -gt 0 ]; then
      log_err "$name：有 $fail 个节点失败，本阶段中止（日志见 $RUN_DIR/<主机名>.log）"
      return 1
    fi
    log_info "$name：已完成 $pos/$total"
  done
  return 0
}

#============================ 节点部署 worker ===============================
zk_install_worker(){
  local i="$1"
  exec_host "$i" "cd $REMOTE_DEPLOY_DIR && ZK_NODES_LIST='$ZK_NODES_LIST' \
    CLIENT_PORT='$ZK_CLIENT_PORT' ZK_PEER_PORT='$ZK_PEER_PORT' ZK_ELECT_PORT='$ZK_ELECT_PORT' \
    bash ./zookeeper_install.sh ${H_ZK[$i]} install"
}

ch_install_worker(){
  local i="$1"
  local shard rep
  shard="$(printf '%02d' "${H_SHARD[$i]}")"
  rep="$(printf '%02d' "${H_REP[$i]}")"
  local local_replica="${CLUSTER_NAME}_${shard}_${rep}"
  local extra=""
  if [ "$MULTI_INSTANCE" = "true" ]; then
    local p9200="${EXPAND_PAIRS:-$SHARD_PAIRS}"
    extra="MULTI_INSTANCE=true SHARD_PAIRS_9200='$p9200'"
  fi
  exec_host "$i" "cd $REMOTE_DEPLOY_DIR && \
    SETUP_CLUSTER=true $extra \
    CLUSTER_NAME='$CLUSTER_NAME' CLUSTER_LAYER='$CLUSTER_LAYER' \
    LOCAL_SHARD='$shard' LOCAL_REPLICA='$local_replica' \
    ZK_HOSTS='$ZK_HOSTS_CH' HOSTS_FILE='$REMOTE_DEPLOY_DIR/hosts.conf' \
    SHARD_PAIRS='$SHARD_PAIRS' \
    bash ./clickhouse_install.sh install"
}

#============================ 等待 ZK 选举 ==================================
wait_quorum(){
  local need=$(( ${#ZK_IDX[@]} / 2 + 1 )) ok i resp
  log_step "等待 ZooKeeper 选举（需 $need 节点 imok）"
  for _ in $(seq 1 60); do
    ok=0
    for i in "${ZK_IDX[@]}"; do
      resp="$(exec_host "$i" "exec 3<>/dev/tcp/127.0.0.1/$ZK_CLIENT_PORT && printf ruok >&3 && \
        { timeout 3 cat <&3 || true; } ; exec 3<&-" 2>/dev/null || true)"
      [ "$resp" = "imok" ] && ok=$((ok+1))
    done
    if [ "$ok" -ge "$need" ]; then log_info "ZooKeeper 已形成法定人数（$ok/${#ZK_IDX[@]}）"; return 0; fi
    sleep 2
  done
  log_err "ZooKeeper 60 次探测未形成法定人数"; return 1
}

#============================ 集群校验 ======================================
cluster_verify(){
  log_step "集群校验"
  local i fail=0
  for i in "${ZK_IDX[@]}"; do
    local resp
    resp="$(exec_host "$i" "exec 3<>/dev/tcp/127.0.0.1/$ZK_CLIENT_PORT && printf ruok >&3 && \
      { timeout 3 cat <&3 || true; }; exec 3<&-" 2>/dev/null || true)"
    if [ "$resp" = "imok" ]; then log_info "${H_NAME[$i]} ZooKeeper imok"
    else log_err "${H_NAME[$i]} ZK 异常"; fail=1; fi
  done
  for i in "${CH_IDX[@]}"; do
    if exec_host "$i" "cd $REMOTE_DEPLOY_DIR && bash ./clickhouse_install.sh verify" >/dev/null; then
      log_info "${H_NAME[$i]} ClickHouse 校验通过"
    else log_err "${H_NAME[$i]} CH 校验失败"; fail=1; fi
  done
  # system.clusters 成员数应等于 CH 节点数
  if [ ${#CH_IDX[@]} -gt 0 ]; then
    local first="${CH_IDX[0]}" out expected=${#CH_IDX[@]}
    out="$(exec_host "$first" "clickhouse-client --port 9000 --user default -q \
      \"SELECT count() FROM system.clusters WHERE cluster='$CLUSTER_NAME'\"" 2>/dev/null || echo 0)"
    if [ "$out" = "$expected" ]; then log_info "system.clusters 成员数=$out，拓扑正确"
    else log_err "system.clusters 成员数=$out，期望 $expected"; fail=1; fi
  fi
  [ $fail -eq 0 ] || exit 1
  log_info "集群校验全部通过"
}

#============================ 全集群回滚 ====================================
cluster_rollback(){
  require_root; derive_topology
  log_step "全集群回滚（先 ClickHouse，后 ZooKeeper）"
  if [ ${#CH_IDX[@]} -gt 0 ]; then
    run_phase "回滚 ClickHouse" ch_rollback_worker "${CH_IDX[@]}" || true
  fi
  if [ ${#ZK_IDX[@]} -gt 0 ]; then
    run_phase "回滚 ZooKeeper" zk_rollback_worker "${ZK_IDX[@]}" || true
  fi
  log_info "全集群回滚完成"
}
ch_rollback_worker(){ exec_host "$1" "cd $REMOTE_DEPLOY_DIR && bash ./clickhouse_install.sh rollback"; }
zk_rollback_worker(){ exec_host "$1" "cd $REMOTE_DEPLOY_DIR && bash ./zookeeper_install.sh ${H_ZK[$1]} rollback"; }

#============================ 卸载 ==========================================
cluster_uninstall(){
  require_root; derive_topology
  local purge="${1:-false}"
  log_warn "即将卸载整个集群（purge=$purge）"
  local flag=""
  [ "$purge" = "true" ] && flag="--purge"
  if [ ${#CH_IDX[@]} -gt 0 ]; then
    run_phase "卸载 ClickHouse" "ch_uninstall_worker $flag" "${CH_IDX[@]}" || true
  fi
  if [ ${#ZK_IDX[@]} -gt 0 ]; then
    run_phase "卸载 ZooKeeper" zk_uninstall_worker "${ZK_IDX[@]}" || true
  fi
  log_info "全集群卸载完成"
}
ch_uninstall_worker(){
  local flag="$1" i="$2"
  exec_host "$i" "cd $REMOTE_DEPLOY_DIR && bash ./clickhouse_install.sh uninstall $flag"
}
zk_uninstall_worker(){ exec_host "$1" "cd $REMOTE_DEPLOY_DIR && bash ./zookeeper_install.sh ${H_ZK[$1]} uninstall"; }

#============================ 通用动作 fan-out ==============================
ch_simple_worker(){
  local action="$1" i="$2"
  exec_host "$i" "cd $REMOTE_DEPLOY_DIR && bash ./clickhouse_install.sh $action"
}
zk_simple_worker(){
  local action="$1" i="$2"
  exec_host "$i" "cd $REMOTE_DEPLOY_DIR && bash ./zookeeper_install.sh ${H_ZK[$i]} $action"
}

cluster_start(){
  require_root; derive_topology
  [ ${#ZK_IDX[@]} -gt 0 ] && run_phase "启动 ZooKeeper" "zk_simple_worker start" "${ZK_IDX[@]}"
  [ ${#CH_IDX[@]} -gt 0 ] && run_phase "启动 ClickHouse" "ch_simple_worker start" "${CH_IDX[@]}"
}
cluster_stop(){
  require_root; derive_topology
  [ ${#CH_IDX[@]} -gt 0 ] && run_phase "停止 ClickHouse" "ch_simple_worker stop" "${CH_IDX[@]}"
  [ ${#ZK_IDX[@]} -gt 0 ] && run_phase "停止 ZooKeeper" "zk_simple_worker stop" "${ZK_IDX[@]}"
}
cluster_restart(){
  require_root; derive_topology
  [ ${#ZK_IDX[@]} -gt 0 ] && run_phase "重启 ZooKeeper" "zk_simple_worker restart" "${ZK_IDX[@]}"
  wait_quorum || true
  [ ${#CH_IDX[@]} -gt 0 ] && run_phase "重启 ClickHouse" "ch_simple_worker restart" "${CH_IDX[@]}"
}
cluster_status(){
  require_root; derive_topology
  local i
  for i in "${CH_IDX[@]}"; do
    local s
    s="$(exec_host "$i" 'systemctl is-active clickhouse-server' 2>/dev/null || echo unknown)"
    printf '  %-12s ClickHouse: %s\n' "${H_NAME[$i]}" "$s"
  done
  for i in "${ZK_IDX[@]}"; do
    local s
    s="$(exec_host "$i" 'systemctl is-active zookeeper' 2>/dev/null || echo unknown)"
    printf '  %-12s ZooKeeper : %s\n' "${H_NAME[$i]}" "$s"
  done
}

#============================ 部署主编排 ====================================
on_fatal(){
  local code="$1" line="$2"
  log_err "编排脚本第 $line 行发生未预期错误（退出码 $code）"
  if [ -n "$RUN_DIR" ] && [ "$ROLLBACK_ON_FAILURE" = "true" ]; then
    log_err "开始全集群自动回滚 ..."
    cluster_rollback || true
  fi
  exit "$code"
}

do_deploy(){
  require_root
  trap 'on_fatal $? $LINENO' ERR
  log_step "集群部署开始（运行目录 $RUN_DIR）"
  preflight
  ensure_ssh_key

  log_step "阶段 0：SSH 免密引导"
  run_phase "SSH 引导" bootstrap_ssh_worker "${!H_NAME[@]}"

  log_step "阶段 1：准备并分发安装文件"
  prepare_stage
  run_phase "文件分发" sync_worker "${!H_NAME[@]}"

  if [ ${#ZK_IDX[@]} -gt 0 ]; then
    log_step "阶段 2：并发部署 ZooKeeper（${#ZK_IDX[@]} 节点，每波 $PARALLEL）"
    run_phase "部署 ZooKeeper" zk_install_worker "${ZK_IDX[@]}"
    wait_quorum
  else
    log_warn "清单中没有 ZooKeeper 节点，跳过"
  fi

  if [ ${#CH_IDX[@]} -gt 0 ]; then
    log_step "阶段 3：并发部署 ClickHouse（${#CH_IDX[@]} 节点，每波 $PARALLEL）"
    run_phase "部署 ClickHouse" ch_install_worker "${CH_IDX[@]}"
  else
    log_warn "清单中没有 ClickHouse 节点，跳过"
  fi

  log_step "阶段 4：集群校验"
  cluster_verify_body

  trap - ERR
  echo; log_info "整个集群部署完成"
  log_info "校验 SQL：clickhouse-client -q \"SELECT * FROM system.clusters WHERE cluster='$CLUSTER_NAME'\""
}

# 部署末尾的校验（复用 cluster_verify 的核心，不重新 init_run）
cluster_verify_body(){
  local first="${CH_IDX[0]}" out expected=${#CH_IDX[@]} fail=0 i
  for i in "${CH_IDX[@]}"; do
    exec_host "$i" "cd $REMOTE_DEPLOY_DIR && bash ./clickhouse_install.sh verify" >/dev/null \
      || { log_err "${H_NAME[$i]} 节点校验失败"; fail=1; }
  done
  out="$(exec_host "$first" "clickhouse-client --port 9000 --user default -q \
    \"SELECT count() FROM system.clusters WHERE cluster='$CLUSTER_NAME'\"" 2>/dev/null || echo 0)"
  if [ "$out" = "$expected" ]; then log_info "system.clusters 成员数=$out，集群拓扑正确"
  else log_err "system.clusters 成员数=$out，期望 $expected"; fail=1; fi
  [ $fail -eq 0 ] || {
    if [ "$ROLLBACK_ON_FAILURE" = "true" ]; then cluster_rollback; fi
    exit 1
  }
}

# worker 包装（run_phase 传一个下标参数）
bootstrap_ssh_worker(){ bootstrap_host "$1"; }
sync_worker(){ sync_host "$1"; }

#============================ 入口 ==========================================
main(){
  local action="${1:-deploy}"; shift || true
  load_inventory
  derive_topology
  require_root
  init_run
  case "$action" in
    deploy)    do_deploy ;;
    verify)    cluster_verify ;;
    status)    cluster_status ;;
    start)     cluster_start ;;
    stop)      cluster_stop ;;
    restart)   cluster_restart ;;
    rollback)  cluster_rollback ;;
    uninstall) local purge="false"; [ "${1:-}" = "--purge" ] && purge="true"; cluster_uninstall "$purge" ;;
    *) echo "用法: $0 {deploy|verify|status|start|stop|restart|rollback|uninstall [--purge]}"; exit 1 ;;
  esac
}
main "$@"
