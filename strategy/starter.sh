#!/bin/bash

# Загружаем конфигурацию
if [ -f /opt/zapret/config ]; then
    source /opt/zapret/config
else
    echo "ERROR: /opt/zapret/config not found!"
    exit 1
fi

# Читаем настройки
FWTYPE=$(cat /opt/zapret/system/FWTYPE 2>/dev/null || echo "nftables")
IFACE_WAN=$(cat /opt/zapret/system/IFACE_WAN 2>/dev/null)
IFACE_LAN=$(cat /opt/zapret/system/IFACE_LAN 2>/dev/null)

echo "Starting zapret with $FWTYPE firewall..."
echo "WAN interface: ${IFACE_WAN:-all}"
echo "LAN interface: ${IFACE_LAN:-none}"

# Загружаем модули ядра
modprobe nfnetlink_queue 2>/dev/null
modprobe nf_conntrack 2>/dev/null
modprobe xt_NFQUEUE 2>/dev/null

# Определяем порты
if [ -f "/opt/zapret/game_filter.enabled" ]; then
    TCP_PORTS="80,443,2053,2083,2087,2096,8443,1024:65535"
    UDP_PORTS="443,19294:19344,50000:50100,1024:65535"
    echo "Game Filter: ENABLED (ports 1024-65535)"
else
    TCP_PORTS="80,443,2053,2083,2087,2096,8443,12"
    UDP_PORTS="443,19294:19344,50000:50100,12"
    echo "Game Filter: DISABLED (port 12 only)"
fi

echo "TCP ports: $TCP_PORTS"
echo "UDP ports: $UDP_PORTS"

# ============================================================================
# НАСТРОЙКА NFTABLES
# ============================================================================
if [ "$FWTYPE" = "nftables" ]; then
    echo "Setting up nftables rules..."

    # Удаляем старую таблицу если есть
    nft delete table inet zapret 2>/dev/null

    # Создаём новую таблицу
    nft add table inet zapret

    # Создаём цепочки
    nft add chain inet zapret input { type filter hook input priority 0 \; policy accept \; }
    nft add chain inet zapret output { type filter hook output priority 0 \; policy accept \; }
    nft add chain inet zapret forward { type filter hook forward priority 0 \; policy accept \; }

    # Преобразуем порты для nftables (замена : на -)
    NFT_TCP_PORTS="${TCP_PORTS//:/-}"
    NFT_UDP_PORTS="${UDP_PORTS//:/-}"

    # Правила для INPUT (входящий трафик)
    if [ -n "$IFACE_WAN" ]; then
        for iface in $IFACE_WAN; do
            echo "Adding INPUT rules for interface: $iface"
            nft add rule inet zapret input iifname "$iface" tcp dport "{ $NFT_TCP_PORTS }" queue num 200 bypass
            nft add rule inet zapret input iifname "$iface" udp dport "{ $NFT_UDP_PORTS }" queue num 200 bypass
        done
    else
        echo "Adding INPUT rules for all interfaces"
        nft add rule inet zapret input tcp dport "{ $NFT_TCP_PORTS }" queue num 200 bypass
        nft add rule inet zapret input udp dport "{ $NFT_UDP_PORTS }" queue num 200 bypass
    fi

    # Правила для OUTPUT (исходящий трафик - ОСНОВНОЕ для обычного ПК)
    echo "Adding OUTPUT rules"
    nft add rule inet zapret output tcp dport "{ $NFT_TCP_PORTS }" queue num 200 bypass
    nft add rule inet zapret output udp dport "{ $NFT_UDP_PORTS }" queue num 200 bypass

    # Правила для FORWARD (проходящий трафик - для роутеров)
    if [ -n "$IFACE_LAN" ]; then
        for iface in $IFACE_LAN; do
            echo "Adding FORWARD rules for LAN interface: $iface"
            nft add rule inet zapret forward iifname "$iface" tcp dport "{ $NFT_TCP_PORTS }" queue num 200 bypass
            nft add rule inet zapret forward iifname "$iface" udp dport "{ $NFT_UDP_PORTS }" queue num 200 bypass
        done
    else
        echo "No LAN interface specified, skipping FORWARD rules"
    fi

    echo "nftables rules configured successfully."

# ============================================================================
# НАСТРОЙКА IPTABLES
# ============================================================================
elif [ "$FWTYPE" = "iptables" ]; then
    echo "Setting up iptables rules..."

    # Создаём новую цепочку zapret
    iptables -t mangle -N zapret 2>/dev/null
    iptables -t mangle -F zapret

    # Функция добавления правил для конкретного интерфейса или для всех
    add_iptables_rules() {
        local chain=$1
        local iface_opt=$2
        
        echo "Adding $chain rules ${iface_opt:+for interface: $iface_opt}"
        
        # TCP правила
        if [ -n "$iface_opt" ]; then
            iptables -t mangle -A zapret $iface_opt -p tcp -m multiport --dports "$TCP_PORTS" -j NFQUEUE --queue-num 200 --queue-bypass
        else
            iptables -t mangle -A zapret -p tcp -m multiport --dports "$TCP_PORTS" -j NFQUEUE --queue-num 200 --queue-bypass
        fi
        
        # UDP правила
        if [ -n "$iface_opt" ]; then
            iptables -t mangle -A zapret $iface_opt -p udp -m multiport --dports "$UDP_PORTS" -j NFQUEUE --queue-num 200 --queue-bypass
        else
            iptables -t mangle -A zapret -p udp -m multiport --dports "$UDP_PORTS" -j NFQUEUE --queue-num 200 --queue-bypass
        fi
    }

    # Правила для INPUT (входящий трафик)
    if [ -n "$IFACE_WAN" ]; then
        for iface in $IFACE_WAN; do
            iptables -t mangle -A INPUT -i "$iface" -j zapret
        done
    else
        iptables -t mangle -A INPUT -j zapret
    fi

    # Правила для OUTPUT (исходящий трафик - ОСНОВНОЕ для обычного ПК)
    echo "Adding OUTPUT rules"
    add_iptables_rules "OUTPUT"
    iptables -t mangle -A OUTPUT -j zapret

    # Правила для FORWARD (проходящий трафик - для роутеров)
    if [ -n "$IFACE_LAN" ]; then
        for iface in $IFACE_LAN; do
            echo "Adding FORWARD rules for LAN interface: $iface"
            iptables -t mangle -A FORWARD -i "$iface" -j zapret
        done
    else
        echo "No LAN interface specified, skipping FORWARD rules"
    fi

    # Добавляем правила в цепочку zapret
    add_iptables_rules "zapret"

    echo "iptables rules configured successfully."

else
    echo "ERROR: Unknown firewall type: $FWTYPE"
    echo "Supported types: nftables, iptables"
    exit 1
fi

# ============================================================================
# ЗАПУСК NFQWS
# ============================================================================
echo "Starting nfqws with 8 profiles..."

# Запускаем nfqws (массив аргументов передаётся правильно)
/opt/zapret/system/nfqws --qnum=200 "${NFQWS_ARGS[@]}" &

# Сохраняем PID
echo $! > /var/run/zapret.pid

sleep 1

# Проверяем что процесс запустился
if ps -p $(cat /var/run/zapret.pid 2>/dev/null) > /dev/null 2>&1; then
    echo "zapret started successfully (PID: $(cat /var/run/zapret.pid))"
else
    echo "ERROR: nfqws failed to start!"
    journalctl -u zapret -n 10 --no-pager
    exit 1
fi
