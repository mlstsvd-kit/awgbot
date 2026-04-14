import os
import subprocess
import configparser
import json
import pytz
import glob
import sys
import socket
import re
from datetime import datetime

EXPIRATIONS_FILE = 'files/expirations.json'
UTC = pytz.UTC

def check_installed_vpn():
    installed_vpn = []
    try:
        wg_check = subprocess.run('dpkg -l | grep wireguard', 
                                shell=True, capture_output=True, text=True)
        if 'ii  wireguard' in wg_check.stdout:
            installed_vpn.append("WireGuard")

        amnezia_check = subprocess.run('dpkg -l | grep amneziawg', 
                                     shell=True, capture_output=True, text=True)
        if 'ii  amneziawg' in amnezia_check.stdout:
            installed_vpn.append("AmneziaWG")

    except subprocess.CalledProcessError:
        pass
    return installed_vpn

def create_config(path='files/setting.ini'):
    try:
        endpoint = subprocess.check_output("curl -s https://api.ipify.org", shell=True).decode().strip()
        socket.inet_aton(endpoint)
    except (subprocess.CalledProcessError, socket.error):
        print("Ошибка при определении внешнего IP-адреса сервера.")
        endpoint = input('Не удалось автоматически определить внешний IP-адрес. Пожалуйста, введите его вручную: ').strip()
        try:
            socket.inet_aton(endpoint)
        except socket.error:
            print("Введён некорректный IP-адрес. Инициализация прервана.")
            sys.exit(1)

    wireguard_dir = "/etc/wireguard"
    amnezia_dir = "/etc/amnezia/amneziawg"

    installed_vpn = check_installed_vpn()
    if not installed_vpn:
        print("AmneziaWG или WireGuard не установлен в системе. Инициализация не завершена.")
        sys.exit(0)

    configs = []
    if "WireGuard" in installed_vpn and os.path.exists(wireguard_dir):
        configs.extend(glob.glob(os.path.join(wireguard_dir, "*.conf")))
    if "AmneziaWG" in installed_vpn and os.path.exists(amnezia_dir):
        configs.extend(glob.glob(os.path.join(amnezia_dir, "*.conf")))

    print(f"В системе установлены: {', '.join(installed_vpn)}\n")

    if configs:
        print("Доступные конфигурации:")
        for idx, conf in enumerate(configs, 1):
            print(f"{idx}) {conf}")
        print(f"{len(configs) + 1}) Создать новую конфигурацию")

        while True:
            choice = input("\nВведите номер: ").strip()
            if choice.isdigit():
                choice = int(choice)
                if 1 <= choice <= len(configs):
                    selected_conf = configs[choice - 1]
                    break
                elif choice == len(configs) + 1:
                    subprocess.run(["./genconf.sh"])
                    new_configs = []
                    if "WireGuard" in installed_vpn:
                        new_configs.extend(glob.glob(os.path.join(wireguard_dir, "*.conf")))
                    if "AmneziaWG" in installed_vpn:
                        new_configs.extend(glob.glob(os.path.join(amnezia_dir, "*.conf")))
                    new_config = set(new_configs) - set(configs)
                    if new_config:
                        selected_conf = list(new_config)[0]
                        break
                    else:
                        print("Не удалось найти новую конфигурацию")
                        sys.exit(1)
            print("Неверный выбор. Пожалуйста, введите корректный номер.")
    else:
        print("Конфигурации отсутствуют\n")
        print("Создать новую конфигурацию?\n")
        print("1) Да")
        print("2) Нет")

        while True:
            choice = input("Введите номер: ").strip()
            if choice == "1":
                subprocess.run(["./genconf.sh"])
                new_configs = []
                if "WireGuard" in installed_vpn:
                    new_configs.extend(glob.glob(os.path.join(wireguard_dir, "*.conf")))
                if "AmneziaWG" in installed_vpn:
                    new_configs.extend(glob.glob(os.path.join(amnezia_dir, "*.conf")))
                if new_configs:
                    selected_conf = new_configs[0]
                    break
                else:
                    print("Не удалось создать конфигурацию")
                    sys.exit(1)
            elif choice == "2":
                print("Инициализация не завершена")
                sys.exit(0)
            else:
                print("Неверный выбор. Пожалуйста, введите 1 или 2")

    bot_token = input("Введите токен Telegram бота: ").strip()
    admin_id = input("Введите Telegram ID администратора: ").strip()

    os.makedirs("files", exist_ok=True)
    with open(path, "w") as f:
        config = configparser.ConfigParser()
        config.add_section("setting")
        config.set("setting", "bot_token", bot_token)
        config.set("setting", "admin_id", admin_id)
        config.set("setting", "wg_config_file", selected_conf)
        config.set("setting", "endpoint", endpoint)
        config.write(f)

def save_client_endpoint(username, endpoint):
    os.makedirs('files/connections', exist_ok=True)
    file_path = os.path.join('files', 'connections', f'{username}_ip.json')
    timestamp = datetime.now().strftime('%d.%m.%Y %H:%M')
    ip_address = endpoint.split(':')[0]

    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            try:
                data = json.load(f)
            except json.JSONDecodeError:
                data = {}
    else:
        data = {}

    data[ip_address] = timestamp

    with open(file_path, 'w') as f:
        json.dump(data, f)

def get_all_clients_transfer():

    setting = get_config()
    wg_config_file = setting['wg_config_file']
    WG_CMD = get_wg_cmd()

    try:
        call = subprocess.check_output(
            f"awk '/^# BEGIN_PEER / {{peer=$3}}; /^PublicKey/ {{print peer, $3}}' {wg_config_file}",
            shell=True
        )
        client_data = call.decode('utf-8').strip().split('\n')

        client_key = {}
        for data in client_data:
            if data:
                parts = data.strip().split()
                if len(parts) >= 2:
                    name = parts[0].strip()
                    public_key = parts[1].strip()
                    client_key[public_key] = name

        call = subprocess.check_output(f"{WG_CMD} show interfaces", shell=True)
        interfaces = call.decode('utf-8').strip().split('\n')

        clients_transfer = {}

        for interface in interfaces:
            call = subprocess.check_output(f"{WG_CMD} show {interface} transfer", shell=True)
            transfer_output = call.decode('utf-8').strip().split('\n')


            for line in transfer_output:
                parts = line.strip().split()
                if len(parts) == 3:
                    public_key = parts[0].strip()
                    received_bytes = int(parts[1].strip())
                    sent_bytes = int(parts[2].strip())

                    username = client_key.get(public_key)
                    if username:
                        if username not in clients_transfer:
                            clients_transfer[username] = {'received_bytes': 0, 'sent_bytes': 0}
                        clients_transfer[username]['received_bytes'] += received_bytes
                        clients_transfer[username]['sent_bytes'] += sent_bytes

        return [
            {
                'username': username,
                'received_bytes': data['received_bytes'],
                'sent_bytes': data['sent_bytes']
            }
            for username, data in clients_transfer.items()
        ]

    except subprocess.CalledProcessError as e:
        return []

def get_config(path='files/setting.ini'):
    if not os.path.exists(path):
        create_config(path)

    config = configparser.ConfigParser()
    config.read(path)
    return {key: config['setting'][key] for key in config['setting']}

def get_wg_cmd():
    setting = get_config()
    wg_config_file = setting['wg_config_file']
    return 'awg' if 'amnezia' in wg_config_file.lower() else 'wg'

def root_add(id_user, ipv6=False):
    setting = get_config()
    endpoint = setting['endpoint']
    wg_config_file = setting['wg_config_file']
    WG_CMD = get_wg_cmd()

    cmd = ["./newclient.sh", id_user, endpoint, wg_config_file, WG_CMD]
    if ipv6:
        cmd.append('ipv6')

    return subprocess.call(cmd) == 0

def get_client_list():
    setting = get_config()
    wg_config_file = setting['wg_config_file']

    try:
        call = subprocess.check_output(f"awk '/# BEGIN_PEER/ {{print $3}}' {wg_config_file}", shell=True)
        client_list = call.decode('utf-8').strip().split('\n')

        call = subprocess.check_output(f"awk '/AllowedIPs/ {{sub(/AllowedIPs = /,\"\"); print}}' {wg_config_file}", shell=True)
        ip_list = call.decode('utf-8').strip().split('\n')

        return [[client, ip_list[n].strip()] for n, client in enumerate(client_list) if client]
    except subprocess.CalledProcessError:
        return []

def get_active_list():
    import subprocess
    import re

    setting = get_config()
    wg_config_file = setting['wg_config_file']
    WG_CMD = get_wg_cmd()

    try:
        call = subprocess.check_output(
            f"awk '/^# BEGIN_PEER / {{peer=$3}}; /^PublicKey/ {{print peer, $3}}' {wg_config_file}",
            shell=True
        )
        client_data = call.decode('utf-8').strip().split('\n')

        client_key = {}
        for data in client_data:
            if data:
                parts = data.strip().split()
                if len(parts) >= 2:
                    name = parts[0].strip()
                    public_key = parts[1].strip()
                    client_key[public_key] = name

        call = subprocess.check_output(f"{WG_CMD} show interfaces", shell=True)
        interfaces = call.decode('utf-8').strip().split('\n')

        active_clients = []

        for interface in interfaces:
            call = subprocess.check_output(f"{WG_CMD} show {interface} peers", shell=True)
            peers = call.decode('utf-8').strip().split('\n')

            call = subprocess.check_output(f"{WG_CMD} show {interface} latest-handshakes", shell=True)
            handshake_output = call.decode('utf-8').strip().split('\n')
            handshake_dict = {}
            for line in handshake_output:
                parts = line.strip().split('\t')
                if len(parts) == 2:
                    peer_key = parts[0].strip()
                    handshake_time = parts[1].strip()
                    handshake_dict[peer_key] = handshake_time

            call = subprocess.check_output(f"{WG_CMD} show {interface} endpoints", shell=True)
            endpoints_output = call.decode('utf-8').strip().split('\n')
            endpoint_dict = {}
            for line in endpoints_output:
                parts = line.strip().split('\t')
                if len(parts) == 2:
                    peer_key = parts[0].strip()
                    endpoint = parts[1].strip()
                    endpoint_dict[peer_key] = endpoint

            call = subprocess.check_output(f"{WG_CMD} show {interface} transfer", shell=True)
            transfer_output = call.decode('utf-8').strip().split('\n')
            transfer_dict = {}
            for line in transfer_output:
                parts = line.strip().split()
                if len(parts) == 3:
                    peer_key = parts[0].strip()
                    rx_bytes = int(parts[1].strip())
                    tx_bytes = int(parts[2].strip())
                    transfer_dict[peer_key] = (rx_bytes, tx_bytes)

            for peer in peers:
                peer = peer.strip()
                username = client_key.get(peer)
                if username:
                    latest_handshake = handshake_dict.get(peer, '0')
                    endpoint = endpoint_dict.get(peer, 'N/A')
                    rx_bytes, tx_bytes = transfer_dict.get(peer, (0, 0))
                    transfer_info = f"{rx_bytes} bytes received, {tx_bytes} bytes sent"

                    if latest_handshake != '0':
                        latest_handshake_time = datetime.fromtimestamp(int(latest_handshake), pytz.UTC)
                        last_handshake_str = str(int(latest_handshake_time.timestamp()))
                    else:
                        last_handshake_str = '0'

                    save_client_endpoint(username, endpoint)
                    active_clients.append([username, last_handshake_str, transfer_info, endpoint])

        return active_clients

    except subprocess.CalledProcessError as e:
        print(f"Ошибка при получении активных клиентов: {e}")
        return []

def deactive_user_db(id_user):
    setting = get_config()
    wg_config_file = setting['wg_config_file']
    WG_CMD = get_wg_cmd()

    return subprocess.call(["./removeclient.sh", id_user, wg_config_file, WG_CMD]) == 0

def load_expirations():
    if not os.path.exists(EXPIRATIONS_FILE):
        return {}
    with open(EXPIRATIONS_FILE, 'r') as f:
        try:
            data = json.load(f)
            for user, timestamp in data.items():
                if timestamp:
                    data[user] = datetime.fromisoformat(timestamp).replace(tzinfo=UTC)
                else:
                    data[user] = None
            return data
        except json.JSONDecodeError:
            return {}

def save_expirations(expirations):
    os.makedirs(os.path.dirname(EXPIRATIONS_FILE), exist_ok=True)
    data = {user: (ts.isoformat() if ts else None) for user, ts in expirations.items()}
    with open(EXPIRATIONS_FILE, 'w') as f:
        json.dump(data, f)

def set_user_expiration(username: str, expiration: datetime):
    expirations = load_expirations()
    if expiration:
        if expiration.tzinfo is None:
            expiration = expiration.replace(tzinfo=UTC)
        expirations[username] = expiration
    else:
        expirations[username] = None
    save_expirations(expirations)

def remove_user_expiration(username: str):
    expirations = load_expirations()
    if username in expirations:
        del expirations[username]
        save_expirations(expirations)

def get_users_with_expiration():
    expirations = load_expirations()
    return [(user, ts.isoformat() if ts else None) for user, ts in expirations.items()]

def get_user_expiration(username: str):
    expirations = load_expirations()
    return expirations.get(username, None)

ADMINS_FILE = 'files/admins.json'

def load_admins():
    if not os.path.exists(ADMINS_FILE):
        return {}
    try:
        with open(ADMINS_FILE, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        return {}

def save_admins(admins):
    os.makedirs(os.path.dirname(ADMINS_FILE), exist_ok=True)
    with open(ADMINS_FILE, 'w') as f:
        json.dump(admins, f, indent=2)

def add_admin(user_id: int, role: str = 'moderator'):
    """Add a new admin or moderator. Roles: 'admin', 'moderator'"""
    admins = load_admins()
    admins[str(user_id)] = {'role': role}
    save_admins(admins)
    return True

def remove_admin(user_id: int):
    """Remove an admin"""
    admins = load_admins()
    if str(user_id) in admins:
        del admins[str(user_id)]
        save_admins(admins)
        return True
    return False

def get_admin_role(user_id: int):
    """Get admin role, returns None if not an admin"""
    admins = load_admins()
    admin_info = admins.get(str(user_id))
    if admin_info:
        return admin_info.get('role', 'moderator')
    return None

def is_admin(user_id: int):
    """Check if user is admin or moderator"""
    return get_admin_role(user_id) is not None

def is_main_admin(user_id: int):
    """Check if user is main admin"""
    return get_admin_role(user_id) == 'admin'

def get_all_admins():
    """Get all admins"""
    return load_admins()
