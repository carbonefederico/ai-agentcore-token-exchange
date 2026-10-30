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
    // The secretless client assertion is the AWS-issued IAM identity JWT. The
    // runtime role itself calls sts:GetWebIdentityToken (audience = the PF
    // token endpoint), so AgentCore Identity can mint the actor token.
    runtime.addToPolicy(new iam.PolicyStatement({
      sid: 'StsIdentityToken',
      actions: ['sts:GetWebIdentityToken'],
      resources: [`arn:aws:sts::${ACCOUNT}:self`],
      conditions: {
        ForAllValuesStringEquals: {
          'sts:IdentityTokenAudience': 'https://ai-agentcore-token-exchange-pingfederate-engine.ping-devops.com/as/token.oauth2',
        },
        NumericLessThanEquals: { 'sts:DurationSeconds': 300 },
      },
    }));
  }
}
