#!/usr/bin/env bash
#================================================================
#  OpenWrt Mediatek (mt7986) DIY 脚本
#  1. 统一变量 & 错误/日志函数
#  2. 合并并行处理的第三方包
#  3. 通过 env 传递关键变量给 workflow
#================================================================
set -euo pipefail
IFS=$'\n\t'
# ==================== 1️⃣ 全局变量 ====================
: "${MIRROR:=https://mirrors.tuna.tsinghua.edu.cn/openwrt}"
: "${GITEA:=git.kejizero.online/zhao}"
: "${GITHUB:=github.com}"
: "${CLASH_KERNEL:=amd64}"
: "${LAN:=192.168.1.1}"               # 默认值，workflow 会覆盖
: "${ROOT_PASSWORD:=}"                # workflow 会覆盖
# ==================== 2️⃣ 日志 & 错误 ====================
log()    { echo -e "\033[1;34m[INFO]  $*\033[0m"; echo "::group::$*"; }
log_end(){ echo "::endgroup::"; }
err()    { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; echo "::error::$*"; exit 1; }
# ==================== 3️⃣ 通用函数 ====================
download() {
  local url=$1 dst=$2
  curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$dst" \
    || err "download failed: $url"
  [[ -s "$dst" ]] || err "download produced empty file: $dst"
}
clone_pkg() {
  local repo=$1 dst=$2 branch=$3
  if [[ -n $branch ]]; then
    git clone --depth=1 -b "$branch" "$repo" "$dst" \
      || err "clone $repo (branch $branch) failed"
  else
    git clone --depth=1 "$repo" "$dst" \
      || err "clone $repo failed"
  fi
}
# ==================== 4️⃣ 基础配置（IP、名称、ttyd） ====================
log "基础配置：IP、默认名称、ttyd免登录"
sed -i -e "s/192\\.168\\.6\\.1/${LAN}/" \
       -e "s/ImmortalWrt/OpenWrt/" \
       -e "s|/bin/login|/bin/login -f root|g" \
       package/base-files/files/bin/config_generate
log_end
# ==================== 5️⃣ Root 密码 ====================
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  log "设置 root 密码"
  ROOT_HASH=$(openssl passwd -5 "$ROOT_PASSWORD")
  sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" \
    package/base-files/files/etc/shadow
  log_end
fi
# ==================== 6️⃣ 删除不需要的 feed 包 ====================
log "删除多余的网络/luCI包"
rm -rf feeds/packages/net/{v2ray-geodata,open-app-filter,shadowsocksr-libev,shadowsocks-rust,shadowsocks-libev,\
tcping,trojan,trojan-plus,tuic-client,v2ray-core,v2ray-plugin,xray-core,xray-plugin,\
sing-box,chinadns-ng,hysteria,mosdns,lucky,ddns-go,v2dat,golang}
rm -rf feeds/luci/applications/{luci-app-daed,luci-app-dae,luci-app-homeproxy,luci-app-openclash,\
luci-app-passwall,luci-app-passwall2,luci-app-ssr-plus,luci-app-vssr,\
luci-app-appfilter,luci-app-ddns-go,luci-app-lucky,luci-app-mosdns,\
luci-app-alist,luci-app-openlist,luci-app-airwhu}
log_end
# ==================== 7️⃣ 固件信息 ====================
log "写入固件自定义信息"
sed -i -e "s/DISTRIB_DESCRIPTION='.*'/DISTRIB_DESCRIPTION='OpenWrt-$(date +%Y%m%d)'/" \
       -e "s/DISTRIB_REVISION='.*'/DISTRIB_REVISION=' By grandway2025'/" \
       package/base-files/files/etc/openwrt_release
sed -i "s|^OPENWRT_RELEASE=\".*\"|OPENWRT_RELEASE=\"OpenWrt定制版\"|" \
       package/base-files/files/usr/lib/os-release
log_end
# ==================== 8️⃣ 主题（argon） ====================
log "替换 Argon 主题"
rm -rf feeds/luci/themes/luci-theme-argon
git clone https://github.com/grandway2025/argon package/new/luci-theme-argon --depth=1
log_end
# ==================== 9️⃣ Golang 1.25 ====================
log "升级 Golang 至 1.25"
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 25.x feeds/packages/lang/golang
log_end
# ==================== 10️⃣ 第三方扩展包（并行） ====================
log "并行克隆第三方插件"
declare -A EXTRA_PKGS=(
  [helloworld]="https://${GITHUB}/grandway2025/helloworld -b openwrt-24.10"
  [lucky]="https://${GITHUB}/gdy666/luci-app-lucky"
  [mosdns]="https://${GITHUB}/sbwml/luci-app-mosdns -b v5"
  [OpenAppFilter]="https://${GITHUB}/destan19/OpenAppFilter"
  [luci-app-taskplan]="https://${GITHUB}/sirpdboy/luci-app-taskplan"
  [luci-app-webdav]="https://${GITHUB}/sbwml/luci-app-webdav -b openwrt-24.10"
  [quickfile]="https://${GITHUB}/sbwml/luci-app-quickfile"
  [openlist]="https://${GITHUB}/sbwml/luci-app-openlist2"
  [socat]="https://${GITHUB}/zhiern/luci-app-socat"
  [adguardhome]="https://git.kejizero.online/zhao/luci-app-adguardhome"
  # 如需继续添加请直接在这里补充
)
for name in "${!EXTRA_PKGS[@]}"; do
  url=${EXTRA_PKGS[$name]}
  repo=$(awk '{print $1}' <<<"$url")
  branch=$(awk '{print $2}' <<<"$url")
  dest="package/new/$name"
  if [[ -n $branch ]]; then
    clone_pkg "$repo" "$dest" "$branch" &
  else
    clone_pkg "$repo" "$dest" "" &
  fi
done
wait
log_end
# ==================== 11️⃣ AdGuardHome 二进制 ====================
log "下载 AdGuardHome 二进制"
AGH_URL=$(curl -fsSL "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" \
          | jq -r '.assets[]|select(.name|endswith("_linux_arm64.tar.gz")).browser_download_url')
curl -fsSL "$AGH_URL" -o /tmp/agh.tar.gz
tar -xzf /tmp/agh.tar.gz -C files/usr/bin --strip-components=1 AdGuardHome/AdGuardHome
chmod +x files/usr/bin/AdGuardHome
log_end
# ==================== 12️⃣ OpenClash 二进制 ====================
log "下载 OpenClash 内核"
CLASH_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
mkdir -p files/etc/openclash/core
curl -fsSL "$CLASH_URL" | tar -xz -C files/etc/openclash/core --strip-components=1 clash
curl -fsSL "$GEOIP_URL" -o files/etc/openclash/GeoIP.dat
curl -fsSL "$GEOSITE_URL" -o files/etc/openclash/GeoSite.dat
chmod +x files/etc/openclash/core/clash*
log_end
# ==================== 13️⃣ Docker utils ====================
log "重新拉取 docker utils"
rm -rf feeds/luci/applications/luci-app-dockerman
git clone https://github.com/sirpdboy/luci-app-dockerman.git package/new/dockerman --depth=1
mv -n package/new/dockerman/luci-app-dockerman feeds/luci/applications && rm -rf package/new/dockerman
rm -rf feeds/packages/utils/{docker,dockerd,containerd,runc}
git clone https://github.com/sbwml/packages_utils_docker feeds/packages/utils/docker --depth=1
git clone https://github.com/sbwml/packages_utils_dockerd feeds/packages/utils/dockerd --depth=1
git clone https://github.com/sbwml/packages_utils_containerd feeds/packages/utils/containerd --depth=1
git clone https://github.com/sbwml/packages_utils_runc feeds/packages/utils/runc --depth=1
log_end
# ==================== 14️⃣ default-settings ====================
log "拉取自定义 default‑settings"
git clone -b mediatek https://github.com/grandway2025/default-settings \
          package/new/default-settings --depth=1
log_end
# ==================== 15️⃣ 生成 final .config ====================
log "调用 make defconfig 生成最终 .config"
make defconfig
log_end
# ==================== 16️⃣ 导出关键变量供 workflow 使用 ====================
DEVICE_TARGET=$(grep ^CONFIG_TARGET_BOARD .config | cut -d'"' -f2)
DEVICE_SUBTARGET=$(grep ^CONFIG_TARGET_SUBTARGET .config | cut -d'"' -f2)
cat <<EOF >> "$GITHUB_ENV"
DEVICE_TARGET=$DEVICE_TARGET
DEVICE_SUBTARGET=$DEVICE_SUBTARGET
EOF
log "DIY 脚本执行完毕 ✅"
exit 0
