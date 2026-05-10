---
title: Split-horizon DNS
description: How the lab resolves *.lab.jackhall.dev internally while still issuing a real Let's Encrypt wildcard certificate.
---

The lab uses **split-horizon DNS** so that internal services
(`*.lab.jackhall.dev`) resolve to LAN addresses (`192.168.1.x`) on
configured devices, while still being able to issue a real Let's Encrypt
wildcard certificate via DNS-01 against Google Cloud DNS.

This page covers the architecture, then walks through pointing a device at
AdGuard Home (`192.168.1.200`) as its DNS server.

For the underlying decision rationale, see
[ADR-0003: Public domain + DNS-01 + split-horizon](https://github.com/RaptGroup/homelab/blob/main/docs/adr/0003-public-domain-dns-tls-split-horizon.md).

## Architecture

Two zones, two responsibilities.

### Public side — Google Cloud DNS

- The apex zone `jackhall.dev` is untouched at the registrar.
- The `lab` subzone is NS-delegated from the registrar to a Cloud DNS zone
  in the `rockingham-homelab` GCP project. The full layout of that
  project — both zones, the SAs cert-manager and ESO impersonate, the
  CAA record, the state bucket — is documented in
  [Cloud / rockingham-homelab GCP project](/homelab/cloud/gcp/).
- Cloud DNS holds **only** records needed for:
  1. ACME DNS-01 challenge records (`_acme-challenge.lab.jackhall.dev`),
     written by cert-manager via a GCP service account.
  2. Any genuinely public records (none today).
- Cloud DNS does **not** serve `dashboard.lab.jackhall.dev`,
  `argocd.lab.jackhall.dev`, or any other internal hostname. No `192.168.1.x`
  addresses live in the public zone.

### Internal side — AdGuard Home in-cluster

- AdGuard Home runs as a Kubernetes Deployment in the cluster, fronted by a
  Cilium `LoadBalancer` Service pinned to `192.168.1.200` (the first address
  in the `192.168.1.200–192.168.1.230` LB pool).
- AdGuard Home holds the rewrite rules for `*.lab.jackhall.dev →
  192.168.1.x` (the LB IPs of the relevant Services) and acts as the
  recursive resolver and ad-blocker for any device pointed at it.
- Devices that aren't pointed at AdGuard Home (guests, IoT) bypass it
  entirely and use Optimum's default resolver. They will fail to resolve
  `*.lab.jackhall.dev`, which is the accepted tradeoff.

## Why split-horizon

The goal is a real, browser-trusted wildcard certificate for
`*.lab.jackhall.dev` without either:

- Distributing a private CA to every device on the LAN, or
- Exposing internal services on the public internet just so Let's Encrypt
  can validate them with HTTP-01.

The split:

- **DNS-01 against Cloud DNS** lets cert-manager prove ownership of the
  `lab.jackhall.dev` zone by writing a `TXT` record. No inbound traffic
  required, and no public A/AAAA records required.
- **Internal A records served by AdGuard Home** mean the actual hostnames
  (`dashboard.lab.jackhall.dev`, `argocd.lab.jackhall.dev`, etc.) only
  resolve from inside the LAN, on devices configured to use it.

The issued wildcard cert is valid against any `*.lab.jackhall.dev` name
regardless of which side answered the DNS query, so browsers see a green
padlock for internal-only services.

## Reaching AdGuard Home

Three theoretical ways to point devices at AdGuard Home; only one is in use.

- **Path A — DHCP-pushed DNS.** The router advertises `192.168.1.200` as
  the DNS server in DHCP leases. **Not available**: the Optimum Gateway 6E
  exposes no custom-DNS-via-DHCP setting and no DHCP-disable.
- **Path B — Bridge mode + downstream router.** Put the Optimum gateway in
  bridge mode, run a real router behind it, then use Path A from there.
  Recorded as the future escape hatch; not pursued today.
- **Path C — Per-device manual config.** Set `192.168.1.200` as the DNS
  server on each device by hand. **This is the steady state.**

Path C means non-configured devices bypass AdGuard. That's accepted: the
operator's own devices are the ones that need `*.lab.jackhall.dev`
resolution and ad-blocking; everything else can use Optimum's resolver.

## Per-OS manual DNS recipes

Each recipe sets `192.168.1.200` as the only DNS server for the active
Wi-Fi or Ethernet connection. DNS settings are stored per network profile,
not globally — repeat per network (home Wi-Fi, wired, etc.) as needed.

To verify after changing, run from a terminal on the device:

```sh
dig +short dashboard.lab.jackhall.dev
```

It should return a `192.168.1.2xx` address. If it returns `NXDOMAIN` or
nothing, the device is still using its old DNS server.

### macOS

1. Open **System Settings → Network**.
2. Click the active connection (Wi-Fi or the Ethernet entry), then
   **Details…**.
3. Select **DNS** in the sidebar.
4. Under **DNS Servers**, click **+** and enter `192.168.1.200`.
5. Select any greyed-out DHCP-supplied entries and click **−** to remove
   them. Greyed entries are inherited from DHCP; removing them makes the
   manual list authoritative.
6. Click **OK**, then **Apply**.

### iOS / iPadOS

1. Open **Settings → Wi-Fi**.
2. Tap the **ⓘ** next to the active network.
3. Scroll to **DNS** and tap **Configure DNS**.
4. Switch from **Automatic** to **Manual**.
5. Under **DNS Servers**, tap **Add Server** and enter `192.168.1.200`.
6. Tap the red **−** next to any auto-populated servers and tap **Delete**.
7. Tap **Save** (top right).

### Windows 11

1. Open **Settings → Network & internet**, then click **Wi-Fi** (or
   **Ethernet**).
2. Click the active network's name to open its properties.
3. Find **DNS server assignment** and click **Edit**.
4. Change the dropdown from **Automatic (DHCP)** to **Manual**.
5. Toggle **IPv4** on.
6. Set **Preferred DNS** to `192.168.1.200`. Leave **Alternate DNS**
   blank, and leave **DNS over HTTPS** at its default.
7. Click **Save**.

### Android

Steps vary slightly by skin (Pixel/stock vs. Samsung One UI). The Pixel
flow:

1. Open **Settings → Network & internet → Internet**.
2. Tap the **gear** ⚙ next to the active Wi-Fi network.
3. Tap the **pencil** ✏ (top right), then expand **Advanced options**.
4. Change **IP settings** from **DHCP** to **Static**.
5. Fill in the fields, copying the values your router currently gave you
   for IP/gateway/prefix:
   - **IP address**: the address this device already has (check it before
     switching to Static).
   - **Gateway**: `192.168.1.1`.
   - **Network prefix length**: `24`.
   - **DNS 1**: `192.168.1.200`.
   - **DNS 2**: leave blank, or repeat `192.168.1.200`.
6. Tap **Save**.

Android's **Private DNS** setting (Settings → Network & internet → Private
DNS) is **not** the right knob here — it requires DNS-over-TLS, which the
in-cluster AdGuard Home isn't fronting today.

### Linux (NetworkManager)

Most desktop distros (Ubuntu, Fedora, Arch with GNOME/KDE) use
NetworkManager. From a terminal:

1. List active connections to find the right name:

   ```sh
   nmcli connection show --active
   ```

2. Override DNS for that connection (replace `<name>` with the value from
   step 1):

   ```sh
   nmcli connection modify "<name>" \
     ipv4.dns "192.168.1.200" \
     ipv4.ignore-auto-dns yes
   ```

3. Bounce the connection so the change takes effect:

   ```sh
   nmcli connection down "<name>" && nmcli connection up "<name>"
   ```

For headless boxes that use `systemd-resolved` directly (no NetworkManager),
edit `/etc/systemd/resolved.conf`, set the following under `[Resolve]`:

```ini
DNS=192.168.1.200
Domains=~lab.jackhall.dev
```

then run `sudo systemctl restart systemd-resolved`. The `~lab.jackhall.dev`
routing domain ensures queries for that suffix are sent to AdGuard Home
even if other resolvers are configured for general traffic.
