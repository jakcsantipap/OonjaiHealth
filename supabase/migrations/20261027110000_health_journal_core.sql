-- Profiles and the server-side access check.
-- The capture flow (chat, cards, confirmation, history) is the next migration.

create schema if not exists private;

revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

create table public.health_profiles (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  relationship text not null default 'self',
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint health_profiles_display_name_len check (char_length(display_name) between 1 and 80),
  constraint health_profiles_relationship_known check (relationship in ('self', 'father', 'mother', 'other'))
);

create unique index health_profiles_one_active_self_idx
  on public.health_profiles (created_by)
  where relationship = 'self' and archived_at is null;

create index health_profiles_created_by_idx on public.health_profiles (created_by);

create table public.profile_access (
  profile_id uuid not null references public.health_profiles (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  can_view boolean not null default false,
  can_add boolean not null default false,
  can_edit boolean not null default false,
  can_manage boolean not null default false,
  granted_by uuid references auth.users (id) on delete restrict,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  primary key (profile_id, user_id),
  constraint profile_access_manage_implies_view check (not can_manage or can_view),
  constraint profile_access_add_implies_view check (not can_add or can_view),
  constraint profile_access_edit_implies_view check (not can_edit or can_view)
);

create index profile_access_user_active_idx
  on public.profile_access (user_id, profile_id)
  where revoked_at is null;

create index profile_access_granted_by_idx on public.profile_access (granted_by);

create or replace function private.has_profile_access(target_profile uuid, flag text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return exists (
    select 1
    from public.profile_access as access_row
    where access_row.profile_id = target_profile
      and access_row.user_id = (select auth.uid())
      and access_row.revoked_at is null
      and case flag
        when 'view' then access_row.can_view
        when 'add' then access_row.can_add
        when 'edit' then access_row.can_edit
        when 'manage' then access_row.can_manage
        else false
      end
  );
end;
$$;

revoke all on function private.has_profile_access(uuid, text) from public;
grant execute on function private.has_profile_access(uuid, text) to authenticated, service_role;
