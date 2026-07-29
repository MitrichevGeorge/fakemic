# fakemic

A fake virtual microphone manager for **PipeWire** (PulseAudio stack). Creates a
virtual capture device that is either **silent** or carries **white noise**, and
makes it the **default** microphone so browsers list it first / pre-select it.

Handy for privacy (feed silence instead of your real mic) or for testing apps
that need a mic signal without speaking into anything.

## Commands

```
fakemic silent   create/ensure a SILENT fake mic, make it the default
fakemic white    create/ensure a WHITE-NOISE fake mic, make it the default
fakemic clear    remove the fake mic and restore normal audio
fakemic status   show current state and the list of microphones browsers see
fakemic help     show help
```

State survives reboot: a PipeWire config drop-in recreates the carrier sink, and
a per-user systemd unit re-feeds the white noise (white mode only).

## Requirements (system, not pip)

These are checked at runtime:

- `pactl` — PulseAudio client (PipeWire's pipewire-pulse provides it)
- `sox` — only needed for `fakemic white`
- `systemctl` (systemd) — only needed for white-noise persistence across reboot

Install on common distros:

| Distro   | pactl                | sox          |
|----------|----------------------|--------------|
| Arch     | `pacman -S libpulse` | `pacman -S sox` |
| Debian   | `apt install pulseaudio-utils` | `apt install sox` |
| Fedora   | `dnf install pulseaudio-utils`  | `dnf install sox` |

PipeWire + pipewire-pulse + WirePlumber must be running (standard on modern
desktop Linux). Run `fakemic` from your graphical user session.

### Optional env overrides

```
FAKEMIC_NOISE_GAIN   white-noise level in dBFS (default -20)
FAKEMIC_NOISE_SECS   seconds per feeder stream (default 86400)
NO_COLOR             set to disable colored output
```

## Install

### pipx (recommended)

```bash
pipx install git+...
```

### uv

```bash
uv tool install ./fakemic
```

### plain pip

```bash
pip install --user ./fakemic
```

Make sure your pipx/uv/pip bin directory (`~/.local/bin` or similar) is on
`PATH` so `fakemic` resolves.

## Uninstall

```bash
fakemic clear
pipx uninstall fakemic
```

`fakemic clear` removes the PipeWire drop-in, the systemd unit, and the saved
default-source state, restoring your previous default microphone.

## License

MIT