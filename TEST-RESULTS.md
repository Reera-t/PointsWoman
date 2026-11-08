# PointsWoman validation

Date: 2026-11-08, Asia/Tehran. Host: Apple Silicon macOS 27.2. Swift 6.4 Command Line Tools; no full Xcode or paid signing identity.

## Automated checks

- 29 Swift checks: exact-host/subdomain boundaries, domain validation, PAC policy, configuration persistence and owner-only permissions, corrupt configuration handling, CONNECT/IPv6 authority parsing, HTTP rewriting, proxy credential stripping, WebSocket headers, malformed/ambiguous request rejection, shell quoting, recovery round trip, conflicting proxies, canceled authorization, external preference changes, stale snapshots, Chromium/Electron adapters, unsupported/invalid app bundles, saved selections, VPN-client exclusion, originally unset PAC URL restoration, scoped-route repair/cleanup, preexisting route preservation, and externally changed route preservation.
- 15 local integration tests: actual loopback socket binding, HTTP forwarding, a 1 MiB upload/download, HTTPS CONNECT with origin certificate unchanged, real WebSocket binary frames, 32 requests with 16 concurrent clients, PAC execution in Node, denied destinations, failed upstreams, occupied ports, missing interfaces, oversized/malformed headers, application proxy accepting destinations outside website rules, domain/app proxy separation, and CLI install/collision protection.
- App bundle plist and ad-hoc signature verified; icon packed as a valid ICNS asset.
- CLI installed at `~/.local/bin/pointswoman`; `--help`, `apps list`, and installed-app discovery executed successfully.

All 29 Swift checks and 15 integration tests passed against the packaged repair release. Network preference transactions are covered by injected-runner tests and the real Wi-Fi activation/restoration described below.

## Live V2Box evidence

V2Box was confirmed connected using both macOS network status and its visible UI. OpenVPN was not connected. No VPN or system proxy preferences were changed by the compatibility probe.

Three paths were compared on Wi-Fi `en0`: normal VPN traffic, explicitly interface-bound curl, and the PointsWoman interface-bound proxy.

| Target/check | Normal path | Physical curl | PointsWoman proxy |
| --- | --- | --- | --- |
| Public IP endpoint | Responded | Responded | Responded |
| `app.example.com` HTTPS HEAD | HTTP 403 | HTTP 200 | HTTP 200 |
| `chat.example.com` HTTPS HEAD | Request failed/timed out | Request failed/timed out | HTTP 200 |

PointsWoman's public egress matched physical curl and differed from normal VPN egress; all compared addresses used the same IP family. Actual public IP addresses were kept out of reports. This verifies direct proxy egress for that V2Box session. The Mattermost physical-curl failure is retained as observed; the successful PointsWoman request does not imply identical DNS/address selection between the two tools.

## UI and remaining manual checks

- Initial GUI launched and was visually inspected. Start proxy only and Stop both changed state correctly. No network proxy changes were made.
- Updated application picker was tested after unlocking the Mac: Google Chrome was selected through the native file dialog and appeared beside Mattermost. Launch Direct refused to alter an already-running Mattermost session, then successfully launched Chrome with its dedicated application proxy.
- Chrome rendered the `app.example.com/login` page through the application proxy. Proxy counters confirmed traffic. The temporary Chrome session was quit normally after testing; no login was submitted.
- Real Wi-Fi PAC activation succeeded. Restore exposed an originally unset PAC URL edge case: networksetup rejects an empty URL. The fix uses a one-shot, administrator-authorized SystemConfiguration helper, verifies the expected loopback URL under a preferences lock, removes that URL key, and preserves other preferences. The fixed CLI restored the original `URL: (null), Enabled: No` state and removed the recovery snapshot. GUI proxies were then stopped.
- Orion loaded the selected website's application shell through website rules but displayed the site's generic application error. Full Orion compatibility remains unresolved; it is not recorded as a successful full-page test. Dependency routing and WebKit behavior need further validation before claiming full Orion support.
- Real Mattermost authenticated session/file behavior remains unverified. No messages were sent and no private files uploaded.
- OpenVPN reconnect failure was subsequently reproduced and repaired as documented below. V2Box and OpenVPN were kept separate. No code automatically starts either VPN or connects them together.
- Application launch adapters configure supported Chromium/Electron proxy stacks. They do not capture arbitrary app traffic, UDP, WebRTC, DNS per app, or helpers using separate networking stacks. Application-specific overrides must be checked live.

## Reproduce

```sh
bash scripts/test.sh
python3 scripts/compatibility_probe.py dist/pointswomanctl --interface en0 --label 'V2Box connected'
```

Run the second command only after confirming the stated VPN is connected. Disconnect V2Box before testing OpenVPN. Probe changes no VPN or PAC settings.

## OpenVPN reconnect regression and repair

The user reconnected OpenVPN with V2Box disconnected and reported Mattermost disconnected again. Both PointsWoman loopback listeners remained healthy. Direct interface-bound curl and PointsWoman outbound connections failed; the proxy returned HTTP 502 with `Network is unreachable`. Mattermost resolved successfully, and a normal destination lookup selected the VPN while an `en0`-scoped lookup had no route.

Adding a default route scoped only to physical Wi-Fi through its DHCP gateway changed Mattermost's public `/api/v4/system/ping` request through the app proxy from HTTP 502 to HTTP 200. Ordinary lookup for `1.1.1.1` still selected the OpenVPN interface, while the explicitly Wi-Fi-scoped lookup selected `en0`.

The final CLI `repair-route` command was tested live and verified its ownership snapshot. The updated GUI was restarted with route monitoring. Removing only the owned scoped test route simulated the route loss from VPN reconnection. Within its monitoring cycle, the app recreated the route, displayed `Physical scoped route repaired`, and the health endpoint again returned HTTP 200 through the running app proxy.

The user then quit and reopened Mattermost normally and reported it stuck on Loading. Both proxy paths still returned HTTP 200, but automatic proxy configuration was disabled. PointsWoman's existing exact-domain PAC was enabled for Wi-Fi and verified as active. The user quit/reopened Mattermost normally again with OpenVPN connected and V2Box disconnected, and confirmed: `Yes, loads now`. The fixed proxy and scoped-route monitor were left running, with the PAC enabled for the desired routing. Full file transfers and calls remain outside this confirmation.

No VPN security setting was disabled and no broad destination-specific bypass route was added. Private Mattermost window inspection was stopped after automatic approval review rejected reading its full accessibility tree; subsequent verification used public health requests and PointsWoman's own UI. No messages were sent or files uploaded. Full support for every OpenVPN profile, IPv6-only paths, calls, and file workflows is not claimed.
