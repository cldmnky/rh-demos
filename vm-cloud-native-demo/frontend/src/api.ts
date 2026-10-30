/** Typed access to the Rocket Ramen API, plus the small helpers the UI shares. */

export interface MenuItem {
  id: number;
  name: string;
  emoji: string;
  description: string;
  price_cents: number;
  prep_seconds: number;
  stock: number;
  spice: number;
  vegan: boolean;
  tags: string;
}

export type OrderStatus = 'queued' | 'cooking' | 'plating' | 'served';

export interface OrderLine {
  menu_item_id: number;
  name: string;
  qty: number;
  unit_price_cents: number;
}

export interface Order {
  id: number;
  code: string;
  customer: string;
  status: OrderStatus;
  total_cents: number;
  eta_minutes: number;
  created_at: string;
  items: OrderLine[];
}

export interface TopSeller {
  name: string;
  qty: number;
}

export interface HourBucket {
  hour: string;
  orders: number;
}

export interface DBInfo {
  version: string;
  uptime_seconds: number;
  latency_ms: number;
  open_connections: number;
}

export interface Placement {
  runtime: string;
  name: string;
  namespace: string;
  node: string;
  serial: string;
  reported_by: string;
}

export interface Stats {
  revenue_cents: number;
  orders_today: number;
  avg_ticket_cents: number;
  queue_depth: number;
  busiest_hour: string;
  top_sellers: TopSeller[];
  hourly: HourBucket[];
  runtime: string;
  placement: Placement;
  db: DBInfo;
  at: string;
}

/** Answered by server.js itself: which tier is serving the page right now. */
export interface WebInfo extends Placement {
  node_version: string;
  host: string;
}

export class ApiError extends Error {
  readonly status: number;
  readonly body: { error?: string; message?: string; item?: string };

  constructor(status: number, body: ApiError['body']) {
    super(body.message || `request failed (${status})`);
    this.status = status;
    this.body = body;
  }
}

async function request<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const text = await response.text();
  const body = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new ApiError(response.status, body);
  }
  return body as T;
}

export const api = {
  menu: (q: string) =>
    request<{ items: MenuItem[] }>(`/api/menu${q ? `?q=${encodeURIComponent(q)}` : ''}`).then((r) => r.items),
  orders: (limit = 30) => request<{ orders: Order[] }>(`/api/orders?limit=${limit}`).then((r) => r.orders),
  stats: () => request<Stats>('/api/stats'),
  webinfo: () => request<WebInfo>('/api/webinfo'),
  placeOrder: (customer: string, items: { menu_item_id: number; qty: number }[]) =>
    request<Order>('/api/orders', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ customer, items }),
    }),
  advance: (id: number) => request<Order>(`/api/orders/${id}/advance`, { method: 'POST' }),
  restock: () => request<{ status: string }>('/api/restock', { method: 'POST' }),
  reset: () => request<{ status: string }>('/api/reset', { method: 'POST' }),
};

export const money = (cents: number) =>
  (cents / 100).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

export const STATUS_FLOW: OrderStatus[] = ['queued', 'cooking', 'plating', 'served'];

export const statusLabel: Record<OrderStatus, string> = {
  queued: 'In the queue',
  cooking: 'Cooking',
  plating: 'Plating',
  served: 'Served',
};

export const nextStatus = (status: OrderStatus): OrderStatus | null => {
  const index = STATUS_FLOW.indexOf(status);
  return index >= 0 && index + 1 < STATUS_FLOW.length ? STATUS_FLOW[index + 1] : null;
};

/** What the galley button says when it advances an order. */
export const advanceLabel: Record<OrderStatus, string> = {
  queued: 'Start cooking',
  cooking: 'Send to plating',
  plating: 'Hand to crew',
  served: 'Delivered',
};

export const statusColor = (status: OrderStatus): 'blue' | 'orange' | 'purple' | 'green' => {
  switch (status) {
    case 'queued':
      return 'blue';
    case 'cooking':
      return 'orange';
    case 'plating':
      return 'purple';
    default:
      return 'green';
  }
};

export const spiceLabel = (spice: number) => '🌶️'.repeat(spice) || 'mild';

/** "11.4.13-MariaDB-ubu2404" -> "MariaDB 11.4.13" */
export const dbVersionLabel = (version: string) => {
  const match = version.match(/^(\d+\.\d+\.\d+).*MariaDB/i);
  return match ? `MariaDB ${match[1]}` : version;
};

export const queueEta = (orders: Order[]) =>
  Math.max(3, Math.round(orders.filter((o) => o.status !== 'served').reduce((sum, o) => sum + o.eta_minutes, 0) / 3));

export const upsertOrder = (orders: Order[], incoming: Order): Order[] => {
  const rest = orders.filter((o) => o.id !== incoming.id);
  return [incoming, ...rest]
    .sort((a, b) => (a.created_at < b.created_at ? 1 : a.created_at > b.created_at ? -1 : b.id - a.id))
    .slice(0, 30);
};
