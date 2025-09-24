#!/bin/bash

mkdir -p files/etc/openclash/core
mkdir -p files/etc/config

# CLASH_META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/smart/clash-linux-amd64.tar.gz"
CLASH_META_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/smart/clash-linux-${1}.tar.gz"
GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
MODEL_URL="https://github.com/vernesong/mihomo/releases/download/LightGBM-Model/model-large.bin"

wget -qO- $CLASH_META_URL | tar xOvz > files/etc/openclash/core/clash_meta
wget -qO- $GEOIP_URL > files/etc/openclash/GeoIP.dat
wget -qO- $GEOSITE_URL > files/etc/openclash/GeoSite.dat
wget -qO- $MODEL_URL > files/etc/openclash/model.bin


chmod +x files/etc/openclash/core/clash*

