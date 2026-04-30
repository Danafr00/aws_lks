import json
import boto3
import os

ENDPOINT_NAME = os.environ['SAGEMAKER_ENDPOINT_NAME']
REGION = os.environ.get('AWS_REGION', 'ap-southeast-1')

runtime = boto3.client('sagemaker-runtime', region_name=REGION)

# Feature order MUST match training CSV columns (after the label column).
# Train CSV: default,age,annual_income,loan_amount,loan_term_months,
#            credit_score,employment_years,debt_to_income_ratio,
#            has_mortgage,num_credit_lines,num_late_payments
FEATURE_KEYS = [
    'age', 'annual_income', 'loan_amount', 'loan_term_months',
    'credit_score', 'employment_years', 'debt_to_income_ratio',
    'has_mortgage', 'num_credit_lines', 'num_late_payments',
]

CORS = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
}


def handler(event, context):
    # Support both REST API (httpMethod) and HTTP API v2 (requestContext.http.method)
    method = (
        event.get('requestContext', {}).get('http', {}).get('method')
        or event.get('httpMethod', 'POST')
    ).upper()

    if method == 'OPTIONS':
        return {'statusCode': 200, 'headers': CORS, 'body': ''}

    try:
        body = event.get('body') or '{}'
        if event.get('isBase64Encoded', False):
            import base64
            body = base64.b64decode(body).decode('utf-8')

        data = json.loads(body)
        features = [data[k] for k in FEATURE_KEYS]
        csv_payload = ','.join(str(f) for f in features)

        resp = runtime.invoke_endpoint(
            EndpointName=ENDPOINT_NAME,
            ContentType='text/csv',
            Body=csv_payload,
        )
        probability = float(resp['Body'].read().decode().strip())

        if probability < 0.30:
            risk_level = 'LOW'
            recommendation = 'Approved — Standard loan terms apply'
        elif probability < 0.55:
            risk_level = 'MEDIUM'
            recommendation = 'Conditional Approval — Additional review required'
        else:
            risk_level = 'HIGH'
            recommendation = 'Rejected — Default risk exceeds acceptance threshold'

        return {
            'statusCode': 200,
            'headers': {**CORS, 'Content-Type': 'application/json'},
            'body': json.dumps({
                'probability': round(probability * 100, 1),
                'risk_level': risk_level,
                'recommendation': recommendation,
            }),
        }

    except KeyError as exc:
        return {
            'statusCode': 400,
            'headers': {**CORS, 'Content-Type': 'application/json'},
            'body': json.dumps({'error': f'Missing field: {exc}'}),
        }
    except Exception as exc:
        return {
            'statusCode': 500,
            'headers': {**CORS, 'Content-Type': 'application/json'},
            'body': json.dumps({'error': str(exc)}),
        }
