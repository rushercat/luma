-- ============================================================================
-- LUMA — Supabase schema
-- Paste this entire file into: Supabase Dashboard → SQL Editor → New query.
-- Run once per project. Safe to re-run (uses "if not exists" / drop-first).
-- ============================================================================
--
-- We deliberately DO NOT store:
--   • face images / video
--   • face landmarks
--   • any biometric template or embedding
--
-- We only store derived, non-identifying metrics (face shape class, tone name,
-- ITA score, etc.) + user preferences.
-- ============================================================================

-- 1) PROFILES ---------------------------------------------------------------
-- One row per user, keyed by auth.users.id (the Supabase-issued uuid).
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 2) SCANS ------------------------------------------------------------------
-- One row per completed face scan. Derived metrics only.
create table if not exists public.scans (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,

  -- Face shape classification (from landmarks, aggregate only)
  face_shape       text,
  face_shape_sub   text,

  -- Tone & undertone (recommended shade snapshot)
  tone_id        text,
  tone_name      text,
  tone_color     text,    -- hex for quick render; not a biometric
  tone_undertone text,
  ita            numeric, -- Individual Typology Angle
  confidence     int,     -- 0..100 self-reported confidence

  -- Skin type (derived)
  skin_type     text,
  skin_type_sub text,

  -- Liveness + capture-quality metadata (no biometric data)
  -- { yawDeg, pitchDeg, brightness, sharpness, coverage, challenges:{first,second,blink} }
  liveness jsonb,

  -- Optional demographic inferences (from face-api, if available)
  expression text,
  age        int,

  created_at timestamptz not null default now()
);

create index if not exists scans_profile_created_idx
  on public.scans (profile_id, created_at desc);

-- 3) PREFERENCES ------------------------------------------------------------
-- One row per user, upserted on change.
create table if not exists public.preferences (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  budget int,
  prefs jsonb,                -- e.g. ["Cruelty-free","Vegan"]
  concerns jsonb,             -- e.g. ["Acne","Dryness"]
  coverage text,              -- 'Light' | 'Medium' | 'Full'
  preferred_brands jsonb,     -- e.g. ["NARS","Rare Beauty"] — soft highlight only
  selected_tone_id text,
  updated_at timestamptz not null default now()
);
-- Safe migration for databases created before preferred_brands existed.
alter table public.preferences
  add column if not exists preferred_brands jsonb;

-- 4) SAVED PRODUCTS ---------------------------------------------------------
-- Many rows per user. Composite key (profile + brand + name).
create table if not exists public.saved_products (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  brand text not null,
  name  text not null,
  saved_at timestamptz not null default now(),
  primary key (profile_id, brand, name)
);

-- 5) VISITS -----------------------------------------------------------------
-- One row per site visit (session-granular). Captures approximate location
-- via client-side IP geolocation (no PII, no IP stored). Anyone can INSERT,
-- but only the admin email can SELECT — so normal users can't read analytics.
create table if not exists public.visits (
  id uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  country      text,        -- full name, e.g. "Germany"
  country_code text,        -- ISO-2, e.g. "DE"
  city         text,        -- e.g. "Berlin"
  region       text,        -- state/region
  path         text,        -- page path like "/" or "/#profile"
  referrer     text,        -- document.referrer if present
  session_id   text         -- random per-session id (dedupes reloads client-side)
);

create index if not exists visits_created_at_idx
  on public.visits (created_at desc);
create index if not exists visits_country_idx
  on public.visits (country_code);

-- ============================================================================
-- Row Level Security — every user sees only their own rows.
-- ============================================================================
alter table public.profiles         enable row level security;
alter table public.scans            enable row level security;
alter table public.preferences      enable row level security;
alter table public.saved_products   enable row level security;
alter table public.visits           enable row level security;

-- Drop existing policies first so this script is idempotent.
drop policy if exists "profiles_self"        on public.profiles;
drop policy if exists "scans_self"           on public.scans;
drop policy if exists "preferences_self"     on public.preferences;
drop policy if exists "saved_products_self"  on public.saved_products;
drop policy if exists "visits_insert_any"    on public.visits;
drop policy if exists "visits_select_admin"  on public.visits;

create policy "profiles_self"
  on public.profiles
  for all
  using  (auth.uid() = id)
  with check (auth.uid() = id);

create policy "scans_self"
  on public.scans
  for all
  using  (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

create policy "preferences_self"
  on public.preferences
  for all
  using  (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

create policy "saved_products_self"
  on public.saved_products
  for all
  using  (auth.uid() = profile_id)
  with check (auth.uid() = profile_id);

-- Anyone (even anonymous visitors) can log a visit — but cannot read them back.
create policy "visits_insert_any"
  on public.visits
  for insert
  to anon, authenticated
  with check (true);

-- Only the admin email can read the visits table. Keep this email in sync
-- with LUMA_ADMIN_EMAIL in index.html.
create policy "visits_select_admin"
  on public.visits
  for select
  to authenticated
  using (
    auth.jwt() ->> 'email' = 'kvboxberg9999@gmail.com'
  );

-- ============================================================================
-- Auto-create a profile row the first time someone signs up.
-- ============================================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ============================================================================
-- Convenience: touch updated_at on profile/preferences updates.
-- ============================================================================
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch
  before update on public.profiles
  for each row execute procedure public.touch_updated_at();

drop trigger if exists preferences_touch on public.preferences;
create trigger preferences_touch
  before update on public.preferences
  for each row execute procedure public.touch_updated_at();

-- ============================================================================
-- Self-service account deletion.
-- A signed-in user can fully delete their own account (auth row + all data,
-- cascaded via our foreign keys). The function runs as "security definer",
-- but enforces `id = auth.uid()` so a user can only delete themselves.
-- ============================================================================
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  -- Cascade kicks in via profiles.id → auth.users(id) ON DELETE CASCADE,
  -- which in turn cascades into scans / preferences / saved_products.
  delete from auth.users where id = auth.uid();
end;
$$;

-- Only logged-in users can call this.
revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

-- ============================================================================
-- Done. Next steps:
--   1. Supabase Dashboard → Authentication → Providers → Email
--      • Leave "Email" enabled.
--      • (Optional) Turn OFF "Confirm email" for frictionless sign-in;
--        otherwise users must click a verification link first.
--   2. Supabase Dashboard → Project Settings → API
--      • Copy "Project URL" and "anon public" key into index.html
--        where it says LUMA_SUPABASE_URL / LUMA_SUPABASE_ANON_KEY.
-- ============================================================================
