# AWS VPN Client for Omarchy

Connect to **AWS Client VPN** with SAML/SSO from the Omarchy bar: pick a
profile, log in through your identity provider in the browser, and watch
connection state in the status bar.

```
󰖂  idle        󰔟  connecting     󰌆  waiting on SSO
󰦝  connected   󰀦  error / daemon not running
```

- Multiple profiles, with a default you can switch
- Import `.ovpn` files from the panel, or point at one in place
- Browser SSO login (an existing IdP session is reused if you have one)
- Tunnel IP and server shown while connected
- Fully keyboard-driven panel
- Bundled CLI for scripting — the widget shells out to the same tool

## Why not plain OpenVPN

AWS returns the SAML assertion (~10 KB) through OpenVPN's **password field**,
which stock `openvpn` caps at 128 bytes. Connecting with the stock client
requires a patched binary. This plugin instead drives
[openlawsvpn](https://github.com/openlawsvpn/go-openlawsvpn), which implements
the OpenVPN3 protocol directly in Go and speaks AWS's SAML/CRV1 flow natively.

The tunnel is owned by a system daemon running as its own user with
`CAP_NET_ADMIN` — **not** root — so connecting never prompts for a password.

## Requirements

| Requirement | Notes |
|---|---|
| Omarchy | with the Quickshell-based `omarchy-shell` bar |
| `openlawsvpn-daemon` | the VPN engine (AUR) |
| `python3` | runs the bundled CLI |
| `gdbus` | talks to the daemon (ships with glib2) |
| A SAML-enabled `.ovpn` | must contain `auth-federate` |

`notify-send` is used for desktop notifications when present.

## Install

### 1. The VPN daemon

```bash
yay -S openlawsvpn-daemon
```

> **Known packaging bug (as of 1.2.3-1).** The systemd unit points at
> `/usr/libexec/openlawsvpn-daemon`, but the package installs the binary to
> `/usr/lib/openlawsvpn/`, so the daemon fails to start with `status=203/EXEC`.
> Until it's fixed upstream, add a drop-in:
>
> ```bash
> sudo mkdir -p /etc/systemd/system/openlawsvpn-daemon.service.d
> printf '[Service]\nExecStart=\nExecStart=/usr/lib/openlawsvpn/openlawsvpn-daemon\n' \
>   | sudo tee /etc/systemd/system/openlawsvpn-daemon.service.d/10-execstart.conf
> sudo systemctl daemon-reload
> ```

Then enable and start it:

```bash
sudo systemctl enable --now openlawsvpn-daemon
systemctl is-active openlawsvpn-daemon   # -> active
```

The package adds your user to the `openlawsvpn` group. That takes effect at
your next login; until then the daemon's D-Bus policy still allows any
logged-in local user, so it works right away.

### 2. The plugin

```bash
omarchy plugin add https://github.com/fernandoaleman/omarchy-aws-vpn-client --enable
```

That clones into `~/.config/omarchy/plugins/omarchy-aws-vpn-client/` and adds the
widget to the bar. To place it explicitly:

```bash
omarchy bar move fernandoaleman.aws-vpn-client --section right
```

Verify:

```bash
omarchy plugin list | grep fernandoaleman.aws-vpn-client   # -> enabled
```

### 3. Optional: CLI on your PATH

The widget always runs the copy inside the plugin, so this is only for using
the CLI yourself from a terminal:

```bash
ln -sfn ~/.config/omarchy/plugins/omarchy-aws-vpn-client/bin/omarchy-aws-vpn-client \
        ~/.local/bin/omarchy-aws-vpn-client
```

### 4. Optional: a keybinding

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + V", "AWS VPN", "omarchy-shell fernandoaleman.aws-vpn-client toggle")
```

Check the key is free first with `omarchy menu keybindings --print`; if it's
taken, `hl.unbind("SUPER + SHIFT + V")` before the `o.bind`, or pick another
combination such as `SUPER + CTRL + SHIFT + V`.

## Usage

### Setting up your first profile

Download your `.ovpn` from the AWS console — it must be the **SAML/federated**
profile, which contains `auth-federate` and no client certificate. Then either
drop it in `~/Downloads` and pick it from the panel's **IMPORT** section, or:

```bash
omarchy-aws-vpn-client add ~/Downloads/work.ovpn --name work
```

Importing copies the file into `~/.config/omarchy/aws-vpn-client/profiles/` with mode
`0600`, so it survives the download being cleaned up. Use `--link` to
reference the original in place instead.

### Connecting

Open the panel (bar icon or your keybinding) and activate a profile, or:

```bash
omarchy-aws-vpn-client connect work
```

Your browser opens at your identity provider. Log in; the assertion is posted
back to the daemon's local callback on `127.0.0.1:35001` and the tunnel comes
up. With a live SSO session this completes without any typing.

> **SAML tokens are valid for 1 hour.** Long sessions need a fresh login; the
> bar glyph turns to `󰌆` while one is pending.

### Mouse

| Action | Result |
|---|---|
| Left click | open/close the panel |
| Right click | connect (default profile) or disconnect |
| Middle click | refresh status and profiles |

### Keyboard (inside the panel)

| Key | Action |
|---|---|
| `j` / `k`, `↑` / `↓` | move the cursor |
| `Enter` / `Space` | activate the highlighted row |
| `c` | connect using the default profile |
| `d` | disconnect |
| `s` | make the highlighted profile the default |
| `r` | refresh |
| `Tab` | move to the next bar panel |
| `Esc` | close |

## CLI reference

```
omarchy-aws-vpn-client <command> [options]
```

| Command | Options | Description |
|---|---|---|
| `status` | `--json` | Connection state, profile, tunnel and server IP |
| `list` (`profiles`) | `--json` | List profiles; `*` marks the default |
| `add <path>` | `--name <name>`, `--link` | Import a profile (`--link` references the file in place instead of copying) |
| `remove <name>` (`rm`) | | Remove a profile; deletes the imported copy, never a `--link`ed original |
| `default <name>` | | Set the default profile |
| `connect [name]` | | Connect, opening the browser for SSO. Uses the default profile when omitted |
| `disconnect` | | Tear down the tunnel |
| `toggle [name]` | | Connect if idle, disconnect if not |
| `discover` | `--json` | List `.ovpn` files not yet added |
| `logs` | `-n`, `--lines <N>` | Daemon logs (default 50 lines) |

`status --json` returns:

```json
{
  "state": "connected",
  "label": "Connected",
  "profile": "work",
  "server_ip": "203.0.113.10",
  "assigned_ip": "172.31.0.42",
  "profiles": 1
}
```

`state` is one of `idle`, `connecting`, `waiting_saml`, `connected`,
`disconnecting`, `error`, `daemon-down`, `unknown` — useful for scripting or a
custom bar module.

### Where things are stored

```
~/.config/omarchy/aws-vpn-client/profiles.json      # profile list + default (0600)
~/.config/omarchy/aws-vpn-client/profiles/*.ovpn    # imported copies (0600)
```

The panel's **IMPORT** section scans `~/Downloads`, `~/Documents`,
`~/Desktop`, and `~` for `.ovpn` files that aren't already profiles.

## Widget settings

Configured per-instance in `~/.config/omarchy/shell.json`, or through the
bar's widget settings UI:

| Key | Type | Default | Range | Description |
|---|---|---|---|---|
| `refreshIntervalSec` | integer | `10` | 2–3600 | How often to poll connection state |

```json
{ "id": "fernandoaleman.aws-vpn-client", "refreshIntervalSec": 5 }
```

While connecting or waiting on SSO the widget polls once a second regardless,
so the panel tracks the login rather than lagging behind this interval.

## IPC

The widget registers an IPC target, so you can drive it from scripts or
keybindings:

```bash
omarchy-shell fernandoaleman.aws-vpn-client toggle       # open/close the panel
omarchy-shell fernandoaleman.aws-vpn-client open
omarchy-shell fernandoaleman.aws-vpn-client close
omarchy-shell fernandoaleman.aws-vpn-client connect      # default profile
omarchy-shell fernandoaleman.aws-vpn-client disconnect
omarchy-shell fernandoaleman.aws-vpn-client refresh
omarchy-shell fernandoaleman.aws-vpn-client status       # -> "Connected"
```

## How it works

```
Panel.qml / Service.qml   (Quickshell bar widget)
        │  runs
        ▼
bin/omarchy-aws-vpn-client       (Python CLI: profiles, browser hand-off)
        │  D-Bus, system bus: com.openlawsvpn.Daemon
        ▼
openlawsvpn-daemon        (Go OpenVPN3 client, CAP_NET_ADMIN, owns tun0)
```

1. The CLI subscribes to daemon signals, then calls `Connect(path, contents)`.
   The daemon runs with `ProtectHome=true` and cannot read your home
   directory, so the profile's **contents** are sent over the bus, not a path.
2. The daemon completes OpenVPN phase 1, starts a local SAML callback (ACS)
   server on `127.0.0.1:35001`, and emits `SAMLRequired(url)`.
3. The CLI opens that URL in your default browser.
4. Your IdP posts the assertion back to the ACS server.
5. The daemon uses it for phase 2 and brings up `tun0`.

## Troubleshooting

**"VPN daemon is not running"** — check `systemctl status openlawsvpn-daemon`.
A `status=203/EXEC` failure means the packaging bug above; apply the drop-in.

**Browser doesn't open** — the CLI uses `omarchy-launch-browser`, falling back
to `xdg-open`. Check `xdg-settings get default-web-browser`. The connect
output prints the URL so you can open it by hand.

**Login never completes** — the daemon waits 5 minutes for the callback. Make
sure nothing else holds port `35001`, and log in with the browser profile that
has your AWS SSO session.

**"warning: no auth-federate directive"** — you exported the certificate-based
profile rather than the SAML one. Re-download the federated `.ovpn`.

**Panel looks stale after editing the plugin** — Quickshell caches compiled
QML and can report errors at line numbers that no longer exist:

```bash
rm -rf ~/.cache/quickshell/qmlcache && omarchy restart shell
```

**Daemon logs** — `omarchy-aws-vpn-client logs -n 100`.

## Development

The installed plugin *is* the git checkout, so edits apply live — QML and
`shell.json` hot-reload on save. After changing the manifest:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/omarchy-aws-vpn-client
omarchy restart shell
```

Symlinks are rejected anywhere inside a plugin folder, so everything the
plugin needs must live inside the repo.

## Credits

Tunnel implementation by [openlawsvpn](https://github.com/openlawsvpn/go-openlawsvpn).
The SAML/CRV1 flow was originally reverse-engineered by
[samm-git](https://github.com/samm-git/aws-vpn-client).

Not affiliated with or supported by AWS.

## License

MIT — see [LICENSE](LICENSE).
