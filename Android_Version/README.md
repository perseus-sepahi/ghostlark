# Ghostlark for Android

Android port of the Ghostlark VPN hub: same server discovery, safety/stealth rating, batch
verification, Stealth mode and Shield (Cloudflare WARP over proxy), on top of the
sing-box 1.14 core built as `libbox.aar` and driven through Android's `VpnService`.

## Build

Requirements: JDK 17, Android SDK (platform 35, build-tools 35), and `app/libs/libbox.aar`.

```bash
./gradlew assembleRelease
# → app/build/outputs/apk/release/app-release.apk
```

The release build is signed with the debug key so it can be sideloaded directly; use
your own keystore for store distribution.

### Rebuilding libbox.aar

```bash
git clone --depth 1 -b v1.14.0 https://github.com/SagerNet/sing-box
cd sing-box && make lib_install && ANDROID_HOME=~/Library/Android/sdk make lib_android
cp libbox.aar ../Android_Version/app/libs/
```

Extra Stealth (Home and Settings tabs) works exactly as on the Mac: stricter server rules, quiet scan,
QUIC blocked, failover pool. See the top-level README.

## How it differs from the Mac app

- **Full-device tunnel.** Android gives every app a TUN interface through `VpnService`,
  so all apps are protected, not only proxy-aware ones.
- **Kill switch is the OS's.** Turn on *Always-on VPN* and *Block connections without
  VPN* for Ghostlark in Android's VPN settings; the system then drops traffic whenever the
  tunnel is down. The Settings tab has a shortcut.
- **Scanning does not need VPN permission.** Batch tests load a config with no TUN
  inbound into the same core, so they run before the user grants VPN consent.
- **Local DNS** uses Android's `DnsResolver` on the underlying network (ported from
  sing-box for Android) so system DNS never loops through the tunnel.

## Layout

```
app/src/main/java/com/sepahi/ghostlark
  model/   ProxyNode, ShareLinkParser, SafetyScorer, AppSettings (+ sources, WARP account)
  core/    SingBoxConfig (TUN inbound), ClashApi, Warp (pure-Kotlin X25519 + registration)
  data/    SourceService (mirror racing), Store (JSON persistence)
  bg/      GhostlarkVpnService (VpnService + libbox PlatformInterface), CoreManager,
           DefaultNetworkMonitor, LocalResolver
  ui/      GhostlarkViewModel, MainActivity (Compose: Home, Servers, Sources, Settings)
```

Licence: GPLv3 for the whole project (the platform glue is derived from sing-box for Android, GPLv3).
