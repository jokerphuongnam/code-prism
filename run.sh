#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="swift-prism-dev"
BIN_TARGET="extension/bin/swift-prism-analyzer"
BUILD_MODE=""

print_step() {
    printf "\n\033[1;36m▸ %s\033[0m\n" "$1"
}

print_done() {
    printf "\033[1;32m✓ %s\033[0m\n" "$1"
}

print_warn() {
    printf "\033[1;33m⚠ %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[1;31m✗ %s\033[0m\n" "$1" >&2
}

docker_available() {
    command -v docker &>/dev/null || return 1
    docker info &>/dev/null 2>&1 || return 1
    return 0
}

cleanup_old_containers() {
    print_step "Cleaning up old containers"
    docker compose down --remove-orphans 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    print_done "Old containers removed"
}

build_with_docker() {
    BUILD_MODE="docker"
    cleanup_old_containers

    print_step "Building and starting containers (Apple Silicon compatible)"
    docker compose up --build -d

    print_step "Waiting for container to be ready"
    for i in $(seq 1 60); do
        if docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
            break
        fi
        if [ "$i" -eq 60 ]; then
            print_error "Container failed to start within 60 seconds"
            docker compose logs --tail=20
            return 1
        fi
        sleep 1
    done
    print_done "Container is running"

    print_step "Extracting Swift binary from container"
    mkdir -p extension/bin
    docker cp "$CONTAINER_NAME:/app/extension/bin/swift-prism-analyzer" "$BIN_TARGET" 2>/dev/null || {
        print_error "Binary extraction failed"
        return 1
    }
    chmod +x "$BIN_TARGET"
    print_done "Binary synced to $BIN_TARGET"

    print_step "Syncing built extension assets from container"
    mkdir -p extension/out extension/dist-webview

    docker cp "$CONTAINER_NAME:/app/extension/out/." extension/out/ 2>/dev/null && \
        print_done "Extension host JS synced" || \
        print_warn "Extension host JS sync failed — will build locally"

    docker cp "$CONTAINER_NAME:/app/extension/dist-webview/." extension/dist-webview/ 2>/dev/null && \
        print_done "React webview bundle synced" || \
        print_warn "Webview bundle sync failed — will build locally"

    return 0
}

build_native() {
    BUILD_MODE="native"

    print_step "Building Swift Core natively"
    if ! command -v swift &>/dev/null; then
        print_error "Swift toolchain not found. Install Swift 5.10+ from swift.org or use Docker."
        exit 1
    fi

    local swift_version
    swift_version=$(swift --version 2>&1 | head -1)
    print_done "Found: $swift_version"

    cd core && swift build -c release 2>&1 | tail -5 && cd ..

    mkdir -p extension/bin
    cp core/.build/release/swift-prism-analyzer "$BIN_TARGET"
    chmod +x "$BIN_TARGET"
    print_done "Binary built and placed at $BIN_TARGET"

    print_step "Installing extension dependencies"
    if ! command -v node &>/dev/null; then
        print_error "Node.js not found. Install Node 18+ from nodejs.org."
        exit 1
    fi

    cd extension
    npm install 2>&1 | tail -3
    cd webview
    npm install 2>&1 | tail -3
    cd ../..

    print_step "Compiling extension and webview"
    cd extension
    npx tsc -p ./ 2>&1
    cd webview
    npx tsc -b 2>&1
    npx vite build 2>&1 | tail -5
    cd ../..

    print_done "Extension and webview built"

    return 0
}

verify_binary() {
    print_step "Verifying binary"
    if [ ! -f "$BIN_TARGET" ]; then
        print_error "Binary not found at $BIN_TARGET"
        return 1
    fi

    chmod +x "$BIN_TARGET"

    if "$BIN_TARGET" 2>&1 | head -1 | grep -qi "usage\|error\|no input\|No input"; then
        print_done "Binary is functional"
    else
        local arch
        arch=$(file "$BIN_TARGET" 2>/dev/null | grep -oE "arm64|x86_64|Mach-O|ELF" | head -1)
        if [ -n "$arch" ]; then
            print_warn "Binary exists ($arch) — may need matching platform to execute"
        else
            print_done "Binary exists"
        fi
    fi
}

generate_context() {
    print_step "Detecting project type and generating prism-context.json"
    local WORKSPACE_ROOT="${1:-$SCRIPT_DIR}"
    local CONTEXT_OUT="$WORKSPACE_ROOT/prism-context.json"

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
        local FLAGS="--workspace $WORKSPACE_ROOT --scan-targets --public-only-external --context --output $CONTEXT_OUT"
        $BIN_TARGET $FLAGS $SWIFT_FILES 2>/dev/null && \
            print_done "prism-context.json written to $CONTEXT_OUT" || \
            print_warn "Context generation skipped (non-critical — extension will generate on analyze)"
    else
        print_warn "Skipped context generation (no .swift files or binary not executable on this platform)"
    fi
}

print_banner() {
    printf "\n\033[1;35m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
    printf "\033[1;35m 💎 SwiftPrism is ready!  \033[0m\n"
    printf "\033[1;35m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n"
    printf "  Build mode: \033[1m%s\033[0m\n\n" "$BUILD_MODE"
    printf "  \033[1mLaunch the 3D Graph:\033[0m\n"
    printf "    1. Open this folder in VS Code\n"
    printf "    2. Press \033[1mF5\033[0m → select \033[1m'Run SwiftPrism Extension'\033[0m\n"
    printf "    3. Click the 💎 icon in the Activity Bar\n"
    printf "    4. Click \033[1m▶ Analyze Project\033[0m\n\n"
    printf "  \033[1mCLI commands:\033[0m\n"
    printf "    $BIN_TARGET --workspace . --scan-targets *.swift\n"
    printf "    $BIN_TARGET --find-dependents-of \"HomeViewModel\" --workspace . *.swift\n\n"
    if [ "$BUILD_MODE" = "docker" ]; then
        printf "  \033[1mStop container:\033[0m  docker compose down\n\n"
    fi
}

printf "\033[1;35m💎 SwiftPrism Build System\033[0m\n"

if docker_available; then
    print_done "Docker detected and running"
    if build_with_docker; then
        verify_binary
        generate_context "$@"
        print_banner
        exit 0
    else
        print_warn "Docker build failed — falling back to native build"
    fi
else
    print_warn "Docker not available — using native build"
fi

build_native
verify_binary
generate_context "$@"
print_banner
