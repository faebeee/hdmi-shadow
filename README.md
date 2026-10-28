# hdmi-shadow

A small bash script to auto-detect a USB HDMI capture stick (e.g. a
"ShadowCast"-style UVC dongle) and display its live video + audio feed using
`ffplay`.

## Requirements

- `v4l2-ctl` (from `v4l-utils`)
- `ffplay` / `ffprobe` (from `ffmpeg`)
- `pactl` (PipeWire-Pulse or PulseAudio), for audio capture

All of the above are standard on most Linux distributions.

## Usage

```sh
./hdmi-view.sh [options]
```

### Options

| Flag | Description |
| --- | --- |
| `-n NAME` | Substring to match the USB video device name (default: common capture-card name patterns) |
| `-r WxH` | Force a resolution (e.g. `1920x1080`). Default: auto-pick the highest resolution the device reports |
| `-f FPS` | Force a framerate (e.g. `30`). Default: highest available at the chosen resolution (capped at 30 unless overridden) |
| `-a` | Audio only sanity check (list matching audio source and exit) |
| `-v` | Video only (no audio) |
| `-l` | List detected V4L2 devices and audio sources, then exit |
| `-d /dev/videoN` | Force a specific video device node (skip auto-detect) |
| `-h` | Show help |

### Examples

List all detected devices to find the right one:

```sh
./hdmi-view.sh -l
```

Auto-detect and play video + audio:

```sh
./hdmi-view.sh
```

Force a specific device, resolution, and framerate:

```sh
./hdmi-view.sh -d /dev/video2 -r 1920x1080 -f 30
```

Video only, no audio:

```sh
./hdmi-view.sh -v
```

## How it works

1. Scans `v4l2-ctl --list-devices` output for a device name matching the
   configured pattern (default matches names containing `capture`, `hdmi`,
   `shadow`, `cast`, `uvc`, or similar), filtering out metadata-only nodes.
2. Picks the best supported video format/resolution/framerate from
   `v4l2-ctl --list-formats-ext`, preferring MJPEG, the largest resolution,
   then the highest framerate (capped at 30 fps by default since many UVC
   sticks can't sustain higher rates over USB2 bandwidth).
3. Looks for a matching USB audio source via `pactl list short sources`.
4. If only video is available, streams directly from the V4L2 device into
   `ffplay`. If audio is also found, muxes video + audio into an MPEG-TS
   stream with `ffmpeg` and pipes it into `ffplay`, using low-latency flags
   on both ends.
