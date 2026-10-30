import { expect, test } from '@playwright/test';
import { createOrder, restock, waitForLive } from './helpers';

test.describe('live board', () => {
  test('a status change streams to another browser without a reload', async ({ browser, request }) => {
    await restock(request);
    const order = await createOrder(request, [{ menu_item_id: 4, qty: 1 }]);

    const galley = await browser.newContext();
    const crew = await browser.newContext();
    const galleyPage = await galley.newPage();
    const crewPage = await crew.newPage();

    await galleyPage.goto('/');
    await crewPage.goto('/');
    await waitForLive(galleyPage);
    await waitForLive(crewPage);

    const status = crewPage.getByTestId(`order-${order.code}-status`);
    await expect(status).toContainText('In the queue');

    // Only one browser clicks; the other must update over SSE.
    await galleyPage.locator(`[data-ouia-component-id="advance-${order.code}"]`).click();
    await expect(status).toContainText('Cooking');
    await expect(galleyPage.getByTestId(`order-${order.code}-status`)).toContainText('Cooking');

    await galley.close();
    await crew.close();
  });
});
