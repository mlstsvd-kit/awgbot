#!/bin/bash

detect_available_configs() {
    available_types=()
    if dpkg -l | grep -q "^ii\s\+wireguard\s"; then
        available_types+=("WireGuard")
    fi
    if dpkg -l | grep -q "^ii\s\+amneziawg\s"; then
        available_types+=("AmneziaWG")
    fi
    if [[ ${#available_types[@]} -eq 0 ]]; then
        echo "Ошибка: WireGuard и AmneziaWG не установлены в системе." >&2
        exit 1
    fi
}

choose_config_type() {
    echo "Выберите тип конфигурации:" >&2
    for i in "${!available_types[@]}"; do
        index=$((i + 1))
        echo "$index) ${available_types[$i]}" >&2
    done
    echo -n "Введите номер: " >&2
    read config_choice
    if [[ -z "$config_choice" ]]; then
        config_choice=1
    fi
    while [[ ! "$config_choice" =~ ^[1-${#available_types[@]}]$ ]]; do
        echo "Неверный выбор. Пожалуйста, введите число от 1 до ${#available_types[@]}." >&2
        echo -n "Введите номер: " >&2
        read config_choice
        if [[ -z "$config_choice" ]]; then
            config_choice=1
        fi
    done
    CONFIG_TYPE="${available_types[$((config_choice - 1))]}"
}

check_installed() {
    if [[ "$CONFIG_TYPE" == "AmneziaWG" && ! $(command -v awg) ]]; then
        echo "AmneziaWG не установлен в системе. Обратитесь к ресурсу https://github.com/amnezia-vpn/amneziawg-linux-kernel-module" >&2
        exit 1
    elif [[ "$CONFIG_TYPE" == "WireGuard" && ! $(command -v wg) ]]; then
        echo "WireGuard не установлен в системе. Обратитесь к ресурсу https://www.wireguard.com/install" >&2
        exit 1
    fi
}

is_port_used() {
    local port=$1
    local config_dir=$2
    if grep -Eq "^ListenPort\s*=\s*$port" "$config_dir"/*.conf 2>/dev/null; then
        return 0
    fi
    if ss -tuln | grep -w ":$port " >/dev/null 2>&1 || netstat -tuln | grep -w ":$port " >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

choose_port() {
    while true; do
        echo -n "Какой порт использовать? " >&2
        read port
        if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
            if is_port_used "$port" "$config_dir"; then
                echo "Порт $port уже занят. Пожалуйста, выберите другой порт." >&2
            else
                PORT="$port"
                break
            fi
        else
            echo "Порт должен быть числом от 1 до 65535." >&2
        fi
    done
}

choose_ipv6() {
    ip6_address=""
    ipv6_list=($(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f1 | grep -oE '([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}'))
    if [[ ${#ipv6_list[@]} -gt 0 ]]; then
        echo "Доступны подсети IPv6:" >&2
        for i in "${!ipv6_list[@]}"; do
            index=$((i + 1))
            echo "$index) ${ipv6_list[$i]}" >&2
        done
        last_option=$(( ${#ipv6_list[@]} +1 ))
        echo "$last_option) Не использовать" >&2
        echo -n "Введите номер: " >&2
        read ip6_number
        until [[ "$ip6_number" =~ ^[0-9]+$ && "$ip6_number" -ge 1 && "$ip6_number" -le "$last_option" ]]; do
            echo "$ip6_number: неверный выбор." >&2
            echo -n "Введите номер: " >&2
            read ip6_number
        done
        if [[ "$ip6_number" -le ${#ipv6_list[@]} ]]; then
            selected_ipv6=${ipv6_list[$((ip6_number -1))]}
            IFS=':' read -r -a segments <<< "$selected_ipv6"
            if [[ "${segments[0]}" =~ ^200 ]]; then
                segments[0]=300
                base_ipv6="${segments[0]}:${segments[1]}:${segments[2]}:${segments[3]}"
                ip6_address="${base_ipv6}::1/64"
            else
                echo "Первый сегмент IPv6 адреса не начинается с 200. IPv6 адрес не будет добавлен." >&2
            fi
        fi
    fi
    echo "$ip6_address"
}

choose_dns() {
    echo "Выберите DNS-сервер:" >&2
    echo "1) Текущие системные резолверы" >&2
    echo "2) Google (8.8.8.8)" >&2
    echo "3) Cloudflare (1.1.1.1)" >&2
    echo "4) OpenDNS (208.67.222.222,208.67.220.220)" >&2
    echo "5) Quad9 (9.9.9.9,149.112.112.112)" >&2
    echo "6) AdGuard (94.140.14.14,94.140.15.15)" >&2
    echo "7) Пользовательский DNS" >&2
    echo -n "Введите номер: " >&2
    read dns_choice
    if [[ -z "$dns_choice" ]]; then
        dns_choice=1
    fi
    while [[ ! "$dns_choice" =~ ^[1-7]$ ]]; do
        echo "Неверный выбор. Пожалуйста, введите число от 1 до 7." >&2
        echo -n "Введите номер: " >&2
        read dns_choice
        if [[ -z "$dns_choice" ]]; then
            dns_choice=1
        fi
    done
    case "$dns_choice" in
        1)
            dns_servers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ", " -)
            if [[ -z "$dns_servers" ]]; then
                echo "Не удалось найти системные резолверы в /etc/resolv.conf. Пожалуйста, выберите другой вариант." >&2
                choose_dns
            else
                DNS="$dns_servers"
            fi
            ;;
        2) DNS="8.8.8.8" ;;
        3) DNS="1.1.1.1" ;;
        4) DNS="208.67.222.222, 208.67.220.220" ;;
        5) DNS="9.9.9.9, 149.112.112.112" ;;
        6) DNS="94.140.14.14, 94.140.15.15" ;;
        7)
            echo -n "Введите DNS-серверы (разделенные пробелом, например: 1.1.1.1 8.8.4.4): " >&2
            read custom_dns
            valid=true
            for dns in $custom_dns; do
                if [[ ! "$dns" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    echo "Неверный формат DNS-сервера: $dns" >&2
                    valid=false
                fi
            done
            if $valid; then
                DNS=$(echo "$custom_dns" | tr ' ' ', ')
            else
                echo "Пожалуйста, введите корректные DNS-серверы." >&2
                choose_dns
            fi
            ;;
        *) DNS="8.8.8.8" ;;
    esac
}

generate_private_key() {
    [[ "$1" == "AmneziaWG" ]] && awg genkey || wg genkey
}

get_next_config_number() {
    local dir=$1 prefix=$2 current_number=0
    while [[ -f "$dir/${prefix}${current_number}.conf" ]]; do
        ((current_number++))
    done
    echo "$current_number"
}

get_next_subnet() {
    local dir=$1 subnet_prefix="10" max_octet=255
    used_subnets=()
    shopt -s nullglob
    for file in "$dir"/*.conf; do
        addresses=$(grep '^Address = ' "$file" | awk -F'=' '{print $2}' | tr ',' '\n' | sed 's/ //g')
        for addr in $addresses; do
            if [[ "$addr" =~ ^10\.([0-9]{1,3})\.([0-9]{1,3})\.1/24$ ]]; then
                used_subnets+=("10.${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.0/24")
            fi
        done
    done
    shopt -u nullglob
    for x in $(seq 0 $max_octet); do
        for y in $(seq 0 $max_octet); do
            subnet="10.$x.$y.0/24"
            if [[ ! " ${used_subnets[@]} " =~ " $subnet " ]]; then
                echo "$subnet"
                return 0
            fi
        done
    done
    echo ""
    return 1
}

assign_subnet() {
    local subnet=$1 ip6_address=$2
    local address="${subnet%.*}.1/24"
    [[ -n "$ip6_address" ]] && address="${address}, ${ip6_address}"
    echo "$address"
}

generate_config() {
    local config_file=$1 address=$2
    if [[ "$CONFIG_TYPE" == "AmneziaWG" ]]; then
        cat > "$config_file" << EOF
[Interface]
Address = $address

DNS = $DNS

Jc = 4
Jmin = 15
Jmax = 1268
S1 = 131
S2 = 45
H1 = 1004746675
H2 = 1157755290
H3 = 1273046607
H4 = 2137162994

ListenPort = $PORT

PrivateKey = $private_key

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
EOF
    else
        cat > "$config_file" << EOF
[Interface]
Address = $address

DNS = $DNS

ListenPort = $PORT

PrivateKey = $private_key

PostUp = iptables -t nat -A POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -o \$(ip route | awk '/default/ {print \$5; exit}') -j MASQUERADE
EOF
    fi
}

detect_available_configs
choose_config_type

if [[ "$CONFIG_TYPE" == "AmneziaWG" ]]; then
    config_dir="/etc/amnezia/amneziawg"
    config_prefix="awg"
else
    config_dir="/etc/wireguard"
    config_prefix="wg"
fi

check_installed
[[ ! -d "$config_dir" ]] && mkdir -p "$config_dir"

choose_port
ip6_address=$(choose_ipv6)
choose_dns
private_key=$(generate_private_key "$CONFIG_TYPE")
config_number=$(get_next_config_number "$config_dir" "$config_prefix")
config_file="${config_dir}/${config_prefix}${config_number}.conf"
interface_name="${config_prefix}${config_number}"

subnet=$(get_next_subnet "$config_dir")
[[ -z "$subnet" ]] && { echo "Ошибка: Все возможные подсети 10.x.y.0/24 заняты." >&2; exit 1; }

address=$(assign_subnet "$subnet" "$ip6_address")
generate_config "$config_file" "$address"

chmod 600 "$config_file"
echo "Генерация конфигурации завершена успешно." >&2

if [[ "$CONFIG_TYPE" == "AmneziaWG" ]]; then
    awg-quick up "$interface_name"
    systemctl enable awg-quick@"$interface_name"
else
    wg-quick up "$interface_name"
    systemctl enable wg-quick@"$interface_name"
fi
