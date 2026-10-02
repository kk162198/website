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

-- 4. 頒獎狀態：stats.html 的頒獎台每揭曉一位就寫進這裡，手機領獎頁 award.html 只讀得到「已經揭曉」的名次
--    資料表本身不開放讀寫，只能透過下面兩個函式存取。
create table if not exists public.triage_award (
  id         integer     primary key check (id = 1),   -- 只有一列
  pass_hash  text,                                      -- 頒獎密碼的 SHA-256；第一次在 stats.html 輸入的密碼會存進來
  revealed   integer     not null default 0,            -- 已揭曉幾位（從最後一名往前數）
  winners    jsonb,                                     -- 按下「開始頒獎」時固定下來的得獎名單
  updated_at timestamptz not null default now()
);
alter table public.triage_award enable row level security;
revoke all on public.triage_award from anon, authenticated;

-- 4a. 讀取：只回傳已揭曉的名次
create or replace function public.triage_award_state()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'ready',    a.pass_hash is not null,
    'total',    coalesce(jsonb_array_length(a.winners), 0),
    'revealed', coalesce(a.revealed, 0),
    'winners',  (select coalesce(jsonb_agg(e.v order by e.i), '[]'::jsonb)
                 from jsonb_array_elements(coalesce(a.winners, '[]'::jsonb)) with ordinality as e(v, i)
                 where e.i > jsonb_array_length(a.winners) - a.revealed))
  from (select 1) x left join public.triage_award a on a.id = 1;
$$;

-- 4b. 寫入：需要頒獎密碼（資料庫裡還沒有密碼時，第一次輸入的就成為正式密碼）
create or replace function public.triage_award_set(p_pass text, p_revealed integer, p_winners jsonb default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  h text := encode(sha256(convert_to(coalesce(p_pass, ''), 'UTF8')), 'hex');
  old text;
begin
  if char_length(coalesce(p_pass, '')) < 4 then raise exception 'short_pass'; end if;
  if p_winners is not null and (jsonb_typeof(p_winners) <> 'array' or jsonb_array_length(p_winners) > 20) then
    raise exception 'bad_winners';
  end if;
  insert into public.triage_award (id) values (1) on conflict (id) do nothing;
  select pass_hash into old from public.triage_award where id = 1 for update;
  if old is not null and old <> h then raise exception 'bad_pass'; end if;
  update public.triage_award
     set pass_hash  = h,
         winners    = coalesce(p_winners, winners),
         revealed   = greatest(0, least(coalesce(p_revealed, 0), coalesce(jsonb_array_length(coalesce(p_winners, winners)), 0))),
         updated_at = now()
   where id = 1;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.triage_award_state() from public;
revoke all on function public.triage_award_set(text, integer, jsonb) from public;
grant execute on function public.triage_award_state() to anon, authenticated;
grant execute on function public.triage_award_set(text, integer, jsonb) to anon, authenticated;

-- 忘記頒獎密碼、或想把領獎頁恢復成「尚未揭曉」時執行（之後第一次輸入的密碼會成為新密碼）：
--   update public.triage_award set pass_hash = null, revealed = 0, winners = null;

-- 5. 場次：每頒完一次獎（或在 stats.html 按「封存目前場次」）就新增一列。
--    成績本身不記場次，而是用時間切：上一場結束之後、到這一場 ended_at 為止送出的成績，都算這一場；
--    最後一場結束之後的成績是「目前場次」。所以刪掉某一列，它的成績就自動併入下一場。
create table if not exists public.triage_batch (
  id       bigint generated always as identity primary key,
  name     text        not null check (char_length(name) between 1 and 30),  -- 場次名稱，例如班級
  ended_at timestamptz not null default now(),
  winners  jsonb                                                              -- 頒獎當時的得獎名單（沒頒獎就封存則為 null）
);
create index if not exists triage_batch_ended_idx on public.triage_batch (ended_at);
create index if not exists triage_scores_created_idx on public.triage_scores (created_at);

alter table public.triage_batch enable row level security;
drop policy if exists "triage_batch_read" on public.triage_batch;
create policy "triage_batch_read" on public.triage_batch for select to anon, authenticated using (true);
revoke all on public.triage_batch from anon, authenticated;
grant select on public.triage_batch to anon, authenticated;   -- 只能讀；新增／改名／刪除要走下面的函式

-- 5a. 檢查頒獎密碼（資料庫裡還沒有密碼時，第一次輸入的就成為正式密碼）。只給下面的函式內部使用。
create or replace function public.triage_pass_check(p_pass text)
returns void language plpgsql security definer set search_path = public as $$
declare
  h text := encode(sha256(convert_to(coalesce(p_pass, ''), 'UTF8')), 'hex');
  old text;
begin
  if char_length(coalesce(p_pass, '')) < 4 then raise exception 'short_pass'; end if;
  insert into public.triage_award (id) values (1) on conflict (id) do nothing;
  select pass_hash into old from public.triage_award where id = 1 for update;
  if old is null then update public.triage_award set pass_hash = h where id = 1;
  elsif old <> h then raise exception 'bad_pass';
  end if;
end;
$$;
revoke all on function public.triage_pass_check(text) from public, anon, authenticated;

-- 5b. 場次管理：p_action = 'close'（封存目前場次）／'rename'／'delete'
create or replace function public.triage_batch_do(p_pass text, p_action text, p_id bigint default null, p_name text default null, p_winners jsonb default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  n text := left(btrim(coalesce(p_name, '')), 30);
  new_id bigint := p_id;
begin
  perform public.triage_pass_check(p_pass);
  if p_action = 'close' then
    if n = '' then raise exception 'bad_name'; end if;
    insert into public.triage_batch (name, winners) values (n, p_winners) returning id into new_id;
  elsif p_action = 'rename' then
    if n = '' then raise exception 'bad_name'; end if;
    update public.triage_batch set name = n where id = p_id;
  elsif p_action = 'delete' then
    delete from public.triage_batch where id = p_id;
  else
    raise exception 'bad_action';
  end if;
  return json_build_object('ok', true, 'id', new_id);
end;
$$;
revoke all on function public.triage_batch_do(text, text, bigint, text, jsonb) from public;
grant execute on function public.triage_batch_do(text, text, bigint, text, jsonb) to anon, authenticated;

-- 讓 API 立刻認得新欄位與新函式
notify pgrst, 'reload schema';

-- 想清空排行榜時執行：  truncate table public.triage_scores;
