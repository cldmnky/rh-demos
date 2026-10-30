import { APIRequestContext, Page, expect } from '@playwright/test';

export interface MenuItem {
  id: number;
  name: string;
  stock: number;
  price_cents: number;
}

export interface Order {
  id: number;
  code: string;
  status: 'queued' | 'cooking' | 'plating' | 'served';
  items: { name: string; qty: number }[];
}

export const restock = async (request: APIRequestContext) => {
  const response = await request.post('/api/restock');
  expect(response.ok(), 'restock should succeed').toBeTruthy();
};

export const menu = async (request: APIRequestContext): Promise<MenuItem[]> => {
  const response = await request.get('/api/menu');
  expect(response.ok()).toBeTruthy();
  return (await response.json()).items as MenuItem[];
};

export const createOrder = async (
  request: APIRequestContext,
  items: { menu_item_id: number; qty: number }[],
  customer = 'Playwright Cadet',
): Promise<Order> => {
  const response = await request.post('/api/orders', { data: { customer, items } });
  expect(response.status(), await response.text()).toBe(201);
  return (await response.json()) as Order;
};

export const waitForLive = async (page: Page) => {
  await expect(page.getByTestId('live-badge')).toHaveText(/live/i);
};
