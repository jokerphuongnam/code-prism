#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="swift-prism-dev"
BIN_TARGET="extension/bin/swift-prism-analyzer"

print_step() {
    printf "\n\033[1;36m▸ %s\033[0m\n" "$1"
}

print_done() {
    printf "\033[1;32m✓ %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2
}

print_step "Building and starting containers"
docker compose up --build -d

print_step "Waiting for container to be ready"
for i in $(seq 1 30); do
    if docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        print_error "Container failed to start within 30 seconds"
        docker compose logs
        exit 1
    fi
    sleep 1
done
print_done "Container is running"

print_step "Extracting Swift binary from container"
docker cp "$CONTAINER_NAME:/app/extension/bin/swift-prism-analyzer" "$BIN_TARGET" 2>/dev/null || true
if [ -f "$BIN_TARGET" ]; then
    chmod +x "$BIN_TARGET"
    print_done "Binary synced to $BIN_TARGET"
else
    print_error "Binary extraction failed — building locally as fallback"
    if command -v swift &>/dev/null; then
        cd core && swift build -c release && cd ..
        cp core/.build/release/swift-prism-analyzer "$BIN_TARGET"
        chmod +x "$BIN_TARGET"
        print_done "Binary built locally"
    else
        print_error "Swift toolchain not found. Install Swift 5.10+ or use the container."
        exit 1
    fi
fi

print_step "Syncing built extension assets from container"
mkdir -p extension/out extension/dist-webview

docker cp "$CONTAINER_NAME:/app/extension/out/." extension/out/ 2>/dev/null && \
    print_done "Extension host JS synced" || \
    print_error "Extension host JS sync failed — run 'cd extension && npm run compile' locally"

docker cp "$CONTAINER_NAME:/app/extension/dist-webview/." extension/dist-webview/ 2>/dev/null && \
    print_done "React webview bundle synced" || \
    print_error "Webview bundle sync failed — run 'cd extension/webview && npm run build' locally"

print_step "Verifying binary"
if "$BIN_TARGET" 2>&1 | head -1 | grep -qi "usage\|error\|no input"; then
    print_done "Binary is functional"
else
    file "$BIN_TARGET" 2>/dev/null || true
    print_done "Binary exists (cross-platform — test inside container if on macOS)"
fi

print_step "Detecting project type and generating prism-context.json"
WORKSPACE_ROOT="${1:-$SCRIPT_DIR}"
CONTEXT_OUT="$WORKSPACE_ROOT/prism-context.json"

detect_and_scan() {
    local FLAGS="--workspace $WORKSPACE_ROOT --scan-targets --public-only-external --context --output $CONTEXT_OUT"

    if [ -f "$WORKSPACE_ROOT/Package.swift" ]; then
        printf "  Project type: \033[1mSwift Package\033[0m\n"
    elif ls "$WORKSPACE_ROOT"/*.xcodeproj 1>/dev/null 2>&1 || ls "$WORKSPACE_ROOT"/*.xcworkspace 1>/dev/null 2>&1; then
        printf "  Project type: \033[1mXcode Project\033[0m\n"
    else
        printf "  Project type: \033[1mStandalone Swift files\033[0m\n"
    fi

    local SWIFT_FILES
    SWIFT_FILES=$(find "$WORKSPACE_ROOT" -name "*.swift" \
        -not -path "*/.build/*" \
        -not -path "*/DerivedData/*" \
        -not -path "*/Pods/*" \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" \
        -not -path "*/Carthage/*" \
        2>/dev/null || true)

    if [ -n "$SWIFT_FILES" ] && [ -x "$BIN_TARGET" ]; then
        $BIN_TARGET $FLAGS $SWIFT_FILES 2>/dev/null && \
            print_done "prism-context.json written to $CONTEXT_OUT" || \
            print_error "Context generation failed (non-critical — extension will generate on analyze)"
    else
        print_error "Skipped context generation (no .swift files or binary not executable on this platform)"
    fi
}

detect_and_scan

printf "\n\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
printf "\033[1;32m SwiftPrism is ready!\033[0m\n"
printf "\033[1;33m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n"
printf "  To launch the extension:\n"
printf "    1. Open VS Code in this folder\n"
printf "    2. Press \033[1mF5\033[0m → select \033[1m'Run SwiftPrism Extension'\033[0m\n\n"
printf "  CLI commands:\n"
printf "    \033[1mAnalyze:\033[0m    $BIN_TARGET --workspace . --scan-targets *.swift\n"
printf "    \033[1mContext:\033[0m    $BIN_TARGET --workspace . --scan-targets --context --output prism-context.json\n"
printf "    \033[1mDependents:\033[0m $BIN_TARGET --workspace . --scan-targets --find-dependents-of \"HomeViewModel\"\n\n"
printf "  To stop the container:\n"
printf "    docker compose down\n\n"
