FROM --platform=$BUILDPLATFORM swift:5.10-jammy AS swift-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY core/Package.swift core/Package.resolved* ./
RUN swift package resolve

COPY core/Sources ./Sources

RUN swift build -c release \
    --static-swift-stdlib \
    -Xlinker -s \
    && mv .build/release/swift-prism-analyzer /usr/local/bin/swift-prism-analyzer

FROM --platform=$TARGETPLATFORM node:20-slim AS final

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=swift-builder /usr/local/bin/swift-prism-analyzer /app/extension/bin/swift-prism-analyzer
RUN chmod +x /app/extension/bin/swift-prism-analyzer

COPY extension/package.json extension/package-lock.json* /app/extension/
WORKDIR /app/extension
RUN npm ci --ignore-scripts 2>/dev/null || npm install

COPY extension/webview/package.json extension/webview/package-lock.json* /app/extension/webview/
WORKDIR /app/extension/webview
RUN npm ci --ignore-scripts 2>/dev/null || npm install

WORKDIR /app

COPY extension/ /app/extension/

WORKDIR /app/extension
RUN npx tsc -p ./ \
    && cd webview && npx tsc -b && npx vite build

WORKDIR /app

RUN /app/extension/bin/swift-prism-analyzer --help 2>&1 || true

ENTRYPOINT ["tail", "-f", "/dev/null"]
