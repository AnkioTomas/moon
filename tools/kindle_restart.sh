#!/usr/bin/env bash
# 重启真机 KOReader，不丢阅读状态。
#
# Kindle 上 KOReader 不处理 SIGTERM，直接杀会丢掉未落盘的 sidecar（进度、段评关联等）和插件状态；
# koreader.sh 只在退出码 85 时自动重启，杀掉后会回原生界面。所以：
# 模拟电源键休眠一次（KOReader 休眠前 flushSettings + 插件 onSuspend 落盘）→ 再按一次唤醒 →
# TERM 退出 → 等旧 koreader.sh（主 reader.lua 的父进程）退干净 → 按 KUAL 方式拉起。
# 设备端脚本脱离 ssh 会话执行（SSH 服务本身跑在 KOReader 里）；约 40 秒后恢复。
#
# 用法：tools/kindle_restart.sh [host]（默认 192.168.100.124，端口 2222）
set -euo pipefail
HOST="${1:-192.168.100.124}"

ssh -p 2222 "root@$HOST" 'cat > /tmp/ko_restart.sh && { setsid nohup sh /tmp/ko_restart.sh >/tmp/ko_restart.log 2>&1 </dev/null & }' <<'EOF'
cd /
waitState() {
    i=0
    while [ "$(lipc-get-prop com.lab126.powerd state)" != "$1" ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
    echo "state $1 after $i s"
}
P=$(awk '{print $4}' /proc/$(pgrep -o reader.lua)/stat)
lipc-set-prop -i com.lab126.powerd powerButton 1; waitState screenSaver; sleep 3
lipc-set-prop -i com.lab126.powerd powerButton 1; waitState active; sleep 3
killall -TERM reader.lua
i=0; while [ -d /proc/$P ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
echo "old exited after $i s"
# /mnt/us 是 FUSE（fsp），唤醒 + 原生框架恢复期间会短暂 Stale file handle。
i=0; until cd /mnt/us/koreader 2>/dev/null || [ $i -ge 30 ]; do sleep 1; i=$((i+1)); done
echo "cd after $i s"
exec ./koreader.sh --kual
EOF
echo "restarting KOReader on $HOST (log: /tmp/ko_restart.log)"
