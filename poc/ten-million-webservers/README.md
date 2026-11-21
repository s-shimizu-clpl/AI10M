# Ten millions of webservers

The purpose of this proof of concept is two explore limitation of extremely dense environments with millions of network services. Original idea was to explore `io_uring` as a batching mechanism for better
throughtput, but turns our using kernel network stack is too expensive for our purpose in terms of RAM usage.

So solve it we've went to userland TCP/IP stack implementation (specifically `smoltcp` Rust lib) and using kernel bypassing mechanism of different kind: from TUN/TAP to AF_XDP and most extreme DPDK. Not only it gave full control on RAM usage, but it also increased overall throughtput considerably.

Conclution of this poc is that userland network stack is the way to go, but also highly valuable would be multiple network stack implementations.

## Running

The benchmark runs in two QEMU VMs (server: 1 vCPU / 10 GiB, client: 3 vCPUs / 10 GiB) joined by a
private virtio link. The server binary, the client and a minimal Linux 7.3.4 kernel are built inside the
VMs, which use the host's CPU architecture. Supported hosts:

| Host | Accelerator | Guest |
| --- | --- | --- |
| Apple Silicon macOS (Homebrew `qemu`) | HVF | Ubuntu 24.04 arm64, `virt` machine, UEFI, SMMUv3 for VFIO |
| x86_64 Linux, e.g. bare-metal Ubuntu 24.04 | KVM | Ubuntu 24.04 amd64, `q35` machine, SeaBIOS, VFIO no-IOMMU mode |

On x86_64 Ubuntu 24.04, prepare the host once:

```sh
sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils openssh-client curl
sudo usermod -aG kvm "$USER"   # log in again afterwards; VT-x/AMD-V must be enabled in firmware
```

The host needs about 20 GiB of free RAM for the two VMs, and at least 8 cores: the server's DPDK
and AF_XDP loops keep one core busy, and the client, QEMU's link threads and the host need the rest.
Then:

```sh
./init_vms.sh             # once: creates the VMs, builds everything, reboots into the custom kernel
./run_server_vm.sh dpdk   # dpdk | tap | tun | af_xdp; LISTENERS=<n> overrides 10000000
./run_client_vm.sh        # in another terminal; DURATION and CONCURRENCY are optional
```

The client is the first bottleneck with the fast backends. `CLIENT_CPUS=<n> ./init_vms.sh` gives the
client VM `n` vCPUs (default 3); `run_client_vm.sh` sizes oha's threads and RPS from the VM's CPUs.
Running `init_vms.sh` again restarts both VMs, for example after a host reboot, and skips the build
on VMs that were already provisioned.

VM state lives in `bin/ten-million-webservers-vm` at the repository root.

