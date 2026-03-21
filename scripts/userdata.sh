#!/usr/bin/env bash
# OOD portal launch-time bootstrap for Amazon Linux 2023 on EC2.
# Handles environment-specific configuration only; static software installs
# are pre-baked into the AMI via scripts/bake.sh (Packer).
# When using the base AL2023 AMI (enable_packer_ami=false), bake.sh is
# prepended to this script by the Terraform launcher.
set -euo pipefail

# Create and lock down the log file before redirecting output.
touch /var/log/ood-bootstrap.log
chmod 600 /var/log/ood-bootstrap.log
exec > >(tee -a /var/log/ood-bootstrap.log) 2>&1

echo "=== OOD bootstrap started at $(date) ==="

###############################################################################
# IMDSv2 token-based metadata retrieval
###############################################################################
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 1800") # L2: 1800s covers full bootstrap including slow EFS/FSx mounts
imds_get() {
  curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "http://169.254.169.254/latest/meta-data/$1"
}
AWS_REGION=$(imds_get placement/region)
INSTANCE_ID=$(imds_get instance-id)

echo "Region    : ${AWS_REGION}"
echo "Instance  : ${INSTANCE_ID}"

###############################################################################
# 0. Pull config from SSM Parameter Store (if enabled)
###############################################################################
if [ "${OOD_ENABLE_PARAMETER_STORE}" = "true" ]; then
  echo "=== Sourcing config from SSM /ood/${OOD_ENVIRONMENT}/ ==="
  SSM_PATH="/ood/${OOD_ENVIRONMENT}"

  if aws ssm get-parameters-by-path \
        --region "${AWS_REGION}" \
        --path "${SSM_PATH}" \
        --with-decryption \
        --query 'Parameters[*].[Name,Value]' \
        --output text 2>/dev/null | \
      while IFS=$'\t' read -r name value; do
          key="${name##*/}"
          case "${key}" in
              domain_name)           OOD_DOMAIN="${value}" ;;
              efs_id)                OOD_EFS_ID="${value}" ;;
              efs_access_point_id)   OOD_EFS_ACCESS_POINT_ID="${value}" ;;
              dynamodb_uid_table)    OOD_DYNAMODB_UID_TABLE="${value}" ;;
              oidc_client_id)         OOD_OIDC_CLIENT_ID="${value}" ;;
              oidc_client_secret_arn) OOD_OIDC_CLIENT_SECRET_ARN="${value}" ;; # H2: ARN pointer only
              oidc_issuer_url)        OOD_OIDC_ISSUER_URL="${value}" ;;
              redis_endpoint)        OOD_REDIS_ENDPOINT="${value}" ;;
          esac
      done; then
    echo "=== SSM parameters loaded ==="
  else
    echo "WARNING: SSM parameter load failed — using Terraform-injected defaults"
  fi
fi

# Fallback defaults for SSM-sourced vars
OOD_DYNAMODB_UID_TABLE="${OOD_DYNAMODB_UID_TABLE:-}"
OOD_OIDC_CLIENT_ID="${OOD_OIDC_CLIENT_ID:-}"
OOD_OIDC_CLIENT_SECRET_ARN="${OOD_OIDC_CLIENT_SECRET_ARN:-}"
OOD_OIDC_ISSUER_URL="${OOD_OIDC_ISSUER_URL:-}"

# Fetch OIDC client secret from Secrets Manager (never stored in SSM or userdata) (H2)
OOD_OIDC_CLIENT_SECRET=""
if [ -n "${OOD_OIDC_CLIENT_SECRET_ARN}" ]; then
  # L3: capture stderr so AccessDeniedException and other errors are visible in bootstrap log
  SM_ERROR_LOG=$(mktemp)
  # L1: ensure temp file is removed even if the script exits unexpectedly (signal, set -e, etc.)
  trap 'rm -f "${SM_ERROR_LOG}"' EXIT
  OOD_OIDC_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "${OOD_OIDC_CLIENT_SECRET_ARN}" \
    --query 'SecretString' \
    --output text 2>"${SM_ERROR_LOG}" || echo "")
  if [ -z "${OOD_OIDC_CLIENT_SECRET}" ]; then
    # L3: OIDC secret is required for portal authentication — abort if retrieval fails.
    # A missing secret would launch a portal that silently rejects all logins.
    echo "FATAL: Failed to retrieve OIDC client secret from Secrets Manager"
    echo "  Secret ARN: ${OOD_OIDC_CLIENT_SECRET_ARN}"
    echo "  AWS error: $(cat "${SM_ERROR_LOG}")"
    echo "  Check: IAM role has secretsmanager:GetSecretValue on this ARN"
    rm -f "${SM_ERROR_LOG}"
    exit 1
  else
    echo "=== OIDC client secret retrieved from Secrets Manager ==="
  fi
  rm -f "${SM_ERROR_LOG}"
fi
OOD_REDIS_ENDPOINT="${OOD_REDIS_ENDPOINT:-}"

###############################################################################
# 1. Mount EFS /home (with TLS + IAM)
###############################################################################
if [ "${OOD_ENABLE_EFS}" = "true" ] && [ -n "${OOD_EFS_ID}" ]; then
  echo "=== Mounting EFS ${OOD_EFS_ID} at /home ==="

  # amazon-efs-utils + botocore (needed for IAM auth IP fallback)
  if ! command -v mount.efs &>/dev/null; then
    dnf install -y amazon-efs-utils python3-botocore
  elif ! python3 -c "import botocore" &>/dev/null; then
    dnf install -y python3-botocore
  fi

  mkdir -p /home
  if ! mountpoint -q /home; then
    # Retry up to 5 times — mount target DNS takes ~60-120s after creation
    for attempt in 1 2 3 4 5; do
      if mount -t efs -o tls,iam,accesspoint="${OOD_EFS_ACCESS_POINT_ID}" \
           "${OOD_EFS_ID}":/ /home; then
        echo "${OOD_EFS_ID}:/ /home efs _netdev,tls,iam,accesspoint=${OOD_EFS_ACCESS_POINT_ID} 0 0" >> /etc/fstab
        break
      fi
      echo "EFS mount attempt ${attempt}/5 failed — waiting 30s"
      sleep 30
    done
    mountpoint -q /home || { echo "ERROR: EFS mount failed after 5 attempts"; exit 1; }
  fi
  echo "=== EFS /home mounted ==="
fi

###############################################################################
# 2. Mount FSx Lustre /scratch (if enabled)
###############################################################################
if [ "${OOD_ENABLE_FSX}" = "true" ] && [ -n "${OOD_FSX_DNS_NAME}" ]; then
  echo "=== Mounting FSx Lustre at /scratch ==="
  dnf install -y lustre-client

  mkdir -p /scratch
  if ! mountpoint -q /scratch; then
    mount -t lustre -o relatime,flock \
      "${OOD_FSX_DNS_NAME}@tcp:/${OOD_FSX_MOUNT_NAME}" /scratch
    echo "${OOD_FSX_DNS_NAME}@tcp:/${OOD_FSX_MOUNT_NAME} /scratch lustre defaults,relatime,flock,_netdev 0 0" >> /etc/fstab
  fi
  echo "=== FSx /scratch mounted ==="
fi

###############################################################################
# 3. Configure oidc-auth-broker (reads from /etc/oidc-auth/broker.yaml)
###############################################################################
if [ -n "${OOD_OIDC_CLIENT_ID}" ] && [ -n "${OOD_OIDC_ISSUER_URL}" ]; then
  echo "=== Configuring oidc-auth-broker ==="

  cat > /etc/oidc-auth/broker.yaml <<BROKERCONF
issuer: "${OOD_OIDC_ISSUER_URL}"
client_id: "${OOD_OIDC_CLIENT_ID}"
client_secret: "${OOD_OIDC_CLIENT_SECRET}"
dynamodb_table: "${OOD_DYNAMODB_UID_TABLE}"
aws_region: "${AWS_REGION}"
uid_range_min: 10000
uid_range_max: 60000
home_dir_prefix: /home
BROKERCONF
  chmod 600 /etc/oidc-auth/broker.yaml

  # Configure NSS to use oidc-pam for user lookups
  if ! grep -q "oidc" /etc/nsswitch.conf; then
    sed -i 's/^passwd:\(.*\)/passwd:\1 oidc/' /etc/nsswitch.conf
    sed -i 's/^group:\(.*\)/group:\1 oidc/' /etc/nsswitch.conf
    sed -i 's/^shadow:\(.*\)/shadow:\1 oidc/' /etc/nsswitch.conf
  fi

  # Configure PAM for OOD authentication
  cat > /etc/pam.d/ood <<'PAMCONF'
auth     required pam_oidc.so
account  required pam_oidc.so
session  optional pam_oidc.so
PAMCONF

  # Enable and start the oidc-auth-broker service
  cat > /etc/systemd/system/oidc-auth-broker.service <<'SVCCONF'
[Unit]
Description=OIDC Auth Broker for oidc-pam
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/oidc-auth-broker serve --config /etc/oidc-auth/broker.yaml
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SVCCONF

  systemctl daemon-reload
  systemctl enable oidc-auth-broker
  systemctl start oidc-auth-broker
  echo "=== oidc-auth-broker started ==="
fi

###############################################################################
# 4. Generate OOD portal config from SSM parameters
###############################################################################
if [ -n "${OOD_DOMAIN}" ]; then
  echo "=== Generating ood_portal.yml ==="

  cat > /etc/ood/config/ood_portal.yml <<OODPORTAL
---
servername: "${OOD_DOMAIN}"
oidc_uri: /oidc
oidc_discover_uri: /oidc/.well-known/openid-configuration
oidc_discover_root: /var/www/ood/discover
oidc_provider_metadata_url: "${OOD_OIDC_ISSUER_URL}/.well-known/openid-configuration"
oidc_client_id: "${OOD_OIDC_CLIENT_ID}"
oidc_client_secret: "${OOD_OIDC_CLIENT_SECRET}"
oidc_remote_user_claim: "preferred_username"
oidc_scope: "openid email profile"
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
user_map_cmd: "/usr/local/bin/oidc-pam map-user"
OODPORTAL

  # Regenerate OOD Apache config from the portal YAML
  if command -v /opt/ood/ood-portal-generator/sbin/update_ood_portal &>/dev/null; then
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
  fi
fi

###############################################################################
# 5. Generate cluster YAML files for each enabled adapter
###############################################################################
ADAPTERS_JSON="${OOD_ADAPTERS_ENABLED}"

# Batch adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('batch' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring Batch cluster ==="
  BATCH_QUEUE=$(aws batch describe-job-queues \
    --region "${AWS_REGION}" \
    --query "jobQueues[?contains(jobQueueName, 'ood-${OOD_ENVIRONMENT}')].jobQueueArn" \
    --output text 2>/dev/null || echo "")

  cat > /etc/ood/config/clusters.d/aws-batch.yml <<BATCHCONF
---
v2:
  metadata:
    title: "AWS Batch"
    hidden: false
  login:
    host: "localhost"
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-aws-batch-adapter"
      args:
        - submit
        - "--queue=${BATCH_QUEUE}"
        - "--region=${AWS_REGION}"
BATCHCONF
fi

# SageMaker adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('sagemaker' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring SageMaker cluster ==="
  SM_DOMAIN_ID=$(aws sagemaker list-domains \
    --region "${AWS_REGION}" \
    --query "Domains[?contains(DomainName, 'ood-${OOD_ENVIRONMENT}')].DomainId" \
    --output text 2>/dev/null || echo "")

  cat > /etc/ood/config/clusters.d/aws-sagemaker.yml <<SMCONF
---
v2:
  metadata:
    title: "AWS SageMaker Studio"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-sagemaker-adapter"
      args:
        - launch
        - "--domain-id=${SM_DOMAIN_ID}"
        - "--region=${AWS_REGION}"
SMCONF
fi

# EC2 adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('ec2' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring EC2 adapter cluster ==="
  cat > /etc/ood/config/clusters.d/aws-ec2.yml <<EC2CONF
---
v2:
  metadata:
    title: "AWS EC2 Compute"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-ec2-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
EC2CONF
fi

###############################################################################
# 6. Configure PUN session cache (ElastiCache Redis, Level 5)
###############################################################################
if [ "${OOD_ENABLE_SESSION_CACHE}" = "true" ] && [ -n "${OOD_REDIS_ENDPOINT}" ]; then
  echo "=== Configuring Redis session cache ==="
  mkdir -p /etc/ood/config
  cat >> /etc/ood/config/nginx_stage.yml <<NGINX_STAGE
# PUN session tokens stored in Redis for Spot-transparency
pun_custom_env:
  OOD_REDIS_URI: "${OOD_REDIS_ENDPOINT}"
NGINX_STAGE
fi

###############################################################################
# 7. Configure S3 browser app (Level 6)
###############################################################################
if [ "${OOD_ENABLE_S3_BROWSER}" = "true" ] && [ -n "${OOD_S3_BROWSER_BUCKET}" ]; then
  echo "=== Configuring S3 browser ==="
  mkdir -p /etc/ood/config/apps/files
  cat > /etc/ood/config/apps/files/env <<S3ENV
OOD_DATAROOT=/var/www/ood/apps/sys/files
S3_BUCKET=${OOD_S3_BROWSER_BUCKET}
AWS_DEFAULT_REGION=${AWS_REGION}
S3ENV
fi

###############################################################################
# 8. Start / reload services
###############################################################################
systemctl start oidc-auth-broker 2>/dev/null || true

# OOD 4.x on AL2023 uses httpd.service with drop-in configs from the ondemand package
systemctl enable --now httpd || true

fail2ban-client start 2>/dev/null || systemctl start fail2ban || true

###############################################################################
# 9. CloudWatch Agent (binary pre-installed by bake.sh)
###############################################################################
if [ "${OOD_ENABLE_MONITORING}" = "true" ]; then
  echo "=== Configuring CloudWatch Agent ==="

  cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<CWCONF
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root"
  },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "InstanceId": "\${aws:InstanceId}"
    },
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": {
        "measurement": ["disk_used_percent"],
        "resources": ["/", "/home", "/scratch"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/ood-bootstrap.log",
            "log_group_name": "${OOD_LOG_GROUP_PREFIX}/bootstrap",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/access.log",
            "log_group_name": "${OOD_LOG_GROUP_PREFIX}/nginx-access",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "${OOD_LOG_GROUP_PREFIX}/nginx-error",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/ood/passenger.log",
            "log_group_name": "${OOD_LOG_GROUP_PREFIX}/passenger",
            "log_stream_name": "\${aws:InstanceId}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWCONF

  amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s
  echo "=== CloudWatch Agent started ==="
fi

echo "=== OOD bootstrap completed at $(date) ==="
