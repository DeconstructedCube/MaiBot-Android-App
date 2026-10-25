#!/bin/bash
REAL_CURL="/usr/bin/curl"
[ ! -x "$REAL_CURL" ] && REAL_CURL="curl"

ARGS=()
for arg in "$@"; do
    if [[ "$arg" =~ ^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com)/.* ]] && [[ ! "$arg" =~ ghfast\.top ]] && [[ ! "$arg" =~ gh-proxy\.com ]] && [[ ! "$arg" =~ ghproxy ]]; then
        ARGS+=("https://ghfast.top/$arg")
    else
        ARGS+=("$arg")
    fi
done

exec "$REAL_CURL" "${ARGS[@]}"
