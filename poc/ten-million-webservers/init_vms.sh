#!/usr/bin/env bash
# Provision both VMs once; run the server and client scripts in separate terminals.
# Running it again restarts both VMs (e.g. after a host reboot or to change
# CLIENT_CPUS) and skips the build on VMs that already run the custom kernel.
set -euo pipefail
cd "$(dirname "$0")"
repo=$(cd ../.. && pwd)
state=$repo/bin/ten-million-webservers-vm
guest=/home/ubuntu/ten-million-webservers
client_cpus=${CLIENT_CPUS:-3}
[[ $client_cpus =~ ^[1-9][0-9]*$ ]] || { echo 'CLIENT_CPUS must be a positive integer.' >&2; exit 1; }
mkdir -p "$state"/{cache,server,client,seed}

# Supported hosts: Apple Silicon macOS (HVF) and x86_64 Linux such as a
# bare-metal Ubuntu 24.04 (KVM). The guests use the host's CPU architecture.
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) image_arch=arm64 ;;
    Linux-x86_64)
        image_arch=amd64
        for tool in qemu-system-x86_64 qemu-img cloud-localds ssh curl; do
            command -v "$tool" >/dev/null || {
                echo "Missing $tool. Run: sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client curl" >&2
                exit 1
            }
        done
        [[ -r /dev/kvm && -w /dev/kvm ]] || {
            echo 'No access to /dev/kvm. Enable VT-x/AMD-V in the firmware and run: sudo usermod -aG kvm "$USER" (then log in again).' >&2
            exit 1
        }
        ;;
    *) echo "Unsupported host $(uname -s)-$(uname -m): use Apple Silicon macOS or x86_64 Linux." >&2; exit 1 ;;
esac

[[ -f $state/cache/ubuntu-$image_arch.img ]] || curl -fL \
    "https://cloud-images.ubuntu.com/noble/20261017/noble-server-cloudimg-$image_arch.img" \
    -o "$state/cache/ubuntu-$image_arch.img"
[[ -f $state/ssh-key ]] || ssh-keygen -q -t ed25519 -N '' -f "$state/ssh-key"
cat > "$state/ssh_config" <<SSH
Host server client
    HostName 127.0.0.1
    User ubuntu
    IdentityFile "$state/ssh-key"
    IdentitiesOnly yes
    BatchMode yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile "$state/known_hosts"
Host server
    Port 2238
Host client
    Port 2239
SSH
ssh_vm() { ssh -F "$state/ssh_config" "$@"; }

# Both machines use the same login key and interface names.
cat > "$state/seed/user-data" <<CLOUD
#cloud-config
ssh_authorized_keys:
  - $(cat "$state/ssh-key.pub")
CLOUD
echo 'instance-id: ten-million-webservers' > "$state/seed/meta-data"
cat > "$state/seed/network-config" <<NET
version: 2
ethernets:
  enp0s1: {dhcp4: true}
  enp0s2: {dhcp4: false, optional: true}
NET
if [[ ! -f $state/seed.iso ]]; then
    if [[ $image_arch == arm64 ]]; then
        hdiutil makehybrid -iso -joliet \
            -default-volume-name cidata -o "$state/seed.iso" "$state/seed"
    else
        cloud-localds -N "$state/seed/network-config" "$state/seed.iso" \
            "$state/seed/user-data" "$state/seed/meta-data"
    fi
fi


# Shut down a VM left running by an earlier invocation.
stop_vm() {
    local pid
    pid=$(cat "$state/$1/qemu.pid" 2>/dev/null) || return 0
    # A stale pid file after a host reboot may name an unrelated process.
    [[ $(ps -p "$pid" -o comm= 2>/dev/null) == *qemu-system* ]] || return 0
    ssh_vm "$1" 'sudo poweroff' 2>/dev/null || true
    for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do sleep 1; done
}

create_vm() {
    local role=$1 cores=1 port=2238 octet=1 link=on
    if [[ $role == client ]]; then cores=$client_cpus; port=2239; octet=2; link=off; fi
    [[ -f $state/$role/disk.qcow2 ]] || qemu-img create -f qcow2 -F qcow2 \
        -b "$state/cache/ubuntu-$image_arch.img" "$state/$role/disk.qcow2" 40G
    [[ $role != server ]] || rm -f "$state/link.sock"
    local disk="file=$state/$role/disk.qcow2,format=qcow2,discard=unmap"
    local seed="file=$state/seed.iso,format=raw,readonly=on"
    local mgmt=virtio-net-pci,netdev=mgmt,mac=52:54:00:12:34:56
    local bench="virtio-net-pci,netdev=bench,mac=52:54:00:ab:00:0$octet,disable-legacy=on,iommu_platform=off,rx_queue_size=256,tx_queue_size=256"
    local machine
    # QEMU option values are comma-separated by design.
    # shellcheck disable=SC2054
    if [[ $image_arch == arm64 ]]; then
        # Keep the device-tree hardware description used by our minimal kernel.
        machine=(qemu-system-aarch64 -machine virt,gic-version=3,iommu=smmuv3,acpi=off
            -accel hvf -cpu host
            -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd
            -drive "$disk,if=virtio" -drive "$seed,if=virtio"
            -device "$mgmt" -device "$bench")
    else
        # q35 + SeaBIOS. Pin the PCI slots so the guest sees the same names as on
        # ARM64: enp0s1 (management), enp0s2 at 0000:00:02.0 (benchmark link).
        machine=(qemu-system-x86_64 -machine q35 -accel kvm -cpu host -vga none
            -device "$mgmt,addr=0x1" -device "$bench,addr=0x2"
            -drive "$disk,if=none,id=disk" -device virtio-blk-pci,drive=disk,addr=0x3
            -drive "$seed,if=none,id=seed" -device virtio-blk-pci,drive=seed,addr=0x4)
    fi
    "${machine[@]}" -daemonize -m 10G -smp "$cores" \
        -netdev "user,id=mgmt,hostfwd=tcp:127.0.0.1:$port-:22" \
        -netdev "stream,id=bench,server=$link,addr.type=unix,addr.path=$state/link.sock" \
        -display none -monitor none -serial "file:$state/$role/console.log" \
        -pidfile "$state/$role/qemu.pid"
    until ssh_vm "$role" true 2>/dev/null; do sleep 1; done
}

configure_vm() {
    if [[ $(ssh_vm "$1" uname -r) == 7.3.4-afxdp ]]; then
        echo "$1: already provisioned, skipping the build."
        ssh_vm "$1" 'sudo cloud-init status --wait' >/dev/null
        return
    fi
    COPYFILE_DISABLE=1 tar --no-xattrs -cf - Cargo.toml Cargo.lock build.rs src kernel*.config |
        ssh_vm "$1" "mkdir -p '$guest'; tar -mxf - -C '$guest'"
    # Run this same guest setup on both VMs.
    ssh_vm "$1" "cd '$guest'; bash -se" <<'GUEST'
set -euo pipefail
# Architecture-specific names: oha release, kernel image, and boot command line.
case "$(uname -m)" in
    aarch64)
        oha_arch=arm64 kernel_image=arch/arm64/boot/Image make_target=Image
        cmdline='console=ttyAMA0 iommu.passthrough=1' ;;
    x86_64)
        oha_arch=amd64 kernel_image=arch/x86/boot/bzImage make_target=bzImage
        cmdline='console=ttyS0 vfio.enable_unsafe_noiommu_mode=1' ;;
esac
sudo cloud-init status --wait
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    iproute2 ethtool curl ca-certificates build-essential git clang-18 llvm-18 libclang1-18 \
    libdpdk-dev libbpf-dev libelf-dev zlib1g-dev libnuma-dev libpcap-dev libsystemd-dev \
    autoconf automake libtool pkg-config m4 bc bison flex libssl-dev xz-utils
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer
sudo swapoff -a
sudo apt-get clean

# Install both the server and the standard HTTP client on each VM.
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs |
    sh -s -- -y --profile minimal --default-toolchain 1.99.1
CLANG=clang-18 LLC=llc-18 LIBCLANG_PATH=/usr/lib/llvm-18/lib \
    ~/.cargo/bin/cargo +1.99.1 build --release --locked
curl -fL "https://github.com/hatoo/oha/releases/download/v1.17.0/oha-linux-$oha_arch" -o /tmp/oha
sudo install -m 755 /tmp/oha /usr/local/bin/oha

# Build and install the kernel inside the VM; QEMU keeps using the normal
# firmware boot (UEFI on ARM64, BIOS on x86_64) through GRUB.
mkdir -p kernel-build
sudo mount -t tmpfs -o size=4G,uid=1000 tmpfs kernel-build
curl -fL https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.4.tar.xz |
    tar -xJ -C kernel-build
cat kernel.config "kernel.$(uname -m).config" > kernel-build/allconfig
make -C kernel-build/linux-7.3.4 KCONFIG_ALLCONFIG="$PWD/kernel-build/allconfig" allnoconfig
make -C kernel-build/linux-7.3.4 -j"$(nproc)" "$make_target"
sudo install -m 644 "kernel-build/linux-7.3.4/$kernel_image" /boot/vmlinuz-ai10m
sudo install -m 644 kernel-build/linux-7.3.4/.config /boot/config-ai10m
sudo umount kernel-build
sudo tee /boot/grub/grub.cfg >/dev/null <<GRUB
set timeout=0
menuentry 'AI10M' {
    linux /vmlinuz-ai10m root=/dev/vda1 rootwait rw $cmdline
}
GRUB

# Ubuntu already expanded the fixed-size disk during its first boot.
echo 'resize_rootfs: false' | sudo tee /etc/cloud/cloud.cfg.d/99-ai10m.cfg >/dev/null
sudo rm -f /etc/cloud/cloud-init.disabled

# Restore the client's network namespace at boot. Its NIC has MAC suffix 02.
sudo mkdir -p /var/lib/cloud/scripts/per-boot
sudo tee /var/lib/cloud/scripts/per-boot/ten-million-network >/dev/null <<'NETWORK'
#!/usr/bin/env bash
set -euo pipefail
[[ $(cat /sys/class/net/enp0s2/address) == 52:54:00:ab:00:02 ]] || exit 0
sysctl -qw net.ipv4.tcp_child_ehash_entries=2097152
ip netns add smol-client
sysctl -qw net.ipv4.tcp_child_ehash_entries=0
ip link set enp0s2 netns smol-client
ip -n smol-client -batch - <<'NET'
link set lo up
link set enp0s2 up
addr add 192.0.2.2/24 dev enp0s2
neigh replace 192.0.2.1 lladdr 52:54:00:ab:00:01 nud permanent dev enp0s2
route replace 10.0.0.0/7 via 192.0.2.1 dev enp0s2
NET
ip netns exec smol-client sysctl -qw net.ipv4.tcp_max_tw_buckets=65536
NETWORK
sudo chmod +x /var/lib/cloud/scripts/per-boot/ten-million-network

# The server start command selects and configures its packet backend.
cat > server.sh <<'SERVER'
set -euo pipefail
cd /home/ubuntu/ten-million-webservers
backend=$1
driver=virtio-pci
[[ $backend != dpdk ]] || driver=vfio-pci
pci=/sys/bus/pci/devices/0000:00:02.0
echo 0000:00:02.0 > "$pci/driver/unbind"
echo "$driver" > "$pci/driver_override"
echo 0000:00:02.0 > /sys/bus/pci/drivers_probe
udevadm settle
if [[ $backend == dpdk ]]; then
    # ARM64 (SMMUv3) only; x86_64 runs VFIO in no-IOMMU mode.
    param=/sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts
    [[ ! -e $param ]] || echo Y > "$param"
    sysctl -qw vm.nr_hugepages=24
else
    sysctl -qw vm.nr_hugepages=0
    ip link set enp0s2 up
    ip link set enp0s2 xdp off
    if [[ $backend == af_xdp ]]; then
        ethtool -K enp0s2 gro off
        export LIBXDP_SKIP_DISPATCHER=1
    else
        ethtool -K enp0s2 gro on
        ip tuntap del dev smolbench mode tap 2>/dev/null || true
        ip tuntap del dev smolbench mode tun 2>/dev/null || true
        ip tuntap add dev smolbench mode "$backend"
        ip link set smolbench up
        sysctl -qw net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=0 \
            net.ipv4.conf.enp0s2.rp_filter=0 net.ipv4.conf.smolbench.rp_filter=0
        ip addr replace 192.0.2.254/24 dev enp0s2
        ip neigh replace 192.0.2.2 lladdr 52:54:00:ab:00:02 nud permanent dev enp0s2
        via=()
        if [[ $backend == tap ]]; then
            ip addr replace 198.51.100.1/24 dev smolbench
            ip link set smolbench address 52:54:00:ab:00:03
            ip neigh replace 198.51.100.2 lladdr 52:54:00:ab:00:01 nud permanent dev smolbench
            via=(via 198.51.100.2)
        fi
        ip route replace 10.0.0.0/7 "${via[@]}" dev smolbench
    fi
fi
ulimit -l unlimited
exec env LISTENERS="$2" \
    ./target/release/ten-million-webservers 10.64.0.1 "$backend" > >(tee server.log) 2>&1
SERVER
sudo reboot
GUEST
    until [[ $(ssh_vm "$1" uname -r 2>/dev/null) == 7.3.4-afxdp ]]; do sleep 1; done
    ssh_vm "$1" 'sudo cloud-init status --wait'
}

# The client connects to the server's link socket, so stop it first.
stop_vm client
stop_vm server
for vm in server client; do
    create_vm "$vm"
    configure_vm "$vm"
done
echo "Ready: server 1 CPU / 10 GiB, client $client_cpus CPUs / 10 GiB."
echo 'Run ./run_server_vm.sh dpdk, then ./run_client_vm.sh in another terminal.'
