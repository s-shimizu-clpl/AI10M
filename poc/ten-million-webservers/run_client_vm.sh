#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

config=../../bin/ten-million-webservers-vm/ssh_config
listeners=$(ssh -F "$config" server 'sed -n "s/^ready listeners=//p" ~/ten-million-webservers/server.log')
[[ $listeners =~ ^[0-9]+$ ]]
ssh -F "$config" client bash -s -- "$listeners" "${DURATION:-12}" "${CONCURRENCY:-256}" <<'CLIENT'
set -euo pipefail
cd /home/ubuntu/ten-million-webservers
awk -v n="$1" 'BEGIN {
    for (i=0; i<n; i++) {
        ip=171966465+i; # 10.64.0.1 + i
        printf "http://%d.%d.%d.%d:8080/\n", int(ip/16777216), int(ip/65536)%256, int(ip/256)%256, ip%256
    }
}' > urls.txt
# Scale with the VM's CPUs (CLIENT_CPUS in init_vms.sh): CPU 0 takes the NIC
# interrupt, RPS spreads TCP processing over the others, oha uses all of them.
cpus=$(nproc)
sudo ip netns exec smol-client sh -c \
    "printf '%x\n' $(( (1 << cpus) - 2 )) > /sys/class/net/enp0s2/queues/rx-0/rps_cpus"
sudo ip netns exec smol-client curl -fsS -o /dev/null http://10.64.0.1:8080/
# Keep the request within the guest's 64-byte TCP window; URLs still select the IP.
exec sudo prlimit --nofile=65536 -- ip netns exec smol-client oha --worker-threads "$cpus" --no-tui \
    --http-version 1.0 --disable-keepalive --disable-compression --no-pre-lookup \
    --host x -A '' -H 'user-agent:' \
    -z "${2}s" -c "$3" --urls-from-file urls.txt
CLIENT
