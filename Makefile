export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=p0stgreS

export POSTGRES_REPL_USER=repl_user
export POSTGRES_REPL_PASSWORD=rep1icatioN

export MASTER_PORT=56430
export SLAVE1_PORT=56431
export SLAVE2_PORT=56432

test_async_replication:
	$(MAKE) async_replication

#############################################################################################

async_replication:
	$(MAKE) step01__initialize
	$(MAKE) step02__setup_master
	$(MAKE) step03__generate_testdata
	$(MAKE) step04__check
	$(MAKE) step05__start_async_replication
	$(MAKE) step06__check
	$(MAKE) step07__crash_master
	$(MAKE) step08__check
	$(MAKE) step09__insert_fail_test
	$(MAKE) step10__promote_slave
	$(MAKE) step11__insert_success_test
	$(MAKE) step12__check
	$(MAKE) step13__re_replication
	$(MAKE) step14__check
	$(MAKE) step15__cleanup

step01__initialize:
	$(MAKE) initialize

step02__setup_master:
	$(MAKE) create_repl_user
	$(MAKE) set_master_replication_params

step03__generate_testdata:
	$(MAKE) insert_records_to_master

step04__check:
	$(MAKE) check_replication_master

step05__start_async_replication:
	$(MAKE) basebackup_master
	$(MAKE) start_slave1_async_replication
	$(MAKE) start_slave2_async_replication

step06__check:
	$(MAKE) insert_records_to_master
	$(MAKE) check_replication_master
	$(MAKE) check_replication_slave1
	$(MAKE) check_replication_slave2

step07__crash_master:
	$(MAKE) crash_master

step08__check:
	$(MAKE) check_replication_slave1
	$(MAKE) check_replication_slave2

step09__insert_fail_test:
	$(MAKE) insert_records_to_slave1

step10__promote_slave:
	$(MAKE) promote_slave1_to_master

step11__insert_success_test:
	$(MAKE) insert_records_to_slave1

step12__check:
	$(MAKE) check_replication_slave1
	$(MAKE) check_replication_slave2

step13__re_replication:
	$(MAKE) start_master_for_slave1_async_replication
	$(MAKE) start_slave2_for_slave1_async_replication

step14__check:
	$(MAKE) insert_records_to_slave1
	$(MAKE) check_replication_master
	$(MAKE) check_replication_slave1
	$(MAKE) check_replication_slave2

step15__cleanup:
	$(MAKE) destroy

#############################################################################################

initialize:
	$(MAKE) destroy
	$(MAKE) start_master

create_repl_user:
	$(MAKE) wait_master
	docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "CREATE ROLE ${POSTGRES_REPL_USER} LOGIN REPLICATION PASSWORD '${POSTGRES_REPL_PASSWORD}';"
	echo "host replication repl_user 127.0.0.1/32 md5" >> ./volumes/master/data/pg_hba.conf
	echo "host replication repl_user 172.16.0.0/24 md5" >> ./volumes/master/data/pg_hba.conf
	docker-compose restart master

set_master_replication_params:
	echo "wal_level = replica" >> ./volumes/master/data/postgresql.conf
	echo "synchronous_commit = on" >> ./volumes/master/data/postgresql.conf
	echo "max_wal_senders = 3" >> ./volumes/master/data/postgresql.conf
	echo "archive_mode = off" >> ./volumes/master/data/postgresql.conf
	echo "wal_keep_segments = 8" >> ./volumes/master/data/postgresql.conf
	docker-compose restart master

basebackup_master:
	$(MAKE) wait_master
	docker-compose exec -T master bash -c 'echo "127.0.0.1:5432:replication:${POSTGRES_REPL_USER}:${POSTGRES_REPL_PASSWORD}" > ~/.pgpass'
	docker-compose exec -T master bash -c 'chmod 600 ~/.pgpass'
	docker-compose exec -T master pg_basebackup -h 127.0.0.1 -p 5432 -U ${POSTGRES_REPL_USER} -D /var/lib/postgresql/shared/data --xlog --checkpoint=fast --progress -w

start_slave1_async_replication:
	mkdir -p ./volumes/slave1
	cp -r ./volumes/shared/data ./volumes/slave1/data
	echo "hot_standby = on" >> ./volumes/slave1/data/postgresql.conf
	echo "standby_mode = 'on'" >> ./volumes/slave1/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.2 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD}'" >> ./volumes/slave1/data/recovery.conf
	docker-compose up -d slave1

start_slave2_async_replication:
	mkdir -p ./volumes/slave2
	cp -r ./volumes/shared/data ./volumes/slave2/data
	echo "hot_standby = on" >> ./volumes/slave2/data/postgresql.conf
	echo "standby_mode = 'on'" >> ./volumes/slave2/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.2 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD}'" >> ./volumes/slave2/data/recovery.conf
	docker-compose up -d slave2

crash_master:
	$(MAKE) stop_master

promote_slave1_to_master:
	docker-compose exec -T slave1 su postgres -c '/usr/lib/postgresql/9.6/bin/pg_ctl promote -D /var/lib/postgresql/data'

start_master_for_slave1_async_replication: stop_master
	echo "hot_standby = on" >> ./volumes/master/data/postgresql.conf
	echo "standby_mode = 'on'" >> ./volumes/master/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.3 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD}'" >> ./volumes/master/data/recovery.conf
	echo "recovery_target_timeline='latest'" >> ./volumes/master/data/recovery.conf
	echo "restore_command = 'cp /var/lib/postgresql/slave1/data/pg_xlog/%f \"%p\" 2> /dev/null'" >> ./volumes/master/data/recovery.conf
	docker-compose up -d master

start_slave2_for_slave1_async_replication:
	$(MAKE) stop_slave2
	rm ./volumes/slave2/data/recovery.conf
	echo "standby_mode = 'on'" >> ./volumes/slave2/data/recovery.conf
	echo "primary_conninfo = 'host=172.16.0.3 port=5432 user=${POSTGRES_REPL_USER} password=${POSTGRES_REPL_PASSWORD}'" >> ./volumes/slave2/data/recovery.conf
	echo "recovery_target_timeline='latest'" >> ./volumes/slave2/data/recovery.conf
	echo "restore_command = 'cp /var/lib/postgresql/slave1/data/pg_xlog/%f \"%p\" 2> /dev/null'" >> ./volumes/slave2/data/recovery.conf
	docker-compose up -d slave2

check_replication_master:
	docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

check_replication_slave1:
	docker-compose exec -T slave1 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T slave1 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T slave1 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

check_replication_slave2:
	docker-compose exec -T slave2 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;"
	docker-compose exec -T slave2 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT pg_last_xact_replay_timestamp();"
	docker-compose exec -T slave2 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT COUNT(*) FROM pgbench_accounts;"

insert_records_to_master:
	$(MAKE) wait_master
	docker-compose exec -T master pgbench -U postgres -h 127.0.0.1 -p 5432 -i

insert_records_to_slave1:
	$(MAKE) wait_slave1
	-docker-compose exec -T slave1 pgbench -U postgres -h 127.0.0.1 -p 5432 -i

insert_records_to_slave2:
	$(MAKE) wait_slave2
	docker-compose exec -T slave2 pgbench -U postgres -h 127.0.0.1 -p 5432 -i

start_all:
	docker-compose up -d

wait_master:
	while ! docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo "waiting"; done;

wait_slave1:
	while ! docker-compose exec -T slave1 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo 'waiting'; done;

wait_slave2:
	while ! docker-compose exec -T slave2 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER} -c "SELECT * FROM pg_stat_replication;" > /dev/null 2>&1; do sleep 1; echo 'waiting'; done;

start_master:
	docker-compose up -d master

start_slave1:
	docker-compose up -d slave1

start_slave2:
	docker-compose up -d slave2

restart_all:
	docker-compose restart

stop_all:
	docker-compose stop

stop_master:
	docker-compose stop master

stop_slave1:
	docker-compose stop slave1

stop_slave2:
	docker-compose stop slave2

destroy:
	docker-compose rm -s -f
	-docker network rm pg-practice-bridge
	rm -rf ./volumes

psql_master:
	docker-compose exec -T master psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}

psql_slave1:
	docker-compose exec -T slave1 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}

psql_slave2:
	docker-compose exec -T slave2 psql -h 127.0.0.1 -p 5432 -U ${POSTGRES_USER}
