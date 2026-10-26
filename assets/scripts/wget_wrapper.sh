#!/bin/bash
REAL_WGET="/usr/bin/wget"
[ ! -x "$REAL_WGET" ] && REAL_WGET="wget"

if [ "${MAIBOT_DIRECT_NETWORK:-0}" = "1" ]; then
    exec "$REAL_WGET" "$@"
fi

HAS_GITHUB_URL=0
for arg in "$@"; do
    if [[ "$arg" =~ ^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com)/.* ]] && \
       [[ ! "$arg" =~ ghfast\.top ]] && [[ ! "$arg" =~ gh-proxy\.com ]] && [[ ! "$arg" =~ ghproxy ]]; then
        HAS_GITHUB_URL=1
        break
    fi
done

if [ "$HAS_GITHUB_URL" -eq 0 ]; then
    exec "$REAL_WGET" "$@"
fi

MIRRORS=("https://ghfast.top/" "https://gh-proxy.com/" "https://mirror.ghproxy.com/")
for prefix in "${MIRRORS[@]}"; do
    ARGS=()
    for arg in "$@"; do
        if [[ "$arg" =~ ^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com)/.* ]] && \
           [[ ! "$arg" =~ ghfast\.top ]] && [[ ! "$arg" =~ gh-proxy\.com ]] && [[ ! "$arg" =~ ghproxy ]]; then
            ARGS+=("${prefix}${arg}")
        else
            ARGS+=("$arg")
        fi
    done
    if "$REAL_WGET" "${ARGS[@]}"; then
        exit 0
    fi
done

exec "$REAL_WGET" "$@"
