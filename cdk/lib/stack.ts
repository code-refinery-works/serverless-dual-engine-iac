import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as apigwv2 from "aws-cdk-lib/aws-apigatewayv2";
import * as integrations from "aws-cdk-lib/aws-apigatewayv2-integrations";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as ssm from "aws-cdk-lib/aws-ssm";
import * as kms from "aws-cdk-lib/aws-kms";
import { Construct } from "constructs";

interface Props extends cdk.StackProps { project: string; }

export class ServerlessApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: Props) {
    super(scope, id, props);
    const { project } = props;

    // ── SSM Lookup: Terraform管理リソース参照 ─────────────────────────────
    const tableArn  = ssm.StringParameter.valueFromLookup(this, `/app/${project}/dynamodb/table_arn`);
    const tableName = ssm.StringParameter.valueFromLookup(this, `/app/${project}/dynamodb/table_name`);
    const kmsArn    = ssm.StringParameter.valueFromLookup(this, `/app/${project}/kms/key_arn`);
    const kmsKey    = kms.Key.fromKeyArn(this, "DdbKmsKey", kmsArn);

    // ── Lambda 実行ロール (最小権限) ──────────────────────────────────────
    const execRole = new iam.Role(this, "LambdaExecRole", {
      assumedBy: new iam.ServicePrincipal("lambda.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("service-role/AWSLambdaBasicExecutionRole"),
        iam.ManagedPolicy.fromAwsManagedPolicyName("AWSXRayDaemonWriteAccess"),
      ],
      inlinePolicies: {
        DynamoDBAccess: new iam.PolicyDocument({
          statements: [
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem",
                        "dynamodb:DeleteItem","dynamodb:Query"],
              resources: [tableArn, `${tableArn}/index/*`],
            }),
            new iam.PolicyStatement({
              effect: iam.Effect.ALLOW,
              actions: ["kms:Decrypt","kms:GenerateDataKey"],
              resources: [kmsKey.keyArn],
            }),
          ],
        }),
      },
    });

    // ── Lambda 関数 ───────────────────────────────────────────────────────
    const logGroup = new logs.LogGroup(this, "LambdaLogGroup", {
      logGroupName: `/aws/lambda/${project}-api`,
      retention: logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    const handler = new lambda.Function(this, "ApiHandler", {
      functionName: `${project}-api`,
      runtime: lambda.Runtime.NODEJS_20_X,
      architecture: lambda.Architecture.ARM_64,
      handler: "index.handler",
      code: lambda.Code.fromInline(`
exports.handler = async (event) => {
  const method = event.requestContext?.http?.method ?? 'GET';
  const path   = event.requestContext?.http?.path ?? '/';
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: 'ok', method, path,
      table: process.env.TABLE_NAME }),
  };
};`),
      role: execRole,
      logGroup,
      tracing: lambda.Tracing.ACTIVE,
      reservedConcurrentExecutions: 10,
      timeout: cdk.Duration.seconds(29),
      environment: { TABLE_NAME: tableName, PROJECT: project },
    });

    // ── API Gateway HTTP API ───────────────────────────────────────────────
    const integration = new integrations.HttpLambdaIntegration("LambdaInteg", handler);

    const httpApi = new apigwv2.HttpApi(this, "HttpApi", {
      apiName: `${project}-http-api`,
      corsPreflight: {
        allowHeaders: ["Content-Type","Authorization"],
        allowMethods: [apigwv2.CorsHttpMethod.GET, apigwv2.CorsHttpMethod.POST,
                       apigwv2.CorsHttpMethod.PUT, apigwv2.CorsHttpMethod.DELETE],
        allowOrigins: ["*"],
        maxAge: cdk.Duration.days(1),
      },
      defaultAuthorizer: undefined, // JWT authorizer: attach per-route as needed
    });

    httpApi.addRoutes({ path: "/{proxy+}", methods: [apigwv2.HttpMethod.ANY], integration });
    httpApi.addRoutes({ path: "/",         methods: [apigwv2.HttpMethod.ANY], integration });

    // ── Throttling (Default Stage) ────────────────────────────────────────
    const stage = httpApi.defaultStage?.node.defaultChild as apigwv2.CfnStage;
    if (stage) {
      stage.defaultRouteSettings = {
        throttlingBurstLimit: 5000,
        throttlingRateLimit:  10000,
      };
    }

    // ── Outputs ───────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, "ApiEndpoint",   { value: httpApi.apiEndpoint });
    new cdk.CfnOutput(this, "FunctionArn",   { value: handler.functionArn });
    new cdk.CfnOutput(this, "FunctionName",  { value: handler.functionName });
  }
}