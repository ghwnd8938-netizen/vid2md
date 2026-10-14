#!/usr/bin/env bash
# Lock an Oracle Cloud account to the Always Free sizes before (or after) upgrading it to Pay As You Go.
#
# Run in Oracle Cloud Shell:
#   curl -fsSL -o oracle-guard.sh <raw URL of this file> && bash oracle-guard.sh
#
# 1. A quota policy (hard limit, Oracle refuses anything above it):
#      - compute: only Ampere A1, at most 2 OCPU and 12 GB in total; every other shape (GPU, AMD, Intel) is 0
#      - block/boot volumes: at most 200 GB in total, at most 5 backups
#    Within a policy, later statements win, so "zero ... quotas" followed by "set" is an allowlist.
#    A1 quotas count per availability domain. No "where request.ad" condition: Oracle's docs show two
#    different spellings for it, and a condition that does not match leaves A1 at 0 (seen in Tokyo).
#    In a region with several domains this allows 2/12 in each; oracle-retry.sh still makes only one server.
# 2. A monthly budget of 1 (in the account's currency) that e-mails you as soon as anything is charged,
#    and when the forecast says something will be. This is only a warning; the quota is the real limit.
#
# Safe to run again: it updates the quota and keeps an existing budget. Settings: EMAIL (asked if empty).
set -uo pipefail

NAME="vid2md-free-only"
C="${OCI_TENANCY:-}"
EMAIL="${EMAIL:-}"

say() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
q() { oci "$@" 2>/dev/null; }

if [ -z "$C" ]; then
  echo "OCI_TENANCY 가 없습니다. Oracle Cloud Shell 에서 실행하세요." >&2
  exit 1
fi

ADS=$(q iam availability-domain list -c "$C" --query 'length(data)' --raw-output)
if [ "${ADS:-1}" != "1" ]; then
  echo "참고: 가용 도메인이 ${ADS}개라 도메인마다 2코어/12GB까지 허용됩니다. 콘솔에서 서버를 따로 만들지 마세요."
fi

STATEMENTS=$(jq -nc '[
  "zero compute-core quotas in tenancy",
  "set compute-core quota standard-a1-core-count to 2 in tenancy",
  "zero compute-memory quotas in tenancy",
  "set compute-memory quota standard-a1-memory-count to 12 in tenancy",
  "set block-storage quota total-storage-gb to 200 in tenancy",
  "set block-storage quota backup-count to 5 in tenancy"
]')
DESC="Always Free only: A1 2 OCPU/12 GB, 200 GB volumes (vid2md)"

QUOTA=$(q limits quota list -c "$C" --name "$NAME" --query 'data[0].id' --raw-output)
if [ -n "$QUOTA" ] && [ "$QUOTA" != "null" ]; then
  oci limits quota update --quota-id "$QUOTA" --statements "$STATEMENTS" --description "$DESC" --force >/dev/null || exit 1
  say "한도 정책을 다시 적용했습니다: $NAME"
else
  oci limits quota create -c "$C" --name "$NAME" --description "$DESC" --statements "$STATEMENTS" >/dev/null || exit 1
  say "한도 정책을 만들었습니다: $NAME"
fi
echo "  - 서버: Ampere A1 만, 합계 2코어 / 12GB 까지 (그 밖의 서버 종류는 0)"
echo "  - 디스크: 합계 200GB, 백업 5개까지"

BUDGET=$(q budgets budget budget list -c "$C" --display-name "$NAME" --query 'data[0].id' --raw-output)
if [ -n "$BUDGET" ] && [ "$BUDGET" != "null" ]; then
  say "요금 알림은 이미 있습니다."
  exit 0
fi
if [ -z "$EMAIL" ]; then
  read -rp "요금 알림을 받을 이메일: " EMAIL
fi
if [ -z "$EMAIL" ]; then
  say "이메일이 없어 요금 알림은 건너뜁니다. 한도 정책은 적용되었습니다."
  exit 0
fi
BUDGET=$(oci budgets budget budget create -c "$C" --display-name "$NAME" --amount 1 --reset-period MONTHLY \
  --target-type COMPARTMENT --targets "[\"$C\"]" --description "Any charge at all means something is outside Always Free" \
  --query data.id --raw-output) || exit 1
for type in ACTUAL FORECAST; do
  oci budgets budget alert-rule create --budget-id "$BUDGET" --type "$type" --threshold 1 --threshold-type PERCENTAGE \
    --recipients "$EMAIL" --display-name "$NAME-$type" \
    --message "Oracle Cloud: a charge appeared or is forecast ($type). Check Billing > Cost Analysis and remove the paid resource." >/dev/null || exit 1
done
say "요금 알림을 만들었습니다: 요금이 조금이라도 생기거나 생길 것으로 예상되면 $EMAIL 로 메일이 갑니다."
