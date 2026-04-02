import boto3

sns = boto3.client('sns')

TOPIC_ARN = "YOUR_SNS_TOPIC"

def lambda_handler(event, context):

    sns.publish(
        TopicArn=TOPIC_ARN,
        Message=f"High severity incident: {event}"
    )

    return event