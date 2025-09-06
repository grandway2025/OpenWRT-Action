#!/usr/bin/env bash
#=================================================
#   OpenWrt X86_64 自定义编译脚本
#   1️⃣ 统一变量（MIRROR / GITEA / GITHUB）
#   2 -euo pipefail + 统一错误/日志函数
#   3️⃣ download / apply_patch / clone_pkg 三个通用函数
#   4️⃣ 通过数组 + 并行方式获取第三方包
#   5️⃣ 最后把关键变量写入 $GITHUB_ENV 供 workflow 使用
#=================================================
set -euo pipefail
IFS=$'\n\t'
# ---------- 1️⃣ 全局变量 ----------
# 这些变量在 workflow 的 env 中已经声明，这里做默认值（便于本地调试）
: "${MIRROR:=https://mirrors.tuna.tsinghua.edu.cn/openwrt}"
: "${GITEA:=git.kejizero.online/zhao}"
: "${GITHUB:=github.com}"
: "${CLASH_KERNEL:=amd64}"
KVER=6.6                       # 只改这里即可切换内核版本
# ---------- 2️⃣ 日志 & 错误 ----------
log()    { echo -e "\033[1;34m[INFO]  $*\033[0m"; echo "::group::$*"; }
log_end(){ echo "::endgroup::"; }
err()    { echo -e "\033[1;31m[ERROR] $*\033[0m" >&2; echo "::error::$*"; exit 1; }
# ---------- 3️⃣ 通用函数 ----------
download() {
  local url=$1 dst=$2
  curl -fsSL --retry 3 --retry-delay 5 "$url" -o "$dst" \
    || err "download failed: $url"
  [[ -s "$dst" ]] || err "download produced empty file: $dst"
}
apply_patch() {
  local f=$1
  if git apply "$f"; then
    rm -f "$f"
  else
    err "apply patch failed: $f"
  fi
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
# ---------- 4️⃣ 编译优化 ----------
log "Set compiler optimization"
sed -i 's/^EXTRA_OPTIMIZATION=.*/EXTRA_OPTIMIZATION=-O2 -march=x86-64-v2/' include/target.mk
log_end
# ---------- 5️⃣ Kernel & vermagic ----------
log "Download kernel $KVER and patches"
download "${MIRROR}/doc/kernel-${KVER}"          include/kernel-${KVER}
download "${MIRROR}/doc/patch/kernel/${KVER}/0001-linux-module-video.patch" \
         package/0001-linux-module-video.patch
apply_patch package/0001-linux-module-video.patch
log "Generate vermagic"
sed -i 's/^\(.\).*vermagic$/\1cp $(TOPDIR)\/.vermagic $(LINUX_DIR)\/.vermagic/' \
      include/kernel-defaults.mk
grep HASH include/kernel-${KVER} | awk -F'HASH-' '{print $2}' | awk '{print $1}' \
  | md5sum | awk '{print $1}' > .vermagic
log_end
# ---------- 6️⃣ 可选功能（依赖 workflow inputs） ----------
if [[ "${ENABLE_DOCKER:-false}" == "true" ]];    then curl -fsSL "${MIRROR}/configs/config-docker"    >> .config; fi
if [[ "${ENABLE_SSRP:-false}" == "true" ]];      then curl -fsSL "${MIRROR}/configs/config-ssrp"      >> .config; fi
if [[ "${ENABLE_PASSWALL:-false}" == "true" ]];  then curl -fsSL "${MIRROR}/configs/config-passwall"  >> .config; fi
if [[ "${ENABLE_NIKKI:-false}" == "true" ]];     then curl -fsSL "${MIRROR}/configs/config-nikki"     >> .config; fi
if [[ "${ENABLE_OPENCLASH:-false}" == "true" ]]; then curl -fsSL "${MIRROR}/configs/config-openclash" >> .config; fi
if [[ "${ENABLE_LUCKY:-false}" == "true" ]];     then curl -fsSL "${MIRROR}/configs/config-lucky"     >> .config; fi
if [[ "${ENABLE_OAF:-false}" == "true" ]];       then curl -fsSL "${MIRROR}/configs/config-oaf"       >> .config; fi
# ---------- 7️⃣ 常规清理 ----------
log "Remove -SNAPSHOT tags & tidy feeds.mk"
sed -i 's/-SNAPSHOT//g' include/version.mk \
                 package/base-files/image-config.in
sed -i '/CONFIG_BUILDBOT/d' include/feeds.mk
sed -i 's/;)\s*\\/; \\/' include/feeds.mk
log_end
# ---------- 8️⃣ 第三方 feed / packages ----------
log "Replace nginx (latest)"
rm -rf feeds/packages/net/nginx
git clone "https://${GITHUB}/sbwml/feeds_packages_net_nginx.git" \
          feeds/packages/net/nginx -b openwrt-24.10
sed -i 's/procd_set_param stdout 1/procd_set_param stdout 0/' \
       feeds/packages/net/nginx/files/nginx.init
sed -i 's/procd_set_param stderr 1/procd_set_param stderr 0/' \
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
sed -i -e 's/threads = 1/threads = 2/' \
       -e 's/processes = 3/processes = 4/' \
       -e 's/cheaper = 1/cheaper = 2/' \
       feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini
log "rpcd timeout fix"
sed -i 's/option timeout 30/option timeout 60/g' \
       package/system/rpcd/files/rpcd.config
sed -i 's#20) \* 1000#60) \* 1000#g' \
       feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js
log_end
# ---------- 9️⃣ LAN & root password ----------
log "Set default LAN address & root password"
sed -i "s/192.168.1.1/${LAN}/" package/base-files/files/bin/config_generate
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  pass_hash=$(openssl passwd -5 "${ROOT_PASSWORD}")
  sed -i "s|^root:[^:]*:|root:${pass_hash}:|" \
         package/base-files/files/etc/shadow
fi
log_end
# ---------- 10️⃣ OpenAppFilter eBPF ----------
if [[ "${ENABLE_OAF:-false}" == "true" ]]; then
  log "Enable BPF syscall for OpenAppFilter"
  sed -i 's/# CONFIG_BPF_SYSCALL is not set/CONFIG_BPF_SYSCALL=y/' .config
  log_end
fi
# ---------- 11️⃣ Rust 编译参数 ----------
log "Disable rust llvm download"
sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' \
       feeds/packages/lang/rust/Makefile
log_end
# ---------- 12️⃣ 第三方扩展包 ----------
declare -A EXTRA_PKGS=(
  [nft-fullcone]="https://${GITEA}/nft-fullcone"
  [6]="https://${GITEA}/package_new_nat6"
  [natflow]="https://${GITEA}/package_new_natflow"
  [shortcut-fe]="https://${GITHUB}/zhiern/shortcut-fe"
  [caddy]="https://git.kejizero.online/zhao/luci-app-caddy"
  [mosdns]="https://${GITHUB}/sbwml/luci-app-mosdns -b v5"
  [OpenAppFilter]="https://${GITHUB}/destan19/OpenAppFilter"
  [luci-app-poweroffdevice]="https://github.com/sirpdboy/luci-app-poweroffdevice"
  # 需要的其它包继续往下添加
)
log "Clone extra packages (parallel)"
for pkg in "${!EXTRA_PKGS[@]}"; do
  url=${EXTRA_PKGS[$pkg]}
  repo=$(awk '{print $1}' <<<"$url")
  branch=$(awk '{print $2}' <<<"$url")
  clone_pkg "$repo" "package/new/$pkg" "$branch" &
done
wait
log_end
# ---------- 13️⃣ 生成 final .config ----------
log "Run make defconfig"
make defconfig
log_end
# ---------- 14️⃣ 输出关键变量（供 workflow 使用） ----------
DEVICE_TARGET=$(grep ^CONFIG_TARGET_BOARD .config | cut -d'"' -f2)
DEVICE_SUBTARGET=$(grep ^CONFIG_TARGET_SUBTARGET .config | cut -d'"' -f2)
cat <<EOF >> "$GITHUB_ENV"
DEVICE_TARGET=$DEVICE_TARGET
DEVICE_SUBTARGET=$DEVICE_SUBTARGET
EOF
log "DIY script finished ✅"
exit 0
