#!/bin/bash
REAL_WGET="/usr/bin/wget"
[ ! -x "$REAL_WGET" ] && REAL_WGET="wget"

ARGS=()
for arg in "$@"; do
    if [[ "$arg" =~ ^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com)/.* ]] && [[ ! "$arg" =~ ghfast\.top ]] && [[ ! "$arg" =~ gh-proxy\.com ]] && [[ ! "$arg" =~ ghproxy ]]; then
        ARGS+=("https://ghfast.top/$arg")
    else
        ARGS+=("$arg")
    fi
done

exec "$REAL_WGET" "${ARGS[@]}"
