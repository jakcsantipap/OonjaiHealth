-- Capture flow: chat, extraction job, pending card, confirm, and history.
-- Family invites, medication reminders, and PDF reports stay out of this step.

comment on table public.health_profiles is
  'Person whose health data this is. Separate from the login account. This migration only opens a self profile; profiles for other people wait for an explicit consent step.';

comment on table public.profile_access is
  'Server-side permission for a login to a health profile. Choosing a name on screen is not enough. Rows are created by the signup trigger.';

create table public.chat_threads (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null unique references public.health_profiles (id) on delete cascade,
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now()
);

create index chat_threads_created_by_idx on public.chat_threads (created_by);

create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references public.chat_threads (id) on delete cascade,
  profile_id uuid not null references public.health_profiles (id) on delete cascade,
  body text not null,
  sent_at timestamptz not null default now(),
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint chat_messages_body_len check (char_length(body) between 1 and 4000)
);

create index chat_messages_thread_sent_idx on public.chat_messages (thread_id, sent_at);
create index chat_messages_profile_id_idx on public.chat_messages (profile_id);
create index chat_messages_created_by_idx on public.chat_messages (created_by);

comment on column public.chat_messages.body is
  'What the person typed. Stored as data, never executed as a command.';

create table public.extraction_jobs (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.health_profiles (id) on delete cascade,
  message_id uuid references public.chat_messages (id) on delete restrict,
  status text not null default 'received',
  error_message text,
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz,
  constraint extraction_jobs_status_known check (
    status in ('received', 'processing', 'awaiting_confirm', 'succeeded', 'failed')
  ),
  constraint extraction_jobs_error_len check (error_message is null or char_length(error_message) <= 500)
);

create index extraction_jobs_profile_status_idx on public.extraction_jobs (profile_id, status);
create index extraction_jobs_message_id_idx on public.extraction_jobs (message_id);
create index extraction_jobs_created_by_idx on public.extraction_jobs (created_by);

comment on table public.extraction_jobs is
  'State of one capture: received, processing, awaiting confirmation, succeeded, or failed. A chat reply is not proof that a reading was saved.';

create table public.health_entries (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.health_profiles (id) on delete cascade,
  job_id uuid references public.extraction_jobs (id) on delete restrict,
  message_id uuid references public.chat_messages (id) on delete restrict,
  kind text not null,
  status text not null default 'pending',
  value_primary numeric not null,
  value_secondary numeric,
  unit text not null,
  sugar_context text,
  measured_at timestamptz,
  sent_at timestamptz not null,
  source_type text not null,
  source_text text,
  details jsonb not null default '{}'::jsonb,
  idempotency_key text not null,
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  confirmed_by uuid references auth.users (id) on delete restrict,
  constraint health_entries_kind_known check (kind in ('sugar', 'bp', 'weight')),
  constraint health_entries_status_known check (status in ('pending', 'confirmed', 'cancelled')),
  constraint health_entries_source_known check (source_type in ('typed', 'voice', 'image', 'form', 'caregiver')),
  constraint health_entries_value_nonnegative check (value_primary >= 0 and (value_secondary is null or value_secondary >= 0)),
  constraint health_entries_shape check (
    (
      kind = 'sugar'
      and value_secondary is null
      and unit = 'mg/dL'
      and (sugar_context is null or sugar_context in ('before', 'after'))
    )
    or (
      kind = 'bp'
      and value_secondary is not null
      and unit = 'mmHg'
      and sugar_context is null
    )
    or (
      kind = 'weight'
      and value_secondary is null
      and unit = 'kg'
      and sugar_context is null
    )
  ),
  constraint health_entries_source_text_len check (source_text is null or char_length(source_text) <= 4000),
  constraint health_entries_idempotency_len check (char_length(idempotency_key) between 8 and 200),
  constraint health_entries_details_object check (jsonb_typeof(details) = 'object'),
  constraint health_entries_confirm_pair check (
    (status = 'confirmed' and confirmed_at is not null and confirmed_by is not null)
    or (status <> 'confirmed' and confirmed_at is null and confirmed_by is null)
  ),
  constraint health_entries_profile_idempotency unique (profile_id, idempotency_key)
);

create index health_entries_profile_status_kind_idx
  on public.health_entries (profile_id, status, kind, measured_at);

create index health_entries_job_id_idx on public.health_entries (job_id);
create index health_entries_message_id_idx on public.health_entries (message_id);
create index health_entries_created_by_idx on public.health_entries (created_by);
create index health_entries_confirmed_by_idx on public.health_entries (confirmed_by);

comment on table public.health_entries is
  'One captured reading. Pending rows are not confirmed history. sugar_context stays null unless the person stated before or after a meal.';

comment on column public.health_entries.sent_at is 'When the message was sent.';
comment on column public.health_entries.measured_at is 'When the reading was taken, if known. Null means the time was not stated.';
comment on column public.health_entries.details is
  'Reserved for later fields such as a reference range copied from a document. Never treated as a command.';

create table public.health_entry_revisions (
  id uuid primary key default gen_random_uuid(),
  entry_id uuid not null references public.health_entries (id) on delete cascade,
  profile_id uuid not null references public.health_profiles (id) on delete cascade,
  action text not null,
  actor_id uuid references auth.users (id) on delete restrict,
  before_row jsonb,
  after_row jsonb,
  created_at timestamptz not null default now(),
  constraint health_entry_revisions_action_known check (action in ('create', 'edit', 'confirm', 'cancel'))
);

create index health_entry_revisions_entry_created_idx
  on public.health_entry_revisions (entry_id, created_at);

create index health_entry_revisions_profile_id_idx on public.health_entry_revisions (profile_id);
create index health_entry_revisions_actor_id_idx on public.health_entry_revisions (actor_id);

comment on table public.health_entry_revisions is
  'Append-only history of a reading. Clients can read it and cannot write it.';

create or replace function private.guard_health_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.relationship <> 'self' then
      raise exception 'โปรไฟล์ของคนอื่นยังไม่เปิดในขั้นนี้' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.created_by is distinct from old.created_by
     or new.relationship is distinct from old.relationship
     or new.archived_at is distinct from old.archived_at then
    raise exception 'เปลี่ยนได้เฉพาะชื่อที่แสดง' using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger health_profiles_guard
before insert or update on public.health_profiles
for each row execute function private.guard_health_profile();

create or replace function private.provision_health_profile()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profile_access (
    profile_id, user_id, can_view, can_add, can_edit, can_manage, granted_by
  ) values (
    new.id, new.created_by, true, true, true, true, new.created_by
  );

  insert into public.chat_threads (profile_id, created_by)
  values (new.id, new.created_by);

  return new;
end;
$$;

create trigger health_profiles_provision
after insert on public.health_profiles
for each row execute function private.provision_health_profile();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  chosen_name text;
begin
  chosen_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');
  if chosen_name is null or char_length(chosen_name) > 80 then
    chosen_name := 'ฉัน';
  end if;

  insert into public.health_profiles (display_name, relationship, created_by)
  values (chosen_name, 'self', new.id);

  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();

create or replace function private.guard_chat_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  thread_profile uuid;
begin
  select thread.profile_id into thread_profile
  from public.chat_threads as thread
  where thread.id = new.thread_id;

  if thread_profile is null or thread_profile is distinct from new.profile_id then
    raise exception 'ข้อความไม่ได้อยู่ในสมุดของโปรไฟล์นี้' using errcode = 'check_violation';
  end if;

  if (select auth.uid()) is not null and new.created_by is distinct from (select auth.uid()) then
    raise exception 'บันทึกได้เฉพาะในชื่อบัญชีที่ล็อกอิน' using errcode = 'check_violation';
  end if;

  return new;
end;
$$;

create trigger chat_messages_guard
before insert on public.chat_messages
for each row execute function private.guard_chat_message();

create or replace function private.guard_extraction_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'received' then
      raise exception 'งานใหม่ต้องเริ่มที่สถานะรับข้อมูล' using errcode = 'check_violation';
    end if;
    if (select auth.uid()) is not null and new.created_by is distinct from (select auth.uid()) then
      raise exception 'บันทึกได้เฉพาะในชื่อบัญชีที่ล็อกอิน' using errcode = 'check_violation';
    end if;
    return new;
  end if;

  if new.profile_id is distinct from old.profile_id
     or new.message_id is distinct from old.message_id
     or new.created_by is distinct from old.created_by then
    raise exception 'เปลี่ยนสถานะงานได้อย่างเดียว' using errcode = 'check_violation';
  end if;

  if not (
    new.status = old.status
    or (old.status = 'received' and new.status in ('processing', 'failed'))
    or (old.status = 'processing' and new.status in ('awaiting_confirm', 'failed'))
    or (old.status = 'awaiting_confirm' and new.status in ('succeeded', 'failed'))
  ) then
    raise exception 'ลำดับสถานะของงานไม่ถูกต้อง' using errcode = 'check_violation';
  end if;

  if new.status in ('succeeded', 'failed') and old.status is distinct from new.status then
    new.finished_at := now();
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger extraction_jobs_guard
before insert or update on public.extraction_jobs
for each row execute function private.guard_extraction_job();

create or replace function private.guard_health_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.status <> 'pending' then
      raise exception 'รายการใหม่ต้องรอการยืนยัน' using errcode = 'check_violation';
    end if;
    if (select auth.uid()) is not null and new.created_by is distinct from (select auth.uid()) then
      raise exception 'บันทึกได้เฉพาะในชื่อบัญชีที่ล็อกอิน' using errcode = 'check_violation';
    end if;
    new.confirmed_at := null;
    new.confirmed_by := null;
    return new;
  end if;

  if new.profile_id is distinct from old.profile_id
     or new.kind is distinct from old.kind
     or new.created_by is distinct from old.created_by
     or new.idempotency_key is distinct from old.idempotency_key
     or new.job_id is distinct from old.job_id
     or new.message_id is distinct from old.message_id
     or new.source_type is distinct from old.source_type
     or new.source_text is distinct from old.source_text
     or new.sent_at is distinct from old.sent_at then
    raise exception 'เปลี่ยนได้เฉพาะค่าที่ยังรอยืนยัน หรือสถานะยืนยันและยกเลิก' using errcode = 'check_violation';
  end if;

  if old.status = 'confirmed'
     and new.status = 'confirmed'
     and new.value_primary is not distinct from old.value_primary
     and new.value_secondary is not distinct from old.value_secondary
     and new.unit is not distinct from old.unit
     and new.sugar_context is not distinct from old.sugar_context
     and new.measured_at is not distinct from old.measured_at
     and new.details is not distinct from old.details then
    return old;
  end if;

  if old.status = 'cancelled' or old.status = 'confirmed' then
    raise exception 'รายการที่ยืนยันหรือยกเลิกแล้วเปลี่ยนค่าไม่ได้' using errcode = 'check_violation';
  end if;

  if new.status = 'confirmed' then
    new.confirmed_at := now();
    new.confirmed_by := (select auth.uid());
  elsif new.status = 'cancelled' then
    new.confirmed_at := null;
    new.confirmed_by := null;
  elsif new.status = 'pending' then
    new.confirmed_at := null;
    new.confirmed_by := null;
  else
    raise exception 'สถานะรายการไม่ถูกต้อง' using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger health_entries_guard
before insert or update on public.health_entries
for each row execute function private.guard_health_entry();

create or replace function private.audit_health_entry()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_action text;
begin
  if tg_op = 'INSERT' then
    insert into public.health_entry_revisions (entry_id, profile_id, action, actor_id, before_row, after_row)
    values (new.id, new.profile_id, 'create', (select auth.uid()), null, to_jsonb(new));
    return new;
  end if;

  if new is not distinct from old then
    return new;
  end if;

  next_action := case new.status
    when 'confirmed' then 'confirm'
    when 'cancelled' then 'cancel'
    else 'edit'
  end;

  insert into public.health_entry_revisions (entry_id, profile_id, action, actor_id, before_row, after_row)
  values (new.id, new.profile_id, next_action, (select auth.uid()), to_jsonb(old), to_jsonb(new));

  return new;
end;
$$;

create trigger health_entries_audit
after insert or update on public.health_entries
for each row execute function private.audit_health_entry();

revoke all on function private.guard_health_profile() from public;
revoke all on function private.provision_health_profile() from public;
revoke all on function private.handle_new_user() from public;
revoke all on function private.guard_chat_message() from public;
revoke all on function private.guard_extraction_job() from public;
revoke all on function private.guard_health_entry() from public;
revoke all on function private.audit_health_entry() from public;

grant execute on function private.guard_health_profile() to authenticated, supabase_auth_admin;
grant execute on function private.provision_health_profile() to authenticated, supabase_auth_admin;
grant execute on function private.handle_new_user() to supabase_auth_admin;
grant execute on function private.guard_chat_message() to authenticated;
grant execute on function private.guard_extraction_job() to authenticated;
grant execute on function private.guard_health_entry() to authenticated;
grant execute on function private.audit_health_entry() to authenticated;
grant usage on schema private to supabase_auth_admin;

create view public.confirmed_health_entries
with (security_invoker = true) as
select
  id,
  profile_id,
  job_id,
  message_id,
  kind,
  value_primary,
  value_secondary,
  unit,
  sugar_context,
  measured_at,
  sent_at,
  source_type,
  source_text,
  details,
  created_by,
  created_at,
  updated_at,
  confirmed_at,
  confirmed_by
from public.health_entries
where status = 'confirmed';

comment on view public.confirmed_health_entries is
  'Confirmed readings only. Pending cards must not be charted from this view.';

alter table public.health_profiles enable row level security;
alter table public.profile_access enable row level security;
alter table public.chat_threads enable row level security;
alter table public.chat_messages enable row level security;
alter table public.extraction_jobs enable row level security;
alter table public.health_entries enable row level security;
alter table public.health_entry_revisions enable row level security;

alter table public.health_profiles force row level security;
alter table public.profile_access force row level security;
alter table public.chat_threads force row level security;
alter table public.chat_messages force row level security;
alter table public.extraction_jobs force row level security;
alter table public.health_entries force row level security;
alter table public.health_entry_revisions force row level security;

revoke all on table public.health_profiles from anon, authenticated;
revoke all on table public.profile_access from anon, authenticated;
revoke all on table public.chat_threads from anon, authenticated;
revoke all on table public.chat_messages from anon, authenticated;
revoke all on table public.extraction_jobs from anon, authenticated;
revoke all on table public.health_entries from anon, authenticated;
revoke all on table public.health_entry_revisions from anon, authenticated;
revoke all on table public.confirmed_health_entries from anon, authenticated;

grant select, update on table public.health_profiles to authenticated;
grant select on table public.profile_access to authenticated;
grant select on table public.chat_threads to authenticated;
grant select, insert on table public.chat_messages to authenticated;
grant select, insert, update on table public.extraction_jobs to authenticated;
grant select, insert, update on table public.health_entries to authenticated;
grant select on table public.health_entry_revisions to authenticated;
grant select on table public.confirmed_health_entries to authenticated;

create policy health_profiles_select on public.health_profiles
for select to authenticated
using ((select private.has_profile_access(id, 'view')));

create policy health_profiles_update on public.health_profiles
for update to authenticated
using ((select private.has_profile_access(id, 'manage')))
with check ((select private.has_profile_access(id, 'manage')));

create policy profile_access_select on public.profile_access
for select to authenticated
using (
  user_id = (select auth.uid())
  or (select private.has_profile_access(profile_id, 'manage'))
);

create policy chat_threads_select on public.chat_threads
for select to authenticated
using ((select private.has_profile_access(profile_id, 'view')));

create policy chat_messages_select on public.chat_messages
for select to authenticated
using ((select private.has_profile_access(profile_id, 'view')));

create policy chat_messages_insert on public.chat_messages
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and (select private.has_profile_access(profile_id, 'add'))
);

create policy extraction_jobs_select on public.extraction_jobs
for select to authenticated
using ((select private.has_profile_access(profile_id, 'view')));

create policy extraction_jobs_insert on public.extraction_jobs
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and status = 'received'
  and (select private.has_profile_access(profile_id, 'add'))
);

create policy extraction_jobs_update on public.extraction_jobs
for update to authenticated
using ((select private.has_profile_access(profile_id, 'add')))
with check ((select private.has_profile_access(profile_id, 'add')));

create policy health_entries_select on public.health_entries
for select to authenticated
using ((select private.has_profile_access(profile_id, 'view')));

create policy health_entries_insert on public.health_entries
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and status = 'pending'
  and (select private.has_profile_access(profile_id, 'add'))
);

create policy health_entries_update on public.health_entries
for update to authenticated
using ((select private.has_profile_access(profile_id, 'edit')))
with check ((select private.has_profile_access(profile_id, 'edit')));

create policy health_entry_revisions_select on public.health_entry_revisions
for select to authenticated
using ((select private.has_profile_access(profile_id, 'view')));
