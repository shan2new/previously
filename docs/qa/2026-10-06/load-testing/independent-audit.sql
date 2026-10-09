-- Read-only mid-run audit. User/catalogue math derives from deterministic fixture creation.
-- Ordinary write targets are checked against acknowledged intent by the HTTP runner's oracle.
with fixture_users as (
  select id, substring(clerk_id from 9)::int as n from users
  where clerk_id ~ '^qa-load-[0-9]{4}$'
), base as (
  select u.id as user_id, u.n, 310000000 + ((u.n * 7 + o.n) % 1000) * 3 + p.n as media_id,
    case when o.n % 5 = 1 then 12 when o.n % 5 = 0 and p.n = 0 then 6 else 0 end as episodes,
    (u.n < 498 and o.n = 0 and p.n = 0) as ordinary_write_target
  from fixture_users u cross join generate_series(0,49) o(n) cross join generate_series(0,2) p(n)
), imports as (
  select u.id as user_id, u.n, 310000000 + i.n as media_id,
    case when i.n % 2 = 0 then 12 else 3 end as episodes, false as ordinary_write_target
  from fixture_users u cross join generate_series(0,149) i(n) where u.n in (498,499)
), expected_progress as (
  select * from base union all select * from imports
), expected_subs as (
  select u.id as user_id, 310000000 + ((u.n * 7 + o.n) % 1000) * 3 as primary_id,
    (array['watching','completed','planned','paused','dropped'])[o.n % 5 + 1] as status
  from fixture_users u cross join generate_series(0,49) o(n)
  union all
  select u.id, 310000000 + i.n * 3, 'watching'
  from fixture_users u cross join generate_series(0,49) i(n) where u.n in (498,499)
)
select json_build_object(
  'database', current_database(),
  'users', (select count(*) from users),
  'franchises', (select count(*) from franchise),
  'media', (select count(*) from media),
  'subscriptions', (select count(*) from subscriptions),
  'progress', (select count(*) from progress),
  'coldFranchises', (select count(*) from franchise where primary_media_id >= 310100000 and primary_media_id < 310100200),
  'coldMedia', (select count(*) from media where id >= 310100000 and id < 310100200),
  'progressRowsIndependentlyChecked', (select count(*) from expected_progress where not ordinary_write_target),
  'unchangedOrImportedProgressMismatches', (
    select count(*) from expected_progress e
    left join progress p on p.user_id = e.user_id and p.media_id = e.media_id
    where not e.ordinary_write_target and p.episodes_watched is distinct from e.episodes
  ),
  'unexpectedProgressRows', (
    select count(*) from progress p
    left join expected_progress e on p.user_id = e.user_id and p.media_id = e.media_id
    where e.user_id is null
  ),
  'subscriptionOwnershipOrStatusMismatches', (
    select count(*) from expected_subs e
    left join franchise f on f.primary_media_id = e.primary_id
    left join subscriptions s on s.user_id = e.user_id and s.franchise_id = f.id
    where s.status::text is distinct from e.status
  ),
  'unexpectedSubscriptions', (
    select count(*) from subscriptions s
    join franchise f on f.id = s.franchise_id
    left join expected_subs e on e.user_id = s.user_id and e.primary_id = f.primary_media_id
    where e.user_id is null
  )
);
