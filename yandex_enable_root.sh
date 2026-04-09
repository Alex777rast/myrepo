#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Настройка SSH и root-доступа для Yandex Cloud..."

if [[ $EUID -ne 0 ]]; then
  echo "[INFO] Перезапуск через sudo..."
  exec sudo bash "$0" "$@"
fi

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_OVERRIDE="${SSHD_DROPIN_DIR}/99-root-password.conf"

CLOUD_CFG_DIR="/etc/cloud/cloud.cfg.d"
CLOUD_OVERRIDE="${CLOUD_CFG_DIR}/99-enable-root-password.cfg"

BROKEN_CA_FILE="${SSHD_DROPIN_DIR}/sshd_casignature_alhgorithms.conf"

echo "[INFO] Подготовка каталогов..."
mkdir -p /run/sshd
chmod 755 /run/sshd
mkdir -p "$SSHD_DROPIN_DIR"
mkdir -p "$CLOUD_CFG_DIR"

echo "[INFO] Удаление известного битого файла, если есть..."
rm -f "$BROKEN_CA_FILE"

echo "[INFO] Проверка Include в основном sshd_config..."
if [ -f "$SSHD_MAIN" ]; then
  grep -qE '^[#[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_MAIN" || \
    echo 'Include /etc/ssh/sshd_config.d/*.conf' >> "$SSHD_MAIN"
fi

echo "[INFO] Запись SSH override..."
cat > "$SSHD_OVERRIDE" <<'EOF'
PasswordAuthentication yes
PermitRootLogin yes
KbdInteractiveAuthentication yes
UsePAM yes
PubkeyAuthentication yes
EOF

echo "[INFO] Запись cloud-init override..."
cat > "$CLOUD_OVERRIDE" <<'EOF'
disable_root: false
ssh_pwauth: true
EOF

echo "[INFO] Подготовка root authorized_keys..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh
: > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

echo "[INFO] Разблокировка root..."
passwd -u root || true

echo "[INFO] Проверка конфигурации sshd..."
sshd -t

echo "[INFO] Перезапуск SSH..."
systemctl restart ssh

echo "[INFO] Итоговые параметры:"
sshd -T | grep -E 'usepam|permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods'

echo "[DONE] Готово."
echo "[NOTE] Если пароль для root еще не задан, задай его отдельно командой: passwd root"