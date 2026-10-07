#!/usr/bin/env bash
###############################################################################
# ZooKeeper 一键安装部署脚本（ClickHouse 分片副本高可用配套）
#
# 适用环境 : CentOS 7 / RHEL 7（x86_64），root 运行
# 部署内容 : JDK 1.8.0_261 + ZooKeeper 3.6.2（系统服务，开机自启）
# 特性     : 幂等、失败自动回滚、支持手动 rollback、支持多节点集群编排
#
# 单机模式（在每台 ZK 节点执行，myid 为该节点编号 1..N）:
#   ./zookeeper_install.sh 1 install
#   ./zookeeper_install.sh 1 status|start|stop|restart
#   ./zookeeper_install.sh 1 rollback
#   ./zookeeper_install.sh 1 uninstall
#
# 集群模式（在任意一台能免密 ssh 到全部节点的机器执行）:
#   ZK_NODES_LIST='ip1,ip2,ip3' ./zookeeper_install.sh cluster install
#   ZK_NODES_LIST='ip1,ip2,ip3' ./zookeeper_install.sh cluster verify
#   ZK_NODES_LIST='ip1,ip2,ip3' ./zookeeper_install.sh cluster status
#   ZK_NODES_LIST='ip1,ip2,ip3' ./zookeeper_install.sh cluster uninstall
#
# 也可用环境变量: ZK_MYID=1 ./zookeeper_install.sh install


#    nc 在 CentOS 7 最小安装里默认没有 → 探测命令静默失败，显示 N/A；
#    换 _zk_remote_state 用 bash -s + heredoc 时，heredoc 内容被漏掉 → 函数空跑，永远返回空；
#    用 bash -x ... | head -60 调试 → 被 SIGPIPE 提前截断，误以为“卡住”。
#下次调脚本的通用口诀：
#    探测远端状态优先用目标软件自带的命令（zkServer.sh status），不要依赖 nc/telnet 这类可装可不装的包；
#    调试用 bash -x ... > /tmp/x.log 2>&1，再 less /tmp/x.log，别接 head；
#    ssh host cmd 一定要显式传 JAVA_HOME（非交互 shell 不读 /etc/profile.d/）。
###############################################################################
set -Eeuo pipefail

#============================ 配置区 =========================================
CH_BASE="${CH_BASE:-/clickhouse}"
CH_USER="${CH_USER:-clickhouse}"
CH_GROUP="${CH_GROUP:-clickhouse}"
PKG_DIR="${PKG_DIR:-$CH_BASE/soft}"
APP_DIR="${APP_DIR:-$CH_BASE/app}"

JDK_TGZ="${JDK_TGZ:-jdk-8u261-linux-x64.tar.gz}"
JDK_DIRNAME="${JDK_DIRNAME:-jdk1.8.0_261}"
ZK_TGZ="${ZK_TGZ:-apache-zookeeper-3.6.2-bin.tar.gz}"
ZK_DIRNAME="${ZK_DIRNAME:-apache-zookeeper-3.6.2-bin}"
ZK_HOME="$APP_DIR/zookeeper"
ZK_DATA="$CH_BASE/zookeeper/data"
ZK_LOG="$CH_BASE/zookeeper/log"
ZK_HEAP="${ZK_HEAP:-1000}"
CLIENT_PORT="${CLIENT_PORT:-32181}"

# 集群节点（编号取自数组顺序；与官网规划一致，可改）
ZK_NODES=("192.168.221.129" "192.168.221.130" "192.168.221.131")
if [ -n "${ZK_NODES_LIST:-}" ]; then
  IFS=',' read -ra ZK_NODES <<< "${ZK_NODES_LIST// /}"
fi
ZK_PEER_PORT="${ZK_PEER_PORT:-2888}"
ZK_ELECT_PORT="${ZK_ELECT_PORT:-3888}"

STATE_DIR="${STATE_DIR:-/var/lib/zookeeper-installer}"
UNIT_NAME="zookeeper.service"

# 集群编排相关
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)
SCP_OPTS=(-P "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o LogLevel=ERROR)
SELF_PATH="$(readlink -f "$0")"
REMOTE_SCRIPT="/tmp/zookeeper_install.sh"
REMOTE_LOG_DIR="/tmp/zk-install-logs"

#============================ 通用函数 =======================================
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
log_info(){ echo "${C_GRN}[INFO]${C_RST} $*"; }
log_warn(){ echo "${C_YEL}[WARN]${C_RST} $*"; }
log_err (){ echo "${C_RED}[ERROR]${C_RST} $*" >&2; }
log_step(){ echo; echo "${C_BLU}========== $* ==========${C_RST}"; }

BK_DIR=""; MAN_ADD=""; MAN_PERSIST=""
init_state(){
  MAN_PERSIST="$STATE_DIR/manifest"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
  BK_DIR="$STATE_DIR/backup/$stamp"; MAN_ADD="$STATE_DIR/manifest.add"
  mkdir -p "$BK_DIR/files" "$STATE_DIR/backup"; : > "$MAN_ADD"
  ln -sfn "backup/$stamp" "$STATE_DIR/latest" >/dev/null 2>&1 || true
  touch "$MAN_PERSIST"
}

backup_file(){
  local p="$1" rel
  { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  # 已在 MAN_ADD 或 MAN_PERSIST 里备份过就跳过，防止清单膨胀
  if grep -qP "^B\t\Q$p\E\t" "$MAN_ADD" 2>/dev/null || \
     grep -qP "^B\t\Q$p\E\t" "$MAN_PERSIST" 2>/dev/null; then
    return 0
  fi
  rel="${p#/}"; rel="${rel//\//_}"
  cp -a "$p" "$BK_DIR/files/$rel"
  printf 'B\t%s\tfiles/%s\n' "$p" "$rel" >> "$MAN_ADD"
}

write_file(){
  local p="$1"; mkdir -p "$(dirname "$p")"
  if [ -e "$p" ] || [ -L "$p" ]; then backup_file "$p"; else printf 'F\t%s\n' "$p" >> "$MAN_ADD"; fi
  cat > "$p"
}

ensure_dir(){
  local p="$1"
  if [ ! -e "$p" ]; then mkdir -p "$p"; printf 'D\t%s\n' "$p" >> "$MAN_ADD"; else mkdir -p "$p"; fi
}
reg_tree(){ printf 'T\t%s\n' "$1" >> "$MAN_ADD"; }

dump_diag(){
  log_err "----- systemctl status $UNIT_NAME -----"
  systemctl status "$UNIT_NAME" --no-pager -l 2>/dev/null | tail -n 25 >&2 || true
  log_err "----- journalctl -u $UNIT_NAME（最近 50 行）-----"
  journalctl -u "$UNIT_NAME" --no-pager -n 50 2>/dev/null >&2 || true
  log_err "----- ZooKeeper 自身日志（$ZK_LOG，最近 40 行）-----"
  local f
  for f in "$ZK_LOG"/*.log "$ZK_LOG"/*.out; do
    [ -f "$f" ] && { echo "==> $f" >&2; tail -n 40 "$f" >&2; }
  done
}

step_check_local_ip(){
  local myip="${ZK_NODES[$((ZK_MYID-1))]:-}"
  if [ -z "$myip" ]; then
    log_err "myid=$ZK_MYID 超出节点清单数量（当前 ${#ZK_NODES[@]} 个节点）"
    return 1
  fi
  local local_ips x found=0
  local_ips="$( { ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1; } || \
                { ifconfig -a 2>/dev/null | awk '/inet /{print $2}'; } || hostname -I )"
  for x in $local_ips; do
    x="${x%%/*}"
    [ "$x" = "$myip" ] && { found=1; break; }
  done
  if [ "$found" -ne 1 ]; then
    log_err "本节点 myid=$ZK_MYID 对应的集群地址是 $myip，但本机网卡上没有这个 IP"
    log_err "ZooKeeper 无法绑定 $myip:$ZK_PEER_PORT/$ZK_ELECT_PORT，服务会启动即退出。"
    log_err "请按本机真实 IP 注入节点清单后重试，例如："
    log_err "  ZK_NODES_LIST='本机IP,节点2IP,节点3IP' $0 $ZK_MYID install"
    return 1
  fi
  log_info "本节点 myid=$ZK_MYID 地址 $myip 校验通过"
}

#============================ 安装步骤 =======================================
step_prereq(){
  log_step "前置检查：用户与目录"
  if ! getent group "$CH_GROUP" >/dev/null; then groupadd "$CH_GROUP"; printf 'G\t%s\n' "$CH_GROUP" >> "$MAN_ADD"; fi
  if ! id -u "$CH_USER" >/dev/null 2>&1; then
    useradd -g "$CH_GROUP" -m -s /bin/bash "$CH_USER"; printf 'X\t%s\n' "$CH_USER" >> "$MAN_ADD"
  fi
  ensure_dir "$APP_DIR"; ensure_dir "$PKG_DIR"; ensure_dir "$ZK_DATA"; ensure_dir "$ZK_LOG"
}

step_jdk(){
  log_step "安装 JDK（$JDK_DIRNAME）"
  if [ -x "$CH_BASE/$JDK_DIRNAME/bin/java" ]; then log_info "JDK 已存在，跳过"; return 0; fi
  [ -f "$PKG_DIR/$JDK_TGZ" ] || { log_err "找不到 $PKG_DIR/$JDK_TGZ"; return 1; }
  tar xzf "$PKG_DIR/$JDK_TGZ" -C "$CH_BASE"
  reg_tree "$CH_BASE/$JDK_DIRNAME"
}

step_zk(){
  log_step "安装 ZooKeeper（$ZK_DIRNAME）"
  step_check_local_ip
  if [ -d "$ZK_HOME" ]; then log_info "ZooKeeper 目录已存在，跳过解压"; else
    [ -f "$PKG_DIR/$ZK_TGZ" ] || { log_err "找不到 $PKG_DIR/$ZK_TGZ"; return 1; }
    tar xzf "$PKG_DIR/$ZK_TGZ" -C "$APP_DIR"
    reg_tree "$APP_DIR/$ZK_DIRNAME"
    ln -sfn "$APP_DIR/$ZK_DIRNAME" "$ZK_HOME"
    printf 'L\t%s\n' "$ZK_HOME" >> "$MAN_ADD"
  fi

  local servers="" i=1 node
  for node in "${ZK_NODES[@]}"; do
    [ -z "$node" ] && continue
    servers+="server.$i=$node:$ZK_PEER_PORT:$ZK_ELECT_PORT"$'\n'; i=$((i+1))
  done
  write_file "$ZK_HOME/conf/zoo.cfg" <<EOF
tickTime=2000
initLimit=30000
syncLimit=10
maxClientCnxns=2000
maxSessionTimeout=60000000
autopurge.snapRetainCount=10
autopurge.purgeInterval=1
globalOutstandingLimit=200
preAllocSize=131072
snapCount=3000000
leaderServes=yes
dataDir=$ZK_DATA
dataLogDir=$ZK_LOG
clientPort=$CLIENT_PORT
$servers
EOF

  write_file "$ZK_DATA/myid" <<EOF
$ZK_MYID
EOF

  if grep -q '^ZK_SERVER_HEAP=' "$ZK_HOME/bin/zkEnv.sh"; then
    sed -i "s#^ZK_SERVER_HEAP=.*#ZK_SERVER_HEAP=\"\${ZK_SERVER_HEAP:-$ZK_HEAP}\"#" "$ZK_HOME/bin/zkEnv.sh"
  else
    echo "ZK_SERVER_HEAP=\"\${ZK_SERVER_HEAP:-$ZK_HEAP}\"" >> "$ZK_HOME/bin/zkEnv.sh"
  fi

  write_file /etc/profile.d/zookeeper.sh <<EOF
export JAVA_HOME=$CH_BASE/$JDK_DIRNAME
export PATH=\$JAVA_HOME/bin:$ZK_HOME/bin:\$PATH
EOF

  chown -R "$CH_USER:$CH_GROUP" "$CH_BASE/$JDK_DIRNAME" "$APP_DIR/$ZK_DIRNAME" "$ZK_DATA" "$ZK_LOG"
}

step_unit(){
  log_step "配置 systemd 服务 $UNIT_NAME"
  local unit_file="/etc/systemd/system/$UNIT_NAME"
  local existed=0; [ -e "$unit_file" ] && existed=1

  write_file "$unit_file" <<EOF
[Unit]
Description=ZooKeeper Service
After=network-online.target
Requires=network-online.target

[Service]
Type=simple
User=$CH_USER
Group=$CH_GROUP
Environment=JAVA_HOME=$CH_BASE/$JDK_DIRNAME
Environment=ZK_SERVER_HEAP=$ZK_HEAP
ExecStart=$ZK_HOME/bin/zkServer.sh start-foreground
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  # 仅当 unit 文件原本不存在时才记录 UN，避免回滚把已有服务一起干掉
  [ "$existed" -eq 0 ] && printf 'UN\t%s\n' "$UNIT_NAME" >> "$MAN_ADD"

  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1
  systemctl restart "$UNIT_NAME"

  local n st
  for n in $(seq 1 20); do
    st="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
    case "$st" in
      active) log_info "$UNIT_NAME 已进入 active"; return 0 ;;
      failed) log_err "$UNIT_NAME 启动失败"; dump_diag; return 1 ;;
      *) sleep 1 ;;
    esac
  done
  log_err "$UNIT_NAME 在 20s 内未进入 active（当前：${st:-unknown}）"
  dump_diag
  return 1
}

zk_probe_ruok(){
  local resp=""
  { exec 3<>/dev/tcp/127.0.0.1/"$CLIENT_PORT"; } 2>/dev/null || return 1
  printf 'ruok\n' >&3 2>/dev/null || true
  IFS= read -r -t 5 resp <&3 2>/dev/null || resp=""
  exec 3<&- 2>/dev/null || true
  exec 3>&- 2>/dev/null || true
  [ "$resp" = "imok" ]
}

zk_probe_state(){
  # 返回 leader / follower / looking / 空
  local resp=""
  { exec 3<>/dev/tcp/127.0.0.1/"$CLIENT_PORT"; } 2>/dev/null || return 1
  printf 'mntr\n' >&3 2>/dev/null || true
  resp="$(timeout 3 cat <&3 2>/dev/null || true)"
  exec 3<&- 2>/dev/null || true; exec 3>&- 2>/dev/null || true
  echo "$resp" | awk -F'\t' '/zk_server_state/{print $2; exit}'
}

# 通过 SSH 在远端节点上，用 /dev/tcp 读 ZK 状态；不依赖 nc / telnet
# 输出：leader / follower / looking / standalone / ""（探测失败）
_zk_remote_state(){
  local node="$1" out mode
  out="$(timeout 15 ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" \
    "JAVA_HOME=$CH_BASE/$JDK_DIRNAME timeout 8 $ZK_HOME/bin/zkServer.sh status 2>&1" \
    2>/dev/null || true)"

  mode="$(printf '%s\n' "$out" | awk '/Mode:/{print $NF; exit}')"
  if [ -n "$mode" ]; then echo "$mode"; return 0; fi

  if printf '%s\n' "$out" | grep -qi 'not running\|Error contacting service'; then
    echo "DOWN"
  else
    echo "UNKNOWN"
  fi
}

# 顺便提供一个更直观的：直接问 zkServer.sh status
_zk_remote_status(){
  local node="$1"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" \
    "$ZK_HOME/bin/zkServer.sh status 2>/dev/null | awk '/Mode:/{print \$NF}'" 2>/dev/null || true
}

# 远端打诊断包（集群失败时自动调用）
_cluster_diag_node(){
  local node="$1" myid="$2"
  log_err "----- $node (myid=$myid) 诊断 -----"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" "bash -s" <<REMOTE 2>&1 | sed 's/^/    /' >&2 || true
echo "== systemctl =="
systemctl is-active $UNIT_NAME 2>/dev/null
systemctl status $UNIT_NAME --no-pager -l 2>/dev/null | tail -15
echo "== 监听端口 =="
ss -tlnp 2>/dev/null | grep -E '$CLIENT_PORT|$ZK_PEER_PORT|$ZK_ELECT_PORT' || echo "(未监听)"
echo "== 防火墙 =="
firewall-cmd --list-all 2>/dev/null || iptables -L -n 2>/dev/null | head -20 || echo "(无)"
echo "== ZK 日志尾部 =="
for f in $ZK_LOG/*.log $ZK_LOG/*.out; do
  [ -f "\$f" ] && { echo "--> \$f"; tail -30 "\$f"; }
done
REMOTE
}

do_verify(){
  log_step "校验 ZooKeeper（myid=$ZK_MYID, port=$CLIENT_PORT）"

  # 1) 进程必须活着
  if ! systemctl is-active --quiet "$UNIT_NAME"; then
    log_err "$UNIT_NAME 未运行"
    dump_diag
    return 1
  fi

  # 2) 30s 内等 ruok=imok（进程在 LOOKING 也可能返回 imok；此步主要确认端口已监听）
  local i
  for i in $(seq 1 30); do
    if zk_probe_ruok; then
      local st; st="$(zk_probe_state 2>/dev/null || true)"
      log_info "ZooKeeper 正常：imok（state=${st:-unknown}）"
      return 0
    fi
    sleep 1
  done

  # 3) ruok 未回应但进程还在：多节点场景下通常是在等其它节点组成 quorum
  if systemctl is-active --quiet "$UNIT_NAME"; then
    if [ "${ZK_STRICT_VERIFY:-0}" = "1" ]; then
      log_err "严格校验模式下：ruok 未在 30s 内返回 imok"
      dump_diag
      return 1
    fi
    log_warn "进程运行中但 $CLIENT_PORT 未返回 ruok（多数情况是等待集群其它节点）"
    log_warn "多节点部署完成后请执行： ZK_NODES_LIST='...' $0 cluster verify"
    return 0
  fi

  log_err "ZooKeeper 进程未运行"
  dump_diag
  return 1
}

#============================ 回滚引擎 =======================================
revert_manifest(){
  local mf="$1" bkdir="$2"
  [ -f "$mf" ] || { log_warn "无清单可回滚: $mf"; return 0; }
  trap - ERR; set +e
  local k a b
  while IFS=$'\t' read -r k a b; do
    [ -n "$k" ] || continue
    case "$k" in
      UN) systemctl stop "$a" 2>/dev/null; systemctl disable "$a" 2>/dev/null; rm -f /etc/systemd/system/"$a" ;;
      L)  rm -f "$a" ;;
      T)  rm -rf "$a" ;;
      F)  rm -f "$a" ;;
      B)  [ -n "$b" ] && [ -e "$bkdir/$b" ] && { mkdir -p "$(dirname "$a")"; cp -a "$bkdir/$b" "$a"; } ;;
      X)  id -u "$a" >/dev/null 2>&1 && userdel "$a" 2>/dev/null ;;
      G)  getent group "$a" >/dev/null && groupdel "$a" 2>/dev/null ;;
      D)  rmdir "$a" 2>/dev/null || true ;;
    esac
  done < <(tac "$mf")
  systemctl daemon-reload 2>/dev/null
}

on_error(){
  local code="$1" line="$2"
  log_err "安装在第 $line 行失败（退出码 $code），开始自动回滚 ..."
  revert_manifest "$MAN_ADD" "$BK_DIR"
  log_err "已回滚。排查后可重新执行（幂等）；备份位于 $BK_DIR"
  exit "$code"
}

#============================ 单机动作 =======================================
do_install(){
  [ "$(id -u)" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }
  init_state; trap 'on_error $? $LINENO' ERR
  step_prereq
  step_jdk
  step_zk
  step_unit
  do_verify
  # 直接追加，保持操作顺序（不能 sort -u，否则回滚顺序错乱）
  cat "$MAN_ADD" >> "$MAN_PERSIST"
  rm -f "$MAN_ADD"
  echo; log_info "ZooKeeper 节点 myid=$ZK_MYID 部署完成"
}

do_rollback(){
  [ "$(id -u)" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }
  local bkdir; bkdir="$(readlink -f "$STATE_DIR/latest" 2>/dev/null || true)"
  [ -n "$bkdir" ] && [ -d "$bkdir" ] || { log_err "没有可用备份"; exit 1; }
  if [ -f "$MAN_ADD" ]; then revert_manifest "$MAN_ADD" "$bkdir"; rm -f "$MAN_ADD"
  else revert_manifest "$MAN_PERSIST" "$bkdir"; fi
  log_info "已回滚: $bkdir"
}

do_uninstall(){
  [ "$(id -u)" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }
  [ -f "$MAN_PERSIST" ] || { log_err "无安装清单，无法卸载"; exit 1; }
  local bkdir; bkdir="$(readlink -f "$STATE_DIR/latest" 2>/dev/null || echo "$STATE_DIR")"
  revert_manifest "$MAN_PERSIST" "$bkdir"
  rm -rf "$ZK_DATA" "$ZK_LOG" "$MAN_PERSIST"
  log_info "ZooKeeper 已卸载"
}

#============================ 集群编排 =======================================
_nodes_csv(){ local IFS=','; echo "${ZK_NODES[*]}"; }

_cluster_check_ssh(){
  local node
  for node in "${ZK_NODES[@]}"; do
    log_info "检查 SSH 到 $node ..."
    if ! ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" "true" 2>/dev/null; then
      log_err "无法 SSH 到 $node（用户 $SSH_USER，端口 $SSH_PORT），请先配置免密登录"
      return 1
    fi
  done
  log_info "所有节点 SSH 可达"
}

_cluster_push_script(){
  local node
  for node in "${ZK_NODES[@]}"; do
    scp "${SCP_OPTS[@]}" "$SELF_PATH" "$SSH_USER@$node:$REMOTE_SCRIPT" >/dev/null
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" "chmod +x $REMOTE_SCRIPT" >/dev/null
  done
}

_cluster_push_script(){
  local node
  for node in "${ZK_NODES[@]}"; do
    scp "${SCP_OPTS[@]}" "$SELF_PATH" "$SSH_USER@$node:$REMOTE_SCRIPT" >/dev/null
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" "chmod +x $REMOTE_SCRIPT" >/dev/null
  done
}

# ===== 新增：分发安装包 =====
_cluster_distribute_pkgs(){
  [ "${SKIP_PKG_DISTRIBUTE:-0}" = "1" ] && { log_warn "SKIP_PKG_DISTRIBUTE=1，跳过分发包"; return 0; }
  log_step "分发安装包到各节点（PKG_DIR=$PKG_DIR）"

  # 收集本地存在哪些包
  local pkgs=()
  [ -f "$PKG_DIR/$JDK_TGZ" ] && pkgs+=("$PKG_DIR/$JDK_TGZ")
  [ -f "$PKG_DIR/$ZK_TGZ" ]  && pkgs+=("$PKG_DIR/$ZK_TGZ")

  if [ "${#pkgs[@]}" -eq 0 ]; then
    log_warn "本地 $PKG_DIR 下未找到安装包："
    log_warn "    $JDK_TGZ"
    log_warn "    $ZK_TGZ"
    log_warn "跳过自动分发；请确保各节点已自备，或先放好包再重试"
    return 0
  fi

  local node pkg fname local_size remote_size
  local any_fail=0
  for node in "${ZK_NODES[@]}"; do
    # 确保远端目录存在
    if ! ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" "mkdir -p '$PKG_DIR'"; then
      log_err "无法在 $node 上创建 $PKG_DIR"
      any_fail=1
      continue
    fi
    for pkg in "${pkgs[@]}"; do
      fname="$(basename "$pkg")"
      local_size="$(stat -c %s "$pkg" 2>/dev/null || echo 0)"
      # 远端已有同名同大小文件则跳过（幂等，重跑很快）
      remote_size="$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" \
        "stat -c %s '$PKG_DIR/$fname' 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
      if [ "$local_size" = "$remote_size" ] && [ "$local_size" != "0" ]; then
        log_info "  $node: $fname 已存在（大小一致），跳过"
        continue
      fi
      log_info "  → 分发 $fname 到 $node ..."
      if ! scp "${SCP_OPTS[@]}" "$pkg" "$SSH_USER@$node:$PKG_DIR/$fname" >/dev/null; then
        log_err "  分发 $fname 到 $node 失败"
        any_fail=1
      fi
    done
  done

  [ "$any_fail" -eq 0 ] || return 1
  log_info "安装包分发完成"
}

do_cluster_install(){
  [ "$(id -u)" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }
  [ "${#ZK_NODES[@]}" -ge 1 ] || { log_err "ZK_NODES 为空"; exit 1; }
  log_step "集群安装：${ZK_NODES[*]}"
  _cluster_check_ssh
  _cluster_push_script
  _cluster_distribute_pkgs
  
  local csv; csv="$(_nodes_csv)"
  log_step "在所有节点上并行执行安装"
  local pids=() nodes_ran=() myid=1 node
  for node in "${ZK_NODES[@]}"; do
    nodes_ran+=("$node")
    log_info "→ 在 $node 上以 myid=$myid 启动安装"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" \
      "ZK_NODES_LIST='$csv' $REMOTE_SCRIPT $myid install" \
      > "/tmp/zk-install-$node.log" 2>&1 &
    pids+=($!)
    myid=$((myid+1))
  done

  local i=0 failed=0
  for node in "${nodes_ran[@]}"; do
    if wait "${pids[$i]}"; then
      log_info "✓ $node 安装成功（日志 /tmp/zk-install-$node.log）"
    else
      log_err "✗ $node 安装失败，日志 /tmp/zk-install-$node.log"
      tail -n 20 "/tmp/zk-install-$node.log" >&2 || true
      failed=$((failed+1))
    fi
    i=$((i+1))
  done

  if [ "$failed" -gt 0 ]; then
    log_err "$failed 个节点安装失败，请检查各节点日志"
    exit 1
  fi

  # 等集群稳定
  log_step "等待集群成形（最多 60s）"
  do_cluster_verify
}

do_cluster_verify(){
  local total="${#ZK_NODES[@]}"
  local need=$(( total / 2 + 1 ))
  local i node myid ok states

  for i in $(seq 1 30); do
    ok=0
    states=()
    for node in "${ZK_NODES[@]}"; do
      local st; st="$(_zk_remote_state "$node")"
      states+=("$st")
      case "$st" in leader|follower) ok=$((ok+1)) ;; esac
    done
    if [ "$ok" -ge "$need" ]; then
      log_info "集群校验通过：$ok/$total 节点已加入 quorum（需要 ≥$need）"
      myid=1
      for node in "${ZK_NODES[@]}"; do
        printf '    %-16s myid=%s state=%s\n' "$node" "$myid" "${states[$((myid-1))]:-N/A}"
        myid=$((myid+1))
      done
      return 0
    fi
    sleep 2
  done

  log_err "集群校验失败：60s 内只有 $ok/$total 节点加入 quorum（需要 ≥$need）"
  myid=1
  for node in "${ZK_NODES[@]}"; do
    log_err "    $node myid=$myid state=${states[$((myid-1))]:-N/A}"
    myid=$((myid+1))
  done

  # 关键：失败时打印每个节点的完整诊断，一眼看出是"没起来"还是"2888/3888 被墙"
  log_err "================ 节点诊断 ================"
  myid=1
  for node in "${ZK_NODES[@]}"; do
    _cluster_diag_node "$node" "$myid"
    myid=$((myid+1))
  done
  return 1
}

do_cluster_status(){
  local node myid=1 st
  for node in "${ZK_NODES[@]}"; do
    st="$(_zk_remote_state "$node")"
    [ -z "$st" ] && st="DOWN/unreachable"
    printf '  %-16s myid=%-3s state=%s\n' "$node" "$myid" "$st"
    myid=$((myid+1))
  done
}

do_cluster_uninstall(){
  [ "$(id -u)" -eq 0 ] || { log_err "请用 root 运行"; exit 1; }
  _cluster_check_ssh
  _cluster_push_script
  local csv; csv="$(_nodes_csv)"
  local node myid=1
  for node in "${ZK_NODES[@]}"; do
    log_info "→ 卸载 $node"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$node" \
      "ZK_NODES_LIST='$csv' $REMOTE_SCRIPT $myid uninstall" 2>&1 || \
      log_warn "$node 卸载返回非 0"
    myid=$((myid+1))
  done
  log_info "集群卸载完成"
}

#============================ 主入口 =========================================
main(){
  ZK_MYID="${ZK_MYID:-}"
  local action="install"
  if [ $# -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    ZK_MYID="$1"; shift; action="${1:-install}"; shift || true
  else
    action="${1:-install}"; shift || true
  fi

  # status/start/stop/restart/rollback/uninstall 不强制 myid
  case "$action" in
    install|verify)
      [ -n "$ZK_MYID" ] || { log_err "请提供 myid，例如: $0 1 install"; exit 1; } ;;
  esac

  case "$action" in
    install)          do_install ;;
    verify)           [ "$(id -u)" -eq 0 ] || exit 1; init_state; do_verify ;;
    status)           systemctl status "$UNIT_NAME" --no-pager ;;
    start)            systemctl start "$UNIT_NAME" ;;
    stop)             systemctl stop "$UNIT_NAME" ;;
    restart)          systemctl restart "$UNIT_NAME" ;;
    rollback)         do_rollback ;;
    uninstall)        do_uninstall ;;
    cluster)
      local sub="${1:-}"
      case "$sub" in
        install)    do_cluster_install ;;
        verify)     do_cluster_verify ;;
        status)     do_cluster_status ;;
        uninstall)  do_cluster_uninstall ;;
        *) echo "用法: $0 cluster {install|verify|status|uninstall}"; exit 1 ;;
      esac
      ;;
    *)
      cat <<EOF
用法:
  单机:  $0 <myid> {install|verify|status|start|stop|restart|rollback|uninstall}
  集群:  ZK_NODES_LIST='ip1,ip2,ip3' $0 cluster {install|verify|status|uninstall}
EOF
      exit 1 ;;
  esac
}
main "$@"
