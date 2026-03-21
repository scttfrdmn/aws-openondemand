#!/usr/bin/env bash
# OOD AMI bake script — runs inside Packer during image build.
# Installs all static packages and configuration; does NOT configure
# environment-specific settings (those are done at launch by userdata.sh).
set -euo pipefail

exec > >(tee /var/log/ood-bake.log) 2>&1
echo "=== OOD bake started at $(date) ==="

###############################################################################
# 1. System updates & base packages
###############################################################################
dnf -y update
# AL2023 ships curl-minimal; --allowerasing replaces it with full curl.
dnf -y install --allowerasing vim wget curl unzip git tar \
  policycoreutils-python-utils cronie logrotate jq fail2ban \
  amazon-cloudwatch-agent amazon-efs-utils python3-botocore

###############################################################################
# 1a. fail2ban — nginx jails (SSH is not exposed; SSM only)
###############################################################################
cat > /etc/fail2ban/jail.local <<'F2BCONF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*error*log

[nginx-badbots]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*access*log
F2BCONF
systemctl enable fail2ban

###############################################################################
# 2. OOD web stack note
# OOD 3.x+ bundles its own Apache + Passenger; no separate web server install.
# Security headers are configured via OOD's ood_portal.yml at boot.
###############################################################################

###############################################################################
# 3. Open OnDemand from the official ondemand-release RPM
###############################################################################
# Install the OOD release package which configures the OOD yum repo
ONDEMAND_RELEASE_URL="https://yum.osc.edu/ondemand/4.0/ondemand-release-web-4.0-1.amzn2023.noarch.rpm"
dnf -y install --setopt=gpgcheck=1 "${ONDEMAND_RELEASE_URL}" || {
  echo "ERROR: Failed to verify RPM GPG signature or install OOD release RPM"
  exit 1
}

dnf -y install ondemand-4.0.10

# Enable OOD services (OOD 4.x on AL2023 uses httpd.service with drop-in configs)
systemctl enable httpd || true

# Create OOD directory structure expected at bake time
mkdir -p /etc/ood/config/clusters.d \
         /etc/ood/config/apps \
         /var/www/ood/apps/sys \
         /var/log/ood

chown -R apache:apache /var/log/ood || true
chmod 755 /var/log/ood

###############################################################################
# 4. oidc-pam — OIDC → PAM bridge for cloud-native Unix identity
###############################################################################
# Download the latest release binary from github.com/scttfrdmn/oidc-pam
# Pin to a specific release tag for reproducible AMI builds.
# Override at packer build time: packer build -var oidc_pam_version=v1.2.3
OIDC_PAM_VERSION="${OIDC_PAM_VERSION:-}"
if [ -z "${OIDC_PAM_VERSION}" ]; then
  OIDC_PAM_VERSION=$(curl -fsSL \
    https://api.github.com/repos/scttfrdmn/oidc-pam/releases/latest \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
    || echo "")
fi
if [ -z "${OIDC_PAM_VERSION}" ]; then
  echo "ERROR: Cannot determine oidc-pam version — set OIDC_PAM_VERSION env var or ensure GitHub API is reachable"
  exit 1
fi

ARCH=$(uname -m)
if [ "${ARCH}" = "x86_64" ]; then
  OIDC_PAM_ARCH="amd64"
elif [ "${ARCH}" = "aarch64" ]; then
  OIDC_PAM_ARCH="arm64"
else
  OIDC_PAM_ARCH="${ARCH}"
fi

OIDC_PAM_TGZ_URL="https://github.com/scttfrdmn/oidc-pam/releases/download/${OIDC_PAM_VERSION}/oidc-pam_linux_${OIDC_PAM_ARCH}.tar.gz"
OIDC_PAM_SHA_URL="https://github.com/scttfrdmn/oidc-pam/releases/download/${OIDC_PAM_VERSION}/checksums.txt"
echo "=== Installing oidc-pam ${OIDC_PAM_VERSION} ==="
if curl -fsSL --head "${OIDC_PAM_TGZ_URL}" 2>/dev/null | grep -q "200\|302"; then
  TMPDIR=$(mktemp -d)
  TGZ="${TMPDIR}/oidc-pam.tar.gz"
  curl -fsSL "${OIDC_PAM_TGZ_URL}" -o "${TGZ}"
  # Verify SHA256 checksum when checksums.txt is available
  if curl -fsSL "${OIDC_PAM_SHA_URL}" -o "${TMPDIR}/checksums.txt" 2>/dev/null; then
    EXPECTED=$(grep "oidc-pam_linux_${OIDC_PAM_ARCH}.tar.gz" "${TMPDIR}/checksums.txt" | awk '{print $1}')
    ACTUAL=$(sha256sum "${TGZ}" | awk '{print $1}')
    if [ "${EXPECTED}" != "${ACTUAL}" ]; then
      echo "ERROR: oidc-pam checksum mismatch — aborting install"
      rm -rf "${TMPDIR}"
      exit 1
    fi
    echo "oidc-pam checksum verified: ${ACTUAL}"
  else
    echo "ERROR: checksums.txt unavailable — aborting for supply chain safety"
    rm -rf "${TMPDIR}"
    exit 1
  fi
  tar -xz -C /usr/local/bin/ -f "${TGZ}"
  rm -rf "${TMPDIR}"
  chmod 755 /usr/local/bin/oidc-pam /usr/local/bin/oidc-auth-broker 2>/dev/null || true
  # Verify extraction succeeded
  if [ ! -f /usr/local/bin/oidc-pam ] || [ ! -x /usr/local/bin/oidc-pam ]; then
    echo "ERROR: oidc-pam binary missing or not executable after extraction"
    exit 1
  fi
  echo "=== oidc-pam ${OIDC_PAM_VERSION} installed ==="
else
  echo "ERROR: oidc-pam binary not available at ${OIDC_PAM_TGZ_URL} — aborting AMI build (L1)"
  echo "       Set OIDC_PAM_VERSION to a published release tag and retry."
  exit 1
fi

# Create oidc-auth-broker config directory (populated at launch by userdata.sh)
mkdir -p /etc/oidc-auth
chmod 700 /etc/oidc-auth

# Install PAM module for oidc-pam
# The oidc-pam release should include pam_oidc.so — place in PAM module dir
ARCH_PAM=$(uname -m)
PAM_MODULE_PATH="/usr/lib64/security/pam_oidc.so"
if [ -f /usr/local/bin/pam_oidc.so ]; then
  cp /usr/local/bin/pam_oidc.so "${PAM_MODULE_PATH}"
  chmod 644 "${PAM_MODULE_PATH}"
fi

# NSS module for oidc-pam UID mapping (libnss_oidc.so)
NSS_MODULE_PATH="/usr/lib64/libnss_oidc.so.2"
if [ -f /usr/local/bin/libnss_oidc.so.2 ]; then
  cp /usr/local/bin/libnss_oidc.so.2 "${NSS_MODULE_PATH}"
  chmod 644 "${NSS_MODULE_PATH}"
fi

###############################################################################
# 5. Adapter binary placeholders
#    Actual binaries are pulled at launch by userdata.sh from SSM-specified URLs
###############################################################################
mkdir -p /usr/local/lib/ood-adapters
cat > /usr/local/lib/ood-adapters/README <<'EOF'
OOD compute adapter binaries are installed at instance launch.
See /etc/ood/config/clusters.d/ for cluster configurations.
EOF

###############################################################################
# 6. OOD portal skeleton config (populated at launch from SSM)
###############################################################################
# ood_portal.yml will be generated at boot by userdata.sh
cat > /etc/ood/config/ood_portal.yml.tmpl <<'OODPORTAL'
# Generated at boot by userdata.sh from SSM parameters.
# Edit SSM parameters under /ood/${environment}/ to change portal config.
---
servername: "${OOD_DOMAIN}"
ssl:
  - 'SSLCertificateFile "/etc/letsencrypt/live/${OOD_DOMAIN}/cert.pem"'
  - 'SSLCertificateKeyFile "/etc/letsencrypt/live/${OOD_DOMAIN}/privkey.pem"'
  - 'SSLCertificateChainFile "/etc/letsencrypt/live/${OOD_DOMAIN}/chain.pem"'
oidc_uri: /oidc
oidc_discover_uri: /oidc/.well-known/openid-configuration
oidc_discover_root: /var/www/ood/discover
oidc_provider_metadata_url: "${OIDC_ISSUER_URL}/.well-known/openid-configuration"
oidc_client_id: "${OIDC_CLIENT_ID}"
oidc_client_secret: "${OIDC_CLIENT_SECRET}"
oidc_remote_user_claim: "preferred_username"
oidc_scope: "openid email profile"
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
user_map_cmd: "/usr/local/bin/oidc-pam map-user"
OODPORTAL

# PHP session hardening (only if PHP is installed — OOD 4.x doesn't use system PHP)
if [ -d /etc/php.d ]; then
  cat > /etc/php.d/99-ood-session.ini <<'PHPINI'
session.cookie_httponly = On
session.cookie_secure = On
session.cookie_samesite = Lax
expose_php = Off
PHPINI
fi

###############################################################################
# 7. AIDE file integrity baseline
###############################################################################
# Install AIDE and initialize the database now so userdata.sh can run --check
dnf -y install aide
# Generate default config if not present
[ -f /etc/aide.conf ] || aide --init 2>/dev/null || true
aide --init 2>/dev/null || true
# Move the generated database into place
if [ -f /var/lib/aide/aide.db.new.gz ]; then
  cp /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
fi

###############################################################################
# 8. Security: SELinux policies for OOD
###############################################################################
# Allow nginx/passenger to connect to network (needed for OOD sub-apps)
setsebool -P httpd_can_network_connect 1 2>/dev/null || true
setsebool -P httpd_can_network_relay 1 2>/dev/null || true

###############################################################################
# 9. CloudWatch Agent service enabled (configured at launch by userdata.sh)
###############################################################################
systemctl enable amazon-cloudwatch-agent

echo "=== OOD bake completed at $(date) ==="
