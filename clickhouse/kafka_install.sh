#!/bin/bash
###############################################################################
# Kafka SCRAM 集群一键部署脚本（复用已有 ZooKeeper 集群）
#
# 适用环境 : CentOS 7 / RHEL 7 x86_64，root 运行
# 支持版本 : Kafka 3.x（ZooKeeper 模式，默认 3.9.0）
#            Kafka 4.x（KRaft 模式，需 KRAFT_MODE=1 且 JDK 17）
#
# 用法:
#   ./kafka_install.sh
#   KAFKA_VERSION=3.9.0 ./kafka_install.sh
#   KAFKA_VERSION=4.0.0 KRAFT_MODE=1 ./kafka_install.sh
#   KAFKA_DOWNLOAD_URL='http://内网镜像/kafka/kafka_2.13-3.9.0.tgz' ./kafka_install.sh
#
# 特性:
#   - 自动下载 Kafka 二进制包（wget/curl 兜底，支持镜像 URL）
#   - 幂等分发到各节点（远端同大小跳过）
#   - 修复 inter.broker.listener.name 与 security.inter.broker.protocol 冲突
#   - 自动生成 client.properties
#   - 分步验证，失败明确提示

#==================== 部署完成 ====================
#集群地址：
#  broker1: 10.228.131.134:9092
#  broker2: 10.228.131.135:9092
#  broker3: 10.228.131.143:9092
#SCRAM鉴权信息：
#  机制: SCRAM-SHA-512
#  账号: admin
#  密码: Admin@123456
#  依赖ZK: 10.228.131.134:2181,10.228.131.135:2181,10.228.131.143:2181
#服务管理命令：
#  启动: systemctl start kafka
#  停止: systemctl stop kafka
#  状态: systemctl status kafka
#  日志: tail -f /data/kafka/logs/server.log
#==================================================
#10.228.131.134:9092,10.228.131.135:9092,10.228.131.143:9092
## 查看Topic列表
#bin/kafka-topics.sh --bootstrap-server 10.228.131.134:9092 --command-config client.properties --list
## 创建测试Topic
#bin/kafka-topics.sh --bootstrap-server 10.228.131.134:9092 --command-config client.properties \
#  --create --topic monitorDataForCMDB --replication-factor 3 --partitions 3
## 生产消息
#bin/kafka-console-producer.sh --bootstrap-server 10.228.131.134:9092 --producer.config client.properties --topic test_topic
## 消费消息
#bin/kafka-console-consumer.sh --bootstrap-server 10.228.131.134:9092 --consumer.config client.properties --topic test_topic --from-beginning
#cd /data/goldendb/bigdata/kafka
#./bin/kafka-topics.sh --bootstrap-server 10.228.131.134:9092 --command-config client.properties --list
#[root@gdb135 kafka]# ./bin/kafka-topics.sh --bootstrap-server 10.228.131.134:9092 --command-config client.properties --list
#monitorDataForCMDB
#monitorDataForCMDB_goldendb1789118498004
#test_topic
#./bin/kafka-topics.sh --bootstrap-server 10.228.131.134:9092 \
#  --command-config client.properties \
#  --delete --topic monitorDataForCMDB_goldendb1789118498004
#  
#  bin/kafka-console-consumer.sh --bootstrap-server 10.228.131.134:9092 --consumer.config client.properties --topic monitorDataForCMDB --from-beginning
###############################################################################
set -euo pipefail

# ============== 配置区域 ==============
NODE_IPS=("192.168.221.129" "192.168.221.130" "192.168.221.131")
NODE_IDS=(1 2 3)

KAFKA_HOME="/clickhouse/kafka"
KAFKA_LOG_DIR="/clickhouse/kafka/logs"
RUN_USER="kafka"
KAFKA_PORT=9092

SASL_MECHANISM="SCRAM-SHA-512"
ADMIN_USER="admin"
ADMIN_PASSWORD="Admin@123456"   # 生产环境请修改为强密码
ZOOKEEPER_CONNECT="192.168.221.129:32181,192.168.221.130:32181,192.168.221.131:32181"

JAVA_PACKAGE="${JAVA_PACKAGE:-java-17-openjdk-devel}"

# ---- Kafka 二进制包自动下载 ----
KAFKA_VERSION="${KAFKA_VERSION:-3.9.0}"
SCALA_VERSION="${SCALA_VERSION:-2.13}"
KAFKA_PKG="kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz"
KAFKA_DOWNLOAD_URL="${KAFKA_DOWNLOAD_URL:-https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_PKG}}"
PKG_DIR="${PKG_DIR:-/clickhouse/soft}"
KRAFT_MODE="${KRAFT_MODE:-0}"                     # 1=KRaft(仅4.x)，0=ZooKeeper(3.x)
CONTROLLER_PORT="${CONTROLLER_PORT:-9093}"

# ============== 基础校验 ==============
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 用户运行此脚本"; exit 1
fi
if [ "${#NODE_IPS[@]}" -ne "${#NODE_IDS[@]}" ]; then
    echo "错误：NODE_IPS 与 NODE_IDS 数量不匹配"; exit 1
fi

# KRaft 模式仅 Kafka 4.x 支持；ZooKeeper 模式仅 3.x 支持
if [ "$KRAFT_MODE" = "1" ] && [[ "$KAFKA_VERSION" == 3.* ]]; then
    echo "警告：Kafka 3.x 也支持 KRaft，但语法有差异，请确认"
fi
if [ "$KRAFT_MODE" = "0" ] && [[ "$KAFKA_VERSION" == 4.* ]]; then
    echo "错误：Kafka 4.x 已移除 ZooKeeper 模式，请设置 KRAFT_MODE=1"; exit 1
fi

ZK_CONNECT_STR="${ZOOKEEPER_CONNECT}"

echo "==================== Kafka SCRAM 集群一键部署 ===================="
echo "Kafka 版本: ${KAFKA_VERSION}  (协调模式: $([ "$KRAFT_MODE" = "1" ] && echo KRaft || echo ZooKeeper))"
echo "节点列表: ${NODE_IPS[*]}"
echo "Kafka 程序目录: ${KAFKA_HOME}"
echo "鉴权机制: ${SASL_MECHANISM}"
if [ "$KRAFT_MODE" != "1" ]; then
    echo "复用 ZK 集群: ${ZK_CONNECT_STR}"
fi
echo "管理员账号: ${ADMIN_USER}"
echo "=================================================================="
read -p "确认配置无误，开始部署？(y/n): " confirm
[ "$confirm" = "y" ] || { echo "部署已取消"; exit 0; }

# ============== 通用函数 ==============
remote_exec() {
    local node_ip=$1; shift
    echo "[${node_ip}] 执行: $*"
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node_ip} "$@"
}

# ============== 步骤0：下载 + 分发 Kafka ==============
download_and_distribute_kafka() {
    echo -e "\n===== 步骤0：下载并分发 Kafka 二进制包 ====="
    mkdir -p "$PKG_DIR"
    local local_pkg="$PKG_DIR/$KAFKA_PKG"

    # ---- 1) 本地下载（幂等） ----
    if [ -s "$local_pkg" ]; then
        echo "本地已存在 $local_pkg（$(stat -c %s "$local_pkg") 字节），跳过下载"
    else
        echo "从 Apache 下载 Kafka ${KAFKA_VERSION} ..."
        echo "  URL: $KAFKA_DOWNLOAD_URL"
        local tmp="$local_pkg.tmp"
        rm -f "$tmp"
        local dl_ok=0
        if command -v wget >/dev/null 2>&1; then
            wget -q --no-check-certificate --timeout=30 --tries=3 \
                 -O "$tmp" "$KAFKA_DOWNLOAD_URL" && dl_ok=1 || true
        fi
        if [ "$dl_ok" != "1" ] && command -v curl >/dev/null 2>&1; then
            echo "  wget 失败，尝试 curl ..."
            curl -fSL --insecure --connect-timeout 30 --retry 3 \
                 -o "$tmp" "$KAFKA_DOWNLOAD_URL" && dl_ok=1 || true
        fi
        if [ "$dl_ok" != "1" ] || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            echo "错误：下载失败。请检查网络，或手动下载后放到："
            echo "  $local_pkg"
            echo "镜像地址（任选一个）："
            echo "  https://dlcdn.apache.org/kafka/${KAFKA_VERSION}/${KAFKA_PKG}"
            echo "  https://mirrors.tuna.tsinghua.edu.cn/apache/kafka/${KAFKA_VERSION}/${KAFKA_PKG}"
            echo "  https://mirrors.huaweicloud.com/apache/kafka/${KAFKA_VERSION}/${KAFKA_PKG}"
            return 1
        fi
        mv "$tmp" "$local_pkg"
        echo "下载完成: $(stat -c %s "$local_pkg") 字节"
    fi

    # 校验是否像 tar.gz（前两字节魔数 1f 8b）
    local magic
    magic="$(head -c 2 "$local_pkg" | xxd -p 2>/dev/null || true)"
    if [ "$magic" != "1f8b" ]; then
        echo "错误：$local_pkg 不是有效的 gzip 文件（魔数=$magic），请删除后重新下载"
        return 1
    fi

    # ---- 2) 分发到各节点（幂等） ----
    local local_size; local_size=$(stat -c %s "$local_pkg")
    local node remote_size
    for node in "${NODE_IPS[@]}"; do
        remote_size=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${node} \
            "stat -c %s '$PKG_DIR/$KAFKA_PKG' 2>/dev/null || echo 0" 2>/dev/null || echo 0)
        if [ "$remote_size" = "$local_size" ] && [ "$local_size" != "0" ]; then
            echo "  ${node}: $KAFKA_PKG 已存在（大小一致），跳过"
            continue
        fi
        echo "  → 分发 $KAFKA_PKG 到 ${node} ..."
        ssh -o StrictHostKeyChecking=no root@${node} "mkdir -p '$PKG_DIR'"
        scp -o StrictHostKeyChecking=no "$local_pkg" root@${node}:"$PKG_DIR/$KAFKA_PKG"
    done
    echo "Kafka 二进制包分发完成"
}

# ============== 步骤2 辅助：解压 Kafka ==============
extract_kafka_on_node() {
    local node_ip=$1
    remote_exec "${node_ip}" "
        if [ -x '${KAFKA_HOME}/bin/kafka-server-start.sh' ]; then
            echo 'Kafka 已解压，跳过'
        else
            mkdir -p '${KAFKA_HOME}'
            tar xzf '${PKG_DIR}/${KAFKA_PKG}' -C /tmp/
            cp -a /tmp/kafka_${SCALA_VERSION}-${KAFKA_VERSION}/. '${KAFKA_HOME}/'
            rm -rf /tmp/kafka_${SCALA_VERSION}-${KAFKA_VERSION}
            echo 'Kafka 解压完成'
        fi
    "
}

# ============== 执行：下载分发 ==============
download_and_distribute_kafka

# ============== 步骤1：节点基础环境 ==============
echo -e "\n===== 步骤1：节点基础环境初始化 ====="
for i in "${!NODE_IPS[@]}"; do
    node_ip=${NODE_IPS[$i]}
    echo "--- 处理节点 ${node_ip} ---"
    remote_exec "${node_ip}" "
        setenforce 0 2>/dev/null || true
        sed -i 's/^SELINUX=enforcing\$/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
        if ! java -version &>/dev/null; then
            echo '安装 Java 环境...'
            yum install -y ${JAVA_PACKAGE}
        else
            echo \"Java 已安装: \$(java -version 2>&1 | head -1)\"
        fi
        if ! id ${RUN_USER} &>/dev/null; then
            useradd -r -s /sbin/nologin ${RUN_USER}
            echo '创建运行用户 ${RUN_USER}'
        fi
        mkdir -p ${KAFKA_LOG_DIR}
    "
done

# ============== 步骤2：解压 + 授权 ==============
echo -e "\n===== 步骤2：解压 Kafka 并授权 ====="
for node_ip in "${NODE_IPS[@]}"; do
    extract_kafka_on_node "${node_ip}"
    remote_exec "${node_ip}" "
        chown -R ${RUN_USER}:${RUN_USER} ${KAFKA_HOME} ${KAFKA_LOG_DIR}
        echo '权限授权完成'
    "
done

# ============== 步骤3：生成配置 ==============
echo -e "\n===== 步骤3：配置 Kafka SCRAM-SHA-512 鉴权 ====="

# 构造 controller.quorum.voters（仅 KRaft 用）
QUORUM_VOTERS=""
if [ "$KRAFT_MODE" = "1" ]; then
    for i in "${!NODE_IPS[@]}"; do
        [ -n "$QUORUM_VOTERS" ] && QUORUM_VOTERS+=","
        QUORUM_VOTERS+="${NODE_IDS[$i]}@${NODE_IPS[$i]}:${CONTROLLER_PORT}"
    done
fi

for i in "${!NODE_IPS[@]}"; do
    node_ip=${NODE_IPS[$i]}
    broker_id=${NODE_IDS[$i]}
    echo "--- 配置节点 ${node_ip} (broker.id: ${broker_id}) ---"

    if [ "$KRAFT_MODE" = "1" ]; then
        # ---------------- KRaft 模式（Kafka 4.x） ----------------
        SERVER_PROPS="process.roles=broker,controller
node.id=${broker_id}
controller.quorum.voters=${QUORUM_VOTERS}
listeners=SASL_PLAINTEXT://0.0.0.0:${KAFKA_PORT},CONTROLLER://0.0.0.0:${CONTROLLER_PORT}
advertised.listeners=SASL_PLAINTEXT://${node_ip}:${KAFKA_PORT}
listener.security.protocol.map=CONTROLLER:PLAINTEXT,SASL_PLAINTEXT:SASL_PLAINTEXT
controller.listener.names=CONTROLLER
# ★ 关键：只保留 inter.broker.listener.name（KRaft 下必须）
inter.broker.listener.name=SASL_PLAINTEXT
sasl.enabled.mechanisms=${SASL_MECHANISM}
sasl.mechanism.inter.broker.protocol=${SASL_MECHANISM}
log.dirs=${KAFKA_LOG_DIR}
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
auto.create.topics.enable=false
delete.topic.enable=true
"
    else
        # ---------------- ZooKeeper 模式（Kafka 3.x） ----------------
        SERVER_PROPS="broker.id=${broker_id}
listeners=SASL_PLAINTEXT://0.0.0.0:${KAFKA_PORT}
advertised.listeners=SASL_PLAINTEXT://${node_ip}:${KAFKA_PORT}
# ★ 关键：只保留 inter.broker.listener.name，禁止同时设置 security.inter.broker.protocol
listener.security.protocol.map=SASL_PLAINTEXT:SASL_PLAINTEXT
inter.broker.listener.name=SASL_PLAINTEXT
sasl.enabled.mechanisms=${SASL_MECHANISM}
sasl.mechanism.inter.broker.protocol=${SASL_MECHANISM}
zookeeper.connect=${ZK_CONNECT_STR}
zookeeper.connection.timeout.ms=18000
log.dirs=${KAFKA_LOG_DIR}
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
log.retention.hours=168
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
auto.create.topics.enable=false
delete.topic.enable=true
"
    fi

    JAAS_CONF="KafkaServer {
    org.apache.kafka.common.security.scram.ScramLoginModule required
    username=\"${ADMIN_USER}\"
    password=\"${ADMIN_PASSWORD}\";
};
"

    # 用 heredoc 一次性写入所有配置 + systemd unit
    remote_exec "${node_ip}" "bash -s" <<REMOTE
set -e
cat > ${KAFKA_HOME}/config/server.properties << 'EOF'
${SERVER_PROPS}
EOF

cat > ${KAFKA_HOME}/config/kafka_server_jaas.conf << 'EOF'
${JAAS_CONF}
EOF

# ★ 生成客户端连接配置文件
cat > ${KAFKA_HOME}/client.properties << 'EOF'
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="${ADMIN_USER}" password="${ADMIN_PASSWORD}";
security.protocol=SASL_PLAINTEXT
sasl.mechanism=${SASL_MECHANISM}
EOF

chown ${RUN_USER}:${RUN_USER} ${KAFKA_HOME}/config/server.properties \
                             ${KAFKA_HOME}/config/kafka_server_jaas.conf \
                             ${KAFKA_HOME}/client.properties
chmod 600 ${KAFKA_HOME}/config/kafka_server_jaas.conf ${KAFKA_HOME}/client.properties

# ★ 兜底清理冲突配置（幂等）
sed -i '/^security\.inter\.broker\.protocol/d' ${KAFKA_HOME}/config/server.properties

cat > /etc/systemd/system/kafka.service << 'EOF'
[Unit]
Description=Apache Kafka
After=network.target

[Service]
Type=forking
User=${RUN_USER}
Group=${RUN_USER}
Environment="KAFKA_OPTS=-Djava.security.auth.login.config=${KAFKA_HOME}/config/kafka_server_jaas.conf"
ExecStart=${KAFKA_HOME}/bin/kafka-server-start.sh -daemon ${KAFKA_HOME}/config/server.properties
ExecStop=${KAFKA_HOME}/bin/kafka-server-stop.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka >/dev/null 2>&1
echo "配置写入完成"
REMOTE
done

# ============== 步骤4：创建 SCRAM 管理员用户 ==============
echo -e "\n===== 步骤4：创建 SCRAM 管理员用户 ====="
if [ "$KRAFT_MODE" = "1" ]; then
    echo "KRaft 模式下 SCRAM 用户需在启动后通过 kafka-configs.sh --bootstrap-server 添加"
    echo "（首次启动 Kafka 前若无任何用户，需要先以 PLAINTEXT 启动或使用 --add-scram 格式化存储）"
else
    first_node=${NODE_IPS[0]}
    remote_exec "${first_node}" "
        ${KAFKA_HOME}/bin/kafka-configs.sh --zookeeper ${ZK_CONNECT_STR} --alter \
            --add-config '${SASL_MECHANISM}=[password=${ADMIN_PASSWORD}]' \
            --entity-type users --entity-name ${ADMIN_USER}
    "
    echo "已创建 SCRAM 用户: ${ADMIN_USER}（凭据写入 ZooKeeper）"
fi

# ============== 步骤5：启动 Kafka 集群 ==============
echo -e "\n===== 步骤5：启动 Kafka 集群 ====="
for node_ip in "${NODE_IPS[@]}"; do
    echo "启动节点 ${node_ip} Kafka..."
    remote_exec "${node_ip}" "systemctl restart kafka"
done
echo "等待 Kafka 集群启动完成..."
sleep 25

# ============== 步骤6：部署验证 ==============
echo -e "\n===== 步骤6：部署验证 ====="

echo "Kafka 服务状态："
for node_ip in "${NODE_IPS[@]}"; do
    printf '  %-16s ' "${node_ip}"
    remote_exec "${node_ip}" "systemctl is-active kafka" || true
done

# 尝试通过 broker 列表验证（会用到 client.properties）
echo ""
echo "Broker 列表验证（通过 SASL 连接）："
BOOTSTRAP=""
for i in "${!NODE_IPS[@]}"; do
    [ -n "$BOOTSTRAP" ] && BOOTSTRAP+=","
    BOOTSTRAP+="${NODE_IPS[$i]}:${KAFKA_PORT}"
done

if remote_exec "${NODE_IPS[0]}" "
    ${KAFKA_HOME}/bin/kafka-broker-api-versions.sh \
        --bootstrap-server ${BOOTSTRAP} \
        --command-config ${KAFKA_HOME}/client.properties 2>&1 | grep -q 'id:'
"; then
    echo "  ✓ Kafka 集群可正常连接"
else
    echo "  ✗ 连接失败，请检查各节点 kafka 日志："
    echo "    tail -f ${KAFKA_LOG_DIR}/server.log"
fi

# ============== 完成 ==============
echo ""
echo "==================== 部署完成 ===================="
echo "集群地址："
for i in "${!NODE_IPS[@]}"; do
    echo "  broker${NODE_IDS[$i]}: ${NODE_IPS[$i]}:${KAFKA_PORT}"
done
echo ""
echo "SCRAM 鉴权信息："
echo "  机制: ${SASL_MECHANISM}"
echo "  账号: ${ADMIN_USER}"
echo "  密码: ${ADMIN_PASSWORD}"
[ "$KRAFT_MODE" != "1" ] && echo "  依赖 ZK: ${ZK_CONNECT_STR}"
echo ""
echo "客户端配置文件: ${KAFKA_HOME}/client.properties"
echo ""
echo "服务管理命令："
echo "  启动: systemctl start kafka"
echo "  停止: systemctl stop kafka"
echo "  状态: systemctl status kafka"
echo "  日志: tail -f ${KAFKA_LOG_DIR}/server.log"
echo "=================================================="
