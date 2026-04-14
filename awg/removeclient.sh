#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Error: CLIENT_NAME argument is not provided"
    exit 1
fi

if [ -z "$2" ]; then
    echo "Error: WG_CONFIG_FILE argument is not provided"
    exit 1
fi

if [ -z "$3" ]; then
    echo "Error: WG_CMD argument is not provided"
    exit 1
fi

CLIENT_NAME="$1"
WG_CONFIG_FILE="$2"
WG_CMD="$3"

WG_QUICK_CMD="${WG_CMD}-quick"

sed -i "/^# BEGIN_PEER $CLIENT_NAME$/, /^# END_PEER $CLIENT_NAME$/d" "$WG_CONFIG_FILE"

$WG_CMD syncconf $(basename "$WG_CONFIG_FILE" .conf) <($WG_QUICK_CMD strip $(basename "$WG_CONFIG_FILE" .conf))

rm -f "users/$CLIENT_NAME/$CLIENT_NAME.conf" "users/$CLIENT_NAME/$CLIENT_NAME.png"

rmdir "users/$CLIENT_NAME"

echo "Client $CLIENT_NAME successfully removed from WireGuard"
