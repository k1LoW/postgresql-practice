DESC_COLOR=\033[1;36m
INFO_COLOR=\033[1;33m
NO_COLOR=\033[0m

export POSTGRES_VERSION ?= 11

export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=p0stgreS

export POSTGRES_REPL_USER=repl_user
export POSTGRES_REPL_PASSWORD=rep1icatioN

export ALPHA_PORT=56430
export BRAVO_PORT=56431
export CHARLIE_PORT=56432

test_async_replication:
	@$(MAKE) async_replication
	@$(MAKE) async_replication_failover
	@$(MAKE) destroy

test_sync_replication:
	@$(MAKE) sync_replication
	@$(MAKE) sync_replication_failover
	@$(MAKE) destroy

#############################################################################################

async_replication:
	@echo "${DESC_COLOR}環境を初期化し、マスターとなるPostgreSQL(alpha)を起動します${NO_COLOR}"
	@$(MAKE) initialize
	@echo "${DESC_COLOR}テストデータを投入します${NO_COLOR}"
	@$(MAKE) generate_testdata
	@echo "${DESC_COLOR}PostgreSQL(alpha)に非同期ストリーミングレプリケーションの設定を追加します${NO_COLOR}"
	@$(MAKE) setup_alpha_for_replication
	@echo "${DESC_COLOR}PostgreSQL(alpha)からpg_basebackupでデータを取得し、2台のPostgreSQL(bravo, charlie)をスタンバイとして起動します${NO_COLOR}"
	@$(MAKE) start_replication
	@echo "${DESC_COLOR}非同期レプリケーションが正常に構築できているかを確認します${NO_COLOR}"
	@$(MAKE) check_async_replication_alpha

async_replication_failover:
	@echo "${DESC_COLOR}PostgreSQL(alpha)を強制停止します${NO_COLOR}"
	@$(MAKE) crash_alpha
	@echo "${DESC_COLOR}スタンバイ状態のPostgreSQL(bravo)では書き込みクエリはコミットができないことを確認します${NO_COLOR}"
	@$(MAKE) insert_fail_test
	@echo "${DESC_COLOR}PostgreSQL(bravo)をマスターに昇格します${NO_COLOR}"
	@$(MAKE) promote_standby
	@echo "${DESC_COLOR}PostgreSQL(bravo)でWriteができることを確認します${NO_COLOR}"
	@$(MAKE) insert_success_test
	@echo "${INFO_COLOR}この時点で、alphaからbravoへのフェイルオーバーが成功しています${NO_COLOR}"
	@echo "${DESC_COLOR}restore_commandを利用し、残り2台(alpha, charlie)のPostgreSQLをスタンバイとして復旧させます${NO_COLOR}"
	@$(MAKE) re_replication
	@echo "${DESC_COLOR}非同期レプリケーションが正常に構築できているかを確認します${NO_COLOR}"
	@$(MAKE) check_async_replication_bravo

sync_replication:
	@echo "${DESC_COLOR}環境を初期化し、マスターとなるPostgreSQL(alpha)を起動します${NO_COLOR}"
	@$(MAKE) initialize
	@echo "${DESC_COLOR}テストデータを投入します${NO_COLOR}"
	@$(MAKE) generate_testdata
	@echo "${DESC_COLOR}PostgreSQL(alpha)にまず非同期ストリーミングレプリケーションの設定を追加します${NO_COLOR}"
	@$(MAKE) setup_alpha_for_replication
	@echo "${DESC_COLOR}PostgreSQL(alpha)からpg_basebackupでデータを取得し、2台のPostgreSQL(bravo, charlie)をスタンバイとして起動します${NO_COLOR}"
	@$(MAKE) start_replication
	@echo "${DESC_COLOR}非同期レプリケーションが正常に構築できているかを確認します${NO_COLOR}"
	@$(MAKE) check_async_replication_alpha
	@echo "${DESC_COLOR}PostgreSQL(alpha)のレプリケーション設定を同期ストリーミングレプリケーションに変更します${NO_COLOR}"
	@$(MAKE) set_alpha_sync_replication_params
	@echo "${DESC_COLOR}PostgreSQL(alpha)からpg_basebackupでデータを取得し、2台のPostgreSQL(bravo, charlie)をスタンバイとして起動します${NO_COLOR}"
	@$(MAKE) start_replication
	@echo "${DESC_COLOR}同期レプリケーションが正常に構築できているかを確認します${NO_COLOR}"
	@$(MAKE) check_sync_replication_alpha

sync_replication_failover:
	@echo "${DESC_COLOR}PostgreSQL(alpha)を強制停止します${NO_COLOR}"
	@$(MAKE) crash_alpha
	@echo "${DESC_COLOR}スタンバイ状態のPostgreSQL(bravo)では書き込みクエリはコミットができないことを確認します${NO_COLOR}"
	@$(MAKE) insert_fail_test
	@echo "${DESC_COLOR}PostgreSQL(bravo)をマスターに昇格します${NO_COLOR}"
	@$(MAKE) promote_standby
	@echo "${INFO_COLOR}この時、同期レプリケーション状態でスタンバイが指定数存在しないため書き込みクエリはコミット待機します${NO_COLOR}"
	@echo "${DESC_COLOR}PostgreSQL(bravo)のレプリケーション設定を非同期ストリーミングレプリケーションに変更します${NO_COLOR}"
	@$(MAKE) set_bravo_async_replication_params
	@echo "${DESC_COLOR}PostgreSQL(bravo)でWriteができることを確認します${NO_COLOR}"
	@$(MAKE) insert_success_test
	@echo "${INFO_COLOR}この時点で、alphaからbravoへのフェイルオーバーが成功しています${NO_COLOR}"
	@echo "${DESC_COLOR}PostgreSQL(bravo)のレプリケーション設定を同期ストリーミングレプリケーションに変更します${NO_COLOR}"
	@$(MAKE) set_bravo_sync_replication_params
	@echo "${DESC_COLOR}restore_commandを利用し、残り2台(alpha, charlie)のPostgreSQLをスタンバイとして復旧させます${NO_COLOR}"
	@$(MAKE) re_replication
	@echo "${DESC_COLOR}同期レプリケーションが正常に構築できているかを確認します${NO_COLOR}"
	@$(MAKE) check_sync_replication_bravo

#############################################################################################

initialize:
	@$(MAKE) destroy
	mkdir -p ./volumes/alpha ./volumes/shared ./volumes/bravo ./volumes/charlie
	@$(MAKE) start_alpha
	@$(MAKE) wait_alpha
	echo "include_if_exists = 'replication.conf'" >> ./volumes/alpha/data/postgresql.conf
	@$(MAKE) restart_alpha

setup_alpha_for_replication:
	@$(MAKE) create_repl_user
	@$(MAKE) set_alpha_async_replication_params

generate_testdata:
	@$(MAKE) insert_records_to_alpha

start_replication:
	@$(MAKE) basebackup_alpha
	@$(MAKE) start_bravo_async_replication
	@$(MAKE) start_charlie_async_replication

insert_fail_test:
	-@$(MAKE) insert_records_to_bravo

promote_standby:
	@$(MAKE) promote_bravo_to_alpha

insert_success_test:
	@$(MAKE) insert_records_to_bravo

re_replication:
	@$(MAKE) start_alpha_for_bravo_async_replication
	@$(MAKE) start_charlie_for_bravo_async_replication

create_repl_user:
	@$(MAKE) wait_alpha
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "CREATE ROLE ${POSTGRES_REPL_USER} LOGIN REPLICATION PASSWORD '${POSTGRES_REPL_PASSWORD}';"
	echo "host replication repl_user 127.0.0.1/32 md5" >> ./volumes/alpha/data/pg_hba.conf
	echo "host replication repl_user 172.16.0.0/24 md5" >> ./volumes/alpha/data/pg_hba.conf
	@$(MAKE) restart_alpha

set_alpha_async_replication_params:
	echo "wal_level = replica" > ./volumes/alpha/data/replication.conf
	echo "synchronous_commit = on" >> ./volumes/alpha/data/replication.conf
	echo "max_wal_senders = 3" >> ./volumes/alpha/data/replication.conf
	echo "archive_mode = off" >> ./volumes/alpha/data/replication.conf
	echo "wal_keep_segments = 8" >> ./volumes/alpha/data/replication.conf
	echo "hot_standby = on" >> ./volumes/alpha/data/replication.conf
	@$(MAKE) restart_alpha

set_bravo_async_replication_params:
	echo "wal_level = replica" > ./volumes/bravo/data/replication.conf
	echo "synchronous_commit = on" >> ./volumes/bravo/data/replication.conf
	echo "max_wal_senders = 3" >> ./volumes/bravo/data/replication.conf
	echo "archive_mode = off" >> ./volumes/bravo/data/replication.conf
	echo "wal_keep_segments = 8" >> ./volumes/bravo/data/replication.conf
	echo "hot_standby = on" >> ./volumes/bravo/data/replication.conf
	@$(MAKE) restart_bravo

set_alpha_sync_replication_params:
	echo "wal_level = replica" > ./volumes/alpha/data/replication.conf
	echo "synchronous_commit = on" >> ./volumes/alpha/data/replication.conf
	echo "synchronous_standby_names = 'ANY 1(bravo,charlie)'" >> ./volumes/alpha/data/replication.conf
	echo "max_wal_senders = 3" >> ./volumes/alpha/data/replication.conf
	echo "archive_mode = off" >> ./volumes/alpha/data/replication.conf
	echo "wal_keep_segments = 8" >> ./volumes/alpha/data/replication.conf
	echo "hot_standby = on" >> ./volumes/alpha/data/replication.conf
	@$(MAKE) restart_alpha

set_bravo_sync_replication_params:
	echo "wal_level = replica" > ./volumes/bravo/data/replication.conf
	echo "synchronous_commit = on" >> ./volumes/bravo/data/replication.conf
	echo "synchronous_standby_names = 'ANY 1(charlie,alpha)'" >> ./volumes/bravo/data/replication.conf
	echo "max_wal_senders = 3" >> ./volumes/bravo/data/replication.conf
	echo "archive_mode = off" >> ./volumes/bravo/data/replication.conf
	echo "wal_keep_segments = 8" >> ./volumes/bravo/data/replication.conf
	echo "hot_standby = on" >> ./volumes/bravo/data/replication.conf
	@$(MAKE) restart_bravo

basebackup_alpha:
	@$(MAKE) wait_alpha
	rm -rf ./volumes/shared/data
	docker-compose exec -T alpha bash -c 'echo "127.0.0.1:5432:replication:${POSTGRES_REPL_USER}:${POSTGRES_REPL_PASSWORD}" > ~/.pgpass'
	docker-compose exec -T alpha bash -c 'chmod 600 ~/.pgpass'
	docker-compose exec -T alpha pg_basebackup -h 127.0.0.1 -p 5432 -U ${POSTGRES_REPL_USER} -D /var/lib/postgresql/shared/data -X fetch --checkpoint=fast --progress -w

start_bravo_async_replication:
	@$(MAKE) stop_bravo
	rm -rf ./volumes/bravo
	mkdir -p ./volumes/bravo
	cp -r ./volumes/shared/data ./volumes/bravo/data
	echo "standby_mode = 'on'" > ./volumes/bravo/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.2 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD} application_name=bravo'" >> ./volumes/bravo/data/recovery.conf
	@$(MAKE) start_bravo

start_charlie_async_replication:
	@$(MAKE) stop_charlie
	rm -rf ./volumes/charlie
	mkdir -p ./volumes/charlie
	cp -r ./volumes/shared/data ./volumes/charlie/data
	echo "standby_mode = 'on'" > ./volumes/charlie/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.2 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD} application_name=charlie'" >> ./volumes/charlie/data/recovery.conf
	@$(MAKE) start_charlie

crash_alpha:
	docker-compose kill alpha

promote_bravo_to_alpha:
	docker-compose exec -T bravo su postgres -c '/usr/lib/postgresql/${POSTGRES_VERSION}/bin/pg_ctl promote -D /var/lib/postgresql/data'

start_alpha_for_bravo_async_replication:
	@$(MAKE) start_alpha
	echo "standby_mode = 'on'" > ./volumes/alpha/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.3 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD} application_name=alpha'" >> ./volumes/alpha/data/recovery.conf
	echo "recovery_target_timeline='latest'" >> ./volumes/alpha/data/recovery.conf
	echo "restore_command = 'cp /var/lib/postgresql/bravo/data/pg_xlog/%f \"%p\" 2> /dev/null'" >> ./volumes/alpha/data/recovery.conf
	@$(MAKE) start_alpha

start_charlie_for_bravo_async_replication:
	@$(MAKE) stop_charlie
	echo "standby_mode = 'on'" > ./volumes/charlie/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.3 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD} application_name=charlie'" >> ./volumes/charlie/data/recovery.conf
	echo "recovery_target_timeline='latest'" >> ./volumes/charlie/data/recovery.conf
	echo "restore_command = 'cp /var/lib/postgresql/bravo/data/pg_xlog/%f \"%p\" 2> /dev/null'" >> ./volumes/charlie/data/recovery.conf
	@$(MAKE) start_charlie

check_async_replication_alpha:
	while ! docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep '2 rows' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	while ! docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep 'async' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"

check_async_replication_bravo:
	while ! docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep '2 rows' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	while ! docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep 'async' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"

check_sync_replication_alpha:
	while ! docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep '2 rows' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	while ! docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep 'potential' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"

check_sync_replication_bravo:
	while ! docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep '2 rows' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	while ! docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" | grep 'potential' > /dev/null 2>&1; do sleep 1; echo "waiting replication"; done;
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"

check_replication_alpha:
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

check_replication_bravo:
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

check_replication_charlie:
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

insert_records_to_alpha:
	@$(MAKE) wait_alpha
	docker-compose exec -T alpha pgbench -U postgres -h 127.0.0.1 -p 5432 -i

insert_records_to_bravo:
	@$(MAKE) wait_bravo
	docker-compose exec -T bravo pgbench -U postgres -h 127.0.0.1 -p 5432 -i

insert_records_to_charlie:
	@$(MAKE) wait_charlie
	docker-compose exec -T charlie pgbench -U postgres -h 127.0.0.1 -p 5432 -i

start_all:
	docker-compose up -d

wait_alpha:
	while ! docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo "waiting"; done;

wait_bravo:
	while ! docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo 'waiting'; done;

wait_charlie:
	while ! docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo 'waiting'; done;

start_alpha:
	docker-compose up -d alpha

start_bravo:
	docker-compose up -d bravo

start_charlie:
	docker-compose up -d charlie

restart_alpha:
	docker-compose restart alpha

restart_bravo:
	docker-compose restart bravo

restart_charlie:
	docker-compose restart charlie

restart_all:
	docker-compose restart

stop_all:
	docker-compose stop

stop_alpha:
	docker-compose stop alpha

stop_bravo:
	docker-compose stop bravo

stop_charlie:
	docker-compose stop charlie

reload_alpha:
	docker-compose exec -T alpha kill -s HUP 1

reload_bravo:
	docker-compose exec -T bravo kill -s HUP 1

reload_charlie:
	docker-compose exec -T charlie kill -s HUP 1

destroy:
	docker-compose rm -s -f
	-docker network rm pg-practice-bridge
	rm -rf ./volumes

psql_alpha:
	docker-compose exec -T alpha psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}

psql_bravo:
	docker-compose exec -T bravo psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}

psql_charlie:
	docker-compose exec -T charlie psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}
