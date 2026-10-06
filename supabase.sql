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
