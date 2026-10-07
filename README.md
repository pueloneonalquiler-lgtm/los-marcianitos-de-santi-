[README.md](https://github.com/user-attachments/files/33132756/README.md)
# 🛸 Los Marcianitos de Santi

Tienda de helados con pedidos por WhatsApp y Centro de Control gamificado para Santi.

## Archivos
- `index.html`: la app completa (tienda + Centro de Control).
- `supabase.sql`: crea todas las tablas y la seguridad en Supabase (para proyectos nuevos).
- `supabase-pedidos.sql`: agrega solo la tabla de pedidos (si ya habías corrido `supabase.sql` antes).

## Puesta en marcha
1. **GitHub:** subí `index.html`, `supabase.sql` y este `README.md` a un repositorio nuevo.
2. **Supabase:** creá un proyecto, corré `supabase.sql` en el SQL Editor, desactivá los registros públicos y creá el usuario de Santi.
3. **Conectar:** pegá la Project URL y la clave anon/publishable al principio del `<script>` de `index.html`.
4. **Vercel:** importá el repo (preset "Other", sin build). Cada cambio en GitHub se publica solo.

## Sin Supabase
Si dejás `SUPABASE_URL` y `SUPABASE_KEY` vacíos, la app funciona guardando en el celular y el Centro de Control usa PIN (inicial: 1234).

## Seguridad
- Usá solo la clave **anon/publishable**. La **service_role** nunca va en el código.
- Con los registros desactivados, la única cuenta que puede editar es la de Santi.

## Pedidos
Cada pedido que un cliente lanza por WhatsApp también se guarda en Supabase. En el Centro de Control, la pestaña **🛸 Pedidos** muestra los pendientes con dirección, mapa y sabores. Al tocar **✅ Entregado**, el cliente se suma solo a Tripulantes con 1 sticker y la venta se carga sola en la Bitácora.
