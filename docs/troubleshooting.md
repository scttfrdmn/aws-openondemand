# Troubleshooting

## Bootstrap Monitoring

The bootstrap log is written to `/var/log/ood-bootstrap.log` on the instance.
If `enable_monitoring=true`, it also ships to CloudWatch at
`/aws/ec2/ood-<env>/bootstrap`.

To watch bootstrap live via SSM:

```bash
# Find the instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=ood-test" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# SSM session
aws ssm start-session --target "$INSTANCE_ID"

# Inside the session:
tail -f /var/log/ood-bootstrap.log
```

## Common Issues

### OOD portal returns 502/503

1. Check nginx: `systemctl status nginx`
2. Check Passenger: `journalctl -u ood-portal-web`
3. Check `/var/log/nginx/error.log`

### OIDC login fails / redirect loop

1. Verify Cognito App Client callback URL matches your domain
2. Check SSM parameters: `aws ssm get-parameters-by-path --path /ood/test/`
3. Check `systemctl status oidc-auth-broker`
4. Verify `OOD_OIDC_ISSUER_URL` is accessible: `curl "$URL/.well-known/openid-configuration"`

### EFS mount fails at boot

1. Check security group allows TCP 2049 between instance SG and EFS SG
2. Verify `amazon-efs-utils` is installed: `rpm -q amazon-efs-utils`
3. Check mount: `mount | grep efs`
4. Check `/var/log/amazon/efs/mount.log`

### WAF blocking legitimate traffic

WAF rule false positives are common during initial setup.

1. Check WAF sampled requests in the AWS Console (WAF → Web ACLs → ood-test → Rules)
2. Switch a rule from Block to Count temporarily: add `override_action { count {} }` in Terraform
3. Common false positive: OOD's interactive session WebSocket connections — exclude `/rnode/*` path

### Spot interruption — session lost

If `enable_session_cache=false`, PUN sessions don't survive interruption.
Enable it:

```hcl
enable_session_cache = true   # Level 5: ElastiCache Redis ~$15/mo
```

With `enable_session_cache=true`, sessions are stored in Redis and survive
instance replacement with no user impact.

### "Failed to acquire slot" in job submission

The OOD cluster YAML in `/etc/ood/config/clusters.d/` may not match the
deployed infrastructure. Check:

1. Batch queue ARN: `aws batch describe-job-queues --region us-east-1`
2. Adapter binary exists: `ls -la /usr/local/lib/ood-adapters/`
3. Adapter binary is executable: `chmod +x /usr/local/lib/ood-adapters/ood-aws-batch-adapter`

## Useful Commands

```bash
# Check all OOD services
systemctl status nginx oidc-auth-broker amazon-cloudwatch-agent

# View OOD passenger log
journalctl -u ood-portal-web -f

# Check DynamoDB UID table
aws dynamodb scan --table-name oid-uid-map-test --region us-east-1

# Check Cognito users
aws cognito-idp list-users --user-pool-id us-east-1_xxxx

# Reload OOD portal config (after editing ood_portal.yml)
/opt/ood/ood-portal-generator/sbin/update_ood_portal && systemctl reload nginx
```
