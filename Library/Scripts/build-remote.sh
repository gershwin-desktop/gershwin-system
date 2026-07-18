#!/bin/sh
# build-remote.sh - Pull, checkout dev, build and install all dev-branch repos
#                    on the remote system.
# Usage: ./build-remote.sh [user@host]

set -e

REMOTE="${1:-admin@192.168.193}"
SRCDIR="/Developer/Library/Sources"

run() {
    ssh "$REMOTE" "$@"
}

echo "=== Connecting to $REMOTE ==="

# Collect repos that have a dev branch after pulling
DEV_REPOS=""
ALL_REPOS=""

echo ""
echo "=== Pulling all repos in $SRCDIR ==="
run "for d in ${SRCDIR}/*/; do
    name=\$(basename \"\$d\")
    echo \"Pulling \$name...\"
    sudo -E git -C \"\$d\" pull --all 2>&1 | tail -1
done"

echo ""
echo "=== Checking for dev branches ==="
DEV_REPOS=$(run "for d in ${SRCDIR}/*/; do
    name=\$(basename \"\$d\")
    has_dev=\$(sudo -E git -C \"\$d\" branch -r 2>/dev/null | grep -c 'origin/dev' || true)
    if [ \"\$has_dev\" -gt 0 ]; then echo \"\$name\"; fi
done")

if [ -z "$DEV_REPOS" ]; then
    echo "No repos with dev branch found."
    exit 0
fi

echo "Repos with dev branch:"
echo "$DEV_REPOS" | while read -r name; do echo "  $name"; done

echo ""
echo "=== Checking out dev branches ==="
run "for d in ${SRCDIR}/*/; do
    name=\$(basename \"\$d\")
    has_dev=\$(sudo -E git -C \"\$d\" branch -r 2>/dev/null | grep -c 'origin/dev' || true)
    if [ \"\$has_dev\" -gt 0 ]; then
        echo \"Checking out dev for \$name...\"
        cd \"\$d\"
        # Stash local changes if any
        if [ -n \"\$(sudo -E git -C . status --short 2>/dev/null)\" ]; then
            sudo -E git -C . stash 2>/dev/null || true
            STASHED=\"yes\"
        fi
        sudo -E git -C . checkout dev 2>&1
        sudo -E git -C . pull 2>&1 | tail -1
        # Restore stashed changes
        if [ \"\$STASHED\" = \"yes\" ]; then
            sudo -E git -C . stash pop 2>/dev/null || sudo -E git -C . checkout -- . 2>/dev/null || true
        fi
    fi
done"

echo ""
echo "=== Ensuring ownership for build ==="
echo "Fixing ownership so gmake works without sudo..."
run "for d in ${SRCDIR}/*/; do
    name=\$(basename \"\$d\")
    has_dev=\$(sudo -E git -C \"\$d\" branch -r 2>/dev/null | grep -c 'origin/dev' || true)
    if [ \"\$has_dev\" -gt 0 ]; then
        sudo chown -R admin:wheel \"\$d\" 2>/dev/null || true
    fi
done"

echo ""
echo "=== Building and installing dev-branch repos ==="
FAIL=""
run ". /System/Library/Makefiles/GNUstep.sh && for d in ${SRCDIR}/*/; do
    name=\$(basename \"\$d\")
    has_dev=\$(sudo -E git -C \"\$d\" branch -r 2>/dev/null | grep -c 'origin/dev' || true)
    if [ \"\$has_dev\" -gt 0 ]; then
        echo \"\"
        echo \"========== \$name ==========\"
        cd \"\$d\"
        if gmake; then
            echo \"Build OK\"
        else
            echo \"BUILD FAILED for \$name\"
            FAIL=\"\$name\"
        fi
        if sudo -E gmake install; then
            echo \"Install OK\"
        else
            echo \"INSTALL FAILED for \$name\"
            FAIL=\"\$name\"
        fi
        echo \"========== \$name DONE ==========\"
    fi
done
if [ -n \"\$FAIL\" ]; then
    echo \"\"
    echo \"FAILED: \$FAIL\"
    exit 1
fi"

echo ""
echo "=== All done ==="
