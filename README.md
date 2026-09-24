# Ghostlark

**Free, open-source VPN hub for people behind national firewalls.** Ghostlark finds public
proxy servers, rates how much protection each one really gives, verifies that they work, and
connects your Mac or Android phone through the best one. Built for restricted networks:
Reality-first, TLS fragmentation, an Extra Stealth mode, and a Shield mode that wraps a
Cloudflare WARP tunnel inside the proxy so the proxy operator sees only ciphertext.

Ghostlark is free and always will be. If it helps you, please share it with someone who needs it.

## Download

Go to the **[Releases](../../releases/latest)** page:

| Platform | File | Install |
|---|---|---|
| macOS 14+ (Apple Silicon) | `Ghostlark-mac.zip` | Unzip, drag `Ghostlark.app` to Applications. First launch: right-click → Open (the app is not notarized yet). |
| Android 8+ | `Ghostlark.apk` | Open the file on the phone and allow "install unknown apps" once. |

If GitHub is blocked where you are, the release files can also be mirrored on Telegram or
copied between phones; the APK is self-contained.

## Support the project

Ghostlark is free and always will be. Donations are optional and never unlock features;
they pay for code signing, notarization and download mirrors.

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/perseus-sepahi)

**[github.com/sponsors/perseus-sepahi](https://github.com/sponsors/perseus-sepahi)**

## How it works (macOS app)
Ghostlark finds free public proxy/VPN servers, rates how much protection each one actually
gives, verifies that they work, and connects your Mac through the best one. It is built
for restricted networks and drives the open-source
[sing-box](https://github.com/SagerNet/sing-box) core.

## Features

- **Discovery**: 18 built-in public aggregators (GitHub), fetched in parallel with jsDelivr
  and Statically CDN mirrors raced against the original URL so lists load even where
  `raw.githubusercontent.com` is blocked. When connected, fetching goes through the tunnel.
  Add your own subscription URLs or paste links.
- **Protocols**: VLESS (incl. Reality + XTLS-Vision), VMess, Trojan, Shadowsocks (AEAD and
  2022), Hysteria2, TUIC, WireGuard (Cloudflare WARP). Transports: TCP, WebSocket, gRPC,
  HTTP/2, HTTPUpgrade.
- **Security rating** (offline, per server): what the operator or a middlebox can see.
  Reality ≈ Strong, verified TLS ≈ Good, unverified TLS ≈ Weak, plaintext/broken ciphers
  = Unsafe (hidden by default).
- **Stealth score**: how the traffic looks to deep-packet inspection. Reality and
  CDN-fronted WebSocket/gRPC rank highest; QUIC-based protocols are marked as often
  throttled on restricted networks.
- **Verification**: hundreds of servers are tested in seconds by loading them into one
  throwaway core and using its Clash API delay test. Reliability history is kept per server.
- **Stealth mode**: uTLS browser fingerprint, TLS ClientHello fragmentation (defeats
  SNI-based blocking of the proxy itself), `.ir` domains routed directly, DNS-over-HTTPS
  through the tunnel, DNS hijack so nothing resolves in the clear.
- **Extra Stealth** (optional, same tunnel speed): only Reality or verified-TLS WebSocket/gRPC/HTTPUpgrade
  servers on HTTPS ports; Reality decoys that name big self-hosted sites (an SNI/IP mismatch) are ranked
  down; the scan is quiet (at most 80 probes, 8 at a time, previously verified servers first, stops once
  enough answer); QUIC (UDP 443) is rejected so browsers use plain HTTPS; and the core runs a failover
  pool of up to 4 verified servers so a blocked one is replaced without exposing traffic.
- **Shield mode**: a Cloudflare WARP WireGuard tunnel is run *inside* the free proxy.
  The proxy operator only ever sees WireGuard ciphertext and Cloudflare becomes the exit.
  Only servers that relay UDP can do this; Ghostlark probes candidates and remembers which ones can.
- **Verify-before-expose**: the core is started, a real request is made through it, and only
  then is the macOS system proxy set.
- **Kill switch**: if the core dies, the system proxy stays pinned to the dead local port so
  proxy-aware apps fail closed instead of leaking. Auto-reconnect moves to the next verified server.
- Menu bar item, live traffic counters, exit IP/country, core logs.

## Build

Requires Xcode 16+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Ghostlark.xcodeproj -scheme Ghostlark -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Ghostlark.app
```

The `sing-box` binary in `Ghostlark/Resources/bin/` is bundled into the app (1.14.0, arm64,
from Homebrew). To update it: `brew upgrade sing-box && cp /opt/homebrew/bin/sing-box Ghostlark/Resources/bin/`.

## Layout

```
Ghostlark/Sources
  Models/   ProxyNode, ShareLinkParser (vless/vmess/trojan/ss/hy2/tuic), SafetyScorer, AppSettings
  Core/     SingBoxConfig (JSON builder), CoreProcess, ClashAPI, SystemProxy, Keychain
  Services/ SourceService, NodeTester, ConnectionManager, WARPService, LogStore
  App/      GhostlarkApp, AppState (orchestration + persistence)
  Views/    Dashboard, Servers, Sources, Logs, Settings, MenuBar
```

Data lives in `~/Library/Application Support/Ghostlark/` (settings, sources, cached servers,
generated core configs). The WARP private key is stored in the Keychain.

## Signing the Mac app (maintainers)

Release builds are signed with a Developer ID and notarized by Apple, so they open without warnings.

1. Xcode → Settings → Accounts: add your Apple ID, then Manage Certificates → **+** → *Developer ID Application*.
2. Create an app-specific password at https://account.apple.com (Sign-In and Security), then run once:
   `xcrun notarytool store-credentials ghostlark --apple-id YOU@EXAMPLE.COM --team-id TEAMID`
3. `scripts/release-mac.sh` builds, signs, notarizes and staples `release/Ghostlark-mac.zip`.

## Test hooks

- `--autoconnect` launch argument runs "Find best & connect" on start.
- `GHOSTLARK_LOGFILE=/path` mirrors the in-app log to a file.

## Honest limits

- **System-proxy mode only.** Apps that ignore macOS proxy settings are not tunnelled.
  A full-device TUN mode needs root or an Apple-signed Network Extension.
- **Free servers are run by strangers.** Without Shield, assume the operator can see any
  traffic that is not itself HTTPS. The safety rating describes the tunnel's crypto, not
  the operator's intentions.
- Shield/WARP: WireGuard is easy to fingerprint and Cloudflare's endpoints are sometimes
  throttled; that is exactly why it is wrapped inside a stealth proxy.
- Xray-only transports (XHTTP/SplitHTTP, mKCP, QUIC) are parsed but marked unsupported.

## Licences

Ghostlark is licensed under the GPLv3 (see LICENSE); sing-box is GPLv3 (SagerNet). Cloudflare WARP registration follows the
same public client API used by `wgcf`.
