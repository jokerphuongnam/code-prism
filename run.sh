#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONTAINER_NAME="swift-prism-dev"
BIN_TARGET="extension/bin/swift-prism-analyzer"
BUILD_MODE=""
HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

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

run_clean() {
    print_step "Cleaning build artifacts"
    rm -rf core/.build
    rm -rf extension/bin/swift-prism-analyzer
    rm -rf extension/out
    rm -rf extension/dist-webview
    rm -rf extension/dist
    rm -f prism-context.json
    rm -rf .swiftprism
    print_done "All build artifacts removed"

    if docker_available; then
        docker compose down --remove-orphans --volumes 2>/dev/null || true
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        print_done "Docker containers and volumes removed"
    fi
}

docker_available() {
    command -v docker &>/dev/null || return 1
    docker info &>/dev/null 2>&1 || return 1
    return 0
}

build_swift_native() {
    print_step "Building Swift Core natively ($HOST_OS $HOST_ARCH)"
    if ! command -v swift &>/dev/null; then
        print_error "Swift toolchain not found. Install Swift 5.10+ from swift.org."
        return 1
    fi

    local swift_version
    swift_version=$(swift --version 2>&1 | head -1)
    print_done "Found: $swift_version"

    cd core && swift build -c release 2>&1 | tail -5
    local build_exit=$?
    cd ..

    if [ $build_exit -ne 0 ]; then
        print_error "Swift build failed"
        return 1
    fi

    mkdir -p extension/bin
    cp core/.build/release/swift-prism-analyzer "$BIN_TARGET"
    chmod +x "$BIN_TARGET"

    local bin_arch
    bin_arch=$(file "$BIN_TARGET" 2>/dev/null | grep -oE "arm64|x86_64" | head -1)
    print_done "Binary built: $BIN_TARGET ($bin_arch)"
    return 0
}

build_extension_native() {
    print_step "Installing extension dependencies"
    if ! command -v node &>/dev/null; then
        print_error "Node.js not found. Install Node 18+ from nodejs.org."
        return 1
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

build_mcp_server() {
    if [ ! -d "mcp-server" ]; then
        print_warn "MCP server directory not found — skipping"
        return 0
    fi

    print_step "Building MCP Server & Mini Agent"
    cd mcp-server
    npm install 2>&1 | tail -3
    npx tsc 2>&1
    cd ..

    print_step "Writing shared config"
    local PROJECT_ROOT
    PROJECT_ROOT="$(cd .. && pwd)"
    local HIDDEN_DIR="$PROJECT_ROOT/.swiftprism"
    mkdir -p "$HIDDEN_DIR"
    if [ ! -f "$HIDDEN_DIR/.gitignore" ]; then
        printf "*\n" > "$HIDDEN_DIR/.gitignore"
    fi

    cat > "$HIDDEN_DIR/swiftprism-config.json" <<CFGEOF
{
  "graphPath": "$HIDDEN_DIR/prism-context.json",
  "contextsDir": "$HIDDEN_DIR/contexts",
  "mcpServer": "$PROJECT_ROOT/mcp-server/dist/server.js",
  "extensionBin": "$PROJECT_ROOT/extension/bin/swift-prism-analyzer"
}
CFGEOF

    # Remove legacy root-level config
    rm -f "$PROJECT_ROOT/swiftprism-config.json"

    chmod +x dist/server.js
    cd ..

    print_step "Linking swift-prism-mcp globally"
    cd mcp-server
    npm link 2>&1 | tail -3 || {
        print_warn "npm link failed (try with sudo or set npm prefix). You can still use the full path."
    }
    cd ..

    print_done "MCP Server built — swift-prism-mcp command available"
    printf "\n  Claude Desktop config:\n"
    printf "  {\n"
    printf "    \"mcpServers\": {\n"
    printf "      \"swiftprism\": {\n"
    printf "        \"command\": \"swift-prism-mcp\"\n"
    printf "      }\n"
    printf "    }\n"
    printf "  }\n\n"
    return 0
}

build_extension_from_docker() {
    if ! docker_available; then
        return 1
    fi

    print_step "Cleaning up old containers"
    docker compose down --remove-orphans 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    print_step "Building Docker container for JS assets"
    docker compose up --build -d || return 1

    for i in $(seq 1 60); do
        if docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
            break
        fi
        if [ "$i" -eq 60 ]; then
            print_warn "Container did not start in time"
            return 1
        fi
        sleep 1
    done

    mkdir -p extension/out extension/dist-webview

    docker cp "$CONTAINER_NAME:/app/extension/out/." extension/out/ 2>/dev/null && \
        print_done "Extension host JS synced from Docker" || return 1

    docker cp "$CONTAINER_NAME:/app/extension/dist-webview/." extension/dist-webview/ 2>/dev/null && \
        print_done "React webview bundle synced from Docker" || return 1

    return 0
}

verify_binary() {
    print_step "Verifying binary compatibility"
    if [ ! -f "$BIN_TARGET" ]; then
        print_error "Binary not found at $BIN_TARGET"
        return 1
    fi

    chmod +x "$BIN_TARGET"

    if [ ! -x "$BIN_TARGET" ]; then
        print_error "Binary is not executable even after chmod +x"
        return 1
    fi

    local bin_info
    bin_info=$(file "$BIN_TARGET" 2>/dev/null)
    local bin_format
    bin_format=$(echo "$bin_info" | grep -oE "Mach-O|ELF" | head -1)

    if [ "$HOST_OS" = "Darwin" ] && [ "$bin_format" = "ELF" ]; then
        print_error "Binary is a Linux ELF but host is macOS — rebuilding natively"
        build_swift_native || exit 1
        bin_info=$(file "$BIN_TARGET" 2>/dev/null)
    fi

    if [ "$HOST_OS" = "Linux" ] && [ "$bin_format" = "Mach-O" ]; then
        print_error "Binary is a macOS Mach-O but host is Linux — rebuilding natively"
        build_swift_native || exit 1
        bin_info=$(file "$BIN_TARGET" 2>/dev/null)
    fi

    if "$BIN_TARGET" 2>&1 | head -1 | grep -qi "usage\|error\|no input\|No input"; then
        local arch
        arch=$(echo "$bin_info" | grep -oE "arm64|x86_64" | head -1)
        print_done "Binary is functional ($HOST_OS $arch)"
    else
        print_warn "Binary exists but test execution returned unexpected output"
        printf "  %s\n" "$bin_info"
    fi
}

generate_context() {
    print_step "Detecting project type and generating context data"
    local WORKSPACE_ROOT="${1:-$SCRIPT_DIR}"
    local HIDDEN_DIR="$WORKSPACE_ROOT/.swiftprism"
    local CONTEXT_OUT="$HIDDEN_DIR/prism-context.json"

    # Create hidden directory with gitignore
    mkdir -p "$HIDDEN_DIR"
    if [ ! -f "$HIDDEN_DIR/.gitignore" ]; then
        printf "*\n" > "$HIDDEN_DIR/.gitignore"
    fi

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
        -not -path "*/.swiftprism/*" \
        2>/dev/null || true)

    if [ -n "$SWIFT_FILES" ] && [ -x "$BIN_TARGET" ]; then
        local FLAGS="--workspace $WORKSPACE_ROOT --scan-targets --public-only-external --context --output $CONTEXT_OUT"
        $BIN_TARGET $FLAGS $SWIFT_FILES 2>/dev/null && \
            print_done "prism-context.json → $HIDDEN_DIR/" || \
            print_warn "Context generation skipped (non-critical)"
    else
        print_warn "Skipped context generation (no .swift files or binary not executable)"
    fi

    # Clean up legacy root-level file if it exists
    if [ -f "$WORKSPACE_ROOT/prism-context.json" ]; then
        mv "$WORKSPACE_ROOT/prism-context.json" "$CONTEXT_OUT" 2>/dev/null || true
        print_done "Migrated legacy prism-context.json → .swiftprism/"
    fi

    # Generate token-optimized node contexts via local LLM (or deterministic fallback)
    if [ -f "$CONTEXT_OUT" ] && [ -f "$SCRIPT_DIR/mcp-server/dist/node-context-generator.js" ]; then
        print_step "Generating node_context (LLM pre-digestion)"
        local OLLAMA_MODEL="${OLLAMA_MODEL:-codellama}"
        node -e "
          import('$SCRIPT_DIR/mcp-server/dist/node-context-generator.js').then(m => {
            m.generateNodeContexts('$CONTEXT_OUT', '$HIDDEN_DIR', { ollamaModel: '$OLLAMA_MODEL' })
              .then(r => console.log('Context: ' + r.generated + ' generated, ' + r.cached + ' cached (LLM: ' + r.usedLLM + ')'))
              .catch(e => console.error('Context generation skipped:', e.message));
          }).catch(e => console.error('Context module load failed:', e.message));
        " 2>/dev/null && \
            print_done "Node contexts enriched → $CONTEXT_OUT" || \
            print_warn "Node context generation skipped (non-critical)"
    fi

    # Auto-fragment for MCP on-demand loading
    if [ -f "$CONTEXT_OUT" ] && [ -f "$SCRIPT_DIR/mcp-server/dist/fragment-store.js" ]; then
        print_step "Fragmenting graph for on-demand MCP loading"
        node -e "
          import('$SCRIPT_DIR/mcp-server/dist/fragment-store.js').then(m => {
            const idx = m.fragmentGraph('$CONTEXT_OUT', '$HIDDEN_DIR');
            console.log('Fragmented: ' + idx.nodeCount + ' nodes → ' + idx.fragmentCount + ' files');
          }).catch(e => console.error('Fragmentation skipped:', e.message));
        " 2>/dev/null && \
            print_done "Fragments written → $HIDDEN_DIR/fragments/" || \
            print_warn "Fragmentation skipped (non-critical)"
    fi
}

print_banner() {
    printf "\n\033[1;35m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n"
    printf "\033[1;35m 💎 SwiftPrism is ready!  \033[0m\n"
    printf "\033[1;35m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m\n\n"
    printf "  Build mode: \033[1m%s\033[0m  (%s %s)\n\n" "$BUILD_MODE" "$HOST_OS" "$HOST_ARCH"
    printf "  \033[1mLaunch the 3D Graph:\033[0m\n"
    printf "    1. Open this folder in VS Code\n"
    printf "    2. Press \033[1mF5\033[0m → select \033[1m'Run SwiftPrism Extension'\033[0m\n"
    printf "    3. Click the 💎 icon in the Activity Bar\n"
    printf "    4. Click \033[1m▶ Analyze Project\033[0m\n\n"
    printf "  \033[1mCLI commands:\033[0m\n"
    printf "    $BIN_TARGET --workspace . --scan-targets *.swift\n"
    printf "    $BIN_TARGET --find-dependents-of \"HomeViewModel\" --workspace . *.swift\n\n"
    printf "  \033[1mClean:\033[0m  ./run.sh clean\n\n"
}

if [ "${1:-}" = "clean" ]; then
    run_clean
    exit 0
fi

printf "\033[1;35m💎 SwiftPrism Build System\033[0m  (%s %s)\n" "$HOST_OS" "$HOST_ARCH"

if [ "$HOST_OS" = "Darwin" ]; then
    BUILD_MODE="native"
    build_swift_native || exit 1

    if build_extension_from_docker 2>/dev/null; then
        print_done "JS assets from Docker"
    else
        print_warn "Docker unavailable — building JS natively"
        build_extension_native || exit 1
    fi

    verify_binary
    generate_context "$@"
    print_banner
    exit 0
fi

if docker_available; then
    BUILD_MODE="docker+native"
    print_done "Docker detected and running"

    print_step "Cleaning up old containers"
    docker compose down --remove-orphans 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

    docker compose up --build -d || {
        print_warn "Docker build failed — falling back to full native build"
        BUILD_MODE="native"
        build_swift_native || exit 1
        build_extension_native || exit 1
        build_mcp_server || true
        verify_binary
        generate_context "$@"
        print_banner
        exit 0
    }

    for i in $(seq 1 60); do
        if docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then break; fi
        if [ "$i" -eq 60 ]; then
            print_error "Container failed to start"
            BUILD_MODE="native"
            build_swift_native || exit 1
            build_extension_native || exit 1
            verify_binary
            generate_context "$@"
            print_banner
            exit 0
        fi
        sleep 1
    done

    mkdir -p extension/bin extension/out extension/dist-webview
    docker cp "$CONTAINER_NAME:/app/extension/bin/swift-prism-analyzer" "$BIN_TARGET" 2>/dev/null || true
    docker cp "$CONTAINER_NAME:/app/extension/out/." extension/out/ 2>/dev/null || true
    docker cp "$CONTAINER_NAME:/app/extension/dist-webview/." extension/dist-webview/ 2>/dev/null || true

    if [ -f "$BIN_TARGET" ]; then
        chmod +x "$BIN_TARGET"
    fi

    verify_binary
    generate_context "$@"
    print_banner
    exit 0
fi

BUILD_MODE="native"
print_warn "Docker not available — using native build"
build_swift_native || exit 1
build_extension_native || exit 1
build_mcp_server || true
verify_binary
generate_context "$@"
print_banner
