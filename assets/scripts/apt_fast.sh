#!/bin/bash
# apt-fast: high-speed multi-connection wrapper for apt-get using aria2c
set -e
APT_REAL="/usr/bin/apt-get"
[ ! -x "$APT_REAL" ] && APT_REAL="apt-get"

if ! command -v aria2c >/dev/null 2>&1 || [ $# -eq 0 ]; then
    exec "$APT_REAL" "$@"
fi

case "$1" in
    install|reinstall|dist-upgrade|upgrade|build-dep|source)
        TMP_URI_FILE="/tmp/apt-fast-$$.uris"
        TMP_LIST_FILE="/tmp/apt-fast-$$.list"
        mkdir -p /var/cache/apt/archives/partial
        if "$APT_REAL" --print-uris -y "$@" > "$TMP_URI_FILE" 2>/dev/null; then
            awk '{
                gsub(/\047/, "", $1);
                gsub(/\047/, "", $2);
                if ($1 ~ /^https?:\/\// || $1 ~ /^ftp:\/\//) {
                    print $1;
                    print "  dir=/var/cache/apt/archives";
                    print "  out=" $2;
                }
            }' "$TMP_URI_FILE" > "$TMP_LIST_FILE"
            if [ -s "$TMP_LIST_FILE" ]; then
                echo -e "\e[32m[apt-fast]\e[0m 使用 aria2c 多连接并发下载软件包..."
                aria2c \
                    --no-conf \
                    --async-dns=false \
                    --disable-ipv6=true \
                    -i "$TMP_LIST_FILE" \
                    -j 8 \
                    -x 8 \
                    -s 8 \
                    -k 1M \
                    --allow-overwrite=true \
                    --auto-file-renaming=false \
                    --file-allocation=none \
                    --console-log-level=warn \
                    --summary-interval=0 \
                    --connect-timeout=10 \
                    --timeout=30 \
                    --max-tries=5 \
                    --retry-wait=2 \
                    --dir=/var/cache/apt/archives || true
            fi
            rm -f "$TMP_URI_FILE" "$TMP_LIST_FILE"
        fi
        exec "$APT_REAL" "$@"
        ;;
    *)
        exec "$APT_REAL" "$@"
        ;;
esac
