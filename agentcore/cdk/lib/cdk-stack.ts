import { AgentCoreApplication, type AgentCoreApplicationProps } from '@aws/agentcore-cdk';
import { Stack, type StackProps } from 'aws-cdk-lib';
import { aws_iam as iam } from 'aws-cdk-lib';
import { Construct } from 'constructs';

export interface AgentCoreStackProps extends StackProps {
  /** Props for the AgentCore application, produced by transformAgentCoreJson from agentcore/agentcore.json. */
  application: AgentCoreApplicationProps;
}

const ACCOUNT = '574076504146';
const REGION = 'eu-central-1';

/**
 * The stack the AgentCore CLI deploys. Everything declared in agentcore/agentcore.json is
 * created by the AgentCoreApplication construct. Add your own resources below it and wire
 * them to your runtimes and harnesses through the application's accessors.
 */
export class AgentCoreStack extends Stack {
  public readonly application: AgentCoreApplication;

  constructor(scope: Construct, id: string, props: AgentCoreStackProps) {
    super(scope, id, props);
    this.application = new AgentCoreApplication(this, 'Application', props.application);

    // The exchange agent calls GetResourceOauth2Token against the secretless
    // credential provider "pingfederate-obo-poc" (client auth + actor token are
    // both the AWS-issued IAM identity JWT — no secrets anywhere).
    const runtime = this.application.runtime('exchange_agent');
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'WorkloadAccessToken',
      actions: [
        'bedrock-agentcore:GetWorkloadAccessToken',
        'bedrock-agentcore:GetWorkloadAccessTokenForJWT',
        'bedrock-agentcore:GetWorkloadAccessTokenForUserId',
      ],
      resources: [
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default`,
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default/workload-identity/*`,
      ],
    }));
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'ResourceOauth2Token',
      actions: ['bedrock-agentcore:GetResourceOauth2Token'],
      resources: [
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:token-vault/default`,
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:token-vault/default/oauth2credentialprovider/pingfederate-obo-poc`,
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default`,
        `arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT}:workload-identity-directory/default/workload-identity/*`,
      ],
    }));
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'CredentialProviderSecret',
      actions: ['secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret'],
      resources: [
        `arn:aws:secretsmanager:${REGION}:${ACCOUNT}:secret:bedrock-agentcore-identity!default/oauth2/pingfederate-obo-poc*`,
      ],
    }));
    // AgentCore Identity mints the client assertion / actor token (an AWS IAM
    // identity JWT) on behalf of this role - the role needs sts:GetWebIdentityToken.
    // NOTE: Resource '*' is required; the API does not honor the 'self'
    // pseudo-resource in identity policies (verified 2026-10-30).
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'StsIdentityToken',
      actions: ['sts:GetWebIdentityToken'],
      resources: ['*'],
      conditions: {
        StringEquals: {
          'sts:IdentityTokenAudience': 'https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com/as/token.oauth2',
        },
        NumericLessThanEquals: { 'sts:DurationSeconds': 300 },
      },
    }));
    // The provider's private_key_jwt client authentication signs the client
    // assertion with this KMS key (AgentCore Identity calls kms:Sign using the
    // runtime role's credentials).
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'KmsSignClientAssertion',
      actions: ['kms:Sign', 'kms:DescribeKey'],
      resources: ['arn:aws:kms:eu-central-1:574076504146:key/5ef87a2b-677a-40b3-b811-61bb2684c68a'],
    }));
  }
}
