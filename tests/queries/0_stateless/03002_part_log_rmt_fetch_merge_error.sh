#!/usr/bin/env bash
# Tags: no-replicated-database, no-parallel, no-shared-merge-tree
# SMT: The merge process is completely different from RMT

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

set -e

function wait_until()
{
    local q=$1 && shift
    while [ "$($CLICKHOUSE_CLIENT -nm -q "$q")" != "1" ]; do
        # too frequent FLUSH LOGS is too costly
        sleep 2
    done
}

$CLICKHOUSE_CLIENT -nm -q "
    drop table if exists rmt_master;
    drop table if exists rmt_slave;

    create table rmt_master (key Int) engine=ReplicatedMergeTree('/clickhouse/{database}', 'master') order by key settings always_fetch_merged_part=0;
    -- always_fetch_merged_part=1, consider this table as a 'slave'
    create table rmt_slave (key Int) engine=ReplicatedMergeTree('/clickhouse/{database}', 'slave') order by key settings always_fetch_merged_part=1;

    insert into rmt_master values (1);

    system sync replica rmt_master;
    system sync replica rmt_slave;
    system stop replicated sends rmt_master;
    optimize table rmt_master final settings alter_sync=1, optimize_throw_if_noop=1;
"

$CLICKHOUSE_CLIENT -nm -q "
    system flush logs;
    select 'before';
    select table, event_type, error>0, countIf(error=0) from system.part_log where database = currentDatabase() group by 1, 2, 3 order by 1, 2, 3;

    system start replicated sends rmt_master;
"
# wait until rmt_slave will fetch the part and reflect this error in system.part_log
wait_until "system flush logs; select count()>0 from system.part_log where table = 'rmt_slave' and database = '$CLICKHOUSE_DATABASE' and error > 0"
$CLICKHOUSE_CLIENT -nm -q "
    system sync replica rmt_slave;

    system flush logs;
    select 'after';
    select table, event_type, error>0, countIf(error=0) from system.part_log where database = currentDatabase() group by 1, 2, 3 order by 1, 2, 3;

    drop table rmt_master;
    drop table rmt_slave;
"
