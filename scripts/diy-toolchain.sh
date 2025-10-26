#!/bin/bash
#=================================================
# 预编译工具链加载脚本（精简健壮版）
# 位置：scripts/diy-toolchain.sh
#=================================================

# 检查是否启用
[ "$BUILD_FAST" != "y" ] && [ "$ENABLE_PREBUILT_TOOLCHAIN" != "y" ] && exit 0

# 配置
TOOLCHAIN_ARCH="x86_64"
TOOLCHAIN_URL="https://github.com/${GITHUB_REPOSITORY:-zouchanggan/OpenWrt-Actions}/releases/download/openwrt-24.10"

# 下载进度条
CURL_BAR=""
curl --help | grep -q progress-bar && CURL_BAR="--progress-bar"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🔧 Loading Prebuilt Toolchain"
echo "════════════════════════════════════════════════════════════════"

# 🔥 自动检测配置
LIBC="musl"
GCC_VERSION="15"
[ -f ".config" ] && {
    grep -q "CONFIG_LIBC_USE_GLIBC=y" .config && LIBC="glibc"
    grep -q "CONFIG_GCC_USE_VERSION_13=y" .config && GCC_VERSION="13"
    grep -q "CONFIG_GCC_USE_VERSION_14=y" .config && GCC_VERSION="14"
}

echo "📦 Target: ${LIBC} / GCC-${GCC_VERSION}"

# 🔥 智能回退版本列表
VERSIONS=("$GCC_VERSION")
[ "$GCC_VERSION" != "15" ] && VERSIONS+=("15")
[ "$GCC_VERSION" != "14" ] && VERSIONS+=("14")
[ "$GCC_VERSION" != "13" ] && VERSIONS+=("13")

# 尝试加载工具链
for VER in "${VERSIONS[@]}"; do
    FILENAME="toolchain_${LIBC}_${TOOLCHAIN_ARCH}_gcc-${VER}.tar.zst"
    echo ""
    echo "🔍 Trying GCC ${VER}..."
    
    # 下载（3次重试）
    SUCCESS=false
    for i in 1 2 3; do
        if curl -L -f "${TOOLCHAIN_URL}/${FILENAME}" \
            -o toolchain.tar.zst \
            --connect-timeout 30 \
            --max-time 600 \
            --retry 2 \
            $CURL_BAR 2>&1; then
            SUCCESS=true
            break
        fi
        rm -f toolchain.tar.zst
        [ $i -lt 3 ] && sleep 5
    done
    
    [ "$SUCCESS" = false ] && continue
    
    # 验证并解压
    if [ -f "toolchain.tar.zst" ] && zstd -t toolchain.tar.zst >/dev/null 2>&1; then
        echo "📦 Extracting..."
        if tar -I "zstd -d -T0" -xf toolchain.tar.zst 2>&1 | grep -v "Ignoring unknown"; then
            rm -f toolchain.tar.zst
            
            # 更新时间戳
            mkdir -p bin
            find ./staging_dir/ ./tmp/ -name '*' -exec touch {} \; 2>/dev/null
            
            # 验证工具链
            TOOLCHAIN_DIR=$(find staging_dir -maxdepth 1 -type d -name "toolchain-*" 2>/dev/null | head -1)
            if [ -n "$TOOLCHAIN_DIR" ]; then
                GCC_BIN=$(find "$TOOLCHAIN_DIR/bin" -name "*-gcc" -type f 2>/dev/null | head -1)
                if [ -n "$GCC_BIN" ] && [ -f "$GCC_BIN" ]; then
                    chmod +x "$GCC_BIN" 2>/dev/null
                    if GCC_VER=$("$GCC_BIN" --version 2>&1 | head -1); then
                        echo "✅ Toolchain Ready: ${GCC_VER}"
                        echo "   Build time will be reduced by ~25 minutes"
                        export TOOLCHAIN_READY=true
                        echo "════════════════════════════════════════════════════════════════"
                        echo ""
                        exit 0
                    fi
                fi
            fi
        fi
    fi
    
    rm -f toolchain.tar.zst
done

# 未找到可用工具链
echo "⚠️  No compatible toolchain found"
echo "   Will build from source (~25 minutes extra)"
echo "════════════════════════════════════════════════════════════════"
echo ""
exit 0
