import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, to_date, year, month, dayofmonth, lpad, lower, trim

args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'S3_RAW_PATH',
    'S3_PROCESSED_BUCKET',
    'S3_PROCESSED_PREFIX',
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

raw_path = args['S3_RAW_PATH']
processed_bucket = args['S3_PROCESSED_BUCKET']
processed_prefix = args['S3_PROCESSED_PREFIX']

print(f"==> Reading CSV from: {raw_path}")
df = spark.read \
    .option("header", "true") \
    .option("inferSchema", "true") \
    .csv(raw_path)

# Normalize column names to lowercase snake_case
for c in df.columns:
    clean = c.strip().lower().replace(' ', '_').replace('-', '_')
    if clean != c:
        df = df.withColumnRenamed(c, clean)

print(f"==> Schema: {df.dtypes}")
print(f"==> Raw row count: {df.count()}")

# Drop rows missing critical fields
df = df.dropna(subset=['transaction_id', 'sale_date', 'amount'])

# Type casting and value normalization
df = df \
    .withColumn('amount', col('amount').cast('double')) \
    .withColumn('quantity', col('quantity').cast('int')) \
    .withColumn('unit_price', col('unit_price').cast('double')) \
    .withColumn('sale_date', to_date(col('sale_date'), 'yyyy-MM-dd')) \
    .withColumn('product_name', trim(col('product_name'))) \
    .withColumn('category', lower(trim(col('category'))))

# Add Hive-style partition columns
df = df \
    .withColumn('year', year(col('sale_date')).cast('string')) \
    .withColumn('month', lpad(month(col('sale_date')).cast('string'), 2, '0')) \
    .withColumn('day', lpad(dayofmonth(col('sale_date')).cast('string'), 2, '0'))

output_path = f"s3://{processed_bucket}/{processed_prefix}"
print(f"==> Writing Parquet to: {output_path}")

df.write \
    .mode('append') \
    .partitionBy('year', 'month', 'day') \
    .parquet(output_path)

clean_count = df.count()
print(f"==> ETL complete. Wrote {clean_count} rows to {output_path}")

job.commit()
