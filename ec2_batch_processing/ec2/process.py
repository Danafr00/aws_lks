import boto3
import psycopg2
import csv

S3_BUCKET = "student-score-bucket"

DB_CONFIG = {
    "host": "YOUR_RDS_ENDPOINT",
    "database": "postgres",
    "user": "postgres",
    "password": "password123"
}

def get_latest_file():
    s3 = boto3.client('s3')

    response = s3.list_objects_v2(Bucket=S3_BUCKET)

    if 'Contents' not in response:
        print("No file found")
        return None

    latest_file = response['Contents'][-1]['Key']
    return latest_file


def download_file(key):
    s3 = boto3.client('s3')
    local_path = "/tmp/data.csv"
    s3.download_file(S3_BUCKET, key, local_path)
    return local_path


def process_file(file_path):
    conn = psycopg2.connect(**DB_CONFIG)
    cursor = conn.cursor()

    with open(file_path, 'r') as f:
        reader = csv.DictReader(f)

        for row in reader:
            score = int(row['score'])

            status = "PASS" if score >= 75 else "FAIL"

            cursor.execute("""
                INSERT INTO student_scores (student_name, subject, score, status)
                VALUES (%s, %s, %s, %s)
            """, (
                row['name'],
                row['subject'],
                score,
                status
            ))

    conn.commit()
    cursor.close()
    conn.close()


def main():
    key = get_latest_file()

    if key:
        file_path = download_file(key)
        process_file(file_path)


if __name__ == "__main__":
    main()