---
name: synology-router-diag
description: Access and diagnose a Synology Router (SRM, e.g. RT2600ac) over its WebAPI - log in and check WAN/internet status, WiFi radios, DNS, gateway reachability, clock/NTP, and logs. Use when the user asks to check, diagnose, or troubleshoot their router, WiFi, or home internet connection, or wants router performance tuning advice.
license: MIT
metadata:
  author: worldofgeese
  version: "1.0.0"
  hardware: Synology RT2600ac (SRM 1.3.x); should work on other SRM routers
---

# Synology Router Diagnostics (SRM)

Read-only diagnosis of a Synology Router via its WebAPI. Distinguishes a WiFi
problem from an internet/WAN problem, so the user knows whether to fix their own
gear or call the ISP.

## Credentials & safety

- **Never hardcode or commit the password.** Ask the user at runtime, or read
  `SRM_URL`, `SRM_ACCOUNT`, `SRM_PASSWORD` from the environment.
- The script is **read-only** - it only calls `get`/`info`/`list`/`ping_start`
  and then logs out. It changes no settings.
- The router LAN address is typically `http://192.168.99.1:8000`. The web UI
  redirects to `/webman/index.cgi` (Synology SRM).

## Run it

```powershell
# Prompts securely for the password:
& "$HOME\.agents\skills\synology-router-diag\scripts\diagnose.ps1" `
    -RouterUrl http://192.168.99.1:8000 -Account admin

# Add -Raw to also print the raw JSON of every probe.
```

The script prints a section per area (System, WAN/Internet, Connectivity,
WiFi) and a final **Verdict** that classifies the fault.

## What it checks

| Area | API | Signal |
|------|-----|--------|
| Firmware / clock | `SYNO.Core.System` info | model, uptime, NTP, **clock skew** |
| WAN + DNS | `SYNO.Core.Network` get | WAN IP, gateway, DNS, **private-IP/double-NAT** |
| Internet status | `SYNO.Core.Network.Router.ConnectionStatus` get | ipv4/ipv6 `conn_status` |
| Reachability | `SYNO.Core.Network.Tool` ping_start | gateway vs `8.8.8.8`/`1.1.1.1` |
| WiFi on/off | `SYNO.Wifi.Network.NetworkDisabled` get | `is_disabled` |
| Radios | `SYNO.Wifi.Radio.Status` / `.Setting` get | channels, **DFS channel** |
| Logs | `SYNO.Core.SyslogClient.Log` list | recent events (manual) |

## SRM WebAPI quirks (important - these cost real time to discover)

1. **Login must be `POST` with `enable_syno_token=yes`.** A plain GET login, or
   POST without the token, returns `{"error":{"code":400}}` even with correct
   credentials. Endpoint: `/webapi/auth.cgi`, `api=SYNO.API.Auth`, `version=3`,
   `session=SRM`, `format=cookie`.
2. **Authenticate every later call with the `_sid` query param.** curl /
   Invoke-RestMethod do not reliably persist the SRM cookie; passing
   `&_sid=<sid>` on each request is what works. Omitting it => error `119`.
3. **Don't hardcode the entry path.** Most APIs route through an obfuscated
   `______..._entry.cgi`. Resolve each API's `path` from
   `SYNO.API.Info?query=all` at runtime.
4. **`ping_start` wants the target as a JSON string:** `target="8.8.8.8"`
   (URL-encode the quotes). Success = route exists; `error 4360` = ping failed /
   no route. There is no reliable `ping_get`; treat start success/failure as the
   result.
5. **`web_fetch` cannot reach the router** (private/loopback IPs are blocked).
   Use `curl.exe` or `Invoke-RestMethod` from PowerShell.

### Common error codes
`400` bad account/password - `403` 2FA/OTP required - `119` missing SID/token -
`103` unknown method - `117` no privilege - `4302` missing/invalid param -
`4360` ping failed / unreachable.

## Interpreting results (playbook)

- **WiFi enabled, radios broadcasting, but no internet, gateway pingable,
  public IPs not:** the fault is upstream of the router. If the WAN IP is
  private (e.g. `192.168.0.2`), the ONT/modem is in **router mode** and its own
  internet session is down, or it should be **bridged**. -> ISP issue; have them
  verify the WAN/PPPoE session and re-provision. A solid-green ONT optical light
  means the *fiber* is fine but says nothing about the *service session*.
- **Clock stuck far in the past + NTP enabled:** a *symptom* of no internet
  (NTP can't sync). It self-corrects once internet returns; a wrong clock can
  also break HTTPS/cert validation on clients meanwhile.
- **Gateway itself not pingable:** check WAN cable / ONT power / link.
- **`is_disabled = true`:** WiFi was simply switched off - re-enable it.

## Performance tuning (RT2600ac / SRM)

Suggest these once connectivity is healthy. All are in **Network Center ->
Wireless** unless noted.

1. **Avoid DFS 5 GHz channels.** Auto often parks 5 GHz on a DFS channel
   (52-144, e.g. 108); radar detection can silence/hop the radio. Pin a
   non-DFS channel: **36/40/44/48** or **149/153/157/161** (pick the least
   congested; upper band usually allows higher TX power).
2. **Channel width:** keep 5 GHz at **80 MHz** (`20_40_80`) and 2.4 GHz at
   **20 MHz** (40 MHz on 2.4 causes congestion).
3. **2.4 GHz channel:** use **1, 6, or 11** only; pick the clearest.
4. **Smart Connect / band steering:** enable to push capable clients to 5 GHz.
5. **De-double-NAT (biggest win):** put the ONT/modem in **bridge mode** and let
   the Synology do PPPoE/DHCP directly. Single NAT lowers latency and fixes port
   forwarding, UPnP, gaming and VPN.
6. **SmartWAN failover:** if there's no real second WAN, disable it so the
   health-check doesn't flap (`SYNO.Core.Network.SmartWAN.General`).
7. **Keep TX power High**, keep **beamforming** on.
8. **Firmware:** update SRM once back online.
9. **Fix the clock** if it doesn't self-sync after internet returns (NTP =
   `pool.ntp.org`).
