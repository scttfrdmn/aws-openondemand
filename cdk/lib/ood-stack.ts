import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as efs from "aws-cdk-lib/aws-efs";
import * as dynamodb from "aws-cdk-lib/aws-dynamodb";
import * as cognito from "aws-cdk-lib/aws-cognito";
import * as autoscaling from "aws-cdk-lib/aws-autoscaling";
import * as elbv2 from "aws-cdk-lib/aws-elasticloadbalancingv2";
import * as acm from "aws-cdk-lib/aws-certificatemanager";
import * as wafv2 from "aws-cdk-lib/aws-wafv2";
import * as cloudfront from "aws-cdk-lib/aws-cloudfront";
import * as cforigins from "aws-cdk-lib/aws-cloudfront-origins";
import * as dlm from "aws-cdk-lib/aws-dlm";
import * as iam from "aws-cdk-lib/aws-iam";
import * as kms from "aws-cdk-lib/aws-kms";
import * as sns from "aws-cdk-lib/aws-sns";
import * as snsSubscriptions from "aws-cdk-lib/aws-sns-subscriptions";
import * as cloudwatch from "aws-cdk-lib/aws-cloudwatch";
import * as cloudwatchActions from "aws-cdk-lib/aws-cloudwatch-actions";
import * as logs from "aws-cdk-lib/aws-logs";
import * as ssm from "aws-cdk-lib/aws-ssm";
import * as batch from "aws-cdk-lib/aws-batch";
import * as sagemaker from "aws-cdk-lib/aws-sagemaker";
import * as emrserverless from "aws-cdk-lib/aws-emrserverless";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as s3 from "aws-cdk-lib/aws-s3";
import * as s3deploy from "aws-cdk-lib/aws-s3-deployment";
import * as cr from "aws-cdk-lib/custom-resources";
import * as directoryservice from "aws-cdk-lib/aws-directoryservice";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";
import * as crypto from "crypto";
import * as fs from "fs";
import * as path from "path";

interface OodStackProps extends cdk.StackProps {
  environment: string;
}

const VALID_ENVIRONMENTS = ["test", "staging", "prod"];

const ENV_CONFIG: Record<
  string,
  { volumeSize: number; logRetention: logs.RetentionDays }
> = {
  test: { volumeSize: 30, logRetention: logs.RetentionDays.ONE_WEEK },
  staging: { volumeSize: 50, logRetention: logs.RetentionDays.ONE_MONTH },
  prod: { volumeSize: 50, logRetention: logs.RetentionDays.THREE_MONTHS },
};

// Deployment profiles matching terraform/main.tf locals.profile_config
const PROFILE_CONFIG: Record<
  string,
  { instanceType: string; cpuArch: ec2.AmazonLinuxCpuType; useSpot: boolean }
> = {
  minimal: {
    instanceType: "t3.medium",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: false,
  },
  standard: {
    instanceType: "m6i.xlarge",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: false,
  },
  graviton: {
    instanceType: "m7g.xlarge",
    cpuArch: ec2.AmazonLinuxCpuType.ARM_64,
    useSpot: false,
  },
  spot: {
    instanceType: "m6i.xlarge",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: true,
  },
  large: {
    instanceType: "m6i.2xlarge",
    cpuArch: ec2.AmazonLinuxCpuType.X86_64,
    useSpot: false,
  },
};

export class OodStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: OodStackProps) {
    super(scope, id, props);

    if (!VALID_ENVIRONMENTS.includes(props.environment)) {
      throw new Error(
        `Invalid environment "${props.environment}". Must be one of: ${VALID_ENVIRONMENTS.join(", ")}`
      );
    }

    // H7: apply project/environment tags to every taggable resource in the stack
    cdk.Tags.of(this).add("Project", "aws-openondemand");
    cdk.Tags.of(this).add("Environment", props.environment);

    const config = ENV_CONFIG[props.environment];

    // #79: deletion protection / RETAIN only in prod, so non-prod `cdk destroy` is one clean
    // pass (mirrors the Terraform `prod_protected` local). Drives Cognito/DynamoDB protection,
    // RemovalPolicy, and S3 autoDeleteObjects below.
    const prodProtected = props.environment === "prod";

    // --- Context-based configuration (same pattern as aws-hubzero) ---
    const deploymentProfile =
      this.node.tryGetContext("deploymentProfile") || "minimal";
    if (!PROFILE_CONFIG[deploymentProfile]) {
      throw new Error(
        `deploymentProfile must be one of: ${Object.keys(PROFILE_CONFIG).join(", ")} (got "${deploymentProfile}")`
      );
    }
    const profile = PROFILE_CONFIG[deploymentProfile];
    const instanceTypeOverride: string =
      this.node.tryGetContext("instanceType") || "";
    const ec2InstanceType = instanceTypeOverride || profile.instanceType;

    const vpcId = this.node.tryGetContext("vpcId");
    if (!vpcId) {
      throw new Error(
        "vpcId is required — set it in cdk.context.json or pass -c vpcId=vpc-xxx"
      );
    }
    const subnetId: string = this.node.tryGetContext("subnetId") || "";
    const allowedCidr: string = this.node.tryGetContext("allowedCidr");
    if (!allowedCidr) {
      throw new Error(
        "allowedCidr is required — set to your IP (e.g. 203.0.113.5/32)"
      );
    }
    if (
      props.environment !== "test" &&
      !allowedCidr.match(/^(\d{1,3}\.){3}\d{1,3}\/3[0-2]$/)
    ) {
      throw new Error(
        "For staging/prod, allowedCidr must be /30 or narrower"
      );
    }

    const domainName: string =
      this.node.tryGetContext("domainName") || "";
    const useCognito =
      this.node.tryGetContext("useCognito") !== "false";
    const enableEfs =
      this.node.tryGetContext("enableEfs") !== "false";
    const enableDynamodbUid =
      this.node.tryGetContext("enableDynamodbUid") !== "false";
    const enableSessionCache =
      this.node.tryGetContext("enableSessionCache") === "true";
    const enableS3Browser =
      this.node.tryGetContext("enableS3Browser") === "true";
    const enableAlb =
      this.node.tryGetContext("enableAlb") !== "false";
    const acmCertificateArn: string =
      this.node.tryGetContext("acmCertificateArn") || "";
    const enableWaf =
      this.node.tryGetContext("enableWaf") !== "false";
    const _enableVpcEndpoints =
      this.node.tryGetContext("enableVpcEndpoints") !== "false";
    const enableCdn =
      this.node.tryGetContext("enableCdn") === "true";
    const enableMonitoring =
      this.node.tryGetContext("enableMonitoring") !== "false";
    const _enableComplianceLogging =
      this.node.tryGetContext("enableComplianceLogging") === "true";
    const _enableBackup =
      this.node.tryGetContext("enableBackup") === "true";
    const enableKmsCmk =
      this.node.tryGetContext("enableKmsCmk") === "true";
    const enablePackerAmi =
      this.node.tryGetContext("enablePackerAmi") !== "false";
    const enableParameterStore =
      this.node.tryGetContext("enableParameterStore") !== "false";
    // #78: directory-backed identity (AWS Directory Service + SSSD). Default off; mirrors the
    // Terraform enable_directory / directory_name / directory_ldap_uri vars.
    const enableDirectory =
      this.node.tryGetContext("enableDirectory") === "true";
    const directoryName: string =
      this.node.tryGetContext("directoryName") || "ood.internal";
    const alarmEmail: string =
      this.node.tryGetContext("alarmEmail") || "";
    const adaptersEnabled: string[] =
      this.node.tryGetContext("adaptersEnabled") || [];
    const oidcPamVersion: string =
      this.node.tryGetContext("oidcPamVersion") || "v0.3.3";
    if (!/^v[0-9]+\.[0-9]+\.[0-9]+/.test(oidcPamVersion)) {
      throw new Error(`oidcPamVersion must be a semver tag like v0.3.3 (got "${oidcPamVersion}")`);
    }
    // H2: cognito_mfa_required=true sets MFA to REQUIRED (ON) instead of OPTIONAL.
    // Set this in cdk.context.json for prod once all users have enrolled TOTP.
    const cognitoMfaRequired =
      this.node.tryGetContext("cognitoMfaRequired") === "true";
    if (props.environment === "prod" && useCognito && !cognitoMfaRequired) {
      throw new Error(
        "Production Cognito deployments require cognitoMfaRequired=true. " +
          "Set this in cdk.context.json after users complete TOTP enrollment."
      );
    }
    const logGroupPrefix = `/aws/ec2/ood-${props.environment}`;

    // Spot precondition
    if (profile.useSpot && !(enableEfs && enableDynamodbUid && useCognito)) {
      throw new Error(
        'deploymentProfile="spot" requires enableEfs=true, enableDynamodbUid=true, and useCognito=true.'
      );
    }

    const vpc = ec2.Vpc.fromLookup(this, "Vpc", { vpcId });

    // --- KMS CMK (optional) ---
    let cmk: kms.Key | undefined;
    if (enableKmsCmk) {
      cmk = new kms.Key(this, "Cmk", {
        description: `OOD ${props.environment} CMK`,
        enableKeyRotation: true,
        pendingWindow: cdk.Duration.days(30),
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.RETAIN
            : cdk.RemovalPolicy.DESTROY,
      });
      new kms.Alias(this, "CmkAlias", {
        aliasName: `alias/ood-${props.environment}`,
        targetKey: cmk,
      });
      // L7: CloudWatch Logs requires an explicit key policy grant to encrypt log groups.
      // Without this, log groups with kms_key_id set silently fall back to unencrypted storage.
      cmk.addToResourcePolicy(
        new iam.PolicyStatement({
          principals: [
            new iam.ServicePrincipal(
              `logs.${this.region}.amazonaws.com`
            ),
          ],
          actions: [
            "kms:Encrypt*",
            "kms:Decrypt*",
            "kms:ReEncrypt*",
            "kms:GenerateDataKey*",
            "kms:Describe*",
          ],
          resources: ["*"],
          conditions: {
            ArnLike: {
              "kms:EncryptionContext:aws:logs:arn": `arn:aws:logs:${this.region}:${this.account}:*`,
            },
          },
        })
      );
    }

    // --- Security Groups ---
    const sg = new ec2.SecurityGroup(this, "SG", {
      vpc,
      description: `OOD portal ${props.environment}`,
      allowAllOutbound: false,
    });
    if (!enableAlb) {
      for (const port of [80, 443]) {
        sg.addIngressRule(
          ec2.Peer.ipv4(allowedCidr),
          ec2.Port.tcp(port),
          `Port ${port}`
        );
      }
    }
    sg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), "HTTPS outbound");
    sg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(80), "HTTP outbound");
    sg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.udp(53), "DNS UDP");
    sg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(53), "DNS TCP");

    // --- ALB (created early so its DNS name is the OIDC callback host AND the
    // ood_portal servername in user_data; listeners + target group attach later). ---
    // #25: a no-ALB, no-domain Cognito deploy has no stable HTTPS callback — fail fast.
    if (useCognito && !enableAlb && domainName === "") {
      throw new Error(
        "Cognito browser auth requires a stable HTTPS callback URL — set enableAlb=true or provide domainName (an instance IP is not a viable OIDC redirect target)."
      );
    }
    // #33: an ALB requires >=2 AZ subnets; guard explicit single-subnet input.
    const albSubnetIds: string[] = this.node.tryGetContext("albSubnetIds") || [];
    if (enableAlb && albSubnetIds.length > 0 && new Set(albSubnetIds).size < 2) {
      throw new Error(
        "enable_alb requires at least 2 subnets in different AZs. Provide >=2 distinct albSubnetIds."
      );
    }
    let alb: elbv2.ApplicationLoadBalancer | undefined;
    let albSg: ec2.SecurityGroup | undefined;
    if (enableAlb) {
      albSg = new ec2.SecurityGroup(this, "AlbSG", {
        vpc,
        description: `OOD ALB ${props.environment}`,
        allowAllOutbound: false,
      });
      for (const port of [80, 443]) {
        albSg.addIngressRule(ec2.Peer.ipv4(allowedCidr), ec2.Port.tcp(port), `ALB port ${port}`);
      }
      albSg.addEgressRule(sg, ec2.Port.tcp(80), "To EC2 HTTP");
      sg.addIngressRule(albSg, ec2.Port.tcp(80), "HTTP from ALB");
      alb = new elbv2.ApplicationLoadBalancer(this, "ALB", {
        vpc,
        internetFacing: true,
        securityGroup: albSg,
        deletionProtection: props.environment !== "test",
        ...(albSubnetIds.length > 0
          ? { vpcSubnets: { subnets: albSubnetIds.map((id, i) => ec2.Subnet.fromSubnetId(this, `AlbSubnet${i}`, id)) } }
          : {}),
      });

      // #31: ALB access logs — parity with aws_s3_bucket.alb_logs + access_logs{} in
      // terraform/main.tf. ALB log delivery is performed by the ELB service account and
      // only supports SSE-S3 (AES256) — SSE-KMS is rejected — so this bucket is AES256
      // regardless of enableKmsCmk (same constraint noted in the TF resource). logAccessLogs
      // attaches the required ELB-service-account bucket policy and the "alb-logs" prefix.
      const albLogsBucket = new s3.Bucket(this, "AlbLogsBucket", {
        bucketName: undefined, // let CFN assign a unique name (TF uses bucket_prefix)
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        enforceSSL: true, // mirrors the DenyHTTP (aws:SecureTransport=false) statement
        versioned: true, // H5: versioning detects log tampering
        removalPolicy: prodProtected
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
        // #79: non-prod purges objects+versions on destroy (the bucket is versioned, so
        // without this DeleteBucket fails BucketNotEmpty on leftover versions). prod retains.
        autoDeleteObjects: !prodProtected,
        lifecycleRules: [
          {
            expiration: cdk.Duration.days(
              props.environment === "prod" ? 365 : 90
            ),
            abortIncompleteMultipartUploadAfter: cdk.Duration.days(7),
          },
        ],
      });
      alb.logAccessLogs(albLogsBucket, "alb-logs");
    }

    // --- AMI selection ---
    const ami = enablePackerAmi
      ? ec2.MachineImage.lookup({
          name: "ood-base-*",
          owners: ["self"],
          filters: {
            architecture: [
              profile.cpuArch === ec2.AmazonLinuxCpuType.ARM_64
                ? "arm64"
                : "x86_64",
            ],
          },
        })
      : ec2.MachineImage.latestAmazonLinux2023({ cpuType: profile.cpuArch });

    // --- Cognito User Pool ---
    let userPool: cognito.UserPool | undefined;
    let appClient: cognito.UserPoolClient | undefined;
    let oidcIssuer: string;
    let oidcClientId: string;

    if (useCognito) {
      userPool = new cognito.UserPool(this, "UserPool", {
        userPoolName: `ood-${props.environment}`,
        selfSignUpEnabled: false,
        signInAliases: { email: true },
        autoVerify: { email: true },
        passwordPolicy: {
          minLength: 12,
          requireLowercase: true,
          requireUppercase: true,
          requireDigits: true,
          requireSymbols: true,
        },
        // H2: MFA driven by cognitoMfaRequired context — OPTIONAL during rollout,
        // REQUIRED (ON) once all users have enrolled TOTP. Prod throws at synth time
        // if cognitoMfaRequired is not set (enforced above).
        mfa: cognitoMfaRequired ? cognito.Mfa.REQUIRED : cognito.Mfa.OPTIONAL,
        mfaSecondFactor: { otp: true, sms: false },
        accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
        // #79: env-aware (mirrors the Terraform deletion_protection). prod RETAINs the pool
        // and turns on native deletion protection; non-prod DESTROYs so `cdk destroy` is a
        // clean one-pass teardown (was an unconditional RETAIN, which orphaned the pool).
        deletionProtection: prodProtected,
        removalPolicy: prodProtected
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
      });

      // #25: domain wins; else the ALB DNS (the precondition above guarantees one exists
      // when use_cognito). No localhost fallback — it was never a reachable callback.
      const callbackHost = domainName !== "" ? domainName : alb!.loadBalancerDnsName;
      // #60: path is `/oidc`, NOT `/oidc/callback`. OOD's ood_portal.yml sets
      // `oidc_uri: /oidc`, so mod_auth_openidc's OIDCRedirectURI (the redirect_uri sent to
      // Cognito) is `/oidc`. The registered callback must match that exact path.
      const callbackUrl = `https://${callbackHost}/oidc`;

      appClient = new cognito.UserPoolClient(this, "AppClient", {
        userPool,
        userPoolClientName: `ood-portal-${props.environment}`,
        generateSecret: true,
        oAuth: {
          flows: { authorizationCodeGrant: true },
          scopes: [
            cognito.OAuthScope.OPENID,
            cognito.OAuthScope.EMAIL,
            cognito.OAuthScope.PROFILE,
          ],
          callbackUrls: [callbackUrl],
          logoutUrls: [`https://${callbackHost}`],
        },
        // M8: Both userPassword and userSrp are intentionally disabled.
        // OOD uses OIDC/OAuth2 via the ALB authenticator — users never authenticate
        // directly against Cognito's native auth endpoints. Disabling these flows
        // prevents credential stuffing attacks against the Cognito hosted UI endpoints.
        authFlows: { userPassword: false, userSrp: false },
        preventUserExistenceErrors: true,
      });

      oidcIssuer = `https://cognito-idp.${this.region}.amazonaws.com/${userPool.userPoolId}`;
      oidcClientId = appClient.userPoolClientId;

      // Store OIDC config in SSM for userdata.sh
      if (enableParameterStore) {
        new ssm.StringParameter(this, "SsmOidcIssuer", {
          parameterName: `/ood/${props.environment}/oidc_issuer_url`,
          stringValue: oidcIssuer,
        });
        new ssm.StringParameter(this, "SsmOidcClientId", {
          parameterName: `/ood/${props.environment}/oidc_client_id`,
          stringValue: oidcClientId,
        });

        // #37: oidc-auth-broker v0.3.x requires security.token_encryption_key (32 raw
        // bytes, base64-encoded — what `openssl rand -base64 32` yields). userdata.sh
        // reads /ood/${env}/broker_token_key (SecureString, --with-decryption) into
        // OOD_BROKER_TOKEN_KEY → broker.yaml. Mirrors aws_ssm_parameter.broker_token_key
        // in terraform/main.tf, gated on use_cognito && enable_parameter_store.
        //
        // CloudFormation's native AWS::SSM::Parameter cannot create a SecureString, so we
        // PutParameter via a custom resource. DIVERGENCE from Terraform: TF holds the
        // random value in state and keeps it stable across applies; CDK has no such store,
        // so the key is re-generated whenever the template is re-synthesized and will
        // rotate on redeploy. For a token-encryption key this is benign — it only forces
        // the broker to re-issue session tokens (users re-authenticate), it does not break
        // the deployment.
        const brokerTokenKey = crypto.randomBytes(32).toString("base64");
        const brokerKeyParamName = `/ood/${props.environment}/broker_token_key`;
        new cr.AwsCustomResource(this, "BrokerTokenKeyParam", {
          // Stable physical id keyed on the parameter name — the resource maps 1:1 to the
          // SSM parameter regardless of value churn.
          resourceType: "Custom::SsmSecureString",
          onCreate: {
            service: "SSM",
            action: "putParameter",
            parameters: {
              Name: brokerKeyParamName,
              Value: brokerTokenKey,
              Type: "SecureString",
              Overwrite: true,
              ...(cmk ? { KeyId: cmk.keyArn } : {}),
            },
            physicalResourceId: cr.PhysicalResourceId.of(brokerKeyParamName),
          },
          onUpdate: {
            service: "SSM",
            action: "putParameter",
            parameters: {
              Name: brokerKeyParamName,
              Value: brokerTokenKey,
              Type: "SecureString",
              Overwrite: true,
              ...(cmk ? { KeyId: cmk.keyArn } : {}),
            },
            physicalResourceId: cr.PhysicalResourceId.of(brokerKeyParamName),
          },
          onDelete: {
            service: "SSM",
            action: "deleteParameter",
            parameters: { Name: brokerKeyParamName },
          },
          policy: cr.AwsCustomResourcePolicy.fromStatements([
            new iam.PolicyStatement({
              actions: ["ssm:PutParameter", "ssm:DeleteParameter"],
              resources: [
                `arn:aws:ssm:${this.region}:${this.account}:parameter${brokerKeyParamName}`,
              ],
            }),
            // KMS Encrypt is required for SecureString PutParameter under a CMK.
            ...(cmk
              ? [
                  new iam.PolicyStatement({
                    actions: ["kms:Encrypt", "kms:GenerateDataKey"],
                    resources: [cmk.keyArn],
                  }),
                ]
              : []),
          ]),
          installLatestAwsSdk: false,
        });
      }
    }

    // --- DynamoDB UID mapping ---
    let uidTable: dynamodb.Table | undefined;
    if (enableDynamodbUid) {
      uidTable = new dynamodb.Table(this, "UidMap", {
        tableName: `oid-uid-map-${props.environment}`,
        // #39: keyed on `username` (the only identity the pam_exec provisioning hook
        // receives). Rows are {username, uid}; a "__uid_counter__" sentinel item holds
        // next_uid for atomic allocation. (Re-key forces table replacement on an existing
        // deployment — the table is empty in practice at first wiring.)
        partitionKey: { name: "username", type: dynamodb.AttributeType.STRING },
        billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
        pointInTimeRecovery: true,
        encryption: enableKmsCmk
          ? dynamodb.TableEncryption.CUSTOMER_MANAGED
          : dynamodb.TableEncryption.AWS_MANAGED,
        encryptionKey: cmk,
        // #79: native deletion protection + RETAIN in prod only; non-prod DESTROYs for a
        // clean `cdk destroy` (mirrors the Terraform deletion_protection_enabled).
        deletionProtection: prodProtected,
        removalPolicy: prodProtected
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
      });

      if (enableParameterStore) {
        new ssm.StringParameter(this, "SsmUidTable", {
          parameterName: `/ood/${props.environment}/dynamodb_uid_table`,
          stringValue: uidTable.tableName,
        });
      }
    }

    // --- EFS /home ---
    let homeFs: efs.FileSystem | undefined;
    let homeAccessPoint: efs.AccessPoint | undefined;

    if (enableEfs) {
      homeFs = new efs.FileSystem(this, "HomeFs", {
        vpc,
        encrypted: true,
        kmsKey: cmk,
        performanceMode: efs.PerformanceMode.GENERAL_PURPOSE,
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.RETAIN
            : cdk.RemovalPolicy.DESTROY,
        lifecyclePolicy: efs.LifecyclePolicy.AFTER_30_DAYS,
      });
      homeFs.connections.allowFrom(sg, ec2.Port.tcp(2049), "NFS from OOD");
      sg.addEgressRule(
        ec2.Peer.anyIpv4(),
        ec2.Port.tcp(2049),
        "NFS to EFS"
      );

      // M2: The access point runs as uid/gid 0 (root) with permissions 755.
      // This is intentional: OOD's PAM module (oidc-pam) must create per-user
      // home directories under /home on first login, which requires root.
      // User-level isolation is enforced by PAM session configuration and
      // OOD's per-user Nginx/Passenger processes (PUN), not by EFS permissions.
      homeAccessPoint = new efs.AccessPoint(this, "HomeAccessPoint", {
        fileSystem: homeFs,
        posixUser: { uid: "0", gid: "0" },
        createAcl: { ownerUid: "0", ownerGid: "0", permissions: "755" },
        path: "/home",
      });

      if (enableParameterStore) {
        new ssm.StringParameter(this, "SsmEfsId", {
          parameterName: `/ood/${props.environment}/efs_id`,
          stringValue: homeFs.fileSystemId,
        });
        new ssm.StringParameter(this, "SsmEfsApId", {
          parameterName: `/ood/${props.environment}/efs_access_point_id`,
          stringValue: homeAccessPoint.accessPointId,
        });
      }
    }

    // --- S3 browser bucket ---
    let s3BrowserBucket: s3.Bucket | undefined;
    if (enableS3Browser) {
      s3BrowserBucket = new s3.Bucket(this, "FileBucket", {
        versioned: true,
        encryption: enableKmsCmk
          ? s3.BucketEncryption.KMS
          : s3.BucketEncryption.S3_MANAGED,
        encryptionKey: cmk,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        removalPolicy:
          props.environment === "prod"
            ? cdk.RemovalPolicy.RETAIN
            : cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: props.environment !== "prod",
        lifecycleRules: [
          {
            id: "transition-to-ia",
            enabled: true,
            transitions: [
              {
                storageClass: s3.StorageClass.INFREQUENT_ACCESS,
                transitionAfter: cdk.Duration.days(90),
              },
            ],
          },
        ],
      });
    }

    // --- Instance IAM Role ---
    const instanceRole = new iam.Role(this, "InstanceRole", {
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "AmazonSSMManagedInstanceCore"
        ),
      ],
    });

    // --- #78: AWS Directory Service — POSIX identity source for SSSD/NSS ---
    // Mirrors terraform/directory.tf. Managed directory (no servers/DB): Simple AD non-prod,
    // Managed Microsoft AD prod. The OOD host resolves users via SSSD/getpwnam against it, so
    // no login-time useradd is needed (the #77 fix). Default off until the cutover. Placed
    // after instanceRole so the admin secret can be granted to it.
    if (enableDirectory) {
      // >=2 subnets in different AZs are required (same constraint as the ALB).
      if (new Set(vpc.privateSubnets.map((s) => s.subnetId)).size < 2) {
        throw new Error(
          "enableDirectory requires at least 2 private subnets in different AZs (AWS Directory Service is multi-AZ)."
        );
      }
      const dirSubnetIds = vpc.privateSubnets.slice(0, 2).map((s) => s.subnetId);

      // Admin password (used only for the SSSD domain join) in Secrets Manager — fetched at
      // boot, never written to user_data. RETAIN in prod; DESTROY non-prod for clean teardown (#79).
      const dirAdminSecret = new secretsmanager.Secret(this, "DirectoryAdminSecret", {
        secretName: `ood/${props.environment}/directory-admin-password`,
        description: "#78: AWS Directory Service admin password (SSSD domain join)",
        encryptionKey: cmk,
        generateSecretString: {
          passwordLength: 32,
          excludeCharacters: ' "\'\\/@',
        },
        removalPolicy: prodProtected
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
      });

      const dirProps = {
        name: directoryName,
        password: dirAdminSecret.secretValue.unsafeUnwrap(),
        vpcSettings: { vpcId: vpc.vpcId, subnetIds: dirSubnetIds },
      };
      const directory = prodProtected
        ? new directoryservice.CfnMicrosoftAD(this, "Directory", {
            ...dirProps,
            edition: "Standard",
          })
        : new directoryservice.CfnSimpleAD(this, "Directory", {
            ...dirProps,
            size: "Small",
          });

      if (enableParameterStore) {
        new ssm.StringParameter(this, "SsmDirectoryName", {
          parameterName: `/ood/${props.environment}/directory_name`,
          stringValue: directoryName,
        });
        new ssm.StringParameter(this, "SsmDirectoryDnsIps", {
          parameterName: `/ood/${props.environment}/directory_dns_ips`,
          stringValue: cdk.Fn.join(",", directory.attrDnsIpAddresses),
        });
      }

      // The OOD instance role reads the admin password to perform the SSSD domain join.
      dirAdminSecret.grantRead(instanceRole);
    }

    // CloudWatch permissions — metrics to "*", log actions scoped to OOD log groups
    instanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: ["cloudwatch:PutMetricData"],
        resources: ["*"],
      })
    );
    instanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        actions: [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
          "logs:DescribeLogGroups",
        ],
        resources: [
          `arn:aws:logs:${this.region}:${this.account}:log-group:${logGroupPrefix}`,
          `arn:aws:logs:${this.region}:${this.account}:log-group:${logGroupPrefix}/*`,
          `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/ssm/ood-${props.environment}`,
          `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/ssm/ood-${props.environment}/*`,
        ],
      })
    );

    // SSM Parameter Store read
    if (enableParameterStore) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "ssm:GetParametersByPath",
            "ssm:GetParameter",
            "ssm:GetParameters",
          ],
          resources: [
            `arn:aws:ssm:${this.region}:${this.account}:parameter/ood/${props.environment}`,
            `arn:aws:ssm:${this.region}:${this.account}:parameter/ood/${props.environment}/*`,
          ],
        })
      );
    }

    // DynamoDB UID table access (explicit — no Scan, no DeleteItem: H1)
    if (enableDynamodbUid && uidTable) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "dynamodb:GetItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:Query",
            // DeleteItem intentionally omitted: UID mappings must not be deletable
            // by the portal instance to prevent identity erasure. Use the console
            // or a separate admin role for deprovisioning.
          ],
          resources: [uidTable.tableArn],
        })
      );
    }

    // EFS mount access (ClientMount + DescribeMountTargets for IAM auth DNS fallback)
    if (enableEfs && homeFs && homeAccessPoint) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "elasticfilesystem:ClientMount",
            "elasticfilesystem:ClientWrite",
            "elasticfilesystem:ClientRootAccess",
          ],
          resources: [homeFs.fileSystemArn],
          conditions: {
            StringEquals: {
              "elasticfilesystem:AccessPointArn": homeAccessPoint.accessPointArn,
            },
          },
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["elasticfilesystem:DescribeMountTargets"],
          resources: [homeFs.fileSystemArn],
        })
      );
    }

    // S3 browser access (explicit — no DeleteObject permission)
    if (enableS3Browser && s3BrowserBucket) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "s3:GetObject",
            "s3:PutObject",
            "s3:ListBucket",
            "s3:GetBucketLocation",
          ],
          resources: [
            s3BrowserBucket.bucketArn,
            `${s3BrowserBucket.bucketArn}/*`,
          ],
        })
      );
    }

    // Standing infra for adapters that need it (EMR Serverless app, ECS Fargate cluster).
    // Created before the adapter IAM blocks so those blocks can reference the ARNs.
    // Mirrors aws_emrserverless_application.ood / aws_ecs_cluster.ood in terraform/main.tf.
    let emrApp: emrserverless.CfnApplication | undefined;
    if (adaptersEnabled.includes("emr")) {
      emrApp = new emrserverless.CfnApplication(this, "EmrApp", {
        name: `ood-${props.environment}`,
        releaseLabel: "emr-7.0.0",
        type: "SPARK",
      });
      if (enableParameterStore) {
        new ssm.StringParameter(this, "EmrAppIdParam", {
          parameterName: `/ood/${props.environment}/emr_application_id`,
          stringValue: emrApp.attrApplicationId,
        });
      }
    }

    let fargateCluster: ecs.CfnCluster | undefined;
    if (adaptersEnabled.includes("fargate")) {
      fargateCluster = new ecs.CfnCluster(this, "FargateCluster", {
        clusterName: `ood-${props.environment}`,
        clusterSettings: [{ name: "containerInsights", value: "enabled" }],
      });
    }

    // Captured by the Batch / SageMaker adapter blocks below so the stack outputs can
    // reference their ARNs/IDs (mirrors the batch_job_queue_arn / sagemaker_domain_id
    // outputs in terraform/outputs.tf).
    let batchJobQueue: batch.JobQueue | undefined;
    let sagemakerDomain: sagemaker.CfnDomain | undefined;

    // Adapter IAM policies (mutating actions scoped, read-only to "*")
    if (adaptersEnabled.includes("batch")) {
      // Mutating: scoped to job queues and job definitions for this environment
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["batch:SubmitJob", "batch:TerminateJob"],
          resources: [
            `arn:aws:batch:${this.region}:${this.account}:job-queue/ood-${props.environment}*`,
            `arn:aws:batch:${this.region}:${this.account}:job-definition/ood-${props.environment}*`,
          ],
          // L6: prevent cross-region job submission
          conditions: { StringEquals: { "aws:RequestedRegion": this.region } },
        })
      );
      // Read-only: needs "*" for describe/list
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "batch:DescribeJobs",
            "batch:ListJobs",
            "batch:DescribeJobDefinitions",
            "batch:DescribeJobQueues",
          ],
          resources: ["*"],
          conditions: { StringEquals: { "aws:RequestedRegion": this.region } },
        })
      );
    }

    if (adaptersEnabled.includes("sagemaker")) {
      // Mutating: scoped to domains for this environment
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "sagemaker:CreateApp",
            "sagemaker:DeleteApp",
            "sagemaker:CreatePresignedDomainUrl",
          ],
          resources: [
            `arn:aws:sagemaker:${this.region}:${this.account}:domain/ood-${props.environment}*`,
          ],
          // L6: prevent cross-region SageMaker app creation
          conditions: { StringEquals: { "aws:RequestedRegion": this.region } },
        })
      );
      // Read-only: needs "*" for describe/list
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["sagemaker:DescribeApp", "sagemaker:ListApps"],
          resources: ["*"],
          conditions: { StringEquals: { "aws:RequestedRegion": this.region } },
        })
      );
    }

    if (adaptersEnabled.includes("ec2")) {
      // RunInstances: scoped to instances/subnets/security groups with project tag condition
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ec2:RunInstances"],
          resources: [
            `arn:aws:ec2:${this.region}:${this.account}:instance/*`,
            `arn:aws:ec2:${this.region}:${this.account}:subnet/*`,
            `arn:aws:ec2:${this.region}:${this.account}:security-group/*`,
            `arn:aws:ec2:${this.region}:${this.account}:network-interface/*`,
            `arn:aws:ec2:${this.region}:${this.account}:volume/*`,
            `arn:aws:ec2:${this.region}::image/*`,
          ],
          conditions: {
            StringEquals: { "aws:RequestedRegion": this.region },
          },
        })
      );
      // Terminate/tag: scoped to instances tagged with this project
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ec2:TerminateInstances", "ec2:CreateTags"],
          resources: [
            `arn:aws:ec2:${this.region}:${this.account}:instance/*`,
          ],
          conditions: {
            StringEquals: {
              "aws:ResourceTag/Project": `ood-${props.environment}`,
            },
          },
        })
      );
      // Read-only: needs "*"
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"],
          resources: ["*"],
        })
      );
    }

    // --- Omics adapter (mirror aws_iam_role_policy.omics_adapter) ---
    if (adaptersEnabled.includes("omics")) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["omics:StartRun", "omics:GetRun", "omics:CancelRun", "omics:ListRuns"],
          resources: ["*"],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["iam:PassRole"],
          resources: ["*"],
          conditions: { StringEquals: { "iam:PassedToService": "omics.amazonaws.com" } },
        })
      );
    }

    // --- Bedrock batch-inference adapter (mirror aws_iam_role_policy.bedrock_adapter) ---
    if (adaptersEnabled.includes("bedrock")) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "bedrock:CreateModelInvocationJob",
            "bedrock:GetModelInvocationJob",
            "bedrock:StopModelInvocationJob",
            "bedrock:ListModelInvocationJobs",
          ],
          resources: ["*"],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          // Bedrock assumes the passed role to read/write the S3 manifests; S3 access
          // lives on that role, not the instance role.
          actions: ["iam:PassRole"],
          resources: ["*"],
          conditions: { StringEquals: { "iam:PassedToService": "bedrock.amazonaws.com" } },
        })
      );
    }

    // --- router / burst meta-adapters (#6 / #5): intentionally NO IAM here. They are
    // dispatchers that shell out to the backend adapters; the AWS permissions come from
    // those backends' own policies (enable the backends in adaptersEnabled too). Mirrors
    // the Terraform side, which likewise adds no policy for router/burst. ---

    // --- EMR Serverless adapter (mirror aws_iam_role_policy.emr_adapter) ---
    if (adaptersEnabled.includes("emr") && emrApp) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "emr-serverless:StartJobRun",
            "emr-serverless:GetJobRun",
            "emr-serverless:CancelJobRun",
            "emr-serverless:ListJobRuns",
          ],
          resources: [emrApp.attrArn, `${emrApp.attrArn}/jobruns/*`],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["iam:PassRole"],
          resources: ["*"],
          conditions: { StringEquals: { "iam:PassedToService": "emr-serverless.amazonaws.com" } },
        })
      );
    }

    // --- SageMaker Training adapter (mirror aws_iam_role_policy.sagemaker_training_adapter) ---
    if (adaptersEnabled.includes("sagemaker-training")) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "sagemaker:CreateTrainingJob",
            "sagemaker:DescribeTrainingJob",
            "sagemaker:StopTrainingJob",
            "sagemaker:ListTrainingJobs",
          ],
          resources: [`arn:aws:sagemaker:${this.region}:${this.account}:training-job/ood-*`],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["iam:PassRole"],
          resources: ["*"],
          conditions: { StringEquals: { "iam:PassedToService": "sagemaker.amazonaws.com" } },
        })
      );
    }

    // --- Fargate adapter (mirror aws_iam_role_policy.fargate_adapter) ---
    if (adaptersEnabled.includes("fargate") && fargateCluster) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ecs:RunTask", "ecs:StopTask", "ecs:ListTasks"],
          resources: [
            fargateCluster.attrArn,
            `${fargateCluster.attrArn}/task/*`,
            `arn:aws:ecs:${this.region}:${this.account}:task-definition/*`,
          ],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["ecs:DescribeTasks"], // requires "*"
          resources: ["*"],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["iam:PassRole"],
          resources: ["*"],
          conditions: { StringEquals: { "iam:PassedToService": "ecs-tasks.amazonaws.com" } },
        })
      );
    }

    // --- Step Functions adapter (mirror aws_iam_role_policy.stepfunctions_adapter) ---
    if (adaptersEnabled.includes("stepfunctions")) {
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["states:StartExecution", "states:StopExecution", "states:ListExecutions"],
          resources: [`arn:aws:states:${this.region}:${this.account}:stateMachine:ood-*`],
        })
      );
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ["states:DescribeExecution"],
          resources: [`arn:aws:states:${this.region}:${this.account}:execution:ood-*:*`],
        })
      );
    }

    // --- Braket adapter (mirror aws_iam_role_policy.braket_adapter) ---
    if (adaptersEnabled.includes("braket")) {
      // Quantum-task lifecycle (task ARNs are server-assigned UUIDs under this account).
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          sid: "BraketQuantumTasks",
          actions: [
            "braket:CreateQuantumTask",
            "braket:GetQuantumTask",
            "braket:CancelQuantumTask",
            "braket:SearchQuantumTasks",
          ],
          resources: [`arn:aws:braket:${this.region}:${this.account}:quantum-task/*`],
        })
      );
      // Device discovery — QPUs/simulators are AWS-owned global resources, need "*".
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          sid: "BraketDevices",
          actions: ["braket:GetDevice", "braket:SearchDevices"],
          resources: ["*"],
        })
      );
      // Results bucket (scoped to the ood-* prefix, matching the S3 gateway endpoint).
      instanceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          sid: "BraketResultsS3",
          actions: ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
          resources: ["arn:aws:s3:::ood-*", "arn:aws:s3:::ood-*/*"],
        })
      );
    }

    // KMS grant for instance role
    if (enableKmsCmk && cmk) {
      cmk.grantEncryptDecrypt(instanceRole);
    }

    // --- Bootstrap artifact bucket ---
    // #16: EC2 user_data has a hard 16,384-byte limit; scripts/userdata.sh alone
    // is ~18 KB, so it cannot be inlined. Stage the bootstrap scripts in S3 and
    // carry only a tiny fetch-verify-exec stub in user_data. The "ood-" name
    // prefix is REQUIRED so the deployment works in no-egress / VPC-endpoint-only
    // setups (the S3 gateway endpoint policy scopes reachable buckets to ood-*).
    const scriptsDir = path.join(__dirname, "..", "..", "scripts");
    const sha256 = (file: string): string =>
      crypto
        .createHash("sha256")
        .update(fs.readFileSync(path.join(scriptsDir, file)))
        .digest("hex");
    const userdataSha = sha256("userdata.sh");
    const bakeSha = sha256("bake.sh");

    const artifactBucket = new s3.Bucket(this, "ArtifactBucket", {
      bucketName: `ood-artifacts-${props.environment}-${this.account}-${this.region}`,
      versioned: true,
      encryption: enableKmsCmk
        ? s3.BucketEncryption.KMS
        : s3.BucketEncryption.S3_MANAGED,
      encryptionKey: cmk,
      enforceSSL: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
    });

    // Upload the bootstrap scripts (CDK-native equivalent of aws_s3_object).
    // ood-provision-user.sh is included only when the UID map is enabled (#39), matching
    // the count-gated aws_s3_object.provision_user in Terraform.
    const scriptIncludes = ["**", "!userdata.sh", "!bake.sh"];
    if (enableDynamodbUid) scriptIncludes.push("!ood-provision-user.sh");
    new s3deploy.BucketDeployment(this, "ArtifactDeployment", {
      destinationBucket: artifactBucket,
      sources: [
        s3deploy.Source.asset(scriptsDir, {
          // Only ship the scripts the stub fetches — not the whole scripts dir.
          exclude: scriptIncludes,
        }),
      ],
      prune: false,
    });

    artifactBucket.grantRead(instanceRole);

    // --- User Data ---
    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      `export OOD_ENVIRONMENT="${props.environment}"`,
      `export OOD_DOMAIN="${domainName}"`,
      `export OOD_ENABLE_PARAMETER_STORE="${enableParameterStore}"`,
      `export OOD_ENABLE_MONITORING="${enableMonitoring}"`,
      `export OOD_ENABLE_ALB="${enableAlb}"`,
      `export OOD_ENABLE_EFS="${enableEfs}"`,
      `export OOD_EFS_ID="${homeFs ? homeFs.fileSystemId : ""}"`,
      `export OOD_EFS_ACCESS_POINT_ID="${homeAccessPoint ? homeAccessPoint.accessPointId : ""}"`,
      `export OOD_ENABLE_FSX="false"`,
      `export OOD_FSX_DNS_NAME=""`,
      `export OOD_FSX_MOUNT_NAME=""`,
      `export OOD_ENABLE_SESSION_CACHE="${enableSessionCache}"`,
      `export OOD_REDIS_ENDPOINT=""`,
      `export OOD_ENABLE_S3_BROWSER="${enableS3Browser}"`,
      `export OOD_S3_BROWSER_BUCKET="${s3BrowserBucket ? s3BrowserBucket.bucketName : ""}"`,
      `export OOD_ADAPTERS_ENABLED='${JSON.stringify(adaptersEnabled)}'`,
      `export OOD_LOG_GROUP_PREFIX="${logGroupPrefix}"`,
      `export OOD_ALB_DNS="${alb ? alb.loadBalancerDnsName : ""}"`, // #35
      `export OOD_OIDC_PAM_VERSION="${oidcPamVersion}"`,
      `export OOD_DYNAMODB_UID_TABLE="${uidTable ? uidTable.tableName : ""}"`,
      `export OOD_USE_SSSD="${this.node.tryGetContext("useSssd") === "true"}"`, // #78: directory-backed POSIX identity
      // #49: export (not bare assign) so the fetched userdata.sh child process inherits it.
      `export ARTIFACT_BUCKET="${artifactBucket.bucketName}"`,
      // Fetch-verify-exec from S3. The SHA256 is computed at synth time from the
      // exact file uploaded to the bucket, so verification is intrinsic — there
      // is no separate checksum file to drift, and a mismatch hard-fails the boot.
      // L1: with a pre-baked AMI, bake.sh was already applied at image build time.
      // UserData.forLinux() does not enable `set -e`, so each step fails explicitly.
      ...(enablePackerAmi
        ? ["# Baked AMI — bake.sh already applied at image build time"]
        : [
            `aws s3 cp "s3://$ARTIFACT_BUCKET/bake.sh" /tmp/bake.sh --region ${this.region} || { echo "bake.sh download failed" >&2; exit 1; }`,
            `echo "${bakeSha}  /tmp/bake.sh" | sha256sum -c - || { echo "bake.sh checksum mismatch" >&2; exit 1; }`,
            `bash /tmp/bake.sh`,
            `rm -f /tmp/bake.sh`,
          ]),
      `aws s3 cp "s3://$ARTIFACT_BUCKET/userdata.sh" /tmp/userdata.sh --region ${this.region} || { echo "userdata.sh download failed" >&2; exit 1; }`,
      `echo "${userdataSha}  /tmp/userdata.sh" | sha256sum -c - || { echo "userdata.sh checksum mismatch" >&2; exit 1; }`,
      `bash /tmp/userdata.sh`,
      `rm -f /tmp/userdata.sh`
    );

    // --- Launch Template ---
    const launchTemplate = new ec2.LaunchTemplate(this, "LaunchTemplate", {
      instanceType: new ec2.InstanceType(ec2InstanceType),
      machineImage: ami,
      securityGroup: sg,
      requireImdsv2: true,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(config.volumeSize, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
            kmsKey: cmk,
          }),
        },
      ],
      role: instanceRole,
      spotOptions: profile.useSpot
        ? { maxPrice: 0.20, requestType: ec2.SpotRequestType.ONE_TIME }
        : undefined,
    });

    // --- Auto Scaling Group ---
    const subnetSelection = subnetId
      ? { subnets: [ec2.Subnet.fromSubnetId(this, "PortalSubnet", subnetId)] }
      : { subnetType: ec2.SubnetType.PUBLIC };

    const asg = new autoscaling.AutoScalingGroup(this, "ASG", {
      vpc,
      vpcSubnets: subnetSelection,
      launchTemplate,
      minCapacity: 1,
      maxCapacity: 1,
      desiredCapacity: 1,
      healthCheck: enableAlb
        ? autoscaling.HealthCheck.elb({ grace: cdk.Duration.minutes(5) })
        : autoscaling.HealthCheck.ec2(),
      defaultInstanceWarmup: cdk.Duration.seconds(120), // L4: stabilize metrics before scale decisions
    });

    cdk.Tags.of(asg).add("Name", `ood-${props.environment}`);
    cdk.Tags.of(asg).add("Patch Group", `ood-${props.environment}`);

    // --- EBS DLM snapshot policy ---
    const dlmRole = new iam.Role(this, "DlmRole", {
      assumedBy: new iam.ServicePrincipal("dlm.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName(
          "service-role/AWSDataLifecycleManagerServiceRole"
        ),
      ],
    });

    new dlm.CfnLifecyclePolicy(this, "DlmPolicy", {
      description: `OOD ${props.environment} EBS snapshots`,
      executionRoleArn: dlmRole.roleArn,
      state: "ENABLED",
      policyDetails: {
        resourceTypes: ["INSTANCE"],
        schedules: [
          {
            name: "Daily snapshots",
            createRule: { interval: 24, intervalUnit: "HOURS", times: ["03:00"] },
            retainRule: {
              count: props.environment === "prod" ? 14 : 3,
            },
            tagsToAdd: [{ key: "SnapshotCreator", value: "DLM" }],
            copyTags: true,
          },
        ],
        targetTags: [
          { key: "Patch Group", value: `ood-${props.environment}` },
        ],
      },
    });

    // --- ALB listeners + ACM (the ALB itself + its SG were created above, before
    // user_data, so its DNS name is available as the OIDC servername/callback host). ---
    let albCertArn = acmCertificateArn;

    if (enableAlb && alb) {
      const targetGroup = new elbv2.ApplicationTargetGroup(
        this,
        "TargetGroup",
        {
          vpc,
          port: 80,
          protocol: elbv2.ApplicationProtocol.HTTP,
          targets: [asg],
          healthCheck: {
            path: "/pun/sys/dashboard",
            healthyThresholdCount: 2,
            unhealthyThresholdCount: 3,
            // #59: OIDC protects the dashboard, so an unauthenticated prober gets a
            // 302 (Cognito login) or 301 (OOD `/` rewrite), never a 200. Accept the
            // redirect codes — a 301/302 still proves Apache + the OIDC vhost are alive;
            // a dead instance returns 5xx. Mirrors the Terraform matcher "200,301,302".
            healthyHttpCodes: "200,301,302",
          },
        }
      );

      alb.addListener("HttpListener", {
        port: 80,
        defaultAction: elbv2.ListenerAction.redirect({
          port: "443",
          protocol: "HTTPS",
          permanent: true,
        }),
      });

      // Create ACM cert if domain is known but no cert ARN provided
      if (!albCertArn && domainName) {
        const cert = new acm.Certificate(this, "Cert", {
          domainName,
          validation: acm.CertificateValidation.fromDns(),
        });
        albCertArn = cert.certificateArn;
      }

      if (albCertArn) {
        alb.addListener("HttpsListener", {
          port: 443,
          protocol: elbv2.ApplicationProtocol.HTTPS,
          sslPolicy: elbv2.SslPolicy.TLS13_10,
          certificates: [
            elbv2.ListenerCertificate.fromArn(albCertArn),
          ],
          defaultTargetGroups: [targetGroup],
        });
      }
    }

    // --- WAF v2 ---
    if (enableWaf && alb) {
      const waf = new wafv2.CfnWebACL(this, "Waf", {
        name: `ood-${props.environment}`,
        scope: "REGIONAL",
        defaultAction: { allow: {} },
        rules: [
          {
            name: "RateLimit",
            priority: 0,
            action: { block: {} },
            statement: {
              rateBasedStatement: {
                limit: 2000,
                aggregateKeyType: "IP",
              },
            },
            visibilityConfig: {
              cloudWatchMetricsEnabled: true,
              metricName: "RateLimit",
              sampledRequestsEnabled: true,
            },
          },
          // M2: block IPs on the AWS threat intelligence list before other rules
          {
            name: "IpReputationList",
            priority: 1,
            overrideAction: { none: {} },
            statement: {
              managedRuleGroupStatement: {
                name: "AWSManagedRulesAmazonIpReputationList",
                vendorName: "AWS",
              },
            },
            visibilityConfig: {
              cloudWatchMetricsEnabled: true,
              metricName: "IpReputationList",
              sampledRequestsEnabled: true,
            },
          },
          {
            name: "CommonRuleSet",
            priority: 2,
            overrideAction: { none: {} },
            statement: {
              managedRuleGroupStatement: {
                name: "AWSManagedRulesCommonRuleSet",
                vendorName: "AWS",
              },
            },
            visibilityConfig: {
              cloudWatchMetricsEnabled: true,
              metricName: "CommonRuleSet",
              sampledRequestsEnabled: true,
            },
          },
          {
            name: "KnownBadInputs",
            priority: 3,
            overrideAction: { none: {} },
            statement: {
              managedRuleGroupStatement: {
                name: "AWSManagedRulesKnownBadInputsRuleSet",
                vendorName: "AWS",
              },
            },
            visibilityConfig: {
              cloudWatchMetricsEnabled: true,
              metricName: "KnownBadInputs",
              sampledRequestsEnabled: true,
            },
          },
          {
            name: "SQLiProtection",
            priority: 4,
            overrideAction: { none: {} },
            statement: {
              managedRuleGroupStatement: {
                name: "AWSManagedRulesSQLiRuleSet",
                vendorName: "AWS",
              },
            },
            visibilityConfig: {
              cloudWatchMetricsEnabled: true,
              metricName: "SQLiProtection",
              sampledRequestsEnabled: true,
            },
          },
        ],
        visibilityConfig: {
          cloudWatchMetricsEnabled: true,
          metricName: `ood-${props.environment}`,
          sampledRequestsEnabled: true,
        },
      });

      new wafv2.CfnWebACLAssociation(this, "WafAssoc", {
        resourceArn: alb.loadBalancerArn,
        webAclArn: waf.attrArn,
      });
    }

    // --- CloudFront CDN ---
    // M7: CloudFront WAF requires scope=CLOUDFRONT deployed in us-east-1.
    // Pass an existing WAF ACL ARN via context: -c cloudfrontWafArn=arn:aws:wafv2:us-east-1:...
    const cloudfrontWafArn: string =
      this.node.tryGetContext("cloudfrontWafArn") || "";

    if (enableCdn && alb) {
      // M1: S3 bucket for CloudFront access logs
      const cdnLogBucket = new s3.Bucket(this, "CdnLogBucket", {
        bucketName: undefined, // auto-generated
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        encryption: s3.BucketEncryption.S3_MANAGED,
        enforceSSL: true,
        objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_PREFERRED, // required for CF logging
        lifecycleRules: [
          {
            id: "expire-cdn-logs",
            enabled: true,
            expiration: cdk.Duration.days(
              props.environment === "prod" ? 365 : 90
            ),
          },
        ],
        // #79: env-aware (was unconditional RETAIN, which orphaned the bucket on test destroy).
        removalPolicy: prodProtected
          ? cdk.RemovalPolicy.RETAIN
          : cdk.RemovalPolicy.DESTROY,
        autoDeleteObjects: !prodProtected,
      });

      // L1: security response headers policy — HSTS, X-Frame-Options, content-type nosniff
      const securityHeadersPolicy = new cloudfront.ResponseHeadersPolicy(
        this,
        "SecurityHeaders",
        {
          securityHeadersBehavior: {
            strictTransportSecurity: {
              accessControlMaxAge: cdk.Duration.days(365),
              includeSubdomains: true,
              preload: true,
              override: true,
            },
            frameOptions: {
              frameOption: cloudfront.HeadersFrameOption.DENY,
              override: true,
            },
            contentTypeOptions: { override: true },
            referrerPolicy: {
              referrerPolicy:
                cloudfront.HeadersReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN,
              override: true,
            },
            xssProtection: {
              protection: true,
              modeBlock: true,
              override: true,
            },
          },
        }
      );

      new cloudfront.Distribution(this, "Cdn", {
        comment: `OOD ${props.environment} CDN`,
        webAclId: cloudfrontWafArn || undefined,
        logBucket: cdnLogBucket, // M1
        logFilePrefix: "cdn-logs/",
        logIncludesCookies: false,
        defaultBehavior: {
          origin: new cforigins.LoadBalancerV2Origin(alb, {
            protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
          }),
          viewerProtocolPolicy:
            cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          compress: true,
          responseHeadersPolicy: securityHeadersPolicy,
        },
        additionalBehaviors: {
          "/public/*": {
            origin: new cforigins.LoadBalancerV2Origin(alb, {
              protocolPolicy: cloudfront.OriginProtocolPolicy.HTTPS_ONLY,
            }),
            viewerProtocolPolicy:
              cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
            cachePolicy: cloudfront.CachePolicy.CACHING_OPTIMIZED,
            allowedMethods: cloudfront.AllowedMethods.ALLOW_GET_HEAD,
            compress: true,
            responseHeadersPolicy: securityHeadersPolicy,
          },
        },
      });
    }

    // --- CloudWatch monitoring ---
    let alarmTopic: sns.Topic | undefined;
    if (enableMonitoring) {
      for (const name of [
        "bootstrap",
        "nginx-access",
        "nginx-error",
        "passenger",
      ]) {
        new logs.LogGroup(this, `LogGroup-${name}`, {
          logGroupName: `${logGroupPrefix}/${name}`,
          retention: config.logRetention,
          removalPolicy: cdk.RemovalPolicy.DESTROY,
          encryptionKey: cmk, // H1: encrypt log data with CMK when enabled
        });
      }

      // M4: Always encrypt the alarm topic — use CMK when available, otherwise fall back to
      // the AWS-managed SNS key. Never leave alarm notifications unencrypted.
      const snsKey = cmk ?? kms.Alias.fromAliasName(this, "SnsManagedKey", "alias/aws/sns");
      alarmTopic = new sns.Topic(this, "AlarmTopic", {
        topicName: `ood-alarms-${props.environment}`,
        masterKey: snsKey,
      });
      if (alarmEmail) {
        alarmTopic.addSubscription(
          new snsSubscriptions.EmailSubscription(alarmEmail)
        );
      }

      const cpuAlarm = new cloudwatch.Alarm(this, "CpuAlarm", {
        alarmName: `ood-${props.environment}-cpu-high`,
        metric: new cloudwatch.Metric({
          namespace: "AWS/EC2",
          metricName: "CPUUtilization",
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName },
          period: cdk.Duration.seconds(
            props.environment === "prod" ? 60 : 300
          ),
          statistic: "Average",
        }),
        threshold: props.environment === "prod" ? 70 : 80,
        evaluationPeriods: props.environment === "prod" ? 3 : 2,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        alarmDescription: `OOD ${props.environment} CPU > threshold`,
        treatMissingData: cloudwatch.TreatMissingData.BREACHING, // M7
      });
      cpuAlarm.addAlarmAction(
        new cloudwatchActions.SnsAction(alarmTopic)
      );

      const statusAlarm = new cloudwatch.Alarm(this, "StatusAlarm", {
        alarmName: `ood-${props.environment}-instance-status`,
        metric: new cloudwatch.Metric({
          namespace: "AWS/EC2",
          metricName: "StatusCheckFailed",
          dimensionsMap: { AutoScalingGroupName: asg.autoScalingGroupName },
          period: cdk.Duration.seconds(60),
          statistic: "Maximum",
        }),
        threshold: 0,
        evaluationPeriods: 2,
        comparisonOperator:
          cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
        alarmDescription: `OOD ${props.environment} instance status check`,
        treatMissingData: cloudwatch.TreatMissingData.BREACHING, // M7
      });
      statusAlarm.addAlarmAction(
        new cloudwatchActions.SnsAction(alarmTopic)
      );

      // #22: CloudWatch dashboard — mirrors aws_cloudwatch_dashboard.ood in
      // terraform/main.tf. CPU widget always present (12x6 at 0,0); EFS ClientConnections
      // widget (12x6 at 12,0) only when EFS is enabled. Every widget must declare region
      // and explicit x/y/width/height or PutDashboard rejects the body (400).
      const dashboardWidgets: object[] = [
        {
          type: "metric",
          x: 0,
          y: 0,
          width: 12,
          height: 6,
          properties: {
            title: "CPU Utilization",
            region: this.region,
            period: 300,
            stat: "Average",
            metrics: [
              [
                "AWS/EC2",
                "CPUUtilization",
                "AutoScalingGroupName",
                asg.autoScalingGroupName,
              ],
            ],
          },
        },
      ];
      if (enableEfs && homeFs) {
        dashboardWidgets.push({
          type: "metric",
          x: 12,
          y: 0,
          width: 12,
          height: 6,
          properties: {
            title: "EFS Client Connections",
            region: this.region,
            period: 300,
            stat: "Average",
            metrics: [
              ["AWS/EFS", "ClientConnections", "FileSystemId", homeFs.fileSystemId],
            ],
          },
        });
      }
      new cloudwatch.CfnDashboard(this, "Dashboard", {
        dashboardName: `ood-${props.environment}`,
        dashboardBody: JSON.stringify({ widgets: dashboardWidgets }),
      });
    }

    // --- AWS Batch (adapter) ---
    if (adaptersEnabled.includes("batch")) {
      const batchServiceRole = new iam.Role(this, "BatchServiceRole", {
        assumedBy: new iam.ServicePrincipal("batch.amazonaws.com"),
        managedPolicies: [
          iam.ManagedPolicy.fromAwsManagedPolicyName(
            "service-role/AWSBatchServiceRole"
          ),
        ],
      });
      // #79: AWSBatchServiceRole lacks the ECS actions Batch needs to tear down a managed
      // CE's underlying ECS cluster; without them the CE goes INVALID on destroy and can't be
      // deleted (orphan + blocked teardown). Mirrors the Terraform batch_service_ecs_teardown.
      batchServiceRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "ecs:ListClusters",
            "ecs:DescribeClusters",
            "ecs:ListContainerInstances",
            "ecs:DescribeContainerInstances",
            "ecs:DeleteCluster",
            "ecs:DeregisterContainerInstance",
            "ecs:UpdateContainerInstancesState",
          ],
          resources: ["*"],
        })
      );

      // H4: explicit instance family list prevents Batch from selecting
      // expensive families (x2iezn, z1d, etc.) when using "optimal"
      const computeEnv = new batch.ManagedEc2EcsComputeEnvironment(
        this,
        "BatchCompute",
        {
          vpc,
          vpcSubnets: { subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS },
          securityGroups: [sg],
          spot: true,
          spotBidPercentage: 60,
          maxvCpus: 256,
          instanceTypes: [
            ec2.InstanceType.of(ec2.InstanceClass.M5, ec2.InstanceSize.XLARGE),
            ec2.InstanceType.of(ec2.InstanceClass.M5, ec2.InstanceSize.XLARGE2),
            ec2.InstanceType.of(ec2.InstanceClass.M5A, ec2.InstanceSize.XLARGE),
            ec2.InstanceType.of(ec2.InstanceClass.M5A, ec2.InstanceSize.XLARGE2),
            ec2.InstanceType.of(ec2.InstanceClass.M6I, ec2.InstanceSize.XLARGE),
            ec2.InstanceType.of(ec2.InstanceClass.M6I, ec2.InstanceSize.XLARGE2),
          ],
          serviceRole: batchServiceRole,
        }
      );

      batchJobQueue = new batch.JobQueue(this, "BatchQueue", {
        jobQueueName: `ood-${props.environment}`,
        computeEnvironments: [
          { computeEnvironment: computeEnv, order: 1 },
        ],
      });
    }

    // --- SageMaker Domain (adapter) ---
    if (adaptersEnabled.includes("sagemaker")) {
      // C2: scoped policy instead of AmazonSageMakerFullAccess (which grants admin-level access)
      const smRole = new iam.Role(this, "SageMakerExecRole", {
        assumedBy: new iam.ServicePrincipal("sagemaker.amazonaws.com"),
      });
      smRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "sagemaker:CreateApp",
            "sagemaker:DeleteApp",
            "sagemaker:DescribeApp",
            "sagemaker:ListApps",
            "sagemaker:CreatePresignedDomainUrl",
            "sagemaker:DescribeDomain",
            "sagemaker:DescribeUserProfile",
          ],
          resources: [
            `arn:aws:sagemaker:${this.region}:${this.account}:domain/*`,
            `arn:aws:sagemaker:${this.region}:${this.account}:app/*`,
            `arn:aws:sagemaker:${this.region}:${this.account}:user-profile/*`,
          ],
        })
      );
      smRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ],
          resources: [
            `arn:aws:logs:${this.region}:${this.account}:log-group:/aws/sagemaker/*`,
          ],
        })
      );
      smRole.addToPrincipalPolicy(
        new iam.PolicyStatement({
          // H2: DeleteObject omitted — SageMaker jobs should not delete input/output data.
          // Lifecycle management is handled by the SageMaker domain admin, not notebook code.
          actions: ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
          resources: [
            `arn:aws:s3:::sagemaker-${this.region}-${this.account}`,
            `arn:aws:s3:::sagemaker-${this.region}-${this.account}/*`,
          ],
        })
      );

      sagemakerDomain = new sagemaker.CfnDomain(this, "SageMakerDomain", {
        domainName: `ood-${props.environment}`,
        authMode: "IAM",
        vpcId: vpc.vpcId,
        subnetIds: vpc.privateSubnets.map((s) => s.subnetId),
        defaultUserSettings: {
          executionRole: smRole.roleArn,
        },
      });
    }

    // --- Stack Outputs ---
    new cdk.CfnOutput(this, "WebUrl", {
      description: "OOD portal URL",
      value: enableCdn && alb
        ? `https://(see CloudFront domain)`
        : enableAlb && alb && domainName
        ? `https://${domainName}`
        : enableAlb && alb
        ? `https://${alb.loadBalancerDnsName}`
        : domainName
        ? `https://${domainName}`
        : "(no public URL — use SSM to connect)",
    });

    new cdk.CfnOutput(this, "SsmConnectCommand", {
      description: "Connect via SSM Session Manager",
      value: `aws ec2 describe-instances --filters 'Name=tag:aws:autoscaling:groupName,Values=${asg.autoScalingGroupName}' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text | xargs -I{} aws ssm start-session --target {}`,
    });

    if (userPool) {
      new cdk.CfnOutput(this, "CognitoUserPoolId", {
        value: userPool.userPoolId,
        description: "Cognito User Pool ID",
      });
    }

    if (uidTable) {
      new cdk.CfnOutput(this, "UidTableName", {
        value: uidTable.tableName,
        description: "DynamoDB UID mapping table",
      });
    }

    if (homeFs) {
      new cdk.CfnOutput(this, "EfsId", {
        value: homeFs.fileSystemId,
        description: "EFS /home file system ID",
      });
    }

    if (alarmTopic) {
      new cdk.CfnOutput(this, "AlarmTopicArn", {
        value: alarmTopic.topicArn,
        description: "CloudWatch alarm SNS topic",
      });
    }

    // Adapter / infra outputs — parity with terraform/outputs.tf. Each is guarded by the
    // same condition that creates the underlying resource. (CfnOutput has no `sensitive`
    // flag; the TF `sensitive = true` markers are state-display masks with no CFN analogue.)
    new cdk.CfnOutput(this, "ArtifactsBucket", {
      value: artifactBucket.bucketName,
      description:
        "Bootstrap artifacts bucket — stage adapter binaries / app bundles here under a prefix (see docs/adapter-guide.md)",
    });

    if (batchJobQueue) {
      new cdk.CfnOutput(this, "BatchJobQueueArn", {
        value: batchJobQueue.jobQueueArn,
        description: "AWS Batch job queue ARN (Batch adapter)",
      });
    }

    if (sagemakerDomain) {
      new cdk.CfnOutput(this, "SageMakerDomainId", {
        value: sagemakerDomain.attrDomainId,
        description: "SageMaker Domain ID (SageMaker adapter)",
      });
    }

    if (emrApp) {
      new cdk.CfnOutput(this, "EmrApplicationId", {
        value: emrApp.attrApplicationId,
        description: "EMR Serverless application ID (EMR adapter)",
      });
    }

    if (fargateCluster) {
      new cdk.CfnOutput(this, "EcsClusterArn", {
        value: fargateCluster.attrArn,
        description: "ECS cluster ARN for Fargate workloads (Fargate adapter)",
      });
    }
  }
}
