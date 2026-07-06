#!/bin/sh
# 99-custom.sh 就是immortalwrt固件首次启动时运行的脚本 位于固件内的/etc/uci-defaults/99-custom.sh
# Log file for debugging
LOGFILE="/etc/config/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >>$LOGFILE
# 无需特殊防火墙规则：保持固件默认（wan 入站默认拒绝），不额外配置
# WebUI/SSH 仅从 lan 访问，由后续 dropbear/ttyd 绑定 lan 接口实现

# 设置主机名映射，解决安卓原生 TV 无法联网的问题
uci add dhcp domain
uci set "dhcp.@domain[-1].name=time.android.com"
uci set "dhcp.@domain[-1].ip=203.107.6.88"

# 读取 PPPoE 账号密码（由 build.sh 写入 /etc/config/pppoe-settings）
# WAN 固定为 PPPoE 拨号口，账号密码来自此处
SETTINGS_FILE="/etc/config/pppoe-settings"
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "PPPoE settings file not found. WAN will lack credentials." >>$LOGFILE
else
    . "$SETTINGS_FILE"
fi

# 1. 硬编码网口映射：eth3 = WAN，eth0-eth2 = LAN（br-lan）
wan_ifname="eth3"
lan_ifnames="eth0 eth1 eth2"
echo "Hardcoded mapping: WAN=$wan_ifname LAN=$lan_ifnames" >>"$LOGFILE"

# 2. 配置 WAN（eth3 为 PPPoE 拨号口）
uci set network.wan=interface
uci set network.wan.device="$wan_ifname"
uci set network.wan.proto='pppoe'
uci set network.wan.username="$pppoe_account"
uci set network.wan.password="$pppoe_password"
uci set network.wan.peerdns='1'
uci set network.wan.auto='1'

# 配置WAN6（PPPoE 拨号时关闭 IPv6）
uci set network.wan6=interface
uci set network.wan6.device="$wan_ifname"
uci set network.wan6.proto='none'

# 查找 br-lan 设备 section
section=$(uci show network | awk -F '[.=]' '/\.@?device\[\d+\]\.name=.br-lan.$/ {print $2; exit}')
if [ -z "$section" ]; then
    echo "error：cannot find device 'br-lan'." >>$LOGFILE
else
    # 删除原有ports
    uci -q delete "network.$section.ports"
    # 添加LAN接口端口
    for port in $lan_ifnames; do
        uci add_list "network.$section.ports"="$port"
    done
    echo "Updated br-lan ports: $lan_ifnames" >>$LOGFILE
fi

# 3. LAN口设置静态IP（固定为 192.168.100.2）
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.100.2'
uci set network.lan.netmask='255.255.255.0'

uci commit network

# 仅从 lan 访问网页终端（绑定到 lan 接口）
uci set ttyd.@ttyd[0].interface='lan'

# 仅从 lan 连接 SSH（绑定到 lan 接口）
uci set dropbear.@dropbear[0].Interface='lan'
uci commit

# 设置编译作者信息
FILE_PATH="/etc/openwrt_release"
NEW_DESCRIPTION="Packaged by wukongdaily"
sed -i "s/DISTRIB_DESCRIPTION='[^']*'/DISTRIB_DESCRIPTION='$NEW_DESCRIPTION'/" "$FILE_PATH"

# 若luci-app-advancedplus (进阶设置)已安装 则去除zsh的调用 防止命令行报 /usb/bin/zsh: not found的提示
if [ -f /usr/lib/lua/luci/controller/advancedplus.lua ]; then
    sed -i '/\/usr\/bin\/zsh/d' /etc/profile
    sed -i '/\/bin\/zsh/d' /etc/init.d/advancedplus
    sed -i '/\/usr\/bin\/zsh/d' /etc/init.d/advancedplus
    echo "fix ttyd show msg: /usb/bin/zsh: not found" >>$LOGFILE
fi

# 只有安装了 luci-app-quickfile 才执行
if [ -f /usr/bin/quickfile ]; then
    uci set nginx.global.uci_enable='true'
    uci del nginx._lan 2>/dev/null
    uci del nginx._redirect2ssl 2>/dev/null

    uci add nginx server
    uci rename nginx.@server[-1]='_lan'

    uci set nginx._lan.server_name='_lan'
    uci add_list nginx._lan.listen='80 default_server'
    uci add_list nginx._lan.listen='[::]:80 default_server'
    uci add_list nginx._lan.include='conf.d/*.locations'
    uci set nginx._lan.access_log='off; # logd openwrt'

    uci commit nginx
    echo "fix quickfile nginx config" >>$LOGFILE
fi

# 若安装了dockerd 则设置docker的防火墙规则
# 扩大docker涵盖的子网范围 '172.16.0.0/12'
# 方便各类docker容器的端口顺利通过防火墙 
if command -v dockerd >/dev/null 2>&1; then
    echo "检测到 Docker，正在配置防火墙规则..."
    FW_FILE="/etc/config/firewall"

    # 删除所有名为 docker 的 zone
    uci delete firewall.docker

    # 先获取所有 forwarding 索引，倒序排列删除
    for idx in $(uci show firewall | grep "=forwarding" | cut -d[ -f2 | cut -d] -f1 | sort -rn); do
        src=$(uci get firewall.@forwarding[$idx].src 2>/dev/null)
        dest=$(uci get firewall.@forwarding[$idx].dest 2>/dev/null)
        echo "Checking forwarding index $idx: src=$src dest=$dest"
        if [ "$src" = "docker" ] || [ "$dest" = "docker" ]; then
            echo "Deleting forwarding @forwarding[$idx]"
            uci delete firewall.@forwarding[$idx]
        fi
    done
    # 提交删除
    uci commit firewall

# 追加新的 zone + forwarding 配置
cat <<EOF >>"$FW_FILE"

config zone 'docker'
  option input 'ACCEPT'
  option output 'ACCEPT'
  option forward 'ACCEPT'
  option name 'docker'
  list subnet '172.16.0.0/12'

config forwarding
  option src 'docker'
  option dest 'lan'

config forwarding
  option src 'docker'
  option dest 'wan'

config forwarding
  option src 'lan'
  option dest 'docker'
EOF

else
    echo "未检测到 Docker，跳过防火墙配置。"
fi

exit 0
