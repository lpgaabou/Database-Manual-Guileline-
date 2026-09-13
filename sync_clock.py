#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
多节点 NTP/Chrony 时钟同步配置脚本
================================================================================

一、原文件内容整理与注释解析
--------------------------------------------------------------------------------
1. CentOS8/RHEL8 默认不再支持 ntp 软件包，时间同步由 chrony 实现。
2. chrony 优势：
   - 更快的同步，减少时间和频率误差，适合非 24 小时运行的虚拟机。
   - 更好响应时钟频率快速变化，适合虚拟机或不稳定时钟。
   - 初始同步后不会停止时钟，避免影响需要单调时间的应用。
   - 应对临时非对称延迟时更稳定。
   - 无需定期轮询，间歇性网络连接也能快速同步。
3. chrony 两个主要程序：
   - chronyd：后台守护进程，调整内核系统时钟并与时间服务器同步。
   - chronyc：命令行工具，用于监控和配置 chronyd。
4. chrony 服务与端口：
   - 服务 unit：/usr/lib/systemd/system/chronyd.service
   - 监听端口：323/udp，123/udp
   - 配置文件：/etc/chrony.conf
5. chrony 常用配置项：
   - server：指明时间服务器地址，iburst 加快初始同步。
   - driftfile：记录计算机增减时间的比率，重启后用于补偿。
   - rtcsync：启用内核模式，系统时间每 11 分钟拷贝到 RTC。
   - allow NETADD/NETMASK：允许客户端同步本机时间。
   - allow all：允许所有客户端。
   - deny：拒绝客户端。
   - cmdallow/cmddeny：控制哪些主机可通过 chronyd 使用控制命令。
   - bindcmdaddress：chronyd 监听哪个接口接收 chronyc 命令。
   - makestep：偏差大于阈值时强制步进调整系统时钟。
   - local stratum 10：即使 server 不可用，也允许将本地时间作为标准时间授时。
6. RHEL7 ntp 常用配置：
   - 配置文件：/etc/ntp.conf
   - driftfile /var/lib/ntp/drift
   - restrict 控制访问权限。
   - server 127.127.1.0 + fudge 127.127.1.0 stratum 10：使用本地时钟作为时间源。
   - disable monitor：防止 ntpdc monlist 放大攻击。
7. 服务管理：
   - systemctl start/enable/status chronyd
   - systemctl start/enable/status ntpd
   - 防火墙默认放行 123/udp，否则客户端无法同步。
8. 时区相关：
   - timedatectl
   - timedatectl list-timezones
   - timedatectl set-timezone Asia/Shanghai
   - timedatectl set-ntp true/false
9. 硬件时钟：
   - ntp 默认只同步系统时间。
   - 可在 /etc/sysconfig/ntpd 添加 SYNC_HWCLOCK=yes。
   - 也可使用 hwclock -w 将系统时间写入 BIOS/硬件时钟。
   - chrony 使用 rtcsync 自动同步 RTC。
10. 验证命令：
    - chronyc sources -v
    - chronyc sourcestats
    - chronyc tracking
    - chronyc activity
    - chronyc clients
    - ntpq -p
    - ntpstat
11. ntpd 与 ntpdate 区别：
    - ntpd 平滑同步，适合生产环境。
    - ntpdate 跳变同步，生产环境慎用。
    - 本脚本仅在 RHEL7 ntp 客户端初始同步时使用 ntpdate，之后由 ntpd 平滑校准。

二、离线环境依赖说明
--------------------------------------------------------------------------------
本机执行脚本需要：
- Python 3.6+
- openssh-clients：提供 ssh 命令
- sshpass：如果 host.ini 中配置了 password，则需要本机安装 sshpass
  如果不想使用 sshpass，可提前配置 SSH 免密登录，并把 password 留空
目标机需要：
- RHEL7.6：yum 离线源中提前准备 ntp 包
- RHEL8.5：yum 离线源中提前准备 chrony 包
- 目标机需有 base64、systemctl、timedatectl、firewall-cmd 等基础命令
本脚本不依赖 pip 第三方库。

三、host.ini 示例
--------------------------------------------------------------------------------
[global]
allow_network = 192.168.80.0/24

[server]
hostname = node1
ip = 192.168.80.60
user = root
password = 123456
port = 22
system = redhat7.6
role = server

[client1]
hostname = node2
ip = 192.168.80.61
user = root
password = 123456
port = 22
system = redhat8.5
role = client

[client2]
hostname = node3
ip = 192.168.80.62
user = root
password = 123456
port = 22
system = redhat7.6
role = client

四、执行示例
--------------------------------------------------------------------------------
python3 sync_clock.py --host-ini host.ini
python3 sync_clock.py --host-ini host.ini --server node1
python3 sync_clock.py --host-ini host.ini --close-firewall

五、注意
--------------------------------------------------------------------------------
- 默认以第一个 role=server 的节点为时钟源；若未指定，则第一个节点为时钟源。
- 第一台服务器使用本地时钟作为时钟源，适合无外网的测试环境。
- 其他节点同步第一台服务器。
- 生产环境请根据实际网段限制 allow_network，并谨慎关闭防火墙。
================================================================================
"""

import os
import sys
import time
import shutil
import base64
import argparse
import configparser
import subprocess
import ipaddress


class Node:
    """节点信息，兼容 Python 3.6，不使用 dataclasses。"""

    def __init__(self, section, hostname, ip, user, password, port, system, role):
        self.section = section
        self.hostname = hostname
        self.ip = ip
        self.user = user
        self.password = password
        self.port = int(port)
        self.system = system
        self.role = role

    def __repr__(self):
        return "<Node %s %s %s role=%s>" % (
            self.section,
            self.hostname,
            self.ip,
            self.role,
        )


def run_local(cmd, check=True):
    """执行本地命令。"""
    print("[local] $ %s" % cmd)
    return subprocess.run(
        cmd,
        shell=True,
        check=check,
        universal_newlines=True,
    )


def _ssh_base(node):
    """构造 ssh 基础命令。如果配置了密码，则使用 sshpass -e 传递密码。"""
    ssh_cmd = [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "-p", str(node.port),
        "%s@%s" % (node.user, node.ip),
    ]

    if node.password:
        env = os.environ.copy()
        env["SSHPASS"] = node.password
        return ["sshpass", "-e"] + ssh_cmd, env
    else:
        return ssh_cmd, None


def ssh_run(node, remote_cmd, timeout=180, check=True):
    """远程执行命令，直接输出到终端。"""
    cmd, env = _ssh_base(node)
    cmd = cmd + [remote_cmd]
    print("[%s] $ %s" % (node.hostname, remote_cmd))
    return subprocess.run(
        cmd,
        env=env,
        timeout=timeout,
        check=check,
        universal_newlines=True,
    )


def ssh_output(node, remote_cmd, timeout=60, check=True):
    """远程执行命令并返回 stdout。"""
    cmd, env = _ssh_base(node)
    cmd = cmd + [remote_cmd]
    print("[%s] $ %s" % (node.hostname, remote_cmd))
    res = subprocess.run(
        cmd,
        env=env,
        timeout=timeout,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    return res.stdout.strip()


def write_remote_file(node, path, content):
    """通过 base64 写入远程文件，避免 heredoc 转义问题。"""
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    ssh_run(node, "echo %s | base64 -d > %s" % (b64, path))


def read_host_ini(path):
    """读取 host.ini。"""
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(path, encoding="utf-8")

    nodes = []
    for section in cp.sections():
        if section.lower() == "global":
            continue

        node = Node(
            section=section,
            hostname=cp.get(section, "hostname", fallback=section),
            ip=cp.get(section, "ip"),
            user=cp.get(section, "user", fallback="root"),
            password=cp.get(section, "password", fallback=""),
            port=cp.getint(section, "port", fallback=22),
            system=cp.get(section, "system", fallback=""),
            role=cp.get(section, "role", fallback=""),
        )
        nodes.append(node)

    return cp, nodes


def choose_server(cp, nodes, server_arg=None):
    """选择时钟源节点。"""
    if server_arg:
        for n in nodes:
            if n.section == server_arg or n.hostname == server_arg:
                return n
        raise RuntimeError("未找到指定的 server 节点: %s" % server_arg)

    for n in nodes:
        if n.role.lower() == "server":
            return n

    if not nodes:
        raise RuntimeError("host.ini 中没有节点")

    return nodes[0]


def detect_system(node):
    """判断节点使用 ntp 还是 chrony。RHEL7.6 用 ntp，RHEL8.5 用 chrony。"""
    if node.system:
        s = node.system.lower()
        if "8" in s or "chrony" in s:
            return "chrony"
        if "7" in s or "ntp" in s:
            return "ntp"

    out = ssh_output(node, "cat /etc/redhat-release 2>/dev/null || true", check=False).lower()
    if "release 8" in out:
        return "chrony"
    if "release 7" in out:
        return "ntp"

    # 默认按 chrony 处理
    return "chrony"


def ensure_package(node, pkg):
    """检查并尝试安装软件包，要求目标机 yum 离线源已准备好。"""
    if pkg == "chrony":
        check_cmd = "command -v chronyd"
    else:
        check_cmd = "command -v ntpd"

    ssh_run(
        node,
        "%s >/dev/null 2>&1 || yum install -y %s" % (check_cmd, pkg),
        check=False,
    )


def configure_chrony(node, is_server, server_ip, allow_network):
    """配置 chrony。"""
    if is_server:
        conf = """# Generated by sync_clock.py
# chrony 服务端：无外网时以本地时钟作为时钟源
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
local stratum 10
allow %s
logdir /var/log/chrony
""" % allow_network
    else:
        conf = """# Generated by sync_clock.py
# chrony 客户端：同步第一台服务器
server %s iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
""" % server_ip

    ssh_run(node, "mkdir -p /var/log/chrony", check=False)
    write_remote_file(node, "/etc/chrony.conf", conf)

    # 避免与 ntpd 冲突
    ssh_run(node, "systemctl stop ntpd 2>/dev/null || true", check=False)
    ssh_run(node, "systemctl disable ntpd 2>/dev/null || true", check=False)

    ssh_run(node, "systemctl enable chronyd", check=False)
    ssh_run(node, "systemctl restart chronyd", check=False)

    if not is_server:
        time.sleep(2)
        ssh_run(node, "chronyc makestep", check=False)


def configure_ntp(node, is_server, server_ip, allow_network):
    """配置 ntp，主要用于 RHEL7.6。"""
    network = ipaddress.ip_network(allow_network, strict=False)

    if is_server:
        conf = """# Generated by sync_clock.py
# ntp 服务端：无外网时以本地时钟作为时钟源
driftfile /var/lib/ntp/drift
restrict default nomodify notrap nopeer
restrict 127.0.0.1
restrict ::1
restrict %s mask %s nomodify notrap
server 127.127.1.0
fudge 127.127.1.0 stratum 10
disable monitor
""" % (network.network_address, network.netmask)
    else:
        conf = """# Generated by sync_clock.py
# ntp 客户端：同步第一台服务器
driftfile /var/lib/ntp/drift
restrict 127.0.0.1
restrict ::1
server %s iburst
disable monitor
""" % server_ip

    write_remote_file(node, "/etc/ntp.conf", conf)

    # 硬件时钟同步
    ssh_run(
        node,
        "grep -q '^SYNC_HWCLOCK=yes' /etc/sysconfig/ntpd 2>/dev/null || "
        "echo 'SYNC_HWCLOCK=yes' >> /etc/sysconfig/ntpd",
        check=False,
    )

    # 避免与 chronyd 冲突
    ssh_run(node, "systemctl stop chronyd 2>/dev/null || true", check=False)
    ssh_run(node, "systemctl disable chronyd 2>/dev/null || true", check=False)

    ssh_run(node, "systemctl enable ntpd", check=False)

    if not is_server:
        # 初始快速同步：先停 ntpd，再 ntpdate，再启动 ntpd
        ssh_run(node, "systemctl stop ntpd 2>/dev/null || true", check=False)
        ssh_run(node, "ntpdate -u %s" % server_ip, check=False)

    ssh_run(node, "systemctl restart ntpd", check=False)
    ssh_run(node, "hwclock -w", check=False)


def configure_firewall(node, close_firewall=False):
    """防火墙处理：默认放行 ntp 服务；如果指定 --close-firewall 则关闭 firewalld。"""
    if close_firewall:
        ssh_run(
            node,
            "systemctl stop firewalld 2>/dev/null || true; "
            "systemctl disable firewalld 2>/dev/null || true",
            check=False,
        )
    else:
        ssh_run(
            node,
            "systemctl is-active firewalld >/dev/null 2>&1 && "
            "firewall-cmd --permanent --add-service=ntp && "
            "firewall-cmd --reload || true",
            check=False,
        )


def set_timezone(node, timezone):
    """设置时区并开启 NTP。"""
    ssh_run(node, "timedatectl set-timezone %s" % timezone, check=False)
    ssh_run(node, "timedatectl set-ntp yes", check=False)


def verify(node, sys_type):
    """验证节点时间同步状态。"""
    print("\n----- 验证节点 %s (%s) -----" % (node.hostname, node.ip))
    ssh_run(node, "date; timedatectl", check=False)

    if sys_type == "chrony":
        ssh_run(node, "chronyc sources -v; chronyc tracking", check=False)
    else:
        ssh_run(node, "ntpq -p; ntpstat", check=False)


def main():
    parser = argparse.ArgumentParser(description="多节点 NTP/Chrony 时钟同步配置脚本")
    parser.add_argument("--host-ini", default="host.ini", help="host.ini 路径，默认 host.ini")
    parser.add_argument("--server", help="指定作为时钟源的节点 section 或 hostname")
    parser.add_argument("--timezone", default="Asia/Shanghai", help="时区，默认 Asia/Shanghai")
    parser.add_argument(
        "--close-firewall",
        action="store_true",
        help="关闭目标机 firewalld（生产慎用）",
    )
    args = parser.parse_args()

    if not os.path.exists(args.host_ini):
        print("错误：找不到 host.ini: %s" % args.host_ini)
        sys.exit(1)

    cp, nodes = read_host_ini(args.host_ini)
    if not nodes:
        print("错误：host.ini 中没有节点配置")
        sys.exit(1)

    try:
        server_node = choose_server(cp, nodes, args.server)
    except Exception as e:
        print("错误：%s" % e)
        sys.exit(1)

    # 设置角色
    for n in nodes:
        n.role = "server" if n is server_node else "client"

    # 允许网段
    allow_network = cp.get("global", "allow_network", fallback=None)
    if not allow_network:
        try:
            allow_network = str(ipaddress.ip_network("%s/24" % server_node.ip, strict=False))
        except Exception:
            allow_network = "0.0.0.0/0"

    print("时钟源节点: %s (%s)" % (server_node.hostname, server_node.ip))
    print("允许网段: %s" % allow_network)
    print("节点列表: %s" % [n.hostname for n in nodes])

    # 检查 sshpass
    if any(n.password for n in nodes) and not shutil.which("sshpass"):
        print("错误：host.ini 中配置了 password，但本机未找到 sshpass。")
        print("请安装 sshpass，或配置 SSH 免密登录并将 password 留空。")
        sys.exit(1)

    for node in nodes:
        print("\n===== 开始配置 %s (%s) role=%s =====" % (
            node.hostname,
            node.ip,
            node.role,
        ))

        try:
            ssh_run(node, "echo SSH_OK", check=True)
        except Exception as e:
            print("[%s] SSH 连接失败: %s，跳过该节点" % (node.hostname, e))
            continue

        set_timezone(node, args.timezone)

        sys_type = detect_system(node)
        print("[%s] 使用时间服务: %s" % (node.hostname, sys_type))

        if sys_type == "chrony":
            ensure_package(node, "chrony")
            configure_chrony(node, node is server_node, server_node.ip, allow_network)
        else:
            ensure_package(node, "ntp")
            configure_ntp(node, node is server_node, server_node.ip, allow_network)

        configure_firewall(node, close_firewall=args.close_firewall)
        verify(node, sys_type)

    print("\n===== 所有节点配置流程结束 =====")
    print("提示：NTP/Chrony 同步可能需要 1-5 分钟，请稍后再次验证：")
    print("  RHEL7 ntp   : ntpq -p; ntpstat")
    print("  RHEL8 chrony: chronyc sources -v; chronyc tracking")


if __name__ == "__main__":
    main()
