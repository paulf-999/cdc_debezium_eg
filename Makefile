SHELL = /bin/sh

# default: deps install [X, Y, Z...] clean

installations: deps install clean

$(eval current_dir=$(shell pwd))

ZK_FILEPATH := https://apache.mirror.digitalpacific.com.au/zookeeper/zookeeper-3.7.0/apache-zookeeper-3.7.0-bin.tar.gz
ZK_SHA_FILEPATH := https://downloads.apache.org/zookeeper/zookeeper-3.7.0/apache-zookeeper-3.7.0-bin.tar.gz.sha512
DEBEZIUM_FILEPATH := https://repo1.maven.org/maven2/io/debezium/debezium-connector-src/sql/mysql/1.5.0.Final/debezium-connector-mysql-1.5.0.Final-plugin.tar.gz
KAFKA_FILEPATH := https://ftp.cixug.es/apache/kafka/2.8.0/kafka_2.13-2.8.0.tgz
SNOWFLAKE_KAFKA_CONNECTOR_FILEPATH := https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/1.5.2/snowflake-kafka-connector-1.5.2.jar
SNOWFLAKE_KAFKA_CONNECTOR_MD5_FILEPATH := https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/1.5.2/snowflake-kafka-connector-1.5.2.jar.md5
KAFKA_PLUGINS_DIR := ${current_dir}/bin/kafka_plugins
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
	# download the snowflake-kafka connector and corresponding MD5 file
	@wget ${SNOWFLAKE_KAFKA_CONNECTOR_FILEPATH} -P downloads/
	@wget ${SNOWFLAKE_KAFKA_CONNECTOR_MD5_FILEPATH} -P downloads/
	# donwload Bouncy Castle plugin for encrypted private key authentication
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.1/bc-fips-1.0.1.jar -P downloads/
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.1/bc-fips-1.0.1.jar.md5 -P downloads/
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.3/bcpkix-fips-1.0.3.jar -P downloads/
	@wget https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.3/bcpkix-fips-1.0.3.jar.md5 -P downloads/

install:
	$(info [+] Install the relevant dependencies)
	# configure and install zookeeper
	@mkdir -p bin/zookeeper && tar xzf downloads/apache-zookeeper-3.7.0-bin.tar.gz -C bin/zookeeper --strip-components 1
	@mv bin/zookeeper/conf/zoo_sample.cfg bin/zookeeper/conf/zoo.cfg
	@sudo mkdir -p /var/lib/zookeeper
	@mkdir -p bin/kafka && tar xzf downloads/kafka_2.13-2.8.0.tgz -C bin/kafka --strip-components 1
	@tar xzf downloads/debezium-connector-mysql-1.5.0.Final-plugin.tar.gz --directory ${KAFKA_PLUGINS_DIR}
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
	# add 2 additional kafka config options
	@cat src/kafka_settings/connect-standalone.properties | sed \ 's+@CWD+${KAFKA_PLUGINS_DIR}+' >> bin/kafka/config/connect-standalone.properties
	@cat src/kafka_settings/mysql-debezium.properties | sed 's/MyPass/${DEMO_PASS}/' > bin/kafka/config/mysql-debezium.properties

prep_snowflake:
	$(info [+] Prepare Snowflake target)
	@${SNOWSQL_QUERY} -f src/sql/snowflake/create_scaffolding.sql
	@${SNOWSQL_QUERY} -f src/sql/snowflake/create_roles.sql --variable PASS=${DEMO_PASS}

launch_debezium_connector:
	nohup ./bin/kafka/bin/connect-standalone.sh ./bin/kafka/config/connect-standalone.properties ./bin/kafka/config/mysql-debezium.properties > debezium_connector_`date "+%F_%H-%M"`.log 2>&1 &

clean:
	$(info [+] remove compression downloads)
	rm downloads/*.gz
	rm downloads/*.tgz
