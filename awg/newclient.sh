#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Error: CLIENT_NAME argument is not provided"
    exit 1
fi

if [ -z "$2" ]; then
    echo "Error: ENDPOINT argument is not provided"
    exit 1
fi

if [ -z "$3" ]; then
    echo "Error: WG_CONFIG_FILE argument is not provided"
    exit 1
fi

if [ -z "$4" ]; then
    echo "Error: WG_CMD argument is not provided"
    exit 1
fi

CLIENT_NAME="$1"
ENDPOINT="$2"
WG_CONFIG_FILE="$3"
WG_CMD="$4"

if [ "$5" == "ipv6" ]; then
    IPV6="yes"
else
    IPV6="no"
fi

#WG_QUICK_CMD="${WG_CMD}-quick"

if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid CLIENT_NAME. Only letters, numbers, underscores, and hyphens are allowed."
    exit 1
fi

internal_subnet=$(awk '
    /^\[Interface\]/ {flag=1; next}
    /^\[/ {flag=0}
    flag && /^Address\s*=/ {
        sub(/^Address\s*=\s*/, "")
        n = split($0, addr, ",")
        for(i=1;i<=n;i++) {
            gsub(/^[ \t]+|[ \t]+$/, "", addr[i])
            if (addr[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
                split(addr[i], a, "/")
                print a[1]"/"a[2]
                exit
            }
        }
    }
' "$WG_CONFIG_FILE")

if [ -z "$internal_subnet" ]; then
    echo "Error: Internal IPv4 subnet not found in WireGuard configuration."
    exit 1
fi

IFS='/' read -r subnet base_prefix <<< "$internal_subnet"
IFS='.' read -r a b c <<< "$subnet"

if [ "$base_prefix" -ne 24 ]; then
    echo "Error: Unsupported subnet prefix. Only /24 is supported."
    exit 1
fi

base_subnet="${a}.${b}.${c}"
octet=2
while grep -E "AllowedIPs\s*=\s*$base_subnet\.$octet/32" "$WG_CONFIG_FILE" > /dev/null; do
    (( octet++ ))
done

if [ "$octet" -gt 254 ]; then
    echo "Error: WireGuard internal subnet $base_subnet.0/24 is full"
    exit 1
fi

pwd=$(pwd)

mkdir -p "$pwd/users/$CLIENT_NAME"

key=$($WG_CMD genkey)
psk=$($WG_CMD genpsk)

get_value() {
    local key="$1"
    value=$(awk -F '=' -v k="$key" '$1 ~ k {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' "$WG_CONFIG_FILE")

    if [[ -z "$value" ]]; then
        value=0
        echo "Значение для '$key' не найдено. Устанавливаем в 0."
    fi

    echo "$value"
}

dns_servers=$(awk '/^\[Interface\]/ {flag=1; next} /^\[/ {flag=0} flag && /^DNS\s*=/ {
    gsub(/DNS\s*=\s*/, "")
    print
    exit
}' "$WG_CONFIG_FILE")

if [ -z "$dns_servers" ]; then
    dns_servers="8.8.8.8, 8.8.4.4"
    echo "DNS servers not found in WireGuard configuration. Using default DNS 8.8.8.8."
fi

if [ "$IPV6" == "yes" ]; then
    ipv6_subnet=$(awk '
        /^\[Interface\]/ {flag=1; next}
        /^\[/ {flag=0}
        flag && /^Address\s*=/ {
            for(i=1;i<=NF;i++) {
                if ($i ~ /:/) {
                    split($i, b, "/")
                    ipv6_addr=b[1]
                    if (match(ipv6_addr, /^(.*)::[0-9a-fA-F]+$/, arr)) {
                        print arr[1]"::/64"
                        exit
                    } else {
                        match(ipv6_addr, /^(.*):[^:]+$/, arr)
                        if (arr[1] != "") {
                            print arr[1]":/64"
                            exit
                        }
                    }
                }
            }
        }
    ' "$WG_CONFIG_FILE")
    
    if [ -z "$ipv6_subnet" ]; then
        echo "Error: IPv6 subnet not found in WireGuard configuration."
        exit 1
    fi

    prefix=$(echo "$ipv6_subnet" | sed 's/\(.*\)::.*$/\1::/')
    ipv6_subnet_escaped=$(echo "$ipv6_subnet" | sed 's/:/\\:/g')
    existing_ipv6=$(grep -E "^AllowedIPs\s*=\s*$base_subnet\.$octet/32,\s*${ipv6_subnet_escaped}[0-9a-fA-F]+/128" "$WG_CONFIG_FILE" | awk -F',' '{print $2}' | awk '{print $1}' | sed "s|${prefix}||" | sed 's|/128||')

    max_host=1
    for ip_suffix in $existing_ipv6; do
        if [[ "$ip_suffix" =~ ^[0-9a-fA-F]+$ ]]; then
            host_num=$((16#$ip_suffix))
            if [ "$host_num" -gt "$max_host" ]; then
                max_host=$host_num
            fi
        fi
    done
    next_host_num=$((max_host +1))
    client_ipv6="${prefix}${next_host_num}/128"
    ALLOWED_IPS="$base_subnet.$octet/32, $client_ipv6"
else
    ALLOWED_IPS="$base_subnet.$octet/32"
fi

server_private_key=$(awk '/^PrivateKey\s*=/ {print $3}' "$WG_CONFIG_FILE")
if [ -z "$server_private_key" ]; then
    echo "Error: Server PrivateKey not found in WireGuard configuration."
    exit 1
fi
server_public_key=$(echo "$server_private_key" | $WG_CMD pubkey)

cat << EOF >> "$WG_CONFIG_FILE"
# BEGIN_PEER $CLIENT_NAME
[Peer]
PublicKey = $(echo "$key" | $WG_CMD pubkey)
PresharedKey = $psk
AllowedIPs = $ALLOWED_IPS
# END_PEER $CLIENT_NAME
EOF

if [ "$IPV6" == "yes" ]; then
    listen_port=$(awk '/ListenPort\s*=/ {print $3}' "$WG_CONFIG_FILE")
    cat << EOF > "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
[Interface]
Address = $ALLOWED_IPS
DNS = $dns_servers
PrivateKey = $key
EOF

    if [[ "$WG_CONFIG_FILE" == *amnezia* ]]; then
        cat << EOF >> "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
    Jc=$(get_value "Jc")
    Jmin=$(get_value "Jmin")
    Jmax=$(get_value "Jmax")
    H1=$(get_value "H1")
    H2=$(get_value "H2")
    H3=$(get_value "H3")
    H4=$(get_value "H4")
EOF
    fi

    cat << EOF >> "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
[Peer]
PublicKey = $server_public_key
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $ENDPOINT:$listen_port
PersistentKeepalive = 25
EOF
else
    listen_port=$(awk '/ListenPort\s*=/ {print $3}' "$WG_CONFIG_FILE")
    cat << EOF > "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
[Interface]
Address = $ALLOWED_IPS
DNS = $dns_servers
PrivateKey = $key
EOF

    if [[ "$WG_CONFIG_FILE" == *amnezia* ]]; then
        cat << EOF >> "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
    Jc=$(get_value "Jc")
    Jmin=$(get_value "Jmin")
    Jmax=$(get_value "Jmax")
    H1=$(get_value "H1")
    H2=$(get_value "H2")
    H3=$(get_value "H3")
    H4=$(get_value "H4")
EOF
    fi

    cat << EOF >> "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf"
[Peer]
PublicKey = $server_public_key
PresharedKey = $psk
AllowedIPs = 0.0.0.0/0
Endpoint = $ENDPOINT:$listen_port
PersistentKeepalive = 25
EOF
fi

qrencode -l L < "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.conf" -o "$pwd/users/$CLIENT_NAME/$CLIENT_NAME.png"

$WG_CMD addconf "$(basename "$WG_CONFIG_FILE" .conf)" <(sed -n "/^# BEGIN_PEER $CLIENT_NAME$/, /^# END_PEER $CLIENT_NAME$/p" "$WG_CONFIG_FILE")

echo "Client $CLIENT_NAME successfully added to WireGuard"
