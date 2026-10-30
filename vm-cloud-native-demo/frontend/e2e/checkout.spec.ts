import { expect, test } from '@playwright/test';
import { restock } from './helpers';

test.describe('placing a mission', () => {
  test('a bowl goes from tray to Mission Control', async ({ page, request }) => {
    await restock(request);
    await page.goto('/');

    await page.getByRole('textbox', { name: 'Crew name' }).fill('Cadet Vega');
    await page.locator('[data-ouia-component-id="add-2"]').click();
    await page.locator('[data-ouia-component-id="add-2"]').click();
    await expect(page.getByText('In tray (2)')).toBeVisible();

    await page.locator('[data-ouia-component-id="place-order"]').click();

    const board = page.getByRole('list', { name: 'Mission Control orders' });
    await expect(board.getByText('Cadet Vega').first()).toBeVisible();
    await expect(board.getByText('2× Nebula Miso').first()).toBeVisible();
    await expect(page.getByText('In the queue').first()).toBeVisible();
  });

  test('clearing the board empties Mission Control but keeps the menu', async ({ page, request }) => {
    await restock(request);
    await page.goto('/');
    await page.locator('[data-ouia-component-id="add-8"]').click();
    await page.locator('[data-ouia-component-id="place-order"]').click();
    await expect(page.getByRole('list', { name: 'Mission Control orders' })).toBeVisible();

    await page.locator('[data-ouia-component-id="reset"]').click();
    await expect(page.getByText('No missions on this station')).toBeVisible();
    await expect(page.getByTestId('galley-menu')).toBeVisible();
  });

  test('advancing a mission moves it to the next station', async ({ page, request }) => {
    await restock(request);
    await page.goto('/');

    await page.locator('[data-ouia-component-id="add-6"]').click();
    await page.locator('[data-ouia-component-id="place-order"]').click();

    const advance = page.locator('[data-ouia-component-id^="advance-M-"]').first();
    await advance.click();
    await expect(page.getByText('Cooking').first()).toBeVisible();
    await advance.click();
    await expect(page.getByText('Plating').first()).toBeVisible();
  });
});
