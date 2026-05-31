#!/usr/bin/env bash
# ood-provision-user.sh — create the local Unix account for an authenticated OIDC user.
#
# Run by pam_exec from /etc/pam.d/ood at session time. oidc-pam v0.3.x is PAM-only and
# does NOT create local accounts (see scttfrdmn/oidc-pam#87 / DEPLOYMENT.md): it
# authenticates an OIDC identity for an account that must already exist. This script is
# OOD's account-materialization step — it allocates a stable UID from the DynamoDB UID
# map and creates the account so the home (EFS-backed /home) and PUN can come up.
#
# Identity: pam_exec passes PAM_USER, which OOD sets from oidc_remote_user_claim
# (cognito:username — see #64). The DynamoDB table is keyed on `username` because that is
# the only identity available at this hook.
#
# Idempotent and fail-soft: if anything goes wrong we log and exit 0 so we never block a
# session for a user that already exists; a genuinely missing account simply won't have a
# home and OOD will surface that.
set -uo pipefail

PAM_USER="${PAM_USER:-}"
LOG="/var/log/ood-provision-user.log"
log() { echo "$(date -u +%FT%TZ) ood-provision-user: $*" >>"${LOG}" 2>/dev/null || true; }

# Reserved/sentinel and obvious non-users are ignored.
case "${PAM_USER}" in
  "" | root | __uid_counter__) exit 0 ;;
esac

# Fast path: account already exists → nothing to do.
if getent passwd "${PAM_USER}" >/dev/null 2>&1; then
  exit 0
fi

# Resolve config. pam_exec runs with a minimal environment, so read the table/region from
# the env file userdata.sh wrote; fall back to any inherited vars, then IMDS for region.
if [ -r /etc/oidc-auth/provision.env ]; then
  # shellcheck disable=SC1091
  . /etc/oidc-auth/provision.env
fi
TABLE="${OOD_DYNAMODB_UID_TABLE:-}"
REGION="${AWS_REGION:-}"
if [ -z "${REGION}" ]; then
  _tok=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
  REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${_tok}" \
    "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null)
fi

if [ -z "${TABLE}" ] || [ -z "${REGION}" ]; then
  log "no UID table/region configured (enable_dynamodb_uid?) — skipping provisioning for ${PAM_USER}"
  exit 0
fi

UID_MIN=10000
UID_MAX=60000

# Look up an existing username->uid mapping.
get_uid() {
  aws dynamodb get-item --region "${REGION}" --table-name "${TABLE}" \
    --key "{\"username\":{\"S\":\"$1\"}}" --consistent-read \
    --query 'Item.uid.N' --output text 2>>"${LOG}"
}

assigned_uid=$(get_uid "${PAM_USER}")

if [ -z "${assigned_uid}" ] || [ "${assigned_uid}" = "None" ]; then
  # Allocate the next UID atomically from the counter sentinel, then claim the row with a
  # conditional put. If the put loses a race, another node already created it — re-read.
  next=$(aws dynamodb update-item --region "${REGION}" --table-name "${TABLE}" \
    --key '{"username":{"S":"__uid_counter__"}}' \
    --update-expression 'ADD next_uid :one' \
    --expression-attribute-values "{\":one\":{\"N\":\"1\"}}" \
    --return-values UPDATED_NEW --query 'Attributes.next_uid.N' --output text 2>>"${LOG}")

  if [ -z "${next}" ] || [ "${next}" = "None" ]; then
    log "ERROR: counter allocation failed for ${PAM_USER}"
    exit 0
  fi
  candidate=$((UID_MIN + next - 1))
  if [ "${candidate}" -gt "${UID_MAX}" ]; then
    log "ERROR: UID pool exhausted (candidate ${candidate} > ${UID_MAX}) for ${PAM_USER}"
    exit 0
  fi

  if aws dynamodb put-item --region "${REGION}" --table-name "${TABLE}" \
      --item "{\"username\":{\"S\":\"${PAM_USER}\"},\"uid\":{\"N\":\"${candidate}\"}}" \
      --condition-expression 'attribute_not_exists(username)' >>"${LOG}" 2>&1; then
    assigned_uid="${candidate}"
    log "allocated uid ${assigned_uid} for ${PAM_USER}"
  else
    # Lost the race — the row now exists; read it back.
    assigned_uid=$(get_uid "${PAM_USER}")
    log "race on ${PAM_USER}; using existing uid ${assigned_uid}"
  fi
fi

if [ -z "${assigned_uid}" ] || [ "${assigned_uid}" = "None" ]; then
  log "ERROR: could not determine uid for ${PAM_USER}"
  exit 0
fi

# Create the account. A shared primary group keeps file sharing on EFS simple; pam_mkhomedir
# (next in the PAM stack) creates the home directory itself.
getent group ood-users >/dev/null 2>&1 || groupadd --system ood-users 2>>"${LOG}"
if useradd --uid "${assigned_uid}" --gid ood-users \
    --home-dir "/home/${PAM_USER}" --no-create-home --shell /bin/bash \
    "${PAM_USER}" >>"${LOG}" 2>&1; then
  log "created account ${PAM_USER} (uid=${assigned_uid})"
else
  log "WARNING: useradd for ${PAM_USER} (uid=${assigned_uid}) returned non-zero (may already exist)"
fi

exit 0
