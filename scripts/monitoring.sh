#!/usr/bin/env bash
#
# Born2beroot - system monitoring broadcast.
#
# Prints the metrics required by the subject on every connected terminal
# (wall) every INTERVAL seconds.  Intended to be started by
# monitoring.service; can also be run manually as root.
#
set -uo pipefail

export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly INTERVAL="${INTERVAL:-600}"

collect() {
	local architecture pcpu vcpu
	local mem_used mem_total mem_pct
	local disk_used disk_total disk_pct
	local cpu_load last_boot lvm_status tcp_connections user_count
	local ipv4 mac sudo_count

	architecture=$(uname -a)
	pcpu=$(grep -c '^processor' /proc/cpuinfo)
	vcpu=$(nproc)

	read -r mem_used mem_total mem_pct < <(
		awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2}
		     END {u = t - a; printf "%d %d %.2f\n", u / 1024, t / 1024, (t ? u * 100 / t : 0)}' /proc/meminfo
	)

	read -r disk_used disk_total disk_pct < <(
		df -BG 2>/dev/null | awk '$1 ~ /^\/dev\// && $6 != "/boot" {u += $3; t += $2}
		                           END {printf "%d %d %d\n", u, t, (t ? u * 100 / t : 0)}'
	)

	cpu_load=$(top -bn1 | awk '/^%Cpu/ {printf "%.1f", $2 + $4}')
	last_boot=$(who -b | awk '{print $3 " " $4}')
	lvm_status=$(if lsblk 2>/dev/null | grep -q 'lvm'; then echo "yes"; else echo "no"; fi)
	tcp_connections=$(ss -Htan state established 2>/dev/null | wc -l)
	user_count=$(who | wc -l)
	ipv4=$(hostname -I | awk '{print $1}')
	mac=$(ip link show | awk '/link\/ether/ {print $2; exit}')

	# sudo logs are only readable by root or the adm/systemd-journal group.
	sudo_count=$(journalctl _COMM=sudo --no-pager 2>/dev/null | grep -c 'COMMAND' || true)

	wall <<EOF
---------------- SYSTEM MONITORING ----------------
#Architecture: ${architecture}
#CPU physical: ${pcpu}
#vCPU: ${vcpu}
#Memory Usage: ${mem_used}/${mem_total}MB (${mem_pct}%)
#Disk Usage: ${disk_used}/${disk_total}Gb (${disk_pct}%)
#CPU load: ${cpu_load}%
#Last boot: ${last_boot}
#LVM use: ${lvm_status}
#Connections TCP: ${tcp_connections} ESTABLISHED
#User log: ${user_count}
#Network: IP ${ipv4} (${mac})
#Sudo: ${sudo_count} cmd
----------------------------------------------------
EOF
}

if [[ ${EUID} -ne 0 ]]; then
	echo "monitoring.sh must run as root (wall requires it)" >&2
	exit 1
fi

while true; do
	collect
	sleep "${INTERVAL}"
done
