#!/usr/bin/env bash
#
# hdmi-view.sh - Auto-detect a USB HDMI capture stick (e.g. "ShadowCast" UVC
# dongle) and show its live video + audio with ffplay.
#
# Usage:
#   ./hdmi-view.sh [options]
#
# Options:
#   -n NAME        Substring to match the USB video device name
#                   (default: tries common capture-card name patterns)
#   -r WxH         Force a resolution (e.g. 1920x1080). Default: auto-pick
#                   the highest resolution the device reports.
#   -f FPS         Force a framerate (e.g. 30). Default: highest available
#                   at the chosen resolution.
#   -a             Audio only sanity check (list matching audio sources and exit)
#   -v             Video only (no audio)
#   -l             List detected V4L2 devices and audio sources, then exit
#   -d /dev/videoN Force a specific video device node (skip auto-detect)
#   -h             Show this help
#
# Requires: v4l2-ctl, ffplay, ffprobe (ffmpeg), pactl (pipewire-pulse or
# pulseaudio). All standard on most Linux distros.

set -euo pipefail

# ---- defaults -------------------------------------------------------------
NAME_PATTERN="capture|hdmi|shadow|cast|uvc|usb.*video|video.*usb"
FORCE_RES=""
FORCE_FPS=""
FORCE_DEV=""
AUDIO_ONLY=0
VIDEO_ONLY=0
LIST_ONLY=0

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts "n:r:f:avld:h" opt; do
  case "$opt" in
    n) NAME_PATTERN="$OPTARG" ;;
    r) FORCE_RES="$OPTARG" ;;
    f) FORCE_FPS="$OPTARG" ;;
    a) AUDIO_ONLY=1 ;;
    v) VIDEO_ONLY=1 ;;
    l) LIST_ONLY=1 ;;
    d) FORCE_DEV="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

for bin in v4l2-ctl ffplay ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing required tool: $bin" >&2; exit 1; }
done

# ---- helpers ---------------------------------------------------------------

# Print "<device block>" sections from v4l2-ctl --list-devices
list_v4l2_blocks() {
  v4l2-ctl --list-devices 2>/dev/null
}

# Find the first /dev/videoN node whose device name matches NAME_PATTERN and
# which actually supports video capture (not metadata-only nodes).
detect_video_device() {
  local block_name="" dev=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^[^[:space:]].*:$ ]]; then
      block_name="$line"
    elif [[ "$line" =~ /dev/video([0-9]+) ]]; then
      dev="${BASH_REMATCH[0]}"
      if echo "$block_name" | grep -qiE "$NAME_PATTERN"; then
        # Must support actual capture formats (filters out metadata nodes)
        if v4l2-ctl -d "$dev" --list-formats 2>/dev/null | grep -qE "MJPG|YUYV|NV12|H264"; then
          echo "$dev"
          return 0
        fi
      fi
    fi
  done < <(list_v4l2_blocks)
  return 1
}

# Pick the best (largest resolution, then highest fps) format for a device.
# Prefers MJPEG (most UVC capture sticks only do full res in MJPEG).
pick_best_format() {
  local dev="$1"
  v4l2-ctl -d "$dev" --list-formats-ext 2>/dev/null | awk -v dev="$dev" '
    /\[[0-9]+\]/ { if (match($0, /'"'"'[A-Za-z0-9]+'"'"'/)) { fmt=substr($0, RSTART+1, RLENGTH-2) } }
    /Size:/ {
      split($0, a, " "); res=a[3]; split(res, wh, "x"); w=wh[1]; h=wh[2]
      pixels = w * h
    }
    /Interval:/ {
      match($0, /\(([0-9.]+) fps\)/, m)
      fps = m[1] + 0
      if (pixels > bestpixels || (pixels == bestpixels && fps > bestfps)) {
        bestpixels = pixels; bestfps = fps; bestres = res; bestfmt = fmt
      }
    }
    END { printf "%s %s %s\n", bestfmt, bestres, bestfps }
  '
}

# Find a PipeWire/Pulse audio source matching the same capture device name.
detect_audio_source() {
  pactl list short sources 2>/dev/null | awk '
    tolower($0) ~ /usb/ && tolower($0) !~ /monitor/ {print $2; exit}
  '
}

# ---- listing mode -----------------------------------------------------------
if [[ "$LIST_ONLY" -eq 1 ]]; then
  echo "== V4L2 devices =="
  list_v4l2_blocks
  echo
  echo "== Audio sources =="
  pactl list short sources 2>/dev/null
  exit 0
fi

# ---- resolve video device ---------------------------------------------------
DEV="$FORCE_DEV"
if [[ -z "$DEV" ]]; then
  if ! DEV="$(detect_video_device)"; then
    echo "Could not auto-detect a capture device. Plug in the HDMI capture" >&2
    echo "stick and retry, or list devices with: $0 -l" >&2
    echo "You can also force a device with: $0 -d /dev/videoN" >&2
    exit 1
  fi
fi
echo "Using video device: $DEV"

# ---- resolve format/resolution/fps ------------------------------------------
FMT="MJPG"
RES="1280x720"
FPS="30"
if [[ -n "$FORCE_RES" || -n "$FORCE_FPS" ]]; then
  [[ -n "$FORCE_RES" ]] && RES="$FORCE_RES"
  [[ -n "$FORCE_FPS" ]] && FPS="$FORCE_FPS"
else
  read -r auto_fmt auto_res auto_fps < <(pick_best_format "$DEV" || true)
  if [[ -n "${auto_res:-}" ]]; then
    FMT="${auto_fmt:-MJPG}"
    RES="$auto_res"
    FPS="${auto_fps%.*}"
    [[ -z "$FPS" || "$FPS" == "0" ]] && FPS="30"
    # Many UVC capture sticks advertise fps (e.g. 60) at full resolution that
    # they can't actually sustain reliably over USB2 bandwidth, causing
    # corrupted/dropped MJPEG frames. Cap to 30fps by default; use -f to
    # override if your device/bus can handle more.
    if (( FPS > 30 )); then
      FPS=30
    fi
  fi
fi
echo "Using format: $FMT  resolution: $RES  fps: $FPS"

# ---- resolve audio source ---------------------------------------------------
AUDIO_SRC=""
if [[ "$VIDEO_ONLY" -eq 0 ]]; then
  AUDIO_SRC="$(detect_audio_source || true)"
  if [[ -n "$AUDIO_SRC" ]]; then
    echo "Using audio source: $AUDIO_SRC"
  else
    echo "No matching USB audio source found - continuing video-only." >&2
  fi
fi

if [[ "$AUDIO_ONLY" -eq 1 ]]; then
  echo "Audio-only check requested. Detected source: ${AUDIO_SRC:-<none>}"
  exit 0
fi

# ---- build and run -----------------------------------------------------------
INPUT_FORMAT="mjpeg"
[[ "$FMT" == "YUYV" ]] && INPUT_FORMAT="yuyv422"
[[ "$FMT" == "NV12" ]] && INPUT_FORMAT="nv12"
[[ "$FMT" == "H264" ]] && INPUT_FORMAT="h264"

if [[ -z "$AUDIO_SRC" ]]; then
  # Video only: ffplay can read straight from the v4l2 device.
  CMD=(ffplay
    -fflags nobuffer
    -flags low_delay
    -framedrop
    -probesize 64
    -analyzeduration 0
    -f v4l2
    -input_format "$INPUT_FORMAT"
    -video_size "$RES"
    -framerate "$FPS"
    -i "$DEV"
    -window_title "HDMI Capture - $DEV"
  )
  echo "Running: ${CMD[*]}"
  exec "${CMD[@]}"
else
  # Video + audio from two separate devices: ffplay only supports a single
  # input, so mux both into one MPEG-TS stream with ffmpeg and pipe it to
  # ffplay. -fflags nobuffer / low delay flags on both ends keep latency low.
  FFMPEG_CMD=(ffmpeg
    -hide_banner -loglevel warning
    -fflags nobuffer -flags low_delay
    -f v4l2 -input_format "$INPUT_FORMAT" -video_size "$RES" -framerate "$FPS" -i "$DEV"
    -f pulse -i "$AUDIO_SRC"
    -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p
    -c:a aac -b:a 128k
    -f mpegts
    -flush_packets 1
    pipe:1
  )
  FFPLAY_CMD=(ffplay
    -fflags nobuffer
    -flags low_delay
    -framedrop
    -probesize 32
    -analyzeduration 0
    -sync video
    -window_title "HDMI Capture - $DEV"
    -i pipe:0
  )
  echo "Running: ${FFMPEG_CMD[*]} | ${FFPLAY_CMD[*]}"
  "${FFMPEG_CMD[@]}" | "${FFPLAY_CMD[@]}"
fi
