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

# 设备端脚本必须脱离 ssh 会话（SSH 跑在 KOReader 里，杀 reader.lua 会带走同会话子进程）。
# 优先 setsid 新建会话；老机型（K3）连 setsid / nohup 都没有，退回纯 POSIX：
# ( ... & ) 让子 shell 立即退出、任务被 init 收养，trap '' HUP 忽略挂断，父进程 TERM 后仍存活。
ssh -p 2222 "root@$HOST" 'cat > /tmp/ko_restart.sh && if command -v setsid >/dev/null 2>&1; then setsid sh /tmp/ko_restart.sh >/tmp/ko_restart.log 2>&1 </dev/null & else ( trap "" HUP; sh /tmp/ko_restart.sh >/tmp/ko_restart.log 2>&1 </dev/null & ); fi' <<'EOF'
cd /
waitState() {
    i=0
    while [ "$(lipc-get-prop com.lab126.powerd state)" != "$1" ] && [ $i -lt 20 ]; do sleep 1; i=$((i+1)); done
    echo "state $1 after $i s"
}
READER=$(pgrep -o reader.lua) || exit 1
P=$(awk '{print $4}' /proc/$READER/stat)
lipc-set-prop -i com.lab126.powerd powerButton 1; waitState screenSaver; sleep 3
lipc-set-prop -i com.lab126.powerd powerButton 1; waitState active; sleep 3
kill -TERM "$READER"
i=0; while [ -d /proc/$P ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
echo "old exited after $i s"
# /mnt/us 是 FUSE（fsp），唤醒 + 原生框架恢复期间会短暂 Stale file handle。
i=0; until cd /mnt/us/koreader 2>/dev/null || [ $i -ge 30 ]; do sleep 1; i=$((i+1)); done
echo "cd after $i s"
exec ./koreader.sh --kual
EOF
echo "restarting KOReader on $HOST (log: /tmp/ko_restart.log)"
