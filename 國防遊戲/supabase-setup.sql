-- 檢傷分類遊戲 排行榜
-- 用法：Supabase 後台 → SQL Editor → 貼上整段 → Run（只需執行一次，重複執行也安全）

-- 1. 成績資料表：每玩完一局送出一筆
create table if not exists public.triage_scores (
  id         bigint generated always as identity primary key,
  name       text        not null check (char_length(name) between 1 and 12),
  score      integer     not null check (score between 0 and 10000), -- 滿分 10000（含連續答對加成）
  correct    integer     not null check (correct between 0 and 10),
  created_at timestamptz not null default now()
);

-- 1b. 分數上限由 2000 調為 10000（資料表已存在時，上面的 create table 不會更新上限，所以這裡另外改）
alter table public.triage_scores drop constraint if exists triage_scores_score_check;
alter table public.triage_scores add  constraint triage_scores_score_check check (score between 0 and 10000);

-- （選用，只能執行一次）把舊制成績（滿分 2000）換算成新制，讓舊成績還能和新成績比較：
--   update public.triage_scores set score = score * 5 where created_at < '2026-10-03';
-- 或是直接清空重來：
--   truncate table public.triage_scores;

-- 1c. 領獎憑證：送出成績的那支手機的憑證雜湊（SHA-256），領獎頁 award.html 用它確認是不是本人的手機
alter table public.triage_scores add column if not exists claim text;
alter table public.triage_scores drop constraint if exists triage_scores_claim_check;
alter table public.triage_scores add  constraint triage_scores_claim_check check (claim is null or claim ~ '^[0-9a-f]{64}$');

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
select distinct on (name) name, score, correct, created_at, claim
from public.triage_scores
order by name, score desc, created_at asc;

grant select on public.triage_leaderboard to anon, authenticated;

-- 讓 API 立刻認得新欄位
notify pgrst, 'reload schema';

-- 想清空排行榜時執行：  truncate table public.triage_scores;
