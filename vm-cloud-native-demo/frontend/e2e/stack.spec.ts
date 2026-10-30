import { expect, test } from '@playwright/test';

const expectedWeb = process.env.EXPECTED_WEB_RUNTIME || 'VM';
const expectedAPI = process.env.EXPECTED_API_RUNTIME || 'VM';

test.describe('stack badge', () => {
  test('shows which tier answers, so the cutover is verifiable', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByTestId('web-runtime')).toContainText(expectedWeb, { timeout: 15_000 });
    await expect(page.getByTestId('api-runtime')).toContainText(expectedAPI, { timeout: 15_000 });
    await expect(page.getByTestId('db-version')).toContainText(/MariaDB/i);
  });
});
