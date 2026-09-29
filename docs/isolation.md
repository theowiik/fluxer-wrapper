# Running it in an isolated VM or container

Optional, but recommended on a home server. Nothing in the stack changes: you run the same `make up` inside the VM or container instead of on the host.

**Why:** Docker already makes it hard for a compromised app to take over the host. It does nothing to stop that app from talking to the rest of your network: your NAS, your router's admin page, other PCs. Putting the stack in a VM or container that can't reach your LAN limits a worst case to "the chat server is compromised".

This guide uses [Incus](https://linuxcontainers.org/incus/), which runs both VMs and system containers on Ubuntu. If you use LXD, the commands are the same with `lxc` instead of `incus`. If you use Proxmox, see [the Proxmox note](#proxmox) at the end.

## 1. Pick VM or container

| | VM (recommended) | System container (LXC) |
|---|---|---|
| Isolation | Own kernel | Shares the host kernel |
| Overhead | A bit more RAM | Minimal |
| Docker inside | Just works | Needs nesting enabled |

## 2. Install Incus on the host

```bash
sudo apt install incus            # Ubuntu 24.04+
sudo incus admin init --minimal   # creates the incusbr0 NAT network
sudo usermod -aG incus-admin $USER && newgrp incus-admin
```

## 3. Create the instance

VM:

```bash
incus launch images:ubuntu/24.04 fluxer --vm \
  -c limits.cpu=2 -c limits.memory=8GiB -d root,size=40GiB
```

Or a container:

```bash
incus launch images:ubuntu/24.04 fluxer \
  -c limits.cpu=2 -c limits.memory=8GiB \
  -c security.nesting=true \
  -c security.syscalls.intercept.mknod=true \
  -c security.syscalls.intercept.setxattr=true
```

Give it a fixed address on the Incus network, which port forwarding needs:

```bash
incus network get incusbr0 ipv4.address        # e.g. 10.23.45.1/24
incus config device override fluxer eth0 ipv4.address=10.23.45.10   # pick one in that subnet
incus restart fluxer
```

## 4. Forward the ports from the host

`nat=true` matters here. Without it, every visitor shows up as the host's IP, and CrowdSec bans and allowlists stop working.

Replace `HOST_IP` with the host's LAN address and `VM_IP` with the address you picked above:

```bash
HOST_IP=192.168.1.20
VM_IP=10.23.45.10
incus config device add fluxer http     proxy nat=true listen=tcp:$HOST_IP:80   connect=tcp:$VM_IP:80
incus config device add fluxer https    proxy nat=true listen=tcp:$HOST_IP:443  connect=tcp:$VM_IP:443
incus config device add fluxer http3    proxy nat=true listen=udp:$HOST_IP:443  connect=udp:$VM_IP:443
incus config device add fluxer lk-tcp   proxy nat=true listen=tcp:$HOST_IP:7881 connect=tcp:$VM_IP:7881
incus config device add fluxer lk-udp   proxy nat=true listen=udp:$HOST_IP:7882 connect=udp:$VM_IP:7882
```

On your router, forward the same five ports to `HOST_IP`.

**If a reverse proxy on the host already owns 80/443** (for example Nginx Proxy Manager), skip the `http`, `https` and `http3` devices. Use `PROXY_MODE=behind` instead, and point the proxy at `VM_IP:80`; see the README. Only the two LiveKit devices are needed.

## 5. Block the instance from your LAN

This is what makes the isolation real. The rules below:
- let the instance reach the internet;
- let it answer connections that come in through the forwarded ports;
- let it use the Incus network's DHCP and DNS;
- drop everything else it tries to send to private addresses, including the host itself.

Create `/etc/fluxer-isolation.nft`:

```nft
table inet fluxer_isolation
delete table inet fluxer_isolation

table inet fluxer_isolation {
  set private4 {
    type ipv4_addr; flags interval
    elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10 }
  }
  set private6 {
    type ipv6_addr; flags interval
    elements = { fc00::/7, fe80::/10 }
  }

  # Instance -> other machines
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "incusbr0" ct state established,related accept
    iifname "incusbr0" ip  daddr @private4 drop
    iifname "incusbr0" ip6 daddr @private6 drop
  }

  # Instance -> the host itself
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "incusbr0" ct state established,related accept
    iifname "incusbr0" udp dport { 53, 67, 547 } accept
    iifname "incusbr0" tcp dport 53 accept
    iifname "incusbr0" meta l4proto ipv6-icmp accept
    iifname "incusbr0" drop
  }
}
```

Load it now and on every boot. Use a small unit rather than `nftables.service`, because Ubuntu's default `/etc/nftables.conf` flushes all rules, including Docker's and Incus's:

```bash
sudo tee /etc/systemd/system/fluxer-isolation.service >/dev/null <<'EOF'
[Unit]
Description=Block the fluxer instance from the LAN
After=network-online.target incus.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/fluxer-isolation.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now fluxer-isolation
```

Check it from inside the instance. The first command should fail, the second should work:

```bash
incus exec fluxer -- curl -m 5 -sI http://192.168.1.1   # your router: should time out
incus exec fluxer -- curl -m 5 -sI https://example.com  # internet: should work
```

## 6. Install Docker and the stack inside

```bash
incus exec fluxer -- bash
curl -fsSL https://get.docker.com | sh
apt install -y git make
git clone <this repo> /srv/fluxer-wrapper && cd /srv/fluxer-wrapper
cp .env.example .env && nano .env
make up
```

From here, follow the main [README](../README.md#setup) from step 4.

Your LAN clients reach the instance through the host with their own IPs intact, so the default `private_ranges` allowlist still covers "from home" during setup.

## Proxmox

- **VM:** create an Ubuntu VM and follow step 6. For isolation, put it on its own VLAN or enable the Proxmox firewall on its NIC with an outbound rule that rejects your LAN subnets.
- **LXC:** tick **Nesting** (and **keyctl** for unprivileged containers) under Options → Features. Then do the same as for the VM.

## Better: a separate VLAN

If your router supports VLANs or a guest/DMZ network, put the VM there and forward ports straight to it. The router then does the isolation, and you can skip steps 4 and 5.
