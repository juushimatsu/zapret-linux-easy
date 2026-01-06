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

# Настройка nftables
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

    # Определяем ВСЕ порты из Windows стратегии включая специальные порты Discord
    if [ -f "/opt/zapret/game_filter.enabled" ]; then
        TCP_PORTS="80,443,2053,2083,2087,2096,8443,1024-65535"
        UDP_PORTS="443,19294-19344,50000-50100,1024-65535"
        echo "Game Filter: ENABLED (ports 1024-65535)"
    else
        TCP_PORTS="80,443,2053,2083,2087,2096,8443,12"
        UDP_PORTS="443,19294-19344,50000-50100,12"
        echo "Game Filter: DISABLED (port 12 only)"
    fi

    echo "TCP ports: $TCP_PORTS"
    echo "UDP ports: $UDP_PORTS"

    # Правила для INPUT (входящий трафик)
    if [ -n "$IFACE_WAN" ]; then
        for iface in $IFACE_WAN; do
            echo "Adding INPUT rules for interface: $iface"
            nft add rule inet zapret input iifname "$iface" tcp dport "{ $TCP_PORTS }" queue num 200 bypass
            nft add rule inet zapret input iifname "$iface" udp dport "{ $UDP_PORTS }" queue num 200 bypass
        done
    else
        echo "Adding INPUT rules for all interfaces"
        nft add rule inet zapret input tcp dport "{ $TCP_PORTS }" queue num 200 bypass
        nft add rule inet zapret input udp dport "{ $UDP_PORTS }" queue num 200 bypass
    fi

    # Правила для OUTPUT (исходящий трафик - ОСНОВНОЕ для обычного ПК)
    echo "Adding OUTPUT rules"
    nft add rule inet zapret output tcp dport "{ $TCP_PORTS }" queue num 200 bypass
    nft add rule inet zapret output udp dport "{ $UDP_PORTS }" queue num 200 bypass

    # Правила для FORWARD (проходящий трафик - ТОЛЬКО если указан LAN интерфейс для роутеров)
    if [ -n "$IFACE_LAN" ]; then
        for iface in $IFACE_LAN; do
            echo "Adding FORWARD rules for LAN interface: $iface"
            nft add rule inet zapret forward iifname "$iface" tcp dport "{ $TCP_PORTS }" queue num 200 bypass
            nft add rule inet zapret forward iifname "$iface" udp dport "{ $UDP_PORTS }" queue num 200 bypass
        done
    else
        echo "No LAN interface specified, skipping FORWARD rules"
    fi

    echo "nftables rules configured successfully."
fi

# Запуск nfqws с нашей стратегией
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
