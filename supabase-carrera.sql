-- ============================================================
-- Los Marcianitos de Santi: CARRERA GALÁCTICA (ranking público)
-- Si ya corriste los otros archivos, corré SOLO este.
-- Supabase > SQL Editor > New query > pegar > Run
-- ============================================================

-- Santi puede ocultar a un cliente del ranking
alter table public.cards add column if not exists hide_rank boolean not null default false;

-- Marcianitos vendidos en persona que suman a la carrera
create table if not exists public.race_bonus (
  id         bigint generated always as identity primary key,
  card_code  text not null references public.cards(code) on delete cascade,
  qty        int  not null check (qty between 1 and 200),
  created_at timestamptz not null default now()
);
alter table public.race_bonus enable row level security;
drop policy if exists "race_bonus: Santi" on public.race_bonus;
create policy "race_bonus: Santi" on public.race_bonus for all to authenticated using (true) with check (true);
revoke all on public.race_bonus from anon;
grant select, insert, update, delete on public.race_bonus to authenticated;

-- Ranking público. Solo muestra NOMBRE + INICIAL (ej: "Lucía M."), nunca nombres
-- completos, direcciones ni códigos. Si el cliente manda su código, se marca "vos".
create or replace function public.get_race(p_code text default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_since timestamptz := '-infinity';
  v_txt   text;
  v_code  text := upper(coalesce(p_code, ''));
  v_rows  json; v_me json; v_total int;
begin
  select data->>'raceStart' into v_txt from public.config where id = 1;
  if v_txt is not null and v_txt <> '' then
    begin v_since := v_txt::timestamptz; exception when others then v_since := '-infinity'; end;
  end if;

  with pts as (
    select o.card_code, o.qty, o.delivered_at as at
      from public.orders o
     where o.status = 'entregado' and o.card_code is not null and o.delivered_at >= v_since
    union all
    select b.card_code, b.qty, b.created_at
      from public.race_bonus b
     where b.created_at >= v_since
  ), agg as (
    select c.code, btrim(c.name) as name, sum(p.qty)::int as qty, max(p.at) as last_at
      from pts p join public.cards c on c.code = p.card_code
     where not c.hide_rank
     group by c.code, c.name
  ), ranked as (
    select code, qty,
           initcap(split_part(name, ' ', 1)) ||
             case when split_part(name, ' ', 2) <> '' then ' ' || upper(left(split_part(name, ' ', 2), 1)) || '.' else '' end as alias,
           row_number() over (order by qty desc, last_at asc) as pos
      from agg
  )
  select
    coalesce(json_agg(json_build_object('pos', pos, 'name', alias, 'qty', qty, 'me', code = v_code) order by pos)
             filter (where pos <= 50), '[]'::json),
    (select json_build_object('pos', r2.pos, 'qty', r2.qty) from ranked r2 where r2.code = v_code),
    count(*)
  into v_rows, v_me, v_total
  from ranked;

  return json_build_object('rows', v_rows, 'me', v_me, 'total', coalesce(v_total, 0));
end $$;

revoke all on function public.get_race(text) from public;
grant execute on function public.get_race(text) to anon, authenticated;
