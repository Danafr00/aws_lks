import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql.functions import col, year, month, dayofmonth, lpad, to_timestamp, lower, trim

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'S3_RAW_PATH', 'S3_PROCESSED_BUCKET', 'S3_PROCESSED_PREFIX'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

raw_path = args['S3_RAW_PATH']
processed_path = f"s3://{args['S3_PROCESSED_BUCKET']}/{args['S3_PROCESSED_PREFIX']}/"

df = spark.read.option('multiLine', False).json(raw_path)

df = (df
    .withColumn('product_name', trim(col('product_name')))
    .withColumn('category', lower(trim(col('category'))))
    .withColumn('region', lower(trim(col('region'))))
    .withColumn('order_status', lower(trim(col('order_status'))))
    .withColumn('payment_method', lower(trim(col('payment_method'))))
    .withColumn('quantity', col('quantity').cast('int'))
    .withColumn('unit_price', col('unit_price').cast('double'))
    .withColumn('total_amount', col('total_amount').cast('double'))
    .withColumn('event_ts', to_timestamp(col('timestamp')))
    .withColumn('year', year(col('event_ts')).cast('string'))
    .withColumn('month', lpad(month(col('event_ts')).cast('string'), 2, '0'))
    .withColumn('day', lpad(dayofmonth(col('event_ts')).cast('string'), 2, '0'))
    .dropDuplicates(['order_id'])
    .na.drop(subset=['order_id', 'timestamp', 'total_amount'])
)

df.write \
    .mode('append') \
    .partitionBy('year', 'month', 'day') \
    .parquet(processed_path)

job.commit()
