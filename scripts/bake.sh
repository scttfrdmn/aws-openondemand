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

# #78: SSSD/NSS directory-identity stack (AWS Directory Service join). Baked in unconditionally
# (harmless when use_sssd=false); userdata.sh writes /etc/sssd/sssd.conf + joins at launch.
# sssd-ad: AD provider; realmd/adcli: domain join; oddjob-mkhomedir: create homes on first
# login (replaces the bespoke ood-provision-user/useradd path that #77 proved can't work);
# authselect: enable the sssd profile.
dnf -y install sssd sssd-ad sssd-ldap sssd-tools realmd adcli \
  oddjob oddjob-mkhomedir authselect krb5-workstation samba-common-tools

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

# M2: OOD_VERSION must be set explicitly — auto-detecting or defaulting to a mutable
# version produces non-reproducible AMIs. Two Packer runs from the same git SHA must
# install the exact same OOD binary. Pin in CI:
#   packer build -var ood_version=4.0.10 -var oidc_pam_version=v1.2.3 packer/ood.pkr.hcl
if [ -z "${OOD_VERSION:-}" ]; then
  echo "ERROR: OOD_VERSION is not set."
  echo "       Pin to a specific release for reproducible AMI builds:"
  echo "         packer build -var ood_version=4.0.10 packer/ood.pkr.hcl"
  exit 1
fi
dnf -y install "ondemand-${OOD_VERSION}"

# #38: OOD's web auth uses the Apache mod_auth_openidc module. ood-portal-generator
# silently degrades to the need_auth fallback if it isn't loadable, so a portal with a
# correct ood_portal.yml still can't do OIDC. Install it explicitly. mod_auth_openidc is
# not in the AL2023 core repos; the ondemand RPM repo (enabled by ondemand-release above)
# ships it for the OOD platforms. If a future AMI base drops it from that repo, switch to
# the pinned OpenIDC EL9 release RPM (+ cjose) following the oidc-pam install pattern.
if dnf -y install mod_auth_openidc; then
  echo "=== mod_auth_openidc installed ==="
else
  echo "FATAL: mod_auth_openidc not available from configured repos — OOD web OIDC will fall back to need_auth (#38)."
  echo "       Provide it via the ondemand repo or a pinned OpenIDC EL9 RPM, then re-bake."
  exit 1
fi

# Enable OOD services (OOD 4.x on AL2023 uses httpd.service with drop-in configs)
systemctl enable httpd || true

# Assert the module is loadable now, so a bad install fails the bake rather than
# producing an AMI that silently can't authenticate.
if ! httpd -M 2>/dev/null | grep -q auth_openidc; then
  echo "FATAL: mod_auth_openidc installed but not loaded by httpd — aborting AMI bake (#38)"
  exit 1
fi

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
# L3: OIDC_PAM_VERSION must be set explicitly — auto-detecting the "latest" release at bake
# time produces non-reproducible AMIs (two runs from the same commit may install different
# binaries). Pin to a specific tag in CI or the Packer variable file.
if [ -z "${OIDC_PAM_VERSION:-}" ]; then
  echo "ERROR: OIDC_PAM_VERSION is not set."
  echo "       Pin to a specific release tag for reproducible AMI builds:"
  echo "         packer build -var oidc_pam_version=v1.2.3 packer/ood.pkr.hcl"
  echo "       or set the environment variable before running this script."
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

# #34: real release asset naming is oidc-pam-<ver>-linux-<arch>.tar.gz with a per-asset
# <asset>.sha256 sidecar (NOT oidc-pam_linux_<arch>.tar.gz / checksums.txt). The tarball
# extracts to a versioned subdir, so binaries are placed explicitly after extraction.
# NOTE: keep this in sync with the runtime fallback in scripts/userdata.sh.
OIDC_PAM_ASSET="oidc-pam-${OIDC_PAM_VERSION}-linux-${OIDC_PAM_ARCH}.tar.gz"
OIDC_PAM_DIR="oidc-pam-${OIDC_PAM_VERSION}-linux-${OIDC_PAM_ARCH}"
OIDC_PAM_TGZ_URL="https://github.com/scttfrdmn/oidc-pam/releases/download/${OIDC_PAM_VERSION}/${OIDC_PAM_ASSET}"
OIDC_PAM_SHA_URL="${OIDC_PAM_TGZ_URL}.sha256"
echo "=== Installing oidc-pam ${OIDC_PAM_VERSION} ==="
if curl -fsSL --head "${OIDC_PAM_TGZ_URL}" 2>/dev/null | grep -q "200\|302"; then
  TMPDIR=$(mktemp -d)
  TGZ="${TMPDIR}/${OIDC_PAM_ASSET}"
  curl -fsSL "${OIDC_PAM_TGZ_URL}" -o "${TGZ}"
  # Verify against the per-asset .sha256 sidecar (format: "<hash>  <filename>")
  if curl -fsSL "${OIDC_PAM_SHA_URL}" -o "${TMPDIR}/${OIDC_PAM_ASSET}.sha256" 2>/dev/null; then
    EXPECTED=$(awk '{print $1}' "${TMPDIR}/${OIDC_PAM_ASSET}.sha256")
    ACTUAL=$(sha256sum "${TGZ}" | awk '{print $1}')
    if [ "${EXPECTED}" != "${ACTUAL}" ]; then
      echo "ERROR: oidc-pam checksum mismatch — aborting install"
      rm -rf "${TMPDIR}"
      exit 1
    fi
    echo "oidc-pam checksum verified: ${ACTUAL}"
  else
    echo "ERROR: ${OIDC_PAM_ASSET}.sha256 unavailable — aborting for supply chain safety"
    rm -rf "${TMPDIR}"
    exit 1
  fi
  # Extract the versioned subdir, then place the real artifacts the package ships.
  tar -xz -C "${TMPDIR}" -f "${TGZ}"
  install -m 0755 "${TMPDIR}/${OIDC_PAM_DIR}/oidc-auth-broker" /usr/local/bin/oidc-auth-broker
  install -m 0755 "${TMPDIR}/${OIDC_PAM_DIR}/oidc-pam-helper" /usr/local/bin/oidc-pam-helper
  install -m 0755 "${TMPDIR}/${OIDC_PAM_DIR}/oidc-admin" /usr/local/bin/oidc-admin
  mkdir -p /usr/lib64/security
  install -m 0644 "${TMPDIR}/${OIDC_PAM_DIR}/pam_oidc.so" /usr/lib64/security/pam_oidc.so
  rm -rf "${TMPDIR}"
  # Assert the runtime-critical artifacts landed. (The v0.3.x package ships
  # oidc-auth-broker + pam_oidc.so; there is no standalone oidc-pam binary or
  # libnss_oidc.so.2 — see oidc-pam integration issue referenced in userdata.sh.)
  if [ ! -x /usr/local/bin/oidc-auth-broker ]; then
    echo "FATAL: oidc-auth-broker missing/not executable after extraction — aborting AMI bake"
    exit 1
  fi
  if [ ! -f /usr/lib64/security/pam_oidc.so ]; then
    echo "FATAL: pam_oidc.so not installed — a portal without it silently rejects logins; aborting AMI bake"
    exit 1
  fi
  echo "=== oidc-pam ${OIDC_PAM_VERSION} installed ==="
else
  echo "ERROR: oidc-pam asset not available at ${OIDC_PAM_TGZ_URL} — aborting AMI build (L1)"
  echo "       Set OIDC_PAM_VERSION to a published release tag and retry."
  exit 1
fi

# Create oidc-auth-broker config directory (populated at launch by userdata.sh)
mkdir -p /etc/oidc-auth
chmod 700 /etc/oidc-auth

# pam_oidc.so is placed by the oidc-pam install step above (install -D into
# /usr/lib64/security/). The v0.3.x package ships no libnss_oidc.so.2, so there is no
# NSS module to install — the prior cp-from-/usr/local/bin blocks were dead code that
# assumed a flat-extract layout and an NSS artifact that don't exist (#34).

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
# #75: key on the email claim and regex-extract the local-part as the Unix username
# (demo@example.com → demo). cognito:username is the sub UUID under email-login, which
# useradd rejects. ood-portal-generator emits OIDCRemoteUserClaim verbatim, so the
# two-arg "<claim> <regex>" form works. Keep in sync with userdata.sh + the provisioning hook.
oidc_remote_user_claim: "email ^([^@]+)@"
oidc_scope: "openid email profile"
oidc_session_inactivity_timeout: 28800
oidc_session_max_duration: 28800
# No user_map_cmd: identity maps via oidc_remote_user_claim; oidc-pam v0.3.x has
# no map command (scttfrdmn/oidc-pam#87).
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
