import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Brand,
  Masthead,
  MastheadBrand,
  MastheadContent,
  MastheadMain,
  Page,
  PageSection,
  Title,
} from '@patternfly/react-core';
import { Board } from './views/Board';
import { MenuPane } from './views/MenuPane';
import { OpsStrip } from './views/OpsStrip';
import { StackBadges } from './views/StackBadges';
import { StackCard } from './views/StackCard';
import { ApiError, MenuItem, Order, Stats, WebInfo, api, money, upsertOrder } from './api';

const MastheadBar = ({ web, stats }: { web: WebInfo | null; stats: Stats | null }) => (
  <Masthead>
    <MastheadMain>
      <MastheadBrand>
        <Brand src="./ramen.svg" alt="Rocket Ramen" heights={{ default: '48px' }} />
      </MastheadBrand>
    </MastheadMain>
    <MastheadContent>
      <div className="rr-masthead">
        <span className="rr-masthead__title">Rocket Ramen</span>
        <span className="rr-muted">zero-gravity noodle bar · PatternFly 6</span>
      </div>
      <StackBadges web={web} stats={stats} />
    </MastheadContent>
  </Masthead>
);

export default function App() {
  const [menu, setMenu] = useState<MenuItem[]>([]);
  const [orders, setOrders] = useState<Order[]>([]);
  const [stats, setStats] = useState<Stats | null>(null);
  const [web, setWeb] = useState<WebInfo | null>(null);
  const [query, setQuery] = useState('');
  const [cart, setCart] = useState<Record<number, number>>({});
  const [customer, setCustomer] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [restocking, setRestocking] = useState(false);
  const [resetting, setResetting] = useState(false);
  const [advancing, setAdvancing] = useState<number | null>(null);
  const [live, setLive] = useState(false);
  const queryRef = useRef(query);

  const refreshMenu = useCallback(async (search: string) => {
    try {
      const items = await api.menu(search);
      if (search === queryRef.current) {
        setMenu(items);
      }
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'menu unavailable');
    }
  }, []);

  // Initial load: the three tiers answer independently, so partial failures still render.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const [menuResult, orderResult, statsResult, webResult] = await Promise.allSettled([
        api.menu(''),
        api.orders(),
        api.stats(),
        api.webinfo(),
      ]);
      if (cancelled) {
        return;
      }
      if (menuResult.status === 'fulfilled') setMenu(menuResult.value);
      if (orderResult.status === 'fulfilled') setOrders(orderResult.value);
      if (statsResult.status === 'fulfilled') setStats(statsResult.value);
      if (webResult.status === 'fulfilled') setWeb(webResult.value);
      if (menuResult.status === 'rejected') setError('the galley menu is unavailable — is MariaDB running?');
      setLoading(false);
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  // Debounced menu search, including the MariaDB FULLTEXT path.
  useEffect(() => {
    queryRef.current = query;
    const timer = setTimeout(() => {
      void refreshMenu(query);
    }, 250);
    return () => clearTimeout(timer);
  }, [query, refreshMenu]);

  // Live board: one EventSource, fed by the Go API hub through the Node proxy.
  useEffect(() => {
    const source = new EventSource('/api/stream');
    const onOrder = (event: Event) => {
      const order = JSON.parse((event as MessageEvent<string>).data) as Order;
      setOrders((current) => upsertOrder(current, order));
      setLive(true);
    };
    const onStats = (event: Event) => {
      setStats(JSON.parse((event as MessageEvent<string>).data) as Stats);
      setLive(true);
    };
    const onMenu = (event: Event) => {
      const payload = JSON.parse((event as MessageEvent<string>).data) as { items: MenuItem[] };
      if (!queryRef.current) {
        setMenu(payload.items);
      }
    };
    source.addEventListener('hello', () => setLive(true));
    source.addEventListener('order.created', onOrder);
    source.addEventListener('order.updated', onOrder);
    source.addEventListener('stats', onStats);
    source.addEventListener('menu.updated', onMenu);
    source.addEventListener('orders.cleared', () => setOrders([]));
    source.onerror = () => setLive(false);
    return () => source.close();
  }, []);

  // Fallback polling: if the stream is blocked by a proxy, the board still converges.
  useEffect(() => {
    const timer = setInterval(() => {
      void api.orders().then(setOrders).catch(() => setLive(false));
      void api.stats().then(setStats).catch(() => undefined);
    }, 20000);
    return () => clearInterval(timer);
  }, []);

  const setQuantity = (menuItemId: number, quantity: number) => {
    setCart((current) => {
      const next = { ...current };
      if (quantity <= 0) {
        delete next[menuItemId];
      } else {
        next[menuItemId] = quantity;
      }
      return next;
    });
  };

  const cartTotal = useMemo(
    () =>
      menu.reduce((total, item) => total + item.price_cents * (cart[item.id] ?? 0), 0),
    [menu, cart],
  );

  const submitOrder = async () => {
    const items = Object.entries(cart).map(([id, qty]) => ({ menu_item_id: Number(id), qty }));
    if (items.length === 0) {
      return;
    }
    setBusy(true);
    setError(null);
    try {
      const order = await api.placeOrder(customer, items);
      setOrders((current) => upsertOrder(current, order));
      setCart({});
      await refreshMenu(query);
    } catch (err) {
      if (err instanceof ApiError) {
        // The 409 from the transactional stock check names the dish that ran out.
        setError(err.body.message ?? 'checkout failed');
      } else {
        setError('the API tier is unreachable — check the VM and the MariaDB service');
      }
      await refreshMenu(query);
    } finally {
      setBusy(false);
    }
  };

  const advanceOrder = async (order: Order) => {
    setAdvancing(order.id);
    setError(null);
    try {
      const updated = await api.advance(order.id);
      setOrders((current) => upsertOrder(current, updated));
    } catch (err) {
      setError(err instanceof ApiError ? err.body.message ?? 'could not advance' : 'API unreachable');
    } finally {
      setAdvancing(null);
    }
  };

  const resetBoard = async () => {
    setResetting(true);
    setError(null);
    try {
      await api.reset();
      setOrders([]);
      await refreshMenu(query);
      setStats(await api.stats());
    } catch {
      setError('could not clear the board — is the API reachable?');
    } finally {
      setResetting(false);
    }
  };

  const restock = async () => {
    setRestocking(true);
    try {
      await api.restock();
      await refreshMenu(query);
    } catch {
      setError('restock failed — is MariaDB reachable?');
    } finally {
      setRestocking(false);
    }
  };

  return (
    <Page masthead={<MastheadBar web={web} stats={stats} />} className="rr-page">
      <PageSection isWidthLimited={false} className="rr-hero">
        <Title headingLevel="h1" size="2xl">
          Mission Control
        </Title>
        <p className="rr-muted">
          Orders land in MariaDB on a VM, stream back over SSE, and the stack panel tells you which tier
          answers each request. Today&apos;s till: <strong>{money(stats?.revenue_cents ?? 0)}</strong>
        </p>
      </PageSection>
      <PageSection isFilled={false} className="rr-section">
        <div className="rr-grid">
          <div className="rr-grid__left">
            <MenuPane
              menu={menu}
              loading={loading}
              query={query}
              onQuery={setQuery}
              cart={cart}
              onSetQty={setQuantity}
              customer={customer}
              onCustomer={setCustomer}
              cartTotal={cartTotal}
              onSubmit={submitOrder}
              busy={busy}
              error={error}
              onDismissError={() => setError(null)}
            />
          </div>
          <div className="rr-grid__right">
            <Board
              orders={orders}
              loading={loading}
              live={live}
              advancing={advancing}
              onAdvance={advanceOrder}
              onRestock={restock}
              restocking={restocking}
              onReset={resetBoard}
              resetting={resetting}
            />
            <OpsStrip stats={stats} />
            <StackCard web={web} stats={stats} />
          </div>
        </div>
      </PageSection>
    </Page>
  );
}
