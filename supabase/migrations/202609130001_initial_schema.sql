create extension if not exists pgcrypto;

create type public.task_source as enum ('parent_template', 'long_plan', 'automatic_wrong_review');
create type public.task_status as enum ('scheduled', 'ready', 'in_progress', 'paused', 'completed', 'skipped', 'expired');
create type public.mastery_status as enum ('unmastered', 'practicing', 'review_due', 'mastered');
create type public.redemption_status as enum ('requested', 'approved', 'rejected', 'fulfilled', 'cancelled', 'expired');

create table public.families (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'Asia/Shanghai',
  owner_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.family_members (
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('admin', 'parent')),
  primary key (family_id, user_id)
);

create table public.children (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  nickname text not null,
  grade smallint not null check (grade between 1 and 6),
  created_at timestamptz not null default now()
);

create table public.wallets (
  child_id uuid primary key references public.children(id) on delete cascade,
  coin_balance integer not null default 0 check (coin_balance >= 0),
  frozen_balance integer not null default 0 check (frozen_balance >= 0),
  xp integer not null default 0 check (xp >= 0),
  updated_at timestamptz not null default now()
);

create table public.wrong_questions (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  subject text not null check (subject in ('chinese', 'math', 'english')),
  final_text text not null,
  knowledge_point text,
  mastery_status public.mastery_status not null default 'unmastered',
  wrong_count integer not null default 1,
  review_due_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.task_instances (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  title text not null,
  due_date date not null,
  source_type public.task_source not null,
  status public.task_status not null default 'ready',
  coin_reward integer not null default 0,
  xp_reward integer not null default 0,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create unique index task_instances_one_auto_review_per_day_idx
  on public.task_instances (child_id, due_date, source_type)
  where source_type = 'automatic_wrong_review';

create table public.task_review_items (
  task_instance_id uuid not null references public.task_instances(id) on delete cascade,
  wrong_question_id uuid not null references public.wrong_questions(id) on delete cascade,
  sequence smallint not null,
  result boolean,
  answered_at timestamptz,
  primary key (task_instance_id, wrong_question_id),
  unique (task_instance_id, sequence)
);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  child_id uuid not null references public.children(id) on delete cascade,
  asset_type text not null check (asset_type in ('coin', 'xp')),
  amount integer not null,
  source_type text not null,
  source_id uuid,
  idempotency_key text not null unique,
  created_at timestamptz not null default now()
);

create table public.rewards (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  title text not null,
  cost integer not null check (cost > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.redemptions (
  id uuid primary key default gen_random_uuid(),
  reward_id uuid not null references public.rewards(id),
  child_id uuid not null references public.children(id) on delete cascade,
  status public.redemption_status not null default 'requested',
  frozen_amount integer not null check (frozen_amount > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  family_id uuid not null references public.families(id) on delete cascade,
  actor_user_id uuid references auth.users(id),
  action text not null,
  target_type text not null,
  target_id text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index wrong_questions_review_due_idx
  on public.wrong_questions (child_id, review_due_at)
  where mastery_status <> 'mastered';

alter table public.families enable row level security;
alter table public.family_members enable row level security;
alter table public.children enable row level security;
alter table public.wallets enable row level security;
alter table public.wrong_questions enable row level security;
alter table public.task_instances enable row level security;
alter table public.task_review_items enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.rewards enable row level security;
alter table public.redemptions enable row level security;
alter table public.audit_logs enable row level security;

create or replace function public.is_family_member(target_family_id uuid)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (
  select 1 from public.family_members fm
  where fm.family_id = target_family_id and fm.user_id = auth.uid()
) $$;

create policy families_select on public.families for select
  using (public.is_family_member(id) or owner_user_id = auth.uid());
create policy children_all on public.children for all
  using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));
