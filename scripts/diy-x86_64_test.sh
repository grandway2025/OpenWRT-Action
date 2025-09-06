#!/usr/bin/env bash
# -------------------------------------------------
#   OpenWrt X86_64 自定义编译脚本
#   1. 所有外部资源使用统一变量
#   2. 采用 set -euo pipefail + 错误检查
#   3. 通过函数封装重复操作（download、apply_patch、clone_pkg）
#   4. 最后统一输出关键环境变量供 workflow 使用
# -------------------------------------------------
set -euo pipefail
IFS=$'\n\t'
# ---------- 1️⃣ 环境变量 ----------
# 镜像地址可在 workflow 中覆盖（默认公开 CDN），不再硬编码 localhost
: "${MIRROR:=https://mirrors.tuna.tsinghua.edu.cn/openwrt}"
: "${GITEA:=git.kejizero.online/zhao}"
: "${GITHUB:=github.com}"
: "${CLASH_KERNEL:=amd64}"   # 预留给后面的 preset 脚本
# ---------- 2️⃣ 工具函数 ----------
log() { echo -e "\033[1;34m[INFO]  $*\033[0m"; }
err() { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; exit 1; }
# curl 并确保文件非空
download() {
  local url=$1 dest=$2
  curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$dest" \
    || err "download failed: $url"
  [[ -s "$dest" ]] || err "download produced empty file: $dest"
}
# git apply 并检测成功
apply_patch() {
  local patch_file=$1
  git apply "$patch_file" || err "apply patch failed: $patch_file"
  rm -f "$patch_file"
}
# clone 并自动深度 1
clone_pkg() {
  local repo=$1 dst=$2
  git clone --depth=1 "$repo" "$dst" || err "clone $repo → $dst failed"
}
# ---------- 3️⃣ 基础编译参数 ----------
log "Set compiler optimization"
sed -i 's/^EXTRA_OPTIMIZATION=.*$/EXTRA_OPTIMIZATION=-O2 -march=x86-64-v2/' include/target.mk
# ---------- 4️⃣ kernel 相关 ----------
log "下载 kernel 6.6 & 相关补丁"
download "${MIRROR}/doc/kernel-6.6"                include/kernel-6.6
download "${MIRROR}/doc/patch/kernel/6.6/0001-linux-module-video.patch" \
         package/0001-linux-module-video.patch
apply_patch package/0001-linux-module-video.patch
log "生成 vermagic"
sed -i 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' \
      include/kernel-defaults.mk
grep HASH include/kernel-6.6 | awk -F'HASH-' '{print $2}' | awk '{print $1}' | \
  md5sum | awk '{print $1}' > .vermagic
# ---------- 5️⃣ 可选功能（依赖 workflow inputs） ----------
[[ "$ENABLE_DOCKER" == "y" ]] && curl -fsSL "${MIRROR}/configs/config-docker" >> .config
[[ "$ENABLE_SSRP"    == "y" ]] && curl -fsSL "${MIRROR}/configs/config-ssrp"     >> .config
[[ "$ENABLE_PASSWALL" == "y" ]] && curl -fsSL "${MIRROR}/configs/config-passwall" >> .config
[[ "$ENABLE_NIKKI"   == "y" ]] && curl -fsSL "${MIRROR}/configs/config-nikki"    >> .config
[[ "$ENABLE_OPENCLASH" == "y" ]] && curl -fsSL "${MIRROR}/configs/config-openclash" >> .config
[[ "$ENABLE_LUCKY"   == "y" ]] && curl -fsSL "${MIRROR}/configs/config-lucky"    >> .config
[[ "$ENABLE_OAF"     == "y" ]] && curl -fsSL "${MIRROR}/configs/config-oaf"      >> .config
# ---------- 6️⃣ 通用去除/修正 ----------
log "Remove -SNAPSHOT、清理 feeds.mk"
sed -i 's/-SNAPSHOT//g' include/version.mk
sed -i 's/-SNAPSHOT//g' package/base-files/image-config.in
sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
sed -i 's/;)\s*\\/; \\/' include/feeds.mk
# ---------- 7️⃣ 第三方 feed / packages ----------
log "替换 nginx（最新）"
rm -rf feeds/packages/net/nginx
git clone "https://${GITHUB}/sbwml/feeds_packages_net_nginx.git" \
          feeds/packages/net/nginx -b openwrt-24.10
sed -i 's/procd_set_param stdout 1/procd_set_param stdout 0/g' \
       feeds/packages/net/nginx/files/nginx.init
sed -i 's/procd_set_param stderr 1/procd_set_param stderr 0/g' \
       feeds/packages/net/nginx/files/nginx.init
curl -fsSL "${MIRROR}/Customize/nginx/luci.locations" \
      > feeds/packages/net/nginx/files-luci-support/luci.locations
curl -fsSL "${MIRROR}/Customize/nginx/uci.conf.template" \
      > feeds/packages/net/nginx-util/files/uci.conf.template
log "uwsgi performance tweaks"
sed -i '$a cgi-timeout = 600' feeds/packages/net/uwsgi/files-luci-support/luci-*.ini
sed -i '/limit-as/c\limit-as = 5000' feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/procd_set_param stderr 1/procd_set_param stderr 0/g' \
       feeds/packages/net/uwsgi/files/uwsgi.init
sed -i 's/threads = 1/threads = 2/g' \
       feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/processes = 3/processes = 4/g' \
       feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
sed -i 's/cheaper = 1/cheaper = 2/g' \
       feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
log "rpcd timeout fix"
sed -i 's/option timeout 30/option timeout 60/g' \
       package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' \
       feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js
# ---------- 8️⃣ 系统默认 IP / root 密码 ----------
log "Set default LAN & root password"
sed -i "s/192.168.1.1/${LAN}/g" package/base-files/files/bin/config_generate
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  # 采用 shadow SHA‑5 加密（兼容原 OpenWrt）
  pass_hash=$(openssl passwd -5 "${ROOT_PASSWORD}")
  sed -i "s|^root:[^:]*:|root:${pass_hash}:|" \
         package/base-files/files/etc/shadow
fi
# ---------- 9️⃣ OpenAppFilter eBPF 支持 ----------
if [[ "$ENABLE_OAF" == "y" ]]; then
  log "Enable BPF syscall for OpenAppFilter"
  sed -i 's/# CONFIG_BPF_SYSCALL is not set/CONFIG_BPF_SYSCALL=y/' .config
fi
# ---------- 10️⃣ Rust 编译参数 ----------
log "关闭 rust llvm 下载"
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' \
       feeds/packages/lang/rust/Makefile
# ---------- 11️⃣   其他大量第三方包（示例） ----------
# 为了避免 200 行重复，这里使用数组 + 循环
declare -A EXTRA_PKGS=(
  ["nft-fullcone"]="https://${GITEA}/nft-fullcone"
  ["nat6"]="https://${GITEA}/package_new_nat6"
  ["natflow"]="https://${GITEA}/package_new_natflow"
  ["shortcut-fe"]="https://${GITHUB}/zhiern/shortcut-fe"
  ["caddy"]="https://git.kejizero.online/zhao/luci-app-caddy"
  ["mosdns"]="https://${GITHUB}/sbwml/luci-app-mosdns -b v5"
  ["OpenAppFilter"]="https://${GITHUB}/destan19/OpenAppFilter"
  ["luci-app-poweroffdevice"]="https://github.com/sirpdboy/luci-app-poweroffdevice"
  # ...... 其它需要的包自行添加
)
for pkg url in "${!EXTRA_PKGS[@]}"; do
  log "Cloning $pkg ..."
  # url 里可能带有 -b <branch>，我们直接把它完整传给 git
  git clone --depth=1 $url "package/new/$pkg"
done
# ---------- 12️⃣ 生成 final .config ----------
log "Generate final .config"
make defconfig
# ---------- 13️⃣ 输出关键变量（供 workflow 读取） ----------
DEVICE_TARGET=$(grep ^CONFIG_TARGET_BOARD .config | cut -d'"' -f2)
DEVICE_SUBTARGET=$(grep ^CONFIG_TARGET_SUBTARGET .config | cut -d'"' -f2)
cat <<EOF >> $GITHUB_ENV
DEVICE_TARGET=$DEVICE_TARGET
DEVICE_SUBTARGET=$DEVICE_SUBTARGET
EOF
log "DIY script finished ✅"
