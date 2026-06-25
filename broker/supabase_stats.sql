create table if not exists runner_stats (
  dimension text not null,
  key       text not null,
  kind      text not null,
  count     bigint not null default 0,
  last_seen timestamptz,
  primary key (dimension, key, kind)
);
create table if not exists runner_stats_meta (id int primary key default 1, since timestamptz);

create or replace function record_runner_event(p_dimension text, p_key text, p_kind text, p_ts timestamptz)
returns void language sql as $$
  insert into runner_stats(dimension, key, kind, count, last_seen)
  values (p_dimension, p_key, p_kind, 1, p_ts)
  on conflict (dimension, key, kind)
  do update set count = runner_stats.count + 1,
                last_seen = greatest(runner_stats.last_seen, excluded.last_seen);
  insert into runner_stats_meta(id, since) values (1, p_ts) on conflict (id) do nothing;
$$;
