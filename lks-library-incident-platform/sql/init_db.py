"""Create the tables from schema.sql (same folder). Needs DB_HOST, DB_USER, DB_PASS, DB_NAME in the environment."""
import os
import pathlib

import pymysql

schema = (pathlib.Path(__file__).resolve().parent / "schema.sql").read_text()
conn = pymysql.connect(host=os.environ["DB_HOST"], user=os.environ["DB_USER"], password=os.environ["DB_PASS"],
                       database=os.environ["DB_NAME"], connect_timeout=10)
with conn.cursor() as cursor:
    for statement in schema.split(";"):
        if statement.strip():
            cursor.execute(statement)
conn.commit()
with conn.cursor() as cursor:
    cursor.execute("SHOW TABLES")
    print("tables:", [row[0] for row in cursor.fetchall()])
conn.close()
