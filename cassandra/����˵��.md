# Cassandra 4.0 一键部署脚本使用说明

配套脚本：`cassandra-deploy.sh`（依据《cassandra 终章》2.1–2.5 节实施步骤整理）

## 一、脚本做了什么

在 **CentOS/RHEL 7** 上把一台裸机自动配置为 Cassandra 4.0 集群节点，覆盖终章全部步骤：

| # | 阶段 | 内容 |
|---|------|------|
| 1 | preflight | 检查 root、tar 命令、安装包、识别本机在拓扑中的身份 |
| 2 | hosts | `/etc/hosts` 写入全部集群主机名（标记块，可重复刷新） |
| 3 | storage | 挂载检查、创建 `/data/soft` 等目录（LVM 见下，默认不自动建盘） |
| 4 | user | 创建组 `cassandra(60001)`、用户 `cassandra(61001)`、目录授权 |
| 5 | boot | 设置开机级别 `multi-user.target` |
| 6 | locale | cassandra 用户 `LANG=en_US.UTF8` |
| 7 | limits | 写入 `/etc/security/limits.d/cassandra.conf`（nofile/nproc/memlock） |
| 8 | sysctl | 写入 `/etc/sysctl.d/99-cassandra.conf` 并立即生效（终章全部内核参数） |
| 9 | timezone | 时区设为 `Asia/Shanghai` |
| 10 | security | SELinux 禁用、firewalld 停止并禁用（记录原状态，回滚可恢复） |
| 11 | vimrc | cassandra 用户 `.vimrc` 配置 F10 paste / F11 nopaste |
| 12 | thp | 透明大页 THP=never、`zone_reclaim_mode=0`（运行时 + rc.local 开机生效） |
| 13 | ntp | 安装 ntp、停用 chronyd（不卸载）；首节点为时钟源，其余节点向它同步 |
| 14 | jdk | 解压 JDK8 到 `/data/jdk1.8.0_261`（无 tar 包时回退 yum 安装 openjdk） |
| 15 | cassandra | 解压 Cassandra 4.0.7 到 `/data/cassandra`，创建 data/commitlog/saved_caches/logs |
| 16 | cassandra_config | `cassandra.yaml` 全部必改项 + 调优项、JVM 关闭 CMS 启用 G1、机架感知文件 |
| 17 | profile | cassandra 用户 `JAVA_HOME`/`PATH`/`LANG` |
| 18 | systemd | 安装 `/etc/systemd/system/cassandra.service` 并 enable |
| 19 | start_verify | 非种子节点先等种子 7000 端口可达，再启动，等待 nodetool 就绪并打印状态 |

## 二、部署前准备

1. 六台机器网络互通，IP 与主机名按终章规划（默认 `192.168.1.61-66` / `xxxdata01-06`）。
2. 数据盘挂载到 `/data`（**强烈建议先手工做好 LVM/XFS 并写入 /etc/fstab**）。
   - 若希望脚本自动建盘：把脚本顶部 `ENABLE_LVM` 改为 `true` 并确认 `DEV_DISK=/dev/sdb` 无误（pvcreate 会清空该盘）。
3. 上传安装包到每台机器的 `/data/soft/`：
   - `jdk-8u261-linux-x64.tar.gz`（或其它 JDK8 tar 包，同步修改 `JDK_TARBALL`/`JDK_HOME_DIR`）
   - `apache-cassandra-4.0.7-bin.tar.gz`（脚本也会自动匹配 `/data/soft/apache-cassandra-*-bin.tar.gz`）
4. 确认 yum 源可用（安装 ntp；JDK 无 tar 包时也走 yum）。CentOS 7 自带 python2，cqlsh 依赖它。
5. 如拓扑与默认不同，修改脚本顶部 `CLUSTER_NODES`，每行格式：
   ```
   "IP 主机名 数据中心 机架 角色(seed/node) [ntp-master]"
   ```

## 三、执行方法

```bash
chmod +x cassandra-deploy.sh

# 部署前先自检（不需要 root，不修改系统，验证幂等编辑逻辑）
./cassandra-deploy.sh selftest

# 先在三台种子节点依次执行（61 -> 62 -> 63），每台 nodetool status 出现 UN 后再下一台
./cassandra-deploy.sh

# 再在普通节点执行（64 -> 65 -> 66）；脚本会自动等待种子节点 7000 端口可达
./cassandra-deploy.sh
```

其它命令：

```bash
./cassandra-deploy.sh status      # 查看本机各检查项的实际状态（PASS/DIFF）
./cassandra-deploy.sh stages      # 列出全部阶段
./cassandra-deploy.sh rollback            # 回滚最近一次部署（停服务、恢复配置，保留数据/软件）
./cassandra-deploy.sh rollback --purge    # 彻底回滚（连软件、数据目录、用户一并删除）
```

本机 IP 无法被自动识别时可用环境变量覆盖：
```bash
LOCAL_IP=192.168.1.66 LOCAL_DC=dc1 LOCAL_RACK=rack1 ./cassandra-deploy.sh
```

## 四、幂等性如何保证

- 所有修改都**先检查当前实际状态**：值已正确就跳过，不会重复追加；不正确才替换/补写。
- `/etc/hosts`、`.bash_profile`、`rc.local` 使用 `# >>> cassandra-deploy … >>>` 标记块，
  重复执行是“整块刷新”，不会产生重复行；扩容改了拓扑重跑即可刷新 hosts。
- yaml 标量项：已有活动配置则原地改值；只有注释默认值则取消注释并赋值；都没有才追加。
  `data_file_directories` 整块替换；seeds 行整行替换。
- 服务已运行且本次配置无变化时**不重启**；检测到配置变更才自动重启。
- 安装阶段检测到 `/data/cassandra/bin/cassandra` 存在即跳过解压。
- 可随时用 `status` 子命令对照实际状态；`selftest` 子命令在临时目录验证编辑器重复执行结果一致。

## 五、失败回滚如何工作

- 每次部署在 `/var/lib/cassandra-deploy/backup-时间戳/` 保存**所有被改文件的原始副本**和清单 `manifest`。
- 部署中途任何步骤 `die`（或 Ctrl+C）会**自动回滚**：停服务、撤 unit、按清单恢复原文件、
  恢复 SELinux/firewalld/chronyd 的原始状态。默认**保留数据目录和软件目录**，便于排错后直接重跑。
- 手工回滚：`./cassandra-deploy.sh rollback`（重复执行无害）。
- 彻底清除：`rollback --purge` 会删除 `/data/cassandra`、JDK 目录、cassandra 用户/组。
- **LVM（datavg/datalv）不会被自动删除**（防止误删数据盘），需要回收时按脚本提示手工执行
  `umount /data && lvremove -f /dev/datavg/datalv && vgremove -f datavg && pvremove -y <盘>`。
- 如需关闭失败自动回滚：把脚本顶部 `ON_ERROR_ROLLBACK=false`。

## 六、与终章操作的差异（为安全/幂等做的调整）

1. chrony 只**停用**（`systemctl disable --now chronyd`）不 `yum remove`，回滚可恢复。
2. limits 写入独立文件 `/etc/security/limits.d/cassandra.conf`，sysctl 写入
   `/etc/sysctl.d/99-cassandra.conf`，不再直接改主配置文件（语义等价、可干净回滚）。
3. LVM 默认不自动执行（破坏性操作），请手工建盘或显式打开 `ENABLE_LVM=true`。
4. Cassandra 安装目录为实体目录 `/data/cassandra`（终章为 mv 方式，未用软链接）；
   数据目录为 `/data/cassandra/{data,commitlog,saved_caches}`。
5. yaml/JVM 参数值与终章完全一致（num_tokens=16、seeds=61/62/63、并发 512/256/512、
   row_cache 32768MB、commitlog 32MB/4096MB、G1 的 500ms/70%/4+4 线程、gc.log 路径等）。

## 七、部署后验证

```bash
systemctl status cassandra
nodetool status                 # 全部节点应为 UN（Up/Normal）
tail -f /data/cassandra/logs/system.log
cqlsh 192.168.1.61 9042 -u cassandra -p cassandra
# 登录后立即修改默认超级用户密码（PasswordAuthenticator 已开启）
```

常见问题：
- 节点一直 J/DN：先确认种子节点已 UN、`/etc/hosts` 一致、7000/7001/9042 端口互通、时间已同步。
- 想看启动报错：前台 `su - cassandra -c '/data/cassandra/bin/cassandra -f'`，或 `journalctl -u cassandra -n 100`。
- 配置改错想重来：`rollback` 后重新 `deploy`；不要手工删除 data 目录后直接启动（会被当成空节点重新加入）。
- 扩容新节点：复制安装目录时务必清空 `data/commitlog/saved_caches`，加入后在旧节点执行 `nodetool cleanup`。
