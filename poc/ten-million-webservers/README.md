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

## Results on bare-metal x86_64

Host: AMD Ryzen 7 4800H (8 cores, SMT off), 32 GiB, Ubuntu 24.04, KVM. 10,000,000 listeners on the
1-vCPU server, `DURATION=60`, every run 100% successful.

| Backend | Client vCPUs | Concurrency | Requests/sec | p50 | p99 |
| --- | --- | --- | --- | --- | --- |
| dpdk | 5 | 512 | 107,605 | 3.7 ms | 49.9 ms |
| dpdk | 3 | 512 | 46,689 | 8.2 ms | 46.7 ms |
| dpdk | 3 | 64 | 48,311 | 1.0 ms | 4.3 ms |
| af_xdp | 3 | 512 | 48,456 | 8.5 ms | 23.3 ms |
| tun | 3 | 512 | 26,414 | 9.0 ms | 224 ms |
| tap | 3 | 512 | 25,154 | 17.0 ms | 51.8 ms |

- With 3 client vCPUs, all of them run at 100% and cap DPDK and AF_XDP at ~48k req/s. TUN and TAP
  stay below that cap, so their numbers are server-bound.
- With 5 client vCPUs, the host runs out of cores (1% idle): the server vCPU, five client vCPUs and
  QEMU's two `-netdev stream` link threads (~90% each) use all 8. 107k req/s is therefore the limit
  of this host, not of the server.
- Shrinking the listeners from 10M to 100k changed DPDK throughput by only 3% (25.8k vs 26.5k req/s
  on a 4-core host), so the number of resident listeners barely affects the request path.
- A 4-core laptop CPU (Core i5-8265U) saturates at ~26k req/s with millisecond scheduling delays,
  because the VMs' 4 vCPUs plus QEMU's link threads oversubscribe its cores.

