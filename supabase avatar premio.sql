-- ============================================================
-- AREA 42 Club: AVATARES DE CLIENTES + IMAGEN DEL PREMIO
-- Si ya corriste los otros archivos, corré SOLO este.
-- Supabase > SQL Editor > New query > pegar > Run
-- ============================================================

-- Avatar elegido por cada cliente (número de la lista de avatares)
alter table public.cards  add column if not exists avatar int check (avatar is null or avatar between 0 and 99);
alter table public.orders add column if not exists avatar int check (avatar is null or avatar between 0 and 99);

-- El cliente cambia su avatar con su código secreto de tarjeta
create or replace function public.set_avatar(p_code text, p_avatar int)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_avatar is null or p_avatar < 0 or p_avatar > 99 then raise exception 'Avatar inválido'; end if;
  update public.cards set avatar = p_avatar where code = upper(p_code);
  return found;
end $$;
revoke all on function public.set_avatar(text, int) from public;
grant execute on function public.set_avatar(text, int) to anon, authenticated;

-- get_card ahora incluye el avatar
create or replace function public.get_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c public.cards;
begin
  select * into c from public.cards where code = upper(p_code);
  if not found then return null; end if;
  return json_build_object(
    'code', c.code, 'name', c.name, 'avatar', c.avatar,
    'stickers', coalesce((select json_agg(json_build_object('id', s.id, 'created_at', s.created_at) order by s.id)
                          from public.stickers s where s.card_code = c.code and s.redeemed_at is null), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('id', v.id, 'created_at', v.created_at) order by v.id)
                          from public.vouchers v where v.card_code = c.code and v.status = 'disponible'), '[]'::json),
    'redeemed', (select count(*) from public.vouchers v where v.card_code = c.code)
  );
end $$;

-- deliver_order ahora guarda el avatar del pedido en la tarjeta
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar) values (o.card_code, o.customer_name, o.avatar)
      on conflict (code) do update set name = excluded.name, avatar = coalesce(excluded.avatar, public.cards.avatar);
    insert into public.stickers (card_code, order_id) values (o.card_code, o.id)
      on conflict (order_id) do nothing
      returning id into v_sticker;
    if o.voucher_id is not null then
      update public.vouchers set status = 'usado', used_at = now(), used_order_id = o.id
       where id = o.voucher_id and card_code = o.card_code and status = 'disponible';
      v_used := found;
    end if;
    select count(*) into n from public.stickers where card_code = o.card_code and redeemed_at is null;
  end if;

  return json_build_object('sticker_id', v_sticker, 'active', n,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;
revoke all on function public.deliver_order(bigint) from public, anon;
grant execute on function public.deliver_order(bigint) to authenticated;

-- get_race ahora incluye el avatar de cada nave
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
    select c.code, btrim(c.name) as name, c.avatar, sum(p.qty)::int as qty, max(p.at) as last_at
      from pts p join public.cards c on c.code = p.card_code
     where not c.hide_rank
     group by c.code, c.name, c.avatar
  ), ranked as (
    select code, qty, avatar,
           initcap(split_part(name, ' ', 1)) ||
             case when split_part(name, ' ', 2) <> '' then ' ' || upper(left(split_part(name, ' ', 2), 1)) || '.' else '' end as alias,
           row_number() over (order by qty desc, last_at asc) as pos
      from agg
  )
  select
    coalesce(json_agg(json_build_object('pos', pos, 'name', alias, 'qty', qty, 'avatar', avatar, 'me', code = v_code) order by pos)
             filter (where pos <= 50), '[]'::json),
    (select json_build_object('pos', r2.pos, 'qty', r2.qty) from ranked r2 where r2.code = v_code),
    count(*)
  into v_rows, v_me, v_total
  from ranked;

  return json_build_object('rows', v_rows, 'me', v_me, 'total', coalesce(v_total, 0));
end $$;
revoke all on function public.get_race(text) from public;
grant execute on function public.get_race(text) to anon, authenticated;

-- ---------- Imagen del premio: carpeta pública "premios" ----------
insert into storage.buckets (id, name, public)
values ('premios', 'premios', true)
on conflict (id) do update set public = true;

drop policy if exists "premios: ver" on storage.objects;
create policy "premios: ver" on storage.objects
  for select to anon, authenticated using (bucket_id = 'premios');

drop policy if exists "premios: Santi sube" on storage.objects;
create policy "premios: Santi sube" on storage.objects
  for insert to authenticated with check (bucket_id = 'premios');

drop policy if exists "premios: Santi cambia" on storage.objects;
create policy "premios: Santi cambia" on storage.objects
  for update to authenticated using (bucket_id = 'premios');

drop policy if exists "premios: Santi borra" on storage.objects;
create policy "premios: Santi borra" on storage.objects
  for delete to authenticated using (bucket_id = 'premios');
