import json
import os
import uuid
import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    path = event.get("rawPath", "")

    try:
        if method == "POST" and path == "/items":
            return create_item(event)
        elif method == "GET" and path.startswith("/items/"):
            item_id = path.split("/items/")[1]
            return get_item(item_id)
        elif method == "DELETE" and path.startswith("/items/"):
            item_id = path.split("/items/")[1]
            return delete_item(item_id)
        elif method == "GET" and path == "/items":
            return list_items()
        else:
            return response(404, {"error": "Not found"})
    except Exception as e:
        return response(500, {"error": str(e)})


def create_item(event):
    body = json.loads(event.get("body", "{}"))
    item_id = str(uuid.uuid4())
    item = {"id": item_id, **body}
    table.put_item(Item=item)
    return response(201, item)


def get_item(item_id):
    result = table.get_item(Key={"id": item_id})
    item = result.get("Item")
    if not item:
        return response(404, {"error": "Item not found"})
    return response(200, item)


def delete_item(item_id):
    table.delete_item(Key={"id": item_id})
    return response(200, {"deleted": item_id})


def list_items():
    result = table.scan(Limit=50)
    return response(200, {"items": result.get("Items", [])})


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }
