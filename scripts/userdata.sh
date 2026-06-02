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

  # Fetch to a temp file first, then loop with process substitution. A
  # `aws ... | while read` pipe runs the loop body in a SUBSHELL, so every OOD_*
  # assignment would be discarded on subshell exit and the OIDC broker block below
  # would never run (#24). Reading via `< <(...)` keeps the loop in this shell.
  SSM_DUMP=$(mktemp)
  if aws ssm get-parameters-by-path \
        --region "${AWS_REGION}" \
        --path "${SSM_PATH}" \
        --with-decryption \
        --query 'Parameters[*].[Name,Value]' \
        --output text >"${SSM_DUMP}" 2>/dev/null; then
    while IFS=$'\t' read -r name value; do
      key="${name##*/}"
      case "${key}" in
        domain_name) OOD_DOMAIN="${value}" ;;
        efs_id) OOD_EFS_ID="${value}" ;;
        efs_access_point_id) OOD_EFS_ACCESS_POINT_ID="${value}" ;;
        redis_endpoint) OOD_REDIS_ENDPOINT="${value}" ;;
        # #78: directory coordinates for SSSD (POSIX) + the Dex LDAP connector (web auth).
        directory_name) OOD_DIRECTORY_NAME="${value}" ;;
        directory_dns_ips) OOD_DIRECTORY_DNS_IPS="${value}" ;;
        directory_ldap_uri) OOD_DIRECTORY_LDAP_URI="${value}" ;;
        directory_bind_dn) OOD_DIRECTORY_BIND_DN="${value}" ;;
        directory_user_base_dn) OOD_DIRECTORY_USER_BASE_DN="${value}" ;;
        directory_user_filter) OOD_DIRECTORY_USER_FILTER="${value}" ;;
        directory_username_attr) OOD_DIRECTORY_USERNAME_ATTR="${value}" ;;
      esac
    done <"${SSM_DUMP}"
    echo "=== SSM parameters loaded ==="
  else
    echo "WARNING: SSM parameter load failed — using Terraform-injected defaults"
  fi
  rm -f "${SSM_DUMP}"
fi

# Fallback defaults for SSM-sourced vars
OOD_DIRECTORY_NAME="${OOD_DIRECTORY_NAME:-}"
OOD_DIRECTORY_DNS_IPS="${OOD_DIRECTORY_DNS_IPS:-}"
OOD_DIRECTORY_LDAP_URI="${OOD_DIRECTORY_LDAP_URI:-}"
OOD_DIRECTORY_BIND_DN="${OOD_DIRECTORY_BIND_DN:-}"
OOD_DIRECTORY_USER_BASE_DN="${OOD_DIRECTORY_USER_BASE_DN:-}"
OOD_DIRECTORY_USER_FILTER="${OOD_DIRECTORY_USER_FILTER:-}"
OOD_DIRECTORY_USERNAME_ATTR="${OOD_DIRECTORY_USERNAME_ATTR:-}"
OOD_USE_SSSD="${OOD_USE_SSSD:-false}"

# #78: fetch the directory BIND password from Secrets Manager (never in SSM/user_data). The
# Dex LDAP connector binds with it to search the directory. Eval mode auto-fills the secret
# from the Simple AD admin password; BYO deployments have the operator populate it.
OOD_DIRECTORY_BIND_PW=""
if [ "${OOD_USE_SSSD}" = "true" ]; then
  SM_ERROR_LOG=$(mktemp)
  trap 'rm -f "${SM_ERROR_LOG}"' EXIT
  OOD_DIRECTORY_BIND_PW=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "ood/${OOD_ENVIRONMENT}/directory-bind-password" \
    --query 'SecretString' --output text 2>"${SM_ERROR_LOG}" || echo "")
  if [ -z "${OOD_DIRECTORY_BIND_PW}" ]; then
    echo "FATAL: could not fetch directory bind password (#78) — Dex cannot bind LDAP, web login will fail."
    echo "  Secret: ood/${OOD_ENVIRONMENT}/directory-bind-password"
    echo "  AWS error: $(cat "${SM_ERROR_LOG}")"
    echo "  Check the instance role has secretsmanager:GetSecretValue on that secret, and that it is populated."
    rm -f "${SM_ERROR_LOG}"
    exit 1
  fi
  echo "=== directory bind password retrieved from Secrets Manager ==="
  rm -f "${SM_ERROR_LOG}"
fi
OOD_REDIS_ENDPOINT="${OOD_REDIS_ENDPOINT:-}"

###############################################################################
# #78: POSIX identity via SSSD/NSS against AWS Directory Service (or any AD/LDAP)
#
# Replaces the bespoke login-time-useradd path (#39->#77, which can't work: nginx_stage's
# getpwnam runs before any provisioning hook). With SSSD joined to the directory, getpwnam
# resolves users directory-side and oddjob-mkhomedir creates their home on first login — no
# account creation at request time. Gated on use_sssd; coexists with the legacy oidc-pam path
# until the cutover (#78-5). Idempotent: re-running re-joins only if not already joined.
###############################################################################
if [ "${OOD_USE_SSSD}" = "true" ] && [ -n "${OOD_DIRECTORY_NAME}" ]; then
  echo "=== Configuring SSSD against directory ${OOD_DIRECTORY_NAME} ==="

  # Point DNS at the directory's resolvers so the AD domain + SRV records resolve. AWS
  # Directory Service publishes two DNS IPs (from the directory_dns_ips SSM StringList).
  if [ -n "${OOD_DIRECTORY_DNS_IPS}" ]; then
    {
      echo "[main]"
      echo "dns=none"
    } > /etc/NetworkManager/conf.d/dns-none.conf 2>/dev/null || true
    : > /etc/resolv.conf
    for _ip in ${OOD_DIRECTORY_DNS_IPS//,/ }; do
      echo "nameserver ${_ip}" >> /etc/resolv.conf
    done
    echo "search ${OOD_DIRECTORY_NAME}" >> /etc/resolv.conf
  fi

  # Fetch the directory admin password from Secrets Manager (never in user_data) for the join.
  DIR_ADMIN_PW=$(aws secretsmanager get-secret-value \
    --region "${AWS_REGION}" \
    --secret-id "ood/${OOD_ENVIRONMENT}/directory-admin-password" \
    --query 'SecretString' --output text 2>/dev/null || echo "")

  if [ -z "${DIR_ADMIN_PW}" ]; then
    echo "ERROR: could not fetch directory admin password (#78) — SSSD join skipped; getpwnam will fail and the PUN won't start. Check the instance role has secretsmanager:GetSecretValue on ood/${OOD_ENVIRONMENT}/directory-admin-password."
  else
    # Join the realm if not already joined (idempotent across reboots / ASG replacement).
    if ! realm list 2>/dev/null | grep -qi "${OOD_DIRECTORY_NAME}"; then
      echo "${DIR_ADMIN_PW}" | realm join --user=Admin "${OOD_DIRECTORY_NAME}" 2>&1 \
        && echo "=== realm join succeeded ===" \
        || echo "ERROR: realm join failed (#78) — check directory reachability + admin creds."
    else
      echo "=== already joined to ${OOD_DIRECTORY_NAME} ==="
    fi
    unset DIR_ADMIN_PW

    # Enable the SSSD nsswitch profile and auto-home-creation. authselect rewrites
    # /etc/nsswitch.conf + /etc/pam.d to resolve users via SSSD and run pam_oddjob_mkhomedir.
    authselect select sssd with-mkhomedir --force 2>&1 || \
      echo "WARNING: authselect select sssd failed (#78)"

    # fully-qualified-names off so 'demo' works (not 'demo@domain'); homes under /home.
    if [ -f /etc/sssd/sssd.conf ]; then
      sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf 2>/dev/null || true
      grep -q '^use_fully_qualified_names' /etc/sssd/sssd.conf || \
        sed -i "/^\[domain\//a use_fully_qualified_names = False\nfallback_homedir = /home/%u\ndefault_shell = /bin/bash\nldap_id_mapping = True" /etc/sssd/sssd.conf 2>/dev/null || true
    fi

    systemctl enable --now oddjobd 2>/dev/null || true
    systemctl restart sssd 2>/dev/null || systemctl enable --now sssd 2>/dev/null || true

    # Assert getpwnam resolves a directory user (best-effort; warns, doesn't block boot).
    echo "=== SSSD configured; 'id' resolution now directory-backed (no login-time useradd) ==="
  fi
fi

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
# 3 + 4. Web auth: OOD Dex with an LDAP connector → the directory (#78)
###############################################################################
# Replaces the bespoke Cognito + oidc-auth-broker + hand-wired mod_auth_openidc stack. OOD's
# bundled Dex authenticates users via an LDAP connector bound to the SAME directory SSSD reads
# (see the SSSD block above), so the OIDC username == the POSIX account by construction.
# ood-portal-generator reads the dex: block from ood_portal.yml and emits BOTH the Dex config
# and the Apache mod_auth_openidc vhost — so there is NO hand-maintained oidc_*/auth:/
# OIDCXForwardedHeaders/redirect tuning (the #52/#60/#73/#73 class cannot recur), and NO
# login-time account provisioning (the #67/#69/#71/#77 dead end is gone — getpwnam resolves
# via SSSD). See docs/reference-architecture.md.
if [ "${OOD_USE_SSSD}" = "true" ] && [ -n "${OOD_DIRECTORY_BIND_PW}" ]; then
  SERVERNAME="${OOD_DOMAIN:-${OOD_ALB_DNS:-$(imds_get public-hostname)}}"
  echo "=== Generating ood_portal.yml (Dex + LDAP connector, servername=${SERVERNAME}) ==="

  # Derive an LDAP base DN from the directory domain (ood.internal -> dc=ood,dc=internal);
  # used only to default the user-search / bind DNs when the operator did not set them.
  _BASE_DN="dc=$(echo "${OOD_DIRECTORY_NAME}" | sed 's/\./,dc=/g')"
  _USER_BASE_DN="${OOD_DIRECTORY_USER_BASE_DN:-CN=Users,${_BASE_DN}}"
  _BIND_DN="${OOD_DIRECTORY_BIND_DN:-CN=Administrator,CN=Users,${_BASE_DN}}"
  _USER_FILTER="${OOD_DIRECTORY_USER_FILTER:-(objectClass=person)}"
  _USERNAME_ATTR="${OOD_DIRECTORY_USERNAME_ATTR:-sAMAccountName}"
  # Dex's LDAP host is the directory endpoint with no scheme (host:port). Strip ldaps:// etc.
  _LDAP_HOST="${OOD_DIRECTORY_LDAP_URI#*://}"
  case "${_LDAP_HOST}" in *:*) : ;; *) _LDAP_HOST="${_LDAP_HOST}:636" ;; esac

  # The bind password is interpolated into a separate, root-only file rather than echoed into
  # logs. ood_portal.yml itself is world-readable, so we keep the password OUT of it by using
  # Dex's bindPW directly here — ood_portal.yml is 0600 below to protect it.
  umask 077
  cat > /etc/ood/config/ood_portal.yml <<OODPORTAL
---
servername: "${SERVERNAME}"
dex:
  connectors:
    - type: ldap
      id: directory
      name: Directory
      config:
        host: "${_LDAP_HOST}"
        insecureSkipVerify: true
        bindDN: "${_BIND_DN}"
        bindPW: "${OOD_DIRECTORY_BIND_PW}"
        userSearch:
          baseDN: "${_USER_BASE_DN}"
          filter: "${_USER_FILTER}"
          username: "${_USERNAME_ATTR}"
          idAttr: "${_USERNAME_ATTR}"
          emailAttr: mail
          nameAttr: cn
OODPORTAL
  chmod 600 /etc/ood/config/ood_portal.yml
  umask 022

  # Regenerate the Apache config from the portal YAML; the generator owns the OIDC vhost.
  if command -v /opt/ood/ood-portal-generator/sbin/update_ood_portal &>/dev/null; then
    /opt/ood/ood-portal-generator/sbin/update_ood_portal
    # Assert the generator emitted the OIDC vhost (not the need_auth fallback). With a dex:
    # block present this should always hold; warn loudly if not.
    if ! grep -qi "openid-connect" /etc/httpd/conf.d/ood-portal.conf 2>/dev/null; then
      echo "ERROR: ood-portal.conf has no 'openid-connect' AuthType (#78) — generator fell back to need_auth. Check ondemand-dex is installed and the dex: block is valid. Web login will fail."
    fi
  fi
  systemctl enable --now ondemand-dex 2>/dev/null || systemctl restart ondemand-dex 2>/dev/null || true
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

# HealthOmics adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('omics' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring HealthOmics cluster ==="
  cat > /etc/ood/config/clusters.d/aws-omics.yml <<OMICSCONF
---
v2:
  metadata:
    title: "AWS HealthOmics"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-omics-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
OMICSCONF
fi

# Bedrock batch-inference adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('bedrock' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring Bedrock cluster ==="
  cat > /etc/ood/config/clusters.d/aws-bedrock.yml <<BEDROCKCONF
---
v2:
  metadata:
    title: "AWS Bedrock"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-bedrock-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
BEDROCKCONF
fi

# EMR Serverless adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('emr' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring EMR Serverless cluster ==="
  EMR_APP_ID=$(aws ssm get-parameter \
    --region "${AWS_REGION}" \
    --name "/ood/${OOD_ENVIRONMENT}/emr_application_id" \
    --query 'Parameter.Value' \
    --output text 2>/dev/null || echo "")

  cat > /etc/ood/config/clusters.d/aws-emr.yml <<EMRCONF
---
v2:
  metadata:
    title: "Amazon EMR Serverless"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-emr-adapter"
      args:
        - submit
        - "--application-id=${EMR_APP_ID}"
        - "--region=${AWS_REGION}"
EMRCONF
fi

# SageMaker Training adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('sagemaker-training' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring SageMaker Training cluster ==="
  cat > /etc/ood/config/clusters.d/aws-sagemaker-training.yml <<SMTRAINCONF
---
v2:
  metadata:
    title: "AWS SageMaker Training"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-sagemaker-training-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
SMTRAINCONF
fi

# Fargate adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('fargate' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring Fargate cluster ==="
  ECS_CLUSTER_ARN=$(aws ecs list-clusters \
    --region "${AWS_REGION}" \
    --query "clusterArns[?contains(@, 'ood-fargate-${OOD_ENVIRONMENT}')]" \
    --output text 2>/dev/null | head -1 || echo "")
  if [ -z "${ECS_CLUSTER_ARN}" ]; then
    ECS_CLUSTER_ARN=$(aws ecs list-clusters \
      --region "${AWS_REGION}" \
      --query "clusterArns[?contains(@, 'ood-${OOD_ENVIRONMENT}')]" \
      --output text 2>/dev/null | head -1 || echo "")
  fi

  cat > /etc/ood/config/clusters.d/aws-fargate.yml <<FARGATECONF
---
v2:
  metadata:
    title: "AWS Fargate"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-fargate-adapter"
      args:
        - submit
        - "--cluster=${ECS_CLUSTER_ARN}"
        - "--region=${AWS_REGION}"
FARGATECONF
fi

# Step Functions adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('stepfunctions' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring Step Functions cluster ==="
  cat > /etc/ood/config/clusters.d/aws-stepfunctions.yml <<SFNCONF
---
v2:
  metadata:
    title: "AWS Step Functions"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-stepfunctions-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
SFNCONF
fi

# Braket adapter cluster config
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('braket' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring Braket cluster ==="
  cat > /etc/ood/config/clusters.d/aws-braket.yml <<BRAKETCONF
---
v2:
  metadata:
    title: "AWS Braket"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-braket-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
BRAKETCONF
fi

# Router meta-adapter cluster config (#6): dispatches by job-spec content to the
# backend adapters under /usr/local/lib/ood-adapters (which must also be enabled).
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('router' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring router cluster ==="
  cat > /etc/ood/config/clusters.d/aws-router.yml <<ROUTERCONF
---
v2:
  metadata:
    title: "AWS (auto-route)"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-router-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
        - "--adapters-dir=/usr/local/lib/ood-adapters"
ROUTERCONF
fi

# Burst meta-adapter cluster config (#5): submits locally until the local queue is
# busy, then bursts to the cloud adapter. Operators set the local/cloud adapter paths
# to match their site (the cloud default here is Batch).
if echo "${ADAPTERS_JSON}" | python3 -c "import sys,json; print('burst' in json.load(sys.stdin))" 2>/dev/null | grep -q True; then
  echo "=== Configuring burst cluster ==="
  cat > /etc/ood/config/clusters.d/aws-burst.yml <<BURSTCONF
---
v2:
  metadata:
    title: "AWS (burst overflow)"
    hidden: false
  job:
    adapter: "adapter_script"
    submit_host: "localhost"
    submit:
      script: "/usr/local/lib/ood-adapters/ood-burst-adapter"
      args:
        - submit
        - "--region=${AWS_REGION}"
        - "--local-adapter=/usr/local/lib/ood-adapters/ood-slurm-adapter"
        - "--cloud-adapter=/usr/local/lib/ood-adapters/ood-aws-batch-adapter"
        - "--queue-threshold=10"
BURSTCONF
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
# #78: ondemand-dex is the OIDC provider (started in the web-auth block above when use_sssd);
# nothing to start here for the retired oidc-auth-broker.

# OOD 4.x on AL2023 uses httpd.service with drop-in configs from the ondemand package
systemctl enable --now httpd || true

# Open the portal ports in the host firewall. The AMI ships with firewalld active
# (default public zone allows only ssh/mdns/dhcpv6), so without this httpd listens
# but every external connection is refused with a TCP RST (#29). The security group
# remains the primary network control; this just stops the host firewall from
# silently blocking 80/443. Idempotent — safe to re-run on every boot.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  echo "=== Opening http/https in firewalld ==="
  firewall-cmd --permanent --add-service=http --add-service=https
  firewall-cmd --reload
fi

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
