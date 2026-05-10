#!/usr/bin/env python3
"""Send sample orders from data/sample_orders.json to Kinesis."""
import argparse
import json
import os
import time
import boto3

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLE_FILE = os.path.join(BASE_DIR, 'data', 'sample_orders.json')


def main():
    parser = argparse.ArgumentParser(description='Send sample orders to Kinesis')
    parser.add_argument('--stream', required=True, help='Kinesis stream name')
    parser.add_argument('--region', default='us-east-1', help='AWS region')
    parser.add_argument('--delay', type=float, default=0.5, help='Delay between records (sec)')
    args = parser.parse_args()

    client = boto3.client('kinesis', region_name=args.region)

    with open(SAMPLE_FILE) as f:
        orders = [json.loads(line) for line in f if line.strip()]

    print(f"Sending {len(orders)} orders to stream '{args.stream}'...")
    for i, order in enumerate(orders, 1):
        client.put_record(
            StreamName=args.stream,
            Data=(json.dumps(order) + '\n').encode('utf-8'),
            PartitionKey=order['order_id']
        )
        print(f"  [{i:02d}/{len(orders)}] Sent {order['order_id']} ({order['region']})")
        time.sleep(args.delay)

    print(f"\nDone. {len(orders)} records sent.")


if __name__ == '__main__':
    main()
