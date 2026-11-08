# PointsWoman

Local macOS menu-bar app for routing selected website and Mattermost domains through a proxy whose outbound sockets are bound to your physical network interface.

Preconfigured domains:

- `chat.example.com`
- `app.example.com`

Version 0.2 adds an application picker, saved app selections, direct app launch adapters, a standalone CLI, and an original app icon. No paid Apple signing membership required. It is not a transparent per-application router. Supported Electron and Chromium apps can launch with a direct HTTP/HTTPS/WebSocket proxy for all destinations; voice/video calls, UDP, QUIC, and arbitrary apps remain outside this version. VPN compatibility must be proven per connection; the UI never treats a successful connection as proof of bypass.

## Open

Open `dist/PointsWoman.app`, or extract the complete `dist/PointsWoman-macOS-arm64.zip` package. Build supplied for Apple Silicon. It uses a local ad-hoc signature, without an Apple Developer account or notarization. If downloaded onto another Mac, macOS may require the normal Privacy & Security “Open Anyway” approval. No system extension, certificate installation, SIP changes, or antivirus changes are needed.

1. Select your physical interface. `en0` is a common Wi-Fi interface, but verify yours using `pointswomanctl doctor` or `networksetup -listnetworkserviceorder`.
2. Keep the two default domains, or enter one hostname per line. Rules match exact hosts unless you enable subdomains. Login, CDN, upload, and download domains may need separate rules.
3. Connect V2Box **or** OpenVPN Connect normally.
4. Click **Start proxy only** first. This changes no network preferences. Test the proxy explicitly before enabling it for browsing.
5. Click **Enable for network** to set the PAC URL for your selected service. macOS requests administrator approval. Existing active proxies cause setup to refuse rather than overwrite them.
6. Reopen website connections in Orion and Chrome. For whole HTTP/HTTPS app sessions, see Applications below.
7. Click **Restore settings & stop** when finished. Normal Quit restores saved proxy preferences before exiting. Closing the window leaves PointsWoman in the menu bar.

For Mattermost opened normally from Dock/Finder, **Enable for network** must stay active so the `chat.example.com` domain rule is used. Selecting Mattermost in Applications alone does not alter normal launches; **Launch Direct** is a separate launch mode. The OpenVPN reconnect repair plus enabled domain PAC was verified by the user to clear Mattermost's Loading screen after a normal restart.

The PAC URL is `http://127.0.0.1:17839/proxy.pac`. Unmatched hosts return `DIRECT`, which means the normal OS/VPN path. Matched hosts return only `PROXY 127.0.0.1:17839`, without an explicit alternate proxy or direct fallback.

## Applications

Use **Add apps…** to select one or more `.app` bundles. Mattermost is preselected on first use when installed. Proxy launch adapters support Google Chrome, Chromium, Brave, Edge, and apps containing Electron Framework. Other apps are rejected with an explanation; the picker does not claim universal routing support. Orion and Safari use the website PAC rules instead.

Quit the selected app normally, then click **Launch Direct**. PointsWoman starts its two loopback proxies if needed and launches the app with `--proxy-server=http://127.0.0.1:17840`. All HTTP, HTTPS, and WebSocket destinations using that app's Chromium network stack go through the direct proxy, independent of website domain rules. This includes additional Mattermost login/file hosts without adding individual domains. Node networking, updaters, helper components with separate proxy behavior, localhost exceptions, WebRTC, and UDP are not forced through this proxy. Individual Electron apps may override proxy settings; verify your app's actual behavior.

An already-running app is never force-quit or relaunched automatically. Proxy options last for the launched session. Keep PointsWoman running while using it. After stopping PointsWoman, quit and reopen the selected app normally to restore normal networking. Removing an app from selections does not undo launch flags in an existing process.

The application proxy accepts all destinations on IPv4 loopback; other local processes can use it while it is running. This is a convenience proxy, not authenticated per-process traffic enforcement. The separate website proxy still enforces its domain allowlist.

## CLI only

No GUI is needed. Double-click `dist/Install CLI.command`, or run:

```sh
./dist/pointswomanctl install-cli
pointswoman --help
pointswoman apps discover
pointswoman apps add --app /Applications/Mattermost.app
pointswoman apps list
```

Installer creates `~/.local/bin/pointswoman` as a symlink to the executable. Existing different commands are not overwritten. Keep the original executable in place, or reinstall the link after moving it. Add `~/.local/bin` to PATH if your shell does not already include it. No shell profile is edited.

For applications, start a foreground proxy in one terminal:

```sh
pointswoman serve-apps --interface en0
```

Then quit Mattermost normally and launch it from another terminal:

```sh
pointswoman apps launch --app /Applications/Mattermost.app
```

For websites, start `pointswoman serve --interface en0`, then run `pointswoman apply --service Wi-Fi` in another terminal. Run `pointswoman restore` **before** stopping the foreground proxy. Ctrl-C stops the CLI server; it does not restore settings applied by another CLI command. Launching the GUI and CLI on the same ports concurrently fails clearly rather than replacing the running proxy.

Use `--app-port` to change application proxy port, `--port` for website proxy port, `--config` for a separate domain configuration, and `--apps-config` for separate saved app selections. `serve-apps` makes no network preference changes.

**PAC is not a traffic-enforcement boundary.** Browsers can behave differently when PAC is unavailable, cache rules, or use connections created before activation. There is no system-wide guarantee against fallback. Use this for routing convenience, not as an enforced privacy boundary.

## Recover after a crash

Keep `dist/Restore PointsWoman.command` beside `dist/pointswomanctl` or the app bundle. Double-click it, or reopen PointsWoman and choose **Restore settings & stop**.

```sh
./dist/pointswomanctl restore
```

Configuration, app selections, and recovery snapshot live in `~/Library/Application Support/PointsWoman/`. The recovery file records the network service and previous PAC settings. Setup refuses to overwrite an existing snapshot. Restore refuses to overwrite a different PAC URL installed by another app after PointsWoman. Snapshot is deleted only after restoration is verified. On failure, leave proxy running until settings are restored.

If automatic restore is unavailable, open System Settings → Network → the service you selected → Details → Proxies. Turn off Automatic Proxy Configuration if it still points to `http://127.0.0.1:17839/proxy.pac`. Preserve any settings you changed independently. Keep the recovery snapshot until restoration is confirmed.

## Diagnose and test manually

```sh
./dist/pointswomanctl doctor
./dist/pointswomanctl serve --interface en0
```

In a second terminal:

```sh
curl --noproxy '' --proxy http://127.0.0.1:17839 --connect-timeout 10 --max-time 20 -I https://app.example.com
curl --noproxy '' --proxy http://127.0.0.1:17839 --connect-timeout 10 --max-time 20 -I https://chat.example.com
```

The proxy supports HTTP, HTTPS CONNECT, and WebSocket upgrades. It forwards TLS bytes without decrypting them; the destination certificate remains the destination's certificate. Proxy credentials are stripped from forwarded HTTP requests. Listener is IPv4 loopback only and rejects domains outside its allowlist. Other local processes can use listed destinations through this proxy; this is not process authentication.

System DNS remains in use, including VPN-supplied DNS for internal hosts. IPv4 sockets use `IP_BOUND_IF`, IPv6 sockets use `IPV6_BOUND_IF`. An unavailable interface or failed connection returns an error instead of opening an unbound socket. VPN enforcement, kill switches, and corporate endpoint software may still block direct connections. No such settings are changed automatically.

To verify bypass rather than mere connectivity, compare egress through a controlled IP-check endpoint with VPN on/off, or inspect interface traffic. Test V2Box and OpenVPN Connect separately, **never connected together**, then test real Mattermost login/messages/files and browser navigation. `scripts/compatibility_probe.py` compares normal, interface-bound curl, and PointsWoman proxy paths without changing VPN or proxy settings, and redacts actual public IP addresses from output. A public IP check does not prove every service dependency uses the intended route. See `TEST-RESULTS.md` for checks performed on this build.

## Build and automated checks

Requires macOS 13+, Swift 6 Command Line Tools, and no third-party Swift packages. Full Xcode is optional. Builds target the host architecture; the supplied app is arm64. Python 3 with SSL and `/usr/bin/openssl` run local integration tests; Node optionally executes generated PAC in an actual JavaScript engine.

```sh
bash scripts/build.sh
bash scripts/test.sh
```

Use `POINTSWOMAN_BUILD_DIR=/absolute/path` to place caches outside the source tree. Swift checks cover rule boundaries, parser validation, configuration persistence, proxy conflicts, cancellation, and settings restoration using an injected network-preferences runner. Integration tests use local origin servers and `lo0`, testing actual socket binding, TLS CONNECT/certificates, uploads/downloads, WebSocket frames, concurrent connections, and failure handling without changing system preferences.

## Components

- `PointsWomanCore`: configuration, PAC generation, bound-socket proxy, and reversible proxy preferences.
- `PointsWoman`: SwiftUI settings window and AppKit menu-bar lifecycle.
- `pointswomanctl`: proxy server, diagnostics, PAC output, network activation, and recovery.
- `PointsWomanChecks`: assertion runner requiring no XCTest installation.

Original AppKit vector icon source is `scripts/make-icon.swift`; rendered PNG and ICNS live in `Resources/` and the built app bundle. Build regenerates artwork at every required Dock/Finder size.

Runtime keeps only counters and latest domain/error in memory, with no request-body, token, or message logging. Configuration and recovery JSON use owner-only permissions. The source does not include VPN profiles or Mattermost credentials.

Known validation limits: V2Box direct egress and Chrome's selected-site login page were verified. Orion displayed the website's generic application error despite loading its shell; additional dependency rules or browser-specific investigation remain necessary. An OpenVPN reconnect regression was reproduced and repaired as described below; this does not establish compatibility with every OpenVPN profile or kill-switch policy. Authenticated Mattermost file flows remain unverified.

## OpenVPN reconnect repair

Some OpenVPN profiles remove the physical interface's scoped default route on connection. Binding a proxy socket to `en0` then fails with `Network is unreachable`, even while the local proxy is healthy. PointsWoman now checks that route every five seconds while its GUI proxy is running. If missing, it requests administrator authorization to add an **IPv4 interface-scoped** default route through the interface's DHCP router. Ordinary unbound internet traffic retains its VPN route. Existing scoped routes are left alone.

Use **Repair direct route** to retry manually after an authorization cancellation. Automatic retries pause after an error to avoid repeated prompts. Keep PointsWoman running while using apps launched through its proxy. Static/manual gateway configurations and enforced VPN policies may require separate configuration; this repair never disables VPN security settings.

CLI users can run `pointswoman repair-route --interface en0` after connecting or reconnecting OpenVPN. `pointswoman restore-route` removes only a route tracked as created by PointsWoman; stop the GUI monitor first if using this CLI cleanup. Normal GUI Stop/Quit restores its owned route. A changed external route is preserved, with its recovery snapshot retained. The IPv4 repair does not add IPv6 routes.

For an originally unset PAC URL, restore invokes the bundled CLI once with macOS administrator authorization to remove the URL key through SystemConfiguration. The helper checks the expected PointsWoman URL while holding a preferences lock; no persistent privileged daemon is installed. `pointswoman gui open` and `pointswoman gui quit` provide normal GUI lifecycle control from the CLI.

Inspired by [Pointsman](https://github.com/pooriaanv/Pointsman); independently written Swift implementation, with no WinDivert or copied Pointsman code.