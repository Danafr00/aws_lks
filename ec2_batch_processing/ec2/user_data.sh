#!/bin/bash

apt update -y
apt install python3-pip -y

pip3 install boto3 psycopg2-binary --break-system-packages

cat <<EOF > /home/ubuntu/process.py
<PASTE process.py CONTENT HERE>
EOF

python3 /home/ubuntu/process.py

shutdown -h now