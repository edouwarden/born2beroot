#!/usr/bin/env bash
#
# Born2beroot - host hardening performed after the Debian installation.
#
# This script is executed by the preseed late_command (inside the target
# system) but can also be re-run manually on an installed machine.  It is
# idempotent: existing configuration is updated instead of duplicated.
#
set -euo pipefail

readonly USER_NAME="${USER_NAME:-enormand}"
readonly SSH_PORT="${SSH_PORT:-4242}"
readonly GROUP_NAME="user42"
readonly SUDOERS_FILE="/etc/sudoers.d/42-hardening"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

log() { printf '[post_install] %s\n' "$*"; }

require_root() {
	if [[ ${EUID} -ne 0 ]]; then
		echo "post_install.sh must run as root" >&2
		exit 1
	fi
}

# ensure_line <file> <regex> <line>
# Replace the first line matching <regex>, or append <line> if absent.
ensure_line() {
	local file=$1 regex=$2 line=$3

	if grep -Eq "${regex}" "${file}"; then
		sed -ri "s|^.*${regex}.*$|${line}|" "${file}"
	else
		printf '%s\n' "${line}" >>"${file}"
	fi
}

configure_ssh() {
	log "configuring SSH on port ${SSH_PORT}"
	ensure_line /etc/ssh/sshd_config '^#?[[:space:]]*Port[[:space:]]' "Port ${SSH_PORT}"
	ensure_line /etc/ssh/sshd_config '^#?[[:space:]]*PermitRootLogin[[:space:]]' "PermitRootLogin no"
	ensure_line /etc/ssh/sshd_config '^#?[[:space:]]*PasswordAuthentication[[:space:]]' "PasswordAuthentication yes"

	if ! sshd -t; then
		echo "invalid sshd configuration, aborting" >&2
		exit 1
	fi
	# The service cannot be restarted while running inside the installer
	# chroot; it will pick up the configuration on first boot.
	systemctl restart ssh 2>/dev/null || log "ssh restart deferred to first boot"
}

configure_firewall() {
	log "configuring UFW"
	ufw --force reset >/dev/null
	ufw default deny incoming >/dev/null
	ufw default allow outgoing >/dev/null
	ufw allow "${SSH_PORT}/tcp" >/dev/null
	ufw --force enable >/dev/null || log "ufw will be started on first boot"
}

configure_password_policy() {
	log "applying password policy"

	# pam_pwquality must be evaluated before pam_unix, hence the insertion.
	if ! grep -q 'pam_pwquality.so' /etc/pam.d/common-password; then
		sed -i '/^password.*pam_unix\.so/i password requisite pam_pwquality.so retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 difok=7 reject_username enforce_for_root' \
			/etc/pam.d/common-password
	fi

	ensure_line /etc/login.defs '^PASS_MAX_DAYS[[:space:]]' 'PASS_MAX_DAYS   30'
	ensure_line /etc/login.defs '^PASS_MIN_DAYS[[:space:]]' 'PASS_MIN_DAYS   2'
	ensure_line /etc/login.defs '^PASS_WARN_AGE[[:space:]]' 'PASS_WARN_AGE   7'
}

configure_sudo() {
	log "configuring sudo"

	cat >"${SUDOERS_FILE}" <<'EOF'
# Born2beroot - sudo hardening
Defaults	passwd_tries=3
Defaults	badpass_message="Erreur: mot de passe incorrect. Veuillez reessayer."
Defaults	logfile="/var/log/sudo/sudo.log"
Defaults	log_input, log_output
Defaults	iolog_dir="/var/log/sudo"
Defaults	requiretty
Defaults	use_pty
Defaults	secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
EOF
	chmod 0440 "${SUDOERS_FILE}"

	if ! visudo -cf "${SUDOERS_FILE}" >/dev/null; then
		echo "invalid sudoers file, removing it" >&2
		rm -f "${SUDOERS_FILE}"
		exit 1
	fi

	install -d -o root -g root -m 0700 /var/log/sudo
}

configure_users() {
	log "configuring user ${USER_NAME}"

	getent group "${GROUP_NAME}" >/dev/null || addgroup --system "${GROUP_NAME}"
	getent passwd "${USER_NAME}" >/dev/null ||
		adduser --disabled-password --gecos "" "${USER_NAME}"

	usermod -aG sudo,adm,"${GROUP_NAME}" "${USER_NAME}"
}

configure_fail2ban() {
	log "enabling fail2ban"
	systemctl enable fail2ban
	systemctl restart fail2ban || true
}

install_monitoring() {
	log "installing monitoring service"

	install -m 0755 "${SCRIPT_DIR}/monitoring.sh" /usr/local/bin/monitoring.sh

	cat >/etc/systemd/system/monitoring.service <<'EOF'
[Unit]
Description=Born2beroot system monitoring (wall broadcast)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitoring.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload 2>/dev/null || true
	systemctl enable monitoring.service
	systemctl restart monitoring.service 2>/dev/null ||
		log "monitoring service will start on first boot"
}

main() {
	require_root

	configure_ssh
	configure_firewall
	configure_password_policy
	configure_sudo
	configure_users
	configure_fail2ban
	install_monitoring

	log "done"
}

main "$@"
