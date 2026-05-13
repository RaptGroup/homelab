# ADR-0003: Public domain, DNS-01 wildcard, split-horizon resolution

- **Status:** Accepted; amended 2026-05-12 (see [Amendment](#amendment-2026-05-12-apex-on-cloudflare))
- **Date:** 2026-05-10

## Context

LAN-only services (`dashboard.lab.jackhall.dev`,
`argocd.lab.jackhall.dev`, `hubble.lab.jackhall.dev`, etc.) need real
TLS that browsers, mobile devices, and visiting laptops trust without
per-device setup. The constraints are:

- The lab is intentionally **not** internet-exposed. No inbound port
  forwarding, no Cloudflare-fronted public surface for these services.
- Multiple device classes need to reach internal services:
  workstations, phones, occasional guests, IoT. Distributing a private
  CA root to every one of them is a non-starter for guests and IoT,
  and a chore for everything else.
- The Optimum Gateway 6E is the WAN router. It does **not** expose a
  custom-DNS-via-DHCP field and cannot be put into a DHCP-disabled
  mode without bridge mode. So the LAN cannot be told "use AdGuard for
  DNS" via DHCP without buying hardware.
- The operator owns `jackhall.dev` at a registrar and is happy to use
  a subzone for the lab. The apex zone is managed elsewhere and
  should stay untouched.
- LAN IPs (`192.168.1.x`) should not be published in public DNS even
  though there is no inbound exposure. There is no benefit to leaking
  internal addresses.

CONTEXT.md introduces three labels — **Path A**, **Path B**, **Path C**
— for how a LAN device ends up using AdGuard Home as its resolver.
This ADR commits to one of them.

## Decision

Use a **public domain with an NS-delegated subzone, an ACME DNS-01
wildcard certificate, and AdGuard Home as a split-horizon LAN resolver
configured per-device (Path C).** Concretely:

1. **Domain.** `jackhall.dev` is the existing public domain. The
   registrar holds the apex zone. The `lab` subzone is **NS-delegated
   to a Google Cloud DNS zone** managed by `terraform/gcp/`. The apex
   is not modified by this repo.

   *(Amended 2026-05-12: the apex itself now lives on Cloudflare; the
   lab subzone stays on Cloud DNS via NS delegation from CF. See
   [Amendment](#amendment-2026-05-12-apex-on-cloudflare).)*
2. **Wildcard certificate.** A cert-manager `ClusterIssuer` configured
   for Let's Encrypt with the `cloudDNS` solver authenticates via the
   GCP service account created in `terraform/gcp/`. A wildcard
   `Certificate` for `*.lab.jackhall.dev` is issued at bootstrap and
   renewed automatically. Every internal service that consumes the
   wildcard gets a browser-trusted cert with no per-service ACME
   round-trip.
3. **Split-horizon resolution.**
   - **Internal view:** AdGuard Home runs in-cluster, pinned to
     `192.168.1.200` in the LB pool. It serves
     `*.lab.jackhall.dev → 192.168.1.x` (the LB-pool IP for each
     service) for any LAN client that uses it as its resolver.
   - **Public view:** Google Cloud DNS holds only what the ACME DNS-01
     challenge needs and any genuinely public records. Internal LAN
     IPs are never published.
4. **Reach: Path C — per-device manual DNS.** Every device that wants
   ad-blocking and `*.lab` resolution sets `192.168.1.200` as its DNS
   server manually. Per-OS recipes are documented in the docs site.
   Non-configured devices (guests, IoT) bypass AdGuard, fall through
   to Optimum's upstream DNS, and resolve neither `*.lab` nor get
   ad-blocking. This is acceptable steady state.
5. **Scope.** Only `HTTPRoute` (TLS terminates at the Gateway). The
   wildcard cert's private key lives in the cluster; it is not
   distributed to clients.

## Consequences

**Positive**

- Real, browser-trusted TLS on every internal service. No "trust this
  certificate" prompt on phones, on guest laptops, or on the Apple TV.
- LAN IPs are never published. The public Cloud DNS zone holds ACME
  challenge records and the (small) set of intentionally-public names
  only.
- The wildcard cert covers every future `*.lab.jackhall.dev` service
  with no per-service ACME round-trip and no per-service rate-limit
  exposure.
- DNS-01 works entirely outbound from the cluster. No inbound
  port-forward, no public ingress just to satisfy ACME.
- Split-horizon decouples "what does this name resolve to" from "is
  this service reachable from the internet?" — the LAN view changes
  freely without ever publishing it.

**Negative**

- **Path C is per-device.** Every workstation, phone, and tablet that
  wants `*.lab` resolution has to be configured by hand once. Guest
  devices and most IoT will not get configured and won't see internal
  names. This is documented as a known limitation.
- **AdGuard becomes a LAN-DNS dependency.** If AdGuard is down,
  configured devices fall through to Optimum's resolver per the OS's
  fallback behaviour, which means they keep working for public names
  but lose internal name resolution and ad-blocking until AdGuard is
  back. Mitigated by: AdGuard is rejected as the LAN's DHCP server
  (cluster-as-SPOF avoidance); cluster recovery from total loss is
  fast on Talos; the failure mode is "no internal DNS," not "no
  internet."
- **GCP dependency.** Cloud DNS is a paid GCP resource. Cost is
  negligible at homelab scale, but a hard dependency on GCP for cert
  issuance exists by design.
- **LE rate limits.** Bound to the public zone. Wildcard issuance
  keeps the request volume trivial; this would matter if per-service
  certs were used instead, which they aren't.
- **Subzone delegation must stay correct.** If the registrar's NS
  records for `lab.jackhall.dev` drift away from the Cloud DNS zone's
  nameservers, ACME breaks. The TF root outputs the NS records
  explicitly so this is a one-time, copy-paste-from-output operation
  rather than a console-hunt.

## Alternatives considered

### Private CA + mkcert (or similar) on every device

Rejected. Standing up a private CA solves the issuer problem but
displaces it onto every client: workstations, phones, the Apple TV,
visiting laptops, guests. Mobile and guest devices are an immediate
wall — installing a custom CA on a guest's iPhone is not an
acceptable onboarding step. The operational burden of CA key
management (rotation, distribution, revocation) replaces a managed,
free Let's Encrypt path with a homegrown one. There is no value the
private CA provides over a wildcard public cert that this homelab
needs.

### `.local` mDNS / Bonjour

Rejected. mDNS resolves names but offers no path to TLS — no public
CA will issue a certificate for a `.local` hostname, and a private CA
returns us to the rejected option above. mDNS reliability across OSes
and across VLANs is uneven. The split-horizon strategy here uses real
DNS records over a real domain precisely so that browsers and
certificate validation behave normally.

### Cloudflare Tunnel (or any externally-fronted tunnel)

Rejected. Cloudflare Tunnel terminates client TLS at Cloudflare and
proxies traffic into the cluster. The lab's design intent is the
opposite: services are LAN-only, no third party in the request path,
no implicit "this is on the internet now" surface. CF Tunnel also
adds latency for what is intentionally LAN-to-LAN traffic, and a
hard runtime dependency on a third party for what should work even
when the internet is down.

### Tailscale Funnel (or any VPN-fronted exposure)

Rejected. Same shape as Cloudflare Tunnel — externalises the request
path for a service designed to be LAN-only — with the additional
constraint that every client needs a Tailscale install. That breaks
the guest case and the IoT case completely. Tailscale remains useful
as a future, separate decision (remote access for the operator), but
it is not the right answer for "how do internal services get TLS?"

## Amendment 2026-05-12 (apex on Cloudflare)

ADR-0006 introduces a second public surface (`projects.jackhall.dev`,
for public preview environments) fronted by a Cloudflare Tunnel.
Implementing that surface revealed a constraint that affects this
ADR's apex-on-Cloud-DNS posture:

**Cloudflare's subdomain-zone path on every plan requires the parent
zone to already be on Cloudflare authoritative DNS.** Adding
`projects.jackhall.dev` as a CF-managed zone while leaving the apex
on Cloud DNS is not supported on the Free, Pro, or any plan below
Business ($200/mo, via Partial CNAME Setup). ADR-0006's $0 steady-
state cost is load-bearing in that ADR's cost-for-parity decision
against the GCP-bastion alternative, so paying $200/mo here would
invert the math.

The narrower alternative is to **move the apex `jackhall.dev` zone
to Cloudflare** and keep `lab.jackhall.dev` exactly as-is on Cloud
DNS via NS delegation from the new CF-managed apex. Concretely:

1. **Apex on CF.** The registrar (Squarespace) nameservers move from
   the four `ns-cloud-a{1,2,3,4}.googledomains.com.` (Cloud DNS's
   apex-serving NS shard) to the two `*.ns.cloudflare.com` values
   Cloudflare assigns to the apex zone. The Cloud DNS apex zone
   becomes vestigial — kept in `terraform/gcp/` as a dormant fallback
   during Squarespace propagation, destroyed in a follow-up
   ([#146](https://github.com/RaptGroup/homelab/issues/146)) once the
   migration is verified stable.

2. **Apex CAA stays `letsencrypt.org`.** CF apex publishes both
   `issue` and `issuewild` for `letsencrypt.org`, mirroring the
   current Cloud DNS apex CAA verbatim. The CAA walk during
   `*.lab.jackhall.dev` renewal hits this record at the apex and
   matches Let's Encrypt — no change to cert-manager's issuance
   path.

3. **Lab subzone on Cloud DNS, unchanged.** CF apex publishes NS
   records at `lab.jackhall.dev` pointing at the four
   `ns-cloud-d{1,2,3,4}.googledomains.com.` values that authoritatively
   serve the existing Cloud DNS `lab.jackhall.dev` zone. The lab
   zone's records, the cert-manager DNS-01 solver SA
   (`cert-manager-dns01`), and the `roles/dns.admin` IAM binding on
   that zone are all unchanged. cert-manager continues to publish
   ACME TXT records to Cloud DNS exactly as before.

4. **Resolution path post-flip.** For an LE validator querying
   `_acme-challenge.lab.jackhall.dev`:
   - Squarespace → CF NS (apex authoritative).
   - CF apex returns NS for `lab` pointing at `ns-cloud-d*`.
   - Public resolver follows to Cloud DNS.
   - Cloud DNS lab zone serves the TXT.
   - The CAA walk:
     `_acme-challenge.lab` (no CAA) → `lab` (no CAA) →
     `jackhall.dev` (CF, CAA = `letsencrypt.org`) → match.

5. **Propagation safety.** During Squarespace propagation, some
   public resolvers still hit the old Cloud DNS apex (kept in place);
   others hit the new CF apex. Both publish the same CAA and the
   same lab NS delegation, so either path resolves to the same Cloud
   DNS lab zone with the same CAA outcome. No mid-state where cert
   renewal fails.

6. **DNSSEC.** Both Cloud DNS zones are unsigned today; CF defaults
   to DNSSEC off for new zones. No chain to migrate.

**What stays.** Every other part of this ADR is unaffected:
split-horizon resolution via AdGuard Home, Path C per-device DNS
configuration, the wildcard `Certificate` for `*.lab.jackhall.dev`,
LAN IPs never published. The internal LAN-resolution mechanism does
not depend on which DNS provider serves the apex.

**What changes structurally.** The "Negative" consequence above —
"GCP dependency" for cert issuance — is now joined by a new
dependency on Cloudflare for apex resolution. The two surfaces are
on two independent providers; loss of either degrades but does not
disable the other (CF down means apex doesn't resolve and the lab
subzone delegation can't be looked up, taking the lab surface with
it; Cloud DNS down means the lab subzone records don't resolve even
if CF is healthy). Mitigated by both providers being stable
managed services with high SLAs and zero shared infrastructure.

`terraform/gcp/` keeps the Cloud DNS lab zone and the cert-manager
SA. The apex zone, apex CAA, and the apex NS delegation record for
lab are kept in place during this PR's window as a dormant
fallback. The follow-up issue
[#146](https://github.com/RaptGroup/homelab/issues/146) destroys
them once propagation has settled and cert-manager has renewed at
least once through the new CAA-walk path.

`terraform/cloudflare/` owns the CF apex zone's records: apex CAA
(letsencrypt.org), lab NS delegation, the CAA exception at
`projects.jackhall.dev`, and the wildcard CNAME for the preview-env
tunnel. Records inside `lab.jackhall.dev` (the Cloud DNS subzone)
stay in `terraform/gcp/` and remain managed via the cert-manager SA
at runtime.
