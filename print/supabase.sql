-- ============================================================
-- AREA 51 Club: base de datos en Supabase
-- Pegá todo esto en Supabase > SQL Editor > New query > Run
-- ============================================================

-- Configuración pública (horario, precios, sabores, meta).
-- La leen todos los clientes; solo Santi (logueado) la edita.
create table if not exists public.config (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Datos privados de Santi (ventas, tripulantes, medallas).
-- Solo los ve y edita Santi logueado.
create table if not exists public.santi_data (
  id int primary key default 1 check (id = 1),
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

insert into public.config (id, data) values (1, '{}') on conflict (id) do nothing;
insert into public.santi_data (id, data) values (1, '{}') on conflict (id) do nothing;

-- Seguridad por filas (RLS)
alter table public.config enable row level security;
alter table public.santi_data enable row level security;

drop policy if exists "config: lectura publica" on public.config;
create policy "config: lectura publica" on public.config
  for select to anon, authenticated using (true);

drop policy if exists "config: edita Santi" on public.config;
create policy "config: edita Santi" on public.config
  for update to authenticated using (true) with check (true);

drop policy if exists "santi_data: lee Santi" on public.santi_data;
create policy "santi_data: lee Santi" on public.santi_data
  for select to authenticated using (true);

drop policy if exists "santi_data: edita Santi" on public.santi_data;
create policy "santi_data: edita Santi" on public.santi_data
  for update to authenticated using (true) with check (true);

-- Permisos de la API
grant select on public.config to anon, authenticated;
grant update on public.config to authenticated;
grant select, update on public.santi_data to authenticated;

-- ============================================================

create table if not exists public.orders (
  id            bigint generated always as identity primary key,
  created_at    timestamptz not null default now(),
  customer_name text not null check (char_length(customer_name) between 1 and 60),
  address       text not null check (char_length(address) between 1 and 160),
  reference     text check (reference is null or char_length(reference) <= 160),
  items         jsonb not null check (jsonb_typeof(items) = 'array' and jsonb_array_length(items) between 1 and 12),
  combo         text check (combo is null or char_length(combo) <= 200),
  qty           int  not null check (qty between 1 and 600),
  total         int  not null check (total between 0 and 2000000),
  delivery      text check (delivery is null or char_length(delivery) <= 80),
  status        text not null default 'pendiente' check (status in ('pendiente','entregado','cancelado')),
  delivered_at  timestamptz
);

create index if not exists orders_status_created_idx on public.orders (status, created_at);

alter table public.orders enable row level security;

-- Los clientes SOLO pueden crear pedidos nuevos (no pueden ver los de otros)
drop policy if exists "orders: clientes crean" on public.orders;
create policy "orders: clientes crean" on public.orders
  for insert to anon, authenticated with check (status = 'pendiente' and delivered_at is null);

-- Santi (logueado) ve, actualiza y borra
drop policy if exists "orders: Santi lee" on public.orders;
create policy "orders: Santi lee" on public.orders
  for select to authenticated using (true);

drop policy if exists "orders: Santi actualiza" on public.orders;
create policy "orders: Santi actualiza" on public.orders
  for update to authenticated using (true) with check (true);

drop policy if exists "orders: Santi borra" on public.orders;
create policy "orders: Santi borra" on public.orders
  for delete to authenticated using (true);

grant insert on public.orders to anon, authenticated;
grant select, update, delete on public.orders to authenticated;

-- Avisos en tiempo real cuando entra un pedido nuevo
do $$
begin
  alter publication supabase_realtime add table public.orders;
exception when duplicate_object then null;
end $$;

-- ============================================================

-- Pedidos: código de tarjeta del cliente y vale usado
alter table public.orders add column if not exists card_code text
  check (card_code is null or card_code ~ '^[A-Z0-9]{10}$');
alter table public.orders add column if not exists voucher_id bigint;

-- Tarjeta de cada cliente (el código es secreto: solo lo tiene el cliente)
create table if not exists public.cards (
  code       text primary key check (code ~ '^[A-Z0-9]{10}$'),
  name       text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);

-- Cada sticker es único: tiene número de serie propio y máximo 1 por pedido
create table if not exists public.stickers (
  id          bigint generated always as identity primary key,
  card_code   text not null references public.cards(code) on delete cascade,
  order_id    bigint unique references public.orders(id) on delete set null,
  created_at  timestamptz not null default now(),
  redeemed_at timestamptz,          -- cuando se canjea NO se borra: queda marcado
  voucher_id  bigint
);
create index if not exists stickers_card_idx on public.stickers (card_code, redeemed_at);

-- Vales de canje (5 stickers = 1 marcianito gratis)
create table if not exists public.vouchers (
  id            bigint generated always as identity primary key,
  card_code     text not null references public.cards(code) on delete cascade,
  created_at    timestamptz not null default now(),
  status        text not null default 'disponible' check (status in ('disponible','usado')),
  used_at       timestamptz,
  used_order_id bigint
);

-- Seguridad: los clientes NO acceden a estas tablas directamente
alter table public.cards    enable row level security;
alter table public.stickers enable row level security;
alter table public.vouchers enable row level security;

drop policy if exists "cards: Santi" on public.cards;
create policy "cards: Santi" on public.cards for all to authenticated using (true) with check (true);
drop policy if exists "stickers: Santi" on public.stickers;
create policy "stickers: Santi" on public.stickers for all to authenticated using (true) with check (true);
drop policy if exists "vouchers: Santi" on public.vouchers;
create policy "vouchers: Santi" on public.vouchers for all to authenticated using (true) with check (true);

revoke all on public.cards, public.stickers, public.vouchers from anon;
grant select, insert, update, delete on public.cards, public.stickers, public.vouchers to authenticated;

-- ---------- Funciones ----------

-- El cliente ve SOLO su tarjeta, usando su código secreto
create or replace function public.get_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.cards where code = upper(p_code);
  if not found then return null; end if;
  return json_build_object(
    'code', c.code,
    'name', c.name,
    'stickers', coalesce((select json_agg(json_build_object('id', s.id, 'created_at', s.created_at) order by s.id)
                          from public.stickers s where s.card_code = c.code and s.redeemed_at is null), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('id', v.id, 'created_at', v.created_at) order by v.id)
                          from public.vouchers v where v.card_code = c.code and v.status = 'disponible'), '[]'::json),
    'redeemed', (select count(*) from public.vouchers v where v.card_code = c.code)
  );
end $$;

-- El cliente canjea 5 stickers por 1 vale (los stickers quedan guardados como canjeados)
create or replace function public.redeem_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_id bigint; n int;
begin
  perform 1 from public.cards where code = upper(p_code) for update;
  if not found then raise exception 'Tarjeta inexistente'; end if;
  select count(*) into n from public.stickers where card_code = upper(p_code) and redeemed_at is null;
  if n < 5 then raise exception 'Faltan stickers para canjear'; end if;
  insert into public.vouchers (card_code) values (upper(p_code)) returning id into v_id;
  update public.stickers set redeemed_at = now(), voucher_id = v_id
   where id in (select id from public.stickers
                 where card_code = upper(p_code) and redeemed_at is null
                 order by id limit 5);
  return public.get_card(p_code);
end $$;

-- Santi marca un pedido como entregado: crea la tarjeta, el sticker y usa el vale
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
    insert into public.cards (code, name) values (o.card_code, o.customer_name)
      on conflict (code) do update set name = excluded.name;
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

revoke all on function public.get_card(text)         from public;
revoke all on function public.redeem_card(text)      from public;
revoke all on function public.deliver_order(bigint)  from public, anon;
grant execute on function public.get_card(text)        to anon, authenticated;
grant execute on function public.redeem_card(text)     to anon, authenticated;
grant execute on function public.deliver_order(bigint) to authenticated;

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
declare c record;
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

-- ============================================================

-- Cada tarjeta recibe un número de socio correlativo (los socios que ya existen también)
alter table public.cards add column if not exists member_no bigint generated by default as identity;
create unique index if not exists cards_member_no_idx on public.cards (member_no);

-- get_card ahora incluye el número de socio
create or replace function public.get_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from public.cards where code = upper(p_code);
  if not found then return null; end if;
  return json_build_object(
    'code', c.code, 'name', c.name, 'avatar', c.avatar, 'member_no', c.member_no,
    'stickers', coalesce((select json_agg(json_build_object('id', s.id, 'created_at', s.created_at) order by s.id)
                          from public.stickers s where s.card_code = c.code and s.redeemed_at is null), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('id', v.id, 'created_at', v.created_at) order by v.id)
                          from public.vouchers v where v.card_code = c.code and v.status = 'disponible'), '[]'::json),
    'redeemed', (select count(*) from public.vouchers v where v.card_code = c.code)
  );
end $$;
revoke all on function public.get_card(text) from public;
grant execute on function public.get_card(text) to anon, authenticated;

-- ============================================================

-- Invitaciones (de Santi o de un socio a un amigo)
create table if not exists public.invites (
  code         text primary key check (code ~ '^[A-Z0-9]{8}$'),
  inviter_card text references public.cards(code) on delete cascade,   -- null = invitación de Santi
  created_at   timestamptz not null default now(),
  used_at      timestamptz,
  used_by      text references public.cards(code) on delete set null
);
alter table public.invites enable row level security;
drop policy if exists "invites: Santi" on public.invites;
create policy "invites: Santi" on public.invites for all to authenticated using (true) with check (true);
revoke all on public.invites from anon;
grant select, insert, update, delete on public.invites to authenticated;

-- Código al azar (sin letras que se confunden)
create or replace function public._rand_code(n int)
returns text language sql volatile as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
    from generate_series(1, n);
$$;
revoke all on function public._rand_code(int) from public, anon, authenticated;

-- Nombre corto para mostrar (ej: "Lucía M.")
create or replace function public._alias(p_name text)
returns text language sql immutable as $$
  select initcap(split_part(btrim(p_name), ' ', 1)) ||
         case when split_part(btrim(p_name), ' ', 2) <> '' then ' ' || upper(left(split_part(btrim(p_name), ' ', 2), 1)) || '.' else '' end;
$$;

-- Invitaciones por socio (según Ajustes)
create or replace function public._invites_per_member()
returns int language plpgsql stable security definer set search_path = public as $$
declare v int;
begin
  begin select (data->>'invitesPerMember')::int into v from public.config where id = 1;
  exception when others then v := null; end;
  return greatest(0, least(10, coalesce(v, 2)));
end $$;

-- get_card ahora incluye las invitaciones del socio
create or replace function public.get_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c record; v_used int;
begin
  select * into c from public.cards where code = upper(p_code);
  if not found then return null; end if;
  select count(*) into v_used from public.invites where inviter_card = c.code;
  return json_build_object(
    'code', c.code, 'name', c.name, 'avatar', c.avatar, 'member_no', c.member_no,
    'stickers', coalesce((select json_agg(json_build_object('id', s.id, 'created_at', s.created_at) order by s.id)
                          from public.stickers s where s.card_code = c.code and s.redeemed_at is null), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('id', v.id, 'created_at', v.created_at) order by v.id)
                          from public.vouchers v where v.card_code = c.code and v.status = 'disponible'), '[]'::json),
    'redeemed', (select count(*) from public.vouchers v where v.card_code = c.code),
    'invites', coalesce((select json_agg(json_build_object('code', i.code, 'used', i.used_at is not null,
                                   'used_by', (select public._alias(c2.name) from public.cards c2 where c2.code = i.used_by)) order by i.created_at)
                         from public.invites i where i.inviter_card = c.code), '[]'::json),
    'invites_left', greatest(0, public._invites_per_member() - v_used)
  );
end $$;

-- Un socio crea una invitación para un amigo
create or replace function public.create_invite(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v_inv text; v_n int;
begin
  perform 1 from public.cards where code = upper(p_code) for update;
  if not found then raise exception 'Solo los socios pueden invitar'; end if;
  select count(*) into v_n from public.invites where inviter_card = upper(p_code);
  if v_n >= public._invites_per_member() then raise exception 'No te quedan invitaciones'; end if;
  loop
    v_inv := public._rand_code(8);
    exit when not exists (select 1 from public.invites where code = v_inv);
  end loop;
  insert into public.invites (code, inviter_card) values (v_inv, upper(p_code));
  return v_inv;
end $$;

-- Revisa si una invitación sirve (y quién invita)
create or replace function public.check_invite(p_invite text)
returns json language plpgsql stable security definer set search_path = public as $$
declare i record; v_from text;
begin
  select * into i from public.invites where code = upper(p_invite);
  if not found or i.used_at is not null then return json_build_object('valid', false); end if;
  if i.inviter_card is not null then select public._alias(name) into v_from from public.cards where code = i.inviter_card; end if;
  return json_build_object('valid', true, 'from', v_from);
end $$;

-- El invitado entra al club: se crea su tarjeta de socio
create or replace function public.join_with_invite(p_invite text, p_name text, p_avatar int, p_code text default null)
returns json language plpgsql security definer set search_path = public as $$
declare i record; v_code text; v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select * into i from public.invites where code = upper(p_invite) for update;
  if not found or i.used_at is not null then raise exception 'Invitación inválida o ya usada'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;
  v_code := upper(coalesce(p_code, ''));
  if v_code !~ '^[A-Z0-9]{10}$' or exists (select 1 from public.cards where code = v_code) then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;
  insert into public.cards (code, name, avatar) values (v_code, v_name, p_avatar);
  update public.invites set used_at = now(), used_by = v_code where code = i.code;
  return public.get_card(v_code);
end $$;

-- Entregar pedido: los clientes que NO son socios ya no se convierten en socios solos
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  v_member := o.card_code is not null and exists (select 1 from public.cards where code = o.card_code);
  if v_member then
    if o.avatar is not null then update public.cards set avatar = coalesce(avatar, o.avatar) where code = o.card_code; end if;
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

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;

revoke all on function public.get_card(text)                          from public;
revoke all on function public.create_invite(text)                     from public;
revoke all on function public.check_invite(text)                      from public;
revoke all on function public.join_with_invite(text, text, int, text) from public;
revoke all on function public.deliver_order(bigint)                   from public, anon;
grant execute on function public.get_card(text)                          to anon, authenticated;
grant execute on function public.create_invite(text)                     to anon, authenticated;
grant execute on function public.check_invite(text)                      to anon, authenticated;
grant execute on function public.join_with_invite(text, text, int, text) to anon, authenticated;
grant execute on function public.deliver_order(bigint)                   to authenticated;

-- ============================================================

-- Tarjetas de clientes (member = false) y de socios (member = true)
alter table public.cards add column if not exists member boolean not null default true;

-- get_card: dice si es socio; las invitaciones son solo para socios
create or replace function public.get_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare c record; v_used int;
begin
  select * into c from public.cards where code = upper(p_code);
  if not found then return null; end if;
  select count(*) into v_used from public.invites where inviter_card = c.code;
  return json_build_object(
    'code', c.code, 'name', c.name, 'avatar', c.avatar, 'member_no', c.member_no, 'member', c.member,
    'stickers', coalesce((select json_agg(json_build_object('id', s.id, 'created_at', s.created_at) order by s.id)
                          from public.stickers s where s.card_code = c.code and s.redeemed_at is null), '[]'::json),
    'vouchers', coalesce((select json_agg(json_build_object('id', v.id, 'created_at', v.created_at) order by v.id)
                          from public.vouchers v where v.card_code = c.code and v.status = 'disponible'), '[]'::json),
    'redeemed', (select count(*) from public.vouchers v where v.card_code = c.code),
    'invites', case when c.member then coalesce((select json_agg(json_build_object('code', i.code, 'used', i.used_at is not null,
                                   'used_by', (select public._alias(c2.name) from public.cards c2 where c2.code = i.used_by)) order by i.created_at)
                         from public.invites i where i.inviter_card = c.code), '[]'::json) else '[]'::json end,
    'invites_left', case when c.member then greatest(0, public._invites_per_member() - v_used) else 0 end
  );
end $$;

-- Solo los socios pueden invitar
create or replace function public.create_invite(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v_inv text; v_n int;
begin
  perform 1 from public.cards where code = upper(p_code) and member for update;
  if not found then raise exception 'Solo los socios pueden invitar'; end if;
  select count(*) into v_n from public.invites where inviter_card = upper(p_code);
  if v_n >= public._invites_per_member() then raise exception 'No te quedan invitaciones'; end if;
  loop
    v_inv := public._rand_code(8);
    exit when not exists (select 1 from public.invites where code = v_inv);
  end loop;
  insert into public.invites (code, inviter_card) values (v_inv, upper(p_code));
  return v_inv;
end $$;

-- Entrar al club: si ya era cliente con tarjeta, se hace socio y CONSERVA sus stickers
create or replace function public.join_with_invite(p_invite text, p_name text, p_avatar int, p_code text default null)
returns json language plpgsql security definer set search_path = public as $$
declare i record; c record; v_code text;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select * into i from public.invites where code = upper(p_invite) for update;
  if not found or i.used_at is not null then raise exception 'Invitación inválida o ya usada'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;

  v_code := upper(coalesce(p_code, ''));
  if v_code ~ '^[A-Z0-9]{10}$' then
    select * into c from public.cards where code = v_code for update;
    if found then
      if c.member then raise exception 'Ya sos socio del club'; end if;
      update public.cards set member = true, name = v_name, avatar = coalesce(p_avatar, avatar) where code = v_code;
      update public.invites set used_at = now(), used_by = v_code where code = i.code;
      return public.get_card(v_code);
    end if;
  else
    v_code := null;
  end if;

  if v_code is null then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;
  insert into public.cards (code, name, avatar, member) values (v_code, v_name, p_avatar, true);
  update public.invites set used_at = now(), used_by = v_code where code = i.code;
  return public.get_card(v_code);
end $$;

-- Entregar pedido: todos suman sticker. Si el cliente no tenía tarjeta, se crea una de CLIENTE
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean := false;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar, member) values (o.card_code, o.customer_name, o.avatar, false)
      on conflict (code) do update set avatar = coalesce(public.cards.avatar, excluded.avatar);
    select member into v_member from public.cards where code = o.card_code;
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

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;

-- La Carrera Galáctica sigue siendo SOLO para socios
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
    select o.card_code, o.qty, o.delivered_at as at from public.orders o
     where o.status = 'entregado' and o.card_code is not null and o.delivered_at >= v_since
    union all
    select b.card_code, b.qty, b.created_at from public.race_bonus b where b.created_at >= v_since
  ), agg as (
    select c.code, c.name, c.avatar, sum(p.qty)::int as qty, max(p.at) as last_at
      from pts p join public.cards c on c.code = p.card_code
     where not c.hide_rank and c.member
     group by c.code, c.name, c.avatar
  ), ranked as (
    select code, qty, avatar, public._alias(name) as alias,
           row_number() over (order by qty desc, last_at asc) as pos
      from agg
  )
  select
    coalesce(json_agg(json_build_object('pos', pos, 'name', alias, 'qty', qty, 'avatar', avatar, 'me', code = v_code) order by pos)
             filter (where pos <= 50), '[]'::json),
    (select json_build_object('pos', r2.pos, 'qty', r2.qty) from ranked r2 where r2.code = v_code),
    count(*)
  into v_rows, v_me, v_total from ranked;
  return json_build_object('rows', v_rows, 'me', v_me, 'total', coalesce(v_total, 0));
end $$;

-- Competencia de Stickers: gana quien junta más stickers en el período
create or replace function public.get_sticker_comp(p_code text default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_since timestamptz := '-infinity';
  v_until timestamptz := 'infinity';
  v_for   text := 'todos';
  v_txt   text; v_end text;
  v_code  text := upper(coalesce(p_code, ''));
  v_rows  json; v_me json; v_total int;
begin
  select data->>'compStart', data->>'compEnd', coalesce(nullif(data->>'compFor', ''), 'todos')
    into v_txt, v_end, v_for from public.config where id = 1;
  if v_txt is not null and v_txt <> '' then
    begin v_since := v_txt::timestamptz; exception when others then v_since := '-infinity'; end;
  end if;
  if v_end is not null and v_end <> '' then
    begin v_until := (v_end::date + 1)::timestamptz; exception when others then v_until := 'infinity'; end;
  end if;
  with agg as (
    select c.code, c.name, c.avatar, c.member, count(*)::int as qty, max(s.created_at) as last_at
      from public.stickers s join public.cards c on c.code = s.card_code
     where s.created_at >= v_since and s.created_at < v_until
       and not c.hide_rank
       and (v_for = 'todos' or (v_for = 'socios' and c.member) or (v_for = 'clientes' and not c.member))
     group by c.code, c.name, c.avatar, c.member
  ), ranked as (
    select code, qty, avatar, member, public._alias(name) as alias,
           row_number() over (order by qty desc, last_at asc) as pos
      from agg
  )
  select
    coalesce(json_agg(json_build_object('pos', pos, 'name', alias, 'qty', qty, 'avatar', avatar, 'member', member, 'me', code = v_code) order by pos)
             filter (where pos <= 50), '[]'::json),
    (select json_build_object('pos', r2.pos, 'qty', r2.qty) from ranked r2 where r2.code = v_code),
    count(*)
  into v_rows, v_me, v_total from ranked;
  return json_build_object('rows', v_rows, 'me', v_me, 'total', coalesce(v_total, 0));
end $$;

revoke all on function public.get_card(text)                          from public;
revoke all on function public.create_invite(text)                     from public;
revoke all on function public.join_with_invite(text, text, int, text) from public;
revoke all on function public.deliver_order(bigint)                   from public, anon;
revoke all on function public.get_race(text)                          from public;
revoke all on function public.get_sticker_comp(text)                  from public;
grant execute on function public.get_card(text)                          to anon, authenticated;
grant execute on function public.create_invite(text)                     to anon, authenticated;
grant execute on function public.join_with_invite(text, text, int, text) to anon, authenticated;
grant execute on function public.deliver_order(bigint)                   to authenticated;
grant execute on function public.get_race(text)                          to anon, authenticated;
grant execute on function public.get_sticker_comp(text)                  to anon, authenticated;


-- Las invitaciones ahora son palabras fáciles: NAVE-LUNA-42 (las viejas siguen sirviendo)
alter table public.invites drop constraint if exists invites_code_check;
alter table public.invites add constraint invites_code_check check (code ~ '^[A-Z0-9-]{4,30}$');

-- Normaliza lo que escribe la persona: sin tildes, sin guiones ni espacios, en mayúsculas
create or replace function public._norm_inv(p text)
returns text language sql immutable as $$
  select regexp_replace(translate(upper(coalesce(p, '')), 'ÁÉÍÓÚÜÑ', 'AEIOUUN'), '[^A-Z0-9]', '', 'g');
$$;

-- Genera una invitación con palabras del tema que no esté repetida
create or replace function public._invite_code()
returns text language plpgsql volatile as $$
declare
  w text[] := array['NAVE','LUNA','COHETE','ALIEN','PLANETA','ESTRELLA','COMETA','OVNI','MARTE','SATURNO','GALAXIA','NEBULOSA',
                    'ORBITA','ASTRO','METEORO','CRATER','PLUTON','VENUS','JUPITER','ANDES','NIEVE','HELADO','MARCIANO','PALETA',
                    'LIMON','FRUTILLA','CHOCO','RAYO','LASER','ROBOT','RADAR','PORTAL','ANTENA','CAPSULA','SATELITE','ECLIPSE'];
  n int := array_length(w, 1); a text; b text; v text;
begin
  loop
    a := w[1 + floor(random() * n)::int];
    b := w[1 + floor(random() * n)::int];
    continue when a = b;
    v := a || '-' || b || '-' || (10 + floor(random() * 90)::int)::text;
    exit when not exists (select 1 from public.invites where public._norm_inv(code) = public._norm_inv(v));
  end loop;
  return v;
end $$;
revoke all on function public._invite_code() from public, anon, authenticated;

-- Un socio crea una invitación (con palabras)
create or replace function public.create_invite(p_code text)
returns text language plpgsql security definer set search_path = public as $$
declare v_inv text; v_n int;
begin
  perform 1 from public.cards where code = upper(p_code) and member for update;
  if not found then raise exception 'Solo los socios pueden invitar'; end if;
  select count(*) into v_n from public.invites where inviter_card = upper(p_code);
  if v_n >= public._invites_per_member() then raise exception 'No te quedan invitaciones'; end if;
  v_inv := public._invite_code();
  insert into public.invites (code, inviter_card) values (v_inv, upper(p_code));
  return v_inv;
end $$;

-- Revisa una invitación (acepta minúsculas, sin guiones, con espacios)
create or replace function public.check_invite(p_invite text)
returns json language plpgsql stable security definer set search_path = public as $$
declare i record; v_from text;
begin
  select * into i from public.invites where public._norm_inv(code) = public._norm_inv(p_invite) limit 1;
  if not found or i.used_at is not null then return json_build_object('valid', false); end if;
  if i.inviter_card is not null then select public._alias(name) into v_from from public.cards where code = i.inviter_card; end if;
  return json_build_object('valid', true, 'from', v_from);
end $$;

-- Entrar al club con la invitación (si era cliente, conserva sus stickers)
create or replace function public.join_with_invite(p_invite text, p_name text, p_avatar int, p_code text default null)
returns json language plpgsql security definer set search_path = public as $$
declare i record; c record; v_code text;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select * into i from public.invites where public._norm_inv(code) = public._norm_inv(p_invite) limit 1 for update;
  if not found or i.used_at is not null then raise exception 'Invitación inválida o ya usada'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;

  v_code := upper(coalesce(p_code, ''));
  if v_code ~ '^[A-Z0-9]{10}$' then
    select * into c from public.cards where code = v_code for update;
    if found then
      if c.member then raise exception 'Ya sos socio del club'; end if;
      update public.cards set member = true, name = v_name, avatar = coalesce(p_avatar, avatar) where code = v_code;
      update public.invites set used_at = now(), used_by = v_code where code = i.code;
      return public.get_card(v_code);
    end if;
  else
    v_code := null;
  end if;

  if v_code is null then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;
  insert into public.cards (code, name, avatar, member) values (v_code, v_name, p_avatar, true);
  update public.invites set used_at = now(), used_by = v_code where code = i.code;
  return public.get_card(v_code);
end $$;

-- Carrera Galáctica: Santi elige si corren socios, clientes o todos (Ajustes)
create or replace function public.get_race(p_code text default null)
returns json language plpgsql stable security definer set search_path = public as $$
declare
  v_since timestamptz := '-infinity';
  v_txt   text;
  v_for   text := 'socios';
  v_code  text := upper(coalesce(p_code, ''));
  v_rows  json; v_me json; v_total int;
begin
  select data->>'raceStart', coalesce(nullif(data->>'raceFor', ''), 'socios') into v_txt, v_for from public.config where id = 1;
  if v_txt is not null and v_txt <> '' then
    begin v_since := v_txt::timestamptz; exception when others then v_since := '-infinity'; end;
  end if;
  with pts as (
    select o.card_code, o.qty, o.delivered_at as at from public.orders o
     where o.status = 'entregado' and o.card_code is not null and o.delivered_at >= v_since
    union all
    select b.card_code, b.qty, b.created_at from public.race_bonus b where b.created_at >= v_since
  ), agg as (
    select c.code, c.name, c.avatar, sum(p.qty)::int as qty, max(p.at) as last_at
      from pts p join public.cards c on c.code = p.card_code
     where not c.hide_rank
       and (v_for = 'todos' or (v_for = 'socios' and c.member) or (v_for = 'clientes' and not c.member))
     group by c.code, c.name, c.avatar
  ), ranked as (
    select code, qty, avatar, public._alias(name) as alias,
           row_number() over (order by qty desc, last_at asc) as pos
      from agg
  )
  select
    coalesce(json_agg(json_build_object('pos', pos, 'name', alias, 'qty', qty, 'avatar', avatar, 'me', code = v_code) order by pos)
             filter (where pos <= 50), '[]'::json),
    (select json_build_object('pos', r2.pos, 'qty', r2.qty) from ranked r2 where r2.code = v_code),
    count(*)
  into v_rows, v_me, v_total from ranked;
  return json_build_object('rows', v_rows, 'me', v_me, 'total', coalesce(v_total, 0));
end $$;

revoke all on function public.create_invite(text)                     from public;
revoke all on function public.check_invite(text)                      from public;
revoke all on function public.join_with_invite(text, text, int, text) from public;
revoke all on function public.get_race(text)                          from public;
grant execute on function public.create_invite(text)                     to anon, authenticated;
grant execute on function public.check_invite(text)                      to anon, authenticated;
grant execute on function public.join_with_invite(text, text, int, text) to anon, authenticated;
grant execute on function public.get_race(text)                          to anon, authenticated;


-- Sobres: el contenido lo decide el servidor (nadie puede hacer trampa)
create table if not exists public.album_packs (
  id         bigint generated always as identity primary key,
  card_code  text not null references public.cards(code) on delete cascade,
  kind       text not null check (kind in ('normal','dorado','cambio','regalo')),
  items      int[] not null,
  order_id   bigint unique references public.orders(id) on delete set null,   -- 1 sobre por pedido como máximo
  created_at timestamptz not null default now(),
  opened_at  timestamptz
);
create index if not exists album_packs_card_idx on public.album_packs (card_code, opened_at);

-- Figuritas pegadas en el álbum (las repetidas también; al cambiarlas quedan marcadas, no se borran)
create table if not exists public.album_items (
  id         bigint generated always as identity primary key,
  card_code  text not null references public.cards(code) on delete cascade,
  fig        int  not null check (fig between 1 and 24),
  pack_id    bigint references public.album_packs(id) on delete set null,
  created_at timestamptz not null default now(),
  traded_at  timestamptz
);
create index if not exists album_items_card_idx on public.album_items (card_code, fig);

alter table public.album_packs enable row level security;
alter table public.album_items enable row level security;
drop policy if exists "album_packs: Santi" on public.album_packs;
create policy "album_packs: Santi" on public.album_packs for all to authenticated using (true) with check (true);
drop policy if exists "album_items: Santi" on public.album_items;
create policy "album_items: Santi" on public.album_items for all to authenticated using (true) with check (true);
revoke all on public.album_packs, public.album_items from anon;
grant select, insert, update, delete on public.album_packs, public.album_items to authenticated;

-- Rareza: 18 comunes, 4 brillantes (5, 11, 17, 23) y 2 legendarias (6, 24)
create or replace function public._album_pick(p_tier text)
returns int language plpgsql volatile as $$
declare a int[];
begin
  if p_tier = 'legend' then a := array[6, 24];
  elsif p_tier = 'bright' then a := array[5, 11, 17, 23];
  else a := array[1,2,3,4,7,8,9,10,12,13,14,15,16,18,19,20,21,22];
  end if;
  return a[1 + floor(random() * array_length(a, 1))::int];
end $$;

-- Sorteo: 75% común, 20% brillante, 5% legendaria
create or replace function public._album_roll(p_min_bright boolean default false)
returns int language plpgsql volatile as $$
declare r double precision := random();
begin
  if p_min_bright then
    return case when r < 0.2 then public._album_pick('legend') else public._album_pick('bright') end;
  end if;
  return case when r < 0.05 then public._album_pick('legend')
              when r < 0.25 then public._album_pick('bright')
              else public._album_pick('common') end;
end $$;

-- ¿Esta tarjeta juega el álbum? (según Ajustes)
create or replace function public._album_eligible(p_card text)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_on text; v_for text; v_member boolean;
begin
  select data->>'albumOn', coalesce(nullif(data->>'albumFor', ''), 'todos') into v_on, v_for from public.config where id = 1;
  if v_on = 'false' then return false; end if;
  select member into v_member from public.cards where code = p_card;
  if not found then return false; end if;
  return v_for = 'todos' or (v_for = 'socios' and v_member);
end $$;

-- Arma un sobre (dorado = 3 figuritas con al menos 1 brillante)
create or replace function public._album_make_pack(p_card text, p_kind text, p_order bigint default null)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_items int[]; v_id bigint;
begin
  if p_kind = 'dorado' then
    v_items := array[public._album_roll(true), public._album_roll(), public._album_roll()];
  else
    v_items := array[public._album_roll()];
  end if;
  insert into public.album_packs (card_code, kind, items, order_id) values (p_card, p_kind, v_items, p_order)
    on conflict (order_id) do nothing returning id into v_id;
  return v_id;
end $$;
revoke all on function public._album_pick(text), public._album_roll(boolean), public._album_make_pack(text, text, bigint) from public, anon, authenticated;

-- El cliente ve su álbum con su código de tarjeta
create or replace function public.get_album(p_code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_code text := upper(coalesce(p_code, ''));
begin
  if not exists (select 1 from public.cards where code = v_code) then return null; end if;
  return json_build_object(
    'eligible', public._album_eligible(v_code),
    'figs', coalesce((select json_agg(json_build_object('fig', fig, 'n', n) order by fig)
                        from (select fig, count(*)::int as n from public.album_items
                               where card_code = v_code and traded_at is null group by fig) t), '[]'::json),
    'packs', coalesce((select json_agg(json_build_object('id', id, 'kind', kind) order by id)
                         from public.album_packs where card_code = v_code and opened_at is null), '[]'::json),
    'traded', (select count(*) from public.album_items where card_code = v_code and traded_at is not null)
  );
end $$;

-- Abrir un sobre: pega las figuritas y avisa cuáles son nuevas
create or replace function public.open_pack(p_code text, p_pack bigint)
returns json language plpgsql security definer set search_path = public as $$
declare v_code text := upper(coalesce(p_code, '')); p record; f int; v_new boolean; v_out json[] := '{}';
begin
  select * into p from public.album_packs where id = p_pack and card_code = v_code for update;
  if not found then raise exception 'Sobre inexistente'; end if;
  if p.opened_at is not null then raise exception 'Ese sobre ya se abrió'; end if;
  foreach f in array p.items loop
    v_new := not exists (select 1 from public.album_items where card_code = v_code and fig = f and traded_at is null);
    insert into public.album_items (card_code, fig, pack_id) values (v_code, f, p.id);
    v_out := v_out || json_build_object('fig', f, 'new', v_new);
  end loop;
  update public.album_packs set opened_at = now() where id = p.id;
  return json_build_object('kind', p.kind, 'items', array_to_json(v_out));
end $$;

-- Cambiar 3 repetidas por un sobre nuevo (siempre queda al menos 1 de cada figurita)
create or replace function public.trade_dups(p_code text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_code text := upper(coalesce(p_code, '')); v_ids bigint[];
begin
  perform 1 from public.cards where code = v_code for update;
  if not found then raise exception 'Tarjeta inexistente'; end if;
  select array_agg(id) into v_ids from (
    select id from (
      select id, row_number() over (partition by fig order by created_at, id) as rn
        from public.album_items where card_code = v_code and traded_at is null
    ) t where rn > 1 order by id limit 3
  ) x;
  if v_ids is null or array_length(v_ids, 1) < 3 then raise exception 'Necesitás 3 repetidas'; end if;
  update public.album_items set traded_at = now() where id = any(v_ids);
  return public._album_make_pack(v_code, 'cambio');
end $$;

-- Santi regala un sobre
create or replace function public.gift_pack(p_card text)
returns bigint language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  if not exists (select 1 from public.cards where code = upper(p_card)) then raise exception 'Tarjeta inexistente'; end if;
  return public._album_make_pack(upper(p_card), 'regalo');
end $$;

-- Canjear 5 stickers: además del vale, llega un SOBRE DORADO
create or replace function public.redeem_card(p_code text)
returns json language plpgsql security definer set search_path = public as $$
declare v_id bigint; n int;
begin
  perform 1 from public.cards where code = upper(p_code) for update;
  if not found then raise exception 'Tarjeta inexistente'; end if;
  select count(*) into n from public.stickers where card_code = upper(p_code) and redeemed_at is null;
  if n < 5 then raise exception 'Faltan stickers para canjear'; end if;
  insert into public.vouchers (card_code) values (upper(p_code)) returning id into v_id;
  update public.stickers set redeemed_at = now(), voucher_id = v_id
   where id in (select id from public.stickers
                 where card_code = upper(p_code) and redeemed_at is null
                 order by id limit 5);
  if public._album_eligible(upper(p_code)) then perform public._album_make_pack(upper(p_code), 'dorado'); end if;
  return public.get_card(p_code);
end $$;

-- Entregar pedido: sticker + SOBRE de figuritas
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean := false; v_pack bigint;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar, member) values (o.card_code, o.customer_name, o.avatar, false)
      on conflict (code) do update set avatar = coalesce(public.cards.avatar, excluded.avatar);
    select member into v_member from public.cards where code = o.card_code;
    insert into public.stickers (card_code, order_id) values (o.card_code, o.id)
      on conflict (order_id) do nothing
      returning id into v_sticker;
    if o.voucher_id is not null then
      update public.vouchers set status = 'usado', used_at = now(), used_order_id = o.id
       where id = o.voucher_id and card_code = o.card_code and status = 'disponible';
      v_used := found;
    end if;
    select count(*) into n from public.stickers where card_code = o.card_code and redeemed_at is null;
    if public._album_eligible(o.card_code) then v_pack := public._album_make_pack(o.card_code, 'normal', o.id); end if;
  end if;

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member, 'pack', v_pack,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;

revoke all on function public.get_album(text), public.open_pack(text, bigint), public.trade_dups(text),
                       public.gift_pack(text), public.redeem_card(text), public.deliver_order(bigint) from public;
revoke all on function public.gift_pack(text), public.deliver_order(bigint) from anon;
grant execute on function public.get_album(text)          to anon, authenticated;
grant execute on function public.open_pack(text, bigint)  to anon, authenticated;
grant execute on function public.trade_dups(text)         to anon, authenticated;
grant execute on function public.redeem_card(text)        to anon, authenticated;
grant execute on function public.gift_pack(text)          to authenticated;
grant execute on function public.deliver_order(bigint)    to authenticated;


-- Un premio por persona por período (semana o mes)
create table if not exists public.game_claims (
  card_code  text not null references public.cards(code) on delete cascade,
  period     text not null,
  game       text,
  sticker_id bigint,
  pack_id    bigint,
  created_at timestamptz not null default now(),
  primary key (card_code, period)
);
alter table public.game_claims enable row level security;
drop policy if exists "game_claims: Santi" on public.game_claims;
create policy "game_claims: Santi" on public.game_claims for all to authenticated using (true) with check (true);
revoke all on public.game_claims from anon;
grant select, insert, update, delete on public.game_claims to authenticated;

-- Período actual según Ajustes (hora de Argentina): "2026-S41" por semana o "2026-10" por mes
create or replace function public._game_period()
returns text language plpgsql stable security definer set search_path = public as $$
declare v text; t timestamp := now() at time zone 'America/Argentina/Buenos_Aires';
begin
  select coalesce(nullif(data->>'arcadePeriod', ''), 'semana') into v from public.config where id = 1;
  if v = 'mes' then return to_char(t, 'YYYY-MM'); end if;
  return to_char(t, 'IYYY-"S"IW');
end $$;

-- ¿Ya ganó el premio en este período?
create or replace function public.game_status(p_code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare v_code text := upper(coalesce(p_code, '')); v_per text := public._game_period();
begin
  return json_build_object(
    'period', v_per,
    'card', exists (select 1 from public.cards where code = v_code),
    'claimed', exists (select 1 from public.game_claims where card_code = v_code and period = v_per)
  );
end $$;

-- Cobrar el premio al ganar (1 por período)
create or replace function public.claim_game(p_code text, p_game text)
returns json language plpgsql security definer set search_path = public as $$
declare v_code text := upper(coalesce(p_code, '')); c record; v_on text; v_rew text; v_for text; v_per text;
        v_st bigint; v_pk bigint;
begin
  select * into c from public.cards where code = v_code;
  if not found then raise exception 'Necesitás tu tarjeta para ganar el premio'; end if;
  select data->>'arcadeOn', coalesce(nullif(data->>'arcadeReward', ''), 'sticker'), coalesce(nullif(data->>'arcadeFor', ''), 'todos')
    into v_on, v_rew, v_for from public.config where id = 1;
  if v_on = 'false' then raise exception 'El arcade está apagado'; end if;
  if v_for = 'socios' and not c.member then raise exception 'El premio es solo para socios'; end if;
  v_per := public._game_period();
  insert into public.game_claims (card_code, period, game) values (v_code, v_per, left(coalesce(p_game, ''), 20))
    on conflict do nothing;
  if not found then raise exception 'Ya ganaste el premio de este período'; end if;
  if v_rew = 'sobre' and public._album_eligible(v_code) then
    v_pk := public._album_make_pack(v_code, 'regalo');
  else
    insert into public.stickers (card_code) values (v_code) returning id into v_st;
  end if;
  update public.game_claims set sticker_id = v_st, pack_id = v_pk where card_code = v_code and period = v_per;
  return json_build_object('reward', case when v_pk is not null then 'sobre' else 'sticker' end, 'sticker_id', v_st, 'period', v_per);
end $$;

revoke all on function public.game_status(text), public.claim_game(text, text) from public;
grant execute on function public.game_status(text)       to anon, authenticated;
grant execute on function public.claim_game(text, text)  to anon, authenticated;


create or replace function public.join_with_invite(p_invite text, p_name text, p_avatar int, p_code text default null)
returns json language plpgsql security definer set search_path = public as $$
declare i record; c record; v_code text; v_gift text;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select * into i from public.invites where public._norm_inv(code) = public._norm_inv(p_invite) limit 1 for update;
  if not found or i.used_at is not null then raise exception 'Invitación inválida o ya usada'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;

  v_code := upper(coalesce(p_code, ''));
  if v_code ~ '^[A-Z0-9]{10}$' then
    select * into c from public.cards where code = v_code for update;
    if found then
      -- ya era cliente: se hace socio y conserva sus stickers
      if c.member then raise exception 'Ya sos socio del club'; end if;
      update public.cards set member = true, name = v_name, avatar = coalesce(p_avatar, avatar) where code = v_code;
      update public.invites set used_at = now(), used_by = v_code where code = i.code;
      return public.get_card(v_code);
    end if;
  else
    v_code := null;
  end if;

  if v_code is null then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;
  insert into public.cards (code, name, avatar, member) values (v_code, v_name, p_avatar, true);
  update public.invites set used_at = now(), used_by = v_code where code = i.code;

  -- sticker de regalo de bienvenida (se apaga en Ajustes)
  select data->>'welcomeSticker' into v_gift from public.config where id = 1;
  if v_gift is distinct from 'false' then
    insert into public.stickers (card_code) values (v_code);
  end if;

  return public.get_card(v_code);
end $$;

revoke all on function public.join_with_invite(text, text, int, text) from public;
grant execute on function public.join_with_invite(text, text, int, text) to anon, authenticated;


-- Nuevo tipo de sobre: "familiar"
alter table public.album_packs drop constraint if exists album_packs_kind_check;
alter table public.album_packs add constraint album_packs_kind_check
  check (kind in ('normal','dorado','cambio','regalo','familiar'));

-- Cada sobre trae 3 figuritas; el dorado trae 5 (con al menos 1 brillante)
create or replace function public._album_make_pack(p_card text, p_kind text, p_order bigint default null)
returns bigint language plpgsql volatile security definer set search_path = public as $$
declare v_items int[]; v_id bigint;
begin
  if p_kind = 'dorado' then
    v_items := array[public._album_roll(true), public._album_roll(), public._album_roll(), public._album_roll(), public._album_roll()];
  else
    v_items := array[public._album_roll(), public._album_roll(), public._album_roll()];
  end if;
  insert into public.album_packs (card_code, kind, items, order_id) values (p_card, p_kind, v_items, p_order)
    on conflict (order_id) do nothing returning id into v_id;
  return v_id;
end $$;
revoke all on function public._album_make_pack(text, text, bigint) from public, anon, authenticated;

-- Entregar pedido: sticker + sobre, y 1 sobre EXTRA por cada Pack Familiar
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean := false; v_pack bigint;
        v_fam int := 0; v_famon text; k int;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar, member) values (o.card_code, o.customer_name, o.avatar, false)
      on conflict (code) do update set avatar = coalesce(public.cards.avatar, excluded.avatar);
    select member into v_member from public.cards where code = o.card_code;
    insert into public.stickers (card_code, order_id) values (o.card_code, o.id)
      on conflict (order_id) do nothing
      returning id into v_sticker;
    if o.voucher_id is not null then
      update public.vouchers set status = 'usado', used_at = now(), used_order_id = o.id
       where id = o.voucher_id and card_code = o.card_code and status = 'disponible';
      v_used := found;
    end if;
    select count(*) into n from public.stickers where card_code = o.card_code and redeemed_at is null;

    if public._album_eligible(o.card_code) then
      v_pack := public._album_make_pack(o.card_code, 'normal', o.id);
      -- Pack Familiar: "Pack Tripulación Familiar" o "2x Pack Tripulación Familiar"
      select data->>'familiarPack' into v_famon from public.config where id = 1;
      if v_famon is distinct from 'false' and coalesce(o.combo, '') ilike '%Familiar%' then
        v_fam := coalesce(nullif(substring(o.combo from '(\d+)x Pack [^+]*Familiar'), '')::int, 1);
        v_fam := least(v_fam, 10);
        for k in 1..v_fam loop perform public._album_make_pack(o.card_code, 'familiar'); end loop;
      end if;
    end if;
  end if;

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member, 'pack', v_pack, 'familiar', v_fam,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;
revoke all on function public.deliver_order(bigint) from public, anon;
grant execute on function public.deliver_order(bigint) to authenticated;


alter table public.cards add column if not exists source text;

-- Quien escanea el QR saca su tarjeta de CLIENTE (+ sticker de bienvenida si está activado)
create or replace function public.self_register(p_name text, p_avatar int default null, p_code text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v_on text; v_gift text; v_code text; v_recent int;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select data->>'qrRegister', data->>'welcomeSticker' into v_on, v_gift from public.config where id = 1;
  if v_on = 'false' then raise exception 'El registro con QR está apagado'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;

  -- freno anti-abuso: no más de 40 registros por QR cada 10 minutos
  select count(*) into v_recent from public.cards where source = 'qr' and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then raise exception 'Probá en unos minutos'; end if;

  v_code := upper(coalesce(p_code, ''));
  if v_code ~ '^[A-Z0-9]{10}$' and exists (select 1 from public.cards where code = v_code) then
    return public.get_card(v_code);                       -- ya tenía tarjeta: no se duplica
  end if;
  if v_code !~ '^[A-Z0-9]{10}$' then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;

  insert into public.cards (code, name, avatar, member, source) values (v_code, v_name, p_avatar, false, 'qr');
  if v_gift is distinct from 'false' then
    insert into public.stickers (card_code) values (v_code);
  end if;
  return public.get_card(v_code);
end $$;

revoke all on function public.self_register(text, int, text) from public;
grant execute on function public.self_register(text, int, text) to anon, authenticated;


-- Entregar pedido: sticker + sobre, y los sobres de regalo de cada combo (según Ajustes → Combos)
create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean := false; v_pack bigint;
        v_extra int := 0; cfg jsonb; part text; nm text; q int; cmb jsonb; k int; v_np int;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar, member) values (o.card_code, o.customer_name, o.avatar, false)
      on conflict (code) do update set avatar = coalesce(public.cards.avatar, excluded.avatar);
    select member into v_member from public.cards where code = o.card_code;
    insert into public.stickers (card_code, order_id) values (o.card_code, o.id)
      on conflict (order_id) do nothing
      returning id into v_sticker;
    if o.voucher_id is not null then
      update public.vouchers set status = 'usado', used_at = now(), used_order_id = o.id
       where id = o.voucher_id and card_code = o.card_code and status = 'disponible';
      v_used := found;
    end if;
    select count(*) into n from public.stickers where card_code = o.card_code and redeemed_at is null;

    if public._album_eligible(o.card_code) then
      v_pack := public._album_make_pack(o.card_code, 'normal', o.id);
      select data into cfg from public.config where id = 1;
      if cfg ? 'combos' and jsonb_typeof(cfg->'combos') = 'array' then
        -- el pedido trae algo como "Pack Galaxia + 2x Nave Nodriza"
        foreach part in array string_to_array(coalesce(o.combo, ''), ' + ') loop
          if part ~ '^\d+x ' then q := substring(part from '^(\d+)x ')::int; nm := regexp_replace(part, '^\d+x ', '');
          else q := 1; nm := part; end if;
          for cmb in select * from jsonb_array_elements(cfg->'combos') loop
            v_np := coalesce(nullif(regexp_replace(coalesce(cmb->>'packs', '0'), '\D', '', 'g'), ''), '0')::int;
            if cmb->>'n' = nm and v_np > 0 then v_extra := v_extra + q * least(v_np, 5); end if;
          end loop;
        end loop;
      elsif cfg->>'familiarPack' is distinct from 'false' and coalesce(o.combo, '') ilike '%Familiar%' then
        v_extra := coalesce(nullif(substring(o.combo from '(\d+)x Pack [^+]*Familiar'), '')::int, 1);
      end if;
      v_extra := least(v_extra, 20);
      for k in 1..v_extra loop perform public._album_make_pack(o.card_code, 'familiar'); end loop;
    end if;
  end if;

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member, 'pack', v_pack, 'familiar', v_extra,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;
revoke all on function public.deliver_order(bigint) from public, anon;
grant execute on function public.deliver_order(bigint) to authenticated;


alter table public.cards add column if not exists dup_of text;   -- "posible repetida de…"

-- Nombre normalizado: sin tildes, minúsculas, espacios simples
create or replace function public._norm_name(p text)
returns text language sql immutable as $$
  select regexp_replace(lower(translate(btrim(coalesce(p, '')), 'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNaeiouun')), '\s+', ' ', 'g');
$$;

-- Registro con QR: si ya hay una tarjeta con el mismo nombre, pregunta antes de crear otra
drop function if exists public.self_register(text, int, text);
create or replace function public.self_register(p_name text, p_avatar int default null, p_code text default null, p_force boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare v_on text; v_gift text; v_code text; v_recent int; v_dup text;
        v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
begin
  select data->>'qrRegister', data->>'welcomeSticker' into v_on, v_gift from public.config where id = 1;
  if v_on = 'false' then raise exception 'El registro con QR está apagado'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'Nombre inválido'; end if;
  if p_avatar is not null and (p_avatar < 0 or p_avatar > 99) then raise exception 'Avatar inválido'; end if;

  select count(*) into v_recent from public.cards where source = 'qr' and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then raise exception 'Probá en unos minutos'; end if;

  v_code := upper(coalesce(p_code, ''));
  if v_code ~ '^[A-Z0-9]{10}$' and exists (select 1 from public.cards where code = v_code) then
    return public.get_card(v_code);                       -- este celular ya tenía tarjeta
  end if;

  select code into v_dup from public.cards where public._norm_name(name) = public._norm_name(v_name) order by created_at limit 1;
  if v_dup is not null and not coalesce(p_force, false) then
    raise exception 'NOMBRE_EXISTE';                      -- la app pregunta "¿ya tenés tarjeta?"
  end if;

  if v_code !~ '^[A-Z0-9]{10}$' then
    loop
      v_code := public._rand_code(10);
      exit when not exists (select 1 from public.cards where code = v_code);
    end loop;
  end if;
  insert into public.cards (code, name, avatar, member, source, dup_of) values (v_code, v_name, p_avatar, false, 'qr', v_dup);
  if v_gift is distinct from 'false' then
    insert into public.stickers (card_code) values (v_code);
  end if;
  return public.get_card(v_code);
end $$;
revoke all on function public.self_register(text, int, text, boolean) from public;
grant execute on function public.self_register(text, int, text, boolean) to anon, authenticated;

-- Santi une dos tarjetas: todo lo de p_from pasa a p_to y p_from se borra
create or replace function public.merge_cards(p_from text, p_to text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; t record;
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  if upper(p_from) = upper(p_to) then raise exception 'Es la misma tarjeta'; end if;
  select * into f from public.cards where code = upper(p_from) for update;
  if not found then raise exception 'No existe la tarjeta a unir'; end if;
  select * into t from public.cards where code = upper(p_to) for update;
  if not found then raise exception 'No existe la tarjeta destino'; end if;

  update public.stickers    set card_code = t.code where card_code = f.code;
  update public.vouchers    set card_code = t.code where card_code = f.code;
  update public.album_packs set card_code = t.code where card_code = f.code;
  update public.album_items set card_code = t.code where card_code = f.code;
  update public.race_bonus  set card_code = t.code where card_code = f.code;
  update public.orders      set card_code = t.code where card_code = f.code;
  delete from public.game_claims g where g.card_code = f.code
     and exists (select 1 from public.game_claims x where x.card_code = t.code and x.period = g.period);
  update public.game_claims set card_code = t.code where card_code = f.code;
  update public.invites set inviter_card = t.code where inviter_card = f.code;
  update public.invites set used_by = t.code where used_by = f.code;
  update public.cards set dup_of = null where dup_of = f.code;

  update public.cards set member = t.member or f.member, avatar = coalesce(t.avatar, f.avatar),
         hide_rank = t.hide_rank and f.hide_rank, dup_of = null
   where code = t.code;
  delete from public.cards where code = f.code;
  return public.get_card(t.code);
end $$;
revoke all on function public.merge_cards(text, text) from public, anon;
grant execute on function public.merge_cards(text, text) to authenticated;

-- ============================================================

create or replace function public.deliver_order(p_order_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare o public.orders; v_sticker bigint; v_used boolean := false; n int; v_member boolean := false; v_pack bigint;
        v_extra int := 0; cfg jsonb; part text; nm text; q int; cmb jsonb; k int; v_np int;
        v_rule text; v_min int; v_prev int := 0; v_skip text := null;
        v_now timestamp := now() at time zone 'America/Argentina/Buenos_Aires';
begin
  if auth.uid() is null then raise exception 'No autorizado'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Pedido inexistente'; end if;
  if o.status <> 'pendiente' then raise exception 'El pedido ya estaba resuelto'; end if;

  update public.orders set status = 'entregado', delivered_at = now() where id = o.id;
  select data into cfg from public.config where id = 1;

  if o.card_code is not null then
    insert into public.cards (code, name, avatar, member) values (o.card_code, o.customer_name, o.avatar, false)
      on conflict (code) do update set avatar = coalesce(public.cards.avatar, excluded.avatar);
    select member into v_member from public.cards where code = o.card_code;

    -- Reglas: compra mínima y 1 sticker por día / semana (solo cuentan los stickers ganados por pedidos)
    v_rule := coalesce(nullif(cfg->>'stickerLimit', ''), 'dia');
    v_min  := greatest(1, coalesce(nullif(regexp_replace(coalesce(cfg->>'stickerMinQty', '1'), '\D', '', 'g'), ''), '1')::int);
    if o.qty < v_min then
      v_skip := 'minimo';
    elsif v_rule = 'dia' then
      select count(*) into v_prev from public.stickers s
       where s.card_code = o.card_code and s.order_id is not null
         and (s.created_at at time zone 'America/Argentina/Buenos_Aires')::date = v_now::date;
      if v_prev > 0 then v_skip := 'limite'; end if;
    elsif v_rule = 'semana' then
      select count(*) into v_prev from public.stickers s
       where s.card_code = o.card_code and s.order_id is not null
         and date_trunc('week', s.created_at at time zone 'America/Argentina/Buenos_Aires') = date_trunc('week', v_now);
      if v_prev > 0 then v_skip := 'limite'; end if;
    end if;

    if v_skip is null then
      insert into public.stickers (card_code, order_id) values (o.card_code, o.id)
        on conflict (order_id) do nothing
        returning id into v_sticker;
    end if;
    if o.voucher_id is not null then
      update public.vouchers set status = 'usado', used_at = now(), used_order_id = o.id
       where id = o.voucher_id and card_code = o.card_code and status = 'disponible';
      v_used := found;
    end if;
    select count(*) into n from public.stickers where card_code = o.card_code and redeemed_at is null;

    if public._album_eligible(o.card_code) then
      -- el sobre común sigue la misma regla que el sticker
      if v_skip is null then v_pack := public._album_make_pack(o.card_code, 'normal', o.id); end if;
      -- los sobres de regalo de los combos se dan siempre (van con el tamaño de la compra)
      if cfg ? 'combos' and jsonb_typeof(cfg->'combos') = 'array' then
        foreach part in array string_to_array(coalesce(o.combo, ''), ' + ') loop
          if part ~ '^\d+x ' then q := substring(part from '^(\d+)x ')::int; nm := regexp_replace(part, '^\d+x ', '');
          else q := 1; nm := part; end if;
          for cmb in select * from jsonb_array_elements(cfg->'combos') loop
            v_np := coalesce(nullif(regexp_replace(coalesce(cmb->>'packs', '0'), '\D', '', 'g'), ''), '0')::int;
            if cmb->>'n' = nm and v_np > 0 then v_extra := v_extra + q * least(v_np, 5); end if;
          end loop;
        end loop;
      elsif cfg->>'familiarPack' is distinct from 'false' and coalesce(o.combo, '') ilike '%Familiar%' then
        v_extra := coalesce(nullif(substring(o.combo from '(\d+)x Pack [^+]*Familiar'), '')::int, 1);
      end if;
      v_extra := least(v_extra, 20);
      for k in 1..v_extra loop perform public._album_make_pack(o.card_code, 'familiar'); end loop;
    end if;
  end if;

  return json_build_object('sticker_id', v_sticker, 'active', n, 'member', v_member, 'pack', v_pack, 'familiar', v_extra,
                           'skip', v_skip, 'min', v_min, 'rule', v_rule,
                           'voucher_used', v_used, 'voucher_requested', o.voucher_id is not null);
end $$;
revoke all on function public.deliver_order(bigint) from public, anon;
grant execute on function public.deliver_order(bigint) to authenticated;
