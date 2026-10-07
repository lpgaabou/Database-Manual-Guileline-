#!/bin/bash
# ============== 配置区域：与部署脚本保持一致 ==============
# 集群节点IP
NODE_IPS=("10.228.131.134" "10.228.131.135" "10.228.131.143")
# 程序目录
KAFKA_HOME="/data/goldendb/bigdata/kafka"
ZK_HOME="/data/goldendb/bigdata/zookeeper"
# 数据与日志目录
ZK_DATA_DIR="/data/zookeeper"
KAFKA_LOG_DIR="/data/kafka/logs"
# 运行用户
RUN_USER="kafka"
# 端口列表
ZK_CLIENT_PORT=2181
ZK_LEADER_PORT=2888
ZK_ELECTION_PORT=3888
KAFKA_PORT=9092
# ==========================================================
# 权限校验
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用root用户运行此脚本"
    exit 1
fi
# 二次确认
echo "==================== 集群全量回滚清理 ===================="
echo "即将清理以下节点的所有 Kafka + ZooKeeper 部署："
echo "节点列表: ${NODE_IPS[*]}"
echo "删除程序目录: ${KAFKA_HOME}, ${ZK_HOME}"
echo "删除数据目录: ${ZK_DATA_DIR}, ${KAFKA_LOG_DIR}"
echo "删除系统服务: kafka.service, zookeeper.service"
echo "删除运行用户: ${RUN_USER}"
echo "关闭防火墙端口: ${ZK_CLIENT_PORT}, ${ZK_LEADER_PORT}, ${ZK_ELECTION_PORT}, ${KAFKA_PORT}"
echo "=========================================================="
read -p "此操作不可逆！确认继续回滚？(输入 yes 确认): " confirm
if [ "$confirm" != "yes" ]; then
    echo "已取消回滚操作"
    exit 0
fi
# 远程执行函数
remote_exec() {
    local node_ip=$1
    local cmd=$2
    echo "[${node_ip}] 执行: ${cmd}"
    ssh -o StrictHostKeyChecking=no root@${node_ip} "${cmd}"
}
echo -e "\n===== 开始执行全节点回滚清理 ====="
for node_ip in "${NODE_IPS[@]}"; do
    echo "---------- 处理节点 ${node_ip} ----------"
    remote_exec ${node_ip} "
        # 1. 停止服务（先停Kafka，再停ZK）
        echo '停止Kafka服务...'
        systemctl stop kafka 2>/dev/null || true
        systemctl disable kafka 2>/dev/null || true
        echo '停止ZooKeeper服务...'
        systemctl stop zookeeper 2>/dev/null || true
        systemctl disable zookeeper 2>/dev/null || true
        # 2. 删除systemd服务文件
        echo '删除systemd服务配置...'
        rm -f /etc/systemd/system/kafka.service
        rm -f /etc/systemd/system/zookeeper.service
        systemctl daemon-reload
        # 3. 删除程序目录
        echo '删除程序目录...'
        rm -rf ${KAFKA_HOME}
        rm -rf ${ZK_HOME}
        # 4. 删除数据与日志目录
        echo '删除数据与日志目录...'
        rm -rf ${ZK_DATA_DIR}
        rm -rf ${KAFKA_LOG_DIR}
        # 5. 删除运行用户
        echo '删除运行用户...'
        userdel -r ${RUN_USER} 2>/dev/null || true
        echo '节点清理完成'
    "
done
echo -e "\n==================== 回滚完成 ===================="
echo "所有节点 Kafka + ZooKeeper 已全部清理完毕"
echo "可以重新执行部署脚本进行全新安装"
echo "=================================================="