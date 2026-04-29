#!/usr/bin/env bash
set -euo pipefail

cd "$GITHUB_WORKSPACE/SimDeck"
export UDID="${SIMDECK_DEBUG_UDID:-}"
export RUST_BACKTRACE=1
export SIMDECK_LOG=debug

echo "== system =="
date
uname -a
sw_vers
xcodebuild -version
xcode-select -p

echo "== simulator =="
echo "UDID=$UDID"
xcrun simctl list devices "$UDID" || true
xcrun simctl io "$UDID" screenshot /tmp/simdeck-command-screen.png || true
ls -lh /tmp/simdeck-command-screen.png || true

if [[ ! -x build/simdeck ]]; then
  echo "== build simdeck cli =="
  ./scripts/build-cli.sh
fi
mkdir -p /tmp/simdeck-empty-client

if [[ -n "$UDID" ]]; then
  echo "== direct screenshot via simdeck =="
  ./build/simdeck screenshot "$UDID" --output /tmp/simdeck-cli-screen.png || true
  ls -lh /tmp/simdeck-cli-screen.png || true
fi

echo "== start simdeck server =="
pkill -f 'simdeck serve' || true
./build/simdeck serve \
  --port 4310 \
  --bind 127.0.0.1 \
  --access-token debug-token \
  --client-root /tmp/simdeck-empty-client \
  --video-codec h264-software \
  > /tmp/simdeck-server.log 2>&1 &
server_pid=$!
echo "server_pid=$server_pid"

for i in {1..120}; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "server exited before health"
    cat /tmp/simdeck-server.log || true
    exit 1
  fi
  if curl -fsS http://127.0.0.1:4310/api/health; then
    echo
    break
  fi
  sleep 1
done

echo "== list simulators before stream attach =="
curl -fsS -H 'x-simdeck-token: debug-token' http://127.0.0.1:4310/api/simulators || true
echo

if [[ -n "$UDID" ]]; then
  echo "== trigger WebRTC attach with invalid offer to force display session creation =="
  curl -i -sS \
    -H 'content-type: application/json' \
    -H 'x-simdeck-token: debug-token' \
    -d '{"type":"offer","sdp":"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"}' \
    "http://127.0.0.1:4310/api/simulators/$UDID/webrtc/answer" || true
  echo
fi

sleep 3

echo "== list simulators after attach =="
curl -fsS -H 'x-simdeck-token: debug-token' http://127.0.0.1:4310/api/simulators || true
echo

echo "== server log tail =="
tail -240 /tmp/simdeck-server.log || true
