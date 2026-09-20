#!/bin/bash
#=============================================================================
# 脚本名称：onekey_install_python3.sh
# 功能描述：RedHat/CentOS 系统一键安装 Python3（含源修复、依赖、编译、pip升级、失败回滚）
# 兼容系统：CentOS 7/8、RedHat 7/8
# 支持模式：在线自动下载 / 离线本地物料 双模式自动识别
#=============================================================================
set -euo pipefail

############################## 配置区（可按需修改） ##############################
# Python 版本号
PYTHON_VERSION="3.9.19"
# 最终安装路径
INSTALL_PREFIX="/usr/local/python-${PYTHON_VERSION}"
# 物料根目录（源码、依赖包、脚本统一存放）
SOURCE_DIR="/opt/python_install"
# 是否启用编译性能优化（yes/no）
ENABLE_OPTIMIZATION="yes"
# CentOS7 下 Python3.10+ 所需的 devtoolset 版本
DEVTOOLSET_VERSION="9"
# 是否自动修复 CentOS7 yum 源（在线模式生效）
FIX_CENTOS7_REPO="yes"
# 安装失败是否自动回滚清理
AUTO_ROLLBACK="yes"
################################################################################

#================================= 全局变量 =================================
BACKUP_DIR="${SOURCE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
INSTALL_PREFIX_EXISTED="no"
OS_TYPE="unknown"
OS_MAJOR="0"
NETWORK_AVAILABLE="no"
# 提取Python主副版本号，用于匹配get-pip分支
PYTHON_MAJOR_MINOR=$(echo "${PYTHON_VERSION}" | cut -d. -f1,2)

#================================= 工具函数 =================================
info()  { echo -e "\033[32m[INFO] \033[0m$*"; }
warn()  { echo -e "\033[33m[WARN] \033[0m$*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }

# 系统类型与版本检测
detect_os() {
    if grep -qi "centos" /etc/redhat-release; then
        OS_TYPE="centos"
    elif grep -qi "red hat" /etc/redhat-release; then
        OS_TYPE="rhel"
    else
        OS_TYPE="other"
    fi
    OS_MAJOR=$(rpm -q --qf "%{VERSION}" "$(rpm -q --whatprovides redhat-release)" | cut -d. -f1)
    info "检测到系统：${OS_TYPE} ${OS_MAJOR}"
}

# 网络连通性检测
check_network() {
    if curl -s --connect-timeout 3 https://www.baidu.com >/dev/null 2>&1; then
        NETWORK_AVAILABLE="yes"
        info "网络检测正常，启用在线安装模式"
    else
        NETWORK_AVAILABLE="no"
        warn "未检测到外网，启用离线安装模式"
    fi
}

# 安装前状态备份（用于回滚）
backup_original_state() {
    mkdir -p "${BACKUP_DIR}"
    info "备份安装前系统状态至 ${BACKUP_DIR}"
    
    # 备份原有 python3/pip3 软链接
    if [ -L /usr/bin/python3 ]; then
        cp -a /usr/bin/python3 "${BACKUP_DIR}/python3_link"
    fi
    if [ -L /usr/bin/pip3 ]; then
        cp -a /usr/bin/pip3 "${BACKUP_DIR}/pip3_link"
    fi
    
    # 记录安装目录是否已存在
    if [ -d "${INSTALL_PREFIX}" ]; then
        INSTALL_PREFIX_EXISTED="yes"
        warn "安装目录已存在，本次为覆盖安装，失败回滚将保留原目录"
    else
        INSTALL_PREFIX_EXISTED="no"
    fi
}

# 失败自动回滚函数
rollback() {
    echo ""
    warn "==================== 安装失败，执行自动回滚 ===================="
    
    if [ "${AUTO_ROLLBACK,,}" != "yes" ]; then
        error "已关闭自动回滚，请手动清理环境"
    fi

    # 1. 恢复系统软链接
    rm -f /usr/bin/python3 /usr/bin/pip3
    if [ -f "${BACKUP_DIR}/python3_link" ]; then
        cp -a "${BACKUP_DIR}/python3_link" /usr/bin/python3
    fi
    if [ -f "${BACKUP_DIR}/pip3_link" ]; then
        cp -a "${BACKUP_DIR}/pip3_link" /usr/bin/pip3
    fi
    info "已恢复原始软链接配置"

    # 2. 恢复 yum 源配置
    if [ -d "${BACKUP_DIR}/yum_repos_bak" ] && [ "$(ls -A "${BACKUP_DIR}/yum_repos_bak" 2>/dev/null)" ]; then
        rm -f /etc/yum.repos.d/CentOS-Archive.repo
        mv -f "${BACKUP_DIR}/yum_repos_bak"/*.repo /etc/yum.repos.d/ 2>/dev/null || true
        yum clean all >/dev/null 2>&1
        info "已恢复原始 yum 源配置"
    fi

    # 3. 清理编译源码目录
    if [ -d "${SOURCE_DIR}/Python-${PYTHON_VERSION}" ]; then
        rm -rf "${SOURCE_DIR}/Python-${PYTHON_VERSION}"
        info "已清理编译源码目录"
    fi

    # 4. 清理不完整安装目录（仅全新安装时删除）
    if [ "${INSTALL_PREFIX_EXISTED}" = "no" ] && [ -d "${INSTALL_PREFIX}" ]; then
        rm -rf "${INSTALL_PREFIX}"
        info "已清理不完整安装目录"
    fi

    # 5. 清理共享库配置
    rm -f /etc/ld.so.conf.d/python3-custom.conf
    ldconfig >/dev/null 2>&1
    info "已清理系统共享库配置"

    error "自动回滚完成，环境已恢复至安装前状态"
}

# CentOS7 全量 yum 源修复（彻底解决 mirrorlist 失效）
fix_centos7_yum_repos() {
    if [ "${OS_TYPE}" != "centos" ] || [ "${OS_MAJOR}" != "7" ]; then
        return 0
    fi
    if [ "${NETWORK_AVAILABLE}" != "yes" ] || [ "${FIX_CENTOS7_REPO,,}" != "yes" ]; then
        return 0
    fi

    # 已有可用源则跳过
    if yum repolist 2>/dev/null | grep -q "^base"; then
        info "检测到可用 base 源，跳过源修复"
        return 0
    fi

    info "CentOS7 官方源已下线，自动替换为阿里云归档镜像源..."

    # 备份原有全部 repo 文件
    mkdir -p "${BACKUP_DIR}/yum_repos_bak"
    mv -f /etc/yum.repos.d/*.repo "${BACKUP_DIR}/yum_repos_bak/" 2>/dev/null || true

    # 写入全量归档源配置
    cat > /etc/yum.repos.d/CentOS-Archive.repo << 'EOF'
[base]
name=CentOS-7 Base (Archive)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/x86_64/
gpgcheck=0
enabled=1

[updates]
name=CentOS-7 Updates (Archive)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/x86_64/
gpgcheck=0
enabled=1

[extras]
name=CentOS-7 Extras (Archive)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/x86_64/
gpgcheck=0
enabled=1

[sclo-rh]
name=CentOS-7 SCLo RH (Archive)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/rh/
gpgcheck=0
enabled=1

[sclo-sclo]
name=CentOS-7 SCLo sclo (Archive)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/sclo/x86_64/sclo/
gpgcheck=0
enabled=1
EOF

    yum clean all >/dev/null 2>&1
    yum makecache >/dev/null 2>&1
    info "CentOS7 全量归档源配置完成"
}

# 环境前置校验
env_check() {
    info "===== 执行环境校验 ====="
    
    # root权限校验
    if [ "$(id -u)" -ne 0 ]; then
        error "请使用 root 用户执行此脚本"
    fi
    
    # 系统类型校验
    if [ ! -f /etc/redhat-release ]; then
        error "此脚本仅支持 RedHat/CentOS 系列系统"
    fi
    
    mkdir -p "${SOURCE_DIR}/deps"
    unset PYTHONPATH PYTHONHOME

    # 已安装版本确认
    if [ -d "${INSTALL_PREFIX}" ]; then
        warn "检测到 ${INSTALL_PREFIX} 已存在，继续将覆盖该版本"
        read -rp "是否继续安装？(y/N): " confirm
        confirm_lower=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
        if [ "${confirm_lower}" != "y" ]; then
            info "用户取消安装"
            exit 0
        fi
    fi
}

#================================= 依赖安装 =================================
install_dependencies() {
    info "===== 安装编译依赖 ====="
    local deps_rpm_count
    deps_rpm_count=$(find "${SOURCE_DIR}/deps" -type f -name "*.rpm" | wc -l)

    # 优先本地 RPM 离线安装
    if [ "${deps_rpm_count}" -gt 0 ]; then
        info "检测到本地 ${deps_rpm_count} 个 RPM 依赖包，开始离线安装"
        local rpm_files
        rpm_files=$(find "${SOURCE_DIR}/deps" -type f -name "*.rpm")
        
        if yum localinstall -y --disablerepo=* ${rpm_files}; then
            info "本地依赖包安装完成"
        else
            warn "yum 本地安装异常，切换至 RPM 强制兼容模式"
            rpm -Uvh --replacefiles --replacepkgs --nodeps ${rpm_files}
            info "RPM 强制安装完成"
        fi
        return 0
    fi

    # 在线安装
    if [ "${NETWORK_AVAILABLE}" = "yes" ]; then
        info "在线安装基础编译依赖..."
        yum install -y zlib-devel bzip2-devel openssl-devel ncurses-devel \
            sqlite-devel readline-devel tk-devel gcc make xz libffi-devel \
            gdbm-devel expat-devel libuuid-devel
        
        # Python3.10+ 升级 GCC
        if [[ "${PYTHON_VERSION}" =~ ^3\.(1[0-9]|2[0-9])\. ]]; then
            info "Python 版本≥3.10，需要升级 GCC 编译环境"
            
            if [ "${OS_TYPE}" = "rhel" ] && [ "${OS_MAJOR}" = "7" ]; then
                if ! yum repolist 2>/dev/null | grep -qi "rhscl"; then
                    warn "RHEL7 未检测到 RHSCL 订阅源，自动关闭编译优化"
                    ENABLE_OPTIMIZATION="no"
                    return 0
                fi
            fi
            
            info "安装 devtoolset-${DEVTOOLSET_VERSION} 工具链..."
            yum install -y "devtoolset-${DEVTOOLSET_VERSION}-gcc" \
                "devtoolset-${DEVTOOLSET_VERSION}-gcc-c++" \
                "devtoolset-${DEVTOOLSET_VERSION}-binutils"
        fi
        info "在线依赖安装完成"
        return 0
    fi

    error "未找到本地依赖包且无网络连接！
    请将所有依赖 RPM 包上传至 ${SOURCE_DIR}/deps 目录后重试"
}

#================================= GCC 环境适配 =================================
setup_gcc_env() {
    if ! [[ "${PYTHON_VERSION}" =~ ^3\.(1[0-9]|2[0-9])\. ]]; then
        return 0
    fi

    info "===== GCC 编译环境适配 ====="
    local gcc_ver
    gcc_ver=$(gcc -dumpversion | cut -d. -f1)

    if [ "${gcc_ver}" -ge 8 ]; then
        info "当前 GCC 版本 $(gcc -dumpversion)，满足编译要求"
        return 0
    fi

    local devtoolset_path="/opt/rh/devtoolset-${DEVTOOLSET_VERSION}/enable"
    if [ -f "${devtoolset_path}" ]; then
        source "${devtoolset_path}"
        info "已启用 devtoolset-${DEVTOOLSET_VERSION}，当前 GCC 版本：$(gcc -dumpversion)"
    else
        warn "未找到 devtoolset-${DEVTOOLSET_VERSION}，自动关闭编译优化"
        ENABLE_OPTIMIZATION="no"
    fi
}

#================================= Python 源码处理 =================================
get_python_source() {
    info "===== 准备 Python 源码包 ====="
    cd "${SOURCE_DIR}"
    local source_file="Python-${PYTHON_VERSION}.tar.xz"

    if [ -f "${source_file}" ]; then
        info "本地已存在源码包：${source_file}，跳过下载"
        return 0
    fi

    if [ "${NETWORK_AVAILABLE}" = "yes" ]; then
        local download_url="https://www.python.org/ftp/python/${PYTHON_VERSION}/${source_file}"
        info "正在从官方下载源码包..."
        if ! wget -t 3 -T 30 "${download_url}"; then
            error "源码包下载失败！请手动下载后上传至 ${SOURCE_DIR}"
        fi
        info "源码包下载完成"
        return 0
    fi

    error "未找到本地源码包且无网络连接！
    请下载 Python-${PYTHON_VERSION}.tar.xz 上传至 ${SOURCE_DIR} 目录"
}

#================================= 编译安装（带失败降级） =================================
compile_install_python() {
    info "===== 编译安装 Python ${PYTHON_VERSION} ====="
    cd "${SOURCE_DIR}"

    # 解压
    info "解压源码包..."
    rm -rf "Python-${PYTHON_VERSION}"
    tar -xf "Python-${PYTHON_VERSION}.tar.xz"
    cd "Python-${PYTHON_VERSION}"

    # 配置编译参数
    info "配置编译选项（优化：${ENABLE_OPTIMIZATION}）..."
    local config_args="--prefix=${INSTALL_PREFIX} --with-system-ffi --enable-shared"
    if [ "${ENABLE_OPTIMIZATION,,}" = "yes" ]; then
        config_args="${config_args} --enable-optimizations"
    fi
    
    ./configure ${config_args}

    # 编译安装，失败自动降级重试
    info "开始编译安装，预计耗时 3-15 分钟，请耐心等待..."
    if make -j "$(nproc)"; then
        make install
    else
        if [ "${ENABLE_OPTIMIZATION,,}" = "yes" ]; then
            warn "开启优化编译失败，自动关闭优化参数重试..."
            make distclean
            ./configure --prefix="${INSTALL_PREFIX}" --with-system-ffi --enable-shared
            if make -j "$(nproc)"; then
                make install
            else
                error "二次编译均失败，请检查依赖包完整性或降低 Python 版本"
            fi
        else
            error "编译失败，请检查依赖包完整性"
        fi
    fi

    # 配置共享库
    info "配置系统共享库..."
    echo "${INSTALL_PREFIX}/lib" > /etc/ld.so.conf.d/python3-custom.conf
    ldconfig

    info "Python ${PYTHON_VERSION} 安装完成"
}

#================================= 全局软链接 =================================
create_symlinks() {
    info "===== 创建全局软链接 ====="
    rm -f /usr/bin/python3 /usr/bin/pip3
    ln -s "${INSTALL_PREFIX}/bin/python3" /usr/bin/python3
    ln -s "${INSTALL_PREFIX}/bin/pip3" /usr/bin/pip3

    if [ -x /usr/bin/python3 ] && [ -x /usr/bin/pip3 ]; then
        info "软链接创建成功：/usr/bin/python3、/usr/bin/pip3"
    else
        error "软链接创建失败，请检查安装路径"
    fi
}

#================================= pip 升级（自动匹配版本） =================================
upgrade_pip() {
    info "===== 配置升级 pip3 ====="
    cd "${SOURCE_DIR}"

    if [ ! -f "get-pip.py" ]; then
        if [ "${NETWORK_AVAILABLE}" = "yes" ]; then
            # 自动匹配对应Python版本的get-pip.py分支
            local get_pip_url="https://bootstrap.pypa.io/pip/${PYTHON_MAJOR_MINOR}/get-pip.py"
            info "下载 Python ${PYTHON_MAJOR_MINOR} 对应版本 get-pip.py..."
            if ! wget -t 3 -T 30 "${get_pip_url}"; then
                warn "get-pip.py 下载失败，跳过 pip 升级"
                return 0
            fi
        else
            warn "未找到 get-pip.py 且无网络，跳过 pip 升级"
            return 0
        fi
    fi

    python3 get-pip.py
    info "pip3 升级完成"
}

#================================= 结果验证 =================================
verify_install() {
    info "===== 安装结果验证 ====="
    echo "------------------------------------------------"
    echo " Python3 版本：$(python3 -V)"
    echo " pip3    版本：$(pip3 -V 2>/dev/null || echo '未配置')"
    echo " 安装路径：${INSTALL_PREFIX}"
    echo " 全局命令：python3、pip3"
    echo "------------------------------------------------"
    info "Python3 一键安装全部完成！"
    info "提示：系统默认 python 命令仍指向 Python2.7，互不影响"
}

#================================= 主流程 =================================
main() {
    env_check
    detect_os
    check_network
    backup_original_state

    # 注册失败回滚陷阱
    if [ "${AUTO_ROLLBACK,,}" = "yes" ]; then
        trap rollback ERR
    fi

    fix_centos7_yum_repos
    install_dependencies
    setup_gcc_env
    get_python_source
    compile_install_python
    create_symlinks
    upgrade_pip
    verify_install

    # 安装成功，取消回滚，清理临时文件
    trap - ERR
    info "清理编译临时文件..."
    rm -rf "${SOURCE_DIR}/Python-${PYTHON_VERSION}"
    info "安装备份文件保留在：${BACKUP_DIR}，确认无误后可手动删除"
    info "==================== 全部执行完成 ===================="
}

main "$@"
