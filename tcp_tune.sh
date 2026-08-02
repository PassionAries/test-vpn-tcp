#!/usr/bin/env bash
# TCP/BBR 调优脚本 —— 自动检测/自动备份/自动修改/一键回滚
# 适用: Debian 12.15, 1核心声明/2vCPU, 936Mi实际内存, 2G swapfile + zram 已配置
# 仅修改 TCP/网络相关 sysctl 参数
# 不修改: swap/zram、Xray、3x-ui、端口、防火墙
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }

CONF_FILE="/etc/sysctl.d/99-tcp-bbr-tune.conf"
BACKUP_DIR="/root/tcp_tune_backup_$(date +%Y%m%d_%H%M%S)"
SNAPSHOT_FILE="$BACKUP_DIR/sysctl_before.txt"
ROLLBACK_SCRIPT="$BACKUP_DIR/rollback.sh"

KEYS=(
  net.core.default_qdisc
  net.ipv4.tcp_congestion_control
  net.ipv4.tcp_rmem
  net.ipv4.tcp_wmem
  net.core.rmem_max
  net.core.wmem_max
  net.core.rmem_default
  net.core.wmem_default
  net.ipv4.tcp_mem
  net.ipv4.tcp_mtu_probing
  net.ipv4.tcp_slow_start_after_idle
  net.ipv4.tcp_fastopen
  net.ipv4.tcp_window_scaling
  net.ipv4.tcp_sack
  net.ipv4.tcp_notsent_lowat
  net.core.netdev_max_backlog
  net.core.somaxconn
  net.ipv4.tcp_max_syn_backlog
)

echo "============================================"
echo " TCP/BBR 调优脚本 - 环境检测"
echo "============================================"

echo "[*] 检测拥塞控制模块..."
if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -q bbr; then
  echo "    ✓ 检测到 bbr 可用"
else
  echo "    ! 未检测到 bbr，请确认 BBRv3 已正确安装，脚本仍会继续写入参数"
fi

echo "[*] 检测当前内存/swap状况（仅展示，不会修改）..."
free -h || true
echo "----"
swapon --show || true
echo

# ---- 记录检测结果，供参数计算参考，不做任何修改 ----
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_MB=$(( MEM_KB / 1024 ))
echo "[*] 检测到系统声明内存: ${MEM_MB}MB（实际可用以 free -h 为准，已知约936Mi）"
echo "[*] 本脚本不会修改 swap/zram 配置，沿用现有 2G swapfile + zram 设置"
echo

mkdir -p "$BACKUP_DIR"

echo "[*] 备份当前 sysctl 数值 -> $SNAPSHOT_FILE"
: > "$SNAPSHOT_FILE"
for k in "${KEYS[@]}"; do
  v=$(sysctl -n "$k" 2>/dev/null || echo "__UNSET__")
  echo "$k=$v" >> "$SNAPSHOT_FILE"
done

if [[ -f "$CONF_FILE" ]]; then
  cp -a "$CONF_FILE" "$BACKUP_DIR/99-tcp-bbr-tune.conf.orig"
  echo 1 > "$BACKUP_DIR/conf_existed.flag"
else
  echo 0 > "$BACKUP_DIR/conf_existed.flag"
fi

# 生成回滚脚本
cat > "$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -e
echo "[*] 正在回滚到调优前状态..."
if [[ "\$(cat "$BACKUP_DIR/conf_existed.flag")" == "1" ]]; then
  cp -a "$BACKUP_DIR/99-tcp-bbr-tune.conf.orig" "$CONF_FILE"
else
  rm -f "$CONF_FILE"
fi
while IFS='=' read -r k v; do
  [[ -z "\$k" || "\$v" == "__UNSET__" ]] && continue
  sysctl -w "\$k=\$v" >/dev/null 2>&1 || true
done < "$SNAPSHOT_FILE"
sysctl --system >/dev/null 2>&1 || true
echo "[✓] 已回滚，当前参数恢复到调优前状态"
echo "[i] swap/zram 未被本脚本触碰，无需回滚"
EOF
chmod +x "$ROLLBACK_SCRIPT"
ln -sf "$ROLLBACK_SCRIPT" /root/tcp_tune_rollback_latest.sh

echo "[*] 写入调优参数 -> $CONF_FILE"
cat > "$CONF_FILE" <<'EOF2'
# ===== TCP/BBR 调优（自动生成，勿手动改，回滚用 rollback.sh）=====
# 环境: 936Mi 实际内存 + 2G swapfile + zram，本文件不涉及内存/swap配置本身

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区上限：32MB，覆盖16MB测速点上限，满足高延迟单线程吞吐需求
# 注意：这是单socket允许的"上限"，非并发全部占满，真正的防OOM阀门是下面的tcp_mem
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 131072
net.core.wmem_default = 131072

# 全局TCP内存池（单位：4KB页），按实际936Mi可用内存核算，非理论1GB
# min=6000(约23MB) pressure=12000(约47MB，开始温和回收) max=18000(约70MB，硬顶)
# 目的：避免TCP缓冲区挤占内存导致进程被挤入swap，swap应作为最后兜底而非日常占用
net.ipv4.tcp_mem = 6000 12000 18000

# MTU黑洞探测：跨境/多跳线路上ICMP常被丢弃导致连接卡死重传，开启后可自动规避
net.ipv4.tcp_mtu_probing = 1

# 关闭空闲后重新慢启动：代理类间歇性流量场景下避免每次恢复都重新爬窗口
net.ipv4.tcp_slow_start_after_idle = 0

# 低风险增强项
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_notsent_lowat = 131072
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
EOF2

echo "[*] 应用参数..."
sysctl --system

echo
echo "============================================"
echo " [✓] 调优完成"
echo "============================================"
echo "备份目录     : $BACKUP_DIR"
echo "回滚命令     : bash $ROLLBACK_SCRIPT"
echo "             (或: bash /root/tcp_tune_rollback_latest.sh)"
echo
echo "调优后建议观察项："
echo "  1) free -h                      观察 swap used 是否持续上涨"
echo "  2) cat /proc/net/sockstat | grep TCP   观察 mem 是否逼近 18000"
echo "  3) 重跑一次 TcpQuality/NetQuality 检测脚本，对比调优前后数据"
echo "============================================"
