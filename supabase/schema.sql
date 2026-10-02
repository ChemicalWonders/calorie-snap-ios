-- CalorieSnap friends backend.
-- Run this once in your Supabase project: Dashboard → SQL Editor → New query → paste → Run.
-- Safe to re-run.
--
-- Privacy model: every table is locked to its owner by row-level security.
-- Friends never read tables directly. They only see data through the
-- SECURITY DEFINER functions below, which check friendship and each person's
-- sharing toggles on the server.

-- ───────────────────────── Tables ─────────────────────────

create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  display_name   text not null check (char_length(display_name) between 1 and 40),
  friend_code    text not null unique,
  calorie_goal   int  not null default 2000,
  share_calories boolean not null default true,
  share_macros   boolean not null default false,
  share_meals    boolean not null default false,
  share_streak   boolean not null default true,
  updated_at     timestamptz not null default now()
);

create table if not exists public.friendships (
  requester  uuid not null references public.profiles(id) on delete cascade,
  addressee  uuid not null references public.profiles(id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

create table if not exists public.daily_stats (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  day        date not null,
  calories   numeric,
  protein    numeric,
  carbs      numeric,
  fat        numeric,
  meal_count int not null default 0,
  primary key (user_id, day)
);

create table if not exists public.shared_meals (
  id         uuid primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  eaten_at   timestamptz not null,
  name       text not null default '',
  meal_type  text not null default 'snack',
  calories   numeric not null default 0,
  protein    numeric,
  carbs      numeric,
  fat        numeric,
  photo_path text
);
create index if not exists shared_meals_user_time on public.shared_meals (user_id, eaten_at desc);

-- ───────────────────────── Row-level security ─────────────────────────

alter table public.profiles     enable row level security;
alter table public.friendships  enable row level security;
alter table public.daily_stats  enable row level security;
alter table public.shared_meals enable row level security;

drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "own stats" on public.daily_stats;
create policy "own stats" on public.daily_stats
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own meals" on public.shared_meals;
create policy "own meals" on public.shared_meals
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Friendships are read-only for clients; changes go through the functions below.
drop policy if exists "see own friendships" on public.friendships;
create policy "see own friendships" on public.friendships
  for select to authenticated using (auth.uid() in (requester, addressee));

-- ───────────────────────── Helpers ─────────────────────────

create or replace function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  );
$$;

create or replace function public.generate_friend_code() returns text
language plpgsql set search_path = public as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- no 0/O/1/I
  code text;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from profiles where friend_code = code);
  end loop;
  return code;
end $$;

-- Consecutive days with at least one meal, ending today (or yesterday if nothing yet today).
create or replace function public.streak_for(p_user uuid, p_today date) returns int
language plpgsql stable security definer set search_path = public as $$
declare
  d date := p_today;
  n int := 0;
begin
  if not exists (select 1 from daily_stats where user_id = p_user and day = d and meal_count > 0) then
    d := d - 1;
  end if;
  while exists (select 1 from daily_stats where user_id = p_user and day = d and meal_count > 0) loop
    n := n + 1;
    d := d - 1;
  end loop;
  return n;
end $$;

create or replace function public.can_view_meal_photos(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.are_friends(auth.uid(), p_owner)
     and exists (select 1 from profiles where id = p_owner and share_meals);
$$;

-- ───────────────────────── API functions (called by the app) ─────────────────────────

create or replace function public.ensure_profile(p_display_name text) returns public.profiles
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  result profiles;
begin
  if me is null then raise exception 'Not signed in'; end if;
  insert into profiles (id, display_name, friend_code)
  values (me, trim(p_display_name), generate_friend_code())
  on conflict (id) do update set display_name = excluded.display_name, updated_at = now()
  returning * into result;
  return result;
end $$;

create or replace function public.send_friend_request(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  target uuid;
  normalized text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  result text;
begin
  if me is null then raise exception 'Not signed in'; end if;
  select id into target from profiles where friend_code = normalized;
  if target is null then raise exception 'No one has the friend code %', p_code; end if;
  if target = me then raise exception 'That''s your own friend code'; end if;

  -- They already sent me a request: accept it.
  if exists (select 1 from friendships where requester = target and addressee = me) then
    update friendships set status = 'accepted' where requester = target and addressee = me;
    return 'accepted';
  end if;

  insert into friendships (requester, addressee) values (me, target) on conflict do nothing;
  select status into result from friendships where requester = me and addressee = target;
  return result;
end $$;

create or replace function public.respond_friend_request(p_requester uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    update friendships set status = 'accepted'
    where requester = p_requester and addressee = auth.uid();
  else
    delete from friendships where requester = p_requester and addressee = auth.uid();
  end if;
end $$;

-- Removes a friend, or cancels a request in either direction.
create or replace function public.remove_friend(p_other uuid) returns void
language sql security definer set search_path = public as $$
  delete from friendships
  where (requester = auth.uid() and addressee = p_other)
     or (requester = p_other and addressee = auth.uid());
$$;

create or replace function public.list_friends(p_today date)
returns table (
  friend_id uuid, display_name text, status text, outgoing boolean,
  calorie_goal int, today_calories numeric, streak int
)
language sql stable security definer set search_path = public as $$
  select
    p.id,
    p.display_name,
    f.status,
    f.requester = auth.uid(),
    case when f.status = 'accepted' and p.share_calories then p.calorie_goal end,
    case when f.status = 'accepted' and p.share_calories then
      coalesce((select ds.calories from daily_stats ds where ds.user_id = p.id and ds.day = p_today), 0)
    end,
    case when f.status = 'accepted' and p.share_streak then public.streak_for(p.id, p_today) end
  from friendships f
  join profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  where auth.uid() in (f.requester, f.addressee)
  order by f.status, p.display_name;
$$;

create or replace function public.get_friend_stats(p_friend uuid, p_today date, p_days int default 7)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  p profiles;
begin
  if not public.are_friends(auth.uid(), p_friend) then
    raise exception 'You are not friends with this person';
  end if;
  select * into p from profiles where id = p_friend;

  return jsonb_build_object(
    'id', p.id,
    'display_name', p.display_name,
    'share_calories', p.share_calories,
    'share_macros', p.share_macros,
    'share_meals', p.share_meals,
    'share_streak', p.share_streak,
    'calorie_goal', case when p.share_calories then p.calorie_goal end,
    'streak', case when p.share_streak then public.streak_for(p.id, p_today) end,
    'days', case when p.share_calories or p.share_macros then coalesce((
        select jsonb_agg(jsonb_build_object(
          'day', ds.day,
          'calories', case when p.share_calories then ds.calories end,
          'protein',  case when p.share_macros then ds.protein end,
          'carbs',    case when p.share_macros then ds.carbs end,
          'fat',      case when p.share_macros then ds.fat end,
          'meal_count', ds.meal_count
        ) order by ds.day)
        from daily_stats ds
        where ds.user_id = p.id and ds.day > p_today - p_days and ds.day <= p_today
      ), '[]'::jsonb) else '[]'::jsonb end,
    'meals', case when p.share_meals then coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', m.id,
          'eaten_at', m.eaten_at,
          'name', m.name,
          'meal_type', m.meal_type,
          'calories', m.calories,
          'protein', case when p.share_macros then m.protein end,
          'carbs',   case when p.share_macros then m.carbs end,
          'fat',     case when p.share_macros then m.fat end,
          'photo_path', m.photo_path
        ) order by m.eaten_at desc)
        from shared_meals m
        where m.user_id = p.id and m.eaten_at > now() - make_interval(days => p_days)
      ), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- ───────────────────────── Meal photo storage ─────────────────────────
-- Private bucket. Files live at <user id>/<meal id>.jpg.

insert into storage.buckets (id, name, public)
values ('meal-photos', 'meal-photos', false)
on conflict (id) do nothing;

drop policy if exists "meal photos: owner insert" on storage.objects;
create policy "meal photos: owner insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "meal photos: owner update" on storage.objects;
create policy "meal photos: owner update" on storage.objects
  for update to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "meal photos: owner delete" on storage.objects;
create policy "meal photos: owner delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'meal-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "meal photos: owner or friend read" on storage.objects;
create policy "meal photos: owner or friend read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'meal-photos' and (
      (storage.foldername(name))[1] = auth.uid()::text
      or public.can_view_meal_photos(((storage.foldername(name))[1])::uuid)
    )
  );
