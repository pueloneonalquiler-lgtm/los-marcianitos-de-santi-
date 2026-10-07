-- ============================================================
-- Los Marcianitos de Santi: PEDIDOS DE CLIENTES
-- Si ya corriste supabase.sql antes, corré SOLO este archivo.
-- Supabase > SQL Editor > New query > pegar > Run
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
