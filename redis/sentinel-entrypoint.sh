#!/bin/sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
: "${REDIS_SENTINEL_MASTER_NAME:=dbmaster}"

until redis-cli -h redis-master -a "$REDIS_PASSWORD" --no-auth-warning ping | grep -q PONG; do
  echo "waiting for redis-master"
  sleep 1
done

cat > /tmp/sentinel.conf <<EOF
port 26379
bind 0.0.0.0
protected-mode no
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor ${REDIS_SENTINEL_MASTER_NAME} redis-master 6379 2
sentinel auth-pass ${REDIS_SENTINEL_MASTER_NAME} ${REDIS_PASSWORD}
sentinel down-after-milliseconds ${REDIS_SENTINEL_MASTER_NAME} 5000
sentinel failover-timeout ${REDIS_SENTINEL_MASTER_NAME} 60000
sentinel parallel-syncs ${REDIS_SENTINEL_MASTER_NAME} 1
EOF

exec redis-server /tmp/sentinel.conf --sentinel
