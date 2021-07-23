SHELL = /bin/sh

# default: deps install [X, Y, Z...] clean

installations: deps install clean

$(eval CURRENT_DIR=$(shell pwd))

ZK_FILEPATH := https://apache.mirror.digitalpacific.com.au/zookeeper/zookeeper-3.7.0/apache-zookeeper-3.7.0-bin.tar.gz
ZK_SHA_FILEPATH := https://downloads.apache.org/zookeeper/zookeeper-3.7.0/apache-zookeeper-3.7.0-bin.tar.gz.sha512
DEBEZIUM_FILEPATH := https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/1.5.0.Final/debezium-connector-mysql-1.5.0.Final-plugin.tar.gz
KAFKA_FILEPATH := https://ftp.cixug.es/apache/kafka/2.8.0/kafka_2.13-2.8.0.tgz
SNOWFLAKE_KAFKA_CONNECTOR_FILEPATH := https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/1.5.2/snowflake-kafka-connector-1.5.2.jar
SNOWFLAKE_KAFKA_CONNECTOR_MD5_FILEPATH := https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/1.5.2/snowflake-kafka-connector-1.5.2.jar.md5
KAFKA_PLUGINS_DIR := ${CURRENT_DIR}/bin/kafka/libs
# standardised Snowflake SnowSQL query format / options
SNOWSQL_QUERY=snowsql -c ${SNOWFLAKE_CONN_PROFILE} -o friendly=false -o header=false -o timing=false

deps:
	$(info [+] Download the relevant dependencies)
	@brew install java
	@brew install wget
	@brew install coreutils
	# if you have any issues with sha512, uncomment the line below
	# sudo ln -s /usr/local/bin/gsha512sum /usr/local/bin/sha512sum
	# download zookeeper (zk)
	@wget ${ZK_FILEPATH} -P downloads/
	# download zk sha checksum file
	@wget ${ZK_SHA_FILEPATH} -P downloads/
	@sha512sum downloads/apache-zookeeper-3.7.0-bin.tar.gz
	# download debezium connector
	@wget ${DEBEZIUM_FILEPATH} -P downloads/
	# download kafka
	@wget ${KAFKA_FILEPATH} -P downloads/
	# download the snowflake-kafka connector

install:
	$(info [+] Install the relevant dependencies)
	# configure and install zookeeper
	@mkdir -p bin/zookeeper && tar xzf downloads/apache-zookeeper-3.7.0-bin.tar.gz -C bin/zookeeper --strip-components 1
	@mv bin/zookeeper/conf/zoo_sample.cfg bin/zookeeper/conf/zoo.cfg
	@sudo mkdir -p /var/lib/zookeeper
	# configure and install kafka
	@mkdir -p bin/kafka && tar xzf downloads/kafka_2.13-2.8.0.tgz -C bin/kafka --strip-components 1
	# download required kafka plugins
	@wget ${SNOWFLAKE_KAFKA_CONNECTOR_FILEPATH} -P ${KAFKA_PLUGINS_DIR}
	@tar xzf downloads/debezium-connector-mysql-1.5.0.Final-plugin.tar.gz --directory ${KAFKA_PLUGINS_DIR}
	# donwload Bouncy Castle plugin for encrypted private key authentication
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.1/bc-fips-1.0.1.jar -P ${KAFKA_PLUGINS_DIR}
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.3/bcpkix-fips-1.0.3.jar -P ${KAFKA_PLUGINS_DIR}
	# Set the timezone to UTC with homebrew installed mysql
	@cat src/kafka_settings/mysql_tz.txt >> /usr/local/etc/my.cnf
	# restart mysql server, for timezone change to take effect
	@brew services restart mysql

start_zk:
	$(info [+] instructions followed from: https://zookeeper.apache.org/doc/r3.7.0/zookeeperStarted.html.)
	@sudo bin/zookeeper/bin/zkServer.sh start

start_kafka: #do this in a seperate terminal session
	$(info [+] instructions followed from: https://kafka.apache.org/quickstart)
	@bin/kafka/bin/kafka-server-start.sh bin/kafka/config/server.properties

prep_mysql_db:
	$(info [+] Prepare the MySQL DB / server)
	@mysql < src/sql/mysql/create_db.sql
	@mysql --database="snowflake_source" < src/sql/mysql/create_and_populate_animals_tbl.sql
	# create a MySQL 'replication' user, using the env var ${DEMO_PASS} as the password)
	# @cat src/sql/mysql/create_replication_user.sql | sed 's/@Pass/${DEMO_PASS}/' | mysql --database="snowflake_source"
	@echo ""
	# verify that logging is enabled on the server
	@mysql --database="snowflake_source" < src/sql/mysql/verify_logging_enabled.sql
	@echo ""

add_kafka_settings:
	$(info [+]  add 2 additional kafka config options)
	@cat src/kafka_settings/connect-standalone.properties | sed \ 's~@CWD~${KAFKA_PLUGINS_DIR}~' >> bin/kafka/config/connect-standalone.properties
	@cat src/kafka_settings/mysql-debezium.properties | sed 's/MyPass/${DEMO_PASS}/' > bin/kafka/config/mysql-debezium.properties

launch_debezium_connector:
	nohup ./bin/kafka/bin/connect-standalone.sh ./bin/kafka/config/connect-standalone.properties ./bin/kafka/config/mysql-debezium.properties > debezium_connector_`date "+%F_%H-%M"`.log 2>&1 &

prep_snowflake:
	$(info [+] Prepare Snowflake target)
	@${SNOWSQL_QUERY} -f src/sql/snowflake/create_scaffolding.sql
	@${SNOWSQL_QUERY} -f src/sql/snowflake/create_roles.sql --variable PASS=${DEMO_PASS}

generate_keys_and_populate_snowflake_connector: gen_keys populate_snowflake_connector

gen_keys:
	# generate encrpyted private key
	@openssl genrsa 2048 | openssl pkcs8 -topk8 -v2 aes256 -inform PEM -passout pass:${DEMO_PASS} -out rsa_key.p8
	# remove the header, footer and line breaks from the key to use it in the configuration file (snowflake-connector-animals.properties)
	$(eval PRIVATE_KEY=$(shell grep -v PRIVATE rsa_key.p8 | sed ':a;N;$!ba;s/\n/ /g'))
	# generate the public key out of the private key. Then again, remove the the header, footer and line breaks
	@openssl rsa -in rsa_key.p8 -passin pass:${DEMO_PASS} -pubout -out rsa_key.pub
	$(eval PUBLIC_KEY=$(shell grep -v PUBLIC rsa_key.pub | sed ':a;N;$!ba;s/\n//g'))
	@ echo "PUBLIC_KEY = ${PUBLIC_KEY}"

populate_snowflake_connector:
	# change the snowflake role password to instead use the RSA public key
	@${SNOWSQL_QUERY} -f src/sql/snowflake/alter_role.sql --variable PASS="${PUBLIC_KEY}"
	envsubst < src/kafka_settings/snowflake-connector-animals.properties | sed \ 's~MyPrivateKey~${PRIVATE_KEY}~' > bin/kafka/config/snowflake-connector-animals.properties
	cp bin/kafka/config/connect-standalone.properties bin/kafka/config/connect-standalone-write.properties
	echo "rest.port=8084" >> bin/kafka/config/connect-standalone-write.properties

collate_logging:
	nohup ./bin/kafka/bin/connect-standalone.sh ./bin/kafka/config/connect-standalone-write.properties ./bin/kafka/config/snowflake-connector-animals.properties > snowflake_connector_`date "+%F_%H-%M"`.log 2>&1 &

find_and_kill_port_process:
	lsof -i tcp:8083
	#kill -9 73260 #pid

clean:
	$(info [+] remove compression downloads)
	rm downloads/*.gz
	rm downloads/*.tgz
