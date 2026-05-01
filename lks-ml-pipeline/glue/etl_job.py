import sys
from datetime import datetime

from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.context import SparkContext
from pyspark.sql import functions as F
from pyspark.sql.types import DoubleType, IntegerType

args = getResolvedOptions(sys.argv, ["JOB_NAME", "S3_FEATURES_PATH", "S3_OUTPUT_PATH"])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

df = spark.read.option("header", "true").option("inferSchema", "true").csv(args["S3_FEATURES_PATH"])

df = df.dropDuplicates()
df = df.dropna(subset=["amount_log", "merchant_cat_encoded", "hour_of_day"])

df = (
    df.withColumn("amount_log", F.col("amount_log").cast(DoubleType()))
    .withColumn("merchant_cat_encoded", F.col("merchant_cat_encoded").cast(IntegerType()))
    .withColumn("hour_of_day", F.col("hour_of_day").cast(IntegerType()))
    .withColumn("day_of_week", F.col("day_of_week").cast(IntegerType()))
    .withColumn("account_age_days", F.col("account_age_days").cast(IntegerType()))
    .withColumn("prev_fraud_count", F.col("prev_fraud_count").cast(IntegerType()))
    .withColumn("distance_km_log", F.col("distance_km_log").cast(DoubleType()))
    .withColumn("is_foreign", F.col("is_foreign").cast(IntegerType()))
    .withColumn("tx_freq_24h", F.col("tx_freq_24h").cast(IntegerType()))
)

# Add partition columns from ingestion timestamp
now = datetime.utcnow()
df = (
    df.withColumn("year", F.lit(str(now.year)))
    .withColumn("month", F.lit(f"{now.month:02d}"))
    .withColumn("day", F.lit(f"{now.day:02d}"))
)

df.write.mode("append").partitionBy("year", "month", "day").parquet(args["S3_OUTPUT_PATH"])

print(f"ETL complete — {df.count()} rows written to {args['S3_OUTPUT_PATH']}")
job.commit()
