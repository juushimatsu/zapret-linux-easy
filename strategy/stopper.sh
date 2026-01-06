#!/bin/bash

# Останавливаем nfqws
if [ -f /var/run/zapret.pid ]; then
    kill $(cat /var/run/zapret.pid) 2>/dev/null
    rm /var/run/zapret.pid
fi

killall nfqws 2>/dev/null

# Очистка nftables
FWTYPE=$(cat /opt/zapret/system/FWTYPE 2>/dev/null || echo "nftables")
if [ "$FWTYPE" = "nftables" ]; then
    nft delete table inet zapret 2>/dev/null
fi
