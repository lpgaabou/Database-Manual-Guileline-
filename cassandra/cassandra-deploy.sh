#!/bin/bash
#==============================================================================
# Cassandra 4.0 集群一键安装部署脚本（CentOS/RHEL 7）
# 依据《cassandra 终章》实施步骤整理：OS 调优 -> JDK -> Cassandra -> 集群配置
#                            -> systemd -> 启动验证
#
# 特性：
#   1. 幂等：所有步骤按“当前实际状态”判断，可任意重复执行，不重复追加/不破坏数据
#   2. 回滚：任何被修改的文件先备份到 STATE_DIR；部署中途失败自动回滚配置与服务
#            （默认保留数据目录与软件目录，--purge 连数据/软件/用户一并清除）
#   3. 用法：
#        ./cassandra-deploy.sh deploy            # 一键部署（默认动作，可省略）
#        ./cassandra-deploy.sh rollback          # 回滚最近一次部署（保留数据）
#        ./cassandra-deploy.sh rollback --purge  # 彻底回滚（含数据目录/软件/用户）
#        ./cassandra-deploy.sh status            # 查看本机各阶段实际状态
#        ./cassandra-deploy.sh selftest          # 临时目录自检幂等逻辑（不改系统）
#        ./cassandra-deploy.sh stages            # 列出全部阶段
#
#   在集群每一台机器上各执行一次；先执行种子节点(seed)，再执行普通节点。
#   可通过环境变量覆盖，例如：
#        LOCAL_IP=192.168.1.66 LOCAL_DC=dc1 LOCAL_RACK=rack1 ./cassandra-deploy.sh
#
# 注意：本脚本默认不做 LVM 建盘（pvcreate/vgcreate 属破坏性操作），请先自行把
#       数据盘挂载到 /data，或把下方 ENABLE_LVM 改为 true 并确认 DEV_DISK 无误。
#==============================================================================

set -o pipefail
# 显式不使用 set -e：每个阶段自行判定，失败统一走 die -> 回滚，避免半途中止不可控

#============================== 可配置区（开始） ==============================
# 集群拓扑：IP 主机名 数据中心 机架 角色(seed/node) [ntp-master]
CLUSTER_NAME='xxxCluster'
CLUSTER_NODES=(
  "192.168.1.61 xxxdata01 dc1 rack1 seed ntp-master"
  "192.168.1.62 xxxdata02 dc1 rack1 seed"
  "192.168.1.63 xxxdata03 dc1 rack1 seed"
  "192.168.1.64 xxxdata04 dc1 rack1 node"
  "192.168.1.65 xxxdata05 dc1 rack1 node"
  "192.168.1.66 xxxdata06 dc1 rack1 node"
)

DATA_DIR='/data'                       # 数据盘挂载点
SOFT_DIR='/data/soft'                 # 安装包存放目录
CASS_USER='cassandra'; CASS_GROUP='cassandra'
CASS_UID=61001; CASS_GID=60001
JDK_TARBALL='/data/soft/jdk-8u261-linux-x64.tar.gz'   # 不存在则尝试 yum 安装 openjdk 8
CASS_TARBALL='/data/soft/apache-cassandra-4.0.7-bin.tar.gz'  # 也可用 4.0.x 其它版本
JDK_HOME_DIR='/data/jdk1.8.0_261'     # tarball 解压后的目录名（yum 安装时自动探测）
CASS_HOME="${DATA_DIR}/cassandra"     # 安装目录（解压后直接落为该目录）
CASS_HEAP=''                          # 例如 '4G'，留空则 JVM 自动决定堆大小（测试环境推荐留空）

# 数据目录（与终章一致；课件另用过 /u01/cassandra，二选一，保持全集群一致即可）
CASS_DATA="${CASS_HOME}/data"
CASS_COMMITLOG="${CASS_HOME}/commitlog"
CASS_CACHES="${CASS_HOME}/saved_caches"

ENABLE_AUTH='true'                    # PasswordAuthenticator（默认账号 cassandra/cassandra）
ENABLE_AUTHORIZER='false'             # true 时同时开启 CassandraAuthorizer（权限管理）
START_AFTER_CONFIG='true'             # 配置完成后自动启动并验证
ON_ERROR_ROLLBACK='true'              # 部署失败自动回滚（配置/服务层，不动数据）

# LVM（默认关闭：避免误擦磁盘；需要脚本自动建盘时置 true 并确认 DEV_DISK）
ENABLE_LVM='false'
DEV_DISK='/dev/sdb'
LV_SIZE_M='100000'
VG_NAME='datavg'; LV_NAME='datalv'

# 时钟同步：ntp（与终章一致）；脚本只禁用 chronyd 不卸载，便于回滚
TIME_SYNC='ntp'
#============================== 可配置区（结束） ==============================

STATE_DIR='/var/lib/cassandra-deploy'
LOG_FILE='/var/log/cassandra-deploy.log'
YAML="${CASS_HOME}/conf/cassandra.yaml"
RACKDC="${CASS_HOME}/conf/cassandra-rackdc.properties"
JVM8_OPT="${CASS_HOME}/conf/jvm8-server.options"
JVM_OPT="${CASS_HOME}/conf/jvm-server.options"
UNIT_FILE='/etc/systemd/system/cassandra.service'
PROFILE="/home/${CASS_USER}/.bash_profile"

STAGES=(preflight hosts storage user boot locale limits sysctl timezone security vimrc thp ntp
        jdk cassandra cassandra_config profile systemd start_verify)

# 运行期变量（detect_local 后填充；LOCAL_IP/LOCAL_DC/LOCAL_RACK 允许环境变量覆盖）
LOCAL_IP="${LOCAL_IP:-}"; LOCAL_HOST=''; LOCAL_DC="${LOCAL_DC:-}"; LOCAL_RACK="${LOCAL_RACK:-}"
LOCAL_ROLE=''; NTP_MASTER=''
SEED_IPS=(); ALL_IPS=(); ALL_HOSTS=()
BACKUP_DIR=''; MANIFEST=''
NEED_RESTART=0

#============================== 基础工具函数 ==============================
c_g=$'\033[0;32m'; c_y=$'\033[0;33m'; c_r=$'\033[0;31m'; c_b=$'\033[0;36m'; c_0=$'\033[0m'
log(){  echo "$(date '+%F %T') [INFO]  $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
info(){ echo "${c_b}        -> $*${c_0}"; log "$*"; }
ok(){   echo "${c_g}[OK]${c_0} $*"; log "[OK] $*"; }
warn(){ echo "${c_y}[WARN]${c_0} $*" >&2; log "[WARN] $*"; }
err(){  echo "${c_r}[ERROR]${c_0} $*" >&2; log "[ERROR] $*"; }
step(){ echo; echo "${c_g}========== [阶段] $* ==========${c_0}"; log "==== STAGE $* ===="; }
die(){ local code=$?; err "$*"; echo "请查看日志：$LOG_FILE" >&2; on_failure "$code"; exit 1; }
need_root(){ [ "$(id -u)" -eq 0 ] || { echo "请用 root 执行" >&2; exit 1; }; }

# 首次改动文件前备份（幂等：同一次部署内每个文件只备份一次；记录“原本不存在”）
backup_file(){
  local f="$1" rel
  [ -n "$BACKUP_DIR" ] || { err "BACKUP_DIR 未初始化"; return 1; }
  grep -qF "FILE|${f}|" "$MANIFEST" 2>/dev/null && return 0
  if [ -e "$f" ]; then
    rel="${f#/}"; mkdir -p "${BACKUP_DIR}/root/$(dirname "$rel")"
    cp -a "$f" "${BACKUP_DIR}/root/${rel}"
    echo "FILE|${f}|${BACKUP_DIR}/root/${rel}" >> "$MANIFEST"
  else
    echo "ABSENT|${f}|" >> "$MANIFEST"
  fi
}
manifest_add(){ echo "$1|$2|$3" >> "$MANIFEST"; }

# 标记化托管块：ensure_block <file> <begin_tag> <end_tag> <content>
# 文件中存在该块则整体替换，不存在则追加；回滚时按标记精确删除
ensure_block(){
  local f="$1" begin="$2" end="$3" content="$4"
  backup_file "$f"; mkdir -p "$(dirname "$f")"
  local tmp; tmp="$(mktemp)"
  if grep -qF "$begin" "$f" 2>/dev/null; then
    awk -v b="$begin" -v e="$end" '
      $0==b {skip=1; print; next}
      $0==e {skip=0; print; next}
      skip!=1 {print}
    ' "$f" > "$tmp"
    # 在 begin 后写入新内容：重建块
    awk -v b="$begin" -v e="$end" -v c="$content" '
      $0==b {print; print c; inblk=1; next}
      $0==e {inblk=0; print; next}
      inblk!=1 {print}
    ' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
  else
    cp -a "$f" "$tmp" 2>/dev/null || :
    if [ -s "$tmp" ] && [ "$(tail -c1 "$tmp")" != "" ]; then printf '\n' >> "$tmp"; fi
    printf '%s\n' "$begin" "$content" "$end" >> "$tmp"
  fi
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# 删除托管块（回滚用）
remove_block(){
  local f="$1" begin="$2" end="$3"
  [ -e "$f" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip!=1 {print}
  ' "$f" > "$tmp" && cat "$tmp" > "$f"; rm -f "$tmp"
}
# 按标记前缀删除该文件中所有 cassandra-deploy 托管块（兜底用）
remove_blocks_prefix(){
  local f="$1"
  [ -e "$f" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk '
    index($0,"# >>> cassandra-deploy")==1 {skip=1; next}
    index($0,"# <<< cassandra-deploy")==1 {skip=0; next}
    skip!=1 {print}
  ' "$f" > "$tmp" && cat "$tmp" > "$f"; rm -f "$tmp"
}

#============================== 拓扑识别 ==============================
detect_local(){
  local rec ip host dc rack role _dc='' _rack=''
  for rec in "${CLUSTER_NODES[@]}"; do
    set -- $rec; ip="$1"; host="$2"; dc="$3"; rack="$4"; role="$5"
    ALL_IPS+=("$ip"); ALL_HOSTS+=("$host")
    [ "$role" = "seed" ] && SEED_IPS+=("$ip")
    echo "$rec" | grep -qw ntp-master && NTP_MASTER="$ip"
  done
  if [ -z "$LOCAL_IP" ]; then
    for ip in "${ALL_IPS[@]}"; do
      if ip addr show 2>/dev/null | grep -qw "$ip"; then LOCAL_IP="$ip"; break; fi
    done
  fi
  [ -n "$LOCAL_IP" ] || {
    if [ "$ALLOW_MISSING_LOCAL" = '1' ]; then
      warn '本机 IP 不在 CLUSTER_NODES 拓扑中（回滚/状态检查允许继续）'
      LOCAL_IP='unknown'; LOCAL_HOST='unknown'; LOCAL_DC="${LOCAL_DC:-dc1}"
      LOCAL_RACK="${LOCAL_RACK:-rack1}"; LOCAL_ROLE='node'
      export LOCAL_IP LOCAL_HOST LOCAL_DC LOCAL_RACK LOCAL_ROLE NTP_MASTER
      return 0
    fi
    die "无法在本机网卡上识别拓扑中的 IP，请用 LOCAL_IP=x.x.x.x 指定"
  }
  for rec in "${CLUSTER_NODES[@]}"; do
    set -- $rec
    if [ "$1" = "$LOCAL_IP" ]; then
      LOCAL_HOST="$2"; _dc="$3"; _rack="$4"; LOCAL_ROLE="$5"; break
    fi
  done
  if [ -z "$LOCAL_HOST" ]; then
    if [ "$ALLOW_MISSING_LOCAL" = '1' ]; then
      warn "拓扑中找不到 $LOCAL_IP（回滚/状态检查允许继续）"
      LOCAL_HOST='unknown'; _dc='dc1'; _rack='rack1'; LOCAL_ROLE='node'
    else
      die "拓扑中找不到 $LOCAL_IP，请检查 CLUSTER_NODES"
    fi
  fi
  # 环境变量 LOCAL_DC / LOCAL_RACK 可覆盖拓扑定义
  LOCAL_DC="${LOCAL_DC:-$_dc}"
  LOCAL_RACK="${LOCAL_RACK:-$_rack}"
  export LOCAL_IP LOCAL_HOST LOCAL_DC LOCAL_RACK LOCAL_ROLE NTP_MASTER
}

#============================== cassandra.yaml 幂等修改 ==============================
# 标量键：已存在且值相同->跳过；已存在但不同->替换；仅注释存在->取消注释并赋值；否则追加
set_yaml_raw(){ # file key value（value 原样写入）
  local f="$1" k="$2" v="$3"
  [ -f "$f" ] || { warn "找不到 $f，跳过 $k"; return 0; }
  if grep -Eq "^[[:space:]]*${k}[[:space:]]*:[[:space:]]*${v//\//\\/}[[:space:]]*$" "$f"; then return 0; fi
  backup_file "$f"
  if grep -Eq "^[[:space:]]*${k}[[:space:]]*:" "$f"; then
    sed -i -E "s|^([[:space:]]*${k}[[:space:]]*:).*|\1 ${v}|" "$f"
  elif grep -Eq "^#[[:space:]]*${k}[[:space:]]*:" "$f"; then
    sed -i -E "0,/^#[[:space:]]*${k}[[:space:]]*:.*/s|^#[[:space:]]*(${k}[[:space:]]*:).*|\1 ${v}|" "$f"
  else
    printf '%s: %s\n' "$k" "$v" >> "$f"
  fi
  NEED_RESTART=1
  info "yaml: $k = $v"
}
set_yaml_str(){ set_yaml_raw "$1" "$2" "'$3'"; }
set_yaml_num(){ set_yaml_raw "$1" "$2" "$3"; }

# seeds 行（- seeds: "..."）
set_yaml_seeds(){
  local f="$1" seeds="$2"
  grep -Eq "^[[:space:]]*-[[:space:]]*seeds:[[:space:]]*\"${seeds}\"[[:space:]]*$" "$f" && return 0
  backup_file "$f"
  if grep -Eq "^[[:space:]]*-[[:space:]]*seeds:" "$f"; then
    sed -i -E "s|^([[:space:]]*-[[:space:]]*seeds:).*|\1 \"${seeds}\"|" "$f"
  else
    printf -- '- seeds: "%s"\n' "$seeds" >> "$f"
  fi
  NEED_RESTART=1
  info "yaml: seeds = $seeds"
}

# data_file_directories 块整体替换为单目录
set_yaml_datadir(){
  local f="$1" dir="$2"
  if grep -Eq "^[[:space:]]*-[[:space:]]*${dir//\//\\/}[[:space:]]*$" "$f"; then return 0; fi
  backup_file "$f"
  local tmp; tmp="$(mktemp)"
  awk -v d="$dir" '
    /^data_file_directories:/ { print; print "    - " d; skip=1; next }
    skip==1 {
      if ($0 ~ /^[[:space:]]*#?[[:space:]]*-[[:space:]]*/) next
      if ($0 ~ /^[A-Za-z_]/) { skip=0; print; next }
      if ($0 ~ /^[[:space:]]*$/) { skip=0; print; next }
      next
    }
    { print }
  ' "$f" > "$tmp" && cat "$tmp" > "$f"; rm -f "$tmp"
  NEED_RESTART=1
  info "yaml: data_file_directories -> $dir"
}

# JVM options：确保某开关启用（去掉行首注释），不存在则追加到托管块
ensure_jvm_flag(){
  local f="$1" flag="$2"
  [ -f "$f" ] || { warn "找不到 $f，跳过 $flag"; return 0; }
  grep -Eq "^[[:space:]]*${flag//+/\\+}[[:space:]]*$" "$f" && return 0
  backup_file "$f"
  if grep -Eq "^#[[:space:]]*${flag//+/\\+}[[:space:]]*$" "$f"; then
    sed -i -E "0,/^#[[:space:]]*(${flag//+/\\+})[[:space:]]*$/s|^#[[:space:]]*(${flag//+/\\+})[[:space:]]*$|\1|" "$f"
  else
    ensure_block "$f" '# >>> cassandra-deploy managed >>>' '# <<< cassandra-deploy managed <<<' "$flag"
  fi
  NEED_RESTART=1
  info "jvm: 启用 $flag"
}
# 注释掉指定 JVM 开关（用于关闭 CMS），幂等
disable_jvm_flag(){
  local f="$1" flag="$2"
  [ -f "$f" ] || return 0
  grep -Eq "^[[:space:]]*${flag//+/\\+}[[:space:]]*$" "$f" || return 0
  backup_file "$f"
  sed -i -E "s|^[[:space:]]*(${flag//+/\\+})[[:space:]]*$|#\1|" "$f"
  NEED_RESTART=1
  info "jvm: 禁用 $flag"
}
# JVM 带值参数：存在则替换（含注释行），否则追加
set_jvm_value(){
  local f="$1" prefix="$2" value="$3"
  if grep -Eq "^[[:space:]]*${prefix//+/\\+}[[:space:]]*[^[:space:]].*$" "$f" && \
     grep -Eq "^[[:space:]]*${prefix//+/\\+}[[:space:]]*${value//./\\.}[[:space:]]*$" "$f"; then return 0; fi
  backup_file "$f"
  if grep -Eq "^#?[[:space:]]*${prefix//+/\\+}[[:space:]]*" "$f"; then
    sed -i -E "s|^#?[[:space:]]*(${prefix//+/\\+})[[:space:]]*.*|\1${value}|" "$f"
  else
    ensure_block "$f" '# >>> cassandra-deploy managed >>>' '# <<< cassandra-deploy managed <<<' "${prefix}${value}"
  fi
  NEED_RESTART=1
  info "jvm: ${prefix} -> ${value}"
}

#============================== 阶段实现 ==============================
stage_preflight(){
  step '01 环境预检'
  [ -f /etc/redhat-release ] && info "OS: $(cat /etc/redhat-release)" || warn '非 RedHat 系系统，继续但可能不兼容'
  command -v tar >/dev/null || die '缺少 tar'
  command -v python2.7 >/dev/null || command -v python >/dev/null || warn '未发现 python2.7（cqlsh 依赖），请稍后确认'
  if [ ! -f "$CASS_TARBALL" ]; then
    local found; found="$(ls "${SOFT_DIR}"/apache-cassandra-*-bin.tar.gz 2>/dev/null | head -1)"
    [ -n "$found" ] && CASS_TARBALL="$found"
  fi
  [ -f "$CASS_TARBALL" ] || die "缺少 Cassandra 安装包：$CASS_TARBALL（请放置后重跑，本步骤幂等）"
  ok "安装包检查通过：$(basename "$CASS_TARBALL")"
  [ "$ENABLE_LVM" = 'true' ] && { [ -b "$DEV_DISK" ] || die "ENABLE_LVM=true 但 $DEV_DISK 不是块设备"; }
  info "本机身份：$LOCAL_IP ($LOCAL_HOST) DC=$LOCAL_DC RACK=$LOCAL_RACK ROLE=$LOCAL_ROLE"
  info "种子节点：${SEED_IPS[*]}；NTP master：$NTP_MASTER"
}

stage_hosts(){
  step '02 /etc/hosts 集群主机名'
  local content='' rec
  for rec in "${CLUSTER_NODES[@]}"; do set -- $rec; content+="$1 $2"$'\n'; done
  ensure_block /etc/hosts '# >>> cassandra-deploy cluster hosts >>>' '# <<< cassandra-deploy cluster hosts <<<' "${content%$'\n'}"
  ok '/etc/hosts 已包含全部集群映射'
}

stage_locale(){
  step '06 语言环境（cassandra 用户）'
  local content='export LANG=en_US.UTF8'
  ensure_block "$PROFILE" '# >>> cassandra-deploy locale >>>' '# <<< cassandra-deploy locale <<<' "$content"
  chown "${CASS_USER}:${CASS_GROUP}" "$PROFILE" 2>/dev/null || true
  ok 'LANG=en_US.UTF8 已配置'
}

stage_storage(){
  step '03 文件系统与目录'
  if [ "$ENABLE_LVM" = 'true' ] && ! mount | grep -q " on ${DATA_DIR} "; then
    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
      info "在 $DEV_DISK 上创建 LVM（$VG_NAME/$LV_NAME）"
      pvcreate -y "$DEV_DISK" && vgcreate "$VG_NAME" "$DEV_DISK" && \
      lvcreate -n "$LV_NAME" -L "${LV_SIZE_M}M" "$VG_NAME" && mkfs.xfs -f "/dev/${VG_NAME}/${LV_NAME}"
      manifest_add LVM "$VG_NAME/$LV_NAME" "$DEV_DISK"
    fi
    local uuid; uuid="$(blkid -s UUID -o value "/dev/${VG_NAME}/${LV_NAME}")"
    mkdir -p "$DATA_DIR"
    grep -q "/dev/${VG_NAME}/${LV_NAME}" /etc/fstab || {
      backup_file /etc/fstab
      echo "/dev/${VG_NAME}/${LV_NAME} ${DATA_DIR} xfs defaults 0 0" >> /etc/fstab
    }
    mount "$DATA_DIR" 2>/dev/null || mount -U "$uuid" "$DATA_DIR"
  fi
  mount | grep -q " on ${DATA_DIR} " || warn "$DATA_DIR 未挂载（将直接在根分区下创建目录，生产请先挂载独立数据盘）"
  # 注意：不预建 $CASS_HOME 下的数据目录，避免与安装阶段的 mv 冲突（由 cassandra 阶段创建）
  mkdir -p "$SOFT_DIR" "${DATA_DIR}/u01/cassandra" 2>/dev/null
  mkdir -p /u01/cassandra/{commitlog,data,saved_caches} 2>/dev/null
  ok "软件目录与数据盘就绪：$SOFT_DIR（数据目录将在安装阶段创建于 $CASS_HOME）"
}

stage_user(){
  step '04 用户与组'
  if ! getent group "$CASS_GROUP" | grep -q ":${CASS_GID}:"; then
    if getent group "$CASS_GROUP" >/dev/null; then groupmod -g "$CASS_GID" "$CASS_GROUP"
    else groupadd -g "$CASS_GID" "$CASS_GROUP"; fi
    manifest_add GROUP "$CASS_GROUP" "$CASS_GID"
  fi
  if ! id -u "$CASS_USER" >/dev/null 2>&1; then
    useradd -u "$CASS_UID" -g "$CASS_GROUP" -m "$CASS_USER"
    echo "${CASS_USER}:${CASS_USER}" | chpasswd
    manifest_add USER "$CASS_USER" "$CASS_UID"
  fi
  mkdir -p "/home/${CASS_USER}"
  chown -R "${CASS_USER}:${CASS_GROUP}" "$DATA_DIR" /u01 2>/dev/null
  chmod 775 "$DATA_DIR"
  ok "用户 $CASS_USER($CASS_UID)/组 $CASS_GROUP($CASS_GID) 就绪"
}

stage_boot(){ step '05 启动级别'; systemctl set-default multi-user.target >/dev/null 2>&1; ok 'multi-user.target'; }

stage_limits(){
  step '07 资源限制 limits'
  local f='/etc/security/limits.d/cassandra.conf'
  local content='root soft nofile 1048576
root hard nofile 1048576
cassandra soft nproc 32768
cassandra hard nproc 32768
cassandra soft nofile 32768
cassandra hard nofile 32768
cassandra hard memlock unlimited
cassandra soft memlock unlimited'
  if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then ok 'limits 已是目标状态'; return 0; fi
  backup_file "$f"; printf '%s\n' "$content" > "$f"; chmod 644 "$f"
  ok '/etc/security/limits.d/cassandra.conf 已写入'
}

stage_sysctl(){
  step '08 内核参数 sysctl'
  local f='/etc/sysctl.d/99-cassandra.conf'
  local content='fs.aio-max-nr = 1048576
fs.file-max = 6815744
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 40960
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
vm.swappiness = 1
vm.min_free_kbytes = 204800
vm.max_map_count = 2048000
kernel.pid_max = 819200
vm.zone_reclaim_mode = 0'
  if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then ok 'sysctl 已是目标状态'; sysctl -q -p "$f"; return 0; fi
  backup_file "$f"; printf '%s\n' "$content" > "$f"; chmod 644 "$f"
  sysctl -q -p "$f" || warn '部分 sysctl 参数未生效，请检查'
  ok '/etc/sysctl.d/99-cassandra.conf 已生效'
}

stage_timezone(){
  step '09 时区'
  backup_file /etc/localtime
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
  ok '时区已设为 Asia/Shanghai'
}

stage_security(){
  step '10 SELinux / 防火墙'
  # 记录原始状态（仅本次首次）
  if ! grep -q '^ORIG_SELINUX|' "$MANIFEST"; then
    local mode; mode="$(getenforce 2>/dev/null || echo Disabled)"; manifest_add ORIG_SELINUX "$mode" ''
    if systemctl is-active firewalld >/dev/null 2>&1; then manifest_add ORIG_FIREWALL active ''
    else manifest_add ORIG_FIREWALL inactive ''; fi
  fi
  if [ -f /etc/selinux/config ]; then
    backup_file /etc/selinux/config
    sed -i -E 's/^\s*SELINUX=(enforcing|permissive|disabled)/SELINUX=disabled/I' /etc/selinux/config
    grep -q '^SELINUX=' /etc/selinux/config || echo 'SELINUX=disabled' >> /etc/selinux/config
  fi
  command -v setenforce >/dev/null && setenforce 0 2>/dev/null || true
  if systemctl list-unit-files | grep -q firewalld; then
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld >/dev/null 2>&1 || true
  fi
  ok 'SELinux 已禁用、firewalld 已停止并禁用（回滚可恢复原状态）'
}

stage_vimrc(){
  step '11 vim paste 设置（防 yml 粘贴乱码）'
  local f="/home/${CASS_USER}/.vimrc"
  local content='map <F10>:set paste<CR>
map <F11>:set nopaste<CR>'
  backup_file "$f"; mkdir -p "/home/${CASS_USER}"
  printf '%s\n' "$content" > "$f"; chown "${CASS_USER}:${CASS_GROUP}" "$f"
  ok '.vimrc 已配置'
}

stage_thp(){
  step '12 关闭透明大页 THP'
  local f='/etc/rc.d/rc.local'
  local content='if test -f /sys/kernel/mm/transparent_hugepage/enabled; then
echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if test -f /sys/kernel/mm/transparent_hugepage/defrag; then
echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi
echo 0 > /proc/sys/vm/zone_reclaim_mode'
  ensure_block "$f" '# >>> cassandra-deploy thp >>>' '# <<< cassandra-deploy thp <<<' "$content"
  chmod +x "$f"
  systemctl enable rc-local >/dev/null 2>&1 || true
  [ -f /sys/kernel/mm/transparent_hugepage/enabled ] && echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  [ -f /sys/kernel/mm/transparent_hugepage/defrag ] && echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  echo 0 > /proc/sys/vm/zone_reclaim_mode 2>/dev/null || true
  ok 'THP=never、zone_reclaim_mode=0（运行时+开机均生效）'
}

stage_ntp(){
  step '13 时钟同步（NTP）'
  [ "$TIME_SYNC" != 'ntp' ] && { info "TIME_SYNC=$TIME_SYNC，跳过"; return 0; }
  if ! rpm -q ntp >/dev/null 2>&1; then
    info '安装 ntp（请确保 yum 源可用；离线环境请先配置本地源）'
    yum install -y ntp >/dev/null 2>&1 || die 'ntp 安装失败'
    manifest_add PKG ntp installed
  fi
  # 记录 chronyd 原始状态并停用（不卸载，便于回滚）
  if systemctl list-unit-files | grep -q chronyd; then
    if ! grep -q '^ORIG_CHRONY|' "$MANIFEST"; then
      if systemctl is-enabled chronyd >/dev/null 2>&1; then manifest_add ORIG_CHRONY enabled ''
      else manifest_add ORIG_CHRONY disabled ''; fi
    fi
    systemctl disable --now chronyd >/dev/null 2>&1 || true
  fi
  backup_file /etc/ntp.conf
  if [ "$LOCAL_IP" = "$NTP_MASTER" ]; then
    grep -q '^server 127.127.1.0' /etc/ntp.conf || echo 'server 127.127.1.0 iburst' >> /etc/ntp.conf
    info '本机为 NTP master，使用本地时钟源'
  else
    grep -q "^server ${NTP_MASTER}" /etc/ntp.conf || echo "server ${NTP_MASTER} iburst" >> /etc/ntp.conf
    grep -q "^restrict ${NTP_MASTER}" /etc/ntp.conf || \
      echo "restrict ${NTP_MASTER} nomodify notrap noquery" >> /etc/ntp.conf
    info "本机为 NTP 客户端，与 ${NTP_MASTER} 同步"
    systemctl stop ntpd 2>/dev/null || true
    ntpdate -u "$NTP_MASTER" >/dev/null 2>&1 || warn "ntpdate $NTP_MASTER 暂未成功（master 未就绪？ntpd 启动后会自动同步）"
    hwclock -w 2>/dev/null || true
  fi
  systemctl enable ntpd >/dev/null 2>&1
  systemctl restart ntpd
  ok 'ntpd 已启用'
}

#============================== 软件安装 ==============================
stage_jdk(){
  step '14 JDK 8 安装'
  if "$JDK_HOME_DIR/bin/java" -version 2>/dev/null | grep -q '1.8'; then
    ok "JDK 已存在：$JDK_HOME_DIR"; return 0
  fi
  if [ -f "$JDK_TARBALL" ]; then
    info "解压 $JDK_TARBALL -> $DATA_DIR"
    tar zxf "$JDK_TARBALL" -C "$DATA_DIR"
    local d; d="$(tar tzf "$JDK_TARBALL" | head -1 | cut -d/ -f1)"
    [ -d "${DATA_DIR}/${d}" ] && JDK_HOME_DIR="${DATA_DIR}/${d}"
    manifest_add JDKDIR "$JDK_HOME_DIR" tarball
  else
    warn "未找到 $JDK_TARBALL，尝试 yum 安装 java-1.8.0-openjdk"
    yum install -y java-1.8.0-openjdk >/dev/null 2>&1 || die 'JDK 安装失败（请准备 JDK tarball 或 yum 源）'
    local jh; jh="$(readlink -f /usr/bin/java 2>/dev/null | sed 's#/bin/java##')"
    JDK_HOME_DIR="$jh"; manifest_add JDKPKG java-1.8.0-openjdk yum
  fi
  "$JDK_HOME_DIR/bin/java" -version 2>/dev/null | head -1 || die 'JDK 验证失败'
  ok "JDK 就绪：$JDK_HOME_DIR"
}

stage_cassandra(){
  step '15 Cassandra 安装'
  if [ -x "${CASS_HOME}/bin/cassandra" ]; then
    ok "Cassandra 已存在：$CASS_HOME"; chown -R "${CASS_USER}:${CASS_GROUP}" "$CASS_HOME"; return 0
  fi
  [ -f "$CASS_TARBALL" ] || die "缺少安装包 $CASS_TARBALL"
  info "解压 $CASS_TARBALL"
  local vdir; vdir="$(tar tzf "$CASS_TARBALL" | head -1 | cut -d/ -f1)"
  rm -rf "${DATA_DIR:?}/$vdir"; tar zxf "$CASS_TARBALL" -C "$DATA_DIR"
  # 与终章一致：解压目录直接落为 /data/cassandra（数据目录在其内，升级前请先备份）
  rm -rf "${CASS_HOME:?}"; mv "${DATA_DIR}/$vdir" "$CASS_HOME"
  manifest_add CASSDIR "$CASS_HOME" "${DATA_DIR}/$vdir"
  mkdir -p "$CASS_DATA" "$CASS_COMMITLOG" "$CASS_CACHES" "${CASS_HOME}/logs"
  chown -R "${CASS_USER}:${CASS_GROUP}" "$CASS_HOME" "$CASS_DATA" "$CASS_COMMITLOG" "$CASS_CACHES"
  "${CASS_HOME}/bin/cqlsh" --version 2>/dev/null | head -1 || true
  ok "Cassandra 就绪：$CASS_HOME"
}

stage_cassandra_config(){
  step '16 cassandra.yaml / JVM / rackdc 配置'
  [ -f "$YAML" ] || die "找不到 $YAML"
  local seeds; seeds="$(IFS=,; echo "${SEED_IPS[*]}")"

  # ---- 基本配置（终章 2.4）----
  set_yaml_str "$YAML" cluster_name "$CLUSTER_NAME"
  set_yaml_num "$YAML" num_tokens 16
  set_yaml_seeds "$YAML" "$seeds"
  set_yaml_str "$YAML" listen_address "$LOCAL_IP"
  set_yaml_str "$YAML" rpc_address "$LOCAL_IP"
  set_yaml_datadir "$YAML" "$CASS_DATA"
  set_yaml_raw "$YAML" commitlog_directory "'$CASS_COMMITLOG'"
  set_yaml_raw "$YAML" saved_caches_directory "'$CASS_CACHES'"
  set_yaml_raw "$YAML" request_timeout_in_ms 30000
  set_yaml_raw "$YAML" endpoint_snitch GossipingPropertyFileSnitch
  set_yaml_num "$YAML" dynamic_snitch_update_interval_in_ms 100
  set_yaml_num "$YAML" dynamic_snitch_reset_interval_in_ms 10000
  set_yaml_num "$YAML" dynamic_snitch_badness_threshold 0.1
  if [ "$ENABLE_AUTH" = 'true' ]; then set_yaml_raw "$YAML" authenticator PasswordAuthenticator
  else set_yaml_raw "$YAML" authenticator AllowAllAuthenticator; fi
  if [ "$ENABLE_AUTHORIZER" = 'true' ]; then set_yaml_raw "$YAML" authorizer CassandraAuthorizer
  else set_yaml_raw "$YAML" authorizer AllowAllAuthorizer; fi

  # ---- 线程分配优化 ----
  set_yaml_num "$YAML" native_transport_max_threads 4092
  set_yaml_num "$YAML" memtable_flush_writers 2
  set_yaml_num "$YAML" concurrent_compactors 8
  set_yaml_num "$YAML" concurrent_reads 512
  set_yaml_num "$YAML" concurrent_writes 256
  set_yaml_num "$YAML" concurrent_counter_writes 512

  # ---- 内存 / 缓存优化 ----
  set_yaml_raw "$YAML" cdc_enabled false
  set_yaml_num "$YAML" key_cache_size_in_mb 0
  set_yaml_num "$YAML" row_cache_size_in_mb 32768
  set_yaml_num "$YAML" row_cache_save_period 1000
  set_yaml_num "$YAML" row_cache_keys_to_save 0
  set_yaml_num "$YAML" file_cache_size_in_mb 8192
  set_yaml_raw "$YAML" buffer_pool_use_heap_if_exhausted false
  set_yaml_num "$YAML" hinted_handoff_throttle_in_kb 128000
  set_yaml_num "$YAML" hints_flush_period_in_ms 1000
  set_yaml_num "$YAML" max_hints_file_size_in_mb 128
  set_yaml_num "$YAML" index_summary_capacity_in_mb 1024

  # ---- 数据结构 / CommitLog / Compaction ----
  set_yaml_num "$YAML" batch_size_warn_threshold_in_kb 5000
  set_yaml_num "$YAML" batch_size_fail_threshold_in_kb 100000
  set_yaml_raw "$YAML" commitlog_sync periodic
  set_yaml_num "$YAML" commitlog_sync_period_in_ms 1000
  set_yaml_num "$YAML" commitlog_segment_size_in_mb 32
  set_yaml_num "$YAML" commitlog_total_space_in_mb 4096
  set_yaml_num "$YAML" compaction_throughput_mb_per_sec 64

  # ---- JVM：关闭 CMS、启用 G1（终章 jvm8-server.options）----
  if [ -f "$JVM8_OPT" ]; then
    # 先注释所有启用中的 CMS/ParNew 参数（G1 与 CMS 不能同时启用）
    if grep -Eq '^[[:space:]]*-XX:.*(CMS|ParNew|ConcMarkSweep)' "$JVM8_OPT"; then
      backup_file "$JVM8_OPT"
      sed -i -E 's|^([[:space:]]*)(-XX:.*(CMS|ParNew|ConcMarkSweep).*)$|\1#\2|' "$JVM8_OPT"
      NEED_RESTART=1; info 'jvm: 已注释 CMS/ParNew 参数'
    fi
    ensure_jvm_flag "$JVM8_OPT" '-XX:+UseG1GC'
    ensure_jvm_flag "$JVM8_OPT" '-XX:+ParallelRefProcEnabled'
    set_jvm_value "$JVM8_OPT" '-XX:G1RSetUpdatingPauseTimePercent=' '5'
    set_jvm_value "$JVM8_OPT" '-XX:MaxGCPauseMillis=' '500'
    set_jvm_value "$JVM8_OPT" '-XX:InitiatingHeapOccupancyPercent=' '70'
    set_jvm_value "$JVM8_OPT" '-XX:ParallelGCThreads=' '4'
    set_jvm_value "$JVM8_OPT" '-XX:ConcGCThreads=' '4'
    set_jvm_value "$JVM8_OPT" '-Xloggc:' "${CASS_HOME}/logs/gc.log"
  fi
  # 堆大小（可选）
  if [ -n "$CASS_HEAP" ] && [ -f "$JVM_OPT" ]; then
    set_jvm_value "$JVM_OPT" '-Xms' "$CASS_HEAP"
    set_jvm_value "$JVM_OPT" '-Xmx' "$CASS_HEAP"
  fi
  mkdir -p "${CASS_HOME}/logs"

  # ---- 机架感知（内容相同则不重写）----
  local rack_content="dc=${LOCAL_DC}
rack=${LOCAL_RACK}"
  if [ ! -f "$RACKDC" ] || [ "$(cat "$RACKDC")" != "$rack_content" ]; then
    backup_file "$RACKDC"; printf '%s\n' "$rack_content" > "$RACKDC"; NEED_RESTART=1
  fi
  chown "${CASS_USER}:${CASS_GROUP}" "$RACKDC"

  chown -R "${CASS_USER}:${CASS_GROUP}" "$CASS_HOME"
  ok 'cassandra.yaml / JVM(G1) / rackdc 已按终章参数配置（重复执行只补缺、不重复追加）'
}

stage_profile(){
  step '17 cassandra 用户环境变量'
  local content="export JAVA_HOME=${JDK_HOME_DIR}
export PATH=${JDK_HOME_DIR}/bin:${CASS_HOME}/bin:\$PATH
export LANG=en_US.UTF8"
  ensure_block "$PROFILE" '# >>> cassandra-deploy env >>>' '# <<< cassandra-deploy env <<<' "$content"
  chown "${CASS_USER}:${CASS_GROUP}" "$PROFILE"
  ok 'JAVA_HOME / PATH / LANG 已写入 bash_profile'
}

stage_systemd(){
  step '18 systemd 开机自启动'
  local unit="[Unit]
Description=Cassandra Server Service
After=network.service

[Service]
Type=simple
Environment=JAVA_HOME=${JDK_HOME_DIR}
PIDFile=${CASS_HOME}/cassandra.pid
User=${CASS_USER}
Group=${CASS_GROUP}
ExecStart=${CASS_HOME}/bin/cassandra -f -p ${CASS_HOME}/cassandra.pid
StandardOutput=journal
StandardError=journal
LimitNOFILE=100000
LimitMEMLOCK=infinity
LimitNPROC=32768
LimitAS=infinity
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target"
  if [ -f "$UNIT_FILE" ] && [ "$(cat "$UNIT_FILE")" = "$unit" ]; then ok 'systemd unit 已是目标状态'
  else backup_file "$UNIT_FILE"; printf '%s\n' "$unit" > "$UNIT_FILE"; fi
  systemctl daemon-reload
  systemctl enable cassandra >/dev/null 2>&1
  ok 'cassandra.service 已安装并 enable'
}

stage_start_verify(){
  step '19 启动与验证'
  [ "$START_AFTER_CONFIG" != 'true' ] && { info 'START_AFTER_CONFIG=false，跳过启动'; return 0; }
  # 非种子节点先等种子节点 7000 可达
  if [ "$LOCAL_ROLE" != 'seed' ]; then
    info '非种子节点，等待至少一个种子节点 7000 端口可达…'
    local s ok_port i
    for i in $(seq 1 60); do
      ok_port=''
      for s in "${SEED_IPS[@]}"; do
        (exec 3<>"/dev/tcp/${s}/7000") 2>/dev/null && { ok_port=1; exec 3<&- 3>&-; break; }
      done
      [ -n "$ok_port" ] && break
      sleep 5
    done
    [ -n "$ok_port" ] && ok '种子节点可达' || warn '种子节点暂不可达，仍尝试启动（请确认已先启动种子节点）'
  fi
  if systemctl is-active cassandra >/dev/null 2>&1; then
    if [ "$NEED_RESTART" = '1' ]; then
      info '检测到配置变更，重启 cassandra 使配置生效'
      systemctl restart cassandra
    else
      ok 'cassandra 已在运行，配置无变化，跳过重启'
    fi
  else
    systemctl start cassandra || { journalctl -u cassandra --no-pager -n 30 >&2; die 'cassandra 服务启动失败'; }
  fi
  info '等待 Cassandra 就绪（最多 180 秒）…'
  local ready='' i
  for i in $(seq 1 36); do
    if su - "$CASS_USER" -c "JAVA_HOME=${JDK_HOME_DIR} ${CASS_HOME}/bin/nodetool status" >/dev/null 2>&1; then ready=1; break; fi
    sleep 5
  done
  [ -n "$ready" ] || { journalctl -u cassandra --no-pager -n 30 >&2; die 'Cassandra 启动验证失败（可用 cassandra -f 前台调试）'; }
  echo
  su - "$CASS_USER" -c "JAVA_HOME=${JDK_HOME_DIR} ${CASS_HOME}/bin/nodetool status" | tee -a "$LOG_FILE"
  echo
  if [ "$ENABLE_AUTH" = 'true' ]; then
    su - "$CASS_USER" -c "${CASS_HOME}/bin/cqlsh ${LOCAL_IP} 9042 -u cassandra -p cassandra -e 'describe cluster;'" 2>/dev/null | tee -a "$LOG_FILE" \
      || warn 'cqlsh 验证未通过（集群仍在握手？稍后手动验证）'
  else
    su - "$CASS_USER" -c "${CASS_HOME}/bin/cqlsh ${LOCAL_IP} 9042 -e 'describe cluster;'" 2>/dev/null | tee -a "$LOG_FILE" \
      || warn 'cqlsh 验证未通过（集群仍在握手？稍后手动验证）'
  fi
  ok "本机 Cassandra 已启动：$LOCAL_IP ($LOCAL_DC/$LOCAL_RACK/$LOCAL_ROLE)"
}

#============================== 回滚 ==============================
latest_backup(){ ls -1dt "${STATE_DIR}"/backup-* 2>/dev/null | head -1; }

restore_original_states(){
  # SELinux
  local orig
  orig="$(grep '^ORIG_SELINUX|' "$MANIFEST" 2>/dev/null | tail -1 | cut -d'|' -f2)"
  if [ -n "$orig" ]; then
    case "$orig" in
      Enforcing) sed -i -E 's/^\s*SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config 2>/dev/null; setenforce 1 2>/dev/null || true;;
      Permissive) sed -i -E 's/^\s*SELINUX=.*/SELINUX=permissive/' /etc/selinux/config 2>/dev/null; setenforce 0 2>/dev/null || true;;
    esac
  fi
  # firewalld
  if grep -q '^ORIG_FIREWALL|active' "$MANIFEST" 2>/dev/null; then
    systemctl enable firewalld >/dev/null 2>&1; systemctl start firewalld 2>/dev/null || true
  fi
  # chronyd / ntpd
  if grep -q '^ORIG_CHRONY|enabled' "$MANIFEST" 2>/dev/null; then
    systemctl enable chronyd >/dev/null 2>&1; systemctl restart chronyd 2>/dev/null || true
    systemctl disable --now ntpd >/dev/null 2>&1 || true
  fi
  # 重新加载 sysctl（恢复后的值）
  sysctl --system >/dev/null 2>&1 || true
}

do_rollback(){
  local purge="$1" bk
  bk="$(latest_backup)"
  if [ -z "$bk" ] || [ ! -f "$bk/manifest" ]; then
    warn '没有找到部署备份清单，仅执行服务停用与 unit 清理'
    MANIFEST=/dev/null
  else
    BACKUP_DIR="$bk"; MANIFEST="$bk/manifest"
    if grep -q '^RESTORED|' "$MANIFEST" && [ "$purge" != 'purge' ]; then
      warn "该备份已回滚过：$bk（重复执行无害）"
    fi
    step "回滚（备份：$bk）"
    systemctl stop cassandra 2>/dev/null || true
    systemctl disable cassandra >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"; systemctl daemon-reload

    # 恢复被修改文件 / 删除新建文件
    local line type f src
    while IFS= read -r line; do
      type="$(echo "$line" | cut -d'|' -f1)"
      f="$(echo "$line" | cut -d'|' -f2)"
      src="$(echo "$line" | cut -d'|' -f3)"
      case "$type" in
        FILE) [ -f "$src" ] && { mkdir -p "$(dirname "$f")"; cp -a "$src" "$f"; info "恢复文件 $f"; };;
        ABSENT) [ -e "$f" ] && { rm -f "$f"; info "删除新建文件 $f"; };;
      esac
    done < "$MANIFEST"

    # 兜底：清理可能的托管块（备份缺失时仍可干净移除）
    for f in /etc/hosts "$PROFILE" /etc/rc.d/rc.local; do
      [ -e "$f" ] && remove_blocks_prefix "$f"
    done
    restore_original_states
    grep -q '^RESTORED|' "$MANIFEST" || echo 'RESTORED|yes|' >> "$MANIFEST"
    ok '配置文件、系统状态、服务已回滚（数据目录与软件目录保留）'
  fi

  if [ "$purge" = 'purge' ]; then
    step '彻底清除（--purge）'
    systemctl stop cassandra 2>/dev/null || true
    rm -f "$UNIT_FILE"; systemctl daemon-reload
    rm -rf "$CASS_HOME"
    rm -rf "${DATA_DIR}/u01" /u01
    grep -q '^JDKDIR|' "$MANIFEST" 2>/dev/null && rm -rf "$(grep '^JDKDIR|' "$MANIFEST" | tail -1 | cut -d'|' -f2)"
    if id "$CASS_USER" >/dev/null 2>&1; then userdel -r "$CASS_USER" 2>/dev/null || userdel "$CASS_USER"; fi
    getent group "$CASS_GROUP" >/dev/null && groupdel "$CASS_GROUP" 2>/dev/null
    warn 'LVM（datavg/datalv）与 /etc/fstab 条目未自动删除，如需回收数据盘请手工确认后执行：'
    warn '  umount /data && lvremove -f /dev/datavg/datalv && vgremove -f datavg && pvremove -y <盘>'
    ok '软件、数据目录、用户已清除'
  fi
}

on_failure(){
  local code="${1:-$?}"
  err "部署失败（退出码 $code）"
  if [ "$ON_ERROR_ROLLBACK" = 'true' ] && [ -n "$BACKUP_DIR" ]; then
    warn '触发失败自动回滚（保留数据；如需彻底清除执行 rollback --purge）'
    do_rollback keep || true
  else
    warn '未开启自动回滚或尚未产生变更；可手工执行 ./cassandra-deploy.sh rollback'
  fi
}

#============================== 状态检查 ==============================
chk(){ if eval "$2"; then echo "  [PASS] $1"; else echo "  [DIFF] $1"; fi; }
do_status(){
  detect_local
  echo "Cassandra 部署状态：$LOCAL_IP ($LOCAL_HOST) DC=$LOCAL_DC RACK=$LOCAL_RACK ROLE=$LOCAL_ROLE"
  echo '--- 操作系统 ---'
  chk '/etc/hosts 含全部集群主机名' "grep -q xxxdata01 /etc/hosts && grep -q xxxdata06 /etc/hosts"
  chk "用户 $CASS_USER 存在" "id -u $CASS_USER >/dev/null 2>&1"
  chk 'limits 配置已下发' '[ -f /etc/security/limits.d/cassandra.conf ]'
  chk 'sysctl swappiness=1' "[ \"\$(sysctl -n vm.swappiness 2>/dev/null)\" = 1 ]"
  chk 'SELinux 已禁用' "[ \"\$(getenforce 2>/dev/null)\" != Enforcing ]"
  chk 'firewalld 未运行' '! systemctl is-active firewalld >/dev/null 2>&1'
  chk 'THP=never' "grep -q '\[never\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null"
  chk 'zone_reclaim_mode=0' "[ \"\$(cat /proc/sys/vm/zone_reclaim_mode 2>/dev/null)\" = 0 ]"
  chk 'ntpd 运行中' 'systemctl is-active ntpd >/dev/null 2>&1'
  echo '--- 软件与配置 ---'
  chk 'JDK8 可用' "$JDK_HOME_DIR/bin/java -version 2>&1 | grep -q 1.8"
  chk 'Cassandra 已安装' '[ -x '"$CASS_HOME"'/bin/cassandra ]'
  if [ -f "$YAML" ]; then
    chk "cluster_name=$CLUSTER_NAME" "grep -Eq \"^cluster_name:[[:space:]]*'$CLUSTER_NAME'\" $YAML"
    chk "listen_address=$LOCAL_IP" "grep -Eq \"^listen_address:[[:space:]]*$LOCAL_IP\" $YAML"
    chk "rpc_address=$LOCAL_IP" "grep -Eq \"^rpc_address:[[:space:]]*$LOCAL_IP\" $YAML"
    chk 'endpoint_snitch=GossipingPropertyFileSnitch' 'grep -Eq "^endpoint_snitch:[[:space:]]*GossipingPropertyFileSnitch" '"$YAML"
    chk 'authenticator=PasswordAuthenticator' 'grep -Eq "^authenticator:[[:space:]]*PasswordAuthenticator" '"$YAML"
  else echo '  [DIFF] cassandra.yaml 不存在'; fi
  chk "rackdc dc=$LOCAL_DC rack=$LOCAL_RACK" "[ -f $RACKDC ] && grep -q \"dc=$LOCAL_DC\" $RACKDC"
  chk 'G1GC 已启用' "[ -f $JVM8_OPT ] && grep -Eq '^-XX:\+UseG1GC' $JVM8_OPT"
  echo '--- 服务 ---'
  chk 'cassandra.service 已 enable' 'systemctl is-enabled cassandra >/dev/null 2>&1'
  chk 'cassandra.service 运行中' 'systemctl is-active cassandra >/dev/null 2>&1'
  chk '9042 端口监听' 'ss -lnt 2>/dev/null | grep -q :9042'
  echo
  su - "$CASS_USER" -c "JAVA_HOME=${JDK_HOME_DIR} ${CASS_HOME}/bin/nodetool status" 2>/dev/null || echo '  nodetool status 暂不可用（节点未启动或未完成握手）'
}

#============================== 自检（不改系统） ==============================
run_selftest(){
  step '自检：在临时目录验证幂等编辑逻辑（不触碰系统文件）'
  local td; td="$(mktemp -d)"
  BACKUP_DIR="$td/bak"; MANIFEST="$td/bak/manifest"; mkdir -p "$BACKUP_DIR"
  local y="$td/cassandra.yaml" j="$td/jvm8-server.options" h="$td/hosts" pf="$td/profile" rc=0
  cat > "$y" <<EOF
cluster_name: 'Test Cluster'
num_tokens: 256
seed_provider:
    - class_name: org.apache.cassandra.locator.SimpleSeedProvider
      parameters:
          - seeds: "127.0.0.1:7000"
# listen_address: localhost
# rpc_address: localhost
data_file_directories:
#     - /var/lib/cassandra/data
     - /var/lib/cassandra/data

commitlog_directory: /var/lib/cassandra/commitlog
saved_caches_directory: /var/lib/cassandra/saved_caches
# authenticator: AllowAllAuthenticator
endpoint_snitch: SimpleSnitch
concurrent_reads: 32
# native_transport_max_threads: 128
row_cache_size_in_mb: 0
# cdc_enabled: false
EOF
  cat > "$j" <<EOF
-XX:+UseParNewGC
-XX:+UseConcMarkSweepGC
-XX:CMSInitiatingOccupancyFraction=75
#-XX:+UseG1GC
#-XX:MaxGCPauseMillis=300
-Xloggc:/var/log/cassandra/gc.log
EOF
  apply_sample(){
    set_yaml_str "$y" cluster_name "$CLUSTER_NAME"
    set_yaml_num "$y" num_tokens 16
    set_yaml_seeds "$y" '192.168.1.61,192.168.1.62,192.168.1.63'
    set_yaml_str "$y" listen_address '192.168.1.61'
    set_yaml_str "$y" rpc_address '192.168.1.61'
    set_yaml_datadir "$y" /data/cassandra/data
    set_yaml_raw "$y" commitlog_directory "'/data/cassandra/commitlog'"
    set_yaml_raw "$y" saved_caches_directory "'/data/cassandra/saved_caches'"
    set_yaml_raw "$y" authenticator PasswordAuthenticator
    set_yaml_raw "$y" endpoint_snitch GossipingPropertyFileSnitch
    set_yaml_num "$y" concurrent_reads 512
    set_yaml_num "$y" native_transport_max_threads 4092
    set_yaml_num "$y" row_cache_size_in_mb 32768
    set_yaml_raw "$y" cdc_enabled false
    if grep -Eq '^[[:space:]]*-XX:.*(CMS|ParNew|ConcMarkSweep)' "$j"; then
      sed -i -E 's|^([[:space:]]*)(-XX:.*(CMS|ParNew|ConcMarkSweep).*)$|\1#\2|' "$j"
    fi
    ensure_jvm_flag "$j" '-XX:+UseG1GC'
    set_jvm_value "$j" '-XX:MaxGCPauseMillis=' '500'
    set_jvm_value "$j" '-Xloggc:' '/data/cassandra/logs/gc.log'
  }
  NEED_RESTART=0; apply_sample
  cp "$y" "$y.1"; cp "$j" "$j.1"
  NEED_RESTART=0; apply_sample
  if ! diff -q "$y" "$y.1" >/dev/null || ! diff -q "$j" "$j.1" >/dev/null; then
    err '幂等性失败：第二次执行结果与第一次不同'; rc=1
  fi
  grep -Eq "^cluster_name:[[:space:]]*'$CLUSTER_NAME'" "$y" || { err 'cluster_name 未生效'; rc=1; }
  grep -Eq '^num_tokens:[[:space:]]*16' "$y" || { err 'num_tokens 未生效'; rc=1; }
  grep -Eq '^- seeds:[[:space:]]*"192.168.1.61' "$y" || { err 'seeds 未生效'; rc=1; }
  grep -Eq "^listen_address:[[:space:]]*'192.168.1.61'" "$y" || { err 'listen_address 未生效'; rc=1; }
  grep -Eq '^[[:space:]]*-[[:space:]]*/data/cassandra/data[[:space:]]*$' "$y" || { err 'data 目录未生效'; rc=1; }
  grep -Eq '^authenticator:[[:space:]]*PasswordAuthenticator' "$y" || { err 'authenticator 未生效'; rc=1; }
  grep -Eq '^endpoint_snitch:[[:space:]]*GossipingPropertyFileSnitch' "$y" || { err 'snitch 未生效'; rc=1; }
  grep -Eq '^-XX:\+UseG1GC' "$j" || { err 'G1 未启用'; rc=1; }
  grep -Eq '^#-XX:\+UseConcMarkSweepGC' "$j" || { err 'CMS 未禁用'; rc=1; }
  grep -Eq '^-Xloggc:/data/cassandra/logs/gc.log' "$j" || { err 'gc 日志路径未生效'; rc=1; }
  ! grep -q '/var/lib/cassandra' "$y" || { err '默认数据路径残留'; rc=1; }
  # 托管块
  echo '127.0.0.1 localhost' > "$h"
  ensure_block "$h" '# >>> t >>>' '# <<< t <<<' $'a\nb'; local hs1; hs1="$(md5sum "$h" 2>/dev/null)"
  ensure_block "$h" '# >>> t >>>' '# <<< t <<<' $'a\nb'
  [ "$hs1" = "$(md5sum "$h" 2>/dev/null)" ] || { err '托管块重复执行发生变化'; rc=1; }
  grep -q '^a$' "$h" && grep -q '^127.0.0.1' "$h" || { err '托管块内容异常'; rc=1; }
  rm -rf "$td"
  if [ "$rc" -eq 0 ]; then ok '自检全部通过：编辑器幂等且结果正确（未修改任何系统文件）'
  else err '自检失败，请把输出反馈给维护者'; fi
  return "$rc"
}

#============================== 主流程 ==============================
usage(){
  cat <<EOF
用法: $0 [deploy|rollback [--purge]|status|selftest|stages] [-h]
  deploy   一键部署（默认），幂等可重复执行；失败自动回滚配置/服务
  rollback 回滚最近一次部署；--purge 同时删除软件、数据目录与用户
  status   查看本机各阶段实际状态
  selftest 在临时目录自检幂等编辑逻辑，不修改系统
  stages   列出部署阶段
可用环境变量覆盖：LOCAL_IP LOCAL_DC LOCAL_RACK（例如 LOCAL_IP=192.168.1.66）
EOF
}

main(){
  local action="${1:-deploy}"; shift || true
  local purge='keep'
  [ "${1:-}" = '--purge' ] && purge='purge'
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  case "$action" in
    deploy)
      need_root
      detect_local
      BACKUP_DIR="${STATE_DIR}/backup-$(date +%Y%m%d-%H%M%S)"
      mkdir -p "$BACKUP_DIR/root"; MANIFEST="$BACKUP_DIR/manifest"; : > "$MANIFEST"
      trap 'on_failure; exit 1' INT TERM
      log "部署开始，备份目录：$BACKUP_DIR"
      local st
      for st in "${STAGES[@]}"; do eval "stage_${st}"; done
      echo; ok '全部阶段完成（脚本幂等，重复执行只补缺不重做）'
      log '部署成功'
      ;;
    rollback)
      need_root
      ALLOW_MISSING_LOCAL=1 detect_local; do_rollback "$purge"
      ;;
    status) ALLOW_MISSING_LOCAL=1 do_status ;;
    selftest) run_selftest ;;
    stages) printf '%s\n' "${STAGES[@]}" ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"




