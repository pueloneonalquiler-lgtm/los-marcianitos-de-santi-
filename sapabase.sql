-- ============================================================
-- Los Marcianitos de Santi: base de datos en Supabase
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
declare c public.cards;
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
