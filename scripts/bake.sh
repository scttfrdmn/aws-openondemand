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

# #78: OOD's bundled Dex is the OIDC provider. ood-portal-generator reads the dex: block in
# ood_portal.yml and emits BOTH the Dex config and the Apache mod_auth_openidc vhost that
# points at Dex — so both packages are required. mod_auth_openidc is the Apache OIDC handler;
# ondemand-dex is the IdP that authenticates users via its LDAP connector against the
# directory. (This replaces the bespoke Cognito + oidc-pam stack — see reference-architecture.md.)
if dnf -y install mod_auth_openidc ondemand-dex; then
  echo "=== mod_auth_openidc + ondemand-dex installed ==="
else
  echo "FATAL: mod_auth_openidc / ondemand-dex not available from configured repos — OOD web OIDC will fall back to need_auth (#38/#78)."
  echo "       Both ship from the ondemand RPM repo (enabled by ondemand-release above); provide them, then re-bake."
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
# 4. Identity: Dex (web auth) + SSSD (POSIX) — no oidc-pam
###############################################################################
# #78: the bespoke oidc-pam/oidc-auth-broker bridge is RETIRED. Web auth is now OOD's bundled
# Dex (installed above via ondemand-dex), authenticating against the directory via an LDAP
# connector that userdata.sh writes into ood_portal.yml. POSIX identity is SSSD against the
# same directory (sssd/sssd-ad/oddjob-mkhomedir installed in section 1; joined at launch by
# userdata.sh). There is no login-time account creation — getpwnam resolves directory-side.
# See docs/reference-architecture.md.

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
# 6. OOD portal config
###############################################################################
# #78: ood_portal.yml (the Dex dex: block + SSSD-aligned settings) is generated at boot by
# userdata.sh from the directory config — no bake-time template. The generator emits the
# Apache mod_auth_openidc vhost from the dex: block.

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
