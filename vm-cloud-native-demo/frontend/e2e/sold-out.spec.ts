import { expect, test } from '@playwright/test';
import { restock } from './helpers';

test.describe('transactional stock', () => {
  test('the tray surfaces a 409 sold-out alert instead of a partial order', async ({ page, request }) => {
    await restock(request);
    await page.goto('/');

    // Drain Supernova Shio (20 in stock) through the API, leaving the UI closed.
    for (const qty of [9, 9, 2]) {
      const response = await request.post('/api/orders', {
        data: { customer: 'Drain', items: [{ menu_item_id: 5, qty }] },
      });
      expect(response.status()).toBe(201);
    }

    await page.reload();
    await expect(page.locator('[data-ouia-component-id="add-5"]')).toBeDisabled();

    // Force the stale-basket case: put one in the tray, then drain the rest.
    await restock(request);
    await page.reload();
    await page.locator('[data-ouia-component-id="add-5"]').click();
    for (const qty of [9, 9, 2]) {
      await request.post('/api/orders', { data: { customer: 'Drain', items: [{ menu_item_id: 5, qty }] } });
    }
    await page.locator('[data-ouia-component-id="place-order"]').click();

    // The 409 alert names the dish and the tray is kept, not silently emptied.
    await expect(page.getByText(/Supernova Shio is sold out/)).toBeVisible();
    await expect(page.getByText('In tray (1)')).toBeVisible();
  });
});
