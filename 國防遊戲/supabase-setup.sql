-- 檢傷分類遊戲 排行榜
-- 用法：Supabase 後台 → SQL Editor → 貼上整段 → Run（只需執行一次，重複執行也安全）

-- 1. 成績資料表：每玩完一局送出一筆
create table if not exists public.triage_scores (
  id         bigint generated always as identity primary key,
  name       text        not null check (char_length(name) between 1 and 12),
  score      integer     not null check (score between 0 and 2000),  -- 10 題 × 每題最高 200 分
  correct    integer     not null check (correct between 0 and 10),
  created_at timestamptz not null default now()
);

create index if not exists triage_scores_name_score_idx
  on public.triage_scores (name, score desc, created_at);

-- 2. 權限：任何人都可以「讀取」與「新增」，但不能修改或刪除別人的成績
alter table public.triage_scores enable row level security;

drop policy if exists "triage_scores_read"   on public.triage_scores;
drop policy if exists "triage_scores_insert" on public.triage_scores;

create policy "triage_scores_read"   on public.triage_scores
  for select to anon, authenticated using (true);
create policy "triage_scores_insert" on public.triage_scores
  for insert to anon, authenticated with check (true);

grant select, insert on public.triage_scores to anon, authenticated;

-- 3. 排行榜檢視表：同一個暱稱只留最高分（同分時取較早的那一筆）
create or replace view public.triage_leaderboard
  with (security_invoker = on) as
select distinct on (name) name, score, correct, created_at
from public.triage_scores
order by name, score desc, created_at asc;

grant select on public.triage_leaderboard to anon, authenticated;

-- 想清空排行榜時執行：  truncate table public.triage_scores;
