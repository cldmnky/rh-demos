import { expect, test } from '@playwright/test';
import { menu } from './helpers';

test.describe('galley menu', () => {
  test('renders dishes from MariaDB with prices and stock', async ({ page, request }) => {
    const dishes = await menu(request);
    await page.goto('/');

    await expect(page.getByText('Galley menu')).toBeVisible();
    await expect(page.getByText(dishes[0].name, { exact: false }).first()).toBeVisible();
    await expect(page.getByTestId('live-badge')).toHaveText(/live|reconnecting/i);
  });

  test('FULLTEXT search narrows the menu to spicy dishes', async ({ page }) => {
    await page.goto('/');
    const galley = page.getByTestId('galley-menu');
    const search = page.getByRole('textbox', { name: 'Search the menu' });
    await search.fill('spicy');

    await expect(galley.getByText('Solar Flare Tan Tan')).toBeVisible();
    await expect(galley.getByText('Lunar Shoyu')).toHaveCount(0);

    await search.fill('');
    await expect(galley.getByText('Lunar Shoyu')).toBeVisible();
  });
});
