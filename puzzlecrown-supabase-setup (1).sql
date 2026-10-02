-- Puzzlecrown: Supabase setup. Paste into Supabase > SQL Editor and run once.
-- Review before use. Test with fake accounts first.

-- 1. PROFILES (private details live here; only the owner can read them)
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  first_name text not null,
  last_name text not null,
  mobile text,
  birth_date date not null,
  gender text,
  country text not null,
  city text,
  occupation text,
  bio text check (char_length(bio) <= 160),
  interests text[] not null default '{}',
  social_handle text,
  heard_from text,
  news_opt_in boolean not null default false,
  avatar_url text,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "own profile: read" on public.profiles for select using (auth.uid() = id);
create policy "own profile: update" on public.profiles for update using (auth.uid() = id);

-- Create the profile automatically when someone signs up.
-- The sign-up form sends these fields as user metadata.
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare m jsonb := new.raw_user_meta_data;
begin
  if (m->>'birth_date')::date > current_date - interval '13 years' then
    raise exception 'You must be at least 13 to join.';
  end if;
  insert into public.profiles (id, username, first_name, last_name, mobile, birth_date,
    gender, country, city, occupation, bio, interests, social_handle, heard_from, news_opt_in)
  values (new.id, m->>'username', m->>'first_name', m->>'last_name', m->>'mobile',
    (m->>'birth_date')::date, m->>'gender', m->>'country', m->>'city', m->>'occupation',
    m->>'bio', coalesce(array(select jsonb_array_elements_text(m->'interests')), '{}'),
    m->>'social_handle', m->>'heard_from', coalesce((m->>'news_opt_in')::boolean, false));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2. PUZZLE SCORES
create table public.scores (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  moves int not null check (moves between 1 and 500),
  seconds int not null check (seconds between 1 and 7200),
  created_at timestamptz not null default now()
);
alter table public.scores enable row level security;
create policy "scores: insert own" on public.scores for insert with check (auth.uid() = user_id);

-- 3. SHOWCASE VIDEOS (new uploads wait for your approval)
create type public.category as enum ('Crafts', 'Skills', 'Puzzle tricks');
create type public.video_status as enum ('pending', 'approved', 'rejected');
create table public.videos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 50),
  category public.category not null,
  storage_path text not null,
  media_type text not null default 'video' check (media_type in ('video', 'image')),
  duration_seconds int check (duration_seconds between 1 and 60),
  status public.video_status not null default 'pending',
  created_at timestamptz not null default now()
);
alter table public.videos enable row level security;
create policy "videos: see approved or own" on public.videos for select
  using (status = 'approved' or auth.uid() = user_id);
create policy "videos: upload own as pending" on public.videos for insert
  with check (auth.uid() = user_id and status = 'pending');
create policy "videos: delete own" on public.videos for delete using (auth.uid() = user_id);

-- 4. VOTES (one row per person per video: a like and/or a 1-5 rating)
create table public.votes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  video_id uuid not null references public.videos(id) on delete cascade,
  liked boolean not null default false,
  rating smallint check (rating between 1 and 5),
  primary key (user_id, video_id)
);
alter table public.votes enable row level security;
create policy "votes: read own" on public.votes for select using (auth.uid() = user_id);
create policy "votes: insert own, not on own video" on public.votes for insert with check (
  auth.uid() = user_id and exists (
    select 1 from public.videos v
    where v.id = video_id and v.status = 'approved' and v.user_id <> auth.uid()));
create policy "votes: update own" on public.votes for update using (auth.uid() = user_id);

-- 5. PUBLIC VIEWS (only safe columns; no birth dates, emails or mobiles)
create view public.leaderboard as
  select * from (
    select distinct on (s.user_id) p.username, s.moves, s.seconds
    from public.scores s join public.profiles p on p.id = s.user_id
    order by s.user_id, s.moves, s.seconds) best
  order by moves, seconds limit 50;

create view public.video_scores as
  select v.id, v.title, v.category, v.storage_path, p.username,
    coalesce(avg(vt.rating), 0) as avg_rating,
    count(vt.rating) as rating_count,
    count(*) filter (where vt.liked) as likes,
    round(coalesce(avg(vt.rating), 0) * 20 + count(*) filter (where vt.liked)) as score
  from public.videos v
  join public.profiles p on p.id = v.user_id
  left join public.votes vt on vt.video_id = v.id
  where v.status = 'approved'
  group by v.id, p.username;

create view public.category_leaders as
  select distinct on (category) * from public.video_scores
  order by category, score desc, rating_count desc, id;

grant select on public.leaderboard, public.video_scores, public.category_leaders to anon, authenticated;

-- 6. VIDEO STORAGE (50 MB cap, video files only, each user writes to their own folder)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 52428800, array['video/mp4', 'video/webm', 'video/quicktime', 'image/png', 'image/jpeg', 'image/webp']);
create policy "upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'videos' and (storage.foldername(name))[1] = auth.uid()::text);

-- 7. PROFILE PICTURES (2 MB cap, images only, each user writes to their own folder)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp']);
create policy "avatar: upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatar: replace own" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
