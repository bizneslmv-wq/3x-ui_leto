#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# Глобальные переменные для итогового вывода
PANEL_USER=""
PANEL_PASS=""
PANEL_PORT=""
PANEL_PATH=""
SERVER_IP_PRINT=""

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
    x86_64 | x64 | amd64) echo 'amd64' ;;
    i*86 | x86) echo '386' ;;
    armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
    armv7* | armv7 | arm) echo 'armv7' ;;
    armv6* | armv6) echo 'armv6' ;;
    armv5* | armv5) echo 'armv5' ;;
    s390x) echo 's390x' ;;
    *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

install_base() {
    case "${release}" in
    ubuntu | debian | armbian)
        apt-get update && apt-get install -y -q wget curl tar tzdata ufw fail2ban
        ;;
    centos | rhel | almalinux | rocky | ol)
        yum -y update && yum install -y -q wget curl tar tzdata
        ;;
    fedora | amzn | virtuozzo)
        dnf -y update && dnf install -y -q wget curl tar tzdata
        ;;
    arch | manjaro | parch)
        pacman -Syu && pacman -Syu --noconfirm wget curl tar tzdata
        ;;
    opensuse-tumbleweed | opensuse-leap)
        zypper refresh && zypper -q install -y wget curl tar timezone
        ;;
    alpine)
        apk update && apk add wget curl tar tzdata
        ;;
    *)
        apt-get update && apt-get install -y -q wget curl tar tzdata ufw fail2ban
        ;;
    esac
}

gen_random_string() {
    local length="$1"
    local random_string
    random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

check_password_strength() {
    local pass="$1"

    if [[ ${#pass} -lt 8 ]]; then
        echo "Пароль должен быть не короче 8 символов."
        return 1
    fi
    if ! [[ "$pass" =~ [a-z] ]]; then
        echo "Пароль должен содержать хотя бы одну строчную букву (a-z)."
        return 1
    fi
    if ! [[ "$pass" =~ [A-Z] ]]; then
        echo "Пароль должен содержать хотя бы одну прописную букву (A-Z)."
        return 1
    fi
    if ! [[ "$pass" =~ [0-9] ]]; then
        echo "Пароль должен содержать хотя бы одну цифру (0-9)."
        return 1
    fi

    return 0
}

configure_ssh() {
    echo -e "${green}=== SSH configuration (port + password) ===${plain}"

    # Смена пароля root
    while true; do
        echo "Введите новый пароль для root:"
        read -s ROOT_PASS1
        echo
        echo "Повторите новый пароль для root:"
        read -s ROOT_PASS2
        echo

        if [[ "$ROOT_PASS1" != "$ROOT_PASS2" ]]; then
            echo -e "${red}Пароли не совпадают. Попробуйте ещё раз.${plain}"
            continue
        fi

        if ! check_password_strength "$ROOT_PASS1"; then
            echo -e "${yellow}Пароль не соответствует требованиям. Попробуйте ещё раз.${plain}"
            continue
        fi

        echo "root:${ROOT_PASS1}" | chpasswd
        echo -e "${green}Пароль root успешно изменён.${plain}"
        break
    done

    # Смена порта SSH
    read -rp "Хотите изменить порт SSH (по умолчанию 22)? [y/N]: " CHANGE_SSH_PORT
    if [[ "$CHANGE_SSH_PORT" =~ ^[Yy]$ ]]; then
        while true; do
            read -rp "Введите новый порт SSH (10000–65535): " NEW_SSH_PORT
            if ! [[ "$NEW_SSH_PORT" =~ ^[0-9]+$ ]]; then
                echo -e "${red}Порт должен быть числом.${plain}"
                continue
            fi
            if (( NEW_SSH_PORT < 10000 || NEW_SSH_PORT > 65535 )); then
                echo -e "${red}Порт должен быть в диапазоне 10000–65535.${plain}"
                continue
            fi
            break
        done

        # Правка /etc/ssh/sshd_config
        if grep -qE '^[#[:space:]]*Port ' /etc/ssh/sshd_config; then
            sed -i "s/^[#[:space:]]*Port .*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
        else
            echo "Port ${NEW_SSH_PORT}" >> /etc/ssh/sshd_config
        fi

        # Разрешаем новый порт SSH и базовые HTTPS-порты в UFW (если установлен)
        if command -v ufw >/dev/null 2>&1; then
            ufw allow "${NEW_SSH_PORT}"/tcp >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
            ufw allow 8443/tcp >/dev/null 2>&1 || true
        fi

        systemctl restart sshd || systemctl restart ssh

        echo -e "${green}Порт SSH изменён на ${NEW_SSH_PORT}.${plain}"
        echo -e "${yellow}Не забудьте подключаться: ssh -p ${NEW_SSH_PORT} user@server${plain}"
    else
        echo -e "${yellow}Порт SSH оставлен без изменений.${plain}"
        # Но всё равно откроем 443 и 8443, если UFW есть
        if command -v ufw >/dev/null 2>&1; then
            ufw allow 443/tcp >/dev/null 2>&1 || true
            ufw allow 8443/tcp >/dev/null 2>&1 || true
        fi
    fi
}

configure_fail2ban() {
    if [[ -f /etc/fail2ban/jail.local ]]; then
        # Обновляем bantime, если строка уже есть
        if grep -q "^bantime" /etc/fail2ban/jail.local; then
            sed -i 's/^bantime.*/bantime  = 2592000/' /etc/fail2ban/jail.local
        else
            sed -i '1i bantime  = 2592000' /etc/fail2ban/jail.local
        fi
    else
        cat >/etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 2592000   ; 30 дней
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
EOF
    fi

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    echo -e "${green}Fail2Ban включён. Время блокировки: 30 дней.${plain}"
}

block_ping() {
    # Запретить входящий ping (ICMP echo-request) через UFW
    if command -v ufw >/dev/null 2>&1; then
        ufw deny proto icmp from any to any >/dev/null 2>&1 || true
        echo -e "${green}Запрет входящих ping (ICMP echo-request) через UFW включён.${plain}"
    fi
}

config_after_install() {
    local existing_hasDefaultCredential=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        server_ip=$(curl -s --max-time 3 "${ip_address}" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "${server_ip}" ]]; then
            break
        fi
    done
    SERVER_IP_PRINT="${server_ip}"

    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath
            local config_username
            local config_password
            local config_port

            config_webBasePath=$(gen_random_string 64)
            config_username=$(gen_random_string 64)
            config_password=$(gen_random_string 64)

            read -rp "Would you like to customize the Panel Port settings? (If not, a random port will be applied) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "Please set up the panel port (10000–65535): " config_port
                if ! [[ "$config_port" =~ ^[0-9]+$ ]]; then
                    echo -e "${red}Порт должен быть числом. Будет выбран случайный порт.${plain}"
                    config_port=$(shuf -i 10000-65535 -n 1)
                fi
                echo -e "${yellow}Your Panel Port is: ${config_port}${plain}"
            else
                config_port=$(shuf -i 10000-65535 -n 1)
                echo -e "${yellow}Generated random port: ${config_port}${plain}"
            fi

            /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
            echo -e "This is a fresh installation, generating random login info for security concerns:"
            echo -e "###############################################"
            echo -e "${green}Username: ${config_username}${plain}"
            echo -e "${green}Password: ${config_password}${plain}"
            echo -e "${green}Port: ${config_port}${plain}"
            echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}Access URL: http://${server_ip}:${config_port}/${config_webBasePath}${plain}"
            echo -e "###############################################"

            # Заполним глобальные переменные
            PANEL_USER="${config_username}"
            PANEL_PASS="${config_password}"
            PANEL_PORT="${config_port}"
            PANEL_PATH="${config_webBasePath}"

            # Открываем порт панели в UFW, если есть
            if command -v ufw >/dev/null 2>&1; then
                ufw allow "${config_port}"/tcp >/dev/null 2>&1 || true
            fi

        else
            local config_webBasePath
            config_webBasePath=$(gen_random_string 64)
            echo -e "${yellow}WebBasePath is missing or too short. Generating a new one...${plain}"
            /usr/local/x-ui/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}New WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}Access URL: http://${server_ip}:${existing_port}/${config_webBasePath}${plain}"

            PANEL_PORT="${existing_port}"
            PANEL_PATH="${config_webBasePath}"

            # Открываем существующий порт панели в UFW, если есть
            if command -v ufw >/dev/null 2>&1 && [[ -n "${existing_port}" ]]; then
                ufw allow "${existing_port}"/tcp >/dev/null 2>&1 || true
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username
            local config_password

            config_username=$(gen_random_string 64)
            config_password=$(gen_random_string 64)

            echo -e "${yellow}Default credentials detected. Security update required...${plain}"
            /usr/local/x-ui/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "Generated new random login credentials:"
            echo -e "###############################################"
            echo -e "${green}Username: ${config_username}${plain}"
            echo -e "${green}Password: ${config_password}${plain}"
            echo -e "###############################################"

            PANEL_USER="${config_username}"
            PANEL_PASS="${config_password}"
            PANEL_PORT="${existing_port}"
            PANEL_PATH="${existing_webBasePath}"
        else
            echo -e "${green}Username, Password, and WebBasePath are properly set. Exiting...${plain}"
            PANEL_PORT="${existing_port}"
            PANEL_PATH="${existing_webBasePath}"
        fi

        # Убедимся, что текущий порт панели открыт в UFW
        if command -v ufw >/dev/null 2>&1 && [[ -n "${existing_port}" ]]; then
            ufw allow "${existing_port}"/tcp >/dev/null 2>&1 || true
        fi
    fi

    /usr/local/x-ui/x-ui migrate
}

# Генерация самоподписанного сертификата и привязка к панели
generate_self_signed_cert() {
    local cert_dir="/usr/local/x-ui/cert"
    local cert_file="${cert_dir}/cert.crt"
    local key_file="${cert_dir}/secret.key"

    mkdir -p "${cert_dir}"

    # Установить openssl, если его нет
    if ! command -v openssl >/dev/null 2>&1; then
        case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q openssl
            ;;
        centos | rhel | almalinux | rocky | ol)
            yum install -y -q openssl
            ;;
        fedora | amzn | virtuozzo)
            dnf install -y -q openssl
            ;;
        arch | manjaro | parch)
            pacman -Syu --noconfirm openssl
            ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper -q install -y openssl
            ;;
        alpine)
            apk add --no-cache openssl
            ;;
        *)
            apt-get update && apt-get install -y -q openssl
            ;;
        esac
    fi

    # Получаем внешний IPv4 сервера (fallback на 127.0.0.1)
    local ip=""
    ip=$(timeout 3 curl -4 -s icanhazip.com || echo "")
    if [[ -z "${ip}" ]]; then
        ip="127.0.0.1"
    fi

    # Генерируем ключ и самоподписанный сертификат на 10 лет
    openssl genrsa -out "${key_file}" 2048
    openssl req -key "${key_file}" -new -out "${cert_dir}/cert.csr" -nodes \
      -subj "/C=AU/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=${ip}" \
      -addext "subjectAltName=DNS:${ip},DNS:*.${ip},IP:${ip}"
    openssl x509 -signkey "${key_file}" -in "${cert_dir}/cert.csr" -req -days 3650 -out "${cert_file}"

    rm -f "${cert_dir}/cert.csr"

    chmod 600 "${key_file}"
    chmod 644 "${cert_file}"

    echo -e "${green}Self-signed certificate generated for 10 years:${plain}"
    echo -e "${yellow}Certificate path:${plain} ${cert_file}"
    echo -e "${yellow}Private key path:${plain} ${key_file}"

    # Привязка сертификата к панели (через CLI x-ui)
    /usr/local/x-ui/x-ui setting -certFile "${cert_file}" -keyFile "${key_file}"
}

install_x-ui() {
    cd /usr/local/

    # Download resources
    if [ $# == 0 ]; then
        tag_version=$(curl -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$tag_version" ]]; then
            echo -e "${yellow}Trying to fetch version with IPv4...${plain}"
            tag_version=$(curl -4 -Ls "https://api.github.com/repos/MHSanaei/3x-ui/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ ! -n "$tag_version" ]]; then
                echo -e "${red}Failed to fetch x-ui version, it may be due to GitHub API restrictions, please try it later${plain}"
                exit 1
            fi
        fi
        echo -e "Got x-ui latest version: ${tag_version}, beginning the installation..."
        wget --inet4-only -N -O /usr/local/x-ui-linux-$(arch).tar.gz https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Downloading x-ui failed, please be sure that your server can access GitHub ${plain}"
            exit 1
        fi
    else
        tag_version=$1
        tag_version_numeric=${tag_version#v}
        min_version="2.3.5"

        if [[ "$(printf '%s\n' "$min_version" "$tag_version_numeric" | sort -V | head -n1)" != "$min_version" ]]; then
            echo -e "${red}Please use a newer version (at least v2.3.5). Exiting installation.${plain}"
            exit 1
        fi

        url="https://github.com/MHSanaei/3x-ui/releases/download/${tag_version}/x-ui-linux-$(arch).tar.gz"
        echo -e "Beginning to install x-ui $1"
        wget --inet4-only -N -O /usr/local/x-ui-linux-$(arch).tar.gz ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Download x-ui $1 failed, please check if the version exists ${plain}"
            exit 1
        fi
    fi
    wget --inet4-only -O /usr/bin/x-ui-temp https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Failed to download x-ui.sh${plain}"
        exit 1
    fi

    # Stop x-ui service and remove old resources
    if [[ -e /usr/local/x-ui/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm /usr/local/x-ui/ -rf
    fi

    # Extract resources and set permissions
    tar zxvf x-ui-linux-$(arch).tar.gz
    rm x-ui-linux-$(arch).tar.gz -f

    cd x-ui
    chmod +x x-ui
    chmod +x x-ui.sh

    # Check the system's architecture and rename the file accordingly
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv bin/xray-linux-$(arch) bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui bin/xray-linux-$(arch)

    # Update x-ui cli and set permission
    mv -f /usr/bin/x-ui-temp /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    # Создаём скрипт смены порта и пути панели
    cat >/usr/local/x-ui/change-panel-access.sh << 'EOF'
#!/bin/bash
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
if [[ $EUID -ne 0 ]]; then
  echo -e "${red}Этот скрипт нужно запускать от root (sudo).${plain}"
  exit 1
fi
if [[ ! -x /usr/local/x-ui/x-ui ]]; then
  echo -e "${red}Не найден /usr/local/x-ui/x-ui. Похоже, 3X-UI не установлен.${plain}"
  exit 1
fi
gen_random_string() {
    local length="$1"
    local random_string
    random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}
existing_port=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
existing_webBasePath=$(/usr/local/x-ui/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}')
echo -e "${yellow}Текущие настройки панели:${plain}"
echo -e "Port: ${green}${existing_port}${plain}"
echo -e "WebBasePath: ${green}${existing_webBasePath}${plain}"
echo
config_port=$(shuf -i 10000-65535 -n 1)
config_webBasePath=$(gen_random_string 64)
echo -e "${yellow}Будут установлены новые значения:${plain}"
echo -e "Новый порт панели: ${green}${config_port}${plain}"
echo -e "Новый WebBasePath: ${green}${config_webBasePath}${plain}"
echo
read -rp "Применить эти настройки? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${yellow}Отменено пользователем.${plain}"
    exit 0
fi
URL_lists=(
    "https://api4.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://v4.api.ipinfo.io/ip"
    "https://ipv4.myexternalip.com/raw"
    "https://4.ident.me"
    "https://check-host.net/ip"
)
server_ip=""
for ip_address in "${URL_lists[@]}"; do
    server_ip=$(curl -s --max-time 3 "${ip_address}" 2>/dev/null | tr -d '[:space:]')
    if [[ -n "${server_ip}" ]]; then
        break
    fi
done
/usr/local/x-ui/x-ui setting -port "${config_port}" -webBasePath "${config_webBasePath}"
if command -v ufw >/dev/null 2>&1; then
    ufw allow "${config_port}"/tcp >/dev/null 2>&1 || true
    if [[ -n "${existing_port}" ]]; then
        read -rp "Закрыть старый порт панели ${existing_port} в UFW? [y/N]: " close_old
        if [[ "$close_old" =~ ^[Yy]$ ]]; then
            ufw delete allow "${existing_port}"/tcp >/dev/null 2>&1 || true
        fi
    fi
fi
echo
echo -e "${green}Настройки панели обновлены.${plain}"
if [[ -n "${server_ip}" ]]; then
    echo -e "${yellow}Новый URL для доступа к панели:${plain}"
    echo -e "${green}http://${server_ip}:${config_port}/${config_webBasePath}${plain}"
else
    echo -e "${yellow}Внешний IP не удалось определить. Используйте IP сервера вручную:${plain}"
    echo -e "${green}http://<SERVER_IP>:${config_port}/${config_webBasePath}${plain}"
fi
echo
echo -e "${yellow}Не забудьте сохранить новый URL и порт.${plain}"
EOF

    chmod +x /usr/local/x-ui/change-panel-access.sh

    # Базовая конфигурация панели
    config_after_install

    # Генерация самоподписанного сертификата и привязка к панели
    generate_self_signed_cert

    if [[ $release == "alpine" ]]; then
        wget --inet4-only -O /etc/init.d/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.rc
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to download x-ui.rc${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        cp -f x-ui.service /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable x-ui
        systemctl start x-ui
    fi

    echo -e "${green}x-ui ${tag_version}${plain} installation finished, it is running now..."
    echo -e ""
    echo -e "${green}Self-signed certificate for the panel has been generated and applied.${plain}"
    echo -e "${yellow}Certificate path:${plain} /usr/local/x-ui/cert/cert.crt"
    echo -e "${yellow}Private key path:${plain} /usr/local/x-ui/cert/secret.key"
    echo -e ""
    echo -e "${yellow}Для смены порта и пути панели используйте:${plain} /usr/local/x-ui/change-panel-access.sh"
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"
}

configure_logrotate() {
    cat >/etc/logrotate.d/x-ui << 'EOF'
/var/log/xray/*.log /var/log/x-ui/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    echo -e "${green}Logrotate для логов Xray/3X-UI настроен.${plain}"
}

print_summary() {
    echo
    echo -e "${green}=========== INSTALL SUMMARY ==========${plain}"
    echo -e "${yellow}Данные панели 3X-UI:${plain}"
    if [[ -n "${SERVER_IP_PRINT}" && -n "${PANEL_PORT}" && -n "${PANEL_PATH}" ]]; then
        echo -e "  URL:        ${green}http://${SERVER_IP_PRINT}:${PANEL_PORT}/${PANEL_PATH}${plain}"
    fi
    if [[ -n "${PANEL_USER}" ]]; then
        echo -e "  Login:      ${green}${PANEL_USER}${plain}"
    fi
    if [[ -n "${PANEL_PASS}" ]]; then
        echo -e "  Password:   ${green}${PANEL_PASS}${plain}"
    fi
    if [[ -n "${PANEL_PORT}" ]]; then
        echo -e "  Port
