#!/bin/bash

export HUBOT_ZABBIX_ENDPOINT=
export HUBOT_ZABBIX_USER=
export HUBOT_ZABBIX_PASSWORD=

export HUBOT_ZABBIX_S3_BUCKET=
export HUBOT_ZABBIX_S3_ACCESS_KEY=
export HUBOT_ZABBIX_S3_SECRET_KEY=
export HUBOT_ZABBIX_S3_REGION=

export HUBOT_BEARYCHAT_TOKENS=
export HUBOT_BEARYCHAT_MODE=http

# in case you want to debug
#export HUBOT_LOG_LEVEL="debug"

bin/hubot --adapter bearychat
