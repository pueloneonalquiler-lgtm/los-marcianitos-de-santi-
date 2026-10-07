-- ============================================================
-- Los Marcianitos de Santi: TARJETAS, STICKERS Y CANJES
-- Si ya corriste los otros archivos, corré SOLO este.
-- Supabase > SQL Editor > New query > pegar > Run
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
