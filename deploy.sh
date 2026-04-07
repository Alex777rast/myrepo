#!/bin/sh

set -eu

# =========================
# Авторазвертывание Ubuntu 24.04
# =========================

NODE_EXPORTER_VERSION="1.8.2"
NODE_EXPORTER_ARCH="linux-amd64"
NODE_EXPORTER_DIR="node_exporter-${NODE_EXPORTER_VERSION}.${NODE_EXPORTER_ARCH}"
NODE_EXPORTER_TAR="${NODE_EXPORTER_DIR}.tar.gz"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/${NODE_EXPORTER_TAR}"

MONITOR_IP="80.92.211.160"
FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.local"

log() {
  echo
  echo "===> $1"
}

die() {
  echo "ОШИБКА: $1" >&2
  exit 1
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Запусти скрипт от root: sudo sh $0"
  fi
}

validate_port() {
  PORT_TO_CHECK="$1"

  case "$PORT_TO_CHECK" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac

  if [ "$PORT_TO_CHECK" -lt 1 ] || [ "$PORT_TO_CHECK" -gt 65535 ]; then
    return 1
  fi

  return 0
}

backup_file() {
  FILE_PATH="$1"
  if [ -f "$FILE_PATH" ]; then
    cp "$FILE_PATH" "${FILE_PATH}.bak.$(date +%F-%H%M%S)"
  fi
}

detect_current_ssh_port() {
  CURRENT_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2}' /etc/ssh/sshd_config 2>/dev/null | tail -n1 || true)"
  if [ -z "${CURRENT_PORT:-}" ]; then
    CURRENT_PORT="22"
  fi
  echo "$CURRENT_PORT"
}

configure_ssh_port() {
  NEW_PORT="$1"

  log "Настройка SSH"

  backup_file /etc/ssh/sshd_config

  if grep -Eq '^[[:space:]]*#?[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config; then
    sed -i "s/^[[:space:]]*#\?[[:space:]]*Port[[:space:]]\+[0-9]\+/Port ${NEW_PORT}/" /etc/ssh/sshd_config
  else
    printf "\nPort %s\n" "$NEW_PORT" >> /etc/ssh/sshd_config
  fi

  mkdir -p /run/sshd
  chmod 755 /run/sshd

  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  fi

  # Отключаем socket activation и работаем только через обычный ssh.service
  systemctl disable --now ssh.socket 2>/dev/null || true

  # Если раньше создавались override'ы для socket/service — убираем их
  rm -f /etc/systemd/system/ssh.socket.d/override.conf 2>/dev/null || true
  rm -f /etc/systemd/system/ssh.service.d/00-socket.conf 2>/dev/null || true

  systemctl daemon-reload
  systemctl enable ssh
  systemctl restart ssh
}

update_system() {
  log "Обновление системы"
  apt update
  DEBIAN_FRONTEND=noninteractive apt upgrade -y
}

install_packages() {
  log "Установка необходимых пакетов"
  DEBIAN_FRONTEND=noninteractive apt install -y \
    ufw \
    fail2ban \
    wget \
    tar \
    ca-certificates
}

configure_firewall() {
  NEW_PORT="$1"

  log "Настройка UFW"

  ufw default deny incoming
  ufw default allow outgoing

  ufw allow "${NEW_PORT}/tcp"
  ufw allow 443/tcp
  ufw allow from "${MONITOR_IP}" to any port 9100 proto tcp

  ufw disable || true
  ufw --force enable
}

configure_fail2ban() {
  NEW_PORT="$1"

  log "Настройка fail2ban"

  backup_file "$FAIL2BAN_JAIL_FILE"

  cat > "$FAIL2BAN_JAIL_FILE" <<EOF
[sshd]
enabled   = true
port      = ${NEW_PORT}
maxretry  = 3
findtime  = 1h
bantime   = 1d
ignoreip  = 127.0.0.1/8 ${MONITOR_IP}/32
EOF

  systemctl enable fail2ban
  systemctl restart fail2ban
}

install_node_exporter() {
  log "Установка Prometheus Node Exporter"

  cd /tmp

  rm -rf "$NODE_EXPORTER_DIR" "$NODE_EXPORTER_TAR"

  wget -O "$NODE_EXPORTER_TAR" "$NODE_EXPORTER_URL"
  tar xvf "$NODE_EXPORTER_TAR"
  rm -f "$NODE_EXPORTER_TAR"

  chmod +x "${NODE_EXPORTER_DIR}/node_exporter"
  mv -f "${NODE_EXPORTER_DIR}/node_exporter" /usr/bin/node_exporter
  rm -rf "$NODE_EXPORTER_DIR"

  cat > /etc/systemd/system/exporterd.service <<EOF
[Unit]
Description=Node Exporter
After=network.target

[Service]
User=root
ExecStart=/usr/bin/node_exporter

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable exporterd.service
  systemctl restart exporterd.service
}

show_status() {
  NEW_PORT="$1"

  log "Проверка статусов"

  echo "--- SSH ---"
  systemctl status ssh --no-pager -l || true

  echo
  echo "--- Проверка прослушивания SSH порта ${NEW_PORT} ---"
  ss -tulpn | grep ":${NEW_PORT}" || true

  echo
  echo "--- UFW ---"
  ufw status verbose || true

  echo
  echo "--- Fail2Ban ---"
  systemctl status fail2ban --no-pager -l || true
  fail2ban-client status || true
  fail2ban-client status sshd || true

  echo
  echo "--- Node Exporter ---"
  systemctl status exporterd.service --no-pager -l || true
  ss -tulpn | grep ":9100" || true
}

main() {
  require_root

  echo "=== Авторазвертывание сервера Ubuntu 24.04 ==="
  echo

  CURRENT_SSH_PORT="$(detect_current_ssh_port)"
  echo "Текущий SSH-порт: ${CURRENT_SSH_PORT}"
  printf "Введите новый SSH-порт: "
  read -r NEW_SSH_PORT

  if ! validate_port "$NEW_SSH_PORT"; then
    die "Некорректный порт. Допустимы значения 1-65535."
  fi

  echo
  echo "Будет установлен SSH-порт: ${NEW_SSH_PORT}"

  configure_ssh_port "$NEW_SSH_PORT"
  update_system
  install_packages
  configure_firewall "$NEW_SSH_PORT"
  configure_fail2ban "$NEW_SSH_PORT"
  install_node_exporter
  show_status "$NEW_SSH_PORT"

  echo
  echo "Готово."
  echo "Новый SSH-порт: ${NEW_SSH_PORT}"
  echo "SSH теперь работает через обычный ssh.service без ssh.socket."
  echo "Node Exporter открыт на 9100 только для ${MONITOR_IP}."
  echo
  echo "Не закрывай текущую SSH-сессию, пока не проверишь подключение на новый порт."
}

main "$@"
