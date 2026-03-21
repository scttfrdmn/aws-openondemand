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
import * as s3 from "aws-cdk-lib/aws-s3";
import { Construct } from "constructs";

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
    const alarmEmail: string =
      this.node.tryGetContext("alarmEmail") || "";
    const adaptersEnabled: string[] =
      this.node.tryGetContext("adaptersEnabled") || [];
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
        removalPolicy: cdk.RemovalPolicy.RETAIN, // M10: always RETAIN — pool contains all user identities
      });

      const callbackUrl =
        domainName !== ""
          ? `https://${domainName}/oidc/callback`
          : "https://localhost/oidc/callback";

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
          logoutUrls: [
            domainName !== "" ? `https://${domainName}` : "https://localhost",
          ],
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
      }
    }

    // --- DynamoDB UID mapping ---
    let uidTable: dynamodb.Table | undefined;
    if (enableDynamodbUid) {
      uidTable = new dynamodb.Table(this, "UidMap", {
        tableName: `oid-uid-map-${props.environment}`,
        partitionKey: { name: "oidc_sub", type: dynamodb.AttributeType.STRING },
        billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
        pointInTimeRecovery: true,
        encryption: enableKmsCmk
          ? dynamodb.TableEncryption.CUSTOMER_MANAGED
          : dynamodb.TableEncryption.AWS_MANAGED,
        encryptionKey: cmk,
        removalPolicy:
          props.environment === "prod"
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

    // KMS grant for instance role
    if (enableKmsCmk && cmk) {
      cmk.grantEncryptDecrypt(instanceRole);
    }

    // --- User Data ---
    const userData = ec2.UserData.forLinux();
    // C1: Pin to a commit SHA for production deployments to prevent supply chain attacks.
    // Usage: cdk deploy -c scriptsBranch=<40-char-sha>
    // Using "main" is acceptable for development but MUST NOT be used in prod.
    const scriptsBranch =
      this.node.tryGetContext("scriptsBranch") || "main";
    const isSha = /^[a-f0-9]{40}$/.test(scriptsBranch);
    if (!isSha && props.environment !== "test") {
      throw new Error(
        `scriptsBranch must be a full commit SHA (40 hex chars) for ${props.environment} deployments. ` +
          `Got: "${scriptsBranch}". Using a mutable branch ref is a supply chain risk.`
      );
    }
    const baseUrl = `https://raw.githubusercontent.com/scttfrdmn/aws-openondemand/${scriptsBranch}/scripts`;

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
      // H3: download-then-verify-then-run instead of curl|bash to prevent
      // truncated-download execution and enable SHA verification.
      // L1: when enablePackerAmi=true, scriptsBranch is only used for userdata.sh (not bake.sh).
      // The bake.sh was already applied at AMI build time from the commit SHA recorded in the AMI tags.
      ...(enablePackerAmi
        ? ["# Baked AMI — bake.sh already applied at image build time"]
        : [
            `curl -fsSL "${baseUrl}/bake.sh" -o /tmp/bake.sh`,
            `curl -fsSL "${baseUrl}/bake.sh.sha256" -o /tmp/bake.sh.sha256 || true`,
            `if [ -s /tmp/bake.sh.sha256 ]; then sha256sum -c /tmp/bake.sh.sha256 || { echo "bake.sh checksum mismatch" >&2; exit 1; }; fi`,
            `bash /tmp/bake.sh`,
            `rm -f /tmp/bake.sh /tmp/bake.sh.sha256`,
          ]),
      `curl -fsSL "${baseUrl}/userdata.sh" -o /tmp/userdata.sh`,
      `curl -fsSL "${baseUrl}/userdata.sh.sha256" -o /tmp/userdata.sh.sha256 || true`,
      `if [ -s /tmp/userdata.sh.sha256 ]; then sha256sum -c /tmp/userdata.sh.sha256 || { echo "userdata.sh checksum mismatch" >&2; exit 1; }; fi`,
      `bash /tmp/userdata.sh`,
      `rm -f /tmp/userdata.sh /tmp/userdata.sh.sha256`
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

    // --- ALB + ACM ---
    let alb: elbv2.ApplicationLoadBalancer | undefined;
    let albCertArn = acmCertificateArn;

    if (enableAlb) {
      const albSg = new ec2.SecurityGroup(this, "AlbSG", {
        vpc,
        description: `OOD ALB ${props.environment}`,
        allowAllOutbound: false,
      });
      for (const port of [80, 443]) {
        albSg.addIngressRule(
          ec2.Peer.ipv4(allowedCidr),
          ec2.Port.tcp(port),
          `ALB port ${port}`
        );
      }
      albSg.addEgressRule(sg, ec2.Port.tcp(80), "To EC2 HTTP");
      sg.addIngressRule(albSg, ec2.Port.tcp(80), "HTTP from ALB");

      alb = new elbv2.ApplicationLoadBalancer(this, "ALB", {
        vpc,
        internetFacing: true,
        securityGroup: albSg,
        deletionProtection: props.environment !== "test",
      });

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
        removalPolicy: cdk.RemovalPolicy.RETAIN,
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

      new batch.JobQueue(this, "BatchQueue", {
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

      new sagemaker.CfnDomain(this, "SageMakerDomain", {
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
  }
}
