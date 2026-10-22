# GW Switch

A macOS menu-bar utility that shows whether your **default gateway is Wi-Fi** and
fixes it with one click when your VPN steals the default route.

- 🟢 default gateway is Wi-Fi (`en0`)
- 🟠 default gateway is something else (usually the VPN tunnel `utunN`)
- **Left-click 🟠** → instantly routes your configured networks through the VPN
  tunnel and resets the default gateway back to Wi-Fi — **no password prompt**
- **Left-click 🟢** → opens the control window
- **Right-click** → menu (Open window, Route via Wi-Fi now, Reset to VPN, Quit)

Two directions:

- **Route via Wi-Fi** — the fix: routes your configured networks through the tunnel and points the default gateway at Wi-Fi.
- **Reset to VPN (original)** — the undo: restores the default route that was in
  effect just before you applied the fix (i.e. hands the default back to the VPN
  tunnel). The daemon records the pre-fix default on every apply; if none was
  recorded it falls back to the current `utun` default route.

The app **auto-starts at login** via a LaunchAgent installed in
`/Library/LaunchAgents` (loads for every user at their next login; the installer
also starts it immediately for the user running the install).

It grew out of a shell script that did the same route juggling by hand; this
packages that fix as a shareable app with a one-time privileged install.

## How the "no password after install" works

macOS route changes require root. Rather than prompting every time (or granting
the app broad `sudo`), GW Switch installs a tiny **root LaunchDaemon**
(`gatewayd`) that does the privileged work:

```text
GW Switch (your user, no privileges)
        │  JSON over a local Unix socket  (/var/run/gatewaytray.sock, root:admin, 0660)
        ▼
gatewayd (root LaunchDaemon)
        │  /sbin/route add/delete   (argv arrays, never a shell)
        ▼
   routing table
```

The `.pkg` installer asks for an admin password **once** to place and load the
daemon. Every route change after that goes through the already-running root
daemon, so there is no further prompt.

### Security model (worth reading before wide distribution)

- The app holds **no** privileges and is granted **no** `sudo` rights.
- `gatewayd` detects the Wi-Fi/VPN interfaces and the Wi-Fi gateway **itself**.
  The client can only send a **list of CIDR networks**, each strictly validated
  (`isValidCIDR`) before use. It cannot supply an interface, a gateway, or a
  command.
- All external commands run via **argv arrays** (`Process` with `arguments`),
  never a shell string — so there is no command-injection path even for
  malformed input.
- The socket is `root:admin`, mode `0660`: only root and members of the `admin`
  group (i.e. administrator accounts) can request route changes. Standard user
  accounts cannot.
- The daemon binary is installed root-owned (`root:wheel`, `755`) and is not
  writable by regular users.

### Security & deployment (read before distributing)

This tool is designed for **individual, personal use on your own Mac**. Before
you deploy it to anyone else's machine, understand what it entails:

- **It installs a root LaunchDaemon that changes system networking.** Any
  admin-group process on the machine can drive it (reset the default route to
  Wi-Fi, add tunnel routes). That is acceptable for a personal routing utility;
  it is *not* automatically acceptable on managed/corporate endpoints.
- **The build is unsigned** (ad-hoc signature, not notarized). It will trip
  Gatekeeper, and it is not suitable for MDM/managed distribution without a
  proper Developer ID signature and notarization.
- **No warranty.** Provided as-is under the MIT license.

> If you are on a managed or corporate machine, get sign-off from whoever owns
> endpoint / security / change-management policy first. A root daemon that
> alters networking and overrides VPN routing is exactly the kind of change
> those teams need to review — installing it yourself may violate device or
> acceptable-use policy. When in doubt, ask before installing.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`). No other deps.
Produces an arm64 build; runs on Apple Silicon Macs, macOS 11+.

```bash
./build.sh                 # compiles gatewayd + GWSwitch.app into dist/build/
./packaging/build-pkg.sh   # produces dist/GWSwitch-1.0.pkg
```

## Install (per machine)

```bash
sudo installer -pkg dist/GWSwitch-1.0.pkg -target /
```

…or double-click the `.pkg`. Because it is **unsigned** (no Apple Developer ID),
Gatekeeper may block it: right-click the `.pkg` → **Open**, or approve it under
**System Settings → Privacy & Security**. The installer starts **GW Switch**
immediately and it auto-starts at every login (no need to add it to Login Items).

> The `.pkg` payload lists some `._*` files — a benign macOS `com.apple.provenance`
> artifact. The installer reconstructs the real files correctly.

## Configure the routed networks

Open the window (left-click 🟢, or right-click → Open) and edit the **Tunnel
networks** list — one CIDR per line, `#` to disable a line. Saved per-user at:

```text
~/Library/Application Support/GatewayTray/networks.conf
```

It is seeded with example networks on first run — replace them with your own.

## Uninstall

```bash
./uninstall.sh             # re-runs itself with sudo
```

Removes the daemon, app, LaunchDaemon plist, and socket. Leaves your per-user
config and `/var/log/gatewaytray.log` (delete manually if you want them gone).

## Layout

```text
gwswitch/
├── app/GatewayTray.swift          # menu-bar app + control window + socket client
├── daemon/gatewayd.swift          # root helper: Unix socket server + route ops
├── packaging/
│   ├── com.gatewaytray.daemon.plist   # root daemon (LaunchDaemon)
│   ├── com.gatewaytray.app.plist      # auto-start login agent (LaunchAgent)
│   ├── scripts/{preinstall,postinstall}
│   └── build-pkg.sh
├── build.sh                       # compile app + daemon
├── uninstall.sh
└── dist/                          # build output + .pkg (generated)
```
