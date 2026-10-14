#!/usr/bin/env bash
# Keep trying to create the Always Free ARM server until Oracle has room ("Out of host capacity").
#
# Run in Oracle Cloud Shell (the >_ icon at the top of the console; free, already signed in):
#   curl -fsSL -o oracle-retry.sh <raw URL of this file> && bash oracle-retry.sh
#
# It tries VM.Standard.A1.Flex with 2 OCPU/12 GB, then 1/6, in every availability domain, waits WAIT seconds
# and starts over. Always Free covers 2 OCPU and 12 GB of A1 in total (cut from 4/24 in 2026), so it refuses
# anything bigger: on a Pay As You Go account a bigger server would be billed. Stop with Ctrl+C. Safe to run
# again: it stops at once if a server named $NAME already exists. On Pay As You Go, run oracle-guard.sh first.
#
# Settings (environment variables): NAME (vid2md), SHAPES ("2:12 1:6"), WAIT (90), DISK_GB (100).
set -uo pipefail

NAME="${NAME:-vid2md}"
SHAPES="${SHAPES:-2:12 1:6}"
WAIT="${WAIT:-90}"
DISK_GB="${DISK_GB:-100}"
C="${COMPARTMENT:-${OCI_TENANCY:-}}"
KEY="$HOME/.ssh/vid2md"

say() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
q() { oci "$@" 2>/dev/null; }

if [ -z "$C" ]; then
  echo "OCI_TENANCY 가 없습니다. Oracle Cloud Shell 에서 실행하세요." >&2
  exit 1
fi

# Never ask for more than Always Free: 2 OCPU / 12 GB of A1 and 200 GB of disk in total.
for shape in $SHAPES; do
  ocpus="${shape%%:*}"; mem="${shape##*:}"
  if ! [[ "$ocpus" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+$ ]] || [ "$ocpus" -lt 1 ] || [ "$ocpus" -gt 2 ] || [ "$mem" -gt 12 ]; then
    echo "무료 범위(2코어·12GB)를 넘는 크기는 쓰지 않습니다: $shape" >&2
    exit 1
  fi
done
if ! [[ "$DISK_GB" =~ ^[0-9]+$ ]] || [ "$DISK_GB" -lt 47 ] || [ "$DISK_GB" -gt 200 ]; then
  echo "디스크는 47~200GB 안에서 정하세요 (무료 합계 200GB): $DISK_GB" >&2
  exit 1
fi

# SSH key made here, so you can log in from this Cloud Shell: ssh -i ~/.ssh/vid2md ubuntu@<IP>
# RSA: Cloud Shell runs in FIPS mode, which refuses ed25519 keys.
if [ ! -f "$KEY.pub" ]; then
  mkdir -p "$HOME/.ssh"
  rm -f "$KEY"
  if ! ssh-keygen -t rsa -b 4096 -N "" -f "$KEY" -C vid2md >/dev/null 2>&1 || [ ! -f "$KEY.pub" ]; then
    echo "SSH 키를 만들지 못했습니다." >&2
    exit 1
  fi
  say "SSH 키를 만들었습니다: $KEY"
fi

show_ip() {
  local id="$1" ip
  ip=$(q compute instance list-vnics --instance-id "$id" --query 'data[0]."public-ip"' --raw-output)
  say "서버가 있습니다. 공인 IP: ${ip:-확인 중}"
  echo
  echo "접속:  ssh -i ~/.ssh/vid2md ubuntu@${ip}"
  echo "다음:  deploy/ORACLE.md 의 '작업 서버로 쓰기' 순서대로 진행하세요."
}

existing=$(q compute instance list -c "$C" --display-name "$NAME" \
  --query 'data[?"lifecycle-state"!=`TERMINATED`].id | [0]' --raw-output)
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  show_ip "$existing"
  exit 0
fi

mapfile -t ADS < <(q iam availability-domain list -c "$C" --query 'data[].name' --raw-output | jq -r '.[]')
if [ "${#ADS[@]}" -eq 0 ]; then
  echo "가용 도메인을 찾지 못했습니다." >&2
  exit 1
fi

IMAGE=$(q compute image list -c "$C" --operating-system "Canonical Ubuntu" --operating-system-version "24.04" \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output)
if [ -z "$IMAGE" ] || [ "$IMAGE" = "null" ]; then
  echo "Ubuntu 24.04 ARM 이미지를 찾지 못했습니다." >&2
  exit 1
fi

# A public subnet: reuse one (e.g. from an earlier attempt), or make a small network for the server.
SUBNET=$(q network subnet list -c "$C" --query 'data[?"prohibit-public-ip-on-vnic"==`false`].id | [0]' --raw-output)
if [ -z "$SUBNET" ] || [ "$SUBNET" = "null" ]; then
  say "네트워크를 만듭니다 (한 번만)"
  VCN=$(oci network vcn create -c "$C" --cidr-block 10.0.0.0/16 --display-name "$NAME-vcn" --dns-label "${NAME//[^a-z0-9]/}" \
    --wait-for-state AVAILABLE --query data.id --raw-output) || exit 1
  IGW=$(oci network internet-gateway create -c "$C" --vcn-id "$VCN" --is-enabled true --display-name "$NAME-igw" \
    --wait-for-state AVAILABLE --query data.id --raw-output) || exit 1
  RT=$(oci network vcn get --vcn-id "$VCN" --query 'data."default-route-table-id"' --raw-output) || exit 1
  oci network route-table update --rt-id "$RT" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW\"}]" >/dev/null || exit 1
  SUBNET=$(oci network subnet create -c "$C" --vcn-id "$VCN" --cidr-block 10.0.0.0/24 --display-name "$NAME-subnet" \
    --dns-label sub --wait-for-state AVAILABLE --query data.id --raw-output) || exit 1
fi

say "시도 순서: ${SHAPES} (OCPU:GB) × 가용 도메인 ${#ADS[@]}개, 실패하면 ${WAIT}초 뒤 다시"
round=0
while true; do
  round=$((round + 1))
  for shape in $SHAPES; do
    ocpus="${shape%%:*}"; mem="${shape##*:}"
    for ad in "${ADS[@]}"; do
      out=$(oci compute instance launch -c "$C" --availability-domain "$ad" --display-name "$NAME" \
        --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\":$ocpus,\"memoryInGBs\":$mem}" \
        --image-id "$IMAGE" --subnet-id "$SUBNET" --assign-public-ip true \
        --boot-volume-size-in-gbs "$DISK_GB" --ssh-authorized-keys-file "$KEY.pub" \
        --wait-for-state RUNNING --max-wait-seconds 600 --query data.id --raw-output 2>&1)
      if [ $? -eq 0 ] && [[ "$out" == ocid1.instance* ]]; then
        say "성공: ${ocpus} OCPU / ${mem} GB  (${ad##*:})"
        show_ip "$out"
        exit 0
      fi
      if grep -qiE "out of (host )?capacity|InternalError|TooManyRequests|429" <<<"$out"; then
        say "#${round} ${ocpus}/${mem} ${ad##*:}: 자리 없음"
      elif grep -qiE "LimitExceeded|QuotaExceeded|limit" <<<"$out"; then
        say "#${round} ${ocpus}/${mem} ${ad##*:}: 무료 한도 초과 — 더 작은 크기로 넘어갑니다"
        break
      else
        say "예상하지 못한 오류로 멈춥니다:"
        echo "$out" | head -20
        exit 1
      fi
    done
  done
  sleep "$WAIT"
done
