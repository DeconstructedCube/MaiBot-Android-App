#!/bin/bash
# Unified Git operations script for MaiBot container management
set -e

REPO_PATH="${MAIBOT_REPO_PATH:-/root/MaiBot}"
ACTION="$1"
TARGET="$2"

cd "$REPO_PATH"
git config --global --add safe.directory "*" 2>/dev/null || true
git config --system --remove-section url."https://ghfast.top/https://github.com/" 2>/dev/null || true
git config --global --remove-section url."https://ghfast.top/https://github.com/" 2>/dev/null || true
git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true

sync_uv_if_present() {
    if [ -f /root/.local/bin/uv ]; then
        echo -e "\033[36m[UV]\033[0m 检查 Python 依赖..."
        /root/.local/bin/uv sync --no-progress
    fi
}

stash_if_dirty() {
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        git stash push -m "maibot-auto-update" 2>/dev/null || true
    fi
}
case "$ACTION" in
    current_ref)
        git symbolic-ref --short HEAD 2>/dev/null || git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD 2>/dev/null
        ;;
    fetch_branches)
        git -c gc.auto=0 fetch origin "+refs/heads/*:refs/remotes/origin/*" --prune 2>/dev/null || \
        git -c gc.auto=0 fetch --all --prune 2>/dev/null || \
        git -c gc.auto=0 fetch origin 2>/dev/null || true
        ;;
    fetch_tags)
        git -c gc.auto=0 fetch --tags --force origin 2>/dev/null || \
        git -c gc.auto=0 fetch --tags --prune 2>/dev/null || \
        git -c gc.auto=0 fetch origin 2>/dev/null || true
        ;;
    pull)
        echo -e "\033[36m[GIT]\033[0m 同步远程分支与标签..."
        git -c gc.auto=0 fetch origin "+refs/heads/*:refs/remotes/origin/*" --tags --prune 2>/dev/null || \
        git -c gc.auto=0 fetch --all --prune 2>/dev/null || true
        stash_if_dirty
        echo -e "\033[36m[GIT]\033[0m 拉取最新代码..."
        git -c gc.auto=0 pull --rebase=false || git -c gc.auto=0 pull --rebase=false origin main || true
        sync_uv_if_present
        ;;
    switch_branch)
        echo -e "\033[36m[GIT]\033[0m 抓取远程分支 $TARGET..."
        git -c gc.auto=0 fetch origin "+refs/heads/$TARGET:refs/remotes/origin/$TARGET" 2>/dev/null || \
        git -c gc.auto=0 fetch origin "$TARGET" 2>/dev/null || \
        git -c gc.auto=0 fetch origin "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true
        stash_if_dirty
        echo -e "\033[36m[GIT]\033[0m 检出分支 $TARGET..."
        if git show-ref --verify --quiet "refs/heads/$TARGET"; then
            git -c gc.auto=0 checkout "$TARGET" || git -c gc.auto=0 checkout -f "$TARGET"
        elif git show-ref --verify --quiet "refs/remotes/origin/$TARGET"; then
            git -c gc.auto=0 checkout -b "$TARGET" --track "origin/$TARGET" 2>/dev/null || \
            git -c gc.auto=0 checkout -B "$TARGET" "origin/$TARGET" || \
            git -c gc.auto=0 checkout -f "$TARGET"
        else
            echo -e "\033[31m[错误]\033[0m 未在本地或远程找到分支 $TARGET" >&2
            exit 1
        fi
        echo -e "\033[36m[GIT]\033[0m 同步分支最新提交..."
        git -c gc.auto=0 pull --rebase=false origin "$TARGET" 2>/dev/null || git -c gc.auto=0 pull --rebase=false 2>/dev/null || true
        sync_uv_if_present
        ;;
    switch_tag)
        echo -e "\033[36m[GIT]\033[0m 抓取标签 $TARGET..."
        git -c gc.auto=0 fetch --tags --force origin 2>/dev/null || \
        git -c gc.auto=0 fetch origin "refs/tags/$TARGET:refs/tags/$TARGET" 2>/dev/null || \
        git -c gc.auto=0 fetch --tags 2>/dev/null || true
        stash_if_dirty
        echo -e "\033[36m[GIT]\033[0m 检出标签: $TARGET..."
        git -c gc.auto=0 checkout "tags/$TARGET" || git -c gc.auto=0 checkout -f "tags/$TARGET" || git -c gc.auto=0 checkout "$TARGET"
        sync_uv_if_present
        ;;
    *)
        echo "Unknown git action: $ACTION" >&2
        exit 1
        ;;
esac
