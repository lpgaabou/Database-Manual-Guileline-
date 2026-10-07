#!/usr/bin/env bash
###############################################################################
# ClickHouse 一键安装部署脚本
#
# 适用环境 : CentOS 7 / RHEL 7（x86_64），需以 root 运行
# 安装方式 : 官网离线 tgz 包 + install/doinst.sh（版本 20.11.4.13，可改）
# 特性     :
#   1. 幂等  —— 可反复执行，已完成的步骤自动跳过/收敛，不会重复写坏配置
#   2. 回滚  —— 任意步骤失败（ERR/中断）自动按相反顺序撤销本次改动；
#               也可手动执行  ./clickhouse_install.sh rollback  回滚最近一次安装
#   3. 多形态 —— 默认单机；MULTI_INSTANCE=true 增加 9200 多实例；
#               SETUP_CLUSTER=true 生成分片+副本+ZK 的 metrika.xml 集群配置
#
# 用法 :
#   ./clickhouse_install.sh install            # 安装/收敛（默认动作）
#   ./clickhouse_install.sh verify             # 只做安装后校验
#   ./clickhouse_install.sh status|start|stop|restart
#   ./clickhouse_install.sh rollback           # 回滚最近一次安装
#   ./clickhouse_install.sh uninstall          # 卸载（默认保留数据，加 --purge 连数据一起删）
#
# 可用环境变量覆盖顶部默认值，例如:
#   MULTI_INSTANCE=true ./clickhouse_install.sh install
#   SETUP_CLUSTER=true LOCAL_SHARD=02 LOCAL_REPLICA=xxcluster3s2r02_02_01 ./clickhouse_install.sh install
###############################################################################
set -Eeuo pipefail

#============================ 用户配置区（按需修改） ==========================
CH_VERSION="${CH_VERSION:-20.11.4.13}"                 # 与 tgz 文件名版本一致
CH_BASE="${CH_BASE:-/clickhouse}"                      # 官网统一根目录
CH_USER="${CH_USER:-clickhouse}"
CH_GROUP="${CH_GROUP:-clickhouse}"
CH_GID="${CH_GID:-60001}"
CH_UID="${CH_UID:-61001}"
CH_OS_PASSWORD="${CH_OS_PASSWORD:-clickhouse}"         # clickhouse 操作系统用户口令

PKG_DIR="${PKG_DIR:-$CH_BASE/soft}"                    # 4 个 tgz 所在目录
APP_DIR="${APP_DIR:-$CH_BASE/app}"
DATA_DIR="${DATA_DIR:-$CH_BASE/data}"
LOG_DIR="${LOG_DIR:-$CH_BASE/log}"
ETC_BASE="${ETC_BASE:-$CH_BASE/etc}"
CONF_DIR="${CONF_DIR:-$ETC_BASE/clickhouse-server}"    # 最终配置目录

# 实例1端口
TCP_PORT="${TCP_PORT:-9000}"
HTTP_PORT="${HTTP_PORT:-8123}"
MYSQL_PORT="${MYSQL_PORT:-9004}"
INTER_PORT="${INTER_PORT:-9009}"
# 实例2端口（MULTI_INSTANCE=true 时）
S_TCP_PORT="${S_TCP_PORT:-9200}"
S_HTTP_PORT="${S_HTTP_PORT:-8224}"
S_MYSQL_PORT="${S_MYSQL_PORT:-9204}"
S_INTER_PORT="${S_INTER_PORT:-9209}"

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LISTEN_HOST="${LISTEN_HOST:-::}"                       # 监听所有 IPv4/IPv6
INSTALL_DBG="${INSTALL_DBG:-true}"                     # 是否安装 dbg 调试包
DO_OS_TUNING="${DO_OS_TUNING:-true}"                   # 是否做系统内核/资源调优
MULTI_INSTANCE="${MULTI_INSTANCE:-false}"              # 是否部署第二个实例
SETUP_CLUSTER="${SETUP_CLUSTER:-false}"                # 是否生成集群 metrika 配置

# 集群拓扑（SETUP_CLUSTER=true 时生效，对应官网 3.6 生产推荐架构）
CLUSTER_NAME="${CLUSTER_NAME:-xxcluster3s2r02}"
CLUSTER_LAYER="${CLUSTER_LAYER:-02}"
LOCAL_SHARD="${LOCAL_SHARD:-01}"
LOCAL_REPLICA="${LOCAL_REPLICA:-xxcluster3s2r02_01_01}"
# ZooKeeper 集群（主机:客户端端口）
ZK_HOSTS="${ZK_HOSTS:-xxx81:32181,xxx82:32181,xxx83:32181,xxx84:32181,xxx85:32181}"

# /etc/hosts 规划（幂等追加；不需要可把数组内容清空）
HOSTS_ENTRIES=(
  "192.168.1.81 xxx81" "192.168.1.82 xxx82" "192.168.1.83 xxx83"
  "192.168.1.84 xxx84" "192.168.1.85 xxx85" "192.168.1.86 xxx86")

# 安装器状态目录（备份、清单、哈希都在这里）
STATE_DIR="${STATE_DIR:-/var/lib/clickhouse-installer}"
UNIT_NAME="clickhouse-server.service"
S_UNIT_NAME="clickhouse-server9200.service"

#================================ 通用函数 ===================================
C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_RST=$'\e[0m'
log_info(){ echo "${C_GRN}[INFO]${C_RST} $*"; }
log_warn(){ echo "${C_YEL}[WARN]${C_RST} $*"; }
log_err (){ echo "${C_RED}[ERROR]${C_RST} $*" >&2; }
log_step(){ echo; echo "${C_BLU}========== $* ==========${C_RST}"; }

require_root(){
  [ "$(id -u)" -eq 0 ] || { log_err "请使用 root 运行本脚本"; exit 1; }
}

# 状态目录与本次安装的备份/清单
BK_DIR=""; MAN_ADD=""; MAN_PERSIST=""
init_state(){
  MAN_PERSIST="$STATE_DIR/manifest"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  BK_DIR="$STATE_DIR/backup/$stamp"
  MAN_ADD="$STATE_DIR/manifest.add"
  mkdir -p "$BK_DIR/files" "$STATE_DIR/backup"
  : > "$MAN_ADD"
  ln -sfn "backup/$stamp" "$STATE_DIR/latest" >/dev/null 2>&1 || true
  touch "$MAN_PERSIST"
}

# 备份“已存在”的文件/软链（只备份一次），记录 B
backup_file(){
  local p="$1" rel
  { [ -e "$p" ] || [ -L "$p" ]; } || return 0
  if grep -qP "^B\t\Q$p\E\t" "$MAN_ADD" 2>/dev/null; then return 0; fi
  rel="${p#/}"; rel="${rel//\//_}"
  cp -a "$p" "$BK_DIR/files/$rel"
  printf 'B\t%s\tfiles/%s\n' "$p" "$rel" >> "$MAN_ADD"
}

# 由 stdin 写入文件：已存在则先备份(B)，否则登记 F
write_file(){
  local p="$1"
  mkdir -p "$(dirname "$p")"
  if [ -e "$p" ] || [ -L "$p" ]; then backup_file "$p"; else printf 'F\t%s\n' "$p" >> "$MAN_ADD"; fi
  cat > "$p"
}

ensure_dir(){
  local p="$1"
  if [ ! -e "$p" ]; then
    mkdir -p "$p"
    printf 'D\t%s\n' "$p" >> "$MAN_ADD"
  else
    mkdir -p "$p"
  fi
}

# 登记可递归删除的“软件树”（解压出来的 app 版本目录）
reg_tree(){ printf 'T\t%s\n' "$1" >> "$MAN_ADD"; }

# 枚举 tgz 内将要落到 / 的文件：已存在则备份(B)，否则登记 F
prepare_payload(){
  local tgz="$1" rel dest
  [ -f "$tgz" ] || { log_err "找不到安装包: $tgz"; return 1; }
  while IFS= read -r rel; do
    rel="${rel#./}"
    [ -n "$rel" ] || continue
    case "$rel" in */install/*|*"/install") continue;; esac
    dest="/${rel}"
    if [ -e "$dest" ] || [ -L "$dest" ]; then backup_file "$dest"; else printf 'F\t%s\n' "$dest" >> "$MAN_ADD"; fi
  done < <(tar tzf "$tgz")
}

# 用户/组
ensure_identity(){
  if ! getent group "$CH_GROUP" >/dev/null; then
    groupadd -g "$CH_GID" "$CH_GROUP"; printf 'G\t%s\n' "$CH_GROUP" >> "$MAN_ADD"
  fi
  if ! id -u "$CH_USER" >/dev/null 2>&1; then
    useradd -u "$CH_UID" -g "$CH_GROUP" -m -s /bin/bash "$CH_USER"
    printf 'X\t%s\n' "$CH_USER" >> "$MAN_ADD"
  fi
  # 口令与属组收敛（幂等）
  echo "$CH_USER:$CH_OS_PASSWORD" | chpasswd
  usermod -g "$CH_GROUP" "$CH_USER" >/dev/null 2>&1 || true
}

# 在文件中维护一段标记块（先删旧块再写新块，幂等）
manage_block(){
  local file="$1" tag="$2" content="$3" begin end
  begin="# >>> $tag >>>"; end="# <<< $tag <<<"
  [ -f "$file" ] || { mkdir -p "$(dirname "$file")"; touch "$file"; printf 'F\t%s\n' "$file" >> "$MAN_ADD"; }
  backup_file "$file"
  sed -i "\\|$begin|,\\|$end|d" "$file"
  { echo "$begin"; printf '%s\n' "$content"; echo "$end"; } >> "$file"
}

#============================ 步骤 1：OS 环境准备 ===========================
step_hosts(){
  log_step "配置 /etc/hosts"
  [ -f /etc/hosts ] && backup_file /etc/hosts
  local line
  # HOSTS_FILE 指向外部清单时以外部清单为准（集群编排使用，便于规模化）
  if [ -n "${HOSTS_FILE:-}" ] && [ -f "$HOSTS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$line" ] || continue
      if ! grep -qF "$line" /etc/hosts; then echo "$line" >> /etc/hosts; log_info "追加 $line"; fi
    done < "$HOSTS_FILE"
  else
    for line in "${HOSTS_ENTRIES[@]}"; do
      [ -n "$line" ] || continue
      if ! grep -qF "$line" /etc/hosts; then echo "$line" >> /etc/hosts; log_info "追加 $line"; fi
    done
  fi
}

step_basedirs(){
  log_step "创建目录结构"
  ensure_dir "$CH_BASE"; ensure_dir "$PKG_DIR"; ensure_dir "$APP_DIR"
  ensure_dir "$DATA_DIR"; ensure_dir "$LOG_DIR"; ensure_dir "$ETC_BASE"
  chown -R "$CH_USER:$CH_GROUP" "$CH_BASE"
  chmod 775 "$CH_BASE" "$PKG_DIR" "$APP_DIR" "$DATA_DIR" "$LOG_DIR" "$ETC_BASE"
}

step_os_tuning(){
  log_step "系统资源与内核调优"
  if command -v yum >/dev/null; then
    yum install -y lvm2 >/dev/null 2>&1 || log_warn "lvm2 安装失败，跳过（不影响后续）"
  fi

  # /etc/security/limits.conf
  manage_block /etc/security/limits.conf "clickhouse installer limits" "\
root soft nofile 1048576
root hard nofile 1048576
$CH_USER soft nproc 1048576
$CH_USER hard nproc 1048576
$CH_USER soft nofile 1048576
$CH_USER hard nofile 1048576
$CH_USER soft stack 10240
$CH_USER hard stack 32768
$CH_USER hard memlock unlimited
$CH_USER soft memlock unlimited"

  # /etc/sysctl.conf
  manage_block /etc/sysctl.conf "clickhouse installer sysctl" "\
fs.aio-max-nr = 1048576
fs.file-max = 6815744
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_mem = 786432 2097152 3145728
net.ipv4.tcp_rmem = 4096 4096 16777216
net.ipv4.tcp_wmem = 4096 4096 16777216
vm.swappiness = 1
vm.min_free_kbytes = 204800
vm.overcommit_memory = 0"
  sysctl -p >/dev/null 2>&1 || log_warn "部分 sysctl 参数未生效，请检查 /etc/sysctl.conf"

  # 时区
  if [ -f /usr/share/zoneinfo/"$TIMEZONE" ]; then
    [ -L /etc/localtime ] && backup_file /etc/localtime
    ln -sf /usr/share/zoneinfo/"$TIMEZONE" /etc/localtime
  fi

  # SELinux 关闭
  if [ -f /etc/selinux/config ]; then
    backup_file /etc/selinux/config
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
    setenforce 0 2>/dev/null || true
  fi

  # firewalld 关闭（记录原状态，回滚时恢复）
  if command -v systemctl >/dev/null && systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
    if systemctl is-enabled firewalld >/dev/null 2>&1; then echo "firewalld=enabled" >> "$MAN_ADD"; fi
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld >/dev/null 2>&1 || true
  fi

  # 透明大页 THP=never（运行时 + rc.local 开机生效）
  local thp
  for thp in enabled defrag; do
    [ -f /sys/kernel/mm/transparent_hugepage/$thp ] && echo never > /sys/kernel/mm/transparent_hugepage/$thp
  done
  manage_block /etc/rc.d/rc.local "clickhouse installer thp" "\
if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi"
  chmod +x /etc/rc.d/rc.local 2>/dev/null || true
}

#============================ 步骤 2：安装软件包 =============================
pkg_path(){ printf '%s/%s-%s.tgz' "$PKG_DIR" "$1" "$CH_VERSION"; }

extract_and_run(){
  # $1=包名前缀  $2=解压后目录名  $3=doinst 路径（相对） 其余为 doinst 环境变量
  local prefix="$1" dirname="$2" doinst_rel="$3"
  local tgz; tgz="$(pkg_path "$prefix")"
  [ -f "$tgz" ] || { log_err "找不到安装包 $tgz，请将 4 个 tgz 放到 $PKG_DIR"; return 1; }
  prepare_payload "$tgz"
  if [ ! -d "$APP_DIR/$dirname" ]; then
    tar xzf "$tgz" -C "$APP_DIR"
    reg_tree "$APP_DIR/$dirname"
  fi
  shift 3
  env "$@" "$APP_DIR/$dirname/$doinst_rel"
}

step_packages(){
  log_step "安装 ClickHouse 软件包（版本 $CH_VERSION）"
  local cur_ver=""
  if [ -x /usr/bin/clickhouse ]; then
    cur_ver="$(/usr/bin/clickhouse local -q 'SELECT version()' 2>/dev/null || true)"
  fi

  if [ "$cur_ver" = "$CH_VERSION" ]; then
    log_info "ClickHouse $CH_VERSION 已安装，跳过解包与 doinst"
  else
    [ -n "$cur_ver" ] && log_warn "检测到旧版本 $cur_ver，将覆盖安装为 $CH_VERSION（数据目录不受影响）"
    extract_and_run clickhouse-common-static "clickhouse-common-static-$CH_VERSION" \
      install/doinst.sh
    if [ "$INSTALL_DBG" = "true" ]; then
      extract_and_run clickhouse-common-static-dbg "clickhouse-common-static-dbg-$CH_VERSION" \
        install/doinst.sh
    fi
    # server：用环境变量指定目录，无需手工改 doinst.sh
    extract_and_run clickhouse-server "clickhouse-server-$CH_VERSION" \
      install/doinst.sh \
      CLICKHOUSE_USER="$CH_USER" CLICKHOUSE_GROUP="$CH_GROUP" \
      CLICKHOUSE_DATADIR="$DATA_DIR" CLICKHOUSE_LOGDIR="$LOG_DIR" \
      CLICKHOUSE_CONFDIR="$CONF_DIR" CLICKHOUSE_BINDIR=/usr/bin
    # client
    extract_and_run clickhouse-client "clickhouse-client-$CH_VERSION" install/doinst.sh
  fi

  log_step "迁移配置目录到 $ETC_BASE 并建立软链"
  relocate_etc clickhouse-server
  relocate_etc clickhouse-client
}

# /etc/<name> 迁移到 $ETC_BASE/<name>，软链指回
relocate_etc(){
  local name="$1"
  local etcp="/etc/$name"
  local basep="$ETC_BASE/$name"
  if [ -L "$etcp" ]; then
    ln -sfn "$basep" "$etcp"                       # 已软链：收敛目标
  elif [ -e "$etcp" ]; then
    if [ -e "$basep" ]; then                      # 目标已存在（一般不会）
      backup_file "$basep"; rm -rf "$basep"
    fi
    mv "$etcp" "$basep"
    printf 'M\t%s\t%s\n' "$basep" "$etcp" >> "$MAN_ADD"
    ln -s "$basep" "$etcp"; printf 'L\t%s\n' "$etcp" >> "$MAN_ADD"
  else
    ensure_dir "$basep"
    ln -s "$basep" "$etcp"; printf 'L\t%s\n' "$etcp" >> "$MAN_ADD"
  fi
}

#========================= 步骤 3：配置收敛（幂等） =========================
ensure_include_config(){
  local file="$1" glob="$2"
  grep -qF "<include_config>$glob</include_config>" "$file" && return 0
  backup_file "$file"
  sed -i "\|</yandex>|i\  <include_config>$glob</include_config>" "$file"
}

# include_from（集群 metrika）的收敛：$1=配置文件 $2=后缀(空/9200)
converge_include_from(){
  local file="$1"
  local suffix="${2:-}"
  local name="metrika${suffix}.xml"
  local line="  <include_from>$CONF_DIR/$name</include_from>"
  local marker="  <!--clickhouse-installer include_from-->"
  local tmp; tmp="$(mktemp)"
  while IFS= read -r l || [ -n "$l" ]; do
    case "$l" in
      *"<!--clickhouse-installer include_from-->"*) continue ;;
      *"<include_from>"*"metrika"*".xml</include_from>"*) continue ;;
    esac
    if [[ "$l" == *"</yandex>"* ]] && [ "$SETUP_CLUSTER" = "true" ]; then
      echo "$marker"; echo "$line"
    fi
    echo "$l"
  done < "$file" > "$tmp"
  if ! cmp -s "$tmp" "$file"; then backup_file "$file"; mv "$tmp" "$file"; else rm -f "$tmp"; fi
}

apply_config(){
  log_step "写入 ClickHouse 自定义配置（config.d / users.d 覆盖，幂等）"
  ensure_dir "$CONF_DIR/config.d"
  ensure_dir "$CONF_DIR/users.d"

  ensure_include_config "$CONF_DIR/config.xml" "$CONF_DIR/config.d/*.xml"
  ensure_include_config "$CONF_DIR/users.xml"  "$CONF_DIR/users.d/*.xml"

  # ---- 实例1：路径/监听/时区 ----
  write_file "$CONF_DIR/config.d/10-base.xml" <<EOF
<?xml version="1.0"?>
<yandex>
    <timezone>$TIMEZONE</timezone>
    <listen_host>$LISTEN_HOST</listen_host>
    <logger>
        <log>$LOG_DIR/clickhouse-server.log</log>
        <errorlog>$LOG_DIR/clickhouse-server.err.log</errorlog>
    </logger>
    <path>$DATA_DIR/</path>
    <tmp_path>$DATA_DIR/tmp/</tmp_path>
    <user_files_path>$DATA_DIR/user_files/</user_files_path>
    <format_schema_path>$DATA_DIR/format_schemas/</format_schema_path>
    <access_control_path>$DATA_DIR/access/</access_control_path>
</yandex>
EOF

  # ---- default 用户开启访问管理（SQL 建用户/授权） ----
  write_file "$CONF_DIR/users.d/10-default.xml" <<EOF
<?xml version="1.0"?>
<yandex>
    <users>
        <default>
            <access_management>1</access_management>
        </default>
    </users>
</yandex>
EOF
}

#============================ 步骤 4：多实例 9200 ===========================
setup_multi(){
  log_step "多实例：配置第二实例 tcp/$S_TCP_PORT"
  local cfg="$CONF_DIR/config$S_TCP_PORT.xml"
  ensure_dir "$CONF_DIR/config$S_TCP_PORT.d"
  ensure_dir "$CH_BASE/data$S_TCP_PORT"
  ensure_dir "$CH_BASE/log$S_TCP_PORT"

  # 以 config.xml 为模板，把 include 目录改成实例专属
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then backup_file "$cfg"; else printf 'F\t%s\n' "$cfg" >> "$MAN_ADD"; fi
  cp -f "$CONF_DIR/config.xml" "$cfg"
  sed -i "s#$CONF_DIR/config.d/\*\.xml#$CONF_DIR/config$S_TCP_PORT.d/*.xml#" "$cfg"

  write_file "$CONF_DIR/config$S_TCP_PORT.d/10-base.xml" <<EOF
<?xml version="1.0"?>
<yandex>
    <timezone>$TIMEZONE</timezone>
    <listen_host>$LISTEN_HOST</listen_host>
    <logger>
        <log>$CH_BASE/log$S_TCP_PORT/clickhouse-server.log</log>
        <errorlog>$CH_BASE/log$S_TCP_PORT/clickhouse-server.err.log</errorlog>
    </logger>
    <http_port>$S_HTTP_PORT</http_port>
    <tcp_port>$S_TCP_PORT</tcp_port>
    <mysql_port>$S_MYSQL_PORT</mysql_port>
    <interserver_http_port>$S_INTER_PORT</interserver_http_port>
    <path>$CH_BASE/data$S_TCP_PORT/</path>
    <tmp_path>$CH_BASE/data$S_TCP_PORT/tmp/</tmp_path>
    <user_files_path>$CH_BASE/data$S_TCP_PORT/user_files/</user_files_path>
    <format_schema_path>$CH_BASE/data$S_TCP_PORT/format_schemas/</format_schema_path>
    <access_control_path>$CH_BASE/data$S_TCP_PORT/access/</access_control_path>
</yandex>
EOF
  chown -R "$CH_USER:$CH_GROUP" "$CH_BASE/data$S_TCP_PORT" "$CH_BASE/log$S_TCP_PORT"
}

#============================ 步骤 5：集群 metrika ==========================
# 生成 ZK <node> 与分片 <replica> XML 片段
zk_nodes_xml(){
  local i=0 h p
  IFS=',' read -ra arr <<< "$ZK_HOSTS"
  for hp in "${arr[@]}"; do
    h="${hp%:*}"; p="${hp##*:}"; i=$((i+1))
    printf '        <node index="%d">\n            <host>%s</host>\n            <port>%s</port>\n        </node>\n' "$i" "$h" "$p"
  done
}

# $1=后缀（空 / 9200）  $2=端口  $3=副本主机对（"h1 h2" 每行一个分片）
gen_metrika(){
  local suffix="$1" port="$2"; shift 2
  local pairs="$*"
  local file="$CONF_DIR/metrika${suffix}.xml"
  local shards="" pair h1 h2 i=0
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue; i=$((i+1))
    h1="${pair%% *}"; h2="${pair##* }"
    shards+="            <shard>
                <weight>1</weight>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>$h1</host>
                    <port>$port</port>
                </replica>
                <replica>
                    <host>$h2</host>
                    <port>$port</port>
                </replica>
            </shard>
"
  done <<< "$pairs"

  write_file "$file" <<EOF
<?xml version="1.0"?>
<yandex>
    <clickhouse_remote_servers>
        <$CLUSTER_NAME>
$shards        </$CLUSTER_NAME>
    </clickhouse_remote_servers>
    <zookeeper-servers>
$(zk_nodes_xml)    </zookeeper-servers>
    <macros>
        <layer>$CLUSTER_LAYER</layer>
        <shard>$LOCAL_SHARD</shard>
        <replica>$LOCAL_REPLICA</replica>
    </macros>
    <networks>
        <ip>::/0</ip>
    </networks>
    <clickhouse_compression>
        <case>
            <min_part_size>10000000000</min_part_size>
            <min_part_size_ratio>0.01</min_part_size_ratio>
            <method>lz4</method>
        </case>
    </clickhouse_compression>
</yandex>
EOF
}

step_cluster(){
  log_step "生成集群配置 metrika.xml（分片 x 副本 + ZooKeeper）"
  # 分片对：外部通过 SHARD_PAIRS 注入（分号分隔，每段“副本主机1 副本主机2”）；
  # 未注入时使用内置 3 分片规划
  local pairs=() p9200=()
  if [ -n "${SHARD_PAIRS:-}" ]; then
    IFS=';' read -ra pairs <<< "$SHARD_PAIRS"
  else
    pairs=("xxx81 xxx82" "xxx83 xxx84" "xxx85 xxx86")
  fi
  gen_metrika "" "$TCP_PORT" "${pairs[@]}"
  converge_include_from "$CONF_DIR/config.xml" ""
  if [ "$MULTI_INSTANCE" = "true" ]; then
    # 第二实例分片对：SHARD_PAIRS_9200 注入；缺省与实例1相同
    if [ -n "${SHARD_PAIRS_9200:-}" ]; then
      IFS=';' read -ra p9200 <<< "$SHARD_PAIRS_9200"
    else
      p9200=("${pairs[@]}")
    fi
    gen_metrika "$S_TCP_PORT" "$S_TCP_PORT" "${p9200[@]}"
    converge_include_from "$CONF_DIR/config$S_TCP_PORT.xml" "$S_TCP_PORT"
  fi
}

#============================ 步骤 6：systemd 服务 ==========================
write_unit(){
  local file="$1" desc="$2" cfg="$3" pidf="$4" rundir="$5"
  write_file "$file" <<EOF
[Unit]
Description=$desc
Requires=network-online.target
After=network-online.target

[Service]
Type=simple
User=$CH_USER
Group=$CH_GROUP
Restart=always
RestartSec=30
RuntimeDirectory=$rundir
ExecStart=/usr/bin/clickhouse-server --config=$cfg --pid-file=$pidf
LimitCORE=infinity
LimitNOFILE=500000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_IPC_LOCK CAP_SYS_NICE

[Install]
WantedBy=multi-user.target
EOF
}

conf_hash(){
  { find "$CONF_DIR" -type f -name '*.xml' -exec sha256sum {} + 2>/dev/null
    sha256sum /etc/systemd/system/"$UNIT_NAME" 2>/dev/null
    [ -f /etc/systemd/system/"$S_UNIT_NAME" ] && sha256sum /etc/systemd/system/"$S_UNIT_NAME";
  } | sha256sum | awk '{print $1}'
}

step_service(){
  log_step "配置 systemd 服务"
  write_unit /etc/systemd/system/"$UNIT_NAME" \
    "ClickHouse Server (analytic DBMS for big data)" \
    /etc/clickhouse-server/config.xml \
    /etc/clickhouse-server/clickhouse-server.pid clickhouse-server
  printf 'UN\t%s\n' "$UNIT_NAME" >> "$MAN_ADD"

  if [ "$MULTI_INSTANCE" = "true" ]; then
    write_unit /etc/systemd/system/"$S_UNIT_NAME" \
      "ClickHouse Server second instance (tcp $S_TCP_PORT)" \
    /etc/clickhouse-server/config"$S_TCP_PORT".xml \
    /etc/clickhouse-server/clickhouse"$S_TCP_PORT".pid clickhouse-server"$S_TCP_PORT"
    printf 'UN\t%s\n' "$S_UNIT_NAME" >> "$MAN_ADD"
  else
    # 收敛：曾经启用过多实例则关闭（数据保留）
    if systemctl list-unit-files "$S_UNIT_NAME" >/dev/null 2>&1 && systemctl is-enabled "$S_UNIT_NAME" >/dev/null 2>&1; then
      systemctl --now disable "$S_UNIT_NAME" || true
      rm -f /etc/systemd/system/"$S_UNIT_NAME"
      systemctl daemon-reload
    fi
  fi

  # 权限收敛
  chown -R "$CH_USER:$CH_GROUP" "$CH_BASE"
  chmod -R 755 "$APP_DIR"
  find "$CONF_DIR" -type d -exec chmod 755 {} \;

  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1

  # 仅当配置变化或未运行时才重启（减少不必要的停机）
  local newhash oldhash=""
  newhash="$(conf_hash)"
  [ -f "$STATE_DIR/conf.hash" ] && oldhash="$(cat "$STATE_DIR/conf.hash")"
  if [ "$newhash" != "$oldhash" ] || ! systemctl is-active --quiet "$UNIT_NAME"; then
    log_info "配置发生变化或服务未运行，重启 $UNIT_NAME"
    systemctl restart "$UNIT_NAME"
    [ "$MULTI_INSTANCE" = "true" ] && { systemctl enable "$S_UNIT_NAME" >/dev/null 2>&1; systemctl restart "$S_UNIT_NAME"; }
  else
    log_info "配置未变化，服务保持运行"
  fi
  echo "$newhash" > "$STATE_DIR/conf.hash"
}

#============================ 安装后校验 ====================================
wait_tcp(){
  local port="$1" i
  for i in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then exec 3<&- 2>/dev/null || true; return 0; fi
    sleep 1
  done
  return 1
}

do_verify(){
  log_step "安装后校验"
  wait_tcp "$TCP_PORT" || { log_err "端口 $TCP_PORT 未在 30s 内监听"; return 1; }
  local ver
  ver="$(clickhouse-client --host 127.0.0.1 --port "$TCP_PORT" --user default -q 'SELECT version()' 2>/dev/null)"
  [ "$ver" = "$CH_VERSION" ] || { log_err "版本校验失败: 期望 $CH_VERSION, 实际 $ver"; return 1; }
  log_info "实例1 正常：tcp/$TCP_PORT, version=$ver"
  systemctl is-active --quiet "$UNIT_NAME" || { log_err "$UNIT_NAME 未处于 active"; return 1; }

  if [ "$MULTI_INSTANCE" = "true" ]; then
    wait_tcp "$S_TCP_PORT" || { log_err "端口 $S_TCP_PORT 未监听"; return 1; }
    clickhouse-client --host 127.0.0.1 --port "$S_TCP_PORT" --user default -q 'SELECT 1' >/dev/null
    log_info "实例2 正常：tcp/$S_TCP_PORT"
  fi
  log_info "校验全部通过"
}

#============================ 回滚引擎 ======================================
# 按清单“倒序”撤销。$1=清单文件 $2=备份目录
revert_manifest(){
  local mf="$1" bkdir="$2"
  [ -f "$mf" ] || { log_warn "无清单可回滚: $mf"; return 0; }
  trap - ERR; set +e

  local k a b
  while IFS=$'\t' read -r k a b; do
    [ -n "$k" ] || continue
    case "$k" in
      UN)
        systemctl stop "$a" 2>/dev/null
        systemctl disable "$a" 2>/dev/null
        rm -f /etc/systemd/system/"$a" /usr/lib/systemd/system/"$a"
        ;;
      L) rm -f "$a" ;;
      M) # 迁移还原：先保证软链已删，再把目录移回 /etc
        rm -f "$b"
        if [ -e "$a" ]; then mkdir -p "$(dirname "$b")"; mv "$a" "$b"; fi
        ;;
      T) rm -rf "$a" ;;
      F) rm -f "$a" ;;
      B) [ -n "$b" ] && [ -e "$bkdir/$b" ] && { mkdir -p "$(dirname "$a")"; cp -a "$bkdir/$b" "$a"; } ;;
      X) id -u "$a" >/dev/null 2>&1 && userdel "$a" 2>/dev/null ;;
      G) getent group "$a" >/dev/null && groupdel "$a" 2>/dev/null ;;
      D) rmdir "$a" 2>/dev/null || true ;;
    esac
  done < <(tac "$mf")

  # 特殊：firewalld 原状态行（k 字段不是标准 tab 结构，单独处理）
  if grep -q '^firewalld=enabled$' "$mf"; then
    systemctl enable firewalld >/dev/null 2>&1; systemctl start firewalld 2>/dev/null
  fi

  systemctl daemon-reload 2>/dev/null
  sysctl -p >/dev/null 2>&1 || true
}

# 失败时自动触发
on_error(){
  local code="$1" line="$2"
  log_err "安装在第 $line 行失败（退出码 $code），开始自动回滚本次改动 ..."
  revert_manifest "$MAN_ADD" "$BK_DIR"
  log_err "已回滚。可排查问题后重新执行本脚本（幂等）；备份位于 $BK_DIR"
  exit "$code"
}

#============================ 动作分发 ======================================
do_install(){
  require_root; init_state
  trap 'on_error $? $LINENO' ERR
  step_hosts
  step_basedirs
  [ "$DO_OS_TUNING" = "true" ] && step_os_tuning
  ensure_identity
  step_packages
  apply_config
  [ "$MULTI_INSTANCE" = "true" ] && setup_multi
  [ "$SETUP_CLUSTER" = "true" ] && step_cluster
  step_service
  do_verify

  # 成功：合并本次清单到持久清单（去重）
  sort -u "$MAN_PERSIST" "$MAN_ADD" -o "$MAN_PERSIST"
  rm -f "$MAN_ADD"
  echo; log_info "ClickHouse $CH_VERSION 部署完成"
  log_info "登录: clickhouse-client -h 127.0.0.1 --port $TCP_PORT --user default"
}

do_uninstall(){
  require_root
  local purge="${1:-false}"
  [ -f "$MAN_PERSIST" ] || { log_err "未找到安装清单 $MAN_PERSIST，无法卸载"; exit 1; }
  log_warn "即将卸载 ClickHouse（purge=$purge）"
  local bkdir; bkdir="$(readlink -f "$STATE_DIR/latest" 2>/dev/null || echo "")"
  # 用持久清单撤销（B 项从最近备份恢复）
  if [ -n "$bkdir" ]; then
    revert_manifest "$MAN_PERSIST" "$bkdir"
  else
    revert_manifest "$MAN_PERSIST" "$STATE_DIR"
  fi
  if [ "$purge" = "true" ]; then
    log_warn "purge 模式：删除数据/日志目录 $DATA_DIR $LOG_DIR"
    rm -rf "$DATA_DIR" "$LOG_DIR" "$CH_BASE/data$S_TCP_PORT" "$CH_BASE/log$S_TCP_PORT"
  else
    log_info "数据目录已保留: $DATA_DIR（如需连数据删除请加 --purge）"
  fi
  rm -f "$MAN_PERSIST" "$STATE_DIR/conf.hash"
  log_info "卸载完成"
}

do_rollback_manual(){
  require_root
  local bkdir; bkdir="$(readlink -f "$STATE_DIR/latest" 2>/dev/null || true)"
  [ -n "$bkdir" ] && [ -d "$bkdir" ] || { log_err "没有可用的备份（$STATE_DIR/latest）"; exit 1; }
  # 优先回滚最近一次未完成安装的 add 清单，否则回滚持久清单
  if [ -f "$MAN_ADD" ]; then revert_manifest "$MAN_ADD" "$bkdir"; rm -f "$MAN_ADD"
  else revert_manifest "$MAN_PERSIST" "$bkdir"; fi
  log_info "已按最近备份回滚: $bkdir"
}

simple_svc(){
  require_root
  case "$1" in
    status)  systemctl status "$UNIT_NAME" --no-pager ;;
    start)   systemctl start "$UNIT_NAME" ;;
    stop)    systemctl stop "$UNIT_NAME" ;;
    restart) systemctl restart "$UNIT_NAME" ;;
  esac
}

main(){
  local action="${1:-install}"; shift || true
  case "$action" in
    install)        do_install ;;
    verify)         require_root; init_state; do_verify ;;
    status|start|stop|restart) simple_svc "$action" ;;
    rollback)       do_rollback_manual ;;
    uninstall)      local purge="false"; [ "${1:-}" = "--purge" ] && purge="true"; do_uninstall "$purge" ;;
    *) echo "用法: $0 {install|verify|status|start|stop|restart|rollback|uninstall [--purge]}"; exit 1 ;;
  esac
}
main "$@"
